using System.Text.Json.Serialization;
using Microsoft.UI.Xaml;
using System.ComponentModel;

namespace SpeedDownload;

public sealed class DownloadJob : INotifyPropertyChanged
{
    [JsonPropertyName("job_id")] public string JobId { get; set; } = "";
    [JsonPropertyName("url")] public string Url { get; set; } = "";
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("destination")] public string Destination { get; set; } = "";
    [JsonPropertyName("reference_url")] public string? ReferenceUrl { get; set; }
    [JsonPropertyName("expected_sha256")] public string? ExpectedSha256 { get; set; }
    [JsonPropertyName("state")] public string State { get; set; } = "queued";
    [JsonPropertyName("revision")] public string Revision { get; set; } = "0";
    [JsonPropertyName("error_message")] public string? ErrorMessage { get; set; }
    [JsonPropertyName("retry_attempts")] public int RetryAttempts { get; set; }
    [JsonPropertyName("retry_at_unix_ms")] public string? RetryAtUnixMs { get; set; }
    [JsonPropertyName("completed_bytes")] public string? CompletedBytes { get; set; }
    [JsonPropertyName("received_bytes")] public string? ReceivedBytes { get; set; }
    [JsonPropertyName("total_bytes")] public string? TotalBytes { get; set; }
    [JsonPropertyName("requested_control")] public string? RequestedControl { get; set; }
    [JsonPropertyName("queue_finish_action")] public string? QueueFinishAction { get; set; }
    [JsonPropertyName("queue_action_outcome")] public string? QueueActionOutcome { get; set; }
    [JsonPropertyName("priority")] public int Priority { get; set; }
    [JsonPropertyName("bandwidth_limit_bytes_per_second")] public ulong BandwidthLimit { get; set; }
    [JsonPropertyName("queue_id")] public string QueueId { get; set; } = "main";
    [JsonPropertyName("workers")] public List<DownloadWorker> Workers { get; set; } = [];
    [JsonPropertyName("torrent_active_peer_count")] public uint TorrentActivePeerCount { get; set; }
    [JsonPropertyName("torrent_peer_count")] public uint? TorrentPeerCount { get; set; }
    [JsonPropertyName("torrent_seeder_count")] public uint? TorrentSeederCount { get; set; }
    [JsonPropertyName("torrent_leecher_count")] public uint? TorrentLeecherCount { get; set; }
    [JsonPropertyName("torrent_active_peer")] public string? TorrentActivePeer { get; set; }
    [JsonIgnore] public bool IsTorrent => Url.StartsWith("magnet:", StringComparison.OrdinalIgnoreCase) ||
        Url.StartsWith("torrent-file:", StringComparison.OrdinalIgnoreCase) ||
        (Uri.TryCreate(Url, UriKind.Absolute, out var torrentUri) && torrentUri.AbsolutePath.EndsWith(".torrent", StringComparison.OrdinalIgnoreCase));

    private string? _iconKey;
    [JsonIgnore] public Microsoft.UI.Xaml.Media.ImageSource? FileIcon { get; private set; }
    [JsonIgnore] public Visibility FallbackIconVisibility => FileIcon is null ? Visibility.Visible : Visibility.Collapsed;
    public async Task LoadFileIconAsync()
    {
        var key = ShellFileIcon.KeyForName(Title);
        if (_iconKey == key) return;
        _iconKey = key;
        var icon = await ShellFileIcon.GetAsync(key);
        if (_iconKey != key) return;
        FileIcon = icon;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(FileIcon)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(FallbackIconVisibility)));
    }

    private DateTimeOffset _sampleTime;
    private ulong _sampleBytes;
    [JsonIgnore] public double BytesPerSecond { get; private set; }
    private bool _compactSize;
    private bool _compactSpeed;
    private bool _compactEta;
    [JsonIgnore] public string SizeText => Total == 0 ? "Unknown" : FormatBytes(Total);
    [JsonIgnore] public double? EtaSeconds => State == "downloading" && Total > Received && BytesPerSecond > 0
        ? (Total - Received) / BytesPerSecond : null;
    [JsonIgnore] public string CompactMetrics => string.Join(" · ", new[]
    {
        _compactSize ? "Size: " + SizeText : null,
        _compactSpeed ? "Speed: " + SpeedText : null,
        _compactEta ? EtaText : null,
    }.Where(value => value is not null));
    [JsonIgnore] public Visibility CompactMetricsVisibility => _compactSize || _compactSpeed || _compactEta ? Visibility.Visible : Visibility.Collapsed;
    public void SetCompactMetrics(bool size, bool speed, bool eta)
    {
        if (_compactSize == size && _compactSpeed == speed && _compactEta == eta) return;
        _compactSize = size; _compactSpeed = speed; _compactEta = eta;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CompactMetrics)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CompactMetricsVisibility)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(AccessibleStatus)));
    }
    [JsonIgnore] public string SpeedText => State == "downloading" && BytesPerSecond > 0 ? $"{FormatBytes((ulong)BytesPerSecond)}/s" : "Not available";
    private bool _localPending;
    private bool _online = true;
    [JsonIgnore] public bool CanControl => _online && !_localPending && string.IsNullOrEmpty(RequestedControl);
    public void SetLocalPending(bool pending)
    {
        _localPending = pending;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CanControl)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(StateText)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(AccessibleStatus)));
    }
    [JsonIgnore] public string EtaText
    {
        get
        {
            if (State != "downloading" || Total == 0 || Received >= Total || BytesPerSecond <= 0) return "ETA not available";
            var seconds = (Total - Received) / BytesPerSecond;
            if (!double.IsFinite(seconds) || seconds > TimeSpan.MaxValue.TotalSeconds) return "ETA not available";
            var remaining = TimeSpan.FromSeconds(seconds);
            return remaining.TotalDays >= 1 ? $"About {(int)remaining.TotalDays} d {remaining.Hours} h remaining" :
                remaining.TotalHours >= 1 ? $"About {(int)remaining.TotalHours} h {remaining.Minutes} min remaining" :
                remaining.TotalMinutes >= 1 ? $"About {(int)remaining.TotalMinutes} min remaining" : "Less than a minute remaining";
        }
    }
    [JsonIgnore] public string StateText => _localPending || !string.IsNullOrEmpty(RequestedControl) ? $"{StateLabel} · command pending" : StateLabel;
    [JsonIgnore] public string AccessibleStatus => $"{StateText}; {ProgressText}" + (CompactMetrics.Length == 0 ? "" : $"; {CompactMetrics}");
    private string StateLabel => State switch
    {
        "retry_wait" => "Waiting to retry", "queued" => "Queued", "scheduled" => "Scheduled",
        "resolving" => "Resolving", "connecting" => "Connecting", "downloading" => "Downloading",
        "paused" => "Paused", "verifying" => "Verifying", "completed" => "Completed",
        "failed" => "Failed", "canceled" => "Canceled", _ => State,
    };
    public event PropertyChangedEventHandler? PropertyChanged;

    public void UpdateFrom(DownloadJob next)
    {
        if (_online && State != "downloading" && State == next.State && Revision == next.Revision && ReceivedBytes == next.ReceivedBytes &&
            CompletedBytes == next.CompletedBytes && TotalBytes == next.TotalBytes && ErrorMessage == next.ErrorMessage && RetryAttempts == next.RetryAttempts && RetryAtUnixMs == next.RetryAtUnixMs && RequestedControl == next.RequestedControl && QueueFinishAction == next.QueueFinishAction && QueueActionOutcome == next.QueueActionOutcome &&
            Name == next.Name && Url == next.Url && Destination == next.Destination && ReferenceUrl == next.ReferenceUrl && ExpectedSha256 == next.ExpectedSha256 && Priority == next.Priority && BandwidthLimit == next.BandwidthLimit && QueueId == next.QueueId &&
            TorrentActivePeerCount == next.TorrentActivePeerCount && TorrentPeerCount == next.TorrentPeerCount &&
            TorrentSeederCount == next.TorrentSeederCount && TorrentLeecherCount == next.TorrentLeecherCount && TorrentActivePeer == next.TorrentActivePeer &&
            Workers.Count == next.Workers.Count && Workers.Zip(next.Workers).All(pair => pair.First.WorkerId == pair.Second.WorkerId && pair.First.Downloaded == pair.Second.Downloaded && pair.First.End == pair.Second.End))
            return;
        _online = true;
        var now = DateTimeOffset.UtcNow;
        var elapsed = (now - _sampleTime).TotalSeconds;
        var currentBytes = next.Received;
        BytesPerSecond = next.State == "downloading" && State == "downloading" && _sampleTime != default && elapsed > 0 && currentBytes >= _sampleBytes
            ? (currentBytes - _sampleBytes) / elapsed : 0;
        _sampleTime = now;
        _sampleBytes = currentBytes;
        Url = next.Url;
        Name = next.Name;
        Destination = next.Destination;
        ReferenceUrl = next.ReferenceUrl;
        ExpectedSha256 = next.ExpectedSha256;
        State = next.State;
        Revision = next.Revision;
        ErrorMessage = next.ErrorMessage;
        RetryAttempts = next.RetryAttempts;
        RetryAtUnixMs = next.RetryAtUnixMs;
        CompletedBytes = next.CompletedBytes;
        ReceivedBytes = next.ReceivedBytes;
        TotalBytes = next.TotalBytes;
        RequestedControl = next.RequestedControl;
        QueueFinishAction = next.QueueFinishAction;
        QueueActionOutcome = next.QueueActionOutcome;
        Priority = next.Priority;
        BandwidthLimit = next.BandwidthLimit;
        QueueId = next.QueueId;
        Workers = next.Workers;
        TorrentActivePeerCount = next.TorrentActivePeerCount;
        TorrentPeerCount = next.TorrentPeerCount;
        TorrentSeederCount = next.TorrentSeederCount;
        TorrentLeecherCount = next.TorrentLeecherCount;
        TorrentActivePeer = next.TorrentActivePeer;
        _ = LoadFileIconAsync();
        foreach (var property in new[] { nameof(Title), nameof(Host), nameof(State), nameof(StateText), nameof(SpeedText), nameof(SizeText), nameof(EtaText), nameof(EtaSeconds), nameof(CompactMetrics), nameof(AccessibleStatus), nameof(CanControl), nameof(Progress), nameof(ProgressVisibility), nameof(ProgressText), nameof(CheckpointText), nameof(PrimaryActionText), nameof(PrimaryActionGlyph), nameof(PrimaryActionVisibility), nameof(RemoveActionText) })
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
    }

    public void MarkDisconnected()
    {
        _online = false;
        _sampleTime = default;
        BytesPerSecond = 0;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CanControl)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(SpeedText)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(EtaText)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(EtaSeconds)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CompactMetrics)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(AccessibleStatus)));
    }

    [JsonIgnore] public string Title => string.IsNullOrWhiteSpace(Name) ? (Uri.TryCreate(Url, UriKind.Absolute, out var source) ? Uri.UnescapeDataString(source.Segments.LastOrDefault()?.TrimEnd('/') ?? source.Host) : "Download") : Name;
    [JsonIgnore] public string Host => Uri.TryCreate(Url, UriKind.Absolute, out var uri) ? uri.Host : "";
    [JsonIgnore] public ulong Completed => ulong.TryParse(CompletedBytes, out var value) ? value : 0;
    [JsonIgnore] public ulong Received => ulong.TryParse(ReceivedBytes ?? CompletedBytes, out var value) ? value : 0;
    [JsonIgnore] public ulong Total => ulong.TryParse(TotalBytes, out var value) ? value : 0;
    [JsonIgnore] public double Progress => Total == 0 ? 0 : Math.Min(State == "completed" ? 100d : 99.9d, (State == "downloading" ? Received : Completed) * 100d / Total);
    [JsonIgnore] public Visibility ProgressVisibility => Total > 0 ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public Visibility StartVisibility => State == "queued" ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public Visibility PauseVisibility => State is "queued" or "scheduled" or "downloading" ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public Visibility ResumeVisibility => State == "paused" ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public Visibility RetryVisibility => State is "failed" or "retry_wait" ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public Visibility CancelVisibility => State is "queued" or "scheduled" or "downloading" or "paused" or "retry_wait" ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public string PrimaryActionText => State switch
    {
        "downloading" or "scheduled" => "Pause",
        "paused" or "retry_wait" => "Resume",
        "failed" => "Retry",
        "queued" => "Start",
        _ => "",
    };
    [JsonIgnore] public Visibility PrimaryActionVisibility => PrimaryActionText.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public string PrimaryActionGlyph => State switch
    {
        "downloading" or "scheduled" => "\uE769",
        "failed" => "\uE72C",
        "queued" or "paused" or "retry_wait" => "\uE768",
        _ => "",
    };
    [JsonIgnore] public string RemoveActionText => State is "resolving" or "connecting" or "downloading" or "verifying" or "queued" or "scheduled" or "paused" or "retry_wait" ? "Cancel transfer" : "Remove job";
    [JsonIgnore] public string ProgressText => Total == 0 ? "Size unknown" : State == "downloading"
        ? $"Received {FormatBytes(Received)} of {FormatBytes(Total)}"
        : $"{FormatBytes(Completed)} of {FormatBytes(Total)}";
    [JsonIgnore] public string CheckpointText => State == "downloading" ? $"Resume checkpoint: {FormatBytes(Completed)}" : "";

    private static string FormatBytes(ulong value)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        double amount = value;
        var unit = 0;
        while (amount >= 1024 && unit < units.Length - 1)
        {
            amount /= 1024;
            unit++;
        }
        return $"{amount:0.#} {units[unit]}";
    }
}

public sealed class DownloadWorker : INotifyPropertyChanged
{
    [JsonPropertyName("worker_id")] public uint WorkerId { get; set; }
    [JsonPropertyName("start")] public ulong Start { get; set; }
    [JsonPropertyName("end")] public ulong End { get; set; }
    [JsonPropertyName("downloaded")] public ulong Downloaded { get; set; }

    private long _sampleTicks;
    private ulong _sampleDownloaded;
    private double? _bytesPerSecond;
    [JsonIgnore] public string RateText => _bytesPerSecond is double rate ? $"{rate / 1_000_000d:0.##} MB/s" : "Rate unavailable";
    [JsonIgnore] public double Percent => End <= Start ? 0 : Math.Min(100d, Downloaded * 100d / (End - Start));
    [JsonIgnore] public string Caption => $"Connection {WorkerId} · {Downloaded / 1_000_000d:0.#} / {(End >= Start ? End - Start : 0) / 1_000_000d:0.#} MB";
    [JsonIgnore] public string RangeText => $"Byte range {Start:N0}–{(End > Start ? End - 1 : Start):N0}";
    public event PropertyChangedEventHandler? PropertyChanged;

    public void BeginSampling()
    {
        _sampleTicks = System.Diagnostics.Stopwatch.GetTimestamp();
        _sampleDownloaded = Downloaded;
        _bytesPerSecond = null;
    }

    public void UpdateFrom(DownloadWorker next)
    {
        var now = System.Diagnostics.Stopwatch.GetTimestamp();
        var elapsed = _sampleTicks == 0 ? 0 : System.Diagnostics.Stopwatch.GetElapsedTime(_sampleTicks, now).TotalSeconds;
        _bytesPerSecond = elapsed > 0 && Start == next.Start && End == next.End && next.Downloaded >= _sampleDownloaded
            ? (next.Downloaded - _sampleDownloaded) / elapsed : null;
        _sampleTicks = now;
        _sampleDownloaded = next.Downloaded;
        Start = next.Start;
        End = next.End;
        Downloaded = next.Downloaded;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Percent)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Caption)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(RangeText)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(RateText)));
    }

    public void MarkDisconnected()
    {
        _sampleTicks = 0;
        _bytesPerSecond = null;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(RateText)));
    }
}
