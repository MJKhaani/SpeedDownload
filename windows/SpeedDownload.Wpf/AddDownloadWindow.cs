using System.Windows;
using System.Windows.Controls;
using Forms = System.Windows.Forms;

namespace SpeedDownload;

internal sealed class AddDownloadWindow : Window
{
    private readonly EngineClient _engine;
    private readonly TextBox _url = new();
    private readonly TextBox _name = new();
    private readonly TextBox _destination = new();
    private readonly ComboBox _priority = new();
    private readonly Button _add = new() { Content = "Add to Queue", IsDefault = true, MinWidth = 110 };

    public AddDownloadWindow(EngineClient engine)
    {
        _engine = engine;
        Title = "Add Download";
        Width = 560;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;

        var layout = new Grid { Margin = new Thickness(20) };
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var row = 0; row < 5; row++) layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Content = layout;

        AddField(layout, "URL", _url, 0);
        AddField(layout, "File name", _name, 1);
        _destination.Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        var folderRow = new DockPanel();
        var choose = new Button { Content = "Choose…", MinWidth = 75, Margin = new Thickness(8, 0, 0, 0) };
        choose.Click += (_, _) => ChooseFolder();
        DockPanel.SetDock(choose, Dock.Right);
        folderRow.Children.Add(choose);
        folderRow.Children.Add(_destination);
        AddField(layout, "Save to", folderRow, 2);

        _priority.Items.Add("Normal");
        _priority.Items.Add("High");
        _priority.Items.Add("Low");
        _priority.SelectedIndex = 0;
        AddField(layout, "Queue priority", _priority, 3);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 80, Margin = new Thickness(0, 0, 8, 0) };
        buttons.Children.Add(cancel);
        buttons.Children.Add(_add);
        Grid.SetRow(buttons, 4);
        Grid.SetColumnSpan(buttons, 2);
        layout.Children.Add(buttons);
        _add.Click += async (_, _) => await AddAsync();
        Loaded += (_, _) => _url.Focus();
    }

    private static void AddField(Grid grid, string title, UIElement field, int row)
    {
        var label = new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 10) };
        Grid.SetRow(label, row);
        grid.Children.Add(label);
        if (field is FrameworkElement element) element.Margin = new Thickness(0, 0, 0, 10);
        Grid.SetRow(field, row);
        Grid.SetColumn(field, 1);
        grid.Children.Add(field);
    }

    private void ChooseFolder()
    {
        using var picker = new Forms.FolderBrowserDialog { SelectedPath = _destination.Text };
        if (picker.ShowDialog() == Forms.DialogResult.OK) _destination.Text = picker.SelectedPath;
    }

    private async Task AddAsync()
    {
        var url = _url.Text.Trim();
        if (!Uri.TryCreate(url, UriKind.Absolute, out _))
        {
            MessageBox.Show(this, "Enter a valid download URL.", "Speed Download", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        _add.IsEnabled = false;
        try
        {
            var priority = _priority.SelectedIndex switch { 1 => 1, 2 => -1, _ => 0 };
            await _engine.AddJobAsync(url, _name.Text.Trim(), _destination.Text.Trim(), priority);
            DialogResult = true;
        }
        catch (Exception error)
        {
            MessageBox.Show(this, error.Message, "Speed Download", MessageBoxButton.OK, MessageBoxImage.Error);
            _add.IsEnabled = true;
        }
    }
}
