using Microsoft.Win32;
using System.Text.Json;

namespace SpeedDownload;

// GUI-owned preferences are separate from the engine's per-user settings.
internal sealed class ClientPreferences
{
    public bool StartMinimized { get; set; }
    public string CloseAction { get; set; } = "hide";
    public string LastQueueId { get; set; } = "main";
    public bool NotifyCompleted { get; set; } = true;
    public bool NotifyFailed { get; set; } = true;
    private static string DirectoryPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SpeedDownload");
    private static string FilePath => Path.Combine(DirectoryPath, "client-preferences.json");

    public static ClientPreferences Load()
    {
        if (!File.Exists(FilePath)) return new ClientPreferences();
        var value = JsonSerializer.Deserialize<ClientPreferences>(File.ReadAllText(FilePath)) ?? new ClientPreferences();
        if (value.CloseAction is not ("hide" or "exit" or "stop")) value.CloseAction = "hide";
        if (string.IsNullOrWhiteSpace(value.LastQueueId)) value.LastQueueId = "main";
        return value;
    }

    public void Save()
    {
        Directory.CreateDirectory(DirectoryPath);
        var temporary = Path.Combine(DirectoryPath, $"client-preferences-{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(this));
            File.Move(temporary, FilePath, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    public static bool LaunchOnLoginEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        return key?.GetValue("SpeedDownload") is string command && !string.IsNullOrWhiteSpace(command);
    }

    public static void SetLaunchOnLogin(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (!enabled) { key.DeleteValue("SpeedDownload", false); return; }
        var exe = Environment.ProcessPath ?? throw new InvalidOperationException("Cannot locate the app executable.");
        if (!Path.IsPathFullyQualified(exe) || !File.Exists(exe)) throw new InvalidOperationException("The app executable is unavailable.");
        key.SetValue("SpeedDownload", $"\"{exe}\" --startup");
    }
}
