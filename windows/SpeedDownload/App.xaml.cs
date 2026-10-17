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
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
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
        _window.Activate();
    }
}
