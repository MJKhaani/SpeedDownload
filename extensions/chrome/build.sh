#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DESTINATION="$ROOT/dist/SpeedDownload-Chrome-extension"
mkdir -p "$DESTINATION"
cp "$ROOT/extensions/chrome/manifest.json" "$DESTINATION/manifest.json"
cp "$ROOT/extensions/firefox/popup.html" "$DESTINATION/popup.html"
{ printf 'const browser = chrome;\n'; cat "$ROOT/extensions/firefox/background.js"; } > "$DESTINATION/background.js"
{ printf 'const browser = chrome;\n'; cat "$ROOT/extensions/firefox/popup.js"; } > "$DESTINATION/popup.js"
echo "Created $DESTINATION"
