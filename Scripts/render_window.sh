#!/bin/sh
# Renders the main window to a PNG. Arguments are passed to VisualTests/Render.swift, e.g.
#   sh Scripts/render_window.sh window.png .build/DemoWorkspace billing-service branch 1360 860 light
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD="$ROOT/.build/VisualRender"
mkdir -p "$BUILD"
cd "$BUILD"

# The app is an executable target, so its views are compiled straight into the renderer.
swiftc -O -parse-as-library -module-name GitSightCore -emit-module -emit-library -static \
    "$ROOT"/Sources/GitSightCore/*.swift -o libGitSightCore.a
swiftc -O -parse-as-library -I . -L . -lGitSightCore \
    $(ls "$ROOT"/Sources/GitSight/*.swift | grep -v GitSightApp.swift) "$ROOT/VisualTests/Render.swift" -o render

cd "$ROOT"
"$BUILD/render" "$@"
