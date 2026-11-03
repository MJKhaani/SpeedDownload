using System.ComponentModel;

namespace SpeedDownload;

public sealed class TorrentFileChoice : INotifyPropertyChanged
{
    private bool _selected = true;
    public required string Path { get; init; }
    public required string SizeText { get; init; }
    public bool Selected
    {
        get => _selected;
        set
        {
            if (_selected == value) return;
            _selected = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Selected)));
        }
    }
    public event PropertyChangedEventHandler? PropertyChanged;
}
