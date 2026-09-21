#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 4 ]]; then
    echo "Usage: $0 APP_PATH [TEMPLATE] [SECONDS] [OUTPUT.trace]" >&2
    exit 2
fi

APP="$1"
TEMPLATE="${2:-Time Profiler}"
SECONDS="${3:-45}"
OUTPUT="${4:-$(pwd)/Artifacts/Instruments/$(date -u +%Y%m%dT%H%M%SZ)-${TEMPLATE// /-}.trace}"
EXECUTABLE="$APP/Contents/MacOS/PhotoRelay"

if [[ ! -x "$EXECUTABLE" ]]; then
    echo "Photo Curator executable not found at $EXECUTABLE" >&2
    exit 1
fi
if [[ -e "$OUTPUT" ]]; then
    echo "Refusing to overwrite $OUTPUT" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
exec xcrun xctrace record \
    --template "$TEMPLATE" \
    --time-limit "${SECONDS}s" \
    --output "$OUTPUT" \
    --launch -- "$EXECUTABLE"
