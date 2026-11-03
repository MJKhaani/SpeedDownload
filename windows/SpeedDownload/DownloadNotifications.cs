using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using System.Runtime.InteropServices;
using System.Security.Principal;

namespace SpeedDownload;

// Notification payloads intentionally contain only an internal job ID.
internal sealed class DownloadNotifications : IDisposable
{
    private readonly Action<string> _activate;
    private bool _registered;
    private bool _deliveryFailed;
    private string? _unavailableReason;

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(IntPtr token, int informationClass, out int information, int length, out int returnedLength);

    internal DownloadNotifications(Action<string> activate)
    {
        _activate = activate;
        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            if (GetTokenInformation(identity.AccessToken.DangerousGetHandle(), 20, out var elevated, sizeof(int), out _) && elevated != 0)
            {
                _unavailableReason = "Windows app notifications are unavailable while Speed Download runs as administrator.";
                return;
            }
            AppNotificationManager.Default.NotificationInvoked += OnInvoked;
            AppNotificationManager.Default.Register();
            _registered = true;
        }
        catch (Exception)
        {
            try { AppNotificationManager.Default.NotificationInvoked -= OnInvoked; }
            catch (Exception) { }
        }
    }

    internal string Status
    {
        get
        {
            if (!_registered) return _unavailableReason ?? "Windows notifications are unavailable for this app. Check Windows notification settings and the Windows App SDK runtime.";
            if (_deliveryFailed) return "Windows could not accept a notification. Check Windows notification settings and whether the app is running as administrator.";
            try { return AppNotificationManager.Default.Setting.ToString() == "Enabled" ? "Windows notifications are enabled." : "Windows notifications are disabled by Windows settings or policy."; }
            catch (Exception) { return "Windows notification status is unavailable."; }
        }
    }

    internal void Show(string jobId, bool completed)
        => ShowMessage(jobId, completed ? "A download completed." : "A download needs attention.");

    internal void ShowQueueFailure(string jobId)
        => ShowMessage(jobId, "A queue completion action failed.");

    private void ShowMessage(string jobId, string message)
    {
        if (!_registered) return;
        try
        {
            if (AppNotificationManager.Default.Setting.ToString() != "Enabled") return;
            var notification = new AppNotificationBuilder()
                .AddArgument("job", jobId)
                .AddText("Speed Download")
                .AddText(message)
                .BuildNotification();
            AppNotificationManager.Default.Show(notification);
            _deliveryFailed = false;
        }
        catch (Exception) { _deliveryFailed = true; }
    }

    private void OnInvoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args)
        => HandleActivation(args);

    internal void HandleActivation(AppNotificationActivatedEventArgs args)
    {
        if (args.Arguments.TryGetValue("job", out var jobId) && !string.IsNullOrWhiteSpace(jobId) && jobId.Length <= 128)
            _activate(jobId);
    }

    public void Dispose()
    {
        if (!_registered) return;
        try { AppNotificationManager.Default.Unregister(); }
        catch (Exception) { }
        try { AppNotificationManager.Default.NotificationInvoked -= OnInvoked; }
        catch (Exception) { }
        _registered = false;
    }
}
