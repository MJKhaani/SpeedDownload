# Interactive Windows GUI check for Phase 0

The engine and WPF client build and pass GUI startup, visible progress, and
engine restart/reconnect smoke tests on Windows x64 and ARM64 GitHub runners.
The original WinUI build crashed before managed startup; WPF is the packaged
Windows client. An interactive desktop check is still needed.

1. Open the latest [Phase 0 workflow run](https://github.com/MJKhaani/SpeedDownload/actions/workflows/phase0.yml), then download **SpeedDownload-Windows-X64** for an x64 PC or **SpeedDownload-Windows-ARM64** for an ARM64 PC. Extract the artifact.
2. Quit any running Speed Download client and engine. The smoke script refuses to run while another engine owns the per-user named pipe.
3. In PowerShell, from the extracted artifact's top directory, run:

   ```powershell
   python tests\integration\windows_client.py windows\SpeedDownload.Wpf\publish\speed-download.exe windows\SpeedDownload.Wpf\publish\SpeedDownload.exe
   ```

The script launches the published window and an isolated engine, serves a slow
local test download, checks that the window reports intermediate progress,
terminates the engine, and checks that the window reconnects to a new engine
instance. It removes its temporary state and stops its test processes.

If Python is unavailable, launch `windows\SpeedDownload.Wpf\publish\SpeedDownload.exe`
from the extracted artifact and check that a window appears with **Engine
connected**. That manual check covers startup and connection only; the script
is needed to verify progress and restart behavior.

Record the Windows version and CPU, the script's final line or traceback, and
whether the window appeared. A passing interactive result can confirm the
experimental status in the [support matrix](support-matrix.md).
