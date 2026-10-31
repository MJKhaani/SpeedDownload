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
    [JsonPropertyName("state")] public string State { get; set; } = "queued";
    [JsonPropertyName("revision")] public string Revision { get; set; } = "0";
    [JsonPropertyName("error_message")] public string? ErrorMessage { get; set; }
    [JsonPropertyName("completed_bytes")] public string? CompletedBytes { get; set; }
    [JsonPropertyName("received_bytes")] public string? ReceivedBytes { get; set; }
    [JsonPropertyName("total_bytes")] public string? TotalBytes { get; set; }
    [JsonPropertyName("requested_control")] public string? RequestedControl { get; set; }
    [JsonPropertyName("priority")] public int Priority { get; set; }
    [JsonPropertyName("queue_id")] public string QueueId { get; set; } = "main";
    [JsonPropertyName("workers")] public List<DownloadWorker> Workers { get; set; } = [];

    public event PropertyChangedEventHandler? PropertyChanged;

    public void UpdateFrom(DownloadJob next)
    {
        if (State == next.State && Revision == next.Revision && ReceivedBytes == next.ReceivedBytes &&
            CompletedBytes == next.CompletedBytes && TotalBytes == next.TotalBytes && ErrorMessage == next.ErrorMessage &&
            Name == next.Name && Url == next.Url && Destination == next.Destination && Priority == next.Priority && QueueId == next.QueueId &&
            Workers.Count == next.Workers.Count && Workers.Zip(next.Workers).All(pair => pair.First.WorkerId == pair.Second.WorkerId && pair.First.Downloaded == pair.Second.Downloaded && pair.First.End == pair.Second.End))
            return;
        Url = next.Url;
        Name = next.Name;
        Destination = next.Destination;
        State = next.State;
        Revision = next.Revision;
        ErrorMessage = next.ErrorMessage;
        CompletedBytes = next.CompletedBytes;
        ReceivedBytes = next.ReceivedBytes;
        TotalBytes = next.TotalBytes;
        RequestedControl = next.RequestedControl;
        Priority = next.Priority;
        QueueId = next.QueueId;
        Workers = next.Workers;
        foreach (var property in new[] { nameof(Title), nameof(Host), nameof(State), nameof(Progress), nameof(ProgressVisibility), nameof(ProgressText), nameof(PrimaryActionText), nameof(PrimaryActionGlyph), nameof(PrimaryActionVisibility), nameof(RemoveActionText) })
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
    }

    [JsonIgnore] public string Title => string.IsNullOrWhiteSpace(Name) ? Url : Name;
    [JsonIgnore] public string Host => Uri.TryCreate(Url, UriKind.Absolute, out var uri) ? uri.Host : "";
    [JsonIgnore] public ulong Completed => ulong.TryParse(ReceivedBytes ?? CompletedBytes, out var value) ? value : 0;
    [JsonIgnore] public ulong Total => ulong.TryParse(TotalBytes, out var value) ? value : 0;
    [JsonIgnore] public double Progress => Total == 0 ? 0 : Math.Min(100d, Completed * 100d / Total);
    [JsonIgnore] public Visibility ProgressVisibility => State == "downloading" && Total > 0 ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public Visibility StartVisibility => State == "queued" ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public Visibility PauseVisibility => State is "queued" or "scheduled" or "downloading" ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public Visibility ResumeVisibility => State == "paused" ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public Visibility RetryVisibility => State is "failed" or "retry_wait" ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public Visibility CancelVisibility => State is "queued" or "scheduled" or "downloading" or "paused" or "retry_wait" ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public string PrimaryActionText => State switch
    {
        "downloading" => "Pause",
        "paused" => "Resume",
        "failed" => "Retry",
        "queued" or "scheduled" or "retry_wait" => "Start",
        _ => "",
    };
    [JsonIgnore] public Visibility PrimaryActionVisibility => PrimaryActionText.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public string PrimaryActionGlyph => State switch
    {
        "downloading" => "⏸",
        "failed" or "retry_wait" => "↻",
        "queued" or "scheduled" or "paused" => "▶",
        _ => "",
    };
    [JsonIgnore] public string RemoveActionText => State is "resolving" or "connecting" or "downloading" or "verifying" or "queued" or "scheduled" or "paused" or "retry_wait" ? "Cancel transfer" : "Remove job";
    [JsonIgnore] public string ProgressText => Total == 0 ? "Waiting for response…" : $"{FormatBytes(Completed)} of {FormatBytes(Total)}";

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

    [JsonIgnore] public double Percent => End <= Start ? 0 : Math.Min(100d, Downloaded * 100d / (End - Start));
    [JsonIgnore] public string Caption => $"Connection {WorkerId}  ·  {Downloaded / 1_000_000d:0.#} / {(End - Start) / 1_000_000d:0.#} MB";
    public event PropertyChangedEventHandler? PropertyChanged;

    public void UpdateFrom(DownloadWorker next)
    {
        if (Start == next.Start && End == next.End && Downloaded == next.Downloaded) return;
        Start = next.Start;
        End = next.End;
        Downloaded = next.Downloaded;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Percent)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Caption)));
    }
}
