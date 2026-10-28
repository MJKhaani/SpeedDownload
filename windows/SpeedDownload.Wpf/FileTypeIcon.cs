using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace SpeedDownload;

internal static class FileTypeIcon
{
    private const uint FileAttributeNormal = 0x80;
    private const uint Icon = 0x100;
    private const uint SmallIcon = 0x1;
    private const uint UseFileAttributes = 0x10;
    private static readonly Dictionary<string, ImageSource> Cache = new(StringComparer.OrdinalIgnoreCase);

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
    private static extern IntPtr SHGetFileInfo(string path, uint attributes, ref ShellFileInfo info, uint size, uint flags);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr icon);

    public static ImageSource? ForName(string name)
    {
        var extension = Path.GetExtension(name);
        if (string.IsNullOrEmpty(extension)) extension = ".bin";
        if (Cache.TryGetValue(extension, out var cached)) return cached;
        var info = new ShellFileInfo();
        if (SHGetFileInfo("file" + extension, FileAttributeNormal, ref info,
                (uint)Marshal.SizeOf<ShellFileInfo>(), Icon | SmallIcon | UseFileAttributes) == IntPtr.Zero || info.IconHandle == IntPtr.Zero)
            return null;
        try
        {
            var source = Imaging.CreateBitmapSourceFromHIcon(info.IconHandle, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            source.Freeze();
            Cache[extension] = source;
            return source;
        }
        finally { _ = DestroyIcon(info.IconHandle); }
    }
}
