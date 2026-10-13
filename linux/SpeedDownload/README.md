# Speed Download for Linux

This is the native GTK 4 client for the Speed Download engine. It uses GTK 4
and JSON-GLib and connects to the engine over its per-user Unix socket.

## Build

Dependencies: GTK 4, JSON-GLib, CMake, a C11 compiler, and the Speed Download
engine.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

Start the engine with `speed-download engine`, then run
`./build/speed-download-gtk`. The client looks for
`$XDG_RUNTIME_DIR/speed-download/engine.sock`. The GTK client is source-complete
but has not yet been built or runtime-validated on a Linux desktop.
