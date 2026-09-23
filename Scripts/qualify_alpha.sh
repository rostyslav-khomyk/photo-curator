#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-preflight}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="${PHOTO_CURATOR_QUALIFICATION_OUTPUT:-$ROOT/Artifacts/Alpha/$STAMP}"
APP="$ROOT/dist/Photo Curator.app"
DMG="$OUTPUT/Photo-Curator.dmg"

if [[ "$MODE" != "preflight" && "$MODE" != "release" ]]; then
    echo "Usage: $0 [preflight|release]" >&2
    exit 2
fi
if [[ "$MODE" == "release" ]]; then
    : "${PHOTO_RELAY_SIGNING_IDENTITY:?Set PHOTO_RELAY_SIGNING_IDENTITY to a Developer ID Application identity}"
    : "${PHOTO_CURATOR_NOTARY_PROFILE:?Set PHOTO_CURATOR_NOTARY_PROFILE to a notarytool Keychain profile}"
    if [[ "$PHOTO_RELAY_SIGNING_IDENTITY" != Developer\ ID\ Application:* ]]; then
        echo "Release mode requires a Developer ID Application identity." >&2
        exit 1
    fi
fi

mkdir -p "$OUTPUT"
cd "$ROOT"
git rev-parse HEAD > "$OUTPUT/git-revision.txt"
git status --porcelain > "$OUTPUT/git-status.txt"
sw_vers > "$OUTPUT/macos.txt"
uname -m > "$OUTPUT/architecture.txt"

if [[ -s "$OUTPUT/git-status.txt" ]]; then
    echo "Qualification requires a clean worktree." >&2
    exit 1
fi

echo "Running complete native test suite..."
swift test 2>&1 | tee "$OUTPUT/tests.log"

echo "Checking strict-concurrency release build..."
swift build -c release --scratch-path "$OUTPUT/strict-build" \
    -Xswiftc -strict-concurrency=complete 2>&1 | tee "$OUTPUT/strict-build.log"
if grep -q "warning:" "$OUTPUT/strict-build.log"; then
    echo "Strict release build emitted warnings." >&2
    exit 1
fi

echo "Running deterministic 250,000-photo benchmark..."
PHOTO_CURATOR_PERFORMANCE=1 PHOTO_CURATOR_PERFORMANCE_COUNT=250000 \
    swift test --filter CuratorPerformanceTests 2>&1 | tee "$OUTPUT/performance-250k.log"

if [[ "$MODE" != "release" ]]; then
    export PHOTO_RELAY_SIGNING_IDENTITY="-"
fi

echo "Building application bundle..."
PHOTO_CURATOR_BUILD="${PHOTO_CURATOR_BUILD:-$(git rev-list --count HEAD)}" \
    "$ROOT/Scripts/build_app.sh" 2>&1 | tee "$OUTPUT/app-build.log"

test "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" = "com.rostyslavkhomyk.PhotoCurator"
codesign --verify --deep --strict --verbose=2 "$APP" 2> "$OUTPUT/codesign-verify.txt"
codesign -dvvv "$APP" 2> "$OUTPUT/codesign-details.txt"

if [[ "$MODE" == "release" ]]; then
    if ! grep -q "flags=.*runtime" "$OUTPUT/codesign-details.txt"; then
        echo "Hardened runtime is missing." >&2
        exit 1
    fi
    hdiutil create -quiet -volname "Photo Curator" -srcfolder "$APP" -ov -format UDZO "$DMG"
    codesign --force --timestamp --sign "$PHOTO_RELAY_SIGNING_IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$PHOTO_CURATOR_NOTARY_PROFILE" --wait \
        2>&1 | tee "$OUTPUT/notarization.txt"
    xcrun stapler staple "$DMG" 2>&1 | tee "$OUTPUT/stapler.txt"
    xcrun stapler validate "$DMG" 2>&1 | tee "$OUTPUT/stapler-validation.txt"
    spctl --assess --type open --context context:primary-signature -vv "$DMG" \
        2> "$OUTPUT/gatekeeper.txt"
    shasum -a 256 "$DMG" > "$OUTPUT/SHA256SUMS"
fi

cat > "$OUTPUT/result.txt" <<EOF
mode=$MODE
revision=$(git rev-parse HEAD)
bundle_identifier=com.rostyslavkhomyk.PhotoCurator
tests=passed
strict_concurrency=passed
synthetic_photos=250000
artifact=$([[ "$MODE" == "release" ]] && echo notarized-dmg || echo local-app)
EOF

echo "Alpha $MODE evidence saved to $OUTPUT"
