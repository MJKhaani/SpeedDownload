using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace SpeedDownload;

public partial class MainWindow : Window
{
    private readonly EngineClient _engine = new();
    private readonly DispatcherTimer _refreshTimer;
    private readonly Forms.NotifyIcon _trayIcon;
    private IReadOnlyList<DownloadJob> _allJobs = [];
    private string _category = "All Downloads";
    private bool _refreshInFlight;
    private bool _updatingLimitControl;
    private bool _limitBusy;
    private bool _limitLoaded;
    private ulong _lastLimit;
    private DateTime _limitReadAt;
    private readonly Dictionary<string, (ulong bytes, long ticks)> _speedSamples = new();
    private readonly List<SpeedLimitOption> _speedLimits = BuildSpeedLimits();

    private sealed record SpeedLimitOption(ulong BytesPerSecond, string Label);

    public MainWindow()
    {
        InitializeComponent();
        _updatingLimitControl = true;
        StatusLimitCombo.ItemsSource = _speedLimits;
        StatusLimitCombo.SelectedIndex = 0;
        _updatingLimitControl = false;
        PreviewKeyDown += OnWindowKeyDown;
        var trayMenu = new Forms.ContextMenuStrip();
        trayMenu.Items.Add("Open Speed Download", null, (_, _) => Dispatcher.Invoke(ShowAndActivate));
        trayMenu.Items.Add("Quit", null, (_, _) => Dispatcher.Invoke(Close));
        _trayIcon = new Forms.NotifyIcon
        {
            Icon = new Drawing.Icon(Path.Combine(AppContext.BaseDirectory, "SpeedDownload.ico")),
            Text = "Speed Download",
            ContextMenuStrip = trayMenu,
            Visible = true,
        };
        _trayIcon.DoubleClick += (_, _) => Dispatcher.Invoke(ShowAndActivate);
        Closed += (_, _) => { _trayIcon.Visible = false; _trayIcon.Dispose(); trayMenu.Dispose(); };

        _refreshTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _refreshTimer.Tick += async (_, _) => await RefreshAsync();
        _refreshTimer.Start();
        Loaded += async (_, _) => await RefreshAsync();
    }

    private void ShowAndActivate()
    {
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Show();
        Activate();
    }

    private async Task RefreshAsync()
    {
        if (_refreshInFlight) return;
        _refreshInFlight = true;
        try
        {
            _allJobs = await _engine.ListJobsAsync();
            UpdateDownloadSpeeds();
            ApplyFilter();
            QueueSummary.Text = $"{_allJobs.Count(job => job.State == "downloading")} active · {_allJobs.Count(job => job.State is "queued" or "scheduled")} queued";
            ConnectionStatus.Text = "Engine connected";
            ConnectionDot.Fill = Brushes.SeaGreen;
            Dispatcher.BeginInvoke(ReportPhase0UiState, DispatcherPriority.ApplicationIdle);
            if (!_limitBusy && (!_limitLoaded || DateTime.UtcNow - _limitReadAt > TimeSpan.FromSeconds(15)))
                await RefreshGlobalLimitAsync();
        }
        catch (Exception error)
        {
            ConnectionStatus.Text = $"Engine disconnected · {error.Message}";
            ConnectionDot.Fill = Brushes.DarkOrange;
            TotalSpeed.Text = "↓ 0 KB/s";
            Dispatcher.BeginInvoke(ReportPhase0UiState, DispatcherPriority.ApplicationIdle);
        }
        finally { _refreshInFlight = false; }
    }

    private void ReportPhase0UiState()
    {
        var path = Environment.GetEnvironmentVariable("SPEED_DOWNLOAD_PHASE0_REPORT");
        if (string.IsNullOrEmpty(path) || !Path.IsPathFullyQualified(path)) return;
        if (JobsList.Items.Count > 0 && JobsList.ItemContainerGenerator.ContainerFromIndex(0) is null) return;
        try
        {
            var rows = _allJobs.Select(job => $"{job.JobId}\t{job.State}\t{job.Completed}");
            File.WriteAllLines(path, [ConnectionStatus.Text, .. rows]);
        }
        catch (IOException) { }
    }

    private void ApplyFilter()
    {
        if (JobsList is null) return;
        IEnumerable<DownloadJob> jobs = _category switch
        {
            "Unfinished" => _allJobs.Where(job => job.State is not ("completed" or "failed" or "canceled")),
            "Completed" => _allJobs.Where(job => job.State == "completed"),
            "Failed" => _allJobs.Where(job => job.State is "failed" or "canceled"),
            _ => _allJobs,
        };
        var query = SearchBox?.Text?.Trim();
        if (!string.IsNullOrEmpty(query))
            jobs = jobs.Where(job => job.Title.Contains(query, StringComparison.OrdinalIgnoreCase) || job.Url.Contains(query, StringComparison.OrdinalIgnoreCase));
        var selectedId = (JobsList.SelectedItem as DownloadJob)?.JobId;
        var visibleJobs = jobs.ToList();
        JobsList.ItemsSource = visibleJobs;
        if (selectedId is not null) JobsList.SelectedItem = visibleJobs.FirstOrDefault(job => job.JobId == selectedId);
        SectionCount.Text = $"{visibleJobs.Count} transfer{(visibleJobs.Count == 1 ? "" : "s")}";
        UpdateDetails(JobsList.SelectedItem as DownloadJob);
    }

    private void UpdateDetails(DownloadJob? job)
    {
        DetailTitle.Text = job?.Title ?? "Select a transfer";
        DetailState.Text = job?.State ?? "—";
        DetailUrl.Text = job?.Url ?? "—";
        DetailDestination.Text = job?.Destination ?? "—";
        DetailProgress.Text = job?.ProgressText ?? "—";
        DetailError.Text = job?.ErrorMessage ?? "";
    }

    private void OnNavigationChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Navigation?.SelectedItem is not ListBoxItem item || SectionTitle is null) return;
        _category = item.Content?.ToString() ?? "All Downloads";
        SectionTitle.Text = _category;
        ApplyFilter();
    }

    private void OnJobSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (DetailTitle is not null) UpdateDetails(JobsList.SelectedItem as DownloadJob);
    }

    private void OnSearchChanged(object sender, TextChangedEventArgs e) => ApplyFilter();
    private async void OnRefresh(object sender, RoutedEventArgs e) => await RefreshAsync();

    private void OnAdd(object sender, RoutedEventArgs e)
    {
        var dialog = new AddDownloadWindow(_engine) { Owner = this };
        if (dialog.ShowDialog() == true) _ = RefreshAsync();
    }

    private DownloadJob? JobForButton(object sender) =>
        sender is Button { Tag: string id } ? _allJobs.FirstOrDefault(job => job.JobId == id) : null;

    private void UpdateDownloadSpeeds()
    {
        var now = Stopwatch.GetTimestamp();
        var activeIds = new HashSet<string>();
        double total = 0;
        foreach (var job in _allJobs.Where(job => job.State == "downloading"))
        {
            activeIds.Add(job.JobId);
            double speed = 0;
            if (_speedSamples.TryGetValue(job.JobId, out var previous) && job.Completed >= previous.bytes)
            {
                var seconds = (now - previous.ticks) / (double)Stopwatch.Frequency;
                if (seconds > 0) speed = (job.Completed - previous.bytes) / seconds;
            }
            job.SpeedText = speed > 0 ? FormatRate(speed) : "";
            total += speed;
            _speedSamples[job.JobId] = (job.Completed, now);
        }
        foreach (var id in _speedSamples.Keys.Where(id => !activeIds.Contains(id)).ToArray()) _speedSamples.Remove(id);
        TotalSpeed.Text = "↓ " + FormatRate(total);
    }

    private static string FormatRate(double bytesPerSecond) => bytesPerSecond switch
    {
        >= 1_000_000_000 => $"{bytesPerSecond / 1_000_000_000:0.#} GB/s",
        >= 1_000_000 => $"{bytesPerSecond / 1_000_000:0.#} MB/s",
        _ => $"{bytesPerSecond / 1_000:0.#} KB/s",
    };

    private static List<SpeedLimitOption> BuildSpeedLimits()
    {
        var values = new[] { 1, 2, 3, 5, 8, 10, 15, 20, 30, 50, 75, 100, 150, 200 };
        var options = new List<SpeedLimitOption> { new(0, "Unlimited") };
        options.AddRange(values.Select(value => new SpeedLimitOption((ulong)value * 1_000_000, $"{value} MB/s")));
        return options;
    }

    private async Task RefreshGlobalLimitAsync()
    {
        try
        {
            var limit = await _engine.GetGlobalBandwidthLimitAsync();
            _lastLimit = limit;
            _limitLoaded = true;
            _limitReadAt = DateTime.UtcNow;
            SelectLimit(limit);
        }
        catch (Exception error) { StatusLimitCombo.ToolTip = $"Could not read the global limit: {error.Message}"; }
    }

    private void SelectLimit(ulong limit)
    {
        _updatingLimitControl = true;
        var choice = _speedLimits.FirstOrDefault(option => option.BytesPerSecond == limit);
        if (choice is null)
        {
            choice = new SpeedLimitOption(limit, $"{limit / 1_000_000d:0.#} MB/s");
            _speedLimits.Add(choice);
            StatusLimitCombo.Items.Refresh();
        }
        StatusLimitCombo.SelectedItem = choice;
        StatusLimitCombo.ToolTip = "Global download speed limit";
        _updatingLimitControl = false;
    }

    private async void OnSpeedLimitChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingLimitControl || _limitBusy || StatusLimitCombo.SelectedItem is not SpeedLimitOption option) return;
        _limitBusy = true;
        StatusLimitCombo.IsEnabled = false;
        try
        {
            await _engine.SetGlobalBandwidthLimitAsync(option.BytesPerSecond);
            _lastLimit = option.BytesPerSecond;
            _limitLoaded = true;
            _limitReadAt = DateTime.UtcNow;
        }
        catch (Exception error)
        {
            SelectLimit(_lastLimit);
            MessageBox.Show(this, error.Message, "Speed Download", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally { _limitBusy = false; StatusLimitCombo.IsEnabled = true; }
    }

    private async Task ControlAsync(DownloadJob job, string action)
    {
        try { await _engine.ControlJobAsync(job, action); await RefreshAsync(); }
        catch (Exception error) { MessageBox.Show(this, error.Message, "Speed Download", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private async void OnStartOrResume(object sender, RoutedEventArgs e)
    {
        await StartOrResumeAsync(JobForButton(sender));
    }

    private async Task StartOrResumeAsync(DownloadJob? job)
    {
        if (job is null) return;
        var action = job.State switch
        {
            "queued" or "scheduled" or "retry_wait" => "start",
            "paused" => "resume",
            "failed" => "retry",
            _ => null,
        };
        if (action is not null) await ControlAsync(job, action);
    }

    private async void OnPause(object sender, RoutedEventArgs e)
    {
        await PauseAsync(JobForButton(sender));
    }

    private async Task PauseAsync(DownloadJob? job)
    {
        if (job is not null && job.State is "downloading" or "queued" or "scheduled")
            await ControlAsync(job, "pause");
    }

    private void OnInfo(object sender, RoutedEventArgs e)
    {
        var job = JobForButton(sender);
        if (job is null) return;
        JobsList.SelectedItem = JobsList.Items.Cast<DownloadJob>().FirstOrDefault(item => item.JobId == job.JobId);
        InspectorColumn.Width = new GridLength(270);
        Inspector.Visibility = Visibility.Visible;
    }

    private void OnCloseInspector(object sender, RoutedEventArgs e)
    {
        Inspector.Visibility = Visibility.Collapsed;
        InspectorColumn.Width = new GridLength(0);
    }

    private async void OnStartSelected(object sender, RoutedEventArgs e) => await StartOrResumeAsync(JobsList.SelectedItem as DownloadJob);
    private async void OnPauseSelected(object sender, RoutedEventArgs e) => await PauseAsync(JobsList.SelectedItem as DownloadJob);
    private void OnToggleInspector(object sender, RoutedEventArgs e)
    {
        if (Inspector.Visibility == Visibility.Visible) OnCloseInspector(sender, e);
        else if (JobsList.SelectedItem is DownloadJob job)
        {
            InspectorColumn.Width = new GridLength(270);
            Inspector.Visibility = Visibility.Visible;
            UpdateDetails(job);
        }
    }

    private void OnFind(object sender, RoutedEventArgs e) { SearchBox.Focus(); SearchBox.SelectAll(); }
    private void OnFocusSpeedLimit(object sender, RoutedEventArgs e) { StatusLimitCombo.Focus(); StatusLimitCombo.IsDropDownOpen = true; }
    private void OnQuit(object sender, RoutedEventArgs e) => Close();
    private void OnAbout(object sender, RoutedEventArgs e) => MessageBox.Show(this,
        "Speed Download\nWindows client with bundled download engine.", "About Speed Download", MessageBoxButton.OK, MessageBoxImage.Information);

    private void OnOpenDownloadsFolder(object sender, RoutedEventArgs e)
    {
        var folder = (JobsList.SelectedItem as DownloadJob)?.Destination;
        if (string.IsNullOrWhiteSpace(folder)) folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        if (Directory.Exists(folder)) Process.Start(new ProcessStartInfo(folder) { UseShellExecute = true });
    }

    private void OnWindowKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.F5) { _ = RefreshAsync(); e.Handled = true; }
        else if (e.Key == Key.N && Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) { OnAdd(sender, new RoutedEventArgs()); e.Handled = true; }
        else if (e.Key == Key.F && Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) { OnFind(sender, new RoutedEventArgs()); e.Handled = true; }
    }
}
