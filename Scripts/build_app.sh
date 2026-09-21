#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR"
APP_DIR="$ROOT_DIR/dist/Photo Curator.app"

cd "$ROOT_DIR"

if [[ ! -x "$ROOT_DIR/.venv/bin/pyinstaller" ]]; then
    echo "PyInstaller is missing. Run: uv sync --group dev"
    exit 1
fi

"$ROOT_DIR/.venv/bin/pyinstaller" --clean --noconfirm --onefile \
    --name PhotoCuratorGoogleHelper \
    --paths "$ROOT_DIR/GooglePhotosHelper" \
    "$ROOT_DIR/GooglePhotosHelper/photo_curator_google/__main__.py"
swift build -c release --package-path "$PACKAGE_DIR"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/Engine"
cp "$PACKAGE_DIR/.build/release/PhotoRelay" "$APP_DIR/Contents/MacOS/PhotoRelay"
cp "$ROOT_DIR/dist/PhotoCuratorGoogleHelper" \
    "$APP_DIR/Contents/Resources/Engine/PhotoCuratorGoogleHelper"
cp "$PACKAGE_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
swift "$ROOT_DIR/Scripts/render_icon.swift" "$PACKAGE_DIR/.build/PhotoRelay.iconset"
iconutil -c icns "$PACKAGE_DIR/.build/PhotoRelay.iconset" -o "$APP_DIR/Contents/Resources/PhotoRelay.icns"
if [[ -f "$ROOT_DIR/google_credentials.json" ]]; then
    mkdir -p "$APP_DIR/Contents/Resources/Google"
    cp "$ROOT_DIR/google_credentials.json" \
        "$APP_DIR/Contents/Resources/Google/google_credentials.json"
fi
chmod +x "$APP_DIR/Contents/MacOS/PhotoRelay" \
    "$APP_DIR/Contents/Resources/Engine/PhotoCuratorGoogleHelper"
SIGNING_IDENTITY="${PHOTO_RELAY_SIGNING_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Warning: ad-hoc signing may require Photos authorization again after rebuilding."
    echo "Set PHOTO_RELAY_SIGNING_IDENTITY to a stable installed code-signing identity to preserve app identity."
fi
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "Built: $APP_DIR"
