# Speed Download for Linux

This is the native GTK 4 client for the Speed Download engine. It uses GTK 4
and JSON-GLib and connects to the engine over its per-user Unix socket.

## Build

Dependencies: GTK 4, JSON-GLib, CMake, a C11 compiler, and the Speed Download
engine.

```sh
mkdir -p ../../zig-out/bin
zig build-exe ../../src/main.zig -lc -femit-bin=../../zig-out/bin/speed-download
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
cmake --install build --prefix "$HOME/.local"
```

Run `./build/speed-download-gtk`. If the engine is not already running, the GTK
client starts `speed-download engine` from `SPEED_DOWNLOAD_ENGINE_PATH`, beside
the GTK executable, or from `PATH`, in that order. Install both executables in
the same `bin` directory, or set `SPEED_DOWNLOAD_ENGINE_PATH`. The engine uses
`$XDG_RUNTIME_DIR/speed-download/engine.sock` and its standard per-user state
directory. The GUI retries connection while the engine starts.
