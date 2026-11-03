using Microsoft.UI.Xaml;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;

namespace SpeedDownload;

public partial class App : Microsoft.UI.Xaml.Application
{
    private Window? _window;
    private static Mutex? _instanceMutex;
    private static readonly string InstanceKey = "Local\\SpeedDownload.Gui.Instance";
    private static readonly object CrashLogGate = new();
    private const string ActivationEventName = "Local\\SpeedDownload.Gui.Activate";
    private EventWaitHandle? _activationEvent;
    private EventWaitHandle? _queueCompletionQuitEvent;
    private static string ActivationPipeName => $"SpeedDownload.Gui.Activation-{WindowsIdentity.GetCurrent().User?.Value}-{Process.GetCurrentProcess().SessionId}";

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    public App()
    {
        TracePhase0Startup("App constructor");
        UnhandledException += (_, args) =>
            LogClientException(args.Exception, "WinUI unhandled exception");
        InitializeComponent();
        TracePhase0Startup("App initialized");
    }

    internal static void TracePhase0Startup(string stage)
    {
        var path = Environment.GetEnvironmentVariable("SPEED_DOWNLOAD_PHASE0_STARTUP_TRACE");
        if (string.IsNullOrEmpty(path) || !Path.IsPathFullyQualified(path)) return;
        try { File.AppendAllText(path, stage + Environment.NewLine); }
        catch (IOException) { }
    }

    internal static void LogClientException(Exception error, string phase)
    {
        TracePhase0Startup($"{phase}: 0x{error.HResult:X8} {error}");
        try
        {
            var logDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "SpeedDownload", "logs");
            Directory.CreateDirectory(logDirectory);
            var logPath = Path.Combine(logDirectory, "client-crash.log");
            lock (CrashLogGate)
            {
                if (File.Exists(logPath) && new FileInfo(logPath).Length > 1024 * 1024)
                    File.Move(logPath, Path.Combine(logDirectory, "client-crash.previous.log"), true);
                File.AppendAllText(logPath,
                    $"[{DateTimeOffset.Now:O}] {phase} (HRESULT 0x{error.HResult:X8}){Environment.NewLine}" +
                    error + Environment.NewLine + Environment.NewLine);
            }
        }
        catch (Exception)
        {
            // Diagnostic logging must never replace the original startup error.
        }
    }

    private static string? TorrentArgument()
    {
        var value = Environment.GetCommandLineArgs().Skip(1).FirstOrDefault();
        if (string.IsNullOrWhiteSpace(value) || value.Length > 8192 || value.Contains('\n') || value.Contains('\r')) return null;
        if (value.StartsWith("magnet:", StringComparison.OrdinalIgnoreCase)) return value;
        if (Path.IsPathFullyQualified(value) && value.EndsWith(".torrent", StringComparison.OrdinalIgnoreCase) && File.Exists(value))
            return new Uri(value).AbsoluteUri.Replace("file:", "torrent-file:", StringComparison.OrdinalIgnoreCase);
        if (Uri.TryCreate(value, UriKind.Absolute, out var uri) && (uri.Scheme is "http" or "https") && uri.AbsolutePath.EndsWith(".torrent", StringComparison.OrdinalIgnoreCase)) return value;
        return null;
    }

    private static bool ForwardActivation(string source)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", ActivationPipeName, PipeDirection.Out, PipeOptions.CurrentUserOnly);
            pipe.Connect(3000);
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true };
            writer.WriteLine(source);
            return true;
        }
        catch (Exception error) when (error is IOException or TimeoutException or UnauthorizedAccessException) { return false; }
    }

    private static async Task ListenForActivationsAsync(MainWindow window)
    {
        while (true)
        {
            try
            {
                await using var pipe = new NamedPipeServerStream(ActivationPipeName, PipeDirection.InOut, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync();
                using var reader = new StreamReader(pipe, Encoding.UTF8);
                var buffer = new char[256 * 1024 + 1];
                var length = 0;
                while (length < buffer.Length)
                {
                    var count = await reader.ReadAsync(buffer.AsMemory(length, 1));
                    if (count == 0 || buffer[length] == '\n') break;
                    length += count;
                }
                var value = new string(buffer, 0, length).TrimEnd('\r');
                if (value.StartsWith('{'))
                {
                    var accepted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                    if (!window.DispatcherQueue.TryEnqueue(() => accepted.TrySetResult(window.EnqueueBrowserActivation(value)))) accepted.TrySetResult(false);
                    var ok = await accepted.Task.WaitAsync(TimeSpan.FromSeconds(4));
                    using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, true) { AutoFlush = true };
                    await writer.WriteLineAsync(ok ? "accepted" : "rejected");
                }
                else if (value.Length is > 0 and <= 8192)
                    window.DispatcherQueue.TryEnqueue(() => window.EnqueueTorrentActivation(value));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or TimeoutException) { await Task.Delay(1000); }
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        TracePhase0Startup("App launched");
        var torrentArgument = TorrentArgument();
        _activationEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ActivationEventName);
        _instanceMutex = new Mutex(initiallyOwned: true, InstanceKey, out var isFirstInstance);
        if (!isFirstInstance)
        {
            if (torrentArgument is null && Environment.GetCommandLineArgs().Skip(1).Contains("--startup", StringComparer.OrdinalIgnoreCase))
            {
                Environment.Exit(0);
                return;
            }
            _activationEvent.Set();
            if (torrentArgument is not null && !ForwardActivation(torrentArgument))
                System.Windows.Forms.MessageBox.Show("Could not send the torrent to the running Speed Download window. Try again.", "Speed Download");
            foreach (var process in Process.GetProcessesByName("SpeedDownload"))
            {
                using (process)
                {
                    if (process.Id == Environment.ProcessId || process.MainWindowHandle == IntPtr.Zero) continue;
                    _ = SetForegroundWindow(process.MainWindowHandle);
                    break;
                }
            }
            Environment.Exit(0);
            return;
        }
        _queueCompletionQuitEvent = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\SpeedDownload.Gui.QueueComplete.Quit");
        _window = new MainWindow();
        var window = (MainWindow)_window;
        try
        {
            var activation = Microsoft.Windows.AppLifecycle.AppInstance.GetCurrent().GetActivatedEventArgs();
            if (activation.Kind == Microsoft.Windows.AppLifecycle.ExtendedActivationKind.AppNotification &&
                activation.Data is Microsoft.Windows.AppNotifications.AppNotificationActivatedEventArgs notification)
                window.HandleNotificationActivation(notification);
        }
        catch (Exception error) { LogClientException(error, "Notification activation unavailable"); }
        var dispatcher = window.DispatcherQueue;
        _ = Task.Run(() =>
        {
            while (_queueCompletionQuitEvent?.WaitOne() == true)
                dispatcher.TryEnqueue(window.QuitAfterQueueCompletion);
        });
        _ = Task.Run(() => ListenForActivationsAsync(window));
        if (torrentArgument is not null) window.EnqueueTorrentActivation(torrentArgument);
        _ = Task.Run(() =>
        {
            while (_activationEvent?.WaitOne() == true)
                dispatcher.TryEnqueue(() => window.ShowMainWindow());
        });
        TracePhase0Startup("Main window constructed");
        _window.Activate();
        if (Environment.GetCommandLineArgs().Skip(1).Contains("--startup", StringComparer.OrdinalIgnoreCase) && window.StartMinimizedAtLogin)
            window.AppWindow.Hide();
        TracePhase0Startup("Main window activated");
    }
}
