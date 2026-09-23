# Photo Curator for macOS

Photo Curator is the native macOS workspace for turning a large Photos library into persistent, reviewable Moments. It performs metadata indexing, visual analysis, grouping, title preparation, and representative-photo selection locally, while keeping the user's corrections separate from automatic recommendations.

## Current Workflow

- Browse a complete Moments catalog, with the last visible position restored when the app reopens.
- Prioritize a time range without changing which Moments belong in the catalog.
- Review a Moment, edit its title, select highlights, manage Favorites, and delete unwanted photos through PhotoKit.
- Save curated Moments as albums in Photos, merge selected Moments, or export selected photos to Google Photos.
- Add significant places such as Home and Work to improve local titles and grouping context.
- Let background curation continue newest-to-oldest while foreground review remains responsive.

Google Photos integration is native Swift. It opens a temporary localhost callback only
during system-browser OAuth, stores reusable credentials in Keychain, and does not keep
a web server or helper process running.

## Build and Run

```bash
./Scripts/build_app.sh
open "dist/Photo Curator.app"
```

Run the native test suite with:

```bash
swift test
```

Run the warning gate and deterministic 100,000-photo performance baseline with:

```bash
./Scripts/phase0_baseline.sh
```

Run the closed-alpha preflight, including the complete suite and 250,000-photo fixture, with:

```bash
./Scripts/qualify_alpha.sh preflight
```

Settings includes a privacy-safe **Export Diagnostics** action for alpha support. It exports only
aggregate versions, counts, sizes, and whitelisted activity counters.

Ad-hoc signing can cause macOS to request Photos permission again after a rebuild. Distributed builds
use the stable `com.rostyslavkhomyk.PhotoCurator` bundle identifier and must pass the Developer ID,
hardened-runtime, and notarization gate documented in
[PHASE9_CLOSED_ALPHA.md](Docs/PHASE9_CLOSED_ALPHA.md).

## Local Data

Photo Curator stores its durable catalog and corrections under:

```text
~/Library/Application Support/Photo Relay/curator/
```

Supporting app state is stored under `~/Library/Application Support/Photo Relay/`, and rotating logs are written under `~/Library/Logs/Photo Relay/`. Temporary export and OAuth files use system-recommended temporary locations. Rebuilding the app does not intentionally erase the catalog.

## Verified Checkpoint

On 2026-09-21, the complete live library was verified with:

- 108,999 indexed photos
- 5,224 Moments
- Oldest Moment dated 1998-08-25
- 56.5 MB persisted Moments catalog
- 206 native tests passed, 11 skipped, 0 failed
- Native Google OAuth, REST, and safe-sync tests pass as part of the Swift suite

See [CURATOR_PLAN.md](Docs/CURATOR_PLAN.md) for the product direction and
[CURATOR_DEVELOPMENT.md](Docs/CURATOR_DEVELOPMENT.md) for implementation history, and
[PHASE0_BASELINE.md](Docs/PHASE0_BASELINE.md) for stabilization measurements and open gates.
