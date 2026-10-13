using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Dispatching;

namespace SpeedDownload;

public sealed partial class MainWindow : Window
{
    private readonly EngineClient _engine = new();
    private readonly DispatcherQueueTimer _refreshTimer;
    private bool _refreshInFlight;

    public MainWindow()
    {
        InitializeComponent();
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
            JobsList.ItemsSource = jobs;
            ConnectionStatus.Text = "Engine connected";
            MessageBar.IsOpen = false;
        }
        catch (Exception error)
        {
            ConnectionStatus.Text = "Engine disconnected";
            ShowMessage(error.Message, InfoBarSeverity.Error);
        }
        finally
        {
            _refreshInFlight = false;
        }
    }

    private async void OnRefresh(object sender, RoutedEventArgs e) => await RefreshAsync();

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

    private async void OnAddDownload(object sender, RoutedEventArgs e)
    {
        var destination = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var url = new TextBox { Header = "URL", PlaceholderText = "https://example.com/file.zip" };
        var name = new TextBox { Header = "Name (optional)" };
        var folder = new TextBox { Header = "Destination folder", Text = Path.Combine(destination, "Downloads") };
        var priority = new ComboBox { Header = "Priority", SelectedIndex = 1 };
        priority.Items.Add(new ComboBoxItem { Content = "Low" });
        priority.Items.Add(new ComboBoxItem { Content = "Normal" });
        priority.Items.Add(new ComboBoxItem { Content = "High" });
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(url);
        panel.Children.Add(name);
        panel.Children.Add(folder);
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
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

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
            await _engine.AddJobAsync(url.Text.Trim(), name.Text.Trim(), folder.Text.Trim(), selectedPriority);
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
