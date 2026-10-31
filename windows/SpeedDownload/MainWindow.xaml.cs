using Microsoft.UI.Xaml;

namespace SpeedDownload;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        App.TracePhase0Startup("Blank window constructor");
        InitializeComponent();
        App.TracePhase0Startup("Blank window XAML initialized");
    }
}
