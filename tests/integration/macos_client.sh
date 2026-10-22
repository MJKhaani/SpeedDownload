#!/bin/bash
# Exercise the real GUI handshake against an isolated current engine.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE_BIN="${1:-$ROOT/zig-out/bin/speed-download}"
TASK_DIRECTORY="$(mktemp -d /private/tmp/sd-client.XXXXXX)"
ENGINE_PID=""
cleanup() {
  if [[ -n "$ENGINE_PID" ]]; then
    kill "$ENGINE_PID" 2>/dev/null || true
    wait "$ENGINE_PID" 2>/dev/null || true
  fi
  rm -rf "$TASK_DIRECTORY"
}
trap cleanup EXIT
swiftc "$ROOT/macos/SpeedDownload/Sources/SpeedDownload/UnixEngineClient.swift" \
  "$ROOT/macos/SpeedDownload/Sources/SpeedDownload/EngineModel.swift" \
  "$ROOT/tests/integration/macos_client.swift" -o "$TASK_DIRECTORY/client"
TMPDIR="$TASK_DIRECTORY/" SPEED_DOWNLOAD_STATE_DIR="$TASK_DIRECTORY/state" \
  "$ENGINE_BIN" engine >"$TASK_DIRECTORY/engine.log" 2>&1 &
ENGINE_PID=$!
for ((attempt = 0; attempt < 100; attempt++)); do
  if [[ -S "$TASK_DIRECTORY/speed-download/engine.sock" ]]; then break; fi
  if ! kill -0 "$ENGINE_PID" 2>/dev/null; then cat "$TASK_DIRECTORY/engine.log"; exit 1; fi
  sleep 0.05
done
if [[ ! -S "$TASK_DIRECTORY/speed-download/engine.sock" ]]; then
  cat "$TASK_DIRECTORY/engine.log"
  echo "Engine did not create its IPC socket" >&2
  exit 1
fi
TMPDIR="$TASK_DIRECTORY/" SPEED_DOWNLOAD_STATE_DIR="$TASK_DIRECTORY/state" \
  SPEED_DOWNLOAD_ENGINE_PATH="$ENGINE_BIN" "$TASK_DIRECTORY/client"
