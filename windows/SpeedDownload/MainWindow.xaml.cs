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
    private bool _manualReconnectRequired;
    private bool _connected;
    private readonly Dictionary<string, ulong> _rateSamples = [];
    private DateTimeOffset _lastRateSample;
    private double _aggregateRate;
    private IReadOnlyList<DownloadJob> _allJobs = [];
    private readonly ObservableCollection<DownloadJob> _visibleJobs = [];
    private readonly ObservableCollection<DownloadWorker> _workerRows = [];
    private string? _workersJobId;
    private string _category = "All downloads";
    private JsonObject? _settings;
    private readonly SemaphoreSlim _settingsGate = new(1, 1);
    private bool _loadingSettings;
    private readonly System.Globalization.CultureInfo _systemCulture = System.Globalization.CultureInfo.CurrentCulture;
    private readonly System.Globalization.CultureInfo _systemUiCulture = System.Globalization.CultureInfo.CurrentUICulture;
    private bool _persian;
    private DateTimeOffset _lastBackgroundSettingsCheck;
    private bool _loadingClientSettings = true;
    private ClientPreferences _clientPreferences = new();
    private bool _showNarrowDetails;
    private bool _loadingSpeedLimit;
    private string _lastQueueId = "main";
    private readonly NotifyIcon _trayIcon;
    private readonly System.Windows.Forms.ToolStripItem _trayPause;
    private readonly System.Windows.Forms.ToolStripItem _trayResume;
    private readonly System.Windows.Forms.ToolStripItem _trayStopEngine;
    private readonly TaskbarProgress _taskbarProgress;
    private readonly DownloadNotifications _notifications;
    private readonly Dictionary<string, string> _notificationStates = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string?> _notificationQueueOutcomes = new(StringComparer.Ordinal);
    private bool _notificationBaseline;
    private string? _notificationJobId;
    private bool _quitting;
    private bool _closePromptOpen;
    private bool _backgroundNoticeShown;
    private readonly Queue<(string Url, string? Reference)> _torrentActivations = new();
    private readonly Queue<BrowserRequest> _browserActivations = new();
    private readonly Dictionary<string, string> _browserKeys = new(StringComparer.OrdinalIgnoreCase);
    private sealed record BrowserRequest(string Action, string[] Urls, string? Reference, string Key);
    private bool _activationDialogOpen;
    private bool _batchInFlight;
    private bool _forceResort;
    private bool _compactSize;
    private bool _compactSpeed;
    private bool _compactEta;

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
        LoadAppearance();
        LoadClientPreferences();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(920, 620));
        _taskbarProgress = new TaskbarProgress(WinRT.Interop.WindowNative.GetWindowHandle(this));
        _notifications = new DownloadNotifications(id => DispatcherQueue.TryEnqueue(() => OpenNotificationJob(id)));
        NotificationStatus.Text = _notifications.Status;
        App.TracePhase0Startup("Main window XAML initialized");
        JobsList.ItemsSource = _visibleJobs;
        WorkerList.ItemsSource = _workerRows;
        var trayMenu = new ContextMenuStrip();
        trayMenu.Items.Add("Open Speed Download", null, (_, _) => DispatcherQueue.TryEnqueue(ShowMainWindow));
        _trayPause = trayMenu.Items.Add("Pause all active and queued downloads", null,
            (_, _) => DispatcherQueue.TryEnqueue(() => _ = ControlTrayDownloadsAsync(true)));
        _trayResume = trayMenu.Items.Add("Resume all paused downloads", null,
            (_, _) => DispatcherQueue.TryEnqueue(() => _ = ControlTrayDownloadsAsync(false)));
        _trayPause.Enabled = false;
        _trayResume.Enabled = false;
        trayMenu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        trayMenu.Items.Add("Quit Speed Download (downloads continue)", null, (_, _) =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                _quitting = true;
                _trayIcon.Visible = false;
                Close();
            });
        });
        _trayStopEngine = trayMenu.Items.Add("Quit and stop engine…", null,
            (_, _) => DispatcherQueue.TryEnqueue(() => _ = QuitAndStopEngineAsync()));
        _trayStopEngine.Enabled = false;
        _trayIcon = new NotifyIcon
        {
            Icon = new Icon(Path.Combine(AppContext.BaseDirectory, "SpeedDownload.ico")),
            Text = "Speed Download",
            ContextMenuStrip = trayMenu,
            Visible = true,
        };
        App.TracePhase0Startup("Tray icon initialized");
        _trayIcon.DoubleClick += (_, _) => ShowMainWindow();
        AppWindow.Closing += OnWindowClosing;
        Closed += (_, _) => { _notifications.Dispose(); _taskbarProgress.Dispose(); _trayIcon.Dispose(); };
        _refreshTimer = DispatcherQueue.CreateTimer();
        _refreshTimer.Interval = TimeSpan.FromSeconds(2);
        _refreshTimer.Tick += async (_, _) => await RefreshAsync();
        _refreshTimer.Start();
        _ = RefreshAsync();
    }


    internal void ShowMainWindow()
    {
        AppWindow.Show();
        Activate();
    }

    internal void QuitAfterQueueCompletion()
    {
        if (_quitting) return;
        _quitting = true;
        _refreshTimer.Stop();
        _trayIcon.Visible = false;
        Close();
    }

    private async void OnWindowClosing(Microsoft.UI.Windowing.AppWindow sender, Microsoft.UI.Windowing.AppWindowClosingEventArgs args)
    {
        if (_quitting) return;
        args.Cancel = true;
        if (_closePromptOpen) return;
        if (_clientPreferences.CloseAction == "stop")
        {
            if (!_engine.SupportsFeature("engine.shutdown-v1") || !_connected)
            {
                ShowMessage("Connect to a compatible engine before stopping it, or choose another close behavior in Settings.", InfoBarSeverity.Warning);
                return;
            }
            await QuitAndStopEngineAsync();
            return;
        }
        if (!_backgroundNoticeShown && _allJobs.Any(job => job.State is "resolving" or "connecting" or "downloading" or "verifying"))
        {
            _closePromptOpen = true;
            try
            {
                var dialog = new ContentDialog
                {
                    XamlRoot = Content.XamlRoot,
                    Title = "Downloads will continue in the background",
                    Content = "Reopen Speed Download from the notification area or Start. The engine continues running when the window is closed.",
                    PrimaryButtonText = "Continue in background",
                    CloseButtonText = "Cancel",
                    DefaultButton = ContentDialogButton.Close,
                };
                if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
                _backgroundNoticeShown = true;
            }
            finally { _closePromptOpen = false; }
        }
        if (_clientPreferences.CloseAction == "exit")
        {
            _quitting = true;
            _trayIcon.Visible = false;
            DispatcherQueue.TryEnqueue(() => Close());
        }
        else AppWindow.Hide();
    }

    internal bool StartMinimizedAtLogin => _clientPreferences.StartMinimized;

    internal void HandleNotificationActivation(Microsoft.Windows.AppNotifications.AppNotificationActivatedEventArgs args)
        => _notifications.HandleActivation(args);

    private void LoadClientPreferences()
    {
        try
        {
            _clientPreferences = ClientPreferences.Load();
            _lastQueueId = _clientPreferences.LastQueueId;
            StartMinimizedSwitch.IsOn = _clientPreferences.StartMinimized;
            NotifyCompletedSwitch.IsOn = _clientPreferences.NotifyCompleted;
            NotifyFailedSwitch.IsOn = _clientPreferences.NotifyFailed;
            SelectChoice(CloseActionBox, _clientPreferences.CloseAction);
            LaunchOnLoginSwitch.IsOn = ClientPreferences.LaunchOnLoginEnabled();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Text.Json.JsonException or System.Security.SecurityException)
        {
            StartMinimizedSwitch.IsOn = _clientPreferences.StartMinimized;
            NotifyCompletedSwitch.IsOn = _clientPreferences.NotifyCompleted;
            NotifyFailedSwitch.IsOn = _clientPreferences.NotifyFailed;
            SelectChoice(CloseActionBox, _clientPreferences.CloseAction);
            SettingsMessage.Severity = InfoBarSeverity.Error;
            SettingsMessage.Message = "Could not load client preferences: " + error.Message;
            SettingsMessage.IsOpen = true;
        }
        finally { _loadingClientSettings = false; }
    }

    private void OnLoginSettingChanged(object sender, RoutedEventArgs e)
    {
        if (_loadingClientSettings) return;
        var enabled = LaunchOnLoginSwitch.IsOn;
        try { ClientPreferences.SetLaunchOnLogin(enabled); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException or InvalidOperationException)
        {
            _loadingClientSettings = true;
            try { LaunchOnLoginSwitch.IsOn = !enabled; }
            finally { _loadingClientSettings = false; }
            SettingsMessage.Severity = InfoBarSeverity.Error;
            SettingsMessage.Message = "Could not update sign-in launch: " + error.Message;
            SettingsMessage.IsOpen = true;
        }
    }

    private void OnClientChoiceChanged(object sender, SelectionChangedEventArgs e) => OnClientSettingChanged(sender, e);

    private void OnClientSettingChanged(object sender, RoutedEventArgs e)
    {
        if (_loadingClientSettings || CloseActionBox.SelectedItem is not ComboBoxItem item) return;
        var previous = _clientPreferences;
        var changed = new ClientPreferences { StartMinimized = StartMinimizedSwitch.IsOn, CloseAction = item.Tag?.ToString() ?? "hide", LastQueueId = _lastQueueId,
            NotifyCompleted = NotifyCompletedSwitch.IsOn, NotifyFailed = NotifyFailedSwitch.IsOn };
        try { changed.Save(); _clientPreferences = changed; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            _loadingClientSettings = true;
            try { StartMinimizedSwitch.IsOn = previous.StartMinimized; NotifyCompletedSwitch.IsOn = previous.NotifyCompleted; NotifyFailedSwitch.IsOn = previous.NotifyFailed; SelectChoice(CloseActionBox, previous.CloseAction); }
            finally { _loadingClientSettings = false; }
            SettingsMessage.Severity = InfoBarSeverity.Error;
            SettingsMessage.Message = "Could not save client preferences: " + error.Message;
            SettingsMessage.IsOpen = true;
        }
    }

    private void RememberQueue(string queueId)
    {
        _lastQueueId = queueId;
        _clientPreferences.LastQueueId = queueId;
        try { _clientPreferences.Save(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            ShowMessage("The download was added, but the last queue choice could not be saved.", InfoBarSeverity.Warning);
        }
    }

    internal void EnqueueTorrentActivation(string source)
    {
        if (source.Length is 0 or > 8192 || source.Contains('\n') || source.Contains('\r')) return;
        if (!source.StartsWith("magnet:", StringComparison.OrdinalIgnoreCase) &&
            !(Uri.TryCreate(source, UriKind.Absolute, out var uri) && (uri.Scheme is "torrent-file" or "http" or "https") &&
              uri.AbsolutePath.EndsWith(".torrent", StringComparison.OrdinalIgnoreCase))) return;
        ShowMainWindow();
        _torrentActivations.Enqueue((source, null));
        _ = ProcessTorrentActivationsAsync();
    }

    private static bool SafeBrowserUrl(string? value, bool allowMagnet = true)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 8192 || value.Any(char.IsControl)) return false;
        if (allowMagnet && value.StartsWith("magnet:?", StringComparison.OrdinalIgnoreCase)) return value.Contains("xt=", StringComparison.OrdinalIgnoreCase);
        return Uri.TryCreate(value, UriKind.Absolute, out var url) && (url.Scheme is "http" or "https") &&
            !string.IsNullOrWhiteSpace(url.Host) && string.IsNullOrEmpty(url.UserInfo) && string.IsNullOrEmpty(url.Fragment);
    }

    private static bool SafeReviewLink(string value)
    {
        if (SafeBrowserUrl(value)) return true;
        return value.Length <= 8192 && !value.Any(char.IsControl) &&
            Uri.TryCreate(value, UriKind.Absolute, out var uri) && (uri.Scheme is "ftp" or "ftps") &&
            !string.IsNullOrWhiteSpace(uri.Host) && string.IsNullOrEmpty(uri.UserInfo) && string.IsNullOrEmpty(uri.Fragment);
    }

    private void QueueReviewLinks(string text)
    {
        if (text.Length > 256 * 1024)
        {
            ShowMessage("The link list is too large to review.", InfoBarSeverity.Warning);
            return;
        }
        var links = text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (links.Length is < 1 or > 100 || links.Any(link => !SafeReviewLink(link)))
        {
            ShowMessage("Use up to 100 HTTP, HTTPS, FTP, FTPS, or magnet links, one per line, without embedded credentials.", InfoBarSeverity.Warning);
            return;
        }
        var key = Guid.NewGuid().ToString();
        var isTorrent = links[0].StartsWith("magnet:", StringComparison.OrdinalIgnoreCase) ||
            (Uri.TryCreate(links[0], UriKind.Absolute, out var uri) && uri.AbsolutePath.EndsWith(".torrent", StringComparison.OrdinalIgnoreCase));
        var action = links.Length > 1 ? "batch" : isTorrent ? "torrent" : "add";
        _browserActivations.Enqueue(new BrowserRequest(action, links, null, key));
        if (!_connected) ShowMessage("The link is waiting for the engine to reconnect before review.", InfoBarSeverity.Informational);
        _ = ProcessTorrentActivationsAsync();
    }

    private async Task PasteDownloadAsync()
    {
        try
        {
            var data = Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
            if (data.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.WebLink))
                QueueReviewLinks((await data.GetWebLinkAsync()).AbsoluteUri);
            else if (data.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text))
                QueueReviewLinks(await data.GetTextAsync());
            else ShowMessage("The clipboard does not contain a download link.", InfoBarSeverity.Informational);
        }
        catch (Exception error) when (error is InvalidOperationException or System.Runtime.InteropServices.COMException or UnauthorizedAccessException)
        { ShowMessage("Could not read a link from the clipboard.", InfoBarSeverity.Warning); }
    }

    private async void OnPasteDownload(object sender, RoutedEventArgs e) => await PasteDownloadAsync();

    private async void OnPasteDownloadShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (Content.XamlRoot is null) return;
        var focused = FocusManager.GetFocusedElement(Content.XamlRoot) as DependencyObject;
        for (var node = focused; node is not null; node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node))
            if (node is TextBox or PasswordBox or RichEditBox or ComboBox) return;
        args.Handled = true;
        await PasteDownloadAsync();
    }

    private void OnDownloadDragOver(object sender, Microsoft.UI.Xaml.DragEventArgs e)
    {
        var formats = Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text;
        var storage = Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems;
        var link = Windows.ApplicationModel.DataTransfer.StandardDataFormats.WebLink;
        e.AcceptedOperation = e.DataView.Contains(formats) || e.DataView.Contains(storage) || e.DataView.Contains(link)
            ? Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy
            : Windows.ApplicationModel.DataTransfer.DataPackageOperation.None;
        e.Handled = true;
    }

    private async void OnDownloadDrop(object sender, Microsoft.UI.Xaml.DragEventArgs e)
    {
        var deferral = e.GetDeferral();
        try
        {
            if (e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems))
            {
                var files = await e.DataView.GetStorageItemsAsync();
                if (files.Count != 1 || files[0] is not Windows.Storage.StorageFile file ||
                    !file.Name.EndsWith(".torrent", StringComparison.OrdinalIgnoreCase) || !Path.IsPathFullyQualified(file.Path))
                {
                    ShowMessage("Drop one local .torrent file to review it.", InfoBarSeverity.Warning);
                    return;
                }
                EnqueueTorrentActivation(new Uri(file.Path).AbsoluteUri.Replace("file:", "torrent-file:", StringComparison.OrdinalIgnoreCase));
                return;
            }
            string text;
            if (e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.WebLink))
                text = (await e.DataView.GetWebLinkAsync()).AbsoluteUri;
            else if (e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text))
                text = await e.DataView.GetTextAsync();
            else return;
            QueueReviewLinks(text);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or System.Runtime.InteropServices.COMException)
        {
            ShowMessage("Could not read the dropped item. Try adding it again.", InfoBarSeverity.Warning);
        }
        finally { deferral.Complete(); }
    }

    internal bool EnqueueBrowserActivation(string json)
    {
        try
        {
            if (json.Length > 256 * 1024) return false;
            var request = JsonNode.Parse(json)?.AsObject();
            if (request?["version"]?.GetValue<int>() != 1) return false;
            var action = request["action"]?.GetValue<string>();
            var key = request["idempotency_key"]?.GetValue<string>();
            if (action is not ("add" or "torrent" or "batch") || !Guid.TryParseExact(key, "D", out _)) return false;
            var reference = request["reference_url"]?.GetValue<string>();
            if (reference is not null && !SafeBrowserUrl(reference, false)) return false;
            string[] urls;
            if (action == "batch")
            {
                if (request["urls"] is not JsonArray array || array.Count is < 1 or > 100) return false;
                urls = array.Select(item => item?.GetValue<string>() ?? "").ToArray();
            }
            else urls = [request["url"]?.GetValue<string>() ?? ""];
            if (urls.Any(url => !SafeBrowserUrl(url))) return false;
            var canonical = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new { action, urls, reference });
            var fingerprint = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(canonical));
            if (_browserKeys.TryGetValue(key!, out var previous)) return previous == fingerprint;
            _browserKeys.Add(key!, fingerprint);
            _browserActivations.Enqueue(new BrowserRequest(action!, urls, reference, key!));
            TraceBrowserReview("accepted", key!, action!);
            ShowMainWindow();
            _ = ProcessTorrentActivationsAsync();
            return true;
        }
        catch (Exception error) when (error is System.Text.Json.JsonException or InvalidOperationException or FormatException) { return false; }
    }

    private static void TraceBrowserReview(string phase, string key, string action)
    {
        var path = Environment.GetEnvironmentVariable("SPEED_DOWNLOAD_PHASE0_BROWSER_REPORT");
        if (string.IsNullOrEmpty(path) || !Path.IsPathFullyQualified(path) || !Guid.TryParseExact(key, "D", out _)) return;
        try { File.AppendAllText(path, $"{phase}\t{key}\t{action}\n"); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    private async Task ProcessTorrentActivationsAsync()
    {
        if (!_connected || _activationDialogOpen || (_torrentActivations.Count == 0 && _browserActivations.Count == 0)) return;
        _activationDialogOpen = true;
        var browser = _browserActivations.Count > 0 ? _browserActivations.Dequeue() : null;
        (string Url, string? Reference)? torrent = browser is null ? _torrentActivations.Dequeue() : null;
        try
        {
            if (browser is null) await ShowAddTorrentAsync(torrent!.Value.Url, torrent.Value.Reference);
            else if (browser.Action == "batch") await ShowBrowserBatchAsync(browser);
            else if (browser.Action == "torrent") await ShowAddTorrentAsync(browser.Urls[0], browser.Reference);
            else await ShowAddDownloadAsync(browser.Urls[0], browser.Reference, browser.Key);
        }
        catch (Exception error)
        {
            if (browser is not null) _browserActivations.Enqueue(browser); else _torrentActivations.Enqueue(torrent!.Value);
            ShowMessage("Review is waiting for the current dialog to close: " + error.Message, InfoBarSeverity.Warning);
            return;
        }
        finally { _activationDialogOpen = false; }
        if (_torrentActivations.Count > 0 || _browserActivations.Count > 0) _ = ProcessTorrentActivationsAsync();
    }

    private static string AppearancePath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SpeedDownload", "appearance.txt");

    private void LoadAppearance()
    {
        var value = "Default";
        try { if (File.Exists(AppearancePath)) value = File.ReadAllText(AppearancePath).Trim(); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        if (value is not ("Default" or "Light" or "Dark")) value = "Default";
        SelectChoice(AppearanceBox, value);
        if (Content is FrameworkElement root) root.RequestedTheme = Enum.Parse<ElementTheme>(value);
    }

    private void OnAppearanceChanged(object sender, SelectionChangedEventArgs e)
    {
        if (AppearanceBox?.SelectedItem is not ComboBoxItem item || item.Tag is not string value ||
            !Enum.TryParse<ElementTheme>(value, out var theme)) return;
        if (Content is FrameworkElement root) root.RequestedTheme = theme;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(AppearancePath)!);
            File.WriteAllText(AppearancePath, value);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            if (SettingsMessage is not null) { SettingsMessage.Message = "Could not save appearance: " + error.Message; SettingsMessage.IsOpen = true; }
        }
    }

    private async Task RefreshAsync()
    {
        if (_refreshInFlight) return;
        _refreshInFlight = true;
        try
        {
            var jobs = await _engine.ListJobsAsync();
            var now = DateTimeOffset.UtcNow;
            var elapsed = (now - _lastRateSample).TotalSeconds;
            double aggregate = 0;
            foreach (var job in jobs)
                if (job.State == "downloading" && elapsed > 0 && _lastRateSample != default &&
                    _rateSamples.TryGetValue(job.JobId, out var previous) && job.Received >= previous)
                    aggregate += (job.Received - previous) / elapsed;
            _rateSamples.Clear();
            foreach (var job in jobs.Where(job => job.State == "downloading")) _rateSamples[job.JobId] = job.Received;
            _lastRateSample = now;
            _aggregateRate = aggregate;
            RecordNotificationTransitions(jobs);
            _allJobs = jobs;
            try
            {
                var (limit, scheduled) = await _engine.GetEffectiveBandwidthAsync();
                EffectiveLimit.Text = limit is null ? "Effective cap unavailable" :
                    (limit == 0 ? "Effective: Unlimited" : $"Effective: {limit.Value / 1_000_000d:0.##} MB/s") + (scheduled == true ? " (scheduled)" : "");
            }
            catch (Exception error) when (error is IOException or InvalidOperationException or System.Text.Json.JsonException)
            { EffectiveLimit.Text = "Effective cap unavailable"; }
            if (_settings is null || !_connected)
            {
                await LoadSettingsAsync();
                _lastBackgroundSettingsCheck = now;
            }
            else if (Workspace.Visibility == Visibility.Visible && !_activationDialogOpen && !_loadingSettings &&
                now - _lastBackgroundSettingsCheck >= TimeSpan.FromSeconds(15) && await _settingsGate.WaitAsync(0))
            {
                _lastBackgroundSettingsCheck = now;
                try
                {
                    var snapshot = await _engine.GetSettingsAsync();
                    if (!JsonNode.DeepEquals(_settings, snapshot)) await LoadSettingsAsync(snapshot);
                }
                catch (Exception error) when (error is IOException or InvalidOperationException or System.Text.Json.JsonException)
                { /* Keep the last settings until the next successful refresh. */ }
                finally { _settingsGate.Release(); }
            }
            _connected = true;
            _taskbarProgress.Update(jobs);
            UpdateTrayCommands();
            _ = ProcessTorrentActivationsAsync();
            UpdateNavigationCounts();
            ApplyFilter();
            if (_notificationJobId is not null) SelectNotificationJob();
            UpdateSummary();
            DownloadCommands.IsEnabled = true;
            SpeedLimitBox.IsEnabled = true;
            ConnectionBar.IsOpen = false;
            ConnectionStatus.Text = "Engine connected";
            EngineIndicator.Fill = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.ForestGreen);
            ReportPhase0UiState();
        }
        catch (Exception error)
        {
            _connected = false;
            _taskbarProgress.Update([]);
            _trayPause.Enabled = false;
            _trayResume.Enabled = false;
            _trayStopEngine.Enabled = false;
            foreach (var job in _visibleJobs) job.MarkDisconnected();
            foreach (var worker in _workerRows) worker.MarkDisconnected();
            UpdateSelectionDetails();
            _rateSamples.Clear();
            _lastRateSample = default;
            DownloadCommands.IsEnabled = false;
            SpeedLimitBox.IsEnabled = false;
            ConnectionBar.IsOpen = true;
            AggregateSpeed.Text = "Rate unavailable";
            EffectiveLimit.Text = "Effective cap unavailable";
            ConnectionStatus.Text = "Engine disconnected · data may be out of date";
            EngineIndicator.Fill = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.DarkOrange);
            ShowMessage(error.Message, InfoBarSeverity.Error);
            ReportPhase0UiState();
        }
        finally
        {
            _refreshInFlight = false;
        }
    }

    private async void OnRefresh(object sender, RoutedEventArgs e)
    {
        await RefreshAsync();
        if (_manualReconnectRequired && _connected)
        {
            _manualReconnectRequired = false;
            _refreshTimer.Start();
        }
    }

    private void ReportPhase0UiState()
    {
        var path = Environment.GetEnvironmentVariable("SPEED_DOWNLOAD_PHASE0_REPORT");
        if (string.IsNullOrEmpty(path) || !Path.IsPathFullyQualified(path)) return;
        try
        {
            var rows = _allJobs.Select(job => $"{job.JobId}\t{job.State}\t{(job.State == "downloading" ? job.Received : job.Completed)}");
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
            NotificationStatus.Text = _notifications.Status;
            _ = LoadSettingsAsync();
            return;
        }
        if (args.InvokedItemContainer is NavigationViewItem item && item.Tag is string tag)
        {
            if (tag == "new-queue") { _ = CreateQueueAsync(); return; }
            _category = tag;
            StartAllButton.Label = tag.StartsWith("queue:", StringComparison.Ordinal) ? "Resume this queue" : "Resume paused downloads";
            PauseAllButton.Label = tag.StartsWith("queue:", StringComparison.Ordinal) ? "Pause this queue" : "Pause all downloads";
            SectionTitle.Text = tag.StartsWith("queue:", StringComparison.Ordinal) ? item.Content?.ToString() ?? "Queue" : CategoryLabel(tag);
            SettingsView.Visibility = Visibility.Collapsed;
            Workspace.Visibility = Visibility.Visible;
            ApplyFilter();
        }
    }

    private void OnSettingsSectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SettingsSectionBox?.SelectedItem is not ComboBoxItem item || SettingsContent is null || SettingsView is null) return;
        FrameworkElement? heading = item.Tag?.ToString() switch
        {
            "appearance" => AppearanceHeading, "general" => GeneralHeading, "notifications" => NotificationsHeading,
            "downloads" => DownloadsHeading, "network" => NetworkHeading, "bandwidth" => BandwidthHeading,
            "integration" => IntegrationHeading, _ => null,
        };
        if (heading is null || SettingsView.Visibility != Visibility.Visible) return;
        var position = heading.TransformToVisual(SettingsContent).TransformPoint(new Windows.Foundation.Point(0, 0));
        SettingsView.ChangeView(null, Math.Clamp(position.Y, 0, SettingsView.ScrollableHeight), null);
    }

    private void OnSearchTextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (JobsList is not null && DetailTitle is not null) ApplyFilter();
    }

    private void OnSortChanged(object sender, SelectionChangedEventArgs e)
    {
        if (JobsList is null || DetailTitle is null) return;
        var selected = (SortBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "order";
        foreach (var column in JobsList.Columns)
        {
            var prefix = column.Tag?.ToString();
            column.SortDirection = !string.IsNullOrEmpty(prefix) && selected == prefix + "-asc" ? WinUI.TableView.SortDirection.Ascending :
                !string.IsNullOrEmpty(prefix) && selected == prefix + "-desc" ? WinUI.TableView.SortDirection.Descending : null;
        }
        _forceResort = true;
        try { ApplyFilter(); }
        finally { _forceResort = false; }
    }

    private void OnTableSorting(object? sender, WinUI.TableView.TableViewSortingEventArgs e)
    {
        e.Handled = true;
        if (e.Column.Tag is not string column) return;
        var current = (SortBox.SelectedItem as ComboBoxItem)?.Tag?.ToString();
        SelectChoice(SortBox, column + (current == column + "-asc" ? "-desc" : "-asc"));
    }

    private void OnSelectedDetails(object sender, RoutedEventArgs e)
    {
        if (JobsList.SelectedItem is not DownloadJob) return;
        _showNarrowDetails = true;
        UpdateResponsiveLayout();
        CloseDetailsButton.Focus(FocusState.Programmatic);
    }

    private void ApplyFilter()
    {
        IEnumerable<DownloadJob> jobs = _category switch
        {
            "In progress" => _allJobs.Where(job => job.State is not ("completed" or "failed" or "canceled")),
            "Completed" => _allJobs.Where(job => job.State == "completed"),
            "Failed" => _allJobs.Where(job => job.State == "failed"),
            var queue when queue.StartsWith("queue:", StringComparison.Ordinal) => _allJobs.Where(job => job.QueueId == queue[6..]),
            _ => _allJobs,
        };
        var query = SearchBox?.Text?.Trim();
        if (!string.IsNullOrEmpty(query)) jobs = jobs.Where(job => job.Title.Contains(query, StringComparison.OrdinalIgnoreCase) || job.Url.Contains(query, StringComparison.OrdinalIgnoreCase));
        var selectedIds = JobsList.SelectedItems.OfType<DownloadJob>().Select(job => job.JobId).ToHashSet(StringComparer.Ordinal);
        var sort = (SortBox?.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "order";
        var liveRows = _visibleJobs.ToDictionary(job => job.JobId, StringComparer.Ordinal);
        if (!_forceResort && selectedIds.Count > 0 && (sort.StartsWith("speed-", StringComparison.Ordinal) || sort.StartsWith("eta-", StringComparison.Ordinal)))
        {
            // Do not move a selected row on every live progress update.
            var positions = _visibleJobs.Select((job, index) => (job.JobId, index)).ToDictionary(item => item.JobId, item => item.index, StringComparer.Ordinal);
            jobs = jobs.OrderBy(job => positions.TryGetValue(job.JobId, out var position) ? position : int.MaxValue);
        }
        else
        {
            double? Rate(DownloadJob job) => liveRows.TryGetValue(job.JobId, out var row) && row.BytesPerSecond > 0 ? row.BytesPerSecond : null;
            double? Eta(DownloadJob job) => liveRows.TryGetValue(job.JobId, out var row) ? row.EtaSeconds : null;
            jobs = sort switch
            {
                "name-asc" => jobs.OrderBy(job => job.Title, StringComparer.CurrentCultureIgnoreCase),
                "name-desc" => jobs.OrderByDescending(job => job.Title, StringComparer.CurrentCultureIgnoreCase),
                "state-asc" => jobs.OrderBy(job => job.StateText, StringComparer.CurrentCultureIgnoreCase),
                "state-desc" => jobs.OrderByDescending(job => job.StateText, StringComparer.CurrentCultureIgnoreCase),
                "size-asc" => jobs.OrderBy(job => job.Total == 0).ThenBy(job => job.Total),
                "size-desc" => jobs.OrderBy(job => job.Total == 0).ThenByDescending(job => job.Total),
                "speed-asc" => jobs.OrderBy(job => Rate(job) is null).ThenBy(Rate),
                "speed-desc" => jobs.OrderBy(job => Rate(job) is null).ThenByDescending(Rate),
                "eta-asc" => jobs.OrderBy(job => Eta(job) is null).ThenBy(Eta),
                "eta-desc" => jobs.OrderBy(job => Eta(job) is null).ThenByDescending(Eta),
                _ => jobs,
            };
        }
        var filtered = jobs.ToList();
        for (var index = 0; index < filtered.Count; index++)
        {
            var incoming = filtered[index];
            incoming.SetCompactMetrics(_compactSize, _compactSpeed, _compactEta);
            var existingIndex = -1;
            for (var scan = index; scan < _visibleJobs.Count; scan++)
                if (_visibleJobs[scan].JobId == incoming.JobId) { existingIndex = scan; break; }
            if (existingIndex < 0)
            {
                _ = incoming.LoadFileIconAsync();
                _visibleJobs.Insert(index, incoming);
            }
            else
            {
                if (existingIndex != index) _visibleJobs.Move(existingIndex, index);
                _visibleJobs[index].UpdateFrom(incoming);
                _visibleJobs[index].SetCompactMetrics(_compactSize, _compactSpeed, _compactEta);
            }
        }
        while (_visibleJobs.Count > filtered.Count) _visibleJobs.RemoveAt(_visibleJobs.Count - 1);
        foreach (var selected in _visibleJobs.Where(job => selectedIds.Contains(job.JobId)))
            if (!JobsList.SelectedItems.Contains(selected)) JobsList.SelectedItems.Add(selected);
        if (EmptyState is not null)
        {
            EmptyState.Visibility = filtered.Count == 0 && !_showNarrowDetails ? Visibility.Visible : Visibility.Collapsed;
            EmptyStateText.Text = !string.IsNullOrEmpty(query) ? "No matching downloads" : _allJobs.Count == 0 ? "No downloads yet" : "No downloads in this view";
            EmptyStateAction.Content = !string.IsNullOrEmpty(query) ? "Clear search" : "Add download";
            EmptyStateAction.Visibility = !string.IsNullOrEmpty(query) || (_allJobs.Count == 0 && _connected) ? Visibility.Visible : Visibility.Collapsed;
        }
        UpdateSelectionDetails();
    }

    private void OnEmptyStateAction(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrWhiteSpace(SearchBox.Text)) { SearchBox.Text = ""; SearchBox.Focus(FocusState.Programmatic); }
        else if (_connected) _ = ShowAddDownloadAsync(null, null, null);
    }

    private void OnJobsKeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.A && Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down))
        {
            JobsList.SelectAll();
            e.Handled = true;
            return;
        }
        if (JobsList.SelectedItem is not DownloadJob job) return;
        if (e.Key == Windows.System.VirtualKey.F10 && Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down))
        {
            ShowJobMenu(JobsList.ContainerFromItem(job) as FrameworkElement ?? JobsList, job.JobId);
            e.Handled = true;
            return;
        }
        if (e.Key == Windows.System.VirtualKey.Enter)
        {
            _showNarrowDetails = true;
            UpdateResponsiveLayout();
            CloseDetailsButton.Focus(FocusState.Programmatic);
            e.Handled = true;
        }
    }

    private void OnJobSelectionChanged(object sender, SelectionChangedEventArgs e) => UpdateSelectionDetails();

    private void UpdateSelectionDetails()
    {
        if (JobsList is null || DetailTitle is null || SelectionSummary is null || ResumeSelectedButton is null || PauseSelectedButton is null || RemoveSelectedButton is null || SelectedActionsButton is null) return;
        var selected = JobsList.SelectedItems.OfType<DownloadJob>().ToArray();
        SelectionSummary.Text = _batchInFlight ? "Applying download actions…" : selected.Length == 0 ? "" : $"{selected.Length} selected in this view";
        ResumeSelectedButton.IsEnabled = _connected && !_batchInFlight && selected.Any(job => job.CanControl && (job.State is "paused" or "retry_wait"));
        PauseSelectedButton.IsEnabled = _connected && !_batchInFlight && selected.Any(job => job.CanControl && (job.State is "queued" or "scheduled" or "retry_wait" or "downloading"));
        RemoveSelectedButton.IsEnabled = _connected && !_batchInFlight && selected.Any(job => job.CanControl &&
            (job.State is "queued" or "scheduled" or "downloading" or "paused" or "retry_wait" or "completed" or "failed" or "canceled"));
        SelectedActionsButton.IsEnabled = _connected && !_batchInFlight && selected.Length == 1;
        if (selected.Length <= 1) { UpdateDetails(selected.FirstOrDefault()); return; }
        UpdateDetails(null);
        DetailTitle.Text = $"{selected.Length} downloads selected";
        DetailState.Text = "Use selection commands to control eligible downloads.";
    }

    private void OnAddShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!_connected) return;
        _ = ShowAddDownloadAsync(null, null, null);
        args.Handled = true;
    }

    private void OnSearchShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        SearchBox.Focus(FocusState.Programmatic);
        args.Handled = true;
    }

    private void OnWorkspaceSizeChanged(object sender, SizeChangedEventArgs e)
        => UpdateResponsiveLayout();

    private void OnCloseDetails(object sender, RoutedEventArgs e)
    {
        _showNarrowDetails = false;
        UpdateResponsiveLayout();
        JobsList.Focus(FocusState.Programmatic);
    }

    private void OnDetailsBackShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!_showNarrowDetails || JobsList.Visibility != Visibility.Collapsed) return;
        _showNarrowDetails = false;
        UpdateResponsiveLayout();
        JobsList.Focus(FocusState.Programmatic);
        args.Handled = true;
    }

    private void OnSelectedActions(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement anchor && JobsList.SelectedItems.Count == 1 && JobsList.SelectedItem is DownloadJob job)
            ShowJobMenu(anchor, job.JobId);
    }

    private void UpdateDetails(DownloadJob? job)
    {
        DetailTitle.Text = job?.Title ?? "Select a transfer";
        DetailCommands.Visibility = job is null ? Visibility.Collapsed : Visibility.Visible;
        DetailPrimaryAction.Tag = job?.JobId;
        DetailPrimaryAction.Content = job?.PrimaryActionText ?? "";
        DetailPrimaryAction.Visibility = job?.PrimaryActionVisibility ?? Visibility.Collapsed;
        DetailPrimaryAction.IsEnabled = _connected && !_batchInFlight && job?.CanControl == true;
        DetailRemoveAction.Tag = job?.JobId;
        DetailRemoveAction.Content = job?.RemoveActionText ?? "Remove";
        DetailRemoveAction.IsEnabled = _connected && !_batchInFlight && job?.CanControl == true;
        DetailMoreActions.Tag = job?.JobId;
        DetailMoreActions.IsEnabled = _connected && !_batchInFlight && job?.CanControl == true;
        DetailState.Text = job?.StateText ?? "—";
        DetailUrl.Text = job?.Host ?? "—";
        DetailDestination.Text = job?.Destination ?? "—";
        DetailProgress.Text = job is null ? "" : job.Total > 0 ? $"{job.ProgressText} · {job.Progress:0.#}%" : job.State == "downloading" ? "Waiting for the server to report file size…" : "";
        DetailCheckpoint.Text = job?.CheckpointText ?? "";
        DetailRate.Text = job is null ? "" : !_connected ? "Rate unavailable while disconnected" : $"{job.SpeedText} · {job.EtaText}";
        var selectedQueue = job is null ? null : (_settings?["queues"] as JsonArray)?.OfType<JsonObject>()
            .FirstOrDefault(queue => queue["id"]?.GetValue<string>() == job.QueueId);
        DetailQueue.Text = job is null ? "" : "Queue: " + (selectedQueue?["name"]?.GetValue<string>() ?? job.QueueId);
        DetailJobLimit.Text = job is null || job.IsTorrent || !Uri.TryCreate(job.Url, UriKind.Absolute, out var detailUri) || detailUri.Scheme is not ("http" or "https") ? "" : job.BandwidthLimit == 0
            ? "Per-download limit: Unlimited (global limit still applies)"
            : $"Per-download limit: {job.BandwidthLimit / 1_000_000d:0.######} MB/s (global limit also applies)";
        DetailReference.Text = job?.ReferenceUrl is not null && Uri.TryCreate(job.ReferenceUrl, UriKind.Absolute, out var reference) ? $"Reference page: {reference.Host}" : "";
        DetailChecksum.Text = string.IsNullOrEmpty(job?.ExpectedSha256) ? "" : $"Expected SHA-256: {job.ExpectedSha256}";
        DetailError.Text = job?.ErrorMessage ?? "";
        DetailQueueAction.Text = job?.QueueActionOutcome switch
        {
            "failed" => "The queue completion action failed. Review the queue settings; diagnostic logging can capture future failures.",
            "succeeded" when job?.QueueFinishAction == "user_command" => "Queue completion command finished successfully.",
            "succeeded" => "Queue completion action was requested.",
            _ => "",
        };
        DetailRetry.Text = "";
        if (job?.State == "retry_wait")
        {
            DetailRetry.Text = $"Retry attempt {job.RetryAttempts} of 3";
            if (long.TryParse(job.RetryAtUnixMs, out var timestamp))
            {
                try { DetailRetry.Text += $" · next attempt {DateTimeOffset.FromUnixTimeMilliseconds(timestamp).ToLocalTime():g}"; }
                catch (ArgumentOutOfRangeException) { }
            }
        }
        var torrent = job?.IsTorrent == true;
        TorrentHeading.Visibility = torrent ? Visibility.Visible : Visibility.Collapsed;
        TorrentStats.Visibility = torrent ? Visibility.Visible : Visibility.Collapsed;
        if (torrent)
        {
            string Count(uint? value) => value?.ToString() ?? "Not available";
            TorrentStats.Text = !_connected ? "Swarm information unavailable while disconnected." : job!.State != "downloading"
                ? "Swarm information is available only while downloading."
                : $"Peer and web-seed connections: {job.TorrentActivePeerCount}\nDiscovered peers: {Count(job.TorrentPeerCount)}\nTracker seeders: {Count(job.TorrentSeederCount)}\nTracker leechers: {Count(job.TorrentLeecherCount)}\n\nTracker counts may be incomplete. Upload and seeding information is not available.";
        }
        if (_workersJobId != job?.JobId)
        {
            _workerRows.Clear();
            _workersJobId = job?.JobId;
        }
        List<DownloadWorker> workers = torrent ? [] : job?.Workers ?? [];
        WorkersHeading.Visibility = workers.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        for (var index = 0; index < workers.Count; index++)
        {
            if (index >= _workerRows.Count)
            {
                workers[index].BeginSampling();
                _workerRows.Add(workers[index]);
            }
            else if (_workerRows[index].WorkerId == workers[index].WorkerId) _workerRows[index].UpdateFrom(workers[index]);
            else
            {
                workers[index].BeginSampling();
                _workerRows[index] = workers[index];
            }
            if (!_connected || job?.State != "downloading") _workerRows[index].MarkDisconnected();
        }
        while (_workerRows.Count > workers.Count) _workerRows.RemoveAt(_workerRows.Count - 1);
    }

    private void UpdateSummary()
    {
        QueueSummary.Text = $"{_allJobs.Count(job => job.State == "downloading")} active · {_allJobs.Count(job => job.State is "queued" or "scheduled")} queued";
        AggregateSpeed.Text = _aggregateRate > 0 ? $"↓ {_aggregateRate / 1_000_000d:0.##} MB/s" : "Rate unavailable";
    }

    private void RecordNotificationTransitions(IReadOnlyList<DownloadJob> jobs)
    {
        var currentIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var job in jobs)
        {
            currentIds.Add(job.JobId);
            if (_notificationBaseline && _notificationStates.TryGetValue(job.JobId, out var previous) && previous != job.State &&
                ((job.State == "completed" && _clientPreferences.NotifyCompleted) || (job.State == "failed" && _clientPreferences.NotifyFailed)))
            {
                _notifications.Show(job.JobId, job.State == "completed");
                NotificationStatus.Text = _notifications.Status;
            }
            if (_notificationBaseline && _clientPreferences.NotifyFailed && job.QueueActionOutcome == "failed" &&
                _notificationQueueOutcomes.TryGetValue(job.JobId, out var previousOutcome) && previousOutcome != "failed")
            {
                _notifications.ShowQueueFailure(job.JobId);
                NotificationStatus.Text = _notifications.Status;
            }
            _notificationStates[job.JobId] = job.State;
            _notificationQueueOutcomes[job.JobId] = job.QueueActionOutcome;
        }
        foreach (var id in _notificationStates.Keys.Where(id => !currentIds.Contains(id)).ToArray()) _notificationStates.Remove(id);
        foreach (var id in _notificationQueueOutcomes.Keys.Where(id => !currentIds.Contains(id)).ToArray()) _notificationQueueOutcomes.Remove(id);
        _notificationBaseline = true;
    }

    private void OpenNotificationJob(string jobId)
    {
        _notificationJobId = jobId;
        ShowMainWindow();
        if (_connected) SelectNotificationJob();
    }

    private void SelectNotificationJob()
    {
        if (_notificationJobId is null) return;
        var id = _notificationJobId;
        _notificationJobId = null;
        _category = "All downloads";
        SettingsView.Visibility = Visibility.Collapsed;
        Workspace.Visibility = Visibility.Visible;
        SectionTitle.Text = CategoryLabel(_category);
        AppNavigation.SelectedItem = AllNavigationItem;
        SearchBox.Text = "";
        ApplyFilter();
        var selected = _visibleJobs.FirstOrDefault(job => job.JobId == id);
        if (selected is null)
        {
            ShowMessage("This download is no longer in the list.", InfoBarSeverity.Informational);
            return;
        }
        JobsList.SelectedItem = selected;
        _showNarrowDetails = true;
        UpdateResponsiveLayout();
    }

    private void UpdateNavigationCounts()
    {
        AllNavigationItem.Content = $"{L("All downloads", "همه دانلودها")}  {_allJobs.Count}";
        ProgressNavigationItem.Content = $"{L("In progress", "در حال انجام")}  {_allJobs.Count(job => job.State is not ("completed" or "failed" or "canceled"))}";
        CompletedNavigationItem.Content = $"{L("Completed", "تکمیل‌شده")}  {_allJobs.Count(job => job.State == "completed")}";
        FailedNavigationItem.Content = $"{L("Failed", "ناموفق")}  {_allJobs.Count(job => job.State == "failed")}";
    }

    private string L(string english, string persian) => _persian ? persian : english;

    private string CategoryLabel(string category) => category switch
    {
        "All downloads" => L(category, "همه دانلودها"),
        "In progress" => L(category, "در حال انجام"),
        "Completed" => L(category, "تکمیل‌شده"),
        "Failed" => L(category, "ناموفق"),
        _ => category
    };

    private void ApplyLanguage(string language)
    {
        _persian = language == "fa" || (language == "system" && _systemUiCulture.TwoLetterISOLanguageName == "fa");
        System.Globalization.CultureInfo.CurrentCulture = language == "system" ? _systemCulture : System.Globalization.CultureInfo.GetCultureInfo(_persian ? "fa-IR" : "en-US");
        System.Globalization.CultureInfo.CurrentUICulture = language == "system" ? _systemUiCulture : System.Globalization.CultureInfo.GetCultureInfo(_persian ? "fa-IR" : "en-US");
        AppNavigation.FlowDirection = _persian ? FlowDirection.RightToLeft : FlowDirection.LeftToRight;
        LanguageBox.Header = L("Language", "زبان");
        AppearanceHeading.Text = L("Appearance", "ظاهر");
        GeneralHeading.Text = L("General", "عمومی");
        NotificationsHeading.Text = L("Notifications", "اعلان‌ها");
        DownloadsHeading.Text = L("Downloads", "دانلودها");
        NetworkHeading.Text = L("Network", "شبکه");
        BandwidthHeading.Text = L("Bandwidth", "پهنای باند");
        IntegrationHeading.Text = L("Integration", "یکپارچه‌سازی");
        SettingsSectionBox.Header = L("Go to settings section", "رفتن به بخش تنظیمات");
        AppearanceBox.Header = L("App theme", "پوسته برنامه");
        LaunchOnLoginSwitch.Header = L("Open Speed Download at sign-in", "اجرای برنامه هنگام ورود");
        StartMinimizedSwitch.Header = L("Start minimized at sign-in", "شروع به صورت کوچک‌شده");
        CloseActionBox.Header = L("When closing the window", "هنگام بستن پنجره");
        NotifyCompletedSwitch.Header = L("Completed downloads", "دانلودهای تکمیل‌شده");
        NotifyFailedSwitch.Header = L("Failed downloads", "دانلودهای ناموفق");
        DownloadFolderBox.Header = L("Default download folder", "پوشه پیش‌فرض دانلود");
        ConcurrentBox.Header = L("Maximum simultaneous downloads", "حداکثر دانلودهای هم‌زمان");
        ConnectionsBox.Header = L("Maximum connections per download", "حداکثر اتصال برای هر دانلود");
        MultipartModeBox.Header = L("Parallel downloading", "دانلود موازی");
        ProxyModeBox.Header = L("Proxy mode", "حالت پراکسی");
        ProxyUrlBox.Header = L("Manual HTTP proxy URL", "نشانی پراکسی HTTP");
        ProxyUserBox.Header = L("Username", "نام کاربری");
        ProxyPasswordBox.Header = L("Password", "گذرواژه");
        ProxyAuthenticationSwitch.Header = L("Require authentication for manual proxy", "احراز هویت پراکسی دستی");
        BandwidthBox.Header = L("Global download limit (MB/s; 0 = unlimited)", "محدودیت سراسری دانلود (مگابایت بر ثانیه؛ صفر یعنی نامحدود)");
        BrowserExtensionsBox.Header = L("Browser capture file extensions", "پسوندهای دریافت از مرورگر");
        SearchBox.PlaceholderText = L("Search downloads", "جست‌وجوی دانلودها");
        SortBox.Header = L("Sort downloads", "مرتب‌سازی دانلودها");
        CloseDetailsButton.Content = L("Close", "بستن");
        UpdateNavigationCounts();
        if (!_category.StartsWith("queue:", StringComparison.Ordinal)) SectionTitle.Text = CategoryLabel(_category);
        var sectionLabels = new[] { L("Appearance", "ظاهر"), L("General", "عمومی"), L("Notifications", "اعلان‌ها"), L("Downloads", "دانلودها"), L("Network", "شبکه"), L("Bandwidth", "پهنای باند"), L("Integration", "یکپارچه‌سازی") };
        for (var i = 0; i < sectionLabels.Length; i++) ((ComboBoxItem)SettingsSectionBox.Items[i]).Content = sectionLabels[i];
        ((ComboBoxItem)LanguageBox.Items[0]).Content = L("System", "زبان سیستم");
    }

    private async void OnLanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loadingSettings || LanguageBox?.SelectedItem is not ComboBoxItem item || item.Tag is not string language) return;
        if (await SaveSettingsAsync(settings => settings["language"] = language)) ApplyLanguage(language);
    }

    private async Task LoadSettingsAsync(JsonObject? snapshot = null)
    {
        try
        {
            _loadingSettings = true;
            _settings = snapshot ?? await _engine.GetSettingsAsync();
            var language = ReadString("language");
            if (language is not ("en" or "fa")) language = "system";
            SelectChoice(LanguageBox, language);
            ApplyLanguage(language);
            DebugLoggingSwitch.IsOn = ReadBool("debug_log_enabled");
            DownloadFolderBox.Text = ReadString("default_download_folder");
            ConcurrentBox.Value = ReadNumber("max_concurrent_tasks");
            ConnectionsBox.Value = ReadNumber("default_connections_per_task");
            BandwidthBox.Value = ReadNumber("bandwidth_limit_bytes_per_second") / 1_000_000d;
            _loadingSpeedLimit = true;
            var selectedLimit = ReadNumber("bandwidth_limit_bytes_per_second") / 1_000_000d;
            var selectedItem = SpeedLimitBox.Items.OfType<ComboBoxItem>().FirstOrDefault(item =>
                double.TryParse(item.Tag?.ToString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var value) && value == selectedLimit);
            if (selectedItem is null)
            {
                selectedItem = new ComboBoxItem { Content = $"{selectedLimit:0.######} MB/s", Tag = selectedLimit.ToString("R", System.Globalization.CultureInfo.InvariantCulture) };
                SpeedLimitBox.Items.Add(selectedItem);
            }
            SpeedLimitBox.SelectedItem = selectedItem;
            _loadingSpeedLimit = false;
            BrowserExtensionsBox.Text = ReadString("browser_grab_extensions");
            try { WriteBrowserPreferences(); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            ProxyUrlBox.Text = ReadString("proxy_url");
            ProxyAuthenticationSwitch.IsOn = ReadBool("proxy_authentication_required");
            UpdateProxyCredentialStatus();
            SelectChoice(MultipartModeBox, ReadString("multipart_mode"));
            SelectChoice(ProxyModeBox, ReadString("proxy_mode"));
            ProxyUrlBox.IsEnabled = ReadString("proxy_mode") == "custom";
            UpdateQueues();
            SettingsMessage.IsOpen = false;
        }
        catch (Exception error) { ShowMessage(error.Message, InfoBarSeverity.Error); }
        finally { _loadingSpeedLimit = false; _loadingSettings = false; }
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
        var selectedTag = (AppNavigation.SelectedItem as NavigationViewItem)?.Tag?.ToString();
        while (AppNavigation.MenuItems.Count > 7) AppNavigation.MenuItems.RemoveAt(7);
        if (_settings?["queues"] is not JsonArray queues) return;
        foreach (var queue in queues.OfType<JsonObject>())
        {
            var id = queue["id"]?.GetValue<string>();
            var name = queue["name"]?.GetValue<string>();
            if (!string.IsNullOrWhiteSpace(id))
                AppNavigation.MenuItems.Add(new NavigationViewItem { Content = name ?? id, Tag = "queue:" + id, Icon = new SymbolIcon(Symbol.List) });
        }
        if (selectedTag?.StartsWith("queue:", StringComparison.Ordinal) == true)
        {
            var selected = AppNavigation.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(item => item.Tag?.ToString() == selectedTag);
            if (selected is not null)
            {
                AppNavigation.SelectedItem = selected;
                if (_category == selectedTag) SectionTitle.Text = selected.Content?.ToString() ?? "Queue";
            }
            else if (_category == selectedTag)
            {
                _category = "All downloads";
                AppNavigation.SelectedItem = AllNavigationItem;
                SectionTitle.Text = CategoryLabel(_category);
            }
        }
    }

    private async Task<bool> SaveSettingsAsync(Action<JsonObject> change)
    {
        if (_loadingSettings || _settings is null || !_connected) return false;
        await _settingsGate.WaitAsync();
        try
        {
            // Merge edits into a fresh engine snapshot so another client’s unrelated changes are not overwritten.
            var updated = await _engine.GetSettingsAsync();
            change(updated);
            await _engine.UpdateSettingsAsync(updated);
            _settings = updated;
            UpdateProxyCredentialStatus();
            try { WriteBrowserPreferences(); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            SettingsMessage.IsOpen = false;
            return true;
        }
        catch (Exception error)
        {
            var message = error.Message;
            await LoadSettingsAsync();
            SettingsMessage.Severity = InfoBarSeverity.Error;
            SettingsMessage.Message = message;
            SettingsMessage.IsOpen = true;
            if (Workspace.Visibility == Visibility.Visible) ShowMessage(message, InfoBarSeverity.Error);
            return false;
        }
        finally { _settingsGate.Release(); }
    }

    private void OnSettingToggled(object sender, RoutedEventArgs e)
    {
        var enabled = DebugLoggingSwitch.IsOn;
        _ = SaveSettingsAsync(settings => settings["debug_log_enabled"] = enabled);
    }

    private void OnNumberSettingChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (_loadingSettings || !double.IsFinite(sender.Value)) return;
        var value = sender.Value;
        if (sender == ConcurrentBox || sender == ConnectionsBox)
        {
            if (value < 1 || value > 32 || value != Math.Truncate(value))
            {
                SettingsMessage.Severity = InfoBarSeverity.Error;
                SettingsMessage.Message = "Enter a whole number from 1 to 32.";
                SettingsMessage.IsOpen = true;
                return;
            }
            var count = (int)value;
            if (sender == ConcurrentBox) _ = SaveSettingsAsync(settings => settings["max_concurrent_tasks"] = count);
            else _ = SaveSettingsAsync(settings => settings["default_connections_per_task"] = count);
        }
        else if (sender == BandwidthBox)
        {
            if (value < 0 || value > 1_000_000 || (value > 0 && value < 0.000001))
            {
                SettingsMessage.Severity = InfoBarSeverity.Error;
                SettingsMessage.Message = "Enter 0 or a speed of at least 0.000001 MB/s.";
                SettingsMessage.IsOpen = true;
                return;
            }
            var bytes = (ulong)Math.Round(value * 1_000_000, MidpointRounding.AwayFromZero);
            _ = SaveSettingsAsync(settings => settings["bandwidth_limit_bytes_per_second"] = bytes);
        }
    }

    private void OnChoiceSettingChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loadingSettings || sender is not ComboBox box || box.SelectedItem is not ComboBoxItem item) return;
        if (box == MultipartModeBox) _ = SaveSettingsAsync(settings => settings["multipart_mode"] = item.Tag?.ToString());
        else if (box == ProxyModeBox)
        {
            if (item.Tag?.ToString() == "system" && !_engine.SupportsFeature("proxy.windows-system-v1"))
            {
                _loadingSettings = true;
                try { SelectChoice(ProxyModeBox, ReadString("proxy_mode")); }
                finally { _loadingSettings = false; }
                SettingsMessage.Message = "Update and restart the engine before using Windows system proxy settings.";
                SettingsMessage.Severity = InfoBarSeverity.Error; SettingsMessage.IsOpen = true;
                return;
            }
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

    private void UpdateProxyCredentialStatus()
    {
        ProxySystemNotice.Text = _engine.SupportsFeature("proxy.windows-system-v1")
            ? "System mode uses Windows proxy configuration, including automatic discovery. SOCKS and authenticated system proxies are not supported."
            : "This engine cannot use Windows system proxy settings. Update and restart it, or choose a manual proxy.";
        try
        {
            var endpoint = ReadString("proxy_url");
            ProxyCredentialStatus.Text = !_engine.SupportsFeature("proxy.windows-credentials-v1")
                ? "The running engine does not support Windows proxy credentials."
                : string.IsNullOrWhiteSpace(endpoint) ? "Save a manual proxy endpoint before adding credentials."
                : ProxyCredentialStore.Exists(endpoint) ? "A credential is saved for this proxy and Windows user." : "No credential is saved for this proxy.";
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or System.Security.SecurityException)
        { ProxyCredentialStatus.Text = "Windows Credential Manager is unavailable."; }
    }

    private void OnSaveProxyCredentials(object sender, RoutedEventArgs e)
    {
        if (!_engine.SupportsFeature("proxy.windows-credentials-v1"))
        { SettingsMessage.Message = "Update and restart the engine before saving proxy credentials."; SettingsMessage.Severity = InfoBarSeverity.Error; SettingsMessage.IsOpen = true; return; }
        try
        {
            var endpoint = ReadString("proxy_url");
            if (ReadString("proxy_mode") != "custom" || string.IsNullOrWhiteSpace(endpoint) || endpoint != ProxyUrlBox.Text.Trim())
                throw new ArgumentException("Save the manual proxy endpoint first.");
            ProxyCredentialStore.Save(endpoint, ProxyUserBox.Text, ProxyPasswordBox.Password);
            ProxyPasswordBox.Password = "";
            UpdateProxyCredentialStatus();
            SettingsMessage.Message = "Proxy credentials were saved in Windows Credential Manager. Enable authentication to use them.";
            SettingsMessage.Severity = InfoBarSeverity.Success; SettingsMessage.IsOpen = true;
        }
        catch (Exception error) when (error is ArgumentException or System.ComponentModel.Win32Exception or System.Security.SecurityException)
        { SettingsMessage.Message = "Could not save proxy credentials. Save the manual proxy endpoint first, then check the username and Windows Credential Manager."; SettingsMessage.Severity = InfoBarSeverity.Error; SettingsMessage.IsOpen = true; }
    }

    private async void OnRemoveProxyCredentials(object sender, RoutedEventArgs e)
    {
        if (!_connected) return;
        var endpoint = ReadString("proxy_url");
        if (string.IsNullOrWhiteSpace(endpoint)) { SettingsMessage.Message = "No manual proxy endpoint is configured."; SettingsMessage.Severity = InfoBarSeverity.Error; SettingsMessage.IsOpen = true; return; }
        if (ReadBool("proxy_authentication_required") && !await SaveSettingsAsync(settings => settings["proxy_authentication_required"] = false)) return;
        _loadingSettings = true;
        try { ProxyAuthenticationSwitch.IsOn = false; }
        finally { _loadingSettings = false; }
        try
        {
            ProxyCredentialStore.Delete(endpoint);
            ProxyPasswordBox.Password = "";
            UpdateProxyCredentialStatus();
            SettingsMessage.Message = "Proxy authentication is disabled and saved credentials were removed.";
            SettingsMessage.Severity = InfoBarSeverity.Success; SettingsMessage.IsOpen = true;
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or System.Security.SecurityException)
        { SettingsMessage.Message = "Proxy authentication is disabled, but Windows could not remove the saved credential."; SettingsMessage.Severity = InfoBarSeverity.Error; SettingsMessage.IsOpen = true; }
    }

    private async void OnProxyAuthenticationToggled(object sender, RoutedEventArgs e)
    {
        if (_loadingSettings) return;
        var enabled = ProxyAuthenticationSwitch.IsOn;
        try
        {
            if (!_connected || !_engine.SupportsFeature("proxy.windows-credentials-v1")) throw new InvalidOperationException("The engine does not support Windows proxy credentials.");
            if (enabled && ReadString("proxy_mode") != "custom") throw new InvalidOperationException("Choose a manual proxy before enabling authentication.");
            if (enabled && (string.IsNullOrWhiteSpace(ReadString("proxy_url")) || !ProxyCredentialStore.Exists(ReadString("proxy_url"))))
                throw new InvalidOperationException("Save credentials for this proxy before enabling authentication.");
            if (!await SaveSettingsAsync(settings => settings["proxy_authentication_required"] = enabled)) return;
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception or System.Security.SecurityException)
        {
            _loadingSettings = true;
            try { ProxyAuthenticationSwitch.IsOn = ReadBool("proxy_authentication_required"); }
            finally { _loadingSettings = false; }
            SettingsMessage.Message = error.Message; SettingsMessage.Severity = InfoBarSeverity.Error; SettingsMessage.IsOpen = true;
        }
    }

    private void OnRegisterBrowserIntegration(object sender, RoutedEventArgs e)
    {
        try
        {
            WindowsAssociations.RegisterBrowserHosts();
            WriteBrowserPreferences();
            SettingsMessage.Severity = InfoBarSeverity.Success;
            SettingsMessage.Message = "Browser host registered for this user. Install the Speed Download extension in your browser.";
            SettingsMessage.IsOpen = true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException or InvalidOperationException)
        {
            SettingsMessage.Severity = InfoBarSeverity.Error;
            SettingsMessage.Message = "Could not register browser integration: " + error.Message;
            SettingsMessage.IsOpen = true;
        }
    }

    private void WriteBrowserPreferences()
    {
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SpeedDownload");
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "browser-extensions.txt"), ReadString("browser_grab_extensions"));
    }

    private void OnRegisterAssociations(object sender, RoutedEventArgs e)
    {
        try
        {
            WindowsAssociations.Register();
            SettingsMessage.Severity = InfoBarSeverity.Success;
            SettingsMessage.Message = "Registered for this Windows user. Select Speed Download in Windows default app settings.";
            SettingsMessage.IsOpen = true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException or InvalidOperationException)
        {
            SettingsMessage.Severity = InfoBarSeverity.Error;
            SettingsMessage.Message = "Could not register the handler: " + error.Message;
            SettingsMessage.IsOpen = true;
        }
    }

    private async void OnOpenDefaultApps(object sender, RoutedEventArgs e)
    {
        if (!await Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:defaultapps")))
        {
            SettingsMessage.Severity = InfoBarSeverity.Error;
            SettingsMessage.Message = "Could not open Windows default app settings.";
            SettingsMessage.IsOpen = true;
        }
    }

    private async void OnOpenNotificationSettings(object sender, RoutedEventArgs e)
    {
        try
        {
            if (await Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:notifications"))) return;
            SettingsMessage.Message = "Could not open Windows notification settings.";
        }
        catch (Exception) { SettingsMessage.Message = "Could not open Windows notification settings."; }
        SettingsMessage.Severity = InfoBarSeverity.Error;
        SettingsMessage.IsOpen = true;
    }

    private void OnChooseDefaultFolder(object sender, RoutedEventArgs e)
    {
        using var picker = new System.Windows.Forms.FolderBrowserDialog { SelectedPath = DownloadFolderBox.Text, Description = "Choose the default download folder" };
        if (picker.ShowDialog() != System.Windows.Forms.DialogResult.OK) return;
        var selectedPath = picker.SelectedPath;
        DownloadFolderBox.Text = selectedPath;
        _ = SaveSettingsAsync(settings => settings["default_download_folder"] = selectedPath);
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

    private async void OnDeleteQueue(object sender, RoutedEventArgs e)
    {
        if (!_connected || !_category.StartsWith("queue:", StringComparison.Ordinal))
        { ShowMessage("Select a user queue first.", InfoBarSeverity.Informational); return; }
        var id = _category[6..];
        if (id == "main")
        { ShowMessage("The main queue cannot be deleted.", InfoBarSeverity.Informational); return; }
        var jobs = _allJobs.Where(job => job.QueueId == id).ToArray();
        var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Delete this queue?",
            Content = $"Move {jobs.Length} download(s) to main, then delete this queue. Downloaded files and partial data will be kept.",
            PrimaryButtonText = "Move jobs and delete", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            foreach (var job in jobs) await _engine.MoveJobToQueueAsync(job, "main");
            await SaveSettingsAsync(settings =>
            {
                var queues = settings["queues"] as JsonArray;
                var queue = queues?.OfType<JsonObject>().FirstOrDefault(value => value["id"]?.GetValue<string>() == id);
                if (queue is not null) queues!.Remove(queue);
            });
            if (_settings?["queues"] is JsonArray remaining && remaining.OfType<JsonObject>().Any(queue => queue["id"]?.GetValue<string>() == id)) return;
            _category = "All downloads";
            SectionTitle.Text = CategoryLabel(_category);
            UpdateQueues();
            await RefreshAsync();
        }
        catch (Exception error)
        {
            ShowMessage($"The queue was kept. Some jobs may have moved to main: {error.Message}", InfoBarSeverity.Error);
            await RefreshAsync();
        }
    }

    private static void NavigateSchedule(CheckBox[] cells, int index, KeyRoutedEventArgs args)
    {
        var day = index / 24;
        var hour = index % 24;
        var next = args.Key switch
        {
            Windows.System.VirtualKey.Left when day > 0 => index - 24,
            Windows.System.VirtualKey.Right when day < 6 => index + 24,
            Windows.System.VirtualKey.Up when hour > 0 => index - 1,
            Windows.System.VirtualKey.Down when hour < 23 => index + 1,
            _ => -1,
        };
        if (next < 0) return;
        cells[next].Focus(FocusState.Keyboard);
        args.Handled = true;
    }

    private static Expander CreateScheduleRangeEditor(CheckBox[] cells, string enableLabel, string disableLabel)
    {
        var day = new ComboBox { Header = "Day", HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var label in System.Globalization.CultureInfo.CurrentCulture.DateTimeFormat.DayNames) day.Items.Add(label);
        day.SelectedIndex = 0;
        var start = new NumberBox { Header = "Start hour (0–23)", Minimum = 0, Maximum = 23, Value = 8,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact, Width = 145 };
        var end = new NumberBox { Header = "End hour (1–24)", Minimum = 1, Maximum = 24, Value = 17,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact, Width = 145 };
        var hours = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        hours.Children.Add(start); hours.Children.Add(end);
        var error = new InfoBar { IsOpen = false, Severity = InfoBarSeverity.Warning };
        var set = new Button { Content = enableLabel };
        var clear = new Button { Content = disableLabel };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(set); actions.Children.Add(clear);
        void Apply(bool value)
        {
            if (day.SelectedIndex < 0 || !double.IsFinite(start.Value) || !double.IsFinite(end.Value) ||
                start.Value != Math.Truncate(start.Value) || end.Value != Math.Truncate(end.Value) ||
                start.Value < 0 || end.Value > 24 || start.Value >= end.Value)
            {
                error.Message = "Choose a day and whole hours with an end after the start.";
                error.IsOpen = true;
                return;
            }
            for (var hour = (int)start.Value; hour < (int)end.Value; hour++) cells[day.SelectedIndex * 24 + hour].IsChecked = value;
            error.IsOpen = false;
        }
        set.Click += (_, _) => Apply(true);
        clear.Click += (_, _) => Apply(false);
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(day); panel.Children.Add(hours); panel.Children.Add(actions); panel.Children.Add(error);
        return new Expander { Header = "Edit hours by day and time", Content = panel, HorizontalAlignment = HorizontalAlignment.Stretch };
    }

    private static string ScheduleHourLabel(int hour)
        => DateTime.Today.AddHours(hour).ToString("t", System.Globalization.CultureInfo.CurrentCulture);

    private static string ScheduleTimeExplanation()
        => $"Times use this computer's local time zone ({TimeZoneInfo.Local.DisplayName}). " +
           "The engine checks the current hour after waking; missed hours are not replayed. " +
           "During daylight-saving changes, skipped local times do not occur and repeated local times use the same setting both times.";

    private (TextBlock Text, Action Refresh, DispatcherQueueTimer Timer) CreateSchedulePreview(
        CheckBox[] cells, Func<bool> enabled, string selectedRule, string otherRule, string disabledRule)
    {
        var text = new TextBlock { Text = "Calculating schedule…", TextWrapping = TextWrapping.Wrap };
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(150);
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            if (!enabled()) { text.Text = disabledRule; return; }
            var slots = cells.Select(cell => cell.IsChecked == true).ToArray();
            var now = DateTimeOffset.UtcNow;
            var current = now.ToLocalTime();
            var selected = slots[(int)current.DayOfWeek * 24 + current.Hour];
            var firstMinute = DateTimeOffset.FromUnixTimeSeconds((now.ToUnixTimeSeconds() / 60 + 1) * 60);
            for (var minute = 0; minute < 8 * 24 * 60; minute++)
            {
                var candidate = firstMinute.AddMinutes(minute).ToLocalTime();
                if (slots[(int)candidate.DayOfWeek * 24 + candidate.Hour] == selected) continue;
                text.Text = $"Current rule: {(selected ? selectedRule : otherRule)}. Next change: {candidate:g} ({(selected ? otherRule : selectedRule)}).";
                return;
            }
            text.Text = $"Current rule: {(selected ? selectedRule : otherRule)}. No change is scheduled in the next eight days.";
        };
        void Refresh() { timer.Stop(); timer.Start(); }
        return (text, Refresh, timer);
    }

    private async void OnBandwidthSchedule(object sender, RoutedEventArgs e)
    {
        if (!_connected || _settings is null) return;
        var enabled = new ToggleSwitch { Header = "Use limited speed on schedule", IsOn = ReadBool("bandwidth_schedule_enabled") };
        var limit = new NumberBox { Header = "Scheduled limit (MB/s; 0 = unlimited)", Minimum = 0, Maximum = 100000,
            Value = ReadNumber("scheduled_bandwidth_limit_bytes_per_second") / 1_000_000d, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        var slots = _settings["bandwidth_schedule_slots"] as JsonArray;
        if (slots is null || slots.Count != 168 || slots.Any(slot => slot is not JsonValue value ||
            !value.TryGetValue<string>(out var mode) || mode is not ("limited" or "global_limit")))
        { ShowMessage("The engine returned an invalid bandwidth schedule. Refresh and try again.", InfoBarSeverity.Error); return; }
        var grid = new Grid { ColumnSpacing = 4, RowSpacing = 4 };
        for (var col = 0; col < 8; col++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        for (var row = 0; row < 25; row++) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var dayFormat = System.Globalization.CultureInfo.CurrentCulture.DateTimeFormat;
        var days = dayFormat.AbbreviatedDayNames;
        for (var day = 0; day < 7; day++)
        {
            var label = new TextBlock { Text = days[day], HorizontalAlignment = HorizontalAlignment.Center };
            Grid.SetColumn(label, day + 1); grid.Children.Add(label);
        }
        var cells = new CheckBox[168];
        for (var hour = 0; hour < 24; hour++)
        {
            var label = new TextBlock { Text = ScheduleHourLabel(hour), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetRow(label, hour + 1); grid.Children.Add(label);
            for (var day = 0; day < 7; day++)
            {
                var index = day * 24 + hour;
                var cell = new CheckBox { IsChecked = index < (slots?.Count ?? 0) && slots![index]?.GetValue<string>() == "limited", MinWidth = 40 };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(cell, $"{dayFormat.DayNames[day]} {ScheduleHourLabel(hour)}: use scheduled limit");
                cell.KeyDown += (_, args) => NavigateSchedule(cells, index, args);
                Grid.SetColumn(cell, day + 1); Grid.SetRow(cell, hour + 1);
                grid.Children.Add(cell); cells[index] = cell;
            }
        }
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(enabled); panel.Children.Add(limit);
        panel.Children.Add(new TextBlock { Text = "Checked hours use the scheduled limit; other hours use the global limit. Use arrow keys to move between hours. " + ScheduleTimeExplanation(), TextWrapping = TextWrapping.Wrap });
        var rangeEditor = CreateScheduleRangeEditor(cells, "Use scheduled limit", "Use global limit");
        var preview = CreateSchedulePreview(cells, () => enabled.IsOn, "scheduled limit", "global limit", "Schedule disabled; the global limit applies.");
        foreach (var cell in cells) { cell.Checked += (_, _) => preview.Refresh(); cell.Unchecked += (_, _) => preview.Refresh(); }
        void UpdateEnabled() { limit.IsEnabled = enabled.IsOn; rangeEditor.IsEnabled = enabled.IsOn; foreach (var cell in cells) cell.IsEnabled = enabled.IsOn; preview.Refresh(); }
        enabled.Toggled += (_, _) => UpdateEnabled();
        UpdateEnabled();
        panel.Children.Add(rangeEditor);
        panel.Children.Add(preview.Text);
        panel.Children.Add(grid);
        var formError = new InfoBar { IsOpen = false, Severity = InfoBarSeverity.Error };
        panel.Children.Insert(0, formError);
        var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Scheduled download limit",
            Content = new ScrollViewer { Content = panel, MaxHeight = 500 }, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            dialog.IsPrimaryButtonEnabled = false;
            try
            {
                if (!double.IsFinite(limit.Value) || limit.Value < 0 || limit.Value > 100000 || (limit.Value > 0 && limit.Value < 0.000001))
                { formError.Message = "Enter 0 or a speed of at least 0.000001 MB/s."; formError.IsOpen = true; limit.Focus(FocusState.Programmatic); return; }
                var scheduledBytes = (ulong)Math.Round(limit.Value * 1_000_000, MidpointRounding.AwayFromZero);
                var saved = await SaveSettingsAsync(settings =>
                {
                    settings["bandwidth_schedule_enabled"] = enabled.IsOn;
                    settings["scheduled_bandwidth_limit_bytes_per_second"] = scheduledBytes;
                    settings["bandwidth_schedule_slots"] = new JsonArray(cells.Select(cell => (JsonNode?)JsonValue.Create(cell.IsChecked == true ? "limited" : "global_limit")).ToArray());
                });
                if (!saved) { formError.Message = SettingsMessage.Message?.ToString() ?? "Could not save the bandwidth schedule."; formError.IsOpen = true; return; }
                dialog.Hide();
            }
            finally { dialog.IsPrimaryButtonEnabled = true; deferral.Complete(); }
        };
        try { await dialog.ShowAsync(); }
        finally { preview.Timer.Stop(); if (sender is Control control) control.Focus(FocusState.Programmatic); }
    }

    private async void OnQueueSettings(object sender, RoutedEventArgs e)
    {
        if (!_category.StartsWith("queue:", StringComparison.Ordinal) || _settings?["queues"] is not JsonArray queues) return;
        var id = _category[6..];
        var queue = queues.OfType<JsonObject>().FirstOrDefault(value => value["id"]?.GetValue<string>() == id);
        if (queue is null) return;
        var queueName = new TextBox { Header = "Queue name", Text = queue["name"]?.GetValue<string>() ?? id, IsReadOnly = id == "main", MaxLength = 80 };
        var count = new NumberBox { Header = "Maximum active downloads", Minimum = 1, Maximum = 32, Value = System.Text.Json.JsonSerializer.Deserialize<double>(queue["max_active"]?.ToJsonString() ?? "1") };
        var schedule = new ToggleSwitch { Header = "Start and stop on a schedule", IsOn = queue["schedule_enabled"]?.GetValue<bool>() ?? false };
        if (queue["schedule_slots"] is not JsonArray scheduleSlots || scheduleSlots.Count != 168)
        { ShowMessage("The engine returned an invalid queue schedule. Refresh and try again.", InfoBarSeverity.Error); return; }
        var grid = new Grid { ColumnSpacing = 4, RowSpacing = 4 };
        for (var col = 0; col < 8; col++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        for (var row = 0; row < 25; row++) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var dayFormat = System.Globalization.CultureInfo.CurrentCulture.DateTimeFormat;
        var days = dayFormat.AbbreviatedDayNames;
        for (var day = 0; day < 7; day++)
        {
            var label = new TextBlock { Text = days[day], HorizontalAlignment = HorizontalAlignment.Center };
            Grid.SetColumn(label, day + 1); grid.Children.Add(label);
        }
        var cells = new CheckBox[168];
        for (var hour = 0; hour < 24; hour++)
        {
            var label = new TextBlock { Text = ScheduleHourLabel(hour), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetRow(label, hour + 1); grid.Children.Add(label);
            for (var day = 0; day < 7; day++)
            {
                var index = day * 24 + hour;
                var cell = new CheckBox { IsChecked = scheduleSlots[index]?.GetValue<bool>() == true, MinWidth = 40 };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(cell, $"{dayFormat.DayNames[day]} {ScheduleHourLabel(hour)}: queue active");
                cell.KeyDown += (_, args) => NavigateSchedule(cells, index, args);
                Grid.SetColumn(cell, day + 1); Grid.SetRow(cell, hour + 1);
                grid.Children.Add(cell); cells[index] = cell;
            }
        }
        var oldAction = queue["finish_action"]?.GetValue<string>() ?? "none";
        var finishAction = new ComboBox { Header = "When every download in this queue completes", HorizontalAlignment = HorizontalAlignment.Stretch };
        finishAction.Items.Add(new ComboBoxItem { Content = "Do nothing", Tag = "none" });
        finishAction.Items.Add(new ComboBoxItem { Content = "Run a user command", Tag = "user_command" });
        var windowsActions = _engine.SupportsFeature("queue.windows-finish-actions-v1");
        if (windowsActions)
        {
            finishAction.Items.Add(new ComboBoxItem { Content = "Quit Speed Download client", Tag = "quit_app" });
            finishAction.Items.Add(new ComboBoxItem { Content = "Shut down Windows", Tag = "power_off" });
        }
        if (oldAction is not ("none" or "user_command") && !(windowsActions && (oldAction is "quit_app" or "power_off")))
            finishAction.Items.Add(new ComboBoxItem { Content = $"Existing unsupported action ({oldAction}; preserved)", Tag = oldAction });
        SelectChoice(finishAction, oldAction);
        var userCommand = new TextBox { Header = "User command", Text = queue["user_command"]?.GetValue<string>() ?? "", MaxLength = 4096, TextWrapping = TextWrapping.Wrap };
        var powerOffConsent = new CheckBox { Content = "I understand Windows will begin shutting down when this queue completes.", IsChecked = false };
        void UpdateCommandEnabled()
        {
            var choice = (finishAction.SelectedItem as ComboBoxItem)?.Tag?.ToString();
            userCommand.IsEnabled = _engine.SupportsFeature("queue.finish-user-command-v1") && choice == "user_command";
            powerOffConsent.Visibility = choice == "power_off" ? Visibility.Visible : Visibility.Collapsed;
            if (choice != "power_off") powerOffConsent.IsChecked = false;
        }
        finishAction.IsEnabled = _engine.SupportsFeature("queue.finish-user-command-v1");
        finishAction.SelectionChanged += (_, _) => UpdateCommandEnabled();
        UpdateCommandEnabled();
        var completionNote = new TextBlock { Text = finishAction.IsEnabled
            ? "The action runs once as the engine's Windows user when every job in this queue completes. A user command can execute arbitrary programs. Quitting the client leaves the engine running. Windows shutdown can interrupt other queues and close other apps; unsaved work could be lost. Failed or canceled jobs prevent the action."
            : "This engine does not support Windows queue completion commands. Existing actions are preserved.", TextWrapping = TextWrapping.Wrap };
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(queueName);
        panel.Children.Add(count);
        panel.Children.Add(schedule);
        panel.Children.Add(new TextBlock { Text = "Checked hours allow this queue to run. Use arrow keys to move between hours. " + ScheduleTimeExplanation(), TextWrapping = TextWrapping.Wrap });
        var rangeEditor = CreateScheduleRangeEditor(cells, "Allow queue", "Stop queue");
        var preview = CreateSchedulePreview(cells, () => schedule.IsOn, "queue allowed", "queue stopped", "Schedule disabled; the queue is not restricted by time.");
        foreach (var cell in cells) { cell.Checked += (_, _) => preview.Refresh(); cell.Unchecked += (_, _) => preview.Refresh(); }
        void UpdateEnabled() { rangeEditor.IsEnabled = schedule.IsOn; foreach (var cell in cells) cell.IsEnabled = schedule.IsOn; preview.Refresh(); }
        schedule.Toggled += (_, _) => UpdateEnabled();
        UpdateEnabled();
        panel.Children.Add(rangeEditor);
        panel.Children.Add(preview.Text);
        panel.Children.Add(grid);
        panel.Children.Add(finishAction);
        panel.Children.Add(userCommand);
        panel.Children.Add(powerOffConsent);
        panel.Children.Add(completionNote);
        var formError = new InfoBar { IsOpen = false, Severity = InfoBarSeverity.Error };
        panel.Children.Insert(0, formError);
        var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = $"Queue settings · {queue["name"]?.GetValue<string>() ?? id}", Content = new ScrollViewer { Content = panel, MaxHeight = 500 }, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            dialog.IsPrimaryButtonEnabled = false;
            try
            {
                var name = queueName.Text.Trim();
                if (name.Length == 0) { formError.Message = "Enter a queue name."; formError.IsOpen = true; queueName.Focus(FocusState.Programmatic); return; }
                if (double.IsNaN(count.Value) || count.Value < 1 || count.Value > 32 || count.Value != Math.Truncate(count.Value))
                { formError.Message = "Enter a whole number from 1 to 32."; formError.IsOpen = true; count.Focus(FocusState.Programmatic); return; }
                var selectedAction = (finishAction.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? oldAction;
                var command = userCommand.Text.Trim();
                if (finishAction.IsEnabled && selectedAction == "user_command" &&
                    (command.Length == 0 || System.Text.Encoding.UTF8.GetByteCount(command) > 4096 || command.Contains('\0')))
                { formError.Message = "Enter a command of at most 4096 UTF-8 bytes."; formError.IsOpen = true; userCommand.Focus(FocusState.Programmatic); return; }
                if (finishAction.IsEnabled && selectedAction == "power_off" && powerOffConsent.IsChecked != true)
                { formError.Message = "Confirm that Windows should shut down when this queue completes."; formError.IsOpen = true; powerOffConsent.Focus(FocusState.Programmatic); return; }
                var saved = await SaveSettingsAsync(settings =>
                {
                    if (settings["queues"] is not JsonArray list) throw new InvalidOperationException("Queue settings are unavailable.");
                    var target = list.OfType<JsonObject>().FirstOrDefault(value => value["id"]?.GetValue<string>() == id)
                        ?? throw new InvalidOperationException("This queue no longer exists.");
                    if (list.OfType<JsonObject>().Any(other => other["id"]?.GetValue<string>() != id && string.Equals(other["name"]?.GetValue<string>(), name, StringComparison.OrdinalIgnoreCase)))
                        throw new InvalidOperationException("A queue with this name already exists.");
                    target["name"] = name;
                    target["max_active"] = (int)count.Value;
                    target["schedule_enabled"] = schedule.IsOn;
                    target["schedule_slots"] = new JsonArray(cells.Select(cell => (JsonNode?)JsonValue.Create(cell.IsChecked == true)).ToArray());
                    if (finishAction.IsEnabled && ((selectedAction is "none" or "user_command") ||
                        (windowsActions && (selectedAction is "quit_app" or "power_off"))))
                    {
                        target["finish_action"] = selectedAction;
                        target["user_command"] = selectedAction == "user_command" ? command : null;
                    }
                });
                if (!saved) { formError.Message = SettingsMessage.Message?.ToString() ?? "Could not save the queue."; formError.IsOpen = true; return; }
                UpdateQueues();
                SectionTitle.Text = name;
                AppNavigation.SelectedItem = AppNavigation.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(item => item.Tag?.ToString() == _category);
                dialog.Hide();
            }
            finally { dialog.IsPrimaryButtonEnabled = true; deferral.Complete(); }
        };
        try { await dialog.ShowAsync(); }
        finally { preview.Timer.Stop(); if (sender is Control control) control.Focus(FocusState.Programmatic); }
    }

    private async void OnJobAction(object sender, RoutedEventArgs e)
    {
        if (!_connected || _batchInFlight || sender is not Button button || button.Tag is not string jobId) return;
        if (JobsList.ItemsSource is not IEnumerable<DownloadJob> jobs) return;
        var job = jobs.FirstOrDefault(item => item.JobId == jobId);
        if (job is null) return;
        var action = job.State switch
        {
            "queued" => "start",
            "downloading" or "scheduled" => "pause",
            "paused" or "retry_wait" => "resume",
            "failed" => "retry",
            _ => null,
        };
        if (action is null) return;
        if (!job.CanControl) return;
        job.SetLocalPending(true);
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
        finally { job.SetLocalPending(false); }
    }

    private async void OnCancelOrRemove(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string jobId }) return;
        var job = _visibleJobs.FirstOrDefault(item => item.JobId == jobId);
        if (job is null || !_connected || _batchInFlight || !job.CanControl) return;
        var isActive = job.State is "resolving" or "connecting" or "downloading" or "verifying" or "queued" or "scheduled" or "paused" or "retry_wait";
        var confirm = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = isActive ? "Cancel download?" : "Remove download from history?",
            Content = isActive ? "The transfer will stop. Resumable partial data will be kept when supported; unresumable data may be discarded." : "This removes the entry from the list. Downloaded files will be kept.",
            PrimaryButtonText = isActive ? "Cancel download" : "Remove entry",
            CloseButtonText = "Keep",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            if (job.State is "resolving" or "connecting" or "downloading" or "verifying" or "queued" or "scheduled" or "paused" or "retry_wait")
                await _engine.ControlJobAsync(job, "cancel");
            else
                await _engine.DeleteJobAsync(job);
            await RefreshAsync();
        }
        catch (Exception error) { ShowMessage(error.Message, InfoBarSeverity.Error); }
    }

    private async void OnResumeSelected(object sender, RoutedEventArgs e) => await ControlSelectedAsync(false);
    private async void OnPauseSelected(object sender, RoutedEventArgs e) => await ControlSelectedAsync(true);

    private void SetBatchBusy(bool busy)
    {
        _batchInFlight = busy;
        JobsList.IsEnabled = !busy;
        StartAllButton.IsEnabled = _connected && !busy;
        PauseAllButton.IsEnabled = _connected && !busy;
        UpdateSelectionDetails();
        UpdateTrayCommands();
    }

    private async void OnCancelOrRemoveSelected(object sender, RoutedEventArgs e)
    {
        if (!_connected || _batchInFlight) return;
        var selected = JobsList.SelectedItems.OfType<DownloadJob>().ToArray();
        var eligible = selected.Where(job => job.CanControl &&
            (job.State is "queued" or "scheduled" or "downloading" or "paused" or "retry_wait" or "completed" or "failed" or "canceled"))
            .Select(job => new DownloadJob { JobId = job.JobId, Revision = job.Revision, State = job.State }).ToArray();
        if (eligible.Length == 0) return;
        var cancelCount = eligible.Count(job => job.State is "queued" or "scheduled" or "downloading" or "paused" or "retry_wait");
        var removeCount = eligible.Length - cancelCount;
        SetBatchBusy(true);
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Content.XamlRoot,
                Title = "Cancel or remove selected downloads?",
                Content = $"Cancel {cancelCount} transfer(s) and remove {removeCount} finished or failed entry/entries from history. " +
                    $"{selected.Length - eligible.Length} selected item(s) cannot be changed. Completed files are kept; unresumable partial data may be discarded.",
                PrimaryButtonText = "Continue",
                CloseButtonText = "Keep downloads",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            var failures = 0;
            foreach (var job in eligible)
            {
                try
                {
                    if (job.State is "queued" or "scheduled" or "downloading" or "paused" or "retry_wait")
                        await _engine.ControlJobAsync(job, "cancel");
                    else await _engine.DeleteJobAsync(job);
                }
                catch (Exception) { failures++; }
            }
            await RefreshAsync();
            ShowMessage($"{eligible.Length - failures} download(s) updated; {failures} could not be updated. Completed files were kept.",
                failures > 0 ? InfoBarSeverity.Warning : InfoBarSeverity.Informational);
        }
        finally { SetBatchBusy(false); }
    }

    private async Task ControlSelectedAsync(bool pause)
    {
        if (!_connected || _batchInFlight) return;
        var selected = JobsList.SelectedItems.OfType<DownloadJob>().ToArray();
        var eligible = selected.Where(job => job.CanControl && (pause
            ? job.State is "queued" or "scheduled" or "retry_wait" or "downloading"
            : job.State is "paused" or "retry_wait")).ToArray();
        if (eligible.Length == 0) return;
        SetBatchBusy(true);
        try
        {
            var failures = 0;
            foreach (var job in eligible)
            {
                job.SetLocalPending(true);
                try { await _engine.ControlJobAsync(job, pause ? "pause" : "resume"); }
                catch (Exception) { failures++; }
                finally { job.SetLocalPending(false); }
            }
            var succeeded = eligible.Length - failures;
            if (failures > 0 || eligible.Length < selected.Length)
                ShowMessage($"{succeeded} succeeded, {failures} failed, {selected.Length - eligible.Length} were not eligible. Review the selected downloads and retry if needed.", failures > 0 ? InfoBarSeverity.Warning : InfoBarSeverity.Informational);
            await RefreshAsync();
        }
        finally { SetBatchBusy(false); }
    }

    private async void OnStartAll(object sender, RoutedEventArgs e)
    {
        await ControlQueueScopeAsync(false);
    }

    private async void OnPauseAll(object sender, RoutedEventArgs e)
    {
        await ControlQueueScopeAsync(true);
    }

    private async Task ControlQueueScopeAsync(bool pause)
    {
        if (!_connected || _batchInFlight) return;
        var queueId = _category.StartsWith("queue:", StringComparison.Ordinal) ? _category[6..] : null;
        var jobs = _allJobs.Where(job => (queueId is null || job.QueueId == queueId) && job.CanControl && (pause
            ? job.State is "queued" or "scheduled" or "retry_wait" or "downloading"
            : job.State is "paused" or "retry_wait")).ToArray();
        SetBatchBusy(true);
        var failures = 0;
        try
        {
            foreach (var job in jobs)
            {
                job.SetLocalPending(true);
                try { await _engine.ControlJobAsync(job, pause ? "pause" : "resume"); }
                catch (Exception) { failures++; }
                finally { job.SetLocalPending(false); }
            }
            await RefreshAsync();
            if (failures > 0)
                ShowMessage($"{jobs.Length - failures} download(s) updated; {failures} could not be updated. Review their status and retry.", InfoBarSeverity.Warning);
        }
        finally { SetBatchBusy(false); }
    }

    private async Task ControlOneAsync(DownloadJob job, string action)
    {
        try { await _engine.ControlJobAsync(job, action); }
        catch (Exception error) { ShowMessage(error.Message, InfoBarSeverity.Error); }
    }

    private async Task ControlTrayDownloadsAsync(bool pause)
    {
        if (!_connected || _batchInFlight) return;
        var jobs = _allJobs.Where(job => job.CanControl && (pause
            ? job.State is "queued" or "scheduled" or "retry_wait" or "downloading"
            : job.State == "paused")).ToArray();
        SetBatchBusy(true);
        var failures = 0;
        try
        {
            foreach (var job in jobs)
            {
                job.SetLocalPending(true);
                try { await _engine.ControlJobAsync(job, pause ? "pause" : "resume"); }
                catch (Exception) { failures++; }
                finally { job.SetLocalPending(false); }
            }
            await RefreshAsync();
            if (failures > 0)
            {
                ShowMainWindow();
                ShowMessage($"{failures} download(s) could not be {(pause ? "paused" : "resumed")}. Check their status and try again.", InfoBarSeverity.Warning);
            }
        }
        finally { SetBatchBusy(false); }
    }

    private void UpdateTrayCommands()
    {
        _trayPause.Enabled = _connected && !_batchInFlight && _allJobs.Any(job => job.CanControl &&
            (job.State is "queued" or "scheduled" or "retry_wait" or "downloading"));
        _trayResume.Enabled = _connected && !_batchInFlight && _allJobs.Any(job => job.CanControl && job.State == "paused");
        _trayStopEngine.Enabled = _connected && !_batchInFlight && _engine.SupportsFeature("engine.shutdown-v1");
    }

    private async Task QuitAndStopEngineAsync()
    {
        if (!_connected || _batchInFlight || _closePromptOpen || !_engine.SupportsFeature("engine.shutdown-v1")) return;
        _closePromptOpen = true;
        ShowMainWindow();
        IReadOnlyList<DownloadJob> snapshot;
        try { snapshot = await _engine.ListJobsWithoutStartingAsync(); }
        catch (Exception error) { _closePromptOpen = false; ShowMessage("Could not check the engine before shutdown: " + error.Message, InfoBarSeverity.Error); return; }
        var affected = snapshot.Count(job => job.State is "queued" or "scheduled" or "retry_wait" or "downloading");
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = "Quit and stop the engine?",
            Content = $"{affected} active or waiting download(s) will be paused. Resumable partial data will be kept when supported; other transfers may need to restart. " +
                "Schedules will not run while the engine is stopped, and these downloads will need to be resumed after it starts again.",
            PrimaryButtonText = "Pause downloads and stop", CloseButtonText = "Keep running", DefaultButton = ContentDialogButton.Close,
        };
        ContentDialogResult choice;
        try { choice = await dialog.ShowAsync(); }
        catch (Exception error) { ShowMessage("Could not show the shutdown confirmation: " + error.Message, InfoBarSeverity.Error); return; }
        finally { _closePromptOpen = false; }
        if (choice != ContentDialogResult.Primary) return;
        _refreshTimer.Stop();
        SetBatchBusy(true);
        var unconfirmed = false;
        try
        {
            var deadline = DateTimeOffset.UtcNow.AddSeconds(30);
            while (_refreshInFlight && DateTimeOffset.UtcNow < deadline) await Task.Delay(100);
            if (_refreshInFlight) throw new TimeoutException("The current engine refresh did not finish.");
            while (true)
            {
                snapshot = await _engine.ListJobsWithoutStartingAsync();
                var pending = snapshot.Where(job => job.State is "queued" or "scheduled" or "retry_wait" or "downloading").ToArray();
                if (pending.Length == 0) break;
                foreach (var job in pending.Where(job => string.IsNullOrEmpty(job.RequestedControl)))
                    try { await _engine.ControlJobAsync(job, "pause"); }
                    catch (InvalidOperationException) { /* Refresh and retry changed jobs. */ }
                if (DateTimeOffset.UtcNow >= deadline) throw new TimeoutException("Some downloads did not pause. The engine is still running.");
                await Task.Delay(250);
            }
            while (true)
            {
                try { await _engine.ShutdownAsync(); break; }
                catch (InvalidOperationException error) when (error.Message.Contains("Pause active downloads", StringComparison.Ordinal) && DateTimeOffset.UtcNow < deadline)
                { await Task.Delay(250); }
            }
            _quitting = true;
            _trayIcon.Visible = false;
            Close();
        }
        catch (EngineClient.ShutdownUnconfirmedException error)
        {
            unconfirmed = true;
            _connected = false;
            _manualReconnectRequired = true;
            _taskbarProgress.Update([]);
            foreach (var job in _visibleJobs) job.MarkDisconnected();
            foreach (var worker in _workerRows) worker.MarkDisconnected();
            DownloadCommands.IsEnabled = false;
            SpeedLimitBox.IsEnabled = false;
            AggregateSpeed.Text = "Rate unavailable";
            EffectiveLimit.Text = "Effective cap unavailable";
            EngineIndicator.Fill = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.DarkOrange);
            ConnectionStatus.Text = "Engine shutdown could not be confirmed";
            ConnectionBar.IsOpen = true;
            ShowMessage(error.Message + " Automatic reconnection is paused. Reconnect manually; this will start the engine if it has stopped.", InfoBarSeverity.Warning);
        }
        catch (Exception error) { ShowMessage("The engine was not stopped. Some downloads may already be paused. " + error.Message, InfoBarSeverity.Error); }
        finally
        {
            if (!_quitting)
            {
                SetBatchBusy(false);
                if (!unconfirmed) _refreshTimer.Start();
            }
        }
    }

    private void OnJobsRightTapped(object sender, Microsoft.UI.Xaml.Input.RightTappedRoutedEventArgs e)
    {
        if (e.OriginalSource is not DependencyObject source) return;
        var node = source;
        while (node is not null && (node is not FrameworkElement element || element.DataContext is not DownloadJob))
            node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node);
        if (node is not FrameworkElement { DataContext: DownloadJob job } anchor) return;
        JobsList.SelectedItem = job;
        ShowJobMenu(anchor, job.JobId);
        e.Handled = true;
    }

    private void OnMoreActions(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string id } button) ShowJobMenu(button, id);
    }

    private void ShowJobMenu(FrameworkElement anchor, string id)
    {
        if (!_connected || _batchInFlight) return;
        var job = _allJobs.FirstOrDefault(item => item.JobId == id);
        if (job is null) return;
        var flyout = new MenuFlyout();
        void Add(string label, Action action)
        {
            var item = new MenuFlyoutItem { Text = label };
            item.Click += (_, _) => action();
            flyout.Items.Add(item);
        }
        if (job.CanControl && (job.State is "queued" or "scheduled" or "retry_wait" or "downloading")) Add("Pause", () => _ = RunJobActionAsync(job, "pause"));
        if (job.CanControl && (job.State is "paused" or "failed" or "retry_wait")) Add(job.State == "failed" ? "Retry" : "Resume", () => _ = RunJobActionAsync(job, job.State == "failed" ? "retry" : "resume"));
        if (job.CanControl && _category.StartsWith("queue:", StringComparison.Ordinal) && (job.State is "queued" or "scheduled" or "paused" or "retry_wait"))
        {
            var engineOrder = (SortBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() == "order";
            if (engineOrder)
            {
                var index = _allJobs.ToList().FindIndex(item => item.JobId == job.JobId);
                var before = Enumerable.Range(0, Math.Max(0, index)).Reverse().FirstOrDefault(i => _allJobs[i].QueueId == job.QueueId && (_allJobs[i].State is "queued" or "scheduled" or "paused" or "retry_wait"), -1);
                var after = Enumerable.Range(index + 1, Math.Max(0, _allJobs.Count - index - 1)).FirstOrDefault(i => _allJobs[i].QueueId == job.QueueId && (_allJobs[i].State is "queued" or "scheduled" or "paused" or "retry_wait"), -1);
                if (before >= 0) Add("Move up in queue", () => _ = ReorderAsync(job, before));
                if (after >= 0) Add("Move down in queue", () => _ = ReorderAsync(job, after));
            }
            else Add("Switch to engine order to reorder", () => SortBox.SelectedIndex = 0);
        }
        Add("Copy source URL", () => { var package = new Windows.ApplicationModel.DataTransfer.DataPackage(); package.SetText(job.Url); Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package); });
        if (job.State == "completed" && !string.IsNullOrWhiteSpace(job.Name))
        {
            var filePath = Path.GetFullPath(Path.Combine(job.Destination, job.Name));
            var destinationRoot = Path.GetFullPath(job.Destination).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (filePath.StartsWith(destinationRoot, StringComparison.OrdinalIgnoreCase) && File.Exists(filePath))
            {
                Add("Open file", () =>
                {
                    try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(filePath) { UseShellExecute = true }); }
                    catch (Exception error) { ShowMessage(error.Message, InfoBarSeverity.Error); }
                });
                Add("Show in File Explorer", () =>
                {
                    try
                    {
                        var launch = new System.Diagnostics.ProcessStartInfo("explorer.exe") { UseShellExecute = false };
                        launch.ArgumentList.Add("/select,"); launch.ArgumentList.Add(filePath);
                        System.Diagnostics.Process.Start(launch);
                    }
                    catch (Exception error) { ShowMessage(error.Message, InfoBarSeverity.Error); }
                });
            }
        }
        if (Uri.TryCreate(job.ReferenceUrl, UriKind.Absolute, out var reference) && (reference.Scheme is "http" or "https"))
            Add("Open reference page", () =>
            {
                try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(reference.AbsoluteUri) { UseShellExecute = true }); }
                catch (Exception error) { ShowMessage(error.Message, InfoBarSeverity.Error); }
            });
        if (job.CanControl && !job.IsTorrent && (job.State is "paused" or "failed" or "queued" or "scheduled" or "retry_wait"))
            Add("Replace download link…", () => _ = ReplaceSourceAsync(job));
        if (job.CanControl && !job.IsTorrent && Uri.TryCreate(job.Url, UriKind.Absolute, out var limitUri) && (limitUri.Scheme is "http" or "https"))
            Add("Download speed limit…", () => _ = EditJobBandwidthAsync(job));
        if (job.CanControl && (job.State is "queued" or "scheduled" or "downloading" or "paused" or "retry_wait")) Add("Cancel", () => _ = RunJobActionAsync(job, "cancel"));
        if (job.CanControl && _settings?["queues"] is JsonArray queues && queues.Count > 1)
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
        flyout.ShowAt(anchor);
    }

    private async Task EditJobBandwidthAsync(DownloadJob job)
    {
        var limit = new NumberBox { Header = "Limit in MB/s (0 = unlimited)", Minimum = 0, Maximum = 1_000_000,
            Value = job.BandwidthLimit / 1_000_000d, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        var explanation = new TextBlock { Text = "The global and scheduled limits also apply. The most restrictive limit takes effect.", TextWrapping = TextWrapping.Wrap };
        var error = new InfoBar { IsOpen = false, Severity = InfoBarSeverity.Error };
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(limit); panel.Children.Add(explanation); panel.Children.Add(error);
        var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Download speed limit", Content = panel,
            PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            dialog.IsPrimaryButtonEnabled = false;
            try
            {
                if (!double.IsFinite(limit.Value) || limit.Value < 0 || limit.Value > 1_000_000 ||
                    (limit.Value > 0 && limit.Value < 0.000001))
                { error.Message = "Enter 0 or a limit from 0.000001 to 1,000,000 MB/s."; error.IsOpen = true; limit.Focus(FocusState.Programmatic); return; }
                var bytes = (ulong)Math.Round(limit.Value * 1_000_000, MidpointRounding.AwayFromZero);
                await _engine.SetJobBandwidthAsync(job, bytes);
                dialog.Hide();
                await RefreshAsync();
            }
            catch (Exception failure) { error.Message = failure.Message; error.IsOpen = true; }
            finally { dialog.IsPrimaryButtonEnabled = true; deferral.Complete(); }
        };
        await dialog.ShowAsync();
    }

    private async Task ReplaceSourceAsync(DownloadJob job)
    {
        var url = new TextBox { Header = "Replacement URL", PlaceholderText = "https://example.com/file" };
        var warning = new TextBlock { Text = "Replacing this link discards the existing partial download and restarts from the beginning. A matching name or size does not prove that the content is the same.", TextWrapping = TextWrapping.Wrap };
        var error = new InfoBar { IsOpen = false, Severity = InfoBarSeverity.Error };
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(warning); panel.Children.Add(url); panel.Children.Add(error);
        var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Replace download link",
            Content = panel, PrimaryButtonText = "Discard partial data and restart", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            dialog.IsPrimaryButtonEnabled = false;
            try
            {
                if (!Uri.TryCreate(url.Text.Trim(), UriKind.Absolute, out var replacement) ||
                    replacement.Scheme is not ("http" or "https") || string.IsNullOrEmpty(replacement.Host) || !string.IsNullOrEmpty(replacement.UserInfo))
                { error.Message = "Enter a valid HTTP or HTTPS link without embedded credentials."; error.IsOpen = true; url.Focus(FocusState.Programmatic); return; }
                await _engine.ReplaceSourceAsync(job, url.Text.Trim());
                dialog.Hide();
                await RefreshAsync();
            }
            catch (Exception failure) { error.Message = failure.Message; error.IsOpen = true; }
            finally { dialog.IsPrimaryButtonEnabled = true; deferral.Complete(); }
        };
        await dialog.ShowAsync();
    }

    private async Task ReorderAsync(DownloadJob job, int position)
    {
        try { await _engine.ReorderJobAsync(job, position); }
        catch (Exception error) { ShowMessage(error.Message, InfoBarSeverity.Error); }
        await RefreshAsync();
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
        EmptyState.Visibility = !show && _visibleJobs.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        CloseDetailsButton.Visibility = Visibility.Visible;
        if (JobsList.Columns.Count < 6) return;
        var available = Math.Max(0, grid.ActualWidth - (show && wide ? 314 : 0));
        _compactEta = available < 1050;
        _compactSpeed = available < 900;
        _compactSize = available < 790;
        JobsList.Columns[4].Visibility = _compactEta ? Visibility.Collapsed : Visibility.Visible;
        JobsList.Columns[3].Visibility = _compactSpeed ? Visibility.Collapsed : Visibility.Visible;
        JobsList.Columns[2].Visibility = _compactSize ? Visibility.Collapsed : Visibility.Visible;
        JobsList.Columns[5].Visibility = available < 570 ? Visibility.Collapsed : Visibility.Visible;
        foreach (var job in _visibleJobs) job.SetCompactMetrics(_compactSize, _compactSpeed, _compactEta);
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
            !double.TryParse(item.Tag?.ToString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var megabytes) ||
            !double.IsFinite(megabytes) || megabytes < 0 || megabytes > 1_000_000) return;
        _ = SaveSettingsAsync(settings => settings["bandwidth_limit_bytes_per_second"] = (ulong)Math.Round(megabytes * 1_000_000));
    }

    private async Task CreateQueueAsync()
    {
        if (!_connected || _settings?["queues"] is not JsonArray queues) return;
        var number = 1;
        while (queues.OfType<JsonObject>().Any(queue => string.Equals(queue["name"]?.GetValue<string>(), $"queue #{number}", StringComparison.OrdinalIgnoreCase))) number++;
        var name = new TextBox { Header = "Queue name", Text = $"queue #{number}", MaxLength = 80 };
        var count = new NumberBox { Header = "Maximum active downloads", Minimum = 1, Maximum = 32, Value = 4, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        var error = new InfoBar { IsOpen = false, Severity = InfoBarSeverity.Error };
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(name); panel.Children.Add(count); panel.Children.Add(error);
        var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Create queue", Content = panel,
            PrimaryButtonText = "Create", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
        dialog.Opened += (_, _) => { name.Focus(FocusState.Programmatic); name.SelectAll(); };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            dialog.IsPrimaryButtonEnabled = false;
            try
            {
                var queueName = name.Text.Trim();
                if (queueName.Length == 0) { error.Message = "Enter a queue name."; error.IsOpen = true; name.Focus(FocusState.Programmatic); return; }
                if (double.IsNaN(count.Value) || count.Value < 1 || count.Value > 32 || count.Value != Math.Truncate(count.Value))
                { error.Message = "Enter a whole number from 1 to 32."; error.IsOpen = true; count.Focus(FocusState.Programmatic); return; }
                var id = "queue-" + Guid.NewGuid().ToString("N");
                var saved = await SaveSettingsAsync(settings =>
                {
                    if (settings["queues"] is not JsonArray list) throw new InvalidOperationException("Queue settings are unavailable.");
                    if (list.OfType<JsonObject>().Any(queue => string.Equals(queue["name"]?.GetValue<string>(), queueName, StringComparison.OrdinalIgnoreCase)))
                        throw new InvalidOperationException("A queue with this name already exists.");
                    list.Add(new JsonObject
                    {
                        ["id"] = id, ["name"] = queueName, ["max_active"] = (int)count.Value,
                        ["schedule_enabled"] = false,
                        ["schedule_slots"] = new JsonArray(Enumerable.Repeat(true, 168).Select(value => (JsonNode?)JsonValue.Create(value)).ToArray()),
                        ["finish_action"] = "none",
                    });
                });
                if (!saved) { error.Message = SettingsMessage.Message?.ToString() ?? "Could not save the queue."; error.IsOpen = true; return; }
                UpdateQueues();
                _category = "queue:" + id;
                SettingsView.Visibility = Visibility.Collapsed;
                Workspace.Visibility = Visibility.Visible;
                SectionTitle.Text = queueName;
                StartAllButton.Label = "Resume this queue"; PauseAllButton.Label = "Pause this queue";
                AppNavigation.SelectedItem = AppNavigation.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(item => item.Tag?.ToString() == _category);
                ApplyFilter();
                dialog.Hide();
            }
            finally { dialog.IsPrimaryButtonEnabled = true; deferral.Complete(); }
        };
        await dialog.ShowAsync();
        AppNavigation.SelectedItem = AppNavigation.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(item => item.Tag?.ToString() == _category);
    }

    private void PopulateQueueChoices(ComboBox control)
    {
        if (_settings?["queues"] is JsonArray queues)
            foreach (var item in queues.OfType<JsonObject>())
                control.Items.Add(new ComboBoxItem { Content = item["name"]?.GetValue<string>() ?? "main", Tag = item["id"]?.GetValue<string>() ?? "main" });
        control.SelectedItem = control.Items.OfType<ComboBoxItem>().FirstOrDefault(item => item.Tag?.ToString() == _lastQueueId)
            ?? control.Items.OfType<ComboBoxItem>().FirstOrDefault(item => item.Tag?.ToString() == "main");
    }

    private async Task ShowBrowserBatchAsync(BrowserRequest request)
    {
        var panel = new StackPanel { Spacing = 8 };
        var notice = new TextBlock { Text = "Choose which links to add. Torrent links open a separate review.", TextWrapping = TextWrapping.Wrap };
        var error = new InfoBar { IsOpen = false, Severity = InfoBarSeverity.Error };
        var folder = new TextBox { Header = "Destination folder", Text = string.IsNullOrWhiteSpace(ReadString("default_download_folder"))
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads") : ReadString("default_download_folder") };
        var chooseFolder = new Button { Content = "Choose folder…", HorizontalAlignment = HorizontalAlignment.Left };
        chooseFolder.Click += (_, _) =>
        {
            using var picker = new System.Windows.Forms.FolderBrowserDialog { SelectedPath = folder.Text, Description = "Choose a download destination" };
            if (picker.ShowDialog() == System.Windows.Forms.DialogResult.OK) folder.Text = picker.SelectedPath;
        };
        var queue = new ComboBox { Header = "Queue", MinWidth = 200 };
        PopulateQueueChoices(queue);
        var checks = new CheckBox[request.Urls.Length];
        var keys = request.Urls.Select(_ => Guid.NewGuid().ToString()).ToArray();
        var completed = new bool[request.Urls.Length];
        var pendingTorrents = new List<(string Url, string? Reference)>();
        var filter = new TextBox { Header = "Filter links", PlaceholderText = "Search shown host and path" };
        var selectionStatus = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var all = new Button { Content = "Select visible" };
        var none = new Button { Content = "Clear visible" };
        controls.Children.Add(all); controls.Children.Add(none);
        panel.Children.Add(notice); panel.Children.Add(error); panel.Children.Add(folder); panel.Children.Add(chooseFolder); panel.Children.Add(queue); panel.Children.Add(filter); panel.Children.Add(controls); panel.Children.Add(selectionStatus);
        void UpdateSelectionStatus()
        {
            var selected = checks.Count(check => check is not null && check.IsEnabled && check.IsChecked == true);
            var visible = checks.Count(check => check is not null && check.IsEnabled && check.Visibility == Visibility.Visible);
            selectionStatus.Text = $"{selected} selected, including hidden links · {visible} available in this view";
        }
        for (var index = 0; index < request.Urls.Length; index++)
        {
            var uri = new Uri(request.Urls[index]);
            var label = uri.Scheme == "magnet" ? "Magnet link" : uri.Host + uri.AbsolutePath;
            checks[index] = new CheckBox { Content = label, IsChecked = true };
            checks[index].Checked += (_, _) => UpdateSelectionStatus();
            checks[index].Unchecked += (_, _) => UpdateSelectionStatus();
            panel.Children.Add(checks[index]);
        }
        filter.TextChanged += (_, _) =>
        {
            var query = filter.Text.Trim();
            foreach (var check in checks)
                check.Visibility = string.IsNullOrEmpty(query) || (check.Content?.ToString() ?? "").Contains(query, StringComparison.OrdinalIgnoreCase) ? Visibility.Visible : Visibility.Collapsed;
            UpdateSelectionStatus();
        };
        all.Click += (_, _) => { for (var i = 0; i < checks.Length; i++) if (!completed[i] && checks[i].Visibility == Visibility.Visible) checks[i].IsChecked = true; };
        none.Click += (_, _) => { foreach (var check in checks) if (check.Visibility == Visibility.Visible) check.IsChecked = false; };
        UpdateSelectionStatus();
        var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Review browser links", Content = new ScrollViewer { Content = panel, MaxHeight = 500 }, PrimaryButtonText = "Add selected", CloseButtonText = "Cancel" };
        dialog.Opened += (_, _) => TraceBrowserReview("opened", request.Key, "batch");
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            dialog.IsPrimaryButtonEnabled = false;
            try
            {
                if (!Path.IsPathFullyQualified(folder.Text) || !Directory.Exists(folder.Text)) throw new InvalidOperationException("Choose an existing destination folder.");
                if (pendingTorrents.Count == 0 && !checks.Where((check, index) => check.IsChecked == true && !completed[index]).Any())
                    throw new InvalidOperationException("Select at least one link.");
                var queueId = (queue.SelectedItem as ComboBoxItem)?.Tag?.ToString();
                if (string.IsNullOrEmpty(queueId)) throw new InvalidOperationException("Queue settings are unavailable. Reconnect and try again.");
                for (var index = 0; index < checks.Length; index++)
                {
                    if (checks[index].IsChecked != true || completed[index]) continue;
                    var url = request.Urls[index];
                    var uri = new Uri(url);
                    if (uri.Scheme == "magnet" || uri.AbsolutePath.EndsWith(".torrent", StringComparison.OrdinalIgnoreCase))
                        pendingTorrents.Add((url, request.Reference));
                    else
                        await _engine.AddJobAsync(url, null, folder.Text.Trim(), 0, queueId, keys[index], referenceUrl: request.Reference);
                    completed[index] = true; checks[index].IsEnabled = false; checks[index].IsChecked = false;
                }
                RememberQueue(queueId);
                foreach (var torrent in pendingTorrents) _torrentActivations.Enqueue(torrent);
                pendingTorrents.Clear();
                dialog.Hide();
                await RefreshAsync();
            }
            catch (Exception failure)
            {
                var added = completed.Count(value => value) - pendingTorrents.Count;
                error.Message = $"{added} download(s) added. Remaining selections can be retried. {failure.Message}";
                error.IsOpen = true;
            }
            finally { dialog.IsPrimaryButtonEnabled = true; deferral.Complete(); }
        };
        await dialog.ShowAsync();
    }

    private async void OnAddTorrent(object sender, RoutedEventArgs e) => await ShowAddTorrentAsync(null);

    private async Task ShowAddTorrentAsync(string? initialSource, string? referenceUrl = null)
    {
        if (!_connected) return;
        var source = new TextBox { Header = "Magnet link or .torrent file URL", PlaceholderText = "magnet:?xt=…", Text = initialSource ?? "" };
        var choose = new Button { Content = "Choose torrent file…", HorizontalAlignment = HorizontalAlignment.Left };
        choose.Click += (_, _) =>
        {
            using var picker = new System.Windows.Forms.OpenFileDialog { Filter = "Torrent files (*.torrent)|*.torrent", CheckFileExists = true };
            if (picker.ShowDialog() == System.Windows.Forms.DialogResult.OK) source.Text = new Uri(picker.FileName).AbsoluteUri.Replace("file:", "torrent-file:", StringComparison.OrdinalIgnoreCase);
        };
        var status = new InfoBar { IsOpen = false, Severity = InfoBarSeverity.Informational };
        var inspect = new Button { Content = "Load torrent information", HorizontalAlignment = HorizontalAlignment.Left };
        var name = new TextBox { Header = "Name" };
        var folder = new TextBox { Header = "Destination folder", Text = string.IsNullOrWhiteSpace(ReadString("default_download_folder"))
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads") : ReadString("default_download_folder") };
        var queue = new ComboBox { Header = "Queue", MinWidth = 200 };
        PopulateQueueChoices(queue);
        var chooseDestination = new Button { Content = "Choose folder…", HorizontalAlignment = HorizontalAlignment.Left };
        chooseDestination.Click += (_, _) =>
        {
            using var picker = new System.Windows.Forms.FolderBrowserDialog { SelectedPath = folder.Text, Description = "Choose a torrent destination" };
            if (picker.ShowDialog() == System.Windows.Forms.DialogResult.OK) folder.Text = picker.SelectedPath;
        };
        var trackers = new TextBox { Header = "Trackers (one URL per line)", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 100 };
        var fileChoices = new List<TorrentFileChoice>();
        var fileFilter = new TextBox { Header = "Filter files", PlaceholderText = "Search file paths" };
        var fileSummary = new TextBlock { Text = "Load metadata to review files.", TextWrapping = TextWrapping.Wrap };
        var folderTree = new TreeView { Height = 130, SelectionMode = TreeViewSelectionMode.Single };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(folderTree, "Torrent folders");
        var folderPaths = new Dictionary<TreeViewNode, string>();
        string selectedFolder = "";
        var fileList = new ListView { Height = 220, SelectionMode = ListViewSelectionMode.None,
            ItemTemplate = (DataTemplate)((FrameworkElement)Content).Resources["TorrentFileTemplate"] };
        var selectVisible = new Button { Content = "Select visible" };
        var clearVisible = new Button { Content = "Clear visible" };
        var fileActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        fileActions.Children.Add(selectVisible); fileActions.Children.Add(clearVisible);
        bool bulkFileChange = false;
        void UpdateFileSummary() => fileSummary.Text = $"{fileChoices.Count(item => item.Selected)} of {fileChoices.Count} files selected, including hidden files.";
        void FilterFiles()
        {
            var query = fileFilter.Text.Trim();
            fileList.ItemsSource = fileChoices.Where(item =>
                (string.IsNullOrEmpty(selectedFolder) || item.Path.StartsWith(selectedFolder + "/", StringComparison.Ordinal)) &&
                (string.IsNullOrEmpty(query) || item.Path.Contains(query, StringComparison.OrdinalIgnoreCase))).ToArray();
            UpdateFileSummary();
        }
        void BuildFolderTree()
        {
            selectedFolder = "";
            folderPaths.Clear();
            folderTree.RootNodes.Clear();
            var root = new TreeViewNode { Content = "All files", IsExpanded = true };
            folderTree.RootNodes.Add(root);
            folderPaths[root] = "";
            var directories = new Dictionary<string, TreeViewNode>(StringComparer.Ordinal) { [""] = root };
            foreach (var file in fileChoices)
            {
                var components = file.Path.Split('/');
                var prefix = "";
                for (var index = 0; index < components.Length - 1; index++)
                {
                    var parent = prefix;
                    prefix = prefix.Length == 0 ? components[index] : prefix + "/" + components[index];
                    if (directories.ContainsKey(prefix)) continue;
                    var node = new TreeViewNode { Content = components[index] };
                    directories[parent].Children.Add(node);
                    directories[prefix] = node;
                    folderPaths[node] = prefix;
                }
            }
        }
        void SetVisibleFiles(bool selected)
        {
            bulkFileChange = true;
            try { foreach (var item in (fileList.ItemsSource as IEnumerable<TorrentFileChoice>) ?? []) item.Selected = selected; }
            finally { bulkFileChange = false; }
            UpdateFileSummary();
        }
        fileFilter.TextChanged += (_, _) => FilterFiles();
        folderTree.SelectionChanged += (_, _) =>
        {
            var node = folderTree.SelectedNodes.FirstOrDefault();
            selectedFolder = node is not null && folderPaths.TryGetValue(node, out var path) ? path : "";
            FilterFiles();
        };
        selectVisible.Click += (_, _) => SetVisibleFiles(true);
        clearVisible.Click += (_, _) => SetVisibleFiles(false);
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(source); panel.Children.Add(choose); panel.Children.Add(inspect); panel.Children.Add(status);
        panel.Children.Add(name); panel.Children.Add(folder); panel.Children.Add(chooseDestination); panel.Children.Add(queue); panel.Children.Add(trackers);
        panel.Children.Add(new TextBlock { Text = "Files", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        panel.Children.Add(new TextBlock { Text = "Folders" });
        panel.Children.Add(folderTree); panel.Children.Add(fileFilter); panel.Children.Add(fileActions); panel.Children.Add(fileSummary); panel.Children.Add(fileList);
        var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Add torrent", Content = new ScrollViewer { Content = panel, MaxHeight = 500 },
            PrimaryButtonText = "Add to queue", CloseButtonText = "Cancel", IsPrimaryButtonEnabled = false };
        var cancellation = new CancellationTokenSource();
        var idempotencyKey = Guid.NewGuid().ToString();
        string? preparedUrl = null, hash = null, preparedSource = null;
        var originalTrackers = Array.Empty<string>();
        var filePaths = new List<string>();
        source.TextChanged += (_, _) =>
        {
            if (preparedSource == source.Text.Trim()) return;
            preparedUrl = null; hash = null; dialog.IsPrimaryButtonEnabled = false;
            status.IsOpen = false;
            filePaths.Clear(); fileChoices.Clear(); BuildFolderTree(); FilterFiles();
        };
        async Task LoadTorrentAsync()
        {
            var requested = source.Text.Trim();
            preparedUrl = null; hash = null; preparedSource = null; filePaths.Clear(); fileChoices.Clear(); BuildFolderTree(); FilterFiles();
            dialog.IsPrimaryButtonEnabled = false; inspect.IsEnabled = false; source.IsEnabled = false; choose.IsEnabled = false;
            status.Severity = InfoBarSeverity.Informational; status.Message = "Retrieving torrent metadata…"; status.IsOpen = true;
            try
            {
                var first = await _engine.PrepareTorrentAsync(requested, cancellationToken: cancellation.Token);
                var expectedHash = first["torrent_info_hash"]?.GetValue<string>() ?? throw new InvalidDataException("Torrent metadata has no info hash.");
                var count = first["torrent_file_count"]?.GetValue<int>() ?? throw new InvalidDataException("Torrent metadata has no file count.");
                if (count is < 1 or > 10000 || expectedHash.Length != 40) throw new InvalidDataException("Invalid torrent metadata.");
                var previewUrl = first["final_url"]?.GetValue<string>() ?? throw new InvalidDataException("Torrent metadata has no preview source.");
                var page = first;
                while (true)
                {
                    if (page["torrent_info_hash"]?.GetValue<string>() != expectedHash || page["torrent_file_count"]?.GetValue<int>() != count)
                        throw new InvalidDataException("Torrent metadata changed during review. Try again.");
                    if (page["torrent_files"] is JsonArray entries)
                        foreach (var entry in entries.OfType<JsonObject>())
                        {
                            var path = entry["path"]?.GetValue<string>() ?? throw new InvalidDataException("Invalid torrent file path.");
                            var length = entry["length"]?.GetValue<string>();
                            if (!ulong.TryParse(length, out var bytes)) throw new InvalidDataException("Invalid torrent file size.");
                            if (filePaths.Count >= count) throw new InvalidDataException("Invalid torrent file count.");
                            filePaths.Add(path);
                            var choice = new TorrentFileChoice { Path = path, SizeText = $"{bytes:N0} bytes" };
                            choice.PropertyChanged += (_, _) => { if (!bulkFileChange) UpdateFileSummary(); };
                            fileChoices.Add(choice);
                        }
                    var next = page["torrent_next_offset"]?.GetValue<string>();
                    if (next is null) break;
                    if (!int.TryParse(next, out var offset) || offset != filePaths.Count || offset >= count) throw new InvalidDataException("Invalid torrent metadata page.");
                    page = await _engine.PrepareTorrentAsync(previewUrl, offset: offset, cancellationToken: cancellation.Token);
                }
                if (filePaths.Count != count || count == 0) throw new InvalidDataException("The torrent file list is incomplete.");
                BuildFolderTree(); FilterFiles();
                originalTrackers = (first["torrent_trackers"] as JsonArray)?.Select(item => item?.GetValue<string>() ?? "").ToArray() ?? [];
                trackers.Text = string.Join(Environment.NewLine, originalTrackers);
                name.Text = first["suggested_name"]?.GetValue<string>() ?? "";
                preparedUrl = previewUrl; hash = expectedHash; preparedSource = requested;
                status.Message = $"Metadata verified. Review {count} file(s) and trackers before adding.";
                dialog.IsPrimaryButtonEnabled = true;
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { status.Severity = InfoBarSeverity.Error; status.Message = error.Message; }
            finally { inspect.IsEnabled = true; source.IsEnabled = true; choose.IsEnabled = true; }
        }
        inspect.Click += async (_, _) => await LoadTorrentAsync();
        if (initialSource is not null) dialog.Opened += async (_, _) => await LoadTorrentAsync();
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            dialog.IsPrimaryButtonEnabled = false;
            try
            {
                if (preparedUrl is null || hash is null || preparedSource != source.Text.Trim()) throw new InvalidOperationException("Load torrent information first.");
                if (!Path.IsPathFullyQualified(folder.Text) || !Directory.Exists(folder.Text)) throw new InvalidOperationException("Enter an existing destination folder.");
                var selected = fileChoices.Where(item => item.Selected).Select(item => item.Path).ToArray();
                if (selected.Length == 0) throw new InvalidOperationException("Select at least one file.");
                var edited = trackers.Text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                if (edited.Length > 32) throw new InvalidOperationException("Use at most 32 trackers.");
                var finalUrl = preparedUrl;
                if (!edited.SequenceEqual(originalTrackers))
                {
                    var updated = await _engine.PrepareTorrentAsync(preparedUrl, edited, cancellationToken: cancellation.Token);
                    if (updated["torrent_info_hash"]?.GetValue<string>() != hash) throw new InvalidDataException("Torrent identity changed; load the metadata again.");
                    finalUrl = updated["final_url"]?.GetValue<string>() ?? throw new InvalidDataException("Missing torrent preview source.");
                }
                var queueId = (queue.SelectedItem as ComboBoxItem)?.Tag?.ToString();
                if (string.IsNullOrEmpty(queueId)) throw new InvalidOperationException("Queue settings are unavailable. Reconnect and try again.");
                await _engine.AddTorrentAsync(finalUrl, name.Text.Trim(), folder.Text.Trim(), queueId, hash, selected.Length == filePaths.Count ? null : selected, idempotencyKey, referenceUrl, cancellation.Token);
                RememberQueue(queueId); dialog.Hide(); await RefreshAsync();
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { status.Severity = InfoBarSeverity.Error; status.Message = error.Message; status.IsOpen = true; }
            finally { dialog.IsPrimaryButtonEnabled = preparedUrl is not null; deferral.Complete(); }
        };
        await dialog.ShowAsync();
        cancellation.Cancel(); cancellation.Dispose();
    }

    private async void OnAddDownload(object sender, RoutedEventArgs e) => await ShowAddDownloadAsync(null, null, null);

    private async Task ShowAddDownloadAsync(string? initialUrl, string? referenceUrl, string? requestKey)
    {
        var destination = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var url = new TextBox { Header = "URL", PlaceholderText = "https://example.com/file.zip", Text = initialUrl ?? "" };
        var name = new TextBox { Header = "File name" };
        var checksum = new TextBox { Header = "SHA-256 checksum (optional)", PlaceholderText = "64 hexadecimal characters" };
        var probeSummary = new TextBlock { Text = "Paste a link to inspect it.", TextWrapping = TextWrapping.Wrap, Opacity = 0.7 };
        var configuredFolder = ReadString("default_download_folder");
        var folder = new TextBox { Header = "Destination folder", Text = string.IsNullOrWhiteSpace(configuredFolder) ? Path.Combine(destination, "Downloads") : configuredFolder };
        var priority = new ComboBox { Header = "Queue priority", SelectedIndex = 1 };
        priority.Items.Add(new ComboBoxItem { Content = "Low" });
        priority.Items.Add(new ComboBoxItem { Content = "Normal" });
        priority.Items.Add(new ComboBoxItem { Content = "High" });
        var queueChoice = new ComboBox { Header = "Queue", MinWidth = 200 };
        PopulateQueueChoices(queueChoice);
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(url);
        panel.Children.Add(probeSummary);
        panel.Children.Add(name);
        var chooseFolder = new Button { Content = "Choose folder…", HorizontalAlignment = HorizontalAlignment.Left };
        chooseFolder.Click += (_, _) =>
        {
            using var picker = new System.Windows.Forms.FolderBrowserDialog { SelectedPath = folder.Text, Description = "Choose a download destination" };
            if (picker.ShowDialog() == System.Windows.Forms.DialogResult.OK) folder.Text = picker.SelectedPath;
        };
        panel.Children.Add(folder);
        panel.Children.Add(chooseFolder);
        panel.Children.Add(queueChoice);
        panel.Children.Add(priority);
        panel.Children.Add(checksum);
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
        string? suggestedFileName = null;
        bool applyingSuggestion = false;
        name.TextChanged += (_, _) =>
        {
            if (!applyingSuggestion) suggestedFileName = null;
        };
        async Task ProbeUrlAsync()
        {
            probeCancellation?.Cancel();
            probeCancellation?.Dispose();
            probeCancellation = new CancellationTokenSource();
            var token = probeCancellation.Token;
            var text = url.Text.Trim();
            if (!Uri.TryCreate(text, UriKind.Absolute, out var source) || source.Scheme is not ("http" or "https" or "ftp" or "ftps") || !string.IsNullOrEmpty(source.UserInfo))
            {
                probeSummary.Text = "Enter an HTTP, HTTPS, FTP, or FTPS link without embedded credentials.";
                return;
            }
            probeSummary.Text = "Inspecting link…";
            try
            {
                await Task.Delay(400, token);
                var result = await _engine.ProbeAsync(text, token);
                if (token.IsCancellationRequested || url.Text.Trim() != text) return;
                var suggestedName = result["suggested_name"]?.GetValue<string>() ?? "";
                if (string.IsNullOrWhiteSpace(name.Text) && !string.IsNullOrWhiteSpace(suggestedName))
                {
                    applyingSuggestion = true;
                    try { name.Text = suggestedName; suggestedFileName = suggestedName; }
                    finally { applyingSuggestion = false; }
                }
                var final = result["final_url"]?.GetValue<string>() ?? text;
                var total = result["total_bytes"]?.GetValue<string>();
                var size = ulong.TryParse(total, out var bytes) ? $"{bytes / 1_000_000d:0.#} MB" : "Size unknown";
                var resume = result["resume_supported"]?.GetValue<bool>() == true ? "Resume available" : "Resume unavailable";
                var parallel = result["multipart_supported"]?.GetValue<bool>() == true ? "Parallel download available" : "Single connection";
                var warning = source.Scheme == "ftp" ? "\nFTP uses clear-text transport. Only anonymous FTP is supported." :
                    source.Scheme == "ftps" ? "\nFTPS uses encrypted transport. Only anonymous FTPS is supported." : "";
                probeSummary.Text = $"{size} · {resume} · {parallel}" + (final == text ? "" : $"\nRedirects to {(Uri.TryCreate(final, UriKind.Absolute, out var redirected) ? redirected.Host : "another server")}") + warning;
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { if (!token.IsCancellationRequested) probeSummary.Text = $"Could not inspect link: {error.Message}"; }
        }
        url.TextChanged += async (_, _) =>
        {
            if (suggestedFileName is not null && name.Text == suggestedFileName)
            {
                applyingSuggestion = true;
                try { name.Text = ""; suggestedFileName = null; }
                finally { applyingSuggestion = false; }
            }
            await ProbeUrlAsync();
        };
        dialog.Closed += (_, _) => { probeCancellation?.Cancel(); };
        if (initialUrl is not null) dialog.Opened += async (_, _) => await ProbeUrlAsync();
        if (requestKey is not null) dialog.Opened += (_, _) => TraceBrowserReview("opened", requestKey, "add");
        var idempotencyKey = requestKey ?? Guid.NewGuid().ToString();
        var formError = new InfoBar { IsOpen = false, Severity = InfoBarSeverity.Error };
        panel.Children.Insert(0, formError);
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            dialog.IsPrimaryButtonEnabled = false;
            try
            {
                if (!Uri.TryCreate(url.Text.Trim(), UriKind.Absolute, out var parsed) ||
                    parsed.Scheme is not ("http" or "https" or "ftp" or "ftps") || string.IsNullOrWhiteSpace(parsed.Host) || !string.IsNullOrEmpty(parsed.UserInfo))
                {
                    formError.Message = "Enter a valid HTTP, HTTPS, FTP, or FTPS URL without embedded credentials.";
                    formError.IsOpen = true;
                    url.Focus(FocusState.Programmatic);
                    return;
                }
                if (!Path.IsPathFullyQualified(folder.Text) || !Directory.Exists(folder.Text))
                {
                    formError.Message = "Choose an existing destination folder.";
                    formError.IsOpen = true;
                    folder.Focus(FocusState.Programmatic);
                    return;
                }
                var digest = checksum.Text.Trim();
                if (digest.Length != 0 && (digest.Length != 64 || !digest.All(Uri.IsHexDigit)))
                {
                    formError.Message = "Enter a 64-character hexadecimal SHA-256 checksum.";
                    formError.IsOpen = true;
                    checksum.Focus(FocusState.Programmatic);
                    return;
                }
                var selectedPriority = priority.SelectedIndex switch { 0 => -1, 2 => 1, _ => 0 };
                var selectedQueue = (queueChoice.SelectedItem as ComboBoxItem)?.Tag?.ToString();
                if (string.IsNullOrEmpty(selectedQueue)) throw new InvalidOperationException("Queue settings are unavailable. Reconnect and try again.");
                await _engine.AddJobAsync(url.Text.Trim(), name.Text.Trim(), folder.Text.Trim(), selectedPriority, selectedQueue, idempotencyKey, digest.Length == 0 ? null : digest, referenceUrl);
                RememberQueue(selectedQueue);
                dialog.Hide();
                await RefreshAsync();
            }
            catch (Exception error)
            {
                formError.Message = error.Message;
                formError.IsOpen = true;
            }
            finally
            {
                dialog.IsPrimaryButtonEnabled = true;
                deferral.Complete();
            }
        };
        await dialog.ShowAsync();
        probeCancellation?.Cancel();
        probeCancellation?.Dispose();
    }

    private void ShowMessage(string message, InfoBarSeverity severity)
    {
        MessageBar.Message = message;
        MessageBar.Severity = severity;
        MessageBar.IsOpen = true;
    }
}
