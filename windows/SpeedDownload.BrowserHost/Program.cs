using System.Buffers.Binary;
using System.Diagnostics;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

// Native messaging uses a four-byte little-endian length followed by UTF-8 JSON.
// This bridge only contacts the GUI; it never connects to the download engine.
const int maximumMessageBytes = 256 * 1024;
var input = Console.OpenStandardInput();
var output = Console.OpenStandardOutput();
async Task ReplyAsync(object value)
{
    var bytes = JsonSerializer.SerializeToUtf8Bytes(value);
    var header = new byte[4];
    BinaryPrimitives.WriteInt32LittleEndian(header, bytes.Length);
    await output.WriteAsync(header);
    await output.WriteAsync(bytes);
    await output.FlushAsync();
}
try
{
    var arguments = Environment.GetCommandLineArgs().Skip(1).ToArray();
    const string chromeOrigin = "chrome-extension://fcjiipabggcamlocakedfideaamdgknn/";
    const string firefoxExtension = "speed-download@mjkhaani.github";
    var chromium = (arguments.Length is 1 or 2) && string.Equals(arguments[0], chromeOrigin, StringComparison.Ordinal) &&
        (arguments.Length == 1 || arguments[1].StartsWith("--parent-window=", StringComparison.Ordinal));
    var firefox = arguments.Length == 2 && Path.IsPathFullyQualified(arguments[0]) && string.Equals(arguments[1], firefoxExtension, StringComparison.Ordinal);
    if (!chromium && !firefox) throw new InvalidDataException("Unrecognized browser origin.");
    var header = new byte[4];
    await input.ReadExactlyAsync(header);
    var length = BinaryPrimitives.ReadInt32LittleEndian(header);
    if (length is <= 0 or > maximumMessageBytes) throw new InvalidDataException("Invalid message length.");
    var bytes = new byte[length];
    await input.ReadExactlyAsync(bytes);
    using var request = JsonDocument.Parse(bytes);
    var root = request.RootElement;
    if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("version", out var version) ||
        !version.TryGetInt32(out var versionNumber) || versionNumber != 1 ||
        !root.TryGetProperty("action", out var actionValue) || actionValue.ValueKind != JsonValueKind.String)
        throw new InvalidDataException("Invalid request.");
    var action = actionValue.GetString();
    var app = Path.Combine(AppContext.BaseDirectory, "SpeedDownload.exe");
    if (action == "status") { await ReplyAsync(new { version = 1, ok = true, client_available = File.Exists(app) }); return; }
    if (action == "preferences")
    {
        // The GUI writes this non-secret setting for the browser bridge.
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SpeedDownload", "browser-extensions.txt");
        var extensions = File.Exists(path) ? await File.ReadAllTextAsync(path) : "zip,rar,7z,dmg,pkg,exe,msi,iso,pdf,mp4,mp3,torrent";
        if (extensions.Length > 4096) throw new InvalidDataException("Invalid browser preferences.");
        await ReplyAsync(new { version = 1, ok = true, browser_grab_extensions = extensions }); return;
    }
    if (action is not ("add" or "torrent" or "batch") || !root.TryGetProperty("idempotency_key", out var key) ||
        key.ValueKind != JsonValueKind.String || !Guid.TryParseExact(key.GetString(), "D", out _)) throw new InvalidDataException("Invalid request.");
    if (!File.Exists(app)) throw new FileNotFoundException("Speed Download client was not found.");
    var sid = WindowsIdentity.GetCurrent().User?.Value ?? throw new InvalidOperationException("Cannot identify the current user.");
    var name = $"SpeedDownload.Gui.Activation-{sid}-{Process.GetCurrentProcess().SessionId}";
    using var pipe = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
    try { await pipe.ConnectAsync(300); }
    catch (TimeoutException)
    {
        Process.Start(new ProcessStartInfo(app) { UseShellExecute = true });
        await pipe.ConnectAsync(5000);
    }
    using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, true) { AutoFlush = true };
    using var reader = new StreamReader(pipe, Encoding.UTF8, true, 1024, true);
    await writer.WriteLineAsync(JsonSerializer.Serialize(root));
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
    var response = await reader.ReadLineAsync(timeout.Token);
    if (response != "accepted") throw new InvalidOperationException("The client did not accept the request.");
    await ReplyAsync(new { version = 1, ok = true, dialog_opened = true });
}
catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or InvalidDataException or InvalidOperationException or TimeoutException or OperationCanceledException or System.ComponentModel.Win32Exception)
{
    await ReplyAsync(new { version = 1, ok = false, error_message = "Could not hand off the request to Speed Download." });
}
