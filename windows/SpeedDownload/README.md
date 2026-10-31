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
DACL and remote-client rejection. Earlier alpha ZIPs shipped the separately
documented [WPF compatibility client](../SpeedDownload.Wpf/README.md).

The WinUI alpha still fails during `MainWindow.xaml` initialization on Windows
Server 2022 and hosted Windows 11 ARM64. The current managed exception is
`XamlParseException` (`0x802B000A`), followed by a WinUI stowed-exception
fail-fast (`0xC000027B`). The client records the HRESULT, managed stack, and
inner exception text in
`%LOCALAPPDATA%\SpeedDownload\logs\client-crash.log`; the previous log rotates
to `client-crash.previous.log` after 1 MiB. The log may contain local paths, so
review it before sharing. A native dump is still needed when XAML does not
expose the underlying parse location.

The WinUI client must pass the Windows GUI and IPC startup smoke before it can
replace WPF as a verified client.
