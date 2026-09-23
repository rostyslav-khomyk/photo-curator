# Phase 5 Cache and Disk Normalization

Status: implemented; automated gates pass, owner-library migration qualification remains
Prepared: 2026-09-23

## One Derived Cache

OCR, visual labels, prepared captions, automatic grouping proposals, large-Moment window records,
and continuity evidence now share `~/Library/Caches/Photo Curator/analysis-cache.sqlite3`. The cache
uses WAL mode, namespace/key identity, bounded payloads, and one lock-protected synchronous SQLite
connection per store instance. No cache transaction contains an `await`.

Authoritative Catalog v2 rows, user edits, publication operations, PhotoKit checkpoints, and the
mixed metadata index remain in Application Support. Phase 5 does not pretend the mixed index is a
pure cache or couple stabilization to a risky schema split.

## Safe Legacy Migration

Every cache read first checks SQLite and then falls back to the corresponding legacy JSON file. A
valid fallback record is committed before its JSON and sidecar lock are removed, so a crash cannot
turn migration into reanalysis. New writes go directly to SQLite.

Migration runs at utility priority, imports at most 500 records per transaction and 20 transactions
per launch, yields briefly between batches, and resumes naturally on later launches. The enormous
legacy evidence directories are no longer enumerated synchronously during startup. Invalid or
oversized legacy files remain untouched and are treated as cache misses.

## Storage Policy

- Derived payload retention is capped at 2 GB and records older than one year are removed in bounded
  batches; maintenance uses passive WAL checkpointing rather than a launch-time vacuum.
- New derived-cache writes pause when macOS reports less than 2 GB available for important usage.
  Existing evidence and every authoritative catalog remain readable.
- Settings reports the derived-cache record count, its database size, available storage, and whether
  low-disk protection is active.
- Google staging retains its existing 2 GB/seven-day policy, now executed away from app launch work.

## Automated Coverage

- cache namespaces cannot overwrite one another;
- records survive database reopen;
- corrupt evidence is a cache miss rather than a crash;
- legacy fallback commits before deleting its source;
- bounded imports preserve oversized files and remove matching obsolete lock files;
- pipeline restart, priority analysis, late evidence, and large-Moment windows reuse the shared cache;
- metadata edits and analyzer revisions continue to invalidate stale evidence.

## Exit Gate

- [x] High-file-count evidence writes are consolidated into one derived cache database.
- [x] Rebuildable evidence is stored in the standard macOS Caches directory.
- [x] Legacy evidence remains readable during a bounded, crash-safe migration.
- [x] Startup no longer recursively enumerates the large evidence directories.
- [x] Storage reporting and a low-disk write pause are present.
- [x] Full native suite passes: 218 tests, 12 opt-in skips, zero failures.
- [x] Production build passes complete strict-concurrency checking with warnings as errors.
- [ ] Run multiple packaged-app launches against the owner catalog and record legacy file-count,
  cache-size, relaunch, and UI-responsiveness measurements.
- [ ] Confirm with Instruments that utility-priority migration does not create foreground I/O stalls.

No catalog wipe, managed Photos-album deletion, Photos mutation, packaged-app deployment, or full
reanalysis occurred in this phase.
