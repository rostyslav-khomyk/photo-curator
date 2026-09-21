#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="${1:-$ROOT/Artifacts/Phase0/$STAMP}"
mkdir -p "$OUTPUT"

cd "$ROOT"
git rev-parse HEAD > "$OUTPUT/git-revision.txt"
sw_vers > "$OUTPUT/macos.txt"
uname -m > "$OUTPUT/architecture.txt"

echo "Checking production concurrency diagnostics..."
swift build -Xswiftc -strict-concurrency=complete 2>&1 | tee "$OUTPUT/strict-build.log"
if grep -q "warning:" "$OUTPUT/strict-build.log"; then
    echo "Strict production build emitted warnings." >&2
    exit 1
fi

echo "Running deterministic 100,000-photo benchmark..."
PHOTO_CURATOR_PERFORMANCE=1 swift test --filter CuratorPerformanceTests 2>&1 \
    | tee "$OUTPUT/performance-test.log"

echo "Phase 0 baseline saved to $OUTPUT"
