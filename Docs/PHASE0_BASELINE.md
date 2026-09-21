# Phase 0 Stability Baseline

Status: automated guardrails implemented; interactive trace and owner benchmark review remain open  
Prepared: 2026-09-21

## Purpose

This baseline is the stop-the-line reference for the stabilization program. Later phases must compare
against it rather than relying on impressions from one launch. Public fixtures are synthetic. Photo
identifiers, titles, locations, OCR, images, account details, and the private owner benchmark must not
enter this repository or generated support diagnostics.

## Reproducible Automated Baseline

Run:

```bash
./Scripts/phase0_baseline.sh
```

The script records the Git revision, macOS version, architecture, a complete-concurrency production
build, and an opt-in deterministic 100,000-photo grouping benchmark under ignored `Artifacts/Phase0/`.
It fails if the production build emits any warning.

Initial development-Mac result:

| Measure | 2026-09-21 baseline |
| --- | ---: |
| Synthetic photos | 100,000 |
| Grouping clock time, three-run mean | 0.347 s |
| Grouping peak physical memory | 78,142 kB |
| Strict production concurrency warnings | 0 |

These numbers isolate deterministic grouping. They do not represent launch, PhotoKit I/O, thumbnail
latency, visual analysis, or full workspace memory.

## Production-Scale Storage Snapshot

The pre-migration live-catalog audit provides the storage and shape baseline:

| Measure | Current value |
| --- | ---: |
| Indexed photos | 108,999 |
| Derived Moments | 5,224 |
| Selected highlights | 14,279 |
| Curator support data | 2.7 GB |
| Main SQLite database | 1.4 GB |
| Vision result payloads | 1.373 GB |
| Moments JSON catalog | about 57 MB |
| Background-context files | 226,026 files / 883 MB |
| OCR evidence files | 105,818 files / 414 MB |
| Publication journal files | 2,620 files |

The in-app **Export Diagnostics** action records only aggregate versions, counters, file counts, byte
counts, and whitelisted telemetry counters. Its output is mode `0600`. Tests reject session IDs,
unknown telemetry fields, and sensitive filenames.

## Instruments Checklist

Build and install once, then record without rebuilding between scenarios:

```bash
./Scripts/capture_instruments.sh "dist/Photo Curator.app" "Time Profiler" 45
./Scripts/capture_instruments.sh "dist/Photo Curator.app" "Allocations" 60
./Scripts/capture_instruments.sh "dist/Photo Curator.app" "Hangs" 60
```

Record these scenarios separately:

1. Warm launch until the Moments grid accepts keyboard navigation.
2. Scroll top-to-bottom-to-top through all 5,224 Moments and wait 30 seconds for caches to settle.
3. Browse and open a Moment while background analysis is active.
4. Publish one disposable test Moment, then verify the Photos album before deleting it manually.
5. Quit during analysis, relaunch, and confirm completed source revisions are not repeated.

Capture RSS at start, maximum, and settled end; longest main-thread stall; idle CPU; first visible
thumbnail latency; and signpost durations. Available signposts use subsystem `com.photorrelay.app`,
category `Performance`: `Launch to interactive`, `Moment overview`, `Thumbnail request`,
`Metadata batch`, `Analysis step`, and `Photos publication`.

Interactive values remain deliberately marked **pending** until captured on the packaged app and then
repeated on the oldest supported alpha Mac. A debug launch is not an acceptable substitute.

## Owner Benchmark

The public format is illustrated by
`Tools/Evaluation/owner-benchmark.example.json`. The real fixture belongs beside the private exported
reference report and is selected explicitly through `PHOTO_RELAY_REFERENCE_REPORT`; it must not be
committed. Before Phase 1 migration starts, the owner must freeze a version covering dense trips,
quiet periods, old scans, missing GPS, home/work life, celebrations, venues, and recent GPS-rich days.
Each case records expected joins/splits, optional Story membership, title, and required highlights.

## Exit Gate

- [x] Production signposts and repeatable capture script exist.
- [x] Deterministic 100,000-photo time/memory fixture exists.
- [x] Privacy-safe diagnostic export exists and is tested.
- [ ] A clean complete strict-concurrency production build has zero warnings. The original
  incremental check missed existing PhotoKit/publication warnings; Catalog v2 adds none.
- [x] Automatic Photos publication defaults off for a fresh alpha install while preserving an existing choice.
- [ ] Packaged-app launch/scroll/analysis/publication/restart traces are recorded.
- [ ] The private owner benchmark is versioned and approved.
- [ ] The same baseline is recorded on the oldest supported alpha Mac.

Phase 1 should not cut over durable state until the unchecked items are complete.
