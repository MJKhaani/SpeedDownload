using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Controls.Primitives;
using System.Text.Json.Nodes;
using System.Collections.ObjectModel;
using ContextMenuStrip = System.Windows.Forms.ContextMenuStrip;
using Icon = System.Drawing.Icon;
using NotifyIcon = System.Windows.Forms.NotifyIcon;

namespace SpeedDownload;

public sealed partial class MainWindow : Window
{
    private readonly EngineClient _engine = new();
    private readonly DispatcherQueueTimer _refreshTimer;
    private bool _refreshInFlight;
    private IReadOnlyList<DownloadJob> _allJobs = [];
    private readonly ObservableCollection<DownloadJob> _visibleJobs = [];
    private string _category = "All downloads";
    private JsonObject? _settings;
    private readonly SemaphoreSlim _settingsGate = new(1, 1);
    private bool _loadingSettings;
    private bool _showNarrowDetails;
    private bool _loadingSpeedLimit;
    private string _lastQueueId = "main";
    private readonly NotifyIcon _trayIcon;

    public MainWindow()
    {
        App.TracePhase0Startup("Main window constructor");
        try
        {
            InitializeComponent();
        }
        catch (Exception error)
        {
            App.LogClientException(error, "Main window XAML error");
            throw;
        }
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(920, 620));
        App.TracePhase0Startup("Main window XAML initialized");
        JobsList.ItemsSource = _visibleJobs;
        var trayMenu = new ContextMenuStrip();
        trayMenu.Items.Add("Open Speed Download", null, (_, _) => Activate());
        trayMenu.Items.Add("Quit", null, (_, _) => Environment.Exit(0));
        _trayIcon = new NotifyIcon
        {
            Icon = new Icon(Path.Combine(AppContext.BaseDirectory, "SpeedDownload.ico")),
            Text = "Speed Download",
            ContextMenuStrip = trayMenu,
            Visible = true,
        };
        App.TracePhase0Startup("Tray icon initialized");
        _trayIcon.DoubleClick += (_, _) => Activate();
        Closed += (_, _) => _trayIcon.Dispose();
        _refreshTimer = DispatcherQueue.CreateTimer();
        _refreshTimer.Interval = TimeSpan.FromSeconds(2);
        _refreshTimer.Tick += async (_, _) => await RefreshAsync();
        _refreshTimer.Start();
        _ = RefreshAsync();
    }


    private async Task RefreshAsync()
    {
        if (_refreshInFlight) return;
        _refreshInFlight = true;
        try
        {
            var jobs = await _engine.ListJobsAsync();
            _allJobs = jobs;
            if (_settings is null) await LoadSettingsAsync();
            UpdateNavigationCounts();
            ApplyFilter();
            UpdateSummary();
            ConnectionStatus.Text = "Engine connected";
            MessageBar.IsOpen = false;
            ReportPhase0UiState();
        }
        catch (Exception error)
        {
            ConnectionStatus.Text = "Engine disconnected";
            ShowMessage(error.Message, InfoBarSeverity.Error);
            ReportPhase0UiState();
        }
        finally
        {
            _refreshInFlight = false;
        }
    }

    private async void OnRefresh(object sender, RoutedEventArgs e) => await RefreshAsync();

    private void ReportPhase0UiState()
    {
        var path = Environment.GetEnvironmentVariable("SPEED_DOWNLOAD_PHASE0_REPORT");
        if (string.IsNullOrEmpty(path) || !Path.IsPathFullyQualified(path)) return;
        try
        {
            var rows = _allJobs.Select(job => $"{job.JobId}\t{job.State}\t{job.Completed}");
            File.WriteAllLines(path, [ConnectionStatus.Text, .. rows]);
        }
        catch (IOException) { }
    }

    private void OnNavigationItemInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        if (args.IsSettingsInvoked)
        {
            Workspace.Visibility = Visibility.Collapsed;
            SettingsView.Visibility = Visibility.Visible;
            _ = LoadSettingsAsync();
            return;
        }
        if (args.InvokedItemContainer is NavigationViewItem item && item.Tag is string tag)
        {
            if (tag == "new-queue") { _ = CreateQueueAsync(); return; }
            _category = tag;
            SectionTitle.Text = tag.StartsWith("queue:", StringComparison.Ordinal) ? item.Content?.ToString() ?? "Queue" : tag;
            SettingsView.Visibility = Visibility.Collapsed;
            Workspace.Visibility = Visibility.Visible;
            ApplyFilter();
        }
    }

    private void OnSearchTextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args) => ApplyFilter();

    private void ApplyFilter()
    {
        IEnumerable<DownloadJob> jobs = _category switch
        {
            "In progress" => _allJobs.Where(job => job.State is "queued" or "scheduled" or "paused" or "retry_wait" or "downloading"),
            "Completed" => _allJobs.Where(job => job.State == "completed"),
            "Failed" => _allJobs.Where(job => job.State is "failed" or "canceled"),
            var queue when queue.StartsWith("queue:", StringComparison.Ordinal) => _allJobs.Where(job => job.QueueId == queue[6..]),
            _ => _allJobs,
        };
        var query = SearchBox?.Text?.Trim();
        if (!string.IsNullOrEmpty(query)) jobs = jobs.Where(job => job.Title.Contains(query, StringComparison.OrdinalIgnoreCase) || job.Url.Contains(query, StringComparison.OrdinalIgnoreCase));
        var currentSelectionId = (JobsList.SelectedItem as DownloadJob)?.JobId;
        var filtered = jobs.ToList();
        for (var index = 0; index < filtered.Count; index++)
        {
            var incoming = filtered[index];
            var existingIndex = -1;
            for (var scan = index; scan < _visibleJobs.Count; scan++)
                if (_visibleJobs[scan].JobId == incoming.JobId) { existingIndex = scan; break; }
            if (existingIndex < 0) _visibleJobs.Insert(index, incoming);
            else
            {
                if (existingIndex != index) _visibleJobs.Move(existingIndex, index);
                _visibleJobs[index].UpdateFrom(incoming);
            }
        }
        while (_visibleJobs.Count > filtered.Count) _visibleJobs.RemoveAt(_visibleJobs.Count - 1);
        if (currentSelectionId is not null && (JobsList.SelectedItem as DownloadJob)?.JobId != currentSelectionId)
            JobsList.SelectedItem = _visibleJobs.FirstOrDefault(job => job.JobId == currentSelectionId);
        UpdateDetails(JobsList.SelectedItem as DownloadJob);
    }

    private void OnJobSelectionChanged(object sender, SelectionChangedEventArgs e) => UpdateDetails(JobsList.SelectedItem as DownloadJob);

    private void OnWorkspaceSizeChanged(object sender, SizeChangedEventArgs e)
        => UpdateResponsiveLayout();

    private void OnCloseDetails(object sender, RoutedEventArgs e)
    {
        _showNarrowDetails = false;
        UpdateResponsiveLayout();
    }

    private void UpdateDetails(DownloadJob? job)
    {
        DetailTitle.Text = job?.Title ?? "Select a transfer";
        DetailState.Text = job?.State ?? "—";
        DetailUrl.Text = job?.Url ?? "—";
        DetailDestination.Text = job?.Destination ?? "—";
        DetailProgress.Text = job is null ? "" : job.Total > 0 ? $"{job.ProgressText} · {job.Progress:0.#}%" : job.State == "downloading" ? "Waiting for the server to report file size…" : "";
        DetailError.Text = job?.ErrorMessage ?? "";
    }

    private void UpdateSummary()
    {
        QueueSummary.Text = $"{_allJobs.Count(job => job.State == "downloading")} active · {_allJobs.Count(job => job.State is "queued" or "scheduled")} queued";
    }

    private void UpdateNavigationCounts()
    {
        AllNavigationItem.Content = $"All downloads  {_allJobs.Count}";
        ProgressNavigationItem.Content = $"In progress  {_allJobs.Count(job => job.State is "queued" or "scheduled" or "paused" or "retry_wait" or "downloading")}";
        CompletedNavigationItem.Content = $"Completed  {_allJobs.Count(job => job.State == "completed")}";
        FailedNavigationItem.Content = $"Failed  {_allJobs.Count(job => job.State is "failed" or "canceled")}";
    }

    private async Task LoadSettingsAsync()
    {
        try
        {
            _loadingSettings = true;
            _settings = await _engine.GetSettingsAsync();
            DebugLoggingSwitch.IsOn = ReadBool("debug_log_enabled");
            DownloadFolderBox.Text = ReadString("default_download_folder");
            ConcurrentBox.Value = ReadNumber("max_concurrent_tasks");
            ConnectionsBox.Value = ReadNumber("default_connections_per_task");
            BandwidthBox.Value = ReadNumber("bandwidth_limit_bytes_per_second") / 1_000_000d;
            _loadingSpeedLimit = true;
            var selectedLimit = ReadNumber("bandwidth_limit_bytes_per_second") / 1_000_000d;
            SpeedLimitBox.SelectedItem = SpeedLimitBox.Items.OfType<ComboBoxItem>().FirstOrDefault(item => double.TryParse(item.Tag?.ToString(), out var value) && value == selectedLimit);
            _loadingSpeedLimit = false;
            BrowserExtensionsBox.Text = ReadString("browser_grab_extensions");
            ProxyUrlBox.Text = ReadString("proxy_url");
            SelectChoice(MultipartModeBox, ReadString("multipart_mode"));
            SelectChoice(ProxyModeBox, ReadString("proxy_mode"));
            ProxyUrlBox.IsEnabled = ReadString("proxy_mode") == "custom";
            UpdateQueues();
            SettingsMessage.IsOpen = false;
        }
        catch (Exception error) { ShowMessage(error.Message, InfoBarSeverity.Error); }
        finally { _loadingSettings = false; }
    }

    private string ReadString(string key) => _settings?[key]?.GetValue<string>() ?? "";
    private double ReadNumber(string key) => System.Text.Json.JsonSerializer.Deserialize<double>(_settings?[key]?.ToJsonString() ?? "0");
    private bool ReadBool(string key) => _settings?[key]?.GetValue<bool>() ?? false;

    private static void SelectChoice(ComboBox box, string tag)
    {
        box.SelectedItem = box.Items.OfType<ComboBoxItem>().FirstOrDefault(item => item.Tag?.ToString() == tag);
    }

    private void UpdateQueues()
    {
        while (AppNavigation.MenuItems.Count > 7) AppNavigation.MenuItems.RemoveAt(7);
        if (_settings?["queues"] is not JsonArray queues) return;
        foreach (var queue in queues.OfType<JsonObject>())
        {
            var id = queue["id"]?.GetValue<string>();
            var name = queue["name"]?.GetValue<string>();
            if (!string.IsNullOrWhiteSpace(id))
                AppNavigation.MenuItems.Add(new NavigationViewItem { Content = name ?? id, Tag = "queue:" + id, Icon = new SymbolIcon(Symbol.List) });
        }
    }

    private async Task SaveSettingsAsync(Action<JsonObject> change)
    {
        if (_loadingSettings || _settings is null) return;
        await _settingsGate.WaitAsync();
        try
        {
            var updated = (JsonObject)_settings.DeepClone();
            change(updated);
            await _engine.UpdateSettingsAsync(updated);
            _settings = updated;
            SettingsMessage.IsOpen = false;
        }
        catch (Exception error)
        {
            SettingsMessage.Message = error.Message;
            SettingsMessage.IsOpen = true;
            if (Workspace.Visibility == Visibility.Visible) ShowMessage(error.Message, InfoBarSeverity.Error);
        }
        finally { _settingsGate.Release(); }
    }

    private void OnSettingToggled(object sender, RoutedEventArgs e) =>
        _ = SaveSettingsAsync(settings => settings["debug_log_enabled"] = DebugLoggingSwitch.IsOn);

    private void OnNumberSettingChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (_loadingSettings || double.IsNaN(sender.Value)) return;
        if (sender == ConcurrentBox) _ = SaveSettingsAsync(settings => settings["max_concurrent_tasks"] = (int)sender.Value);
        else if (sender == ConnectionsBox) _ = SaveSettingsAsync(settings => settings["default_connections_per_task"] = (int)sender.Value);
        else if (sender == BandwidthBox) _ = SaveSettingsAsync(settings => settings["bandwidth_limit_bytes_per_second"] = (ulong)(sender.Value * 1_000_000));
    }

    private void OnChoiceSettingChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loadingSettings || sender is not ComboBox box || box.SelectedItem is not ComboBoxItem item) return;
        if (box == MultipartModeBox) _ = SaveSettingsAsync(settings => settings["multipart_mode"] = item.Tag?.ToString());
        else if (box == ProxyModeBox)
        {
            ProxyUrlBox.IsEnabled = item.Tag?.ToString() == "custom";
            if (ProxyUrlBox.IsEnabled && string.IsNullOrWhiteSpace(ProxyUrlBox.Text))
            {
                SettingsMessage.Message = "Enter a manual HTTP proxy URL to enable this mode.";
                SettingsMessage.IsOpen = true;
                return;
            }
            _ = SaveSettingsAsync(settings => settings["proxy_mode"] = item.Tag?.ToString());
        }
    }

    private void OnSettingLostFocus(object sender, RoutedEventArgs e)
    {
        if (ReferenceEquals(sender, DownloadFolderBox)) _ = SaveSettingsAsync(settings => settings["default_download_folder"] = DownloadFolderBox.Text.Trim());
        else if (ReferenceEquals(sender, BrowserExtensionsBox)) _ = SaveSettingsAsync(settings => settings["browser_grab_extensions"] = BrowserExtensionsBox.Text.Trim());
        else if (ReferenceEquals(sender, ProxyUrlBox)) _ = SaveSettingsAsync(settings =>
        {
            settings["proxy_url"] = string.IsNullOrWhiteSpace(ProxyUrlBox.Text) ? null : ProxyUrlBox.Text.Trim();
            settings["proxy_mode"] = (ProxyModeBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "system";
        });
    }

    private async void OnQueueSettings(object sender, RoutedEventArgs e)
    {
        if (!_category.StartsWith("queue:", StringComparison.Ordinal) || _settings?["queues"] is not JsonArray queues) return;
        var id = _category[6..];
        var queue = queues.OfType<JsonObject>().FirstOrDefault(value => value["id"]?.GetValue<string>() == id);
        if (queue is null) return;
        var count = new NumberBox { Header = "Maximum active downloads", Minimum = 1, Maximum = 32, Value = System.Text.Json.JsonSerializer.Deserialize<double>(queue["max_active"]?.ToJsonString() ?? "1") };
        var schedule = new ToggleSwitch { Header = "Start and stop on a schedule", IsOn = queue["schedule_enabled"]?.GetValue<bool>() ?? false };
        var days = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        string[] dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
        var dayButtons = new ToggleButton[7];
        for (var day = 0; day < 7; day++)
        {
            var active = (queue["schedule_slots"] as JsonArray)?.Skip(day * 24).Take(24).Any(slot => slot?.GetValue<bool>() == true) ?? true;
            dayButtons[day] = new ToggleButton { Content = dayNames[day], IsChecked = active, MinWidth = 42 };
            days.Children.Add(dayButtons[day]);
        }
        var startHour = new NumberBox { Header = "Start hour (0–23)", Minimum = 0, Maximum = 23, Value = 0, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        var stopHour = new NumberBox { Header = "Stop hour (1–24)", Minimum = 1, Maximum = 24, Value = 24, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        var hours = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        hours.Children.Add(startHour);
        hours.Children.Add(stopHour);
        var finish = new ComboBox { Header = "When all downloads finish", MinWidth = 180 };
        finish.Items.Add(new ComboBoxItem { Content = "Do nothing", Tag = "none" });
        finish.Items.Add(new ComboBoxItem { Content = "Exit app", Tag = "quit_app" });
        finish.Items.Add(new ComboBoxItem { Content = "Power off", Tag = "power_off" });
        finish.Items.Add(new ComboBoxItem { Content = "Run command", Tag = "user_command" });
        SelectChoice(finish, queue["finish_action"]?.GetValue<string>() ?? "none");
        var command = new TextBox { Header = "Command", Text = queue["user_command"]?.GetValue<string>() ?? "", PlaceholderText = "Command to run after this queue finishes" };
        command.IsEnabled = (finish.SelectedItem as ComboBoxItem)?.Tag?.ToString() == "user_command";
        finish.SelectionChanged += (_, _) => command.IsEnabled = (finish.SelectedItem as ComboBoxItem)?.Tag?.ToString() == "user_command";
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(count);
        panel.Children.Add(schedule);
        panel.Children.Add(days);
        panel.Children.Add(hours);
        panel.Children.Add(finish);
        panel.Children.Add(command);
        var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = $"Queue settings · {queue["name"]?.GetValue<string>() ?? id}", Content = new ScrollViewer { Content = panel, MaxHeight = 500 }, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        if (double.IsNaN(count.Value) || count.Value < 1 || count.Value > 32 ||
            double.IsNaN(startHour.Value) || double.IsNaN(stopHour.Value) || startHour.Value >= stopHour.Value)
        { ShowMessage("Check the active download count and start/stop hours.", InfoBarSeverity.Warning); return; }
        if ((finish.SelectedItem as ComboBoxItem)?.Tag?.ToString() == "user_command" && string.IsNullOrWhiteSpace(command.Text))
        { ShowMessage("Enter a command for the completion action.", InfoBarSeverity.Warning); return; }
        await SaveSettingsAsync(settings =>
        {
            var target = (settings["queues"] as JsonArray)?.OfType<JsonObject>().FirstOrDefault(value => value["id"]?.GetValue<string>() == id);
            if (target is null) return;
            target["max_active"] = (int)count.Value;
            target["schedule_enabled"] = schedule.IsOn;
            target["schedule_slots"] = new JsonArray(Enumerable.Range(0, 168).Select(slot => (JsonNode?)JsonValue.Create(dayButtons[slot / 24].IsChecked == true && slot % 24 >= (int)startHour.Value && slot % 24 < (int)stopHour.Value)).ToArray());
            var action = (finish.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "none";
            target["finish_action"] = action;
            target["user_command"] = action == "user_command" ? command.Text.Trim() : null;
        });
    }

    private async void OnJobAction(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button || button.Tag is not string jobId) return;
        if (JobsList.ItemsSource is not IEnumerable<DownloadJob> jobs) return;
        var job = jobs.FirstOrDefault(item => item.JobId == jobId);
        if (job is null) return;
        var action = button.Content?.ToString() switch
        {
            "Start" => "start",
            "Pause" => "pause",
            "Resume" => "resume",
            "Retry" => job.State == "retry_wait" ? "start" : "retry",
            "Cancel" => "cancel",
            _ => null,
        };
        if (action is null) return;
        try
        {
            await _engine.ControlJobAsync(job, action);
            await RefreshAsync();
        }
        catch (Exception error)
        {
            ShowMessage(error.Message, InfoBarSeverity.Error);
            await RefreshAsync();
        }
    }

    private async void OnStartAll(object sender, RoutedEventArgs e)
    {
        foreach (var job in _allJobs.Where(job => job.State is "queued" or "paused" or "failed" or "retry_wait").ToArray())
            await ControlOneAsync(job, job.State switch { "paused" => "resume", "failed" => "retry", _ => "start" });
        await RefreshAsync();
    }

    private async void OnPauseAll(object sender, RoutedEventArgs e)
    {
        foreach (var job in _allJobs.Where(job => job.State is "queued" or "scheduled" or "downloading").ToArray())
            await ControlOneAsync(job, "pause");
        await RefreshAsync();
    }

    private async Task ControlOneAsync(DownloadJob job, string action)
    {
        try { await _engine.ControlJobAsync(job, action); }
        catch (Exception error) { ShowMessage(error.Message, InfoBarSeverity.Error); }
    }

    private void OnMoreActions(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button || button.Tag is not string id) return;
        var job = _allJobs.FirstOrDefault(item => item.JobId == id);
        if (job is null) return;
        var flyout = new MenuFlyout();
        void Add(string label, Action action)
        {
            var item = new MenuFlyoutItem { Text = label };
            item.Click += (_, _) => action();
            flyout.Items.Add(item);
        }
        if (job.State is "queued" or "scheduled" or "downloading") Add("Pause", () => _ = RunJobActionAsync(job, "pause"));
        if (job.State is "paused" or "failed" or "retry_wait") Add(job.State == "failed" ? "Retry" : "Resume", () => _ = RunJobActionAsync(job, job.State switch { "failed" => "retry", "paused" => "resume", _ => "start" }));
        Add("Details", () => { JobsList.SelectedItem = JobsList.ItemsSource is IEnumerable<DownloadJob> rows ? rows.FirstOrDefault(row => row.JobId == id) : null; _showNarrowDetails = true; UpdateDetails(job); UpdateResponsiveLayout(); });
        Add("Copy source URL", () => { var package = new Windows.ApplicationModel.DataTransfer.DataPackage(); package.SetText(job.Url); Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package); });
        if (job.State is "queued" or "scheduled" or "downloading" or "paused" or "retry_wait") Add("Cancel", () => _ = RunJobActionAsync(job, "cancel"));
        if (_settings?["queues"] is JsonArray queues && queues.Count > 1)
        {
            var sub = new MenuFlyoutSubItem { Text = "Move to queue" };
            foreach (var queue in queues.OfType<JsonObject>())
            {
                var queueId = queue["id"]?.GetValue<string>();
                if (string.IsNullOrWhiteSpace(queueId) || queueId == job.QueueId) continue;
                var item = new MenuFlyoutItem { Text = queue["name"]?.GetValue<string>() ?? queueId };
                item.Click += async (_, _) => { try { await _engine.MoveJobToQueueAsync(job, queueId); await RefreshAsync(); } catch (Exception error) { ShowMessage(error.Message, InfoBarSeverity.Error); } };
                sub.Items.Add(item);
            }
            if (sub.Items.Count > 0) flyout.Items.Add(sub);
        }
        flyout.ShowAt(button);
    }

    private async Task RunJobActionAsync(DownloadJob job, string action)
    {
        await ControlOneAsync(job, action);
        await RefreshAsync();
    }

    private void UpdateResponsiveLayout()
    {
        if (JobsList.Parent is not Grid grid) return;
        var show = _showNarrowDetails;
        var wide = grid.ActualWidth >= 700;
        DetailsColumn.Width = new GridLength(show && wide ? 300 : 0);
        DetailsPane.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        Grid.SetColumn(DetailsPane, wide ? 1 : 0);
        JobsList.Visibility = show && !wide ? Visibility.Collapsed : Visibility.Visible;
        CloseDetailsButton.Visibility = Visibility.Visible;
    }

    private void OnShowDetails(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string id }) return;
        JobsList.SelectedItem = (JobsList.ItemsSource as IEnumerable<DownloadJob>)?.FirstOrDefault(job => job.JobId == id);
        _showNarrowDetails = true;
        UpdateResponsiveLayout();
    }

    private void OnSpeedLimitChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loadingSpeedLimit || _settings is null || SpeedLimitBox.SelectedItem is not ComboBoxItem item ||
            !ulong.TryParse(item.Tag?.ToString(), out var megabytes)) return;
        _ = SaveSettingsAsync(settings => settings["bandwidth_limit_bytes_per_second"] = megabytes * 1_000_000);
    }

    private async Task CreateQueueAsync()
    {
        if (_settings?["queues"] is not JsonArray queues) return;
        var number = 1;
        while (queues.OfType<JsonObject>().Any(queue => string.Equals(queue["name"]?.GetValue<string>(), $"queue #{number}", StringComparison.OrdinalIgnoreCase))) number++;
        var name = $"queue #{number}";
        var id = "queue-" + Guid.NewGuid().ToString("N");
        await SaveSettingsAsync(settings =>
        {
            (settings["queues"] as JsonArray)?.Add(new JsonObject
            {
                ["id"] = id, ["name"] = name, ["max_active"] = 4,
                ["schedule_enabled"] = false,
                ["schedule_slots"] = new JsonArray(Enumerable.Repeat(true, 168).Select(value => (JsonNode?)JsonValue.Create(value)).ToArray()),
                ["finish_action"] = "none",
            });
        });
        UpdateQueues();
    }

    private async void OnAddDownload(object sender, RoutedEventArgs e)
    {
        var destination = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var url = new TextBox { Header = "URL", PlaceholderText = "https://example.com/file.zip" };
        var name = new TextBox { Header = "File name" };
        var probeSummary = new TextBlock { Text = "Paste a link to inspect it.", TextWrapping = TextWrapping.Wrap, Opacity = 0.7 };
        var configuredFolder = ReadString("default_download_folder");
        var folder = new TextBox { Header = "Destination folder", Text = string.IsNullOrWhiteSpace(configuredFolder) ? Path.Combine(destination, "Downloads") : configuredFolder };
        var priority = new ComboBox { Header = "Queue priority", SelectedIndex = 1 };
        priority.Items.Add(new ComboBoxItem { Content = "Low" });
        priority.Items.Add(new ComboBoxItem { Content = "Normal" });
        priority.Items.Add(new ComboBoxItem { Content = "High" });
        var queueChoice = new ComboBox { Header = "Queue", MinWidth = 200 };
        if (_settings?["queues"] is JsonArray queues)
            foreach (var queue in queues.OfType<JsonObject>())
                queueChoice.Items.Add(new ComboBoxItem { Content = queue["name"]?.GetValue<string>() ?? "main", Tag = queue["id"]?.GetValue<string>() ?? "main" });
        queueChoice.SelectedItem = queueChoice.Items.OfType<ComboBoxItem>().FirstOrDefault(item => item.Tag?.ToString() == _lastQueueId);
        if (queueChoice.SelectedItem is null) queueChoice.SelectedIndex = 0;
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(url);
        panel.Children.Add(probeSummary);
        panel.Children.Add(name);
        panel.Children.Add(folder);
        panel.Children.Add(queueChoice);
        panel.Children.Add(priority);
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Add Download",
            Content = panel,
            PrimaryButtonText = "Add to Queue",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        CancellationTokenSource? probeCancellation = null;
        url.TextChanged += async (_, _) =>
        {
            probeCancellation?.Cancel();
            probeCancellation?.Dispose();
            probeCancellation = new CancellationTokenSource();
            var token = probeCancellation.Token;
            var text = url.Text.Trim();
            if (!Uri.TryCreate(text, UriKind.Absolute, out var source) || source.Scheme is not ("http" or "https"))
            {
                probeSummary.Text = "Enter an HTTP or HTTPS link.";
                return;
            }
            probeSummary.Text = "Inspecting link…";
            try
            {
                await Task.Delay(400, token);
                var result = await _engine.ProbeAsync(text, token);
                if (token.IsCancellationRequested || url.Text.Trim() != text) return;
                var suggestedName = result["suggested_name"]?.GetValue<string>() ?? "";
                if (string.IsNullOrWhiteSpace(name.Text)) name.Text = suggestedName;
                var final = result["final_url"]?.GetValue<string>() ?? text;
                var total = result["total_bytes"]?.GetValue<string>();
                var size = ulong.TryParse(total, out var bytes) ? $"{bytes / 1_000_000d:0.#} MB" : "Size unknown";
                var resume = result["resume_supported"]?.GetValue<bool>() == true ? "Resume available" : "Resume unavailable";
                var parallel = result["multipart_supported"]?.GetValue<bool>() == true ? "Parallel download available" : "Single connection";
                probeSummary.Text = $"{size} · {resume} · {parallel}" + (final == text ? "" : $"\nRedirects to {final}");
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { if (!token.IsCancellationRequested) probeSummary.Text = $"Could not inspect link: {error.Message}"; }
        };
        var choice = await dialog.ShowAsync();
        probeCancellation?.Cancel();
        probeCancellation?.Dispose();
        if (choice != ContentDialogResult.Primary) return;

        if (!Uri.TryCreate(url.Text.Trim(), UriKind.Absolute, out var parsed) ||
            parsed.Scheme is not ("http" or "https") || string.IsNullOrWhiteSpace(parsed.Host) ||
            !Path.IsPathFullyQualified(folder.Text) || !Directory.Exists(folder.Text))
        {
            ShowMessage("Enter a valid HTTP(S) URL and an existing destination folder.", InfoBarSeverity.Warning);
            return;
        }
        var selectedPriority = priority.SelectedIndex switch { 0 => -1, 2 => 1, _ => 0 };
        try
        {
            _lastQueueId = (queueChoice.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "main";
            await _engine.AddJobAsync(url.Text.Trim(), name.Text.Trim(), folder.Text.Trim(), selectedPriority, _lastQueueId);
            await RefreshAsync();
        }
        catch (Exception error)
        {
            ShowMessage(error.Message, InfoBarSeverity.Error);
        }
    }

    private void ShowMessage(string message, InfoBarSeverity severity)
    {
        MessageBar.Message = message;
        MessageBar.Severity = severity;
        MessageBar.IsOpen = true;
    }
}
