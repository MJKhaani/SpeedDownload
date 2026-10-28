using System;
using System.IO;
using System.Windows;
using System.Windows.Threading;

internal static class Program
{
    [STAThread]
    private static int Main()
    {
        var report = Environment.GetEnvironmentVariable("SPEED_DOWNLOAD_WPF_PROBE_REPORT");
        if (string.IsNullOrWhiteSpace(report)) return 2;
        var app = new Application();
        var window = new Window { Title = "Speed Download WPF startup probe", Width = 320, Height = 180 };
        window.SourceInitialized += (_, _) => File.WriteAllText(report, "window initialized");
        window.Loaded += (_, _) =>
        {
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            timer.Tick += (_, _) => { timer.Stop(); window.Close(); };
            timer.Start();
        };
        app.Run(window);
        return File.Exists(report) ? 0 : 1;
    }
}
