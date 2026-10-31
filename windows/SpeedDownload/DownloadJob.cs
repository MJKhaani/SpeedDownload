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

    public event PropertyChangedEventHandler? PropertyChanged;

    public void UpdateFrom(DownloadJob next)
    {
        if (State == next.State && Revision == next.Revision && ReceivedBytes == next.ReceivedBytes &&
            CompletedBytes == next.CompletedBytes && TotalBytes == next.TotalBytes && ErrorMessage == next.ErrorMessage &&
            Name == next.Name && Url == next.Url && Destination == next.Destination && Priority == next.Priority && QueueId == next.QueueId)
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
        foreach (var property in new[] { nameof(Title), nameof(Host), nameof(State), nameof(Progress), nameof(ProgressVisibility), nameof(ProgressText), nameof(PrimaryActionText), nameof(PrimaryActionVisibility) })
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
