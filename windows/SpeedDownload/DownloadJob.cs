using System.Text.Json.Serialization;
using Microsoft.UI.Xaml;

namespace SpeedDownload;

public sealed class DownloadJob
{
    [JsonPropertyName("job_id")] public string JobId { get; init; } = "";
    [JsonPropertyName("url")] public string Url { get; init; } = "";
    [JsonPropertyName("name")] public string? Name { get; init; }
    [JsonPropertyName("destination")] public string Destination { get; init; } = "";
    [JsonPropertyName("state")] public string State { get; init; } = "queued";
    [JsonPropertyName("revision")] public string Revision { get; init; } = "0";
    [JsonPropertyName("error_message")] public string? ErrorMessage { get; init; }
    [JsonPropertyName("completed_bytes")] public string? CompletedBytes { get; init; }
    [JsonPropertyName("received_bytes")] public string? ReceivedBytes { get; init; }
    [JsonPropertyName("total_bytes")] public string? TotalBytes { get; init; }
    [JsonPropertyName("requested_control")] public string? RequestedControl { get; init; }
    [JsonPropertyName("priority")] public int Priority { get; init; }

    [JsonIgnore] public string Title => string.IsNullOrWhiteSpace(Name) ? Url : Name;
    [JsonIgnore] public ulong Completed => ulong.TryParse(ReceivedBytes ?? CompletedBytes, out var value) ? value : 0;
    [JsonIgnore] public ulong Total => ulong.TryParse(TotalBytes, out var value) ? value : 0;
    [JsonIgnore] public double Progress => Total == 0 ? 0 : Math.Min(100d, Completed * 100d / Total);
    [JsonIgnore] public Visibility ProgressVisibility => State == "downloading" && Total > 0 ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public Visibility StartVisibility => State == "queued" ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public Visibility PauseVisibility => State is "queued" or "scheduled" or "downloading" ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public Visibility ResumeVisibility => State == "paused" ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public Visibility RetryVisibility => State is "failed" or "retry_wait" ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public Visibility CancelVisibility => State is "queued" or "scheduled" or "downloading" or "paused" or "retry_wait" ? Visibility.Visible : Visibility.Collapsed;
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
