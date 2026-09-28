#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR"
APP_DIR="$ROOT_DIR/dist/Photo Curator.app"

cd "$ROOT_DIR"

swift build -c release --package-path "$PACKAGE_DIR"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PACKAGE_DIR/.build/release/PhotoCurator" "$APP_DIR/Contents/MacOS/PhotoCurator"
cp "$PACKAGE_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -n "${PHOTO_CURATOR_VERSION:-}" ]]; then
    plutil -replace CFBundleShortVersionString -string "$PHOTO_CURATOR_VERSION" "$APP_DIR/Contents/Info.plist"
fi
if [[ -n "${PHOTO_CURATOR_BUILD:-}" ]]; then
    plutil -replace CFBundleVersion -string "$PHOTO_CURATOR_BUILD" "$APP_DIR/Contents/Info.plist"
fi
swift "$ROOT_DIR/Scripts/render_icon.swift" "$PACKAGE_DIR/.build/PhotoCurator.iconset"
iconutil -c icns "$PACKAGE_DIR/.build/PhotoCurator.iconset" -o "$APP_DIR/Contents/Resources/PhotoCurator.icns"
if [[ -f "$ROOT_DIR/google_credentials.json" ]]; then
    mkdir -p "$APP_DIR/Contents/Resources/Google"
    cp "$ROOT_DIR/google_credentials.json" \
        "$APP_DIR/Contents/Resources/Google/google_credentials.json"
fi
chmod +x "$APP_DIR/Contents/MacOS/PhotoCurator"
SIGNING_IDENTITY="${PHOTO_CURATOR_SIGNING_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Warning: ad-hoc signing may require Photos authorization again after rebuilding."
    echo "Set PHOTO_CURATOR_SIGNING_IDENTITY to a stable installed code-signing identity to preserve app identity."
fi
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP_DIR"
else
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"

echo "Built: $APP_DIR"
