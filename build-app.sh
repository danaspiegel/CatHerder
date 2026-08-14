#!/bin/bash
#
# Builds CatHerder into a real .app bundle.
#
#   ./build-app.sh              release build into ./build/Cat Herder.app
#   ./build-app.sh --debug      debug build (faster compile)
#   ./build-app.sh --install    also copy into /Applications
#   ./build-app.sh --run        launch when finished
#
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="release"
INSTALL=0
RUN=0
for arg in "$@"; do
    case "$arg" in
        --debug)   CONFIG="debug" ;;
        --release) CONFIG="release" ;;
        --install) INSTALL=1 ;;
        --run)     RUN=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

APP_NAME="Cat Herder"
BUNDLE_ID="co.foundertherapy.CatHerder"
OUT_DIR="build"
APP="$OUT_DIR/$APP_NAME.app"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/CatHerder"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/CatHerder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- Icon ---------------------------------------------------------------------
# Drawn at build time by Tools/GenerateIcon.swift so the repository carries no
# binary assets. Delete build/AppIcon.icns to force a redraw.
if [ ! -f "$OUT_DIR/AppIcon.icns" ]; then
    echo "▸ Rendering icon…"
    mkdir -p "$OUT_DIR"
    ICONSET="$OUT_DIR/AppIcon.iconset"
    rm -rf "$ICONSET"
    swift Tools/GenerateIcon.swift "$ICONSET" >/dev/null 2>&1 || \
        echo "  (icon generation failed; continuing without one)"
    if ls "$ICONSET"/*.png >/dev/null 2>&1; then
        iconutil -c icns "$ICONSET" -o "$OUT_DIR/AppIcon.icns" 2>/dev/null || true
    fi
fi
[ -f "$OUT_DIR/AppIcon.icns" ] && cp "$OUT_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# --- Signing ------------------------------------------------------------------
# Ad-hoc signature with a stable identifier, so macOS keeps the Automation
# permission grant across rebuilds instead of re-prompting every time.
echo "▸ Signing (ad-hoc)…"
codesign --force --sign - --identifier "$BUNDLE_ID" \
    --options runtime --timestamp=none "$APP" 2>/dev/null \
  || codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

# Nudge Launch Services so the new bundle is registered immediately.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" 2>/dev/null || true

echo "✓ Built $APP"

if [ "$INSTALL" = "1" ]; then
    echo "▸ Installing to /Applications…"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    echo "✓ Installed /Applications/$APP_NAME.app"
    APP="/Applications/$APP_NAME.app"
fi

if [ "$RUN" = "1" ]; then
    echo "▸ Launching…"
    open "$APP"
fi
