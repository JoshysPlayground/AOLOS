#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

app="build/AOL-OS.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Sounds" "$app/Contents/Resources/Branding"
cp .build/release/AOLOS "$app/Contents/MacOS/AOL-OS"
cp Resources/Info.plist "$app/Contents/Info.plist"
find Resources/Sounds -type f ! -name '.gitkeep' -exec cp {} "$app/Contents/Resources/Sounds/" \;
find Resources/Branding -type f ! -name '.gitkeep' -exec cp {} "$app/Contents/Resources/Branding/" \;
codesign --force --sign - "$app"

echo "Built $app"
