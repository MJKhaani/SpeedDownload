using System.Runtime.InteropServices;

namespace SpeedDownload;

// ITaskbarList3 is available on Windows 7 and later. Failure to initialize it
// must not prevent the client from starting (for example, without Explorer).
internal sealed class TaskbarProgress : IDisposable
{
    private readonly nint _window;
    private ITaskbarList3? _taskbar;

    internal TaskbarProgress(nint window)
    {
        _window = window;
        try
        {
            var type = Type.GetTypeFromCLSID(new Guid("56FDF344-FD6D-11D0-958A-006097C9A090"), true)!;
            _taskbar = (ITaskbarList3)Activator.CreateInstance(type)!;
            Marshal.ThrowExceptionForHR(_taskbar.HrInit());
        }
        catch (Exception error) when (error is COMException or InvalidCastException or PlatformNotSupportedException)
        {
            Dispose();
        }
    }

    internal void Update(IEnumerable<DownloadJob> jobs)
    {
        if (_taskbar is null) return;
        try
        {
            var active = jobs.Where(job => job.State is "resolving" or "connecting" or "downloading" or "verifying").ToArray();
            if (active.Length == 0)
                _taskbar.SetProgressState(_window, ProgressState.None);
            else if (active.Any(job => job.Total == 0))
                _taskbar.SetProgressState(_window, ProgressState.Indeterminate);
            else
            {
                decimal total = 0, completed = 0;
                foreach (var job in active)
                {
                    total += job.Total;
                    completed += Math.Min(job.Completed, job.Total);
                }
                const ulong scale = 1_000_000;
                var value = (ulong)Math.Min(scale - 1, decimal.Floor(completed * scale / total));
                _taskbar.SetProgressState(_window, ProgressState.Normal);
                _taskbar.SetProgressValue(_window, value, scale);
            }
        }
        catch (COMException) { Dispose(); }
    }

    public void Dispose()
    {
        if (_taskbar is null) return;
        Marshal.ReleaseComObject(_taskbar);
        _taskbar = null;
    }

    private enum ProgressState : uint { None = 0, Indeterminate = 1, Normal = 2 }

    [ComImport, Guid("EA1AFB91-9E28-4B86-90E9-9E9F8A5EEA84"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITaskbarList3
    {
        [PreserveSig] int HrInit();
        [PreserveSig] int AddTab(nint window);
        [PreserveSig] int DeleteTab(nint window);
        [PreserveSig] int ActivateTab(nint window);
        [PreserveSig] int SetActiveAlt(nint window);
        [PreserveSig] int MarkFullscreenWindow(nint window, [MarshalAs(UnmanagedType.Bool)] bool fullscreen);
        [PreserveSig] int SetProgressValue(nint window, ulong completed, ulong total);
        [PreserveSig] int SetProgressState(nint window, ProgressState state);
    }
}
