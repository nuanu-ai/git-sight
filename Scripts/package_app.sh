#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

swift build -c release
python Scripts/generate_icon.py
iconutil -c icns Artifacts/AppIcon.iconset -o Resources/AppIcon.icns

APP=Artifacts/GitSight.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/GitSight "$APP/Contents/MacOS/GitSight"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/GitSight"
plutil -lint "$APP/Contents/Info.plist"
