using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;

namespace SpeedDownload;

// Ask the shell for the registered file-type icon without opening the file.
internal static class ShellFileIcon
{
    private const uint Icon = 0x000000100;
    private const uint SmallIcon = 0x000000001;
    private const uint UseFileAttributes = 0x000000010;
    private const uint FileAttributeNormal = 0x000000080;
    private static readonly Dictionary<string, Task<ImageSource?>> Cache = new(StringComparer.OrdinalIgnoreCase);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ShellFileInfo
    {
        public IntPtr IconHandle;
        public int IconIndex;
        public uint Attributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string DisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string TypeName;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SHGetFileInfo(string path, uint fileAttributes, out ShellFileInfo info, uint infoSize, uint flags);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr icon);

    public static string KeyForName(string name)
    {
        try
        {
            var extension = Path.GetExtension(name);
            return extension.Length is > 1 and <= 32 && extension.All(ch => char.IsAsciiLetterOrDigit(ch) || ch == '.') ? extension : "";
        }
        catch (ArgumentException) { return ""; }
    }

    public static Task<ImageSource?> GetAsync(string extension)
    {
        if (!Cache.TryGetValue(extension, out var task)) Cache[extension] = task = LoadAsync(extension);
        return task;
    }

    private static async Task<ImageSource?> LoadAsync(string extension)
    {
        var result = SHGetFileInfo("file" + extension, FileAttributeNormal, out var info,
            (uint)Marshal.SizeOf<ShellFileInfo>(), Icon | SmallIcon | UseFileAttributes);
        if (result == IntPtr.Zero || info.IconHandle == IntPtr.Zero) return null;
        try
        {
            using var icon = System.Drawing.Icon.FromHandle(info.IconHandle);
            using var bitmap = icon.ToBitmap();
            using var memory = new MemoryStream();
            bitmap.Save(memory, System.Drawing.Imaging.ImageFormat.Png);
            using var stream = new InMemoryRandomAccessStream();
            using var writer = new DataWriter(stream.GetOutputStreamAt(0));
            writer.WriteBytes(memory.ToArray());
            await writer.StoreAsync();
            await writer.FlushAsync();
            stream.Seek(0);
            var source = new BitmapImage();
            await source.SetSourceAsync(stream);
            return source;
        }
        catch (Exception error) when (error is ExternalException or IOException or ArgumentException)
        {
            return null;
        }
        finally { DestroyIcon(info.IconHandle); }
    }
}
