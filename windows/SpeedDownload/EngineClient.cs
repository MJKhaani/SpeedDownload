using System.Buffers.Binary;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace SpeedDownload;

internal sealed class EngineClient
{
    private const int MaxFrameSize = 1_048_576;
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    private bool _engineLaunchAttempted;
    private System.Diagnostics.Process? _engineProcess;

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

    private async Task<IReadOnlyList<DownloadJob>> ListJobsCoreAsync(CancellationToken cancellationToken)
    {
        var jobs = new List<DownloadJob>();
        var offset = 0;
        while (true)
        {
            using var parameters = JsonDocument.Parse(JsonSerializer.Serialize(new { offset, limit = 100 }));
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

    public async Task AddJobAsync(string url, string? name, string destination, int priority, CancellationToken cancellationToken = default)
    {
        using var parameters = JsonDocument.Parse(JsonSerializer.Serialize(new
        {
            url,
            name = string.IsNullOrWhiteSpace(name) ? null : name,
            destination,
            priority,
            idempotency_key = Guid.NewGuid().ToString(),
        }));
        using var result = await CallAsync("jobs.add", parameters.RootElement, cancellationToken);
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

    private async Task<JsonDocument> CallAsync(string method, JsonElement parameters, CancellationToken cancellationToken)
    {
        await using var pipe = new NamedPipeClientStream(
            ".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Identification);
        await pipe.ConnectAsync(5_000, cancellationToken);

        using var hello = JsonDocument.Parse("""
            {"protocol":{"major":1,"minor":0},"client":{"kind":"windows-winui","version":"0.1.0"},"features":[]}
            """);
        using var helloResult = await RequestAsync(pipe, "engine.hello", hello.RootElement, cancellationToken);
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
}
