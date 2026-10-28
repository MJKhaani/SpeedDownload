using System.Text.Json.Serialization;
using System.Windows.Media;

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

    [JsonIgnore] public string Title
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(Name)) return Name;
            if (!Uri.TryCreate(Url, UriKind.Absolute, out var uri)) return Url;
            var lastSegment = Path.GetFileName(Uri.UnescapeDataString(uri.AbsolutePath));
            return string.IsNullOrWhiteSpace(lastSegment) ? uri.Host : lastSegment;
        }
    }
    [JsonIgnore] public ulong Completed => ulong.TryParse(ReceivedBytes ?? CompletedBytes, out var value) ? value : 0;
    [JsonIgnore] public ulong Total => ulong.TryParse(TotalBytes, out var value) ? value : 0;
    [JsonIgnore] public double Progress => Total == 0 ? 0 : Math.Min(100d, Completed * 100d / Total);
    [JsonIgnore] public string ProgressText => Total == 0 ? "Waiting for response…" : $"{FormatBytes(Completed)} of {FormatBytes(Total)}";
    [JsonIgnore] public string Host => Uri.TryCreate(Url, UriKind.Absolute, out var uri) ? uri.Host : "";
    [JsonIgnore] public ImageSource? FileIcon => FileTypeIcon.ForName(Title);
    [JsonIgnore] public string SpeedText { get; set; } = "";

    private static string FormatBytes(ulong value)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        double amount = value;
        var unit = 0;
        while (amount >= 1024 && unit < units.Length - 1) { amount /= 1024; unit++; }
        return $"{amount:0.#} {units[unit]}";
    }
}
