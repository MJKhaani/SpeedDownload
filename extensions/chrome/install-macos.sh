#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_PATH="${1:-$ROOT/dist/Speed Download.app}"
APP_PATH="$(cd "$APP_PATH" && pwd -P)"
HOST="$APP_PATH/Contents/Helpers/speed-download-browser-host"
if [[ ! -x "$HOST" ]]; then
  echo "Browser host is missing from $APP_PATH" >&2
  exit 1
fi
DESTINATION="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "$DESTINATION"
umask 077
TEMPORARY="$(mktemp "$DESTINATION/.com.mjkhaani.speeddownload.XXXXXX")"
trap 'rm -f "$TEMPORARY"' EXIT
"$HOST" --print-chrome-manifest > "$TEMPORARY"
mv -f "$TEMPORARY" "$DESTINATION/com.mjkhaani.speeddownload.json"
echo "Registered Speed Download for Chrome."
