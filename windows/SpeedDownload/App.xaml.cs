using Microsoft.UI.Xaml;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace SpeedDownload;

public partial class App : Microsoft.UI.Xaml.Application
{
    private Window? _window;
    private static Mutex? _instanceMutex;
    private static readonly string InstanceKey = "Local\\SpeedDownload.Gui.Instance";
    private static readonly object CrashLogGate = new();

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

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        TracePhase0Startup("App launched");
        _instanceMutex = new Mutex(initiallyOwned: true, InstanceKey, out var isFirstInstance);
        if (!isFirstInstance)
        {
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
        _window = new MainWindow();
        TracePhase0Startup("Main window constructed");
        _window.Activate();
        TracePhase0Startup("Main window activated");
    }
}
