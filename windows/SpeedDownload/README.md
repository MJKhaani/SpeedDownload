# Speed Download for Windows

This directory contains the native WinUI 3 desktop client and its framed
JSON-RPC named-pipe client. It implements the UI-side handshake, job listing,
add, start, pause, resume, retry, cancel, progress, and reconnect polling.

Build on Windows with the .NET 10 SDK and Windows App SDK 2.4:

```powershell
dotnet publish .\SpeedDownload.csproj -c Release -r win-x64 -p:Platform=x64 --self-contained true
```

The Zig engine includes a Windows named-pipe listener at
`\\.\pipe\SpeedDownload-<user-SID>-<session-id>`, with a private user/SYSTEM
DACL and remote-client rejection. The engine cross-compiles from macOS for
x86_64 Windows; the WinUI project and pipe runtime have not yet been built or
validated on Windows.
