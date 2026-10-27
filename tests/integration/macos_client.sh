#!/bin/bash
# Exercise the real GUI handshake against an isolated current engine.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE_BIN="${1:-$ROOT/zig-out/bin/speed-download}"
TASK_DIRECTORY="$(mktemp -d /private/tmp/sd-client.XXXXXX)"
ENGINE_PID=""
CLIENT_PID=""
cleanup() {
  if [[ -n "$CLIENT_PID" ]]; then
    kill "$CLIENT_PID" 2>/dev/null || true
    wait "$CLIENT_PID" 2>/dev/null || true
  fi
  if [[ -n "$ENGINE_PID" ]]; then
    kill "$ENGINE_PID" 2>/dev/null || true
    wait "$ENGINE_PID" 2>/dev/null || true
  fi
  rm -rf "$TASK_DIRECTORY"
}
trap cleanup EXIT
mkdir -p "$TASK_DIRECTORY/clang-cache" "$TASK_DIRECTORY/swift-cache"
SWIFT_SDK_ARGS=()
if [[ -n "${SPEED_DOWNLOAD_SWIFT_SDK:-}" ]]; then
  SWIFT_SDK_ARGS=(-sdk "$SPEED_DOWNLOAD_SWIFT_SDK")
fi
CLANG_MODULE_CACHE_PATH="$TASK_DIRECTORY/clang-cache" \
  SWIFT_MODULECACHE_PATH="$TASK_DIRECTORY/swift-cache" \
  swiftc "${SWIFT_SDK_ARGS[@]}" "$ROOT/macos/SpeedDownload/Sources/SpeedDownload/UnixEngineClient.swift" \
  "$ROOT/macos/SpeedDownload/Sources/SpeedDownload/EngineModel.swift" \
  "$ROOT/tests/integration/macos_client.swift" -o "$TASK_DIRECTORY/client"
start_engine() {
  TMPDIR="$TASK_DIRECTORY/" SPEED_DOWNLOAD_STATE_DIR="$TASK_DIRECTORY/state" \
    "$ENGINE_BIN" engine >>"$TASK_DIRECTORY/engine.log" 2>&1 &
  ENGINE_PID=$!
  for ((attempt = 0; attempt < 200; attempt++)); do
    if [[ -S "$TASK_DIRECTORY/speed-download/engine.sock" ]]; then return; fi
    if ! kill -0 "$ENGINE_PID" 2>/dev/null; then break; fi
    sleep 0.05
  done
  cat "$TASK_DIRECTORY/engine.log"
  echo "Engine did not create its IPC socket" >&2
  exit 1
}
start_engine
TMPDIR="$TASK_DIRECTORY/" SPEED_DOWNLOAD_STATE_DIR="$TASK_DIRECTORY/state" \
  SPEED_DOWNLOAD_ENGINE_PATH="$ENGINE_BIN" SPEED_DOWNLOAD_TEST_CONTROL_DIR="$TASK_DIRECTORY" \
  "$TASK_DIRECTORY/client" &
CLIENT_PID=$!
for ((attempt = 0; attempt < 400; attempt++)); do
  if [[ -f "$TASK_DIRECTORY/client-ready" ]]; then break; fi
  if ! kill -0 "$CLIENT_PID" 2>/dev/null; then wait "$CLIENT_PID"; exit 1; fi
  sleep 0.05
done
if [[ ! -f "$TASK_DIRECTORY/client-ready" ]]; then
  echo "Client did not reach the restart check" >&2
  exit 1
fi
kill "$ENGINE_PID"
wait "$ENGINE_PID" 2>/dev/null || true
ENGINE_PID=""
start_engine
touch "$TASK_DIRECTORY/engine-restarted"
wait "$CLIENT_PID"
CLIENT_PID=""
