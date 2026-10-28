using System.Windows;
using System.Windows.Controls;
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

    public MainWindow()
    {
        InitializeComponent();
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
            ApplyFilter();
            QueueSummary.Text = $"{_allJobs.Count(job => job.State == "downloading")} active · {_allJobs.Count(job => job.State is "queued" or "scheduled")} queued";
            ConnectionStatus.Text = "Engine connected";
            Dispatcher.BeginInvoke(ReportPhase0UiState, DispatcherPriority.ApplicationIdle);
        }
        catch (Exception error)
        {
            ConnectionStatus.Text = $"Engine disconnected · {error.Message}";
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

    private async Task ControlAsync(DownloadJob job, string action)
    {
        try { await _engine.ControlJobAsync(job, action); await RefreshAsync(); }
        catch (Exception error) { MessageBox.Show(this, error.Message, "Speed Download", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private async void OnStartOrResume(object sender, RoutedEventArgs e)
    {
        var job = JobForButton(sender);
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
        var job = JobForButton(sender);
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
}
