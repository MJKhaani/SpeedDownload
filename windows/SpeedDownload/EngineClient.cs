using System.Buffers.Binary;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace SpeedDownload;

internal sealed class EngineClient
{
    private const int MaxFrameSize = 1_048_576;
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    private bool _engineLaunchAttempted;
    private System.Diagnostics.Process? _engineProcess;
    private HashSet<string> _features = new(StringComparer.Ordinal);

    public bool SupportsFeature(string feature) => _features.Contains(feature);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);

    internal sealed class ShutdownUnconfirmedException : Exception
    {
        internal ShutdownUnconfirmedException(Exception inner) : base("The engine accepted shutdown, but its exit could not be confirmed.", inner) { }
    }

    private static string PipeName
    {
        get
        {
            var sid = WindowsIdentity.GetCurrent().User?.Value ?? throw new InvalidOperationException("Could not determine the current Windows user.");
            var session = Environment.ProcessId > 0 ? ProcessSessionId() : 0;
            return $"SpeedDownload-{sid}-{session}";
        }
    }

    public async Task<IReadOnlyList<DownloadJob>> ListJobsAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            return await ListJobsCoreAsync(cancellationToken);
        }
        catch (Exception initialError) when (!cancellationToken.IsCancellationRequested)
        {
            if (initialError is EngineOutdatedException)
                throw new InvalidOperationException("The running Speed Download engine is incompatible. Stop it safely, then reopen the app; active downloads may otherwise be interrupted.", initialError);
            EnsureEngineRunning();
            for (var attempt = 0; attempt < 20; attempt++)
            {
                await Task.Delay(250, cancellationToken);
                try { return await ListJobsCoreAsync(cancellationToken); }
                catch (Exception) when (!cancellationToken.IsCancellationRequested) { }
            }
            throw new InvalidOperationException("Could not connect to the Speed Download engine after trying to start it.", initialError);
        }
    }

    public Task<IReadOnlyList<DownloadJob>> ListJobsWithoutStartingAsync(CancellationToken cancellationToken = default)
        => ListJobsCoreAsync(cancellationToken);

    public async Task ShutdownAsync(CancellationToken cancellationToken = default)
    {
        System.Diagnostics.Process? process = null;
        var accepted = false;
        try
        {
            using var parameters = JsonDocument.Parse("{}");
            using var result = await CallAsync("engine.shutdown", parameters.RootElement, cancellationToken, pipe =>
            {
                if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var pid) || pid == 0 || pid > int.MaxValue)
                    throw new InvalidOperationException("Could not identify the engine process for shutdown confirmation.");
                process = System.Diagnostics.Process.GetProcessById((int)pid);
                _ = process.SafeHandle;
            });
            if (!result.RootElement.TryGetProperty("stopping", out var stopping) || stopping.ValueKind != JsonValueKind.True)
                throw new InvalidDataException("The engine did not acknowledge shutdown.");
            accepted = true;
            if (process is null) throw new InvalidOperationException("The engine process could not be identified.");
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(20));
            await process.WaitForExitAsync(timeout.Token);
            if (process.ExitCode != 0) throw new InvalidOperationException($"The engine exited with code {process.ExitCode}.");
        }
        catch (Exception error) when (accepted || (process is not null && (error is IOException or TimeoutException or OperationCanceledException)))
        { throw new ShutdownUnconfirmedException(error); }
        finally { process?.Dispose(); }
    }

    private async Task<IReadOnlyList<DownloadJob>> ListJobsCoreAsync(CancellationToken cancellationToken)
    {
        var jobs = new List<DownloadJob>();
        var offset = 0;
        while (true)
        {
            using var parameters = JsonDocument.Parse(JsonSerializer.Serialize(new { offset, limit = 50 }));
            using var result = await CallAsync("jobs.list", parameters.RootElement, cancellationToken);
            var page = JsonSerializer.Deserialize<JobListResult>(result.RootElement.GetRawText(), JsonOptions)
                       ?? throw new InvalidDataException("The engine returned an invalid job list.");
            jobs.AddRange(page.Jobs);
            if (page.NextOffset is null) return jobs;
            if (!int.TryParse(page.NextOffset, out var next) || next <= offset)
                throw new InvalidDataException("The engine returned an invalid job-list cursor.");
            offset = next;
        }
    }

    private void EnsureEngineRunning()
    {
        if (_engineProcess is { HasExited: true })
        {
            _engineProcess.Dispose();
            _engineProcess = null;
            _engineLaunchAttempted = false;
        }
        if (_engineLaunchAttempted) return;
        _engineLaunchAttempted = true;
        var overridePath = Environment.GetEnvironmentVariable("SPEED_DOWNLOAD_ENGINE_PATH");
        var candidates = new[]
        {
            overridePath,
            Path.Combine(AppContext.BaseDirectory, "speed-download.exe"),
            Path.Combine(AppContext.BaseDirectory, "engine", "speed-download.exe"),
        };
        var executable = candidates.FirstOrDefault(path => !string.IsNullOrWhiteSpace(path) && File.Exists(path));
        if (executable is null) throw new FileNotFoundException("The Speed Download engine was not found beside the app. Set SPEED_DOWNLOAD_ENGINE_PATH to its location.");
        _engineProcess = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
        {
            FileName = executable,
            Arguments = "engine",
            WorkingDirectory = Path.GetDirectoryName(executable)!,
            UseShellExecute = false,
            CreateNoWindow = true,
        });
        if (_engineProcess is null) throw new InvalidOperationException("Windows did not start the Speed Download engine.");
    }

    public async Task<(ulong? Limit, bool? Scheduled)> GetEffectiveBandwidthAsync(CancellationToken cancellationToken = default)
    {
        using var parameters = JsonDocument.Parse("{}");
        using var result = await CallAsync("engine.status", parameters.RootElement, cancellationToken);
        ulong? limit = result.RootElement.TryGetProperty("effective_bandwidth_limit_bytes_per_second", out var limitValue) && limitValue.ValueKind == JsonValueKind.Number && limitValue.TryGetUInt64(out var value) ? value : null;
        bool? scheduled = result.RootElement.TryGetProperty("scheduled_bandwidth_active", out var flag) && (flag.ValueKind is JsonValueKind.True or JsonValueKind.False) ? flag.GetBoolean() : null;
        return (limit, scheduled);
    }

    public async Task<JsonObject> ProbeAsync(string url, CancellationToken cancellationToken = default)
    {
        using var parameters = JsonDocument.Parse(JsonSerializer.Serialize(new { url }));
        using var result = await CallAsync("jobs.probe", parameters.RootElement, cancellationToken);
        return JsonNode.Parse(result.RootElement.GetRawText())?.AsObject()
            ?? throw new InvalidDataException("The engine returned an invalid probe result.");
    }

    public async Task<JsonObject> PrepareTorrentAsync(string url, string[]? trackers = null, int offset = 0, CancellationToken cancellationToken = default)
    {
        using var parameters = JsonDocument.Parse(JsonSerializer.Serialize(new { url, trackers, offset },
            new JsonSerializerOptions { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull }));
        using var result = await CallAsync("torrents.prepare", parameters.RootElement, cancellationToken);
        return JsonNode.Parse(result.RootElement.GetRawText())?.AsObject()
            ?? throw new InvalidDataException("The engine returned invalid torrent metadata.");
    }

    public async Task AddTorrentAsync(string url, string name, string destination, string queueId,
        string infoHash, string[]? selectedFiles, string idempotencyKey, string? referenceUrl = null, CancellationToken cancellationToken = default)
    {
        using var parameters = JsonDocument.Parse(JsonSerializer.Serialize(new
        {
            url, name, destination, queue_id = queueId, torrent_info_hash = infoHash,
            selected_torrent_files = selectedFiles, idempotency_key = idempotencyKey, reference_url = referenceUrl,
        }));
        using var result = await CallAsync("jobs.add", parameters.RootElement, cancellationToken);
    }

    public async Task AddJobAsync(string url, string? name, string destination, int priority, string queueId = "main", string? idempotencyKey = null, string? expectedSha256 = null, string? referenceUrl = null, CancellationToken cancellationToken = default)
    {
        using var parameters = JsonDocument.Parse(JsonSerializer.Serialize(new
        {
            url,
            name = string.IsNullOrWhiteSpace(name) ? null : name,
            destination,
            priority,
            expected_sha256 = expectedSha256,
            reference_url = referenceUrl,
            queue_id = queueId,
            idempotency_key = idempotencyKey ?? Guid.NewGuid().ToString(),
        }));
        using var result = await CallAsync("jobs.add", parameters.RootElement, cancellationToken);
    }

    public async Task ReplaceSourceAsync(DownloadJob job, string url, CancellationToken cancellationToken = default)
    {
        using var parameters = JsonDocument.Parse(JsonSerializer.Serialize(new
        {
            job_id = job.JobId, expected_revision = job.Revision, url, restart = true,
        }));
        using var result = await CallAsync("jobs.replace-source", parameters.RootElement, cancellationToken);
    }

    public async Task ControlJobAsync(DownloadJob job, string action, CancellationToken cancellationToken = default)
    {
        using var parameters = JsonDocument.Parse(JsonSerializer.Serialize(new
        {
            job_id = job.JobId,
            action,
            expected_revision = job.Revision,
        }));
        using var result = await CallAsync("jobs.control", parameters.RootElement, cancellationToken);
    }

    public async Task SetJobBandwidthAsync(DownloadJob job, ulong bytesPerSecond, CancellationToken cancellationToken = default)
    {
        using var parameters = JsonDocument.Parse(JsonSerializer.Serialize(new
        {
            job_id = job.JobId, expected_revision = job.Revision, bandwidth_limit_bytes_per_second = bytesPerSecond,
        }));
        using var result = await CallAsync("jobs.set-bandwidth", parameters.RootElement, cancellationToken);
    }

    public async Task DeleteJobAsync(DownloadJob job, bool deletePartial = false, CancellationToken cancellationToken = default)
    {
        using var parameters = JsonDocument.Parse(JsonSerializer.Serialize(new
        {
            job_id = job.JobId,
            expected_revision = job.Revision,
            delete_partial = deletePartial,
        }));
        using var result = await CallAsync("jobs.delete", parameters.RootElement, cancellationToken);
    }

    public async Task ReorderJobAsync(DownloadJob job, int position, CancellationToken cancellationToken = default)
    {
        using var parameters = JsonDocument.Parse(JsonSerializer.Serialize(new
        {
            job_id = job.JobId, position, expected_revision = job.Revision,
        }));
        using var result = await CallAsync("jobs.reorder", parameters.RootElement, cancellationToken);
    }

    public async Task MoveJobToQueueAsync(DownloadJob job, string queueId, CancellationToken cancellationToken = default)
    {
        using var parameters = JsonDocument.Parse(JsonSerializer.Serialize(new
        {
            job_id = job.JobId,
            queue_id = queueId,
            expected_revision = job.Revision,
        }));
        using var result = await CallAsync("jobs.move-queue", parameters.RootElement, cancellationToken);
    }

    public async Task<ulong> GetGlobalBandwidthLimitAsync(CancellationToken cancellationToken = default)
    {
        using var parameters = JsonDocument.Parse("{}");
        using var result = await CallAsync("settings.get", parameters.RootElement, cancellationToken);
        return result.RootElement.GetProperty("bandwidth_limit_bytes_per_second").GetUInt64();
    }

    public async Task<JsonObject> GetSettingsAsync(CancellationToken cancellationToken = default)
    {
        using var parameters = JsonDocument.Parse("{}");
        using var result = await CallAsync("settings.get", parameters.RootElement, cancellationToken);
        return JsonNode.Parse(result.RootElement.GetRawText())?.AsObject()
            ?? throw new InvalidDataException("The engine returned invalid settings.");
    }

    public async Task UpdateSettingsAsync(JsonObject settings, CancellationToken cancellationToken = default)
    {
        using var parameters = JsonDocument.Parse(JsonSerializer.Serialize(new { settings }));
        using var result = await CallAsync("settings.update", parameters.RootElement, cancellationToken);
    }

    public async Task SetGlobalBandwidthLimitAsync(ulong bytesPerSecond, CancellationToken cancellationToken = default)
    {
        using var empty = JsonDocument.Parse("{}");
        using var current = await CallAsync("settings.get", empty.RootElement, cancellationToken);
        var settings = JsonNode.Parse(current.RootElement.GetRawText())?.AsObject()
            ?? throw new InvalidDataException("The engine returned invalid settings.");
        settings["bandwidth_limit_bytes_per_second"] = JsonValue.Create(bytesPerSecond);
        using var parameters = JsonDocument.Parse(JsonSerializer.Serialize(new { settings }));
        using var result = await CallAsync("settings.update", parameters.RootElement, cancellationToken);
    }

    private async Task<JsonDocument> CallAsync(string method, JsonElement parameters, CancellationToken cancellationToken, Action<NamedPipeClientStream>? onConnected = null)
    {
        await using var pipe = new NamedPipeClientStream(
            ".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Identification);
        await pipe.ConnectAsync(5_000, cancellationToken);
        onConnected?.Invoke(pipe);

        using var hello = JsonDocument.Parse("""
            {"protocol":{"major":1,"minor":0},"client":{"kind":"windows-winui","version":"0.1.0"},"features":["jobs.probe","jobs.worker-progress","jobs.probe-filename-decoding","torrents.prepare-v1","torrents.file-selection-v1","jobs.per-job-bandwidth","jobs.reference-page-v1","jobs.source-refresh-v1","jobs.move-queue-v1","queue.finish-user-command-v1","queue.windows-finish-actions-v1","proxy.windows-credentials-v1","proxy.windows-system-v1","engine.shutdown-v1"]}
            """);
        using var helloResult = await RequestAsync(pipe, "engine.hello", hello.RootElement, cancellationToken);
        var handshake = JsonSerializer.Deserialize<HelloResult>(helloResult.RootElement.GetRawText(), JsonOptions)
                        ?? throw new InvalidDataException("Engine returned an invalid hello response.");
        _features = new HashSet<string>(handshake.Features, StringComparer.Ordinal);
        if (!handshake.Features.Contains("jobs.probe") || !handshake.Features.Contains("jobs.worker-progress") ||
            !handshake.Features.Contains("jobs.probe-filename-decoding"))
            throw new EngineOutdatedException();
        void RequireFeature(string feature, string description)
        {
            if (!handshake.Features.Contains(feature))
                throw new InvalidOperationException($"The running engine does not support {description}. Update and restart the engine, then try again.");
        }
        if (method == "torrents.prepare") RequireFeature("torrents.prepare-v1", "torrent review");
        if (method == "engine.shutdown") RequireFeature("engine.shutdown-v1", "graceful engine shutdown");
        if (method == "jobs.set-bandwidth") RequireFeature("jobs.per-job-bandwidth", "per-download speed limits");
        if (method == "jobs.replace-source") RequireFeature("jobs.source-refresh-v1", "replacing download links");
        if (method == "jobs.move-queue") RequireFeature("jobs.move-queue-v1", "moving downloads between queues");
        if (method == "jobs.add" && parameters.TryGetProperty("selected_torrent_files", out var selected) && selected.ValueKind == JsonValueKind.Array)
            RequireFeature("torrents.file-selection-v1", "selecting individual torrent files");
        if (method == "jobs.add" && parameters.TryGetProperty("reference_url", out var reference) && reference.ValueKind == JsonValueKind.String)
            RequireFeature("jobs.reference-page-v1", "saving download reference pages");
        return await RequestAsync(pipe, method, parameters, cancellationToken);
    }

    private static async Task<JsonDocument> RequestAsync(Stream pipe, string method, JsonElement parameters, CancellationToken cancellationToken)
    {
        var id = Guid.NewGuid().ToString("N");
        var payload = JsonSerializer.SerializeToUtf8Bytes(new
        {
            jsonrpc = "2.0",
            id,
            method,
            @params = parameters,
        });
        if (payload.Length is 0 or > MaxFrameSize) throw new InvalidDataException("IPC frame exceeds the supported size.");

        var prefix = new byte[sizeof(uint)];
        BinaryPrimitives.WriteUInt32LittleEndian(prefix, (uint)payload.Length);
        await pipe.WriteAsync(prefix, cancellationToken);
        await pipe.WriteAsync(payload, cancellationToken);
        await pipe.FlushAsync(cancellationToken);

        await ReadExactlyAsync(pipe, prefix, cancellationToken);
        var length = BinaryPrimitives.ReadUInt32LittleEndian(prefix);
        if (length is 0 or > MaxFrameSize) throw new InvalidDataException("Engine sent an invalid IPC frame length.");
        var responseBytes = new byte[checked((int)length)];
        await ReadExactlyAsync(pipe, responseBytes, cancellationToken);
        var response = JsonDocument.Parse(responseBytes);
        var root = response.RootElement;
        if (!root.TryGetProperty("id", out var responseId) || responseId.GetString() != id)
        {
            response.Dispose();
            throw new InvalidDataException("Engine response id did not match the request.");
        }
        if (root.TryGetProperty("error", out var error))
        {
            var message = error.TryGetProperty("message", out var text) ? text.GetString() : null;
            response.Dispose();
            throw new InvalidOperationException(message ?? "The engine rejected the request.");
        }
        if (!root.TryGetProperty("result", out var result))
        {
            response.Dispose();
            throw new InvalidDataException("Engine response has no result.");
        }
        return JsonDocument.Parse(result.GetRawText());
    }

    private static async Task ReadExactlyAsync(Stream stream, Memory<byte> buffer, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var count = await stream.ReadAsync(buffer[offset..], cancellationToken);
            if (count == 0) throw new EndOfStreamException("Engine closed the IPC connection.");
            offset += count;
        }
    }

    private static int ProcessSessionId()
    {
        using var process = System.Diagnostics.Process.GetCurrentProcess();
        return process.SessionId;
    }

    private sealed class JobListResult
    {
        public JobListResult() { }
        public List<DownloadJob> Jobs { get; init; } = [];
        [System.Text.Json.Serialization.JsonPropertyName("next_offset")]
        public string? NextOffset { get; init; }
    }

    private sealed class HelloResult
    {
        public List<string> Features { get; init; } = [];
    }

    private sealed class EngineOutdatedException : InvalidOperationException
    {
        public EngineOutdatedException() : base("The running engine is outdated and must be restarted.") { }
    }
}
