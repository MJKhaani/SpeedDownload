# Speed Download for Windows

This directory contains the native WinUI 3 desktop client and its framed
JSON-RPC named-pipe client. It implements the UI-side handshake, job listing,
add, start, pause, resume, retry, cancel, progress, and reconnect polling.
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
x86_64 Windows; the WinUI project and pipe runtime have not yet been built or
validated on Windows.
