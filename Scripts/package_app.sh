#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

swift build -c release
python3 Scripts/generate_icon.py
iconutil -c icns Artifacts/AppIcon.iconset -o Resources/AppIcon.icns

APP=Artifacts/GitSight.app
BIN="$APP/Contents/MacOS/GitSight"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/GitSight "$BIN"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
ditto .build/release/Sparkle.framework "$SPARKLE"
chmod +x "$BIN"
plutil -lint "$APP/Contents/Info.plist"

# SwiftPM points the binary at frameworks inside .build. Drop those paths so the app
# loads only the Sparkle it carries.
otool -l "$BIN" | sed -n 's/^ *path \(.*\) (offset [0-9]*)$/\1/p' | while IFS= read -r path; do
    case "$path" in
        "$ROOT"/*) install_name_tool -delete_rpath "$path" "$BIN" ;;
    esac
done
install_name_tool -add_rpath @executable_path/../Frameworks "$BIN"

# Ad-hoc sign from the inside out, so every nested piece of Sparkle matches the app.
codesign --force --sign - "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign - --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign - "$SPARKLE/Versions/B/Autoupdate"
codesign --force --sign - "$SPARKLE/Versions/B/Updater.app"
codesign --force --sign - "$SPARKLE"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
