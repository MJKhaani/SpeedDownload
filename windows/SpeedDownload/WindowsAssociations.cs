using Microsoft.Win32;
using System.Runtime.InteropServices;

namespace SpeedDownload;

// Registers a candidate handler for the current user. Windows owns the default choice.
internal static class WindowsAssociations
{
    private const string ApplicationKey = @"Software\SpeedDownload\Capabilities";
    private const string TorrentProgId = "SpeedDownload.Torrent";
    private const string MagnetProgId = "SpeedDownload.Magnet";

    [DllImport("shell32.dll")]
    private static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);

    public static bool IsRegisteredForCurrentExecutable()
    {
        var exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe)) return false;
        var command = $"\"{exe}\" \"%1\"";
        using var torrent = Registry.CurrentUser.OpenSubKey(@"Software\Classes\" + TorrentProgId + @"\shell\open\command");
        using var magnet = Registry.CurrentUser.OpenSubKey(@"Software\Classes\" + MagnetProgId + @"\shell\open\command");
        using var registered = Registry.CurrentUser.OpenSubKey(@"Software\RegisteredApplications");
        return string.Equals(torrent?.GetValue("") as string, command, StringComparison.OrdinalIgnoreCase) &&
            string.Equals(magnet?.GetValue("") as string, command, StringComparison.OrdinalIgnoreCase) &&
            string.Equals(registered?.GetValue("Speed Download") as string, ApplicationKey, StringComparison.OrdinalIgnoreCase);
    }

    public static void Register()
    {
        var exe = Environment.ProcessPath ?? throw new InvalidOperationException("Cannot find the Speed Download executable.");
        if (!Path.IsPathFullyQualified(exe) || !File.Exists(exe)) throw new InvalidOperationException("The application executable is unavailable.");
        var command = $"\"{exe}\" \"%1\"";
        WriteProgId(TorrentProgId, "Speed Download torrent file", exe, command, false);
        WriteProgId(MagnetProgId, "Speed Download magnet link", exe, command, true);
        using (var openWith = Registry.CurrentUser.CreateSubKey(@"Software\Classes\.torrent\OpenWithProgids"))
            openWith.SetValue(TorrentProgId, Array.Empty<byte>(), RegistryValueKind.None);
        using (var capabilities = Registry.CurrentUser.CreateSubKey(ApplicationKey))
        {
            capabilities.SetValue("ApplicationName", "Speed Download");
            capabilities.SetValue("ApplicationDescription", "Review torrent files and magnet links in Speed Download.");
            using var files = capabilities.CreateSubKey("FileAssociations");
            files.SetValue(".torrent", TorrentProgId);
            using var urls = capabilities.CreateSubKey("URLAssociations");
            urls.SetValue("magnet", MagnetProgId);
        }
        using (var apps = Registry.CurrentUser.CreateSubKey(@"Software\RegisteredApplications"))
            apps.SetValue("Speed Download", ApplicationKey);
        SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero); // SHCNE_ASSOCCHANGED
    }

    public static void RegisterBrowserHosts()
    {
        var host = Path.Combine(AppContext.BaseDirectory, "SpeedDownload.BrowserHost.exe");
        if (!File.Exists(host)) throw new FileNotFoundException("The browser host is not included in this build.");
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SpeedDownload", "NativeMessaging");
        Directory.CreateDirectory(directory);
        var chrome = Path.Combine(directory, "chrome.json");
        var firefox = Path.Combine(directory, "firefox.json");
        File.WriteAllText(chrome, System.Text.Json.JsonSerializer.Serialize(new
        {
            name = "com.mjkhaani.speeddownload", description = "Speed Download client handoff", path = host, type = "stdio",
            allowed_origins = new[] { "chrome-extension://fcjiipabggcamlocakedfideaamdgknn/" },
        }));
        File.WriteAllText(firefox, System.Text.Json.JsonSerializer.Serialize(new
        {
            name = "com.mjkhaani.speeddownload", description = "Speed Download client handoff", path = host, type = "stdio",
            allowed_extensions = new[] { "speed-download@mjkhaani.github" },
        }));
        foreach (var browser in new[] { @"Software\Google\Chrome\NativeMessagingHosts", @"Software\Microsoft\Edge\NativeMessagingHosts", @"Software\Chromium\NativeMessagingHosts" })
        {
            using var key = Registry.CurrentUser.CreateSubKey(browser + @"\com.mjkhaani.speeddownload");
            key.SetValue("", chrome);
        }
        using var mozilla = Registry.CurrentUser.CreateSubKey(@"Software\Mozilla\NativeMessagingHosts\com.mjkhaani.speeddownload");
        mozilla.SetValue("", firefox);
    }

    private static void WriteProgId(string progId, string description, string exe, string command, bool protocol)
    {
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Classes\" + progId);
        key.SetValue("", description);
        if (protocol) key.SetValue("URL Protocol", "");
        using (var icon = key.CreateSubKey("DefaultIcon")) icon.SetValue("", $"\"{exe}\",0");
        using var open = key.CreateSubKey(@"shell\open\command");
        open.SetValue("", command);
    }
}
