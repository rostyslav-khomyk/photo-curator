# Phase 9 Closed-Alpha Qualification

Status: automated preflight implemented; signed distribution and multi-library soak gates remain open  
Prepared: 2026-09-24

## Automated Gate

Run the local gate from a clean commit:

```bash
./Scripts/qualify_alpha.sh preflight
```

It records the revision and host, runs the complete Swift suite, rejects strict-concurrency warnings,
runs the deterministic 250,000-photo benchmark, builds the app, and verifies the fixed bundle identity
and signature. Evidence is written under ignored `Artifacts/Alpha/`.

Initial development-Mac result: 256 tests passed with 13 intentional skips, the strict release build
emitted zero warnings, and the 250,000-photo grouping fixture averaged 0.866 seconds over three runs
with 183,556 kB peak physical memory. These figures measure grouping only, not PhotoKit I/O, visual
analysis, thumbnails, or the full workspace.

Release mode additionally requires an installed Developer ID Application identity and a `notarytool`
Keychain profile. It enables the hardened runtime, creates and signs a DMG, submits it to Apple,
staples and validates the ticket, runs Gatekeeper assessment, and records the SHA-256 digest:

```bash
export PHOTO_RELAY_SIGNING_IDENTITY='Developer ID Application: Example (TEAMID)'
export PHOTO_CURATOR_NOTARY_PROFILE='PhotoCurator'
export PHOTO_CURATOR_VERSION='1.0-alpha.1'
./Scripts/qualify_alpha.sh release
```

The script deliberately fails rather than silently producing an ad-hoc "release".

## Soak Matrix

Each candidate must run for at least 72 hours on three opt-in real libraries plus the synthetic gate.
Record one row per library outside the repository; attach only the privacy-safe exported diagnostic.

| Gate | Required evidence |
| --- | --- |
| Library scale | Approximate asset and Moment counts; no identifiers, titles, locations, or images |
| Resume safety | Quit, forced termination, sleep/wake, and relaunch all resume without repeated full indexing |
| PhotoKit safety | Zero lost assets, duplicate managed albums, or unintended Favorite changes |
| Responsiveness | Warm launch, scrolling, review during analysis, and memory measurements from packaged app |
| Google sync | Interrupted upload reconciles; no duplicate media and no process/server remains afterward |
| Curation quality | Owner reviews dense trips, ordinary home/work periods, old scans, and missing-GPS periods |
| Recovery | Export Diagnostics succeeds and rebuild/reset previews match their documented scope |

Stop the run immediately for data loss, mutation outside a proven managed container, repeated hangs,
or a mismatch between a destructive confirmation and its actual scope. Other failures receive a
reproduction note, diagnostic export, app version, macOS version, and terminal disposition.

## Exit Gate

- [x] Fixed production bundle identifier.
- [x] Repeatable complete-test, strict-concurrency, and 250,000-photo preflight.
- [x] Release command rejects missing Developer ID and notarization credentials.
- [x] Privacy-safe diagnostic export remains covered by automated tests.
- [ ] Developer ID-signed, hardened-runtime, notarized DMG passes Gatekeeper.
- [ ] Three real-library 72-hour soak runs pass, including the oldest supported alpha Mac.
- [ ] Zero data-loss incidents, duplicate albums, or recurring hangs.
- [ ] Performance budgets are met or explicitly renegotiated from captured Instruments evidence.
