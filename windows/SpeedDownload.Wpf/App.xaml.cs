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
        DispatcherUnhandledException += (_, error) => TracePhase0Exception(error.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, error) =>
        {
            if (error.ExceptionObject is Exception exception) TracePhase0Exception(exception);
        };
        TracePhase0("WPF app startup");

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

    private static void TracePhase0Exception(Exception error)
    {
        var cause = error.GetBaseException();
        TracePhase0($"Unhandled {error.GetType().FullName}; cause {cause.GetType().FullName}: {cause.Message}{Environment.NewLine}{error.StackTrace}");
    }

    private static void TracePhase0(string line)
    {
        var report = Environment.GetEnvironmentVariable("SPEED_DOWNLOAD_PHASE0_STARTUP_TRACE");
        if (string.IsNullOrEmpty(report) || !Path.IsPathFullyQualified(report)) return;
        try { File.AppendAllText(report, line + Environment.NewLine); }
        catch (IOException) { }
    }
}
