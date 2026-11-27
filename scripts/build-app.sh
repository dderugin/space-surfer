#!/bin/bash
set -euo pipefail

project=$(cd "$(dirname "$0")/.." && pwd)
cd "$project"
swift build -c release --product SpaceSurf "$@"
bin=$(swift build -c release --show-bin-path "$@")
dist="$project/dist"
app="$dist/Space Surfer.app"
mkdir -p "$dist"
stage=$(mktemp -d "$dist/.space-surfer.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
bundle="$stage/Space Surfer.app"

mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin/SpaceSurf" "$bundle/Contents/MacOS/SpaceSurf"
cp Assets/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
cp LICENSE "$bundle/Contents/Resources/LICENSE"

cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>SpaceSurf</string>
  <key>CFBundleIdentifier</key><string>local.spacesurf.app</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Space Surfer</string>
  <key>CFBundleDisplayName</key><string>Space Surfer</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSAppleEventsUsageDescription</key><string>Space Surfer asks Finder to open its standard Get Info windows for selected files and folders.</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Dmitrij Derjugin</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"

# Publish only a complete signed bundle. Swapping directory entries preserves
# the executable open by a running instance and keeps the installed path valid.
python3 - "$bundle" "$app" <<'PY'
import ctypes
import os
from pathlib import Path
import sys

staged, installed = map(Path, sys.argv[1:])
if not os.path.lexists(installed):
    staged.rename(installed)
else:
    rename_swap = ctypes.CDLL(None, use_errno=True).renamex_np
    rename_swap.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename_swap.restype = ctypes.c_int
    RENAME_SWAP = 0x00000002
    if rename_swap(os.fsencode(staged), os.fsencode(installed), RENAME_SWAP) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), installed)
PY

echo "$app"
