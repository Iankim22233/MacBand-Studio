#!/bin/bash
# Builds "MacBand Studio.app" (release) next to this script.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/MacBandStudio"
APP="MacBand Studio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacBandStudio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
# Ad-hoc signature, no hardened runtime: lets MacBand Studio load plugins from any developer.
codesign --force --deep --sign - "$APP"
echo "Built $(pwd)/$APP"
