#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
build_dir="$(swift build -c release --show-bin-path)"
app_dir="$PWD/dist/Still.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Helpers" "$app_dir/Contents/Resources"
cp "$build_dir/Still" "$app_dir/Contents/MacOS/Still"
cp "$build_dir/StillHelper" "$app_dir/Contents/Helpers/StillHelper"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp LICENSE "$app_dir/Contents/Resources/LICENSE"
icon_dir="$PWD/.build/Still.iconset"
swift scripts/make-icon.swift "$icon_dir"
/usr/bin/iconutil --convert icns "$icon_dir" --output "$app_dir/Contents/Resources/Still.icns"
/usr/bin/codesign --force --sign - "$app_dir/Contents/Helpers/StillHelper"
/usr/bin/codesign --force --sign - "$app_dir"
echo "Built $app_dir"
