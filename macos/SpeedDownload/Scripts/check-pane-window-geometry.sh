#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache_dir=${TMPDIR:-/private/tmp}/speed-download-pane-checks
mkdir -p "$cache_dir"
CLANG_MODULE_CACHE_PATH="$cache_dir/clang" SWIFT_MODULECACHE_PATH="$cache_dir/swift" swiftc \
  "$project_dir/Sources/SpeedDownload/PaneWindowGeometry.swift" \
  "$project_dir/Tests/SpeedDownloadTests/PaneWindowGeometryChecks.swift" \
  -o "$cache_dir/pane-window-geometry-checks"
"$cache_dir/pane-window-geometry-checks"
