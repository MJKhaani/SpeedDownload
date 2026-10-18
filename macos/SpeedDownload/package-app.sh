#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PACKAGE_DIR="$ROOT/macos/SpeedDownload"
APP_PATH="${1:-$ROOT/dist/Speed Download.app}"
if [[ "$APP_PATH" != /* ]]; then APP_PATH="$ROOT/$APP_PATH"; fi

mkdir -p "$ROOT/zig-out/bin"
zig build-exe "$ROOT/src/main.zig" -lc -femit-bin="$ROOT/zig-out/bin/speed-download"
zig build-exe "$ROOT/src/browser_host.zig" -lc -femit-bin="$ROOT/zig-out/bin/speed-download-browser-host"
(cd "$PACKAGE_DIR" && swift build --configuration release)
SWIFT_BIN_DIR="$(cd "$PACKAGE_DIR" && swift build --configuration release --show-bin-path)"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Helpers" "$APP_PATH/Contents/Resources"
cp "$SWIFT_BIN_DIR/SpeedDownload" "$APP_PATH/Contents/MacOS/SpeedDownload"
cp "$ROOT/zig-out/bin/speed-download" "$APP_PATH/Contents/Helpers/speed-download"
cp "$ROOT/zig-out/bin/speed-download-browser-host" "$APP_PATH/Contents/Helpers/speed-download-browser-host"
cp "$ROOT/Resources/logo.png" "$APP_PATH/Contents/Resources/logo.png"
cp "$ROOT/Resources/SpeedDownload.icns" "$APP_PATH/Contents/Resources/SpeedDownload.icns"
chmod 755 "$APP_PATH/Contents/MacOS/SpeedDownload" "$APP_PATH/Contents/Helpers/speed-download" "$APP_PATH/Contents/Helpers/speed-download-browser-host"
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>SpeedDownload</string>
  <key>CFBundleIdentifier</key><string>com.mjkhaani.SpeedDownload</string>
  <key>CFBundleName</key><string>Speed Download</string>
  <key>CFBundleDisplayName</key><string>Speed Download</string>
  <key>CFBundleIconFile</key><string>SpeedDownload.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.mjkhaani.SpeedDownload.add</string>
    <key>CFBundleURLSchemes</key><array><string>speeddownload</string><string>magnet</string></array>
  </dict></array>
</dict></plist>
PLIST
echo "Created $APP_PATH"
