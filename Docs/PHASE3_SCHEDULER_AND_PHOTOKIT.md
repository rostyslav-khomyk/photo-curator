# Phase 3 Scheduler and PhotoKit Ownership

Status: implemented; automated gates pass, live owner-library qualification remains
Prepared: 2026-09-23

## Implementation

Photo Curator no longer polls a two-second controller timer. `CurationScheduler` coalesces explicit
events for startup, user requests, PhotoKit changes, completed work, policy changes, verification,
and retries. It sleeps until an event or exact deadline and removes obsolete deadlines when work is
woken early.

`LibraryCoordinator` is the sole PhotoKit observation owner. It persists and replays
`PHPersistentChangeToken` history across launches, coalesces asset identifiers, and gives the
controller bounded batches of at most 100 changes. A valid history token takes precedence over the
old count/newest-photo fingerprint, so an offline edit, Favorite, insertion, or deletion does not
automatically cause a 109k-photo verification. Expired or unreadable history safely requests a full
verification.

Curator-owned Favorite and deletion operations register an operation UUID before changing Photos.
Their matching observer callbacks are suppressed while unrelated external changes remain queued.
The prior timing flags and three-second ignore window are removed.

## Resumable Verification

Full verification stores its scope, generation, cursor, total, and update time in SQLite after each
100-photo batch. Relaunch explicitly resumes this work. Incremental PhotoKit changes received during
verification are applied directly, marked in the active generation, and advance the saved token
scope after the bounded change batch commits.

Finalization first removes rows not seen in the active generation in one SQLite transaction, then
writes the PhotoKit checkpoint, then clears verification progress. A crash after database
finalization resumes at the completed cursor and only repeats the small checkpoint finalization; it
does not repeat completed metadata or visual-analysis work.

## Scheduling Policy

- PhotoKit changes and user-prioritized work wake immediately.
- Existing catalogs interleave bounded verification slices with visual analysis.
- Empty catalogs continue metadata bootstrap without waiting for idle time.
- Visual analysis runs at utility priority while enabled.
- Automatic Photos publication remains separately idle-gated because it has external side effects.
- Low Power Mode, thermal pressure, sync activity, and system sleep pause new work; wake and policy
  changes resume through scheduler events.

## Automated Coverage

- event coalescing and deadline wakeup without polling;
- early wake replacing an obsolete deadline;
- bounded, coalesced PhotoKit change batches;
- expected self-mutation suppression without dropping external changes;
- secure PhotoKit token round-trip and history-first reconciliation;
- persistent full-verification cursor and commit ordering;
- incremental edits surviving full-generation cleanup;
- incremental inserts creating catalog and analysis work;
- unchanged PhotoKit metadata avoiding unnecessary overview refresh.

## Exit Gate

- [x] Timer polling and arbitrary post-publication ignore windows are removed.
- [x] One actor owns PhotoKit observation and persistent-history ingestion.
- [x] Incremental changes are bounded and persistent tokens commit only after local application.
- [x] Full verification survives relaunch without discarding its completed cursor.
- [x] Existing analysis jobs survive metadata verification when source revisions are unchanged.
- [x] Focused scheduler, checkpoint, and catalog tests pass.
- [ ] Run delete, Favorite, external edit, sleep/wake, and forced-relaunch scenarios against a copied
  owner-library state while watching for full-scan restarts and UI stalls.
- [ ] Record packaged-app responsiveness and scheduler signposts with Instruments.
- [x] Full native suite passes: 220 tests, 12 opt-in skips, zero failures.
- [x] Strict production build with complete concurrency checking passes with zero warnings.

No catalog wipe, managed Photos-album deletion, packaged-app deployment, or live indexing restart
occurred in this phase.
