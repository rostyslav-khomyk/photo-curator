# Photo Curator for macOS

Photo Curator is the native macOS workspace for turning a large Photos library into persistent, reviewable Moments. It performs metadata indexing, visual analysis, grouping, title preparation, and representative-photo selection locally, while keeping the user's corrections separate from automatic recommendations.

## Current Workflow

- Browse a complete Moments catalog, with the last visible position restored when the app reopens.
- Prioritize a time range without changing which Moments belong in the catalog.
- Review a Moment, edit its title, select highlights, manage Favorites, and delete unwanted photos through PhotoKit.
- Save curated Moments as albums in Photos, merge selected Moments, or export selected photos to Google Photos.
- Add significant places such as Home and Work to improve local titles and grouping context.
- Let background curation continue newest-to-oldest while foreground review remains responsive.

Google Photos integration is started only when requested. The small helper under
`GooglePhotosHelper/` communicates through private local pipes and opens a temporary
localhost callback only during OAuth; Photo Curator does not keep a web server running.

## Build and Run

```bash
uv sync --group dev
./Scripts/build_app.sh
open "dist/Photo Curator.app"
```

Run the native test suite with:

```bash
swift test
uv run pytest
```

Ad-hoc signing can cause macOS to request Photos permission again after a rebuild. A stable Developer ID signature is required to preserve the installed application's identity across distributed builds.

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
- 203 native tests passed, 10 skipped, 0 failed
- 47 Google helper tests passed

See [CURATOR_PLAN.md](Docs/CURATOR_PLAN.md) for the product direction and
[CURATOR_DEVELOPMENT.md](Docs/CURATOR_DEVELOPMENT.md) for implementation history and verification details.
