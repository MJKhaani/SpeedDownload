using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;

namespace SpeedDownload;

public partial class App : System.Windows.Application
{
    private Mutex? _instanceMutex;

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var report = Environment.GetEnvironmentVariable("SPEED_DOWNLOAD_PHASE0_STARTUP_TRACE");
        if (!string.IsNullOrEmpty(report) && Path.IsPathFullyQualified(report))
            File.AppendAllText(report, "WPF app startup" + Environment.NewLine);

        _instanceMutex = new Mutex(true, @"Local\SpeedDownload.Gui.Instance", out var firstInstance);
        if (!firstInstance)
        {
            foreach (var process in Process.GetProcessesByName("SpeedDownload"))
            {
                using (process)
                {
                    if (process.Id != Environment.ProcessId && process.MainWindowHandle != IntPtr.Zero)
                    {
                        _ = SetForegroundWindow(process.MainWindowHandle);
                        break;
                    }
                }
            }
            Shutdown();
            return;
        }

        var window = new MainWindow();
        MainWindow = window;
        window.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _instanceMutex?.Dispose();
        base.OnExit(e);
    }
}
