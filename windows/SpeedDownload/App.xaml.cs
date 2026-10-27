using Microsoft.UI.Xaml;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace SpeedDownload;

public partial class App : Microsoft.UI.Xaml.Application
{
    private Window? _window;
    private static Mutex? _instanceMutex;
    private static readonly string InstanceKey = "Local\\SpeedDownload.Gui.Instance";

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    public App()
    {
        TracePhase0Startup("App constructor");
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
