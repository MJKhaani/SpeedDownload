# Speed Download for Windows

This directory contains the WinUI 3 / Fluent UI client and its framed JSON-RPC
named-pipe client. It connects to the engine, displays downloads, controls jobs,
reviews HTTP/HTTPS and anonymous FTP/FTPS links, and edits engine settings.
The in-progress client also includes torrent review, named queues, weekly queue
and bandwidth schedules, close-to-background behavior, and optional per-user
sign-in and start-minimized preferences.

The desktop collection uses a native WinUI list with the card-style transfer
rows used in alpha.11. It supports multiple selection, row actions and sorting;
its accessibility and narrow-window behavior require Windows testing. The
project pins `Microsoft.WindowsAppSDK` 2.5.1.

The current development changes have not yet been built or interactively tested
on Windows. They do not yet fulfill the complete Windows client specification:
full torrent details, notification activation validation, accessibility validation,
and other features remain. See
[WINDOWS_CLIENT.md](../WINDOWS_CLIENT.md) for the intended contract; it is not a
claim of implementation. Torrent seeding is not currently supported by the
engine on Windows.

Settings include a saved System, English, or Persian language choice. Persian
mirrors the main layout and translates the navigation and key settings labels;
many dialogs, status messages, and controls remain in English. URL and path
fields are kept left-to-right. The weekly schedule editors include keyboard
navigation, accessible cell names, a day/time alternative, and a local-time
preview. Narrator, right-to-left layout, contrast, scaling, daylight-saving
transitions, and sleep/wake behavior still require interactive validation.

The notification-area menu can open the client, pause active and queued work,
resume paused work, quit the client while the engine continues, or confirm a
graceful engine stop after pausing active and waiting downloads. Queue settings
can run a user command, quit the client, or request a Windows shutdown when all
jobs in the queue complete; Windows shutdown requires explicit confirmation in
the settings. Taskbar progress uses active jobs' reported
completed and total bytes and becomes indeterminate when a total is unknown.
These additions require an interactive Windows build and test, including the
failure cases; do not treat cross-compilation as Windows runtime validation.

System proxy mode reads Windows user settings and can resolve automatic proxy
configuration. Manual proxy credentials are stored in Windows Credential
Manager for the configured endpoint, not in engine settings. HTTP proxy
authentication is supported for HTTP destinations; authenticated HTTPS CONNECT,
SOCKS, and authenticated system proxies are not supported. The engine fails
closed for unsupported proxy configurations. These changes require Windows
runtime and interoperability testing.

Completion and failure notifications are configurable separately and contain
no filenames, paths, or URLs. They detect transitions while the GUI is running;
the GUI does not generate notifications for work completed entirely while it
was closed. Windows notification availability and activation, including on
elevated or Server installations, require interactive Windows testing.

Torrent review loads paged metadata into a scrollable file list with folder
navigation, path filtering, and visible-item selection. It shows file sizes and
preserves selection across filters. File priorities and a unified hierarchical
file tree are not implemented, and this review still needs interactive Windows
testing.

When no engine is listening, the client starts the bundled `speed-download.exe`
beside the GUI executable, or the path configured in
`SPEED_DOWNLOAD_ENGINE_PATH`, then retries the named-pipe connection. It does not
terminate an incompatible running engine automatically. Settings offers per-user
registration as a torrent and magnet handler; Windows controls the default choice.
This registration and activation flow still require Windows testing. Settings also
provides per-user Chrome, Edge, Chromium, and Firefox native-host registration.
Install the matching browser extension separately; the host forwards reviewed
requests to the client and never connects to the engine. Browser handoff is
implemented but has not yet been tested on Windows.

The client registers itself as an available torrent and magnet handler for the
current Windows user when it starts. Windows still controls the user's default
app, which can be chosen in Windows Settings. When diagnostic logging is enabled,
the engine normally writes `%LOCALAPPDATA%\Speed Download\engine-debug.log`.
`SPEED_DOWNLOAD_STATE_DIR` can override that directory for an engine process;
the Settings page shows the expected location and can open its folder. The file
is created on the first logged action after logging is enabled.

The download workspace also accepts a dropped HTTP/HTTPS, FTP/FTPS, or magnet link, a
newline-separated set of up to 100 such links, or one local `.torrent` file.
Each drop opens a review flow before adding work. Drag-and-drop interoperability
with Windows browsers and Explorer still needs interactive Windows testing.
The Paste download link command and Ctrl+V outside text controls likewise open
review for HTTP, HTTPS, FTP, FTPS, or magnet links; they do not submit a download
directly. Clipboard integration still needs an interactive Windows test.

Build the Zig engine first so `dotnet publish` can copy it beside the GUI:

```powershell
New-Item -ItemType Directory -Force ..\..\zig-out\bin | Out-Null
zig build-exe ..\..\src\main.zig -femit-bin=..\..\zig-out\bin\speed-download.exe
dotnet publish .\SpeedDownload.csproj -c Release -r win-x64 -p:Platform=x64 --self-contained true -o .\publish
dotnet publish ..\SpeedDownload.BrowserHost\SpeedDownload.BrowserHost.csproj -c Release -r win-x64 --self-contained true -o .\publish
```

The Zig engine includes a Windows named-pipe listener at
`\\.\pipe\SpeedDownload-<user-SID>-<session-id>`, with a private user/SYSTEM
DACL and remote-client rejection. Earlier alpha ZIPs shipped the separately
documented [WPF compatibility client](../SpeedDownload.Wpf/README.md).

An earlier WinUI build passed the Windows Server 2022 GUI and engine smoke test after
packaging the app PRI resource and replacing an unsupported XAML symbol. The
client records startup exceptions, HRESULTs, managed stacks, and inner exception
text in
`%LOCALAPPDATA%\SpeedDownload\logs\client-crash.log`; the previous log rotates
to `client-crash.previous.log` after 1 MiB. The log may contain local paths, so
review it before sharing. An interactive desktop check is still needed for the
Windows release client.

The CI GUI smoke covers startup, engine connection, live progress, engine
restart, and a browser-host handoff with duplicate-request checks for the build
under test; it is not evidence for unbuilt local changes. The WPF compatibility client remains available in earlier alpha ZIPs.
