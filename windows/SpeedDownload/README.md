# Speed Download for Windows

This directory contains the native WinUI 3 desktop client and its framed
JSON-RPC named-pipe client. It implements the UI-side handshake, job listing,
add, start, pause, resume, retry, cancel, progress, and reconnect polling.

Build on Windows with the .NET 10 SDK and Windows App SDK 2.4:

```powershell
dotnet publish .\SpeedDownload.csproj -c Release -r win-x64 -p:Platform=x64 --self-contained true
```

The Zig engine's Windows named-pipe listener and pipe ACLs are not implemented
yet, so this client cannot connect to the current engine. The project has not
been built or runtime-validated on Windows.
