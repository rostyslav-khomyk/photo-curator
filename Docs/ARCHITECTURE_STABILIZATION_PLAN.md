# Photo Curator Architecture Stabilization Plan

Status: accepted; Phase 0 guardrails in progress
Prepared: 2026-09-21
Baseline: `fdca2bae` on `codex/photo-curator-full-history-snapshot`

## 1. Executive decision

Photo Curator should keep its native SwiftUI product direction and the useful pure curation
components, but replace the foundations that coordinate persistence, background work, PhotoKit
changes, publication, and the Moments read model. Its grouping and selection behavior should then be
recalibrated against the whole library rather than preserved as unquestioned product truth.

This is not primarily a lack-of-locks problem. Complete Swift concurrency checking currently reports only four unique warnings. The repeated failures come from higher-level ownership problems:

- The same durable fact is represented in SQLite, large JSON snapshots, thousands of small files, UserDefaults, and in-memory controller state.
- Several independent triggers can rebuild, publish, reconcile, or overwrite the same logical state.
- The UI receives complete `PhotoMoment` values containing all member photos and derived evidence when it needs only a small card summary.
- A two-second timer and many unstructured `Task` calls form an implicit scheduler whose state is spread across booleans.
- PhotoKit is both an input source and a mutation target, but self-authored and external changes are distinguished with timing flags instead of durable operations.
- Publication crosses a nontransactional system boundary, while its journal and the Moments catalog are persisted separately.

The target is deliberately boring: SQLite is the durable local authority, one component owns each mutable subsystem, the UI reads compact projections, background jobs are explicit and resumable, and external mutations use recoverable sagas.

## 2. What the evidence says

### 2.1 Production-scale snapshot

The current real library gives us a valuable baseline:

| Measure | Current value |
| --- | ---: |
| Indexed photos | 108,999 |
| Derived Moments | 5,224 |
| Selected highlights | 14,279 |
| Curator support data | 2.7 GB |
| Main SQLite database | 1.4 GB |
| Vision result payloads | 1.373 GB, about 13 KB per photo |
| Analysis rows in `running` state | 3,414, despite a single-flight analyzer |
| `moments-catalog.json` | 57 MB |
| Catalog parse peak in `jq` | 227 MB RSS |
| Background-context files | 226,026 files, 883 MB |
| OCR evidence files | 105,818 files, 414 MB |
| Publication journal files | 2,620 files |

The catalog contains every photo record inside its Moment. A lazy SwiftUI grid cannot recover the memory already spent decoding and transforming that complete graph.

The source has 203 behavioral tests but no `measure`/`XCTMetric` performance tests and no signposted
application intervals. `CuratorController.swift` is about 1,386 lines and combines orchestration,
PhotoKit reconciliation, UI state, analysis policy, grouping, and publication. A live process sample
also found the bundled `icloudpd --web-ui` helper resident even with no active upload, reached through
startup Google access checks. These are measurable boundaries for the first stabilization phase.

### 2.2 Failure pattern from the development record

The recent failures are related symptoms:

1. Full-library metadata scans restarted after local mutations and rebuilds.
2. Analysis starved because a timer repeatedly re-entered completed metadata work.
3. Full overview refreshes paused the app for seconds and overwrote newer state.
4. Place enrichment performed quadratic work and reached more than 17 GB RSS.
5. Feature prints were repeatedly decoded inside pairwise loops.
6. Loading older Moments materialized too much data and reached about 2.2 GB RSS.
7. PhotoKit callbacks caused by publication canceled or restarted the work that authored them.
8. A Photos album could be created successfully while a competing catalog refresh lost its published marker.
9. Publication recovery produced generic numeric `PublicationFailure` alerts and recurring conflicts.
10. Large all-in-one snapshots required progressively larger size ceilings.

Each local fix was reasonable, but the architecture kept allowing the same classes of conflict to return.

### 2.3 Strong parts to preserve

- The curation algorithms are mostly pure, testable functions. Preserve their reusable evidence and
  scoring pieces while evaluating their outcomes at full-library scale.
- `CuratorStore` already uses SQLite, WAL mode, transactions, stable job leases, and idempotent upserts.
- The app uses public PhotoKit, Vision, MapKit, and Google Photos APIs.
- The test suite has 203 tests across 35 files and contains substantial behavioral coverage.
- Publication already recognizes that external side effects require recovery rather than blind retry.
- The product workflow and safety boundaries are documented in detail.

### 2.4 Whole-library curation finding

The companion [`HOLISTIC_LIBRARY_AUDIT_2026-09-21.md`](HOLISTIC_LIBRARY_AUDIT_2026-09-21.md)
analyzes the current 108,999-photo catalog as a family photographic history.

- 56.6% of Moments contain at most three photos but only 4.3% of all photos.
- 5.1% of Moments contain more than 100 photos and hold 63.9% of all photos.
- July and August contain 41.1% of captures, with about 49-62 photos per active shooting day, while
  several quieter months average about 12-16.
- 216 Moments over 100 photos still have generic category or date/place titles.
- Historical GPS coverage varies from nearly zero to more than 90%, so missing location is not a
  neutral feature across the library's lifetime.

This is not solved by one better gap threshold. The product needs a small optional hierarchy: a
grounded family `Story` can contain coherent scene-level `Moments`, and each Moment contains selected
`Highlights`. Dense trips gain internal structure without losing the outing. Sparse everyday photos
remain honest standalone Moments and are browsed through calendar/place views unless there is real
evidence for a Story.

## 3. Non-goals

This rearchitecture will not:

- Replace every mathematical grouping, selection, or narrative component at once. Candidate changes
  run as versioned, measured generations and reuse existing evidence where appropriate.
- Introduce SwiftData. The app supports macOS 13, and a framework migration would not solve external side effects or task ownership.
- Introduce Core Data merely to replace working SQLite primitives.
- Add a general dependency-injection framework, event bus, microservices, or one protocol per type.
- Rebuild the UI design while changing persistence and scheduling.
- Promise exactly-once PhotoKit or Google behavior across crashes; those APIs do not share a transaction with our database.
- Keep two complete architectures alive indefinitely behind feature flags.

## 4. Invariants

The implementation must enforce these rules:

1. SQLite is the sole authority for durable curator and user-authored state.
2. UserDefaults stores only small UI preferences, never growing collections or workflow state.
3. Derived files are caches. Deleting them may cost time but must not lose user decisions.
4. The MainActor owns presentation state only. It does no image resizing, full-library grouping, JSON decoding, database scanning, OCR, or Vision work.
5. Exactly one owner mutates each subsystem: catalog, PhotoKit ingestion, analysis jobs, publication, Google sync, and thumbnails.
6. UI refreshes never write domain state.
7. Every external mutation is represented durably before it starts and reconciled after interruption.
8. Cancellation is control flow, not a user-facing failure.
9. A rebuild or relaunch does not invalidate completed work unless an input or algorithm version changed.
10. User edits and grouping decisions survive regrouping, migration, crashes, and cache deletion.
11. Photo volume controls available detail, not presumed emotional importance.
12. A candidate curation generation cannot replace the active generation until its whole-library
    report is complete and user decisions have been reconciled.
13. A SQLite transaction is synchronous from begin through commit or rollback. No transaction may
    suspend, call PhotoKit, perform image work, or cross an actor boundary.

## 5. Target architecture

```text
SwiftUI views
    |
    v
WorkspaceModel (@MainActor)
    | commands                         compact snapshots / typed changes
    v
Application coordinators
    |- LibraryCoordinator actor <---- PhotoKit change observer
    |- CurationScheduler actor
    |- PublicationCoordinator actor
    |- GoogleSyncCoordinator actor
    |- ThumbnailPipeline
    |
    v
CatalogStore
    |- one serialized writer connection
    |- bounded read-only connections for short UI queries
    |- WAL, migrations, constraints, transactions
    |
    +---- durable catalog.sqlite in Application Support
    +---- rebuildable analysis-cache.sqlite in Caches

Pure domain code
    adaptive boundaries, Story grouping, selection, narrative, evidence scoring
```

There should be no generic application event bus. Coordinators call explicit commands and expose typed `AsyncStream` changes where observation is needed. System-level notifications remain appropriate for window activation and OS lifecycle only.

`CatalogStore` owns every SQLite connection. Its writer actor submits a synchronous, nonescaping
transaction closure to the serialized SQLite connection; a read connection is never shared by
concurrent queries. Callers gather PhotoKit, Vision, and other asynchronous inputs before opening a
transaction, then publish typed changes only after commit. Transaction closures cannot `await`, call
external APIs, or invoke callbacks. Signposts and debug assertions flag unexpectedly long writes.

## 6. Durable data model

The exact columns can evolve during implementation, but the ownership boundaries should not.

### 6.1 Durable catalog database

`assets`

- PhotoKit local identifier, creation/modification dates, dimensions, favorite/hidden state, location, media subtype, source revision, seen generation.
- Indexed by date and source revision.

`moments`

- Stable UUID, start/end, grouping revision, state, cover asset ID, counts, canonical headline/story, narrative provenance, customization state.
- Publication and Google status are projected into the card summary but remain normalized.
- Indexed by `(start DESC, id)` and state.

`stories`

- Stable UUID, date range, kind, title/story, confidence, generation, and aggregate counts.
- A Story is a browse and narrative parent, not another copy of asset membership.
- Stories are optional and require positive evidence of one occasion, outing, trip, or reviewed user
  relationship. Calendar months, seasons, and places are views, not automatic Stories.

`story_moments`

- Story ID, Moment ID, sequence, and continuity evidence.
- Unique Moment membership within an active automatic generation; reviewed manual relationships are
  protected.

`moment_assets`

- Moment ID, asset ID, sequence, display role, automatic selection state.
- Unique `(moment_id, asset_id)` with foreign keys.

`asset_decisions`

- User include/exclude decision and favorite intent when needed for pending UI work.

`moment_edits`

- User title, description, grouping protection, edit revision, and timestamps.

`jobs`

- Stable key `(kind, subject_id, algorithm_version)`, priority, state, attempt count, lease token/expiry, not-before date, last typed error.
- States: pending, leased, succeeded, deferred, failed, blocked.

`publications`

- Operation ID, Moment ID, immutable request snapshot, destination, phase, external identifier, verification result, error category, timestamps.

`google_exports`

- Operation and destination album, per-asset status, remote media ID where available, and reconciliation state.

`meaningful_places`, `geocode_cache`, `library_checkpoint`, and `schema_migrations`

- Replace growing UserDefaults and isolated JSON records.

`curation_generations` and `generation_metrics`

- Algorithm/evidence versions, lifecycle state, aggregate quality metrics, comparison result, active
  marker, and rollback expiry.
- Only one generation is active. Candidate generation writes never mutate the active read model.

### 6.2 Stable Moment identity

Moment identity cannot be a fresh hash of the latest grouping. When grouping changes:

1. The engine produces candidate segments with deterministic membership fingerprints.
2. A transactional reconciliation matches candidates to existing Moments using exact membership first, then a conservative overlap rule.
3. Durable user anchors -- explicitly included/highlighted assets, protected grouping members, and a
   user-selected cover -- receive dominant inheritance weight. A candidate containing a uniquely
   matching anchor set normally inherits the existing UUID even when surrounding membership shifts.
4. Reviewed/protected Moments are never silently reassigned. If anchors split across candidates,
   conflict, or disappear, reconciliation fails closed rather than guessing.
5. Ambiguous matches create new Moments and retain the old record for explicit reconciliation.
6. User edits and publication history stay attached to the stable Moment UUID.

The existing `MomentIdentityResolver` can inform this logic, but it must be connected to the primary database path rather than maintained as another sidecar archive.

### 6.3 Derived analysis cache

Vision feature prints are intrinsically large: the present corpus needs about 1.37 GB. Pretending this can be made tiny would be dishonest.

- Keep versioned Vision, OCR, and scene evidence in a separate SQLite cache under `Library/Caches/Photo Curator`.
- Avoid hundreds of thousands of small JSON files and their filesystem overhead.
- Store cache version, byte count, last access, and source revision.
- Expose cache size in Settings and provide a safe `Rebuild Analysis Cache` action.
- Never automatically purge current analysis merely because it is old; that would create surprise reprocessing.
- Apply a documented storage budget and low-disk pause. If a limit is reached, pause with an actionable status instead of silently thrashing.

### 6.4 Versioned holistic curation

Do not tune the active 5,224-Moment catalog in place. A curation run has an immutable generation ID
and produces candidate Stories, Moments, membership, narratives, covers, and highlights beside the
active generation.

The first candidate model should stay deterministic and small:

1. Form timezone-aware logical shooting days.
2. Estimate scene boundaries from time gap relative to local capture cadence, location/venue change,
   visual continuity, activity evidence, and metadata uncertainty.
3. Optionally build parent Stories from adjacent scene-level Moments that share an outing, occasion,
   route, or manually reviewed relationship. Leave Moments standalone when that evidence is absent.
4. Allocate highlights hierarchically with diminishing returns. Score personal intent, quality,
   coverage, chronology, diversity, and contextual rarity separately before combining them with
   documented weights. Emotional significance comes only from owner signals, never photo volume.
5. Generate titles only from grounded Story/Moment evidence and retain a clean date/place fallback.

No universal density target is appropriate. Dense vacation days may contain many scene Moments under
one Story; sparse periods may contain honest standalone single-photo Moments. Local capture cadence
may influence a boundary, but month/year seasonality must not. Seasonality is used only for overview
and cross-library summary allocation. Missing historical GPS lowers confidence rather than forcing a
join.

Boundary evaluation is asymmetric: joining two unrelated events is costlier than temporarily
splitting one event, because a false join corrupts grouping, narrative, and publication together.
Track both costs explicitly and set their weights from the owner-reviewed benchmark rather than an
arbitrary universal constant.

Before activation, compare the candidate with the active generation using counts, size quantiles,
false-join and false-split costs, fragmented days, giant Moments, generic-title rate, each highlight
dimension, user-edit reconciliation, and the frozen owner-reviewed benchmark. Activation is one
database transaction. Keep the previous generation for a bounded rollback window, then delete it.

## 7. Moments UI read model

The first implementation should not reintroduce complex bidirectional pagination.

The real library has 5,224 Moments. Holding 5,224 compact summaries is reasonable; holding 5,224 complete Moments containing 108,999 photos is not.

### 7.1 Summary projection

`MomentSummary` should contain only:

- Moment ID and revision.
- Date range and display title/status.
- Photo and highlight counts.
- Cover asset ID plus a small fallback candidate list.
- In Photos / In Google / customized flags.
- Grouping and narrative readiness flags.

The workspace loads all summaries in one indexed query, normally a few megabytes at most. Filters operate over summaries or an equivalent indexed SQL query. `MomentDetail` and its photo membership load only when a review window opens.

### 7.2 Updates

- A database commit emits changed Moment IDs and revisions.
- `WorkspaceModel` coalesces bursts for a short interval and replaces only changed summaries.
- Structural changes can reload the compact summary list; they never decode every photo or rerun grouping on the MainActor.
- A background analysis completion updates one summary only when its visible fields changed.
- View bodies receive precomputed values. A card does not inspect full membership or query upload sets.

### 7.3 Position and interaction

- Persist the anchor Moment ID, not a pixel offset.
- On reopen, load summaries, scroll to the anchor, and restore the keyboard cursor.
- If the anchor no longer exists, choose the nearest date.
- Remove `Load Older Moments`; scrolling covers the whole summary list.
- Keep the established keyboard model and mouse-click cursor behavior.
- Visible and near-visible cover IDs drive thumbnail preheating.

If measurements later show that compact summaries themselves are too large at substantially bigger libraries, add keyset paging then. Do not build it speculatively now.

### 7.4 Library Overview

Add a holistic overview backed by aggregate SQLite queries, not image loading:

- year/month timeline for photos, Stories, Moments, and highlights;
- dense capture seasons, quiet periods, likely trips/outings, and unresolved ranges;
- fragmentation and over-aggregation indicators linked to filtered Moments;
- analysis coverage, active algorithm generation, last complete run, and disk use;
- candidate-versus-active comparison before a full-library curation switch.

Use neutral photographer language. “Quiet period” describes capture density; it does not mean the
period or its photographs were unimportant. Timeline and seasonal aggregates never create semantic
Stories or alter event boundaries by themselves.

## 8. Thumbnail pipeline

- Use one `PHCachingImageManager` for grid thumbnails, as Apple recommends for collection-style interfaces.
- Preheat the visible rect plus approximately one screen in each direction; stop caching items that leave the preheat window.
- Request the rendered card size, not 1024 or 4096 pixels by default.
- Maintain a cost-limited `NSCache` of decoded card images.
- Move `CGContext` resizing and image decoding off the MainActor through a nonisolated async function or bounded detached work.
- Keep review-quality image requests separate from grid thumbnails and allow iCloud access only for explicit review.
- Key each request by Moment ID, summary revision, cover asset ID, target size, and display scale.
- Cancel requests for reused/disappeared cards. A completion whose full request key no longer matches
  performs no presentation-state mutation.
- Separate the displayed image from the pending request. While a replacement is pending, retain the
  last valid image if its cover asset is still eligible, then replace or crossfade it only after the
  current request succeeds. This prevents a rejected stale completion from blanking the card.
- If there is no valid prior image, keep one stable skeleton. If the prior cover was deleted, hidden,
  or removed from the Moment, discard it immediately and show the skeleton rather than stale content.
- Show an unavailable state only after the current cover is confirmed ineligible or bounded retries
  for the current request are exhausted.
- Choose cover IDs during curation and persist them. Thumbnail loading must not decide Moment semantics.

## 9. Background scheduling

Replace the two-second controller timer with one retained scheduler task.

### 9.1 Event-driven wakeup

The scheduler wakes when:

- PhotoKit reports a coalesced library change.
- A user prioritizes a range or visible Moment.
- A job finishes or its retry time arrives.
- Power, thermal, foreground, or sync policy changes.
- The app launches with unfinished leased work.

When no work is eligible, it suspends on an `AsyncStream` or clock deadline. It does not poll.

### 9.2 Queue classes

Priority order:

1. User-requested detail and visible cover preparation.
2. User-prioritized range analysis.
3. Small PhotoKit change ingestion, including dependency slices required by priority 2.
4. Narrative and grouping updates needed by visible summaries.
5. Ordinary analysis and full verification.
6. Automatic publication, only under its explicit policy.

Start with one Vision/OCR worker because the present analyzer and PhotoKit loader are designed for single flight. Add bounded parallelism only after Instruments proves it improves throughput without memory or UI regressions.

Every long operation works in bounded transactions, yields between units, and checks policy. No coordinator is represented by an open-ended set of unretained `Task` values.

PhotoKit ingestion runs in bounded quanta, initially no more than 100 changes or 500 milliseconds,
then returns to scheduler arbitration. If user-prioritized work is waiting, ingestion cannot receive
two consecutive quanta unless that ingestion is a declared dependency of the user request. Continuous
iCloud changes therefore make progress without starving explicit user work.

A full-library candidate generation runs below visible thumbnails, user commands, publication, and
new-photo curation. It processes bounded date partitions, commits checkpoints, and can pause without
discarding completed partitions. Overview metrics are computed incrementally from committed rows.

## 10. PhotoKit ingestion

`LibraryCoordinator` exclusively owns the fetch result and PhotoKit change observer.

- The observer callback does minimal work and forwards a typed event to the actor.
- Incremental `PHFetchResultChangeDetails` are coalesced and applied as asset upserts/deletes.
- Nonincremental changes schedule a resumable verification generation, not a UI-blocking reset.
- Full verification records progress and can repeat idempotently after a crash.
- Assets are deleted from the local catalog only after a completed, authorized generation confirms absence.
- A permission problem or suddenly empty fetch can never erase the prior catalog.
- App-authored Favorite, deletion, and album changes register expected effects by operation ID. Matching observer events confirm those effects; they do not cancel publication or restart unrelated analysis.

The seven-day verification can remain as a safety audit, but it must be cheap to resume and must not invalidate finished analysis when source revisions match.

## 11. Photos publication saga

PhotoKit and SQLite cannot share an atomic transaction, so publication must be an explicit saga owned by one actor.

Phases:

```text
requested -> applying -> verifying -> succeeded
                       -> needsReconciliation
           -> failedBeforeEffect
```

Rules:

- Persist the immutable request and stable operation ID before calling PhotoKit.
- Only `PublicationCoordinator` may execute a publication for a Moment.
- All UI and automatic requests route through the same command.
- After PhotoKit returns, verify album identity and membership, then commit the receipt and Moment status in one SQLite transaction.
- Persist verification attempt count and `not_before`, then re-fetch album identity and exact requested
  membership with bounded exponential backoff and jitter. This covers cold-launch and batched PhotoKit
  visibility delays.
- If the app stops in `applying`, recover through the same verification schedule. Do not reapply after
  one empty fetch; require stable absence across fresh fetches before retrying the mutation.
- Treat a matching PhotoKit observer event as an early wake-up hint and expected evidence, not as the
  sole proof of success. Verification still reads the resulting PhotoKit state.
- If an effect remains ambiguous or verification exhausts its retry budget, enter
  `needsReconciliation` and never create another album blindly.
- Make `PublicationFailure` a `LocalizedError` with stable categories, recovery suggestions, and an operation ID suitable for logs.
- Default automatic publication to off during closed alpha until restart, sleep/wake, and forced-termination soak tests pass.

Exactly-once behavior cannot be guaranteed across an external API crash gap. The production promise is: no blind duplicate, durable recovery, and an honest reconciliation state.

## 12. Google sync boundary

Google sync is a separate product boundary and must not own or refresh the curator catalog.

- Start the bundled helper only for credential checks or an active Google operation, then stop it deterministically.
- Remove startup credential probing that launches the helper before the user requests Google work.
- Persist export operations and per-asset completion in SQLite instead of growing UserDefaults arrays.
- Store OAuth tokens in Keychain, not adjacent JSON files.
- Keep staging files in Caches or temporary directories and delete them after terminal operation states.
- Route Google completion into a narrow `google_exports` update and changed-summary event.
- Consider a native Google client only after the curator stabilization is complete; replacing the helper now expands the critical path without fixing Moments.

## 13. Concurrency rules

- Keep Swift 5 language mode initially, enable complete strict-concurrency checking in normal builds, and reduce the four current warning sites to zero.
- Make cross-actor DTOs immutable and `Sendable`.
- Do not use `@unchecked Sendable` to silence design problems.
- A `Task` created inside `@MainActor` inherits that isolation. Heavy functions must be explicitly nonisolated or run as bounded detached work before returning small values to the UI.
- Each coordinator retains and cancels its own long-lived task.
- Avoid callbacks that mutate shared state after their owning request has been superseded; compare stable tokens and revisions.
- Keep every database transaction closure synchronous and nonescaping. Complete asynchronous
  preparation before `BEGIN`, emit observations after `COMMIT`, and never hold a transaction across
  an `await`.
- Move to Swift 6 language mode only after behavior is stable and the strict build remains warning-free.

## 14. Observability and performance gates

Add `OSSignposter` intervals for:

- launch to first interactive frame;
- summary query and summary diff application;
- visible thumbnail request and decode;
- PhotoKit change ingestion and full-verification slices;
- analysis, grouping, narrative, and publication phases;
- SQLite transaction duration;
- Google preparation and upload phases.

Logs use subsystem/category, operation IDs, counts, duration, and typed outcomes. They do not log titles, OCR text, GPS coordinates, or asset identifiers by default.

### Initial acceptance budgets

These are gates to validate on the oldest supported test Mac, not promises derived from the development Mac:

| Workflow | Gate |
| --- | --- |
| Warm launch to interactive workspace | under 1.5 seconds |
| Summary database query, warm p95 | under 50 ms |
| Discrete main-thread response | under 100 ms; target under 50 ms |
| SwiftUI card body work | no repeated body update over 1 ms in Instruments |
| Continuous scroll work | normally under 5 ms per main-thread update |
| First local visible thumbnail, p95 | under 1 second |
| Browse full 5,224-Moment history | steady RSS under 350 MB |
| Memory growth after top-to-bottom-to-top browse | under 50 MB after caches settle |
| Idle with no eligible work | under 1% CPU |
| Background analysis while actively browsing | no main-thread hang over 100 ms |
| Restart during any job | resumes without repeating completed source revisions |
| Restart during publication | no duplicate album and no unexplained numeric alert |

Use Instruments SwiftUI, Hangs/Hitches, Time Profiler, Swift Concurrency, Allocations, File Activity, and Energy Log. Add XCTest performance coverage with `XCTOSSignpostMetric`, memory/storage metrics where supported, and checked baselines.

## 15. Test strategy

### Deterministic fixtures

Build a metadata-only library generator for 10k, 100k, and 250k assets with:

- seasonal density shifts, dense trips, sparse home photos, old scans, screenshots, duplicates, no
  Favorites, historically changing GPS coverage, and large venue days;
- deterministic grouping and expected stable IDs;
- configurable PhotoKit-like inserts, deletes, edits, and reorderings.

Keep private photos out of CI. Retain the existing exported-photo quality set as an explicit local opt-in suite.

### Required scenarios

- Fresh import, incremental launch, seven-day verification, and interrupted verification.
- Scroll entire history repeatedly while analysis runs.
- Open/edit/delete/favorite/merge during ingestion and analysis.
- Quit or force-terminate before, during, and after PhotoKit publication.
- Delay and coalesce PhotoKit observer delivery, delay cold-launch visibility, and terminate at every
  publication phase to exercise persisted verification backoff.
- Self-authored PhotoKit changes interleaved with external edits from Photos.
- Sustain continuous PhotoKit changes while visible-cover and user-prioritized work wait; assert
  bounded scheduler latency and continued ingestion progress.
- Sleep/wake, thermal pressure, Low Power Mode, denied/limited/revoked Photos access.
- Cloud-only and damaged assets, missing thumbnails, and low disk space.
- Race thumbnail revisions, cover replacements, deletion, view reuse, cancellation, and failure;
  assert that stale completions never mutate a card and a valid displayed frame never flickers away.
- Google append/replace interruption and restart.
- Candidate-generation interruption, comparison, activation, and rollback.
- Dense trip decomposition into scene Moments under one Story without fragmenting sparse milestones.
- Regroup dense capture periods around user anchors; assert unique UUID inheritance and fail closed on
  split or conflicting anchors.
- Whole-library metrics remain identical across restart and incremental recomputation.
- Migration from the current 2.7 GB installation without losing user edits or publication markers.
- Apple Silicon and Intel Macs across macOS 13 through the newest supported release.

Use Thread Sanitizer and Main Thread Checker in dedicated test runs. A clean compiler concurrency audit complements but does not replace these runtime tests.

## 16. Migration and rollback

Never require another destructive reset.

1. Create `catalog-v2.sqlite` beside the current state.
2. Pause writers and import asset metadata, Moment identity/membership, review decisions, titles, places, publication markers, and Google status.
3. Keep the existing analysis-result database in place initially to avoid copying 1.4 GB.
4. Verify counts, foreign keys, stable-ID uniqueness, publication references, and sampled selections.
5. Atomically write a cutover marker only after validation succeeds.
6. If interrupted before cutover, discard the incomplete v2 database and restart the idempotent import.
7. Keep old JSON/UserDefaults state read-only for one alpha cycle; do not dual-write it.
8. After explicit verification, remove legacy snapshots and consolidate derived caches in a separate maintenance release.

The migration must estimate required free space before starting and refuse safely when space is insufficient.

## 17. Delivery sequence

Feature work should pause until Phases 0 through 5 pass their gates.

### Phase 0: Baseline and stop-the-line guardrails, 2-3 days

Implementation and gate status are tracked in [`PHASE0_BASELINE.md`](PHASE0_BASELINE.md). Automated
guardrails are present; packaged-app traces and approval of the private owner benchmark remain open.

- Add signposts, performance fixtures, repeatable Instruments scripts/checklists, and a diagnostic bundle exporter.
- Record launch, scroll, analysis, storage, publication, and restart baselines on the current build.
- Freeze an owner-reviewed benchmark before migration: representative dense trips, quiet periods,
  old scans, missing-GPS sequences, home/work life, celebrations, museums/venues, and recent GPS-rich
  days. Record expected split/join decisions, optional Story membership, titles, and highlights using
  stable source asset IDs.
- Enable complete strict-concurrency warnings and fix the four current warning sites.
- Default automatic Photos publication off for new alpha installs.
- Exit gate: reproducible performance report, versioned owner-reviewed curation fixture, and no
  concurrency warnings.

### Phase 1: Catalog v2 and migration, 5-8 days

- Add schema, constraints, migrations, stable Moment reconciliation, and summary/detail queries.
- Import current SQLite/JSON/UserDefaults state idempotently.
- Keep algorithms and UI behavior unchanged.
- Exit gate: migration passes on a copied real catalog and all user edits/publication markers match.

### Phase 2: Compact Moments read model, 4-6 days

- Switch the workspace to `[MomentSummary]` and detail-on-open.
- Restore anchor/cursor, remove `Load Older Moments`, and make filters summary-based.
- Add visible-range thumbnail preheating and bounded image caching.
- Exit gate: full-history browse meets responsiveness and memory budgets while analysis runs.

### Phase 3: Explicit scheduler and PhotoKit owner, 5-8 days

- Replace timer/boolean scheduling with durable jobs and event-driven wakeup.
- Centralize PhotoKit observation, incremental ingestion, full verification, and expected self-mutations.
- Exit gate: deletion/favorite/edit/sleep/relaunch tests do not restart completed work or stall UI.

### Phase 4: Publication saga, 3-5 days

- Move journals and published markers into one database transaction boundary.
- Route manual and automatic publication through one coordinator.
- Add deterministic recovery and typed errors.
- Exit gate: repeated forced-termination matrix produces no duplicate albums or lost receipts.

### Phase 5: Cache and disk normalization, 3-5 days

- Consolidate small evidence files into the derived cache database.
- Move rebuildable data to Caches, add storage reporting, low-disk policy, and bounded maintenance.
- Exit gate: file count and write amplification fall materially, with no reanalysis loop after relaunch.

### Phase 6: Holistic curation generations, 5-8 days

- Add adaptive logical-day/scene boundaries, optional Story parents, hierarchical highlight
  allocation, and grounded titles as a candidate generation, reusing the current evidence cache.
- Add the aggregate Library Overview and active-versus-candidate comparison.
- Validate against the current corpus audit and frozen owner-reviewed benchmark. Report false joins
  separately from false splits, with false joins weighted more heavily.
- Exit gate: candidate activation and rollback are atomic; measured fragmentation, over-aggregation,
  narrative, and separately reported highlight dimensions improve without losing user decisions.

### Phase 7: Maintenance and nuclear reset, 2-3 days

- Add storage reporting, versioned curation rebuild, full evidence reanalysis, and the crash-resumable
  destructive reset described below.
- Verify managed Photos container ownership from persisted identifiers and hierarchy, never title alone.
- Exit gate: interruption tests pass and Photos asset/Favorite counts remain unchanged after reset.

### Phase 8: Google operation hardening, 3-5 days

- Make helper lifecycle request-scoped, move tokens to Keychain, and persist export state in SQLite.
- Exit gate: interrupted uploads reconcile and no helper remains running without an active operation.

### Phase 9: Closed-alpha qualification, 1-2 weeks

- Run multi-day soak tests on at least three real libraries and the 250k synthetic fixture.
- Produce a Developer ID-signed, hardened-runtime, notarized build with stable bundle identity and entitlements.
- Start with manually distributed notarized DMGs; defer an updater until alpha feedback justifies it.
- Collect privacy-preserving local diagnostics and opt-in exported support bundles.
- Exit gate: zero data-loss incidents, zero duplicate albums, no recurring hangs, and all performance budgets met or explicitly renegotiated.

Expected focused effort for one developer: roughly 6-9 weeks, including curation evaluation and soak
time. Independent review should happen after this plan, after Phase 1 schema/migration, after the
Phase 6 corpus comparison, and before closed-alpha distribution.

## 18. Maintenance and nuclear reset

Settings should contain a clearly separated `Maintenance` section. Three actions cover different
needs and must not be collapsed into one alarming button:

1. `Rebuild Curation with Latest Algorithm...` creates a shadow generation from existing metadata
   and evidence, preserves user work, shows a comparison, and switches only after acceptance.
2. `Reanalyze Entire Library...` also invalidates Vision/OCR/derived evidence. Use it when evidence
   extraction changed or corruption is suspected; show time and disk estimates.
3. `Reset Photo Curator...` is the nuclear clean-room option. It removes local curation and managed
   Photos containers, then starts from zero.

The first action is the normal way to improve algorithms. The third is an escape hatch and full clean-
room validation tool, not a substitute for schema migration or routine algorithm upgrades.

### 18.1 Reset scope

The confirmation sheet must enumerate the exact effects and counts before enabling Reset:

- delete the local curator catalog, analysis cache, generated narratives/evidence, job state,
  publication history, custom Moment titles, selections, merges, and review decisions;
- delete only albums and folders proven to be managed by Photo Curator under its `Photo Curator`
  hierarchy in Photos;
- preserve every photo and video asset in the Photos library, including assets referenced by those
  albums;
- preserve Photos Favorites, Recently Deleted, unrelated albums/folders, and shared albums;
- preserve Google Photos albums/media, Google authorization, Significant Places, and ordinary app
  preferences;
- rotate normal logs but retain one small privacy-safe reset receipt with operation ID, time, counts,
  and terminal outcome.

Do not identify managed albums by title alone. Prefer stored PhotoKit local identifiers and verify
their parent hierarchy. A same-named user album elsewhere in Photos must never be touched.

### 18.2 Reset workflow

1. Pause and cancel scheduler, analysis, publication, thumbnail, and Google operations and wait for
   their owners to acknowledge quiescence.
2. Create a durable reset operation outside the directory being erased.
3. Fetch and display the number of managed Photos containers that will be removed and the local disk
   space that will be reclaimed.
4. Require an explicit native confirmation that states user curation will be lost. The system may
   present an additional Photos authorization confirmation.
5. Delete the managed Photos albums/folders through public PhotoKit and verify the result. Album
   deletion must not delete contained assets.
6. Only after Photos reaches a known result, close database handles and remove the local catalog and
   caches. If the Photos result is ambiguous, keep local publication state and offer Resume Reset.
7. Recreate an empty schema, clear the reset operation, and return to first-run indexing. Never start
   the rebuild while old workers are still alive.

The operation must be idempotent and recover after a crash at every step. The separate
`Reanalyze Entire Library...` action covers the case where the catalog and user decisions should be
kept but derived evidence must be rebuilt.

### 18.3 Reset acceptance

- Interruption at every phase resumes without deleting unrelated containers or creating duplicate
  rebuild workers.
- A test library containing an unrelated album also named `Photo Curator` outside the managed
  hierarchy remains untouched.
- Asset and Favorite counts before and after reset are identical.
- After reset, the app can rebuild the full 108,999-photo corpus from zero and meet the scheduler,
  memory, and responsiveness gates in this plan.
- The UI never describes album deletion as photo deletion and shows the estimated reanalysis time
  and disk impact before confirmation.

Implement this after the new coordinators and v2 schema exist, so reset has one reliable way to stop
work and one authority to erase. A one-off deletion routine in the current architecture would add
another race-prone path that must immediately be replaced.

## 19. Deletion plan

As each replacement reaches its exit gate, delete rather than preserve:

- `moments-catalog.json` and its 96 MB ceiling.
- Per-Moment publication journals and lock files.
- Group-review, identity, automatic-moment, continuity, context, and OCR sidecar files after verified import.
- Growing UserDefaults dictionaries/sets for titles, decisions, memberships, and Google asset IDs.
- The controller’s two-second timer and restart booleans.
- Domain-level string `NotificationCenter` messages.
- Full `PhotoMoment` arrays from the Moments workspace.
- Startup Google helper probing and any remaining web-view-era routes not required by the native sync command path.

No legacy compatibility layer survives beyond the verified migration window.

## 20. Alpha release policy

A build is not alpha-ready merely because unit tests pass. It must also have:

- stable Developer ID signing, hardened runtime, notarization, and a fixed bundle identifier;
- an explicit supported macOS range and tested hardware matrix;
- a first-launch explanation of local analysis, disk use, Photos mutations, and Google transfer boundaries;
- automatic publication off by default;
- an in-app storage view and safe cache rebuild;
- exportable diagnostics with a privacy preview;
- a schema migration backup/rollback story;
- known-issues and recovery documentation;
- a release checklist that includes Instruments and forced-termination scenarios.
- owner-centered semantic acceptance on each alpha library; independent reviewers assess safety,
  architecture, performance, and usability but do not override the owner's judgment of family meaning.

## 21. Questions for independent audit

The external reviewer should challenge these points specifically:

1. Is SQLite plus a writer actor and short read connection sufficient, or is a mature wrapper justified by demonstrated migration/query complexity?
2. Is the stable Moment reconciliation conservative enough to preserve edits without attaching them to the wrong regrouped event?
3. Does any path still perform decoding, image work, database I/O, or grouping on MainActor?
4. Can a PhotoKit callback re-enter publication or verification through an indirect UI refresh?
5. Are all publication crash windows represented and tested, including success before local receipt persistence?
6. Can migration fail or run out of disk without touching the old authority?
7. Does the full thumbnail request key reject stale completions while retaining the last eligible
   displayed frame, and does invalidating an old cover remove it without waiting for its replacement?
8. Do the proposed memory and responsiveness budgets hold on the oldest supported Intel Mac?
9. Does moving derived analysis to Caches create any unacceptable automatic-purge behavior for a week-long initial analysis?
10. Can Google credentials and operation state be migrated to Keychain/SQLite without forcing unnecessary consent?
11. Can nuclear reset prove album ownership without relying on a user-visible title, and can every
    interruption point resume safely?
12. Is the optional `Story -> Moment -> Highlight` relationship sufficient for grounded events while
    leaving unrelated everyday Moments standalone?
13. Do candidate-generation metrics detect both over-segmentation and under-segmentation, or can an
    apparently improved aggregate hide worse family memories?
14. Does whole-library balancing preserve sparse years and occasions without imposing artificial
    equality across genuinely different periods?
15. Is the frozen benchmark broad enough, and are false joins penalized strongly enough without
    leaving the catalog needlessly fragmented?

## 22. Research basis

- Apple, [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness): keep discrete main-thread work under roughly 100 ms, continuous interaction work within a display interval, and non-UI work off MainActor.
- Apple, [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance): measure long body updates and frequent invalidations with the SwiftUI instrument.
- Apple, [Observing changes in the photo library](https://developer.apple.com/documentation/photokit/observing-changes-in-the-photo-library): use fetch-result change details to update collection-style interfaces incrementally.
- Apple, [PHCachingImageManager](https://developer.apple.com/documentation/photos/phcachingimagemanager): preheat thumbnail-sized images for grids rather than loading full representations ad hoc.
- Apple, [Recording performance data](https://developer.apple.com/documentation/os/recording-performance-data): use `OSSignposter` IDs and intervals to distinguish concurrent operations in Instruments.
- Apple, [Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes): avoid rewriting serialized documents, use SQLite/WAL and appropriate indexes, and measure storage writes.
- Apple, [Reducing app disk usage](https://developer.apple.com/documentation/xcode/reducing-your-app-s-disk-usage): put recoverable data in purgeable cache locations and monitor file count and size.
- Swift, [Enable data-race safety checking](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/enabledataracesafety/): adopt complete checking before switching the language mode.
- Apple, [Keychain services](https://developer.apple.com/documentation/security/keychain-services): store small secrets in the system encrypted keychain.
- Apple, [Signing your apps for Gatekeeper](https://developer.apple.com/developer-id/): use Developer ID, hardened runtime, and notarization for direct macOS distribution.
- Cao et al., [Image Annotation Within the Context of Personal Photo Collections Using Hierarchical
  Event and Scene Models](https://www.cs.virginia.edu/~rmw7my/papers/personal-image.pdf): model personal
  collections hierarchically and account for partially missing GPS.
- Datia et al., [Time and space for segmenting personal photo sets](https://doi.org/10.1007/s11042-016-3341-2):
  exploit bursty capture, logical days, temporal cycles, and spatial context while balancing over- and
  under-segmentation.
- Sinha et al., [Effective summarization of large collections of personal photos](https://doi.org/10.1145/1963192.1963257):
  evaluate personal-photo summaries through quality, diversity, and coverage rather than count alone.
