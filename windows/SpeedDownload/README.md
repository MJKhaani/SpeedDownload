# Speed Download for Windows

This directory contains the planned native WinUI 3 / Fluent UI desktop client and its framed
JSON-RPC named-pipe client. It implements the UI-side handshake, job listing,
add, start, pause, resume, retry, cancel, progress, and reconnect polling.
The redesigned shell uses Mica, an integrated title bar, adaptive library and
queue navigation, a command bar, a native transfer list, and a responsive
details pane. The built-in Settings destination edits the engine's persisted
download, network, bandwidth, browser, and diagnostic settings. Queue settings
can change the active-download limit and enable an existing weekly schedule.
The settings update call always sends the complete engine-owned document.
When no engine is listening, the client starts the bundled `speed-download.exe`
beside the GUI executable, or the path configured in
`SPEED_DOWNLOAD_ENGINE_PATH`, then retries the named-pipe connection.

Build the Zig engine first so `dotnet publish` can copy it beside the GUI:

```powershell
New-Item -ItemType Directory -Force ..\..\zig-out\bin | Out-Null
zig build-exe ..\..\src\main.zig -femit-bin=..\..\zig-out\bin\speed-download.exe
dotnet publish .\SpeedDownload.csproj -c Release -r win-x64 -p:Platform=x64 --self-contained true
```

The Zig engine includes a Windows named-pipe listener at
`\\.\pipe\SpeedDownload-<user-SID>-<session-id>`, with a private user/SYSTEM
DACL and remote-client rejection. The engine cross-compiles from macOS for
x86_64 Windows. The WinUI project builds but currently exits before managed
startup on Windows Server 2022 and hosted Windows 11 ARM64 with `0xC0000409`.
The alpha ZIP therefore ships the separately documented [WPF compatibility
client](../SpeedDownload.Wpf/README.md). WinUI 3 remains the required Windows
client target; its runtime, packaging, and Fluent UI need to pass the same GUI
and IPC checks before it replaces WPF.

The WinUI shell changes above have only been checked for XAML well-formedness
on macOS. A Windows .NET build, startup check, named-pipe smoke test, keyboard
and accessibility review, and the existing `0xC0000409` startup investigation
are still required before this can replace the compatibility ZIP.
