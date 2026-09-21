# Background Curator: Development Record

## Architecture stabilization review (2026-09-21)

- Reviewed the full development record, product plan, evaluation documents, current Swift source,
  real application storage, compiler concurrency diagnostics, and current Apple/Swift guidance.
- The real catalog contains 108,999 photos and 5,224 Moments. Curator state occupies about 2.7 GB,
  including 1.37 GB of Vision results, a 57 MB all-in-one Moments snapshot, and more than 340,000
  small context/OCR files. Decoding the catalog alone peaked at about 227 MB in an independent probe.
- Complete strict-concurrency checking succeeds with four unique warning sites. The recurring failures
  are therefore diagnosed primarily as ownership and consistency failures above the data-race level:
  fragmented durable state, whole-catalog projections, implicit timer scheduling, and nontransactional
  PhotoKit effects coordinated through refreshes and timing flags.
- Wrote [`ARCHITECTURE_STABILIZATION_PLAN.md`](ARCHITECTURE_STABILIZATION_PLAN.md), proposing one
  SQLite authority, compact Moment summaries with detail-on-demand, explicit subsystem actors,
  event-driven durable jobs, recoverable publication sagas, a nondestructive migration, a safe
  nuclear reset, measured responsiveness gates, and closed-alpha qualification. No application
  behavior was changed.

## Full-History Catalog and Background Progress Fix (2026-09-21)

Resolved the apparent 2021 cutoff after a seven-day unattended run. The SQLite index
contained 108,999 photos dating to 1998, and persisted narrative records existed across
the full date range; the missing history was a presentation/cache failure rather than
lost curation. The visible catalog stopped at 2,600 Moments because its 29 MB snapshot
crossed a hard-coded 32 MB bound on the next page. The resulting enum surfaced as the
misleading modal `PublicationFailure error 0`.

The derived catalog bound is now 96 MB. Historical expansion reuses the already prepared
contiguous prefix and computes only the newly exposed suffix. The bottom sentinel is keyed
to the visible count and waits for an in-flight overview instead of dropping the request.
Deep scroll restoration delays thumbnail requests until the saved anchor is restored, so
the jump does not start preview work for every traversed card. Per-photo analysis counters
no longer publish whole-workspace invalidations.

PhotoKit incremental notifications now write metadata and rebuild the overview only when
the public metadata payload actually changed. Resource-availability-only notifications are
no-ops, preventing repeated full catalog refreshes from starving analysis.

Live acceptance on the real library loaded all 5,224 Moments, moving the oldest visible
date from 2021 through 2017 and 2010 to August 25, 1998. The final catalog is 56.5 MB.
No index, decisions, titles, albums, or source photos were reset. Full verification:
202 Swift tests executed, 10 opt-in tests skipped, zero failures; release packaging passed
and `dist/Photo Curator.app` was deployed. Ad-hoc signing required Photos consent again.

## Auto-Publishing Cancellation and Recovery Fix (2026-09-12)

Investigated the first unattended full-library publication run. Local telemetry confirmed
that analysis continued into thousands of assets, but publication produced 198 journals:
196 remained in `publishing`, two reached `published`, and only one album was visible to the
user. The primary feedback loop was the app's own PhotoKit folder/album changes invoking its
library observer, which cancelled the analysis task performing that publication. Recovery
then constructed a new random operation UUID, conflicted with the immutable saved request,
and could not resume. Normal SwiftUI refresh cancellation was also surfaced as a modal
`Swift.CancellationError`.

The controller now distinguishes its own publication changes from external library edits,
keeps the publication task alive, and silently ignores routine overview cancellation. It
reuses the journal's exact request during recovery. `CuratedPublication` remains fail-closed
by default, but the concrete PhotoKit path may retry after its exact managed hierarchy/title
lookup confirms that no album exists. Existing albums are recovered without recreating them.
Automatic publication now excludes unendorsed one-photo/supporting collections, while
reviewed or user-authored collections remain eligible.

Removed the undocumented `assetDescription` KVC mutation from `PhotoKitAlbumAdapter`.
PhotoKit exposes no public caption-editing API, so narrative text remains in Photo Curator;
album/folder creation and membership use public PhotoKit APIs only. Updated settings copy.

Focused verification: `swift test --filter 'CuratedPublicationTests|MomentDisplayEligibilityTests'`
passed 26 tests with zero failures. Added confirmed-absence recovery and production
auto-publication eligibility coverage. Full-suite/release deployment follows this checkpoint.


## Grounded Place Narratives, Multi-Candidate Suggestions & Accessible Review UI (Chunk 10) (2026-09-11)

Completed and polished Chunk 10 (Local Narrative Model & Grounded Text Generation):
1. **Reverse-Geocoded Place Grounding in Narratives & Titles:**
   - Updated `BackgroundMomentContext` and `MomentNarrativeSheet` to query `CuratorGeocodingService.shared.place(for: moment)` and pass the resolved place (`place?.friendlyName`, e.g. *"Fréjus"*, *"Woerden"*) into `MomentNarrativeMetadata.verifiedPlace`.
   - Updated `LocalMomentNarrative.candidates(_:)` to synthesize location into candidate titles (*"Food and dining in Fréjus"*, *"Fréjus · Aug 29, 2026"*, *"Fréjus in pictures"*) and narrative stories (*"13 photos (including 4 favorites) in Fréjus on Aug 29, 2026, highlighting outdoor scenery"*).
   - Removed robotic debug disclaimers across all fallback options.
2. **Prominent "Suggest Title & Story…" Action:**
   - Promoted "Suggest Title & Story…" to a primary button in `MomentReviewView` right next to the title field (previously hidden behind `advancedTools: false`).
3. **Multi-Candidate Interactive Selection in `MomentNarrativeSheet`:**
   - Replaced single take-it-or-leave-it suggestion with an interactive candidate cards list displaying the Curator's Top Pick and diverse alternatives (activity-focused, place-focused, date-focused).
   - Added instant 1-click adoption buttons: *"Use Title"*, *"Use Story"*, and *"Apply Both"*.
4. **Font Accessibility for Glasses Wearers:**
   - Bound `MomentNarrativeSheet` and `MomentTextEvidenceView` to `@AppStorage("curator.fontSizeScale")`, scaling all suggestion cards, text fields, and OCR clues cleanly.
5. **Testing, Build & Verification:**
   - Added `testPlaceGroundedCandidateGenerationWithAndWithoutActivity` in `LocalNarrativeTests`. Full regression suite: 177 tests passed, 10 opt-in skips, 0 failures.
   - Single release build via `macos/build_app.sh`, code signature verified, and relaunched at PID 49623.

## Thumbnail Consent Auto-Refresh, Settings Font Scale Slider & Prominent Typography (2026-09-11)

Resolved initial thumbnail stall on permission consent and introduced complete font accessibility controls:
1. **Thumbnail Auto-Refresh on Photos Consent Grant:**
   - **Root Cause**: On initial launch of an ad-hoc signed build, thumbnails in the viewport rendered while `PHPhotoLibrary.authorizationStatus` was still `.notDetermined`. They immediately caught `.permissionDenied` and displayed `"Not available locally"`. Because their SwiftUI `.task(id:)` only watched static photo identifiers, granting consent never triggered a re-fetch until manual scrolling recycled the cells.
   - **Fix in `PhotoKitThumbnailProvider`**: When status is `.notDetermined`, the provider intercepts the request, triggers/awaits `PHPhotoLibrary.requestAuthorization`, performs the fetch immediately upon approval, and broadcasts `.photoRelayPhotosAccessChanged`.
   - **Fix in `SimilarityThumbnail`**: Bound the loading task to a reactive `refreshCount` and registered listeners for both `.photoRelayPhotosAccessChanged` and `NSApplication.didBecomeActiveNotification`. When authorization is granted or the app regains focus from the macOS prompt, any failed/empty thumbnails automatically reload without requiring user interaction.
   - **Fix in `MomentsWorkspace`**: Automatically refreshes moment covers, titles, and place resolutions as soon as authorization changes.
2. **Settings Text Size Slider & Prominent Typography for Glasses Wearers:**
   - **App Settings Font Size Slider**: Added a dedicated *Display & Accessibility* section in `CuratorSettingsView` with an interactive text size slider (range: 85% to 160%, default 100%) persisting in `@AppStorage("curator.fontSizeScale")`.
   - **Prominent Initial Font Sizing**:
     - Doubled photo count badge from 11pt caption to 18pt font (`.system(size: 18 * fontSizeScale, weight: .medium)`) paired with a `photo.stack` icon.
     - Upgraded the "About this grouping" narrative from 11pt caption to 15pt text (`.system(size: 15 * fontSizeScale)`) with 4pt line spacing and `.foregroundStyle(.primary.opacity(0.88))`, and an enlarged 16pt semibold header.
     - Scaled Moment review titles (22pt), subtitles (15pt), grid card titles (16pt), and curator recommendation notes for effortless reading.
3. **Automated Testing & Single Release Build:**
   - All 176 tests passed in 4.4 seconds.
   - Single release build executed via `macos/build_app.sh`, verified code signature, and relaunched app at PID 48050.

## Native Auxiliary Review Windows, Popover Multiline Wrapping & Photographer Grouping Interpretation (2026-09-11)

Eliminated modal dialog friction, resolved popover text truncation, and replaced mechanical engineering grouping jargon with rich, photographer-oriented interpretations:
1. **Transition from Modal Sheet to Native Auxiliary Windows:**
   - Moved `MomentReviewView` from a modal `.sheet` into independent macOS `NSWindow`s managed by `MomentReviewWindowManager`.
   - Native macOS hardware-accelerated resizing across all four borders and corners with system cursor feedback, completely eliminating sheet drag stutter.
   - **Multi-Moment Review**: Users can now open and review multiple moments simultaneously, placing them side-by-side or across displays to compare shots.
   - **Always on Top (Floating)**: Added a pin button (`pin.fill` / `pin`) in the review window header with automatic `.floating` window level so review windows stay conveniently accessible above the library workspace.
   - Full keyboard shortcuts (`Cmd+W` to close, Return for Done).
2. **Fixed Popover Text Truncation (`...`):**
   - Replaced AppKit-clamped `Label` views with top-aligned `HStack` layouts in `ReviewSafetyHelpView` and `MomentsWorkspaceHelpView`.
   - Applied `.fixedSize(horizontal: false, vertical: true)` and `.lineLimit(nil)` across all popover text blocks (`Curator's Note` info popovers and safety help cards), allowing natural multiline text wrapping with zero ellipses clipping.
3. **Photographer-Oriented Grouping Interpretation (`MomentGroupingInterpretation`):**
   - Completely replaced the debug string `"Conservative time/location group; event not verified."` in both `AutomaticMomentSegmentation` and the Review Moment disclosure accordion.
   - Synthesizes session evidence into natural storytelling: photo and favorite counts, duration in minutes/hours, direct GPS validation versus same-day proximity extrapolation (*"Location estimated as Fréjus based on photos taken nearby on the same day"*), visual scenery/activity cues, and curation rationale (setting aside near-duplicates as alternative angles).
4. **Automated Testing & Single Release Build:**
   - Created `MomentGroupingInterpretationTests` validating direct GPS, extrapolated locations, partial GPS sessions, and visual activity clues.
   - Full test suite passed: 176 tests executed, 10 opt-in skips, 0 failures.
   - Single batched release build executed via `macos/build_app.sh`; verified codesign and relaunched app running at PID 46782.

## Photographer Persona UI Cleanup, macOS ? Help Popovers, Resizable Review Sheet & Reverse Geocoding (2026-09-11)

Transformed the Photo Curator interface from developer diagnostic terminology into a warm, clear, photographer-first user experience:
1. **Clean UI Copy & Elimination of Disclaimers:**
   - Erased all `"place not verified"`, `"unverified venue"`, `"pilot"`, `"logging is on"`, and `"kept for context"` strings across the entire application.
   - Replaced cold database pickers with photography-focused controls: `"In Moment: Curator's Pick / Always Include / Hide from Moment"`.
   - Updated collection counters to `"X highlights · Y photos"` and authored cards to `"✓ Customized"`.
   - Replaced cumbersome 3-line disclosure accordions on photo cards with lightweight, modular `(i)` info popovers (`ReviewPhotoCard`).
2. **Native macOS Settings-Style `?` Help Popovers:**
   - Modeled after macOS System Settings, added clean `?` help buttons in both the Moments grid header and the Review Moment dialog header.
   - Removed the 3-line legal disclaimer banner from the Review dialog; the `?` popover clearly guarantees that Apple Photos library originals are read-only and never modified, deleted, or synced to cloud services without user consent.
3. **Smoothly Resizable "Review Moment" Dialog:**
   - Implemented an interactive macOS diagonal resize grip (`SheetResizeHandle`) at the bottom-right corner of the sheet with real-time `DragGesture` resizing.
   - Bound sheet dimensions to `@AppStorage("curator.reviewSheet.width")` and `@AppStorage("curator.reviewSheet.height")` (defaults 940x700, min 640x520), persisting the user's customized window size across app launches.
4. **Native macOS Reverse Geocoding & Same-Day Timestamp Extrapolation:**
   - Created `CuratorGeocodingService` utilizing Apple's built-in `CLGeocoder` with persistent caching and rate-limiting to translate coordinates into human place names (*"Woerden"*, *"Amsterdam"*).
   - Implemented `CuratorLocationExtrapolator`: evaluates non-GPS photos on the same day using time proximity ($\Delta t \le 45\text{ min}$), intra-moment GPS consensus, and geographic sandwich bracketing, assigning locations when composite confidence $\ge 0.70$.
   - Strictly rejects conflicting city boundaries ($> 15\text{ km}$) and multi-hour gaps without bracketing, falling back gracefully to clean date/activity labels with zero robotic error text.
5. **Verification & Single Release Build:**
   - Full test suite passed: 171 tests executed, 10 opt-in skips, 0 failures (including new `CuratorGeocodingTests`).
   - Single release build executed via `macos/build_app.sh` (`dist/Photo Curator.app`); strict deep code signature verified.
   - App relaunched and verified running at PID 44819.

## Representative Shortlist Compaction and Robust Context (2026-09-11)

Implemented RepresentativeSelector in MomentSelection to compact oversized display
shortlists to curated target budgets (natural <=20, 20 for 20..60, 25 for 60..200, max 35
for >200). Uses quantile-based uniform temporal distribution across visit duration,
prioritizing Favorites, role diversity, and aesthetics. Unselected candidates move safely
to alternatives with transparent explanations, preserving user choices and Review access.

Updated BackgroundMomentContext to gather all available cached evidence instead of blocking
on 100% completion of sampled photos. Requires min(sampled, 4) analyzed photos to prepare
early grounded captions, refreshing automatically as remaining evidence settles.

Integrated into CuratorController display selection pipeline. Full regression suite passed:
165 tests, 10 opt-in skips, zero failures. New tests cover budget limits, compaction of
oversized collections (e.g. 150 photos with 80 favorites to 25), small collection passthrough,
temporal spread across visits, and partial evidence caption preparation.
Single batched release build completed via macos/build_app.sh (Swift release build 29.07s,
engine packaging, icon synthesis); deep and strict code signature verification passed
(dist/Photo Curator.app).

## Discovery Reconciliation and Workspace Merge (2026-09-11)

Added selection-mode card controls and pure toggle/range selection model. Shift-click
unions visible range from anchor; missing anchor safely becomes toggle. Explicit merge
sheet captures review revision, shows original names/descriptions, requires result name.
New GroupReviewStore.merge locks, rejects stale revisions/overlapping input, saves fresh
review ID and source-text provenance atomically. Selected saved groups retain unavailable
members. Existing explicit photo decisions and source defaults are never rewritten.
Subsequent diagnostic saves retain provenance. User edits apply before automatic grouping.

Continuity v2 now covers short non-overlapping gaps and runs on adjacent automatic
sections within a parent as well as existing base visits. Projection and preparation
share the persisted continuity store. Required evidence remains two distinct visual
matches plus consistent recorded GPS; conflicts, utility bridges, compressed dates,
protected/reviewed groups, overlap and chained merges remain blocked. Versions invalidate
old continuity records, not source analysis. No new Photos writes or network operations.

Full suite passed: 160 tests, 10 opt-in skips, zero failures. Targeted MomentMergeTests
rerun passed (3 tests, 0.009s). Single batched release build completed successfully via
macos/build_app.sh (Swift release build 30.59s, engine packaging, icon synthesis); deep and
strict code signature verification passed (dist/Photo Curator.app). Bundles continuity v2,
permission-safe projection, feed promotion triage, and workspace range-selection/merge.
Visual acceptance and live catalog quality comparisons remain pending user validation.
No real Moments merged for test purposes.

## Permission-Safe Projection and Feed Promotion (2026-09-11)

refreshOverview now restores saved Moments then returns before classification,
selection recomputation or catalog writes unless full Photos authorization exists.
This prevents the known permission-prompt fallback category projection. Real TCC
revoke/regrant acceptance is still pending; avoid interrupting the enabled pilot.

Added pure isSupportingCollection feed policy and More Collections disclosure.
Unendorsed singletons, absent selections and empty effective selections stay accessible
outside the main grid. Favorites, explicit Include, named/described and reviewed groups
remain prominent. Two-photo sets are not blanket-suppressed. No regrouping, deletion,
evidence/selection mutation or changes to user decisions. This is presentation triage,
NOT improved event understanding or a fix for oversized shortlists. Broader semantic
grouping remains open and must use multi-case evidence before changing boundaries.

155 Swift tests executed, 10 opt-in skipped, zero failures; new regression covers
singleton triage, Include/title/Favorite protection, pairs, exclusions and membership.
Release build passed (30.80s). No redeployment or indexing scope changes in this chunk.

## Post-Consent Catalog Audit (2026-09-11)

User approved Photos. Telemetry at 12:29:23/27 UTC restored 446 automatic selections;
12:29:55 waiting reason 5 confirms the permission gate cleared and idle gating remains.
No new deployment or library changes. Only PhotoRelay native executable running;
temporary Google pipe helper has exited. August-only pilot remains enabled.

Read-only jq audit of app-owned catalog: 1,132 memberships and unique assets, 47 Moments,
446 automatic selections, zero pending, 58 context-only. 27 candidates contain <=2
photos (16 singletons), 25 suggested titles are date-only, one candidate selects zero.
Largest two collections retain 99/149 and 137/587. These are quality-review flags, not
verified bad groupings or a reason to force fixed-size output. No new pixels inspected.
Actual display choices can differ because explicit user overrides apply separately.

Likely transient selection-count cause found in source: worker.overview calls
PhotoKitSimilarityCategories.classify; without authorization it returns [], then
overview falls back to database photos, recalculates selection, and saves catalog.
After consent the public smart-album categories become available (20 selfies,
21 portraits, 3 Live Photos, 1 panorama, 1 screenshot, 1,086 other photos) and count
returns to the previous 446. A controlled regression test is still required to prove
the exact nine-photo difference. Next build should preserve saved projection while
authorization is unavailable. Do not interrupt this pilot with another ad-hoc rebuild.

## Live Pilot Acceptance and Final Relaunch (2026-09-11)

August-only pilot completed a first pass: 1,132 indexed/analyzed, zero deferred,
47 Moments, zero pending, 16 singletons. Catalog membership covers 1,132 unique
assets without duplicate memberships; all 47 have suggested text. Initial telemetry
reported 446 automatic selections. Counts are processing evidence, not a quality pass:
generic titles and fragmented candidates still need content review. The user's custom
August 30 title remained visible after restart.

Final Dashboard visible-name cleanup built successfully (release, 28.97s), copied to
dist/Photo Curator.app, ad-hoc signed and strict/deep signature verification passed.
Relaunched at 12:22:49 UTC: enabled=1, boundedPilot=1; catalog restored with 47 Moments,
1,132 indexed, zero pending, and 437 selections. The changed selection count must not
be represented as a verified quality improvement. Waiting reason=1 indicates renewed
Photos permission is required after signing; user notified. Do not claim unattended
processing resumed until that is granted. Native UI automation transport failed, so
final window-title and automatic album-loading UI verification remain outstanding.

No port 8080 listener returned by lsof (unrelated unreachable SMB mount warning).
Before final relaunch only the native app was running; startup credential validation
can temporarily start the pipe engine. No Photos mutations or Google uploads performed.
Telemetry remains in ~/Library/Logs/Photo Relay/curator.jsonl for compatibility.

## Native Pilot, Telemetry and Rebranding (2026-09-11)

Replaced BackendController HTTP/MFA polling with private request/reply subprocess pipes.
Existing endpoint handlers remain shared, but native_ipc restricts paths to Google access,
album list, sync prepare/start/abort and control/auth state. No socket is opened; Flask
dispatches requests in-process. Native packaging omits web templates/static assets.
Backend starts lazily through data(for:), ends when isWorking becomes false; sync review
retains engine/token state. Startup Photos permission check no longer waits for persistent
server readiness. Removed iCloud password/MFA and engine-control menus. No Google API
scope/token changes. Legacy CLI web mode remains separate and tested.

Added counts-only rotated private telemetry and persisted bounded pilot scope; metadata,
analysis and context processing clamp to pilot dates even when foreground range differs.
Main view displays the pilot dates and logging state. Existing catalog snapshots retain
selection/evidence for later quality review. Name Photo Curator, new sparkle icon, Moments
default tab; kept bundle ID/support paths/executable unchanged for compatibility.

154 Swift tests passed (10 opt-in skipped); 20 Python tests passed, including no-listener
native request handling, route rejection and secret-safe errors. Actual packaged engine
probe returns 200 and exits. First bundle build interrupted by a final UI source edit;
rerunning build before deployment. No live pilot claim until verified after launch.

## Scenery Pass Validation Outcome (2026-09-11)

Full suite: 152 tests, 10 opt-in skips, zero failures; release build passed in 29.70s.
The real large-only rerun passed
with unchanged 25 selections and 26 context-only; the separate C03/C05 role audits also
remain passing. Do not claim that ScenerySelection fixes the visually observed repetitions.
Recorded GPS for pairs 13/14 differs ~1970m, pair16/21 has one missing location, pair22/23
differs ~194m. All fail the conservative 150m guard regardless of visual resemblance.
Further location-uncertainty policy needs separate testing, not ad-hoc threshold tuning.
No holdout rerun, production deployment, indexing restart or Photos modifications.

## Full Shortlist Review and Scenery Alternatives (2026-09-11)

Regenerated large-only evaluation with exact selections persisted, rendered and inspected
all 25 chosen palace photos. Found possible visual repetition at shortlist pairs 13/14
(gallery, 36 seconds apart), 16/21 (corridor, 3616 seconds), 22/23 (lake-facing palace,
314 seconds). Coverage otherwise includes interiors, objects, grounds, visitors and meal.
These are provisional visual judgments, not exact-duplicate or verified-event labels.
New renderer verifies hashes and writes private fresh directories; holdout not rendered.

Added ScenerySelection after balanced selection, scoped to one Moment's shortlist.
Requires shared scenery vocabulary, recorded GPS within 150m, available zero face count,
no people labels, valid nonutility aesthetics and feature distance at existing scene
cutoff 16. Only compares retained anchors (no chaining), at most 2048 distance calls.
Lower-ranked scenery moves to alternatives, never similar/deleted; unknowns, Favorites,
people and missing GPS retained. Explicit Include still applies afterwards. No new UI,
threshold, library membership change or holdout tuning. Real-copy regressions follow.

Deployment precheck: no valid installed code-signing identity; dist bundle exists,
/Applications bundle absent; curatorEnabled is 0. No deployment/relaunch performed.

## Reviewed Selection Quality (2026-09-11)

Inspected the already-approved C03 two-page and C05 contact sheets. Wrote private
quality-reference.json (0600), with provisional visual-role indices, not person names
or verified event labels. New opt-in PHOTO_RELAY_QUALITY_REPORT test performs hash-checked
local Vision/OCR and production selection on those 36 samples; held-out samples rejected.
No network, live library/index, production changes, or new conversation-AI sample scope.

Full suite: 149 tests, 10 opt-in skips, zero failures; new opt-in audit separately passed.
Actual audit passed in 6.504 seconds. C03 selected indices 2,5,7,9,13,14,16,17,18,19,20;
C05 selected 4,9,13,16. All provisional roles covered; no annotated utility photos selected.
Private selection-quality.json records results. Tests report subjective deficits rather
than treating unapproved annotations as hard truth. See evaluation/QUALITY_CRITERIA.md
for separate content/structural acceptance and known gaps. No justification found for
changing thresholds or blanket singleton suppression. Full-visit shortlist and deployed
UI/Favorites acceptance remain; no live restart or redeployment.

## Full Export Structural Validation (2026-09-11)

Added explicit PHOTO_RELAY_VALIDATION_REPORT opt-in test. All 624 C03 and 684 held-out
February JPEG copies are hash-verified and analyzed locally at 1024px, using fresh temp
stores, existing OCR/Vision and deterministic caption fallback. No PhotoKit, network,
folder-name inputs, cloud LLM, source changes or conversation-AI image inspection.
Private large-validation.json and holdout-validation.json contain reproducible metrics
and catalog membership. Temporary stores are removed when each scope exits.

Full regression suite: 148 tests, 9 opt-in skips, zero failures. The newly added opt-in
test was also run separately and passed, not merely skipped.
Actual result: passed in 153.296 seconds. Large visit 1 -> 1 group, 25 selected,
26 context-only, six preparation steps. Holdout 53 -> 53 groups, 111 selected,
36 context-only, 68 steps; 19 singletons, all 53 grouping states ready. Complete unique
membership, no preparing groups, restart IDs preserved. Ready means processing finished,
not event identity verified. Large visit remains conservative. Four Node audit tests pass.

No algorithms tuned after holdout results. February is now evaluated and must not be
described as untouched. Structural success does not validate semantic story quality;
selection still uses temporal/location buckets and Favorites/categories are absent in
this export. No redeploy or live indexing restart. Next requires explicit quality criteria
and representative output review, rather than declaring Apple Memories-quality from counts.

## Large-Moment Worker Integration (2026-09-11)

Connected internal windows to prepareGrouping and the shared catalog projection.
Round-robin work bounds evidence loading to one window per parent visit, with a bounded
sweep flag preventing early caught-up before all sections have been checked. Missing
evidence does not starve later windows. Internal records now optionally carry an actual
evidence hash; old records remain decodable. Metadata changes produce new window IDs;
changed Vision/labels/OCR refresh records on subsequent sweeps. Group-review revision,
metadata generation and cancellation guard commits. Named/reviewed parents and legacy
protected children retain precedence.

Projection returns the original parent, never internal IDs. It reports section progress
and stays conservative after completion rather than asserting verified event identity.
This does not reconcile cross-window scenes into an event hierarchy. Real-export and
holdout quality validation remain pending. No app deployment or live indexing resumed;
tests use synthetic metadata and temporary stores, without PhotoKit or network access.

Added two 624-photo integration tests for restart/coverage/evidence refresh and missing
first-window recovery; updated the old oversized-state expectation to preparing.
Production build passed (25.72 seconds). Full suite passed: 147 tests, 8 opt-in skips,
zero failures. git diff --check passed (native tree remains untracked).

## Saved Group Decisions Enter the Main Catalog (2026-09-09)

MomentCatalogGrouping now applies GroupReviewArchive to the full indexed scope before
paging. Explicit saved memberships/names become main Moment cards (same persisted IDs),
including cross-date merges. Automatic groups only receive unassigned photos. Untouched
legacy groups keep IDs; partial remainders get deterministic distinct IDs so old full-group
titles aren't silently reassigned. Old title records are retained, not deleted/migrated.
Missing/undated members remain in the saved archive, though undated photos are not yet
shown in dated cards. New photos remain separate from explicitly saved memberships.

Caption grouping consumes the same full-scope projection, prioritizes groups intersecting
the requested range without truncating membership, and invalidates its sweep when review
revision changes. Group save notification refreshes Moments automatically. Existing inline
title overrides take precedence over saved group names; derived captions have lowest priority.
Date bounds for PhotoKit category reads now encompass entire cross-date groups.

Tests added for cross-date groups/unique coverage, legacy identity preservation/remainder
isolation, missing members and new photos. This checkpoint connects existing manual review
to the pipeline; it does NOT introduce automatic semantic segmentation. That remains next,
and must not mistake visual-near-duplicate clusters for coherent travel events.
Google research stays paused; separate unbilled project decision still unresolved.

Validation: 89 Swift tests, 4 opt-in skipped, no failures. Release build and deep/strict
signature verification passed. App not restarted; live saved-group catalog UI acceptance
remains pending. No Photos library writes or research requests.


## Automatic Local Captions and Billing Verification (2026-09-09)

Enabled cloudbilling.googleapis.com through Service Usage on the existing project,
then GET billingInfo succeeded and returned billingEnabled=true. This was pre-existing
billing; no billing account/link/payment settings were modified. No Gemini request sent.
Free-only gate correctly blocks this project. Asked user whether to create a separate
unbilled project; do not detach billing from the existing project. Eligibility question
remains separate from quota and account billing. Existing Google Photos sync unchanged.

Added BackgroundMomentContext actor: caches revision/OS-keyed local Vision labels and
derived captions in private atomic files. OCR stage now also captures classification,
including backfill for previously analyzed photos. Every eighth eligible worker tick
attempts one caption, with a bounded sweep of 32 groups over the full indexed scope,
independent of the UI page. Priority scope is honored. No model work in UI refresh.
Samples up to eight photos across each time-based group; waits for sampled evidence,
filters generic people/sky labels, and uses existing local candidate-choice model.
This is grounded template selection, not unconstrained semantic storytelling.
Unavailable model gets deterministic fallback with a one-hour reattempt timestamp.
Caption fingerprints reject stale asset edits and OS changes. Card/review text prefers
user corrections, then derived captions; automatic work never writes correction store.

Added synthetic test: waits for evidence, generates fallback, reopens caption cache,
avoids repeat generation and rejects stale edit. Swift suite 86 tests, 4 skipped, no
failures before final packaging. No real-library caption quality acceptance yet.
Release rebuilt successfully; deep/strict codesign verification passed (ad-hoc).
Running app was not restarted. Remaining: coherent semantic grouping and durable group identities/corrections, OCR
clue interpretation, place verification, enrichment and meaningful optional questions.


## Collection Workspace and Free-only Boundary (2026-09-09)

Removed Research Settings button/dialog. Native app Settings now owns idle/login/privacy
preferences and Diagnostics. CuratorView is a cover-card catalog; old controls are
CuratorDiagnosticsView. Review keeps title/selection/zoom; standalone text/group tools
are available only in diagnostic review. Priority sheet explicitly does not filter the
catalog. Catalog derives from the entire indexed date span, paged 200 collections with
Show Older. PhotoKit category fetching bounded to that page's date span. Metadata grouping
still processes the indexed library; large-library performance requires profiling.

Added bounded atomic 0600 moments-catalog.json snapshots, loaded before recomputation.
These are derived visible-page snapshots, NOT a durable semantic Moment identity migration.
Existing user title/photo decision stores are separate and untouched. Anchor IDs remain;
ambiguous future split/merge migration is still outstanding. Cards say context is preparing
instead of inventing titles/locations. Balanced heuristic defaults on for new installations.

Analysis queue now orders by priority then actual capture time descending, not asset ID.
Automatic local OCR is integrated after Vision, before completing new analysis jobs.
When visual queue is caught up, a newest-first OCR backfill checks the existing per-asset
revision/engine cache. No iCloud download/network. Backfill cursor is session-local;
completed OCR files persist and are skipped after restart. Failed backfill photos are
skipped for this pass and revisited on a new metadata scan/relaunch; not a durable retry queue.
Local LLM, semantic grouping, place inference and question generation are NOT yet automatic.

Free-tier research: reusable OAuth confirmed using the saved app credentials. Read-only
Cloud Billing projects/.../billingInfo returned 403; billingEnabled is UNKNOWN. No model
request sent. Provider now checks billing before every research call and denies paid,
unknown or forbidden status; model allowlist limited to 2.5 Flash/Flash-Lite. Persistent
SQLite reservation cap of 50/day UTC survives restarts; no automatic paid fallback/retry.
Legacy cost_authorized argument remains as an explicit activation gate, NOT paid override.
App never activates it. EEA eligibility remains unresolved; no APIs/billing enabled.
Research privacy preference is stored but there is no automatic research caller yet.
Reference: https://ai.google.dev/gemini-api/docs/pricing and /gemini-api/terms.

Validation: 46 targeted Python tests passed. Swift snapshot persistence and newest-first
claim tests added; 85 tests, 4 opt-in skipped, no failures before final build.
Still needed: live layout/large-library profiling; end-to-end automatic semantic pipeline;
research result caching, attribution UI, provider quota cooldown, eligibility verification.
Do NOT report unified curation or web enrichment as complete.


## Permission-to-Content Continuation (2026-09-09)

Fixed missing transition from granted PhotoKit access to sidebar loading. Launch,
activation, recovery completion and idle-after-sync now trigger automatic loading
when needed. Banner consent completion notifies model; recovery completion refreshes
banner state. In-flight and attempted guards prevent duplicate loads and retry loops.
Failed/empty/loading states replace misleading generic permission prompt; retry stays
in the sidebar. Album refresh retains valid selected IDs and avoids overwriting sync
activity when completion arrives during other work. Revocation clears displayed albums
when idle; late callbacks check actual authorization before publishing results.

Added WORKFLOW_ACCEPTANCE.md as required development acceptance criteria, not an
optional cosmetic phase. Existing Swift suite: 83 tests, 4 skipped, no failures.
Lifecycle changes compiled; interactive grant/Settings return not yet UI-verified.


## Unified Startup Access Correction (2026-09-09)

User clarified that ALL Google permissions must be checked together every launch.
Added central GOOGLE_APP_SCOPES including album editing and openid, previously missing
from startup check. /google-access uses that union regardless of legacy research flag.
View model checks actual PhotoKit authorization and combined Google access once per
launch, deferred during sync. One recovery alert offers Continue/Not Now. Continue
requests notDetermined Photos access or opens Privacy Settings for denied/limited,
then requests combined Google consent only if missing. Restricted Photos needs system
policy changes; the existing banner explains that. No permission resets or billing.
Research Settings checks the same union rather than a separate feature permission.

OAuth refresh invalid_grant is distinguished from outages/invalid_client; transient
failures never open consent even when interactive was requested. Tokens are retained.
Validation: 41 targeted Python tests passed; 83 Swift tests, 4 opt-in skipped, no failures.
Interactive startup recovery still requires UI acceptance. Ad-hoc signing caveat remains.


## Google Text Research Boundary and Access UI (2026-09-09)

google_enrichment.py uses the documented Gemini interactions Google Search shape,
OAuth cloud-platform via SimplifiedGoogleAuth, project header, no images/files/tools
other than search, store=false. Explicit PublicClue approval plus conservative string
checks are defense in depth, NOT proof of privacy. Caller must vet public landmarks;
raw OCR/metadata must never be passed automatically. Cost authorization defaults false
and blocks before credential refresh. Live provider compatibility remains unverified.
Responses capped at 1 MiB; cited text offsets and search-suggestion metadata retained.
No source navigation/HTML execution, automatic retry or factual photo-location assertion.

Incremental OAuth preserves existing scopes in requests; partial grants return failure.
Added serialized /google-access POST through existing CSRF and cloud-operation lock.
Noninteractive refresh failure reports unavailable rather than revocation when a token
and requested scopes exist. Dashboard startup checks Google after restoring active sync;
busy startup checks skip rather than interfere with upload. Research Settings offers
explicit additional consent, shows paused status, and does not enable requests/costs.
No research endpoint, automatic scheduling, persistent cache or attribution rendering yet.

Validation: 37 targeted Python tests passed, including 12 provider/OAuth tests; Swift
83 tests, 4 opt-in skipped, zero failures. No real Google research, Photos writes,
billing configuration or private clues sent. Packaged release rebuilt successfully with
macos/build_app.sh; deep/strict codesign verification passed (ad-hoc fallback).
Running app was not restarted. Consent flow and native Settings UI still need live
acceptance; no claim of end-to-end enrichment completion.
References: https://ai.google.dev/gemini-api/docs/google-search and
https://ai.google.dev/gemini-api/docs/oauth (reviewed September 9).


## Startup Photos Access and Signing (2026-09-09)

Added LibraryAccessBanner to DashboardView. It uses PhotoKit authorization status,
shows no banner with full access, offers request for notDetermined, Settings for
limited/denied, and explains restricted access. Rechecks when app becomes active.
No TCC resets, library writes, or permission request during tests. Existing scanning
and permission flows are otherwise unchanged; banner is not a scheduler gate.

build_app.sh accepts PHOTO_RELAY_SIGNING_IDENTITY, warns about ad-hoc persistence,
and verifies signature. security find-identity found zero valid code-signing identities.
Swift tests: 83 executed, 4 opt-in skipped, zero failures. New banner compiled;
interactive permission states not tested. No packaged rebuild/relaunch yet.

Google enrichment/provider and noninteractive startup Google check remain pending.
Official Gemini OAuth and Google Search grounding docs reviewed; need agreement on
cloud text processing/project costs before activating this path. No scopes changed,
no credentials exposed, and no real photo/text enrichment requests sent.


## Persistent Group Review and Scene Clues (2026-09-09)

Suggest Groups now allows selecting group checkboxes to merge, selecting photos to
split into a new group, editing group names, and explicit Save Groups. Draft changes
are not written until save; closing dirty review asks to discard, and interactive
dismissal is blocked. Threshold controls are disabled while dirty. In-flight automatic
proposals do not replace edited drafts. Saved grouping applies in this review UI;
it does not yet replace the top-level time-based Moments list or feed publication.

GroupReviewStore persists a versioned global asset-membership archive in Application
Support/Photo Relay/curator/group-review.json. Stable UUIDs, titles and explicit
memberships override future automatic regrouping. New/unreviewed assets stay in
automatic residual groups instead of joining a saved group silently. Save updates
only visible memberships, preserving out-of-range members. Names belong to a whole
saved group (including hidden members); UI exposes hidden-member count. Merging
visible fragments does not move unseen members from other groups. Atomic bounded
16 MiB writes, 0600 files, sidecar flock, archive revision compare-and-save prevent
stale overwrites. Invalid/corrupt archives fail closed. No power-loss fsync guarantee
or cross-library migration/garbage collection yet. Saved user merges do not infer GPS.

SemanticSceneEvidence uses on-device VNClassifyImageRequest revision 2, off UI actor.
Only specific allowlisted clues >=0.7 (e.g. castle, beach, forest) support a bounded
distance allowance, growing monotonically with the base cutoff up to +2 units.
Generic people/adult/outdoor/clothing labels cannot earn that allowance. Conflicting
confident indoor/outdoor evidence prevents automatic joining; missing labels remain
neutral. Clues are hints, not recognized venues. Location inference still requires
the stricter raw-distance cap and direct GPS sources. Classification is session-only
and currently requires local previews even for cached feature prints. Background
semantic caching, venue reasoning and broader calibration remain future work.

Validation: final rebuild and signature verification passed; 83 tests / 4 opt-in
skipped / zero failures after final UI copy cleanup.
Separate 29-export grouping test passed: 20 groups vs previous 21, same-Kurhaus and
same-Amsterdam positives retained, Madurodam/Amsterdam and Peace Palace/De Haar
negative checks retained, compressed-time inference disabled. Real-copy test does
not cover live PhotoKit categories. Manual UI acceptance after relaunch is pending.
No Photos mutations, internet lookups, external image uploads, or changes to working
export/Google sync flow. Next: accept saved split/merge UX, then integrate reviewed
groups into the top-level workspace without losing existing titles/selection state.

## Grouping Preview and Real-Photo Calibration (2026-09-09)

Added EvidenceGrouping and GroupingSuggestionsView. Entry: Moments -> Review Photos
-> Suggest Groups. Resizable, zoomable, session-only preview. It does NOT replace
existing moments, persist grouping edits, create albums, or change sync selections.
Uses existing version/revision-matched visual cache; missing feature prints are
computed locally at 1024 pixels (Vision print revision 1, scaleFit). Reuses OCR cache
or reads local 2048 previews. No network-enabled thumbnail requests or research.

Grouping uses a fixed first-photo anchor, 30-minute maximum anchor separation,
matching media category, visual distance and no recorded GPS conflict over 1 km.
Search is bounded to the last 32 groups. Exact high-confidence shared OCR is shown
as supporting evidence ONLY; unrelated/absent OCR does not prove different venues.
Whole-image distance remains an imperfect scenery proxy, not a venue classifier.
Missing visual evidence is kept separate. Date-order ties use asset IDs.

GPS provenance is represented by source photo ID, never copied coordinates. Each
inferred member must match an actual GPS source directly; other recorded GPS anchors
must agree. Preview slider cannot loosen inference beyond the default distance limit.
Coordinate ranges are checked; GPS accuracy is not currently indexed, so UI says
"possible shared location" and allows source inspection, not a verified geotag.
Eight or more timestamps compressed into <= 3 seconds/photo disable inference for
the set, independently of slider position. This can flag genuine bursts; it is a
conservative warning, not proof of imported timestamps. Nothing writes to Photos.

Initial cutoff 10 left all 29 exported afternoon photos separate. Measured 12, 14,
16, 18, 20 and 22 rather than assuming a similarity percentage. At 16 the set has
21 visual groups; same-Kurhaus and same-Amsterdam-boat pairs merge, while tested
Madurodam/Amsterdam and Peace Palace/De Haar pairs remain separate. At 18 and above,
cross-landmark mistakes appear. Set the experimental default to 16 with Reset and
a looser-value warning. This is NOT complete event/visit curation: substantial
viewpoint changes (and many real same-event photos) remain separate. No claim of
broad calibration beyond this small dataset.

Session distance cache is capped at 8192 successful pairs. New feature generation
clears it. Actor isolation keeps analysis and comparisons off the UI actor. Requests
are cancellable; closing abandons the preview while completed OCR stays cached.

Validation: 79 tests, 4 opt-in skipped, zero failures. Separate opt-in exported-set
test passed in 0.66 seconds, covering all 29 afternoon JPEGs and positive/negative
pair assertions plus timestamp warning, membership preservation, and no inference.
The exported test does not recreate PhotoKit media-category classification, so live
group counts may differ. No automated end-to-end UI acceptance yet. OCR UI was
confirmed working by the user before this chunk.

Remaining: richer scene/venue evidence, persisted user split/merge decisions, GPS
accuracy indexing, spatial anchor calibration, and broader validation before enabling
automatic grouping in the background or publication. Preview is not that completion.

## Local OCR Evidence UI (2026-09-09)

Implemented MomentTextEvidenceStore and MomentTextEvidenceView. Entry: Moments ->
Review Photos -> Suggest Text -> Inspect Text in Photos. Reads every photo in the
moment sequentially, local-only PhotoKit preview at up to 2048 pixels, five-second
per-photo timeout, cancellable between requests. Vision accurate OCR revision 3.
Shows source-thumbnail zoom, raw text and OCR confidence; users choose/correct a
clue before passing it into caption candidates. No automatic place-name assertion.
Raw OCR is never treated as model instructions; the existing model selects an index
from bounded candidate text. Manual draft remains separate from suggestions.

Cache: Application Support/Photo Relay/curator/text-evidence, hashed asset filenames,
atomic per-photo JSON, 0600 files/0700 directory, 128 KiB read/write bound, 100 lines,
500 characters per recognized line. Asset ID, IndexedPhoto.analysisRevision and
engine/OS version must match. Empty successful OCR cached; failed loads not cached.
Revision invalidation uses the current indexed metadata snapshot (not a new live
PhotoKit change observer); reindex after edits is still required to observe revisions.
No cache eviction policy yet. User corrections are session clues; only saved title/
description persists. Background queue integration and semantic grouping remain next.

Validation: swift test, 69 tests with 3 opt-in skipped and zero failures. Separate
PHOTO_RELAY_OCR_TEST_FOLDER run analyzed all 30 previously exported August 30 photos
and asserted the Madurodam sign recognition (3.46 seconds). No Photos modifications,
downloads or uploads during this acceptance test. UI layout/interactions still need
acceptance after app relaunch. This is not a claim of end-to-end GUI verification.

## August 30 Full-Set Evidence Audit (2026-09-09)

Completed Photos UI export and local Vision OCR/faces/classification on 30 unique
images (39 exported entries included nine byte-identical Top Results duplicates).
See `CURATOR_AUGUST30_CASE_STUDY.md` for evidence, semantic groups and next steps.
Private copies/EXIF/OCR/contact sheets live outside this repository in Pictures/Photo
Relay Analysis/2026-08-30. Added reproducible exported-copy-only analysis script.
No app deployment, Photos album edits or Google image uploads. Only one GPS-bearing
image; 29 compressed timestamps combine multiple outings/gatherings. OCR recognized
Madurodam. Two zero-face detections were false negatives on visual inspection: none
of this set should be automatically uploaded for image research. Production gate
must not equate zero detections with privacy clearance. This milestone is research,
not implementation of semantic clustering or OCR enrichment in the app.

## Real-Photo Narrative Check and Visual Context (2026-09-08)

User authorized read-only real-photo testing. Observed current Aug 30 review via CUA,
then UI transport failed repeatedly (native pipe closed); full UI reproduction blocked.
App-owned index read-only aggregate verified 30 photos/16 Favorites for Aug 30 (review
snapshot had 29). Narrative cache exists with saved model indices: some requests completed,
but no conclusion that UI displayed them. Root functional gap: model input was dates/counts
only and could never produce content-aware text. No confirmed diagnosis of an empty sheet.

Added bounded local Vision classification (revision 2, confidence >=0.5, top4 labels/image)
over up to8 local PhotoKit thumbnails with 5s timeout each; no network requests. Sample
spread over stable asset-ID order, not representative semantic sampling. Rank labels by
sample frequency, supply max8 to caption candidate builder. Candidate text explicitly
marks possible subjects/uncertainty; free-form hallucinated names/events still prohibited.
Cache prompt version bumped to avoid old date-only results. Progress and inspected/label
summary shown in suggestion sheet. Empty labels fall back to date/count templates.

Actual exported JPEG in user's Photo Relay export folder read via ImageIO, bounded1024
thumbnail -> Vision -> real Apple text model: 4 labels, valid candidate0, test passed11.578s.
No original Photos DB access, image modification, upload, or saved title edits. This tests
real pixels/backend, not the failing UI transport or full live PhotoKit request in the sheet.
Verification: regular suite 65 tests, 63 passed/2 opt-in skipped; real-photo test passed
separately. Release rebuilt and strict deep signature verified; app not restarted.

## Local Narrative Review UI (2026-09-08)

Review Photos -> Suggest Text opens draft editor plus separate model suggestion. Uses
date/counts/Favorites only, no photos or unverified place guesses. User must choose Use
Suggestion in Draft then Save Text; existing title/description never replaced on generation.
Cancel leaves saved metadata alone and cancels view task. Manual editing remains possible
during generation and on failure. Fallback/source status shown. Descriptions persist in
app preferences beside titles and appear in review; no Photos writes. Cache in app-support
curator/narrative-cache.json. Scope is whole moment, not current filtered/selected subset.
Stable identity backend remains disconnected pending full-scope migration. Existing title
anchor limitations still apply. This deployment connects narrative UI only, not publisher.
Verification: 63 tests executed, 62 passed, 1 opt-in smoke skipped; release rebuilt and
strict deep signature verified. Real-model synthetic smoke passed in preceding checkpoint.
App not restarted automatically. User acceptance: request, inspect, use draft, save/reopen;
also verify Cancel preserves an existing title and description.

## Grounded Local Narrative Adapter (2026-09-08)

Apple FoundationModels adapter uses runtime availability checks on macOS 26+, a fresh
LanguageModelSession without tools, bounded 64-token response and temperature 0. Older OS
or unavailable/refused/invalid responses use deterministic metadata text. Model selects
an index from grounded title/description candidates; arbitrary generated prose is never
displayed. This intentionally constrains style/creativity to avoid invented places/events.
Inputs: date label, counts, optionally verified/user-provided place, with size validation.
No photos, face names, precise coordinates or network tools. Upstream must establish place
provenance; this adapter does not geocode or verify input truth. Manual titles never modified.

Cache stores candidate indices, keyed by SHA256 of sorted metadata + prompt/model/OS adapter
version, with 128-entry reset bound and 64 KiB read cap. Lock protects concurrent writers;
transient model fallbacks not cached. Inference serial per engine; cancellation propagates.
Not yet wired to review UI/background worker. No inference timeout or exact Apple model-build
identifier available here; same-OS model updates may need explicit cache version bump.
Sources: https://developer.apple.com/documentation/foundationmodels/languagemodelsession
https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel
Local SDK interface verified before implementation. Synthetic fake-model tests cover cache
restart/version/input invalidation, availability, malformed response, missing place and errors.
Verification: 61 deterministic tests passed before opt-in smoke addition. All four narrative
tests then passed with PHOTO_RELAY_TEST_LOCAL_MODEL=1, including actual Apple on-device
inference over synthetic metadata (10.917s). No user library accessed. Installed app unchanged.

## Identity Resolver and Journal Hardening (2026-09-08)

MomentIdentityResolver preserves identity only for reciprocal one-to-one overlapping groups
with >=50% membership shared in each direction. Splits/merges allocate new IDs and retain
old records as retired, avoiding silent title reassignment. Per-asset review choices already
survive independently. Scope-keyed archive persists atomically, rejects different scopes,
and has a 16 MiB ceiling. Resolver rejects overlapping input groups; tests cover anchor
removal, split/merge, persistence and scope mismatch. Retired titles are NOT migrated.
Integration intentionally deferred: complete-scope snapshots and legacy anchor-title
migration need a separate implementation; current UI still uses existing candidate IDs.

Publication journals now take nonblocking exclusive flock on stable sidecar files across
the entire async external operation, then reload state under lock. Atomic replacement
cannot invalidate the lock inode. Tests cover contention, release, stale-instance reuse,
and cancellation before effects. Journal payload ceiling 8 MiB; state updated after atomic
write even if chmod later fails, avoiding stale-memory retries. Lock files stay in place.
All tests use synthetic data/temp files; installed app not rebuilt or restarted.
Remaining reliability work: power-loss fsync, aggregate storage/pruning policy, real-adapter
timeouts and long-run soak tests. These are focused backend subchunks, not completion of
all identity migration or all reliability work. No Photos or Google access.
Verification: all 58 native tests passed (6 new tests); diff whitespace check passed.

## Offline Publisher and Sync Handoff Foundations (2026-09-08)

Two backend-only subchunks implemented in CuratedPublication.swift. Immutable validated
operation request, versioned atomic-file journal, prepared/publishing/published/uploading/
complete phases, receipt validation, actor reentrancy guard, cancellation before effects.
Persist confirmed effects even if cancellation arrives during an adapter call. After an
ambiguous failure, only recover a receipt; nil recovery blocks, never blindly recreates or
reuploads. Album receipt survives upload failure. Corrupt/future journal fails closed.
Tests use only fake album/upload adapters and temporary journals. No real adapter exists,
no UI is wired, no actual Photos mutation or network call is possible through this feature.

NOT full chunks 8/9: folder/year placement, rename/move/delete reconciliation, stable moment
identity, real PhotoKit operation recovery, Google ledger integration, progress/Abort UI,
and explicit real-write acceptance remain outstanding. Generic operation IDs do not imply
Google API idempotency. One owner per journal required; cross-process locks and power-loss
fsync durability are not implemented. Atomic replacement targets process interruption only.
No app rebuild needed for these disconnected foundations; existing installed app unchanged.
Verification: all 52 native tests passed (7 new fake-adapter workflow tests), and diff
whitespace check passed. No user acceptance test is required for this isolated checkpoint.

## GPS Coverage in Balanced Selection (2026-09-08)

Split each time/type bucket into deterministic GPS-anchor neighborhoods (1 km), with a
separate missing/invalid-GPS subgroup. Pick representatives independently; nearby chain
members cannot bridge anchors into a single distant group. Similarity suppression also
refuses known pairs over 1 km apart so earlier reduction does not erase distinct stops.
Coordinates stay local; no geocoding, placenames, new permissions or private Photos access.
Heuristic limits: GPS accuracy is not stored, anchor order is stable asset-ID order rather
than semantic places; unknown locations still use time/type fallback. Real-trip calibration
remains necessary. Manual choices and Favorites preserved; publication remains last.
Verification: 45 native tests passed; release rebuilt and strict deep signature verified.
Real-trip quality acceptance pending; no running-app restart performed.

## Experimental Balanced Shortlist (2026-09-08)

Opt-in, persisted toggle adds temporal coverage after conservative similarity suppression.
For each epoch-aligned 30-minute/type bucket, retain all Favorites; otherwise retain the
highest adjusted aesthetics score. Missing scores and dates are retained conservatively.
Remaining photos are alternatives, NOT similar/duplicates, and carry explicit explanations.
Manual Include/Exclude remains authoritative; disabling restores similarity-only selection.
No Photos writes, downloads or sync. This is not semantic story diversity or a calibrated
best-photo model: boundaries are heuristic, categories are not scene labels, and screenshot
curation policy is unchanged. Human acceptance on trips needed before changing defaults.
Verification: 44 native tests passed; release rebuilt, strict deep signature and diff checks
passed. Real-trip usefulness not yet evaluated; running app was not restarted.

## Review Titles and Explanations (2026-09-08)

Review now saves optional 200-character local moment titles and provides Reset Title.
Titles appear in moment list; no Photos rename or publishing. Per-photo expandable reasons
explain Favorite protection, missing analysis, retained-without-match, or a suppressed shot's
representative capture time, distance and cutoff. Aesthetics score is disclosed for retained
photos when available; manual overrides explicitly take precedence. Reasons use actual
selector decisions, not generated narratives or claimed best-photo quality.
Titles use current candidate moment IDs: regrouping that changes the anchor can orphan a
title; never migrate it to another group by guess. Stable published identities remain future
work. Review snapshots still require reopening for fresh automatic analysis. Production
calibration sampling breadth remains deferred as requested. Photos writes remain LAST.
Verification: 43 native tests passed; release rebuilt and strict deep signature verified.
Live title/explanation acceptance remains pending; running app was not restarted.

## Review Layout Repair (2026-09-07)

Fit collapse came from intrinsic-width negotiation through Button/GeometryReader and a nil
aspect ratio. Thumbnail now has an explicit full-width background and image overlay, so
Fit and Square share stable bounds. Grid cells use fixed adaptive widths; crop remains square.
Toolbar split into two rows with hidden segmented label and fixed control widths to avoid
vertical text wrapping. Review sheet uses flexible min/ideal sizing and public AppKit
resizable style with 600x520 content minimum. Native resize interaction still needs acceptance.
Synthetic pixel rendering regression covers Fit letterboxing and Crop at two widths.
Verification: 42 native tests passed; release rebuilt and strict deep signature verified.
No running-app restart or real-library UI interaction performed during this checkpoint.

## Review Grid Usability (2026-09-07)

Review toolbar adds supported PhotoKit type filter, Favorites-only, Fit/Square preview,
and +/- with continuous thumbnail sizing. Filters never alter saved decisions. Clicking
a thumbnail opens local-only enlargement with Fit and 100-400% zoom/scrolling. Viewer asks
PhotoKit for up to 4096px; analysis and normal grid remain 1024px. Loader clamps requests
to 4096 and bounds decoded output without upscaling. No iCloud fetch or Photos mutation.
Videos, Edited, Not in an Album are not exposed as pretend filters: indexed curator is
image-only, and those extra metadata filters remain future work. Manual UI acceptance pending.
Verification: 41 native tests passed, including large-preview request clamping and no
upscaling. Release rebuilt; strict deep signature verification and diff checks passed.

## Durable Thumbnail Review (2026-09-07)

Moment rows open a lazy local-thumbnail grid. Automatic/Include/Exclude decisions persist
by PhotoKit asset ID in app preferences; explicit user exclusion can override Favorite
protection (automatic selection still protects Favorites). Changes save immediately, Done
closes rather than commits. Automatic removes the override. Candidate metadata/automatic
recommendations remain intact; moment counts reflect effective selection and manual exclusions.
No Photos writes or Google sync integration; publication remains last. Review uses a snapshot
of automatic suggestions on opening; reopen to see new background analysis. Next: full-size
single-photo review and selection handoff, plus improved selection/story diversity. Calibration
sample breadth is a documented production follow-up, not expanded in this checkpoint.
Verification: 40 native tests passed; release app rebuilt and strict deep signature verified.
Live thumbnail/restart acceptance remains pending. Running app was not restarted.

## Public Media Categories and Pair Inspection (2026-09-07)

Public PhotoKit smart-album membership and screenshot media flag classify cached assets
read-only at overview/preview time, without reanalysis or private database access. Separate
cutoffs by analyzer version AND category; old mixed-type cutoff is intentionally not copied.
Overlap priority: screenshots, selfies, portrait, panoramas, animated, bursts, RAW, Live,
other photos. Cross-category suppression is prohibited. Screenshots excluded from default
Other Photos examples, but available explicitly under Screenshots. Current library metadata
also removes hidden/missing assets from displayed candidate sets.
Pair columns now have Previous/Next and Enlarge; enlarged pair supports 100-300% zoom and
scrolling with local 1024px previews, not downloaded originals. Slider resets to boundary
examples. Category changes cancel stale sample results. Apply commits all draft categories;
Cancel discards them. Documents/Receipts/Handwriting have no public subtype in installed SDK,
explicitly disclosed in UI; Other Photos can still contain them. No heuristic substitution.
Future SDK checkpoint: inspect newly documented public APIs after Xcode/SDK update, compile
with availability guards, and run read-only acceptance. Do not assume an OS release alone
exposes new APIs. No private symbols, database reads, or schema-dependent fallbacks.
Verification: 38 native tests passed, release build completed. Live category membership,
pair navigation and zoom acceptance on the user's library remain pending. App not restarted.


## Similarity Calibration Dialog (2026-09-07)

Local thumbnail pairs on either side of draft cutoff change as slider moves. Apply persists
per-analyzer-version cutoff and recomputes suggestions; Cancel has no effect. Bounded 512
adjacent-pair sample uses cached analysis. Explicit sample, Favorite and pair-versus-final
selection disclosures. Fixed comparison order to nearest 32 temporal neighbors instead
of last 32 ranked. See CURATOR_SIMILARITY_RESEARCH.md for sources and calibration limits.
No full thumbnail review/manual overrides yet; no library writes or network photo access.
Verification: 36 native tests passed; release bundle rebuilt successfully. Live dialog
acceptance with the user's library remains pending; no running-app restart was performed.

## First Conservative Selection Pass (2026-09-07)

MomentSelector consumes cached current-version analysis, preserves every Favorite and
marks missing results pending. Scores order candidates; utility subtracts 0.2. Only
non-Favorites within 60 seconds and feature distance <=0.01 are marked similar, never
deleted. Compare against at most 32 retained candidates to bound pairwise work.
Moments show suggested/similar/pending counts; analysis refreshes overview periodically.
This is an initial near-duplicate reduction heuristic, NOT calibrated story/diversity
curation, a capped best-photo set, or a review UI. All original members remain available.
Tests cover Favorite protection, pending results and unknown similarity. Full sample
quality evaluation and richer grouping remain pending. Album writes remain disabled.
Verification: all 33 native tests passed; release app rebuilt successfully; deep strict
code-signature verification and git diff --check passed. Running app was not restarted.
Next checkpoint: thumbnail review with durable manual include/exclude decisions, followed
by real-library selection calibration. No Photos albums or assets were changed.

## Queue-to-Vision Runner Integrated (2026-09-07)

Metadata batches enqueue versioned jobs; IndexedPhoto revision uses modification time
and dimensions. After metadata traversal, controller processes one job per gated timer
tick via the reusable local-only thumbnail loader and Vision actor. Foreground range
stays active through visual analysis and claims only assets in that interval; background
reconciliation resumes afterward. Completed identical jobs survive metadata rescans.
Failed/unavailable thumbnails and failed Vision signals defer for one hour. Cancellation
releases the matching lease. User edits/library notifications invalidate in-flight work;
asset fingerprint/hidden state is checked again before result persistence. Completed full
reconciliation prunes orphan queue entries. No Photos writes or external network requests.
UI disclosure updated from metadata-only to local visual analysis, with session counts.
31 native tests passed, including new range isolation and deferred-job tests. Existing
sample acceptance validated the components, not the new long-running scheduler.
Limitations: metadata traversal restarts after launch (results persist); one image per 2s
tick, metadata-first indexing; session counters are not lifetime completion counts.
Idle/thermal gates apply between photos; sync and Stop cancel pending task, but synchronous
Vision request finishes before cancellation is observed. Deferred items may remain when
range is called caught up. Global scan performance and integrated cancellation need real
acceptance. Candidate groups still metadata-based: no best-photo selection/review yet.
Next: user runs a small date range in rebuilt app, then meaningful selection/review.

## PhotoKit Real-Library Acceptance Passed (User Report, 2026-09-07)

User ran the in-app diagnostic: 12 analyzed, 0 unavailable/failed, 8 with GPS;
face, aesthetics and similarity requests each succeeded for all 12. No library changes.
Displayed elapsed time was 0 seconds because the UI truncates to integer seconds; this
is not a precise benchmark. Face request success does not mean 12 faces detected or prove
detection accuracy. This validates the local PhotoKit-to-thumbnail-to-Vision path for
this small sample only, not full-library coverage, cloud-only assets, or selection quality.
Next: connect durable queue and local analysis under idle/sync/power gates, then selection
and thumbnail review. Keep raw database integration parked and Photos writes last.

## PhotoKit-Only Acceptance Diagnostic (2026-09-07)

User rejected schema-dependent database access as a core requirement. Park OSXPhotos
adapter/probe; do NOT ask for Full Disk Access or rerun raw database tests. Public PhotoKit
is the active path, with Vision for missing analysis. All album/folder writes remain last.
CuratorController.runDiagnostic + CuratorView add explicit Test Local Photos / Stop Test.
Uses Photos authorization without prompting for broad disk permission, selected date range,
12 newest nonhidden images, one thumbnail at a time with network=false and 8s timeout.
Runs Vision on the actor; aggregate-only on-screen summary, no names/IDs/images persisted.
Pauses background batches during test; stops between photos on sync/low power/thermal/cancel.
120s checked between items, not a hard deadline for an in-flight synchronous Vision request.
All 29 native tests passed (existing loader/analyzer coverage); diagnostic UI acceptance
and actual library results pending. Release bundle built; deep/strict signature check passed.
Running app not interrupted. Do not claim real test success.
Next: run in-app test, inspect aggregate report; then implement public-API context and
selection/review. The diagnostic does not yet measure albums/bursts or named Places.

## Real-Library Acceptance Attempt (Read Access Blocked, 2026-09-07)

User explicitly authorized read-only real tests and moved ALL Photos album/folder writes
to the final feature. Updated plan accordingly. No library writes or uploads authorized.
Located Pictures/Photos Library.photoslibrary/database/Photos.sqlite (7.7 GB); active/system
library identity not yet confirmed (defaults lookup stalled and was interrupted).
Installed osxphotos==0.76.1 in isolated .build/context-reader-env, not production dependencies.
Added macos/test_library_readonly.py: aggregate-only bounded probe, private temporary
snapshot, source DB/WAL/SHM stat-stability check, SQLite backup on clone, cleanup, no live
SQLite connection. Separate search store deliberately excluded, so search labels are not
validated by this probe. Source-stability checking is conservative, not cross-store atomicity.
Attempt under sandbox network/write denial failed; a plain `head -c 16` also returned
Operation not permitted. Thus macOS privacy access blocks database reads, not merely
the custom sandbox. No metadata read, snapshot completed, photos loaded, or Vision run.
Temp directories cleaned by context manager. No test process left running.
Next: user grants appropriate macOS privacy access to Codex and restarts it; then rerun
bounded read-only probe. Do not disable protection, use immutable=1 on live WAL, or claim
OSXPhotos compatibility from this failure. Real PhotoKit mapping/thumbnail tests still pending.

## Chunk 5a Extension: Library Context (2026-09-07)

User approved broadening people-only ingestion to reuse Places and existing categorization.
Plan updated: existing Photos knowledge first, new Vision second, internet last.
Added curator_context.py with per-field availability/provenance and allowlisted reads for
stored place name/country/home flag, titles/captions/keywords/albums/Favorites, category
labels/activities/holidays/season/venues, capture flags and advisory stored scores.
No reverse-geocoding or new inference. Components default off. Scores remain uncalibrated;
no rank threshold or equivalence with Vision implied. Names/locations remain local-only.
People failures now leave people_status unavailable and face evidence unknown while retaining
other usable context. Identity/hidden-field errors still reject the snapshot. This supersedes
the earlier all-or-nothing people field behavior; upload clearance remains always false.
Targeted tests: 13 passed. Full regression: 333 passed, 4 skipped via
`TZ=UTC .venv/bin/pytest -q`; `git diff --check` clean. Next: chunk 5b compatibility.
Still not a real library integration: dependency pin/fixtures, snapshot consistency/security,
PhotoKit mapping, field freshness and native ingestion remain chunk 5b. Public PhotoKit
burst IDs/selections and detailed place hierarchy are planned, not added in this slice.

## Chunk 5a Checkpoint: Optional People Reader Contract

Added src/icloudpd/curator_people.py: opt-in reader of an explicit database snapshot via
OSXPhotos PhotosDB. Uses person_info IDs, never merges people by name; unnamed face
evidence preserved; hidden/trash/video excluded. Missing/invalid data fails closed with
no partial import and no sensitive exception logs. No network, exports or database writes.
Tests use an injected fake API and temporary empty files, NOT a real Photos database.
Initial test exposed a positional assertion mistake after sorting; fixed by matching UUID.
Verification: `TZ=UTC .venv/bin/pytest -q`: 327 passed, 4 skipped (seven new reader tests).
`git diff --check` clean. This is NOT a verified OSXPhotos integration.
Chunk 5 remains partial: 5b must pin/test dependency, acquire a consistent snapshot with
explicit user selection, map UUIDs without guessing PhotoKit suffixes, and provide native
consumption/storage. Snapshot security, cleanup, version compatibility and bounded helper
process lifetime belong to 5b. No real snapshot, names, faces or photo data accessed here.
API source: https://rhettbull.github.io/osxphotos/API_README.html (person_info, face_info,
PersonInfo.uuid/name, explicit PhotosDB dbfile). Upstream macOS 26 support is incomplete.

## Chunk 4 Checkpoint: Vision Layer Implemented and Tested

CuratorVisionAnalyzer.swift serializes local Vision requests on an actor: face revision 3,
feature print revision 1 with scaleFit, aesthetics revision 1 on macOS 15+. Codable results
distinguish unavailable/failed/available, with OS+algorithm version keys. Feature prints
use secure archives; comparisons reject mismatched versions. Privacy upload gate remains
unconditionally closed. Results round-trip through the durable queue in tests.
All 29 native tests passed, including actual local Vision inference on a generated solid
color image, feature archive/self-distance, queue JSON persistence, version mismatch,
privacy states and oversized input rejection. No personal photos accessed or uploaded.
No packaged app replacement. Layer is not yet wired to the queue runner/background scan.
Limits: cancellation checked between synchronous Vision requests, not during a request;
no accuracy/people/diversity benchmark yet. Retry policy must distinguish failed signals
from permanent absence. Aesthetics are signals, not final rankings. Thumbnail-only face
results never establish research-upload permission. No person identification implemented.
Next action: chunk 5 optional read-only existing-people adapter compatibility/fixtures;
then chunk 6 selection and runner integration. Do not claim automatic visual curation yet.

## Chunk 3 Checkpoint: Thumbnail Loader Implemented and Tested

CuratorThumbnailLoader.swift adds an injected PhotoKit provider and a single-request
async loader. Network access is explicitly false, hidden/missing/unauthorized assets fail
without prompting, degraded callbacks are ignored, final images are redrawn to <=1024px
RGBA, and timeout/task cancellation cancels the PhotoKit request. Request tokens reject
duplicate/late callbacks, including callbacks before request ID return. No disk cache.
ThumbnailLoaderTests uses synthetic images/providers only. Native tests: 24 passed,
including five new tests for size bounds, synchronous/duplicate callbacks, timeout/reuse,
task cancellation, busy rejection, degraded images and distinct failure outcomes.
No production bundle replaced, no Photos requests or downloads made by tests.
Not connected to the queue yet. Caller must reuse one loader and release images between
jobs; returned RGBA is <=4 MiB, but PhotoKit internal/transient allocation is not controlled.
Cloud-only assets remain deferred; no automatic retry enabling network. Thumbnail face
detection alone will not qualify an image for research upload. Real PhotoKit orientation,
edited-image behavior and peak memory still need a scoped acceptance test.
Next action: chunk 4, versioned local Vision observations and safe failure semantics.

## Chunk 2 Checkpoint: Queue Storage Implemented and Tested

CuratorStore schema 2 adds a separate analysis_jobs table in an atomic migration.
Versioned enqueue preserves identical results; changed asset/analyzer versions invalidate
old work. Atomic claims use bounded leases and unique tokens, preventing stale completion.
Cancellation releases only the matching claim. Priority promotion supports later range
scheduling. The queue is NOT connected to the metadata scanner or image requests yet.
Tests added: AnalysisQueueTests, using temporary databases only.
Verification: `swift test --package-path macos/PhotoRelay`: 19 passed (6 new queue tests).
Coverage includes reopen/result persistence, expired lease recovery, stale completion,
edit/model invalidation, priority, cancellation, separate connections and v1 migration.
No real-library access, app rebuild/restart, or Python changes. Production bundle unchanged.
Limitations for worker integration: scheduler must supply reliable revision fingerprints,
only enqueue current versions, bound work below lease duration (or add renewal), and handle
deleted assets and retry backoff. Priority currently promotes but does not demote; scoped
foreground requests need scheduler handling. No claim of image analysis running yet.
Next action: chunk 3 bounded cancellable thumbnail loading with synthetic provider tests.

Planning discussion and resumable future chunks: see `CURATOR_PLAN.md` (2026-09-07).
Read it before further implementation. The user has now authorized implementation;
chunk 1 capability findings are in CURATOR_CAPABILITIES.md. No production app changes
in that chunk; next is the durable analysis queue. Real people-reader compatibility is
explicitly unverified. Repeatable probe: `swift macos/check_curator_capabilities.swift`.

Read this file before continuing curator work. Update it after each significant change,
including verification, limitations, and the next concrete step. Do not replace the
working Google sync implementation with an untested alternative.

## Product Contract (2026-09-07)

- Persona: Mac user with a Nest Hub on the desk who travels and wants to revisit memories.
- Photo Relay lives in the menu bar. Photos remains the originals and album backend.
- Gradually index the entire authorized library (back to 1998), then analyze locally
  during idle periods. Keep durable progress/results across restarts.
- Discover moments using time, location, and eventually visual content and quality.
- Best Photos flow: time range (last week/month/spring/custom), suggested moments,
  thumbnail review, then explicit sync to the remembered Google frame album.
- Foreground range processing takes priority over the historical backlog and reuses
  the same index. Never run two conflicting scans or duplicate analysis engines.
- Eventually publish curated selections as ordinary Photos albums referencing originals,
  not duplicate photos or private Photos Smart Albums. Preserve user edits and stable IDs.
- Internet enrichment is separately opt-in. No background upload of photos/person details.
- Never automatically authorize Google replacement. Keep Add/Replace review and Abort.

## Existing Sync Baseline

The user confirmed a successful Google album with 577 items; two unresolved uploads
were deliberately left out. The client handles explicit HTTP 429 with cancellable
backoff and keeps unknown POST outcomes protected from blind retry. Do not wipe the
upload ledger. OAuth consent consolidation is not yet implemented or requested again.

Native app: `PhotoRelay/Sources/PhotoRelay/`. Python local engine: `../src/icloudpd/`.
Build: `./macos/build_app.sh` from repository root. Native tests:
`swift test --package-path macos/PhotoRelay`. Python tests: `TZ=UTC .venv/bin/pytest -q`.
Baseline: 320 Python tests passed, 4 skipped; 6 native tests passed.

## Milestone 1: Metadata Foundation (Implemented)

Implement an opt-in idle metadata scanner, a durable SQLite index, deterministic
day/location grouping, and a native Moments workspace with prioritized date-range scans.
This milestone must NOT pretend to perform aesthetic AI ranking. It must not change
the Photos library or upload anything. Metadata-only scanning must not fetch originals
from iCloud. Photos authorization remains an explicit user action.

Design choices:
- One serialized worker, bounded metadata batches, atomic transactions.
- Background gates: user idle, no sync/export, no Low Power Mode or serious thermal load.
- Foreground scan overrides idle only, not thermal or concurrent-sync safeguards.
- Index entries survive restarts; a fresh metadata reconciliation replaces an unsafe
  persisted PhotoKit offset. Expensive visual analysis is a later separately versioned stage.
- Missing dates/locations remain unknown, never invented. Hidden photos are excluded.
- Persisted index is app-private; failed/incomplete scans do not delete existing index rows.

### Checkpoint A: Storage and Grouping Added

- `CuratorStore.swift`: SQLite WAL index, transactional upserts, full-scan-only pruning,
  exclusive-end range queries, undated counts. Stored rows contain PhotoKit identifiers,
  creation/modification dates, location, Favorites, and image dimensions; no image bytes.
- `CuratorModels.swift`: pure idle policy and date presets, deterministic day/time/location
  candidate groups. Current thresholds: same local calendar day, <=2h adjacent gap,
  <=10km adjacent known-location distance. No visual scoring or place-name inference.
- Candidate IDs use an anchor asset hash. They are NOT final durable published-album IDs:
  cluster merges/splits and manual edits require reconciliation before publishing exists.

### Checkpoint B: Worker and Native Workspace Added

- `CuratorController.swift`: one actor owns PhotoKit fetch snapshots and SQLite. Each
  batch indexes at most 300 image assets; a 2s main-run-loop timer gates dispatch.
  Background starts only after 120s without input. No power assertion prevents sleep.
- Opt-in enablement and an explicit system-managed launch-at-login toggle. Neither is
  automatically enabled by development/test tools.
- Foreground ranges replace the in-memory metadata cursor; historical reconciliation
  restarts afterward, reusing rows. Completed rows survive restart, but metadata traversal
  restarts at newest on launch. There is not yet any costly analysis to repeat.
- A PhotoKit observer marks metadata reconciliation dirty. Empty full fetches keep the
  old index as a conservative unavailable-library safeguard. Videos and hidden items are
  currently excluded; undated images are indexed but not assigned invented dates.
- `CuratorView.swift`: Moments workspace with counts, presets/custom dates, explicit
  metadata-only disclosure, and candidate rows. Google sync workspace remains separate.
- Tests added in `CuratorTests.swift` use temporary SQLite databases and synthetic photos.

### Checkpoint C: Lifecycle and Verification

- Curator now observes the app-owned sync model directly through Combine, independent
  of window visibility. New batches pause during export/upload; an already dispatched
  bounded metadata batch may finish. Foreground work remains serialized with background.
- Enabling indexing invalidates stale in-flight UI results. Future SQLite schema versions
  are rejected without resetting the index; covered by a regression test.
- All 13 native storage/grouping/policy and sync presentation tests pass.
  Python regression suite: 320 passed, 4 skipped. No real-library scan, login registration,
  Photos album changes, or cloud uploads were performed during verification.
- The first usable milestone is metadata preparation, not best-photo selection. Next
  concrete work is a bounded, cached on-device thumbnail analysis stage, followed by
  review and safe Photos album publication. Do not expose these as completed features.
- Release app rebuilt at `../dist/Photo Relay.app`; deep/strict code-signature verification
  passed. The running app was not restarted. Live Moments UI and 111k-library throughput
  still need user acceptance testing.

## Next Milestones (Not Yet Implemented)

2. Bounded thumbnail analysis using Vision, with cached versioned scores/similarity,
   asset-edit invalidation, iCloud download controls, and representative selection.
3. Thumbnail review, manual include/exclude decisions, stable moment identity reconciliation,
   and Photos album publishing with crash recovery and respect for manual edits.
4. Feed reviewed moment selections into the existing Google sync review workflow.
5. Optional internet enrichment and multi-day travel collections.

## Safety / Verification Notes

### Checkpoint D: Desktop Usability and Album Organization Research (2026-09-07)

- Added reproducible vector app artwork (`macos/render_icon.swift`), all standard iconset
  resolutions, build-time ICNS packaging, and CFBundleIconFile. Removed the runtime SF
  Symbol override, which did not supply a Finder bundle icon.
- Dashboard-only AppKit bridge switches to regular activation while open, including
  minimized/hidden windows, and accessory mode when closed. Tray reopening promotes
  before activation. No global window-title matching or replacement SwiftUI delegate.
- Native tests: 13 passed. Real Command-Tab/minimize/reopen behavior needs acceptance
  testing in the packaged app; tests do not manipulate the user's running window.
- Release bundle rebuilt with ICNS; deep/strict signature verification passed. Icon
  PNG was visually inspected. Running app was not interrupted or relaunched.

#### Researched Publication Design (Not Implemented Yet)

Photos supports nested folders of ordinary albums. Use this visible hierarchy:
`Photo Relay / Moments / 2026 / 2026-08-30 - <reviewed moment title>`.
Each published moment is an ordinary PHAssetCollection containing references to existing
assets, not copied originals and not an Apple Memory or Smart Album. Folder separation
organizes the sidebar, but cannot hide these photos from All Photos or all search results.

Workflow: choose period -> process/reuse index -> review representative thumbnails ->
publish/update a moment album -> select Google destination -> existing Add/Replace review
-> sync. The UI should offer a single "Save & Sync" action for the publication and review
handoff, not require switching tabs or finding the new album manually. Publishing success
and Google failure are distinct durable outcomes; retry sync reuses the same Photos album.
The existing Nest Hub destination keeps its Google ID; several source moments can feed it.

Do not publish today's raw metadata candidates (including singleton fragments). They stay
in the app index. Once visual curation exists, opt-in automatic publishing can maintain
qualified moments under the managed folder; explicit review can publish a selection now.
Tune minimum quality/diversity and merging before enabling historical auto-publication.

Photo Relay's album browser currently fetches albums as a flat list. Before publishing,
add separate "My Albums" and "Photo Relay Moments" sections, with year grouping and
search across both. Classify by persisted managed album IDs, NOT names or folder alone.
Do not show the same album in both sections. Manually created albums remain untouched.

Persist root/year folder IDs, stable moment UUID -> Photos album ID, published membership,
and manual inclusion/exclusion decisions. Use PhotoKit change blocks and placeholders
for creation, and PHCollectionListChangeRequest.addChildCollections for folder membership.
Check edit capability and retain a publication journal for crash reconciliation. A lost
creation response must not cause blind album recreation. Renames retain identity; moved
albums stay managed but are not forcibly moved back. Deleted albums/folders require a
visible recovery decision rather than silent resurrection. Never adopt an existing folder
or album by title alone. Reconcile user membership edits before future automatic updates.
Local identifiers are persistent in the local library, not a cross-Mac sync identity.

Apple sources reviewed:
- https://support.apple.com/guide/photos/group-albums-in-folders-pht211de0d6/mac
- https://support.apple.com/guide/photos/create-and-work-with-albums-pht6d60a1f1/mac
- https://developer.apple.com/documentation/photos/phcollectionlistchangerequest
- https://developer.apple.com/documentation/photos/phobject/localidentifier
- https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum

Do not enable scanning on the user's real library, register a login item, or publish
albums just to test the build. Use synthetic metadata fixtures and temporary databases.
Actual performance on the 111k-item library must be reported as unverified until measured.
# Automatic boundary engine checkpoint (2026-09-09)

Added AutomaticMomentSegmentation and a private atomic record store. Boundaries require
two visually coherent photos on each side plus a sustained distinctive scene change or
recorded GPS shift. OCR can support continuity, never establish an event alone. Missing
evidence leaves the coarse group intact. Requests are bounded to 512 photos. Store writes
reject duplicate membership and require exact input coverage and revision fingerprint.
Protected parent IDs bypass proposals. This is a foundation checkpoint, NOT an enabled
background stage: CuratorWorker does not call it yet. No app redeploy or Photos changes.

Next: wire bounded preparation and catalog projection into CuratorWorker; pass manual
title/description IDs and saved review IDs as protected identities. Do not overwrite records
with protected child IDs. Preserve groupingSource/groupingReason when classifying visible
photos. Handle newly added residual IDs without collisions. Test real August 30 copies
and stale-input/manual-child preservation before enabling automatic grouping in production.

Google admin blocker: existing project vertex-ai-test-project-442812 was verified billed.
Do not change its billing or make enrichment requests. A separate explicitly unbilled
project and service eligibility check are needed for the no-paid-fallback requirement.
# Google research eligibility checkpoint (2026-09-09)

User supplied photos-curator-project, with screenshot showing no billing account.
Rechecked https://ai.google.dev/gemini-api/terms (effective March 23, 2026):
Use Restrictions requires Paid Services when making API clients available to users in
the EEA/Switzerland/UK. Grounding terms also prohibit general caching/database collection
of grounded results, with narrow display/chat-history exceptions. Therefore the planned
persistent automated enrichment cannot be enabled merely by verifying an unbilled project.
Keep the research scheduler disabled. Do not link billing or send research prompts/photos.
Revisit provider licensing and region eligibility before implementing persistent enrichment;
do not ask the user for further GCP IAM changes as if they resolve this product constraint.
# Research removal checkpoint (2026-09-09)

Removed google_enrichment.py and free_research_quota.py and their research-only tests.
Retained OAuth recovery tests in test_google_access.py with an exact Photos/identity
scope regression assertion. Removed cloud-platform from startup permissions, the unused
research request parameter, research status state and Settings toggle. Settings now
clearly separates local Moments preparation from intentional Google Photos uploads.
No remote projects, billing, tokens, Photos assets or persisted user caches were changed.
Python focused verification: 61 tests passed (access, frame sync, rate limits, dashboard).
Reconnect scope merging now retains only supported Photos/identity grants, rather than
reintroducing retired Cloud scopes from an old token. Swift: 93 tests, 4 skipped, no failures.
Older research checkpoints below are historical, not active implementation instructions.
# Automatic Moments integration checkpoint (2026-09-09)

CuratorWorker.prepareMoments now prepares persistent semantic boundaries, then captions
for their projected children. Scheduler runs this between photo jobs and drains a clean
bounded sweep before ending priority work. Full catalog is independent of priority dates;
priority selects intersecting whole groups, never truncates membership. Newest first.
Records live in curator/automatic-moments with revision/engine fingerprints and atomic
private files. Missing cached Vision/labels/OCR leaves grouping visibly pending. Groups
over 512 photos remain explicitly broad/conservative instead of silently size-splitting.

Named/described Moments pin member IDs in curator.namedMomentMembers.v1 UserDefaults.
Explicit saved split/merge groups take precedence; pinned membership then precedes new
automatic groups. Existing visible saved titles are migrated from the catalog snapshot.
Manual include/exclude decisions remain per-asset and untouched by analysis. Resetting
both title/description releases the pin. Review shows an optional grouping explanation;
no new workflow dialogs. Cards distinguish pending grouping from completed preparation.

Final Swift suite: 100 tests, 5 opt-in skips, no failures. Separate opt-in August 30 test
passed: all 30 exported copies processed locally, 2 collections of 29 and 1, complete
coverage, persistent boundary reuse and fallback captions. No finer boundary was supported;
this is an honest conservative result, not venue-quality grouping. Copies lack favorite
flags; test uses false and does not touch PhotoKit or the live curator database.
Caption cache fingerprint now includes capture dates so corrected dates invalidate text.
Current-group child captions finish before the cursor moves to older collections.
Remaining acceptance: launch the rebuilt app and observe the existing Moments workspace.
# Mixed-timeline grouping and presentation checkpoint (2026-09-09)

Added fixed-reference scene grouping for tightly packed (8+ photos, <=3 seconds/photo
total span) timestamps. Does not use their order as an itinerary. Each member must match
its fixed reference (distance <=16; up to 18 with shared distinctive local scene clues),
with no conflicting recorded GPS (>1 km) or distinctive scene clues among members.
Publish scene sets only with >=3 members, >=2 supported sets and >=25% total coverage.
A uniform similar burst stays one scene; agreeing recorded locations retain the original
group. Unresolved photos remain explicitly labeled for review and get no invented caption.
Pair comparisons capped at 8192; budget exhaustion cancels the split, never commits a
partially searched result. Inputs remain capped at 512. No new settings or web requests.

The first complete-link experiment fragmented the real set into mostly two-photo groups;
it was rejected before release. Final fixed-reference rule supports variety without
neighbor chains. Background classification now preserves confident distinctive clues
outside the top four generic labels (max eight total); versioned label/derived caches
refresh automatically without discarding manual corrections or rerunning saved Vision
feature extraction. Protected Moments continue bypassing automatic regrouping.

Real 30-copy test: two supported repeated-scene sets, sizes 5 (garden) and 3 (castle),
21 unresolved afternoon photos, and the separate midday photo. No venue identity claimed.
This improves repeated-scene separation, NOT complete venue/event understanding.

UI: named cards say Your edits saved; auto title no longer repeats below custom text;
cover thumbnails omit timestamps (review thumbnails retain them); full titles available
on hover; thumbnail reload identity includes asset edit revision and requested size.
Synthetic image rendering verifies cover height contains no clipped timestamp row.

Final verification (23:15): 107 Swift tests, 5 opt-in skips, no failures. Separate
authorized exported-copy test passed in about 4 seconds with sizes 5/3/21/1 and complete
coverage. Full-venue naming is still unverified; no network calls or live library writes.
The running app was not restarted, and its named Moment/selection was not modified.

# Generated-state reset checkpoint (2026-09-09, 23:34 CEST)

User requested step 1 of the clean evaluation workflow while exporting a new dataset,
explicitly declining a database backup. Photo Relay and its backend were not running.
Removed the generated index.sqlite3 and WAL/SHM, automatic-moments, background-context,
text-evidence, moments-catalog.json and narrative-cache.json (including cache lock files)
from the live app's Application Support/Photo Relay/curator directory. No backup made.
About 503 MB of generated state was cleared. Only group-review.json and its lock remain
in that directory; explicit split/merge corrections were intentionally preserved.

Set only local.icloudpd.photorelay's curatorEnabled preference to false, verified as 0,
so background work does not immediately repopulate the index. Before/after checksums
match for preserved app-support files (including credentials, upload ledger, album mapping
and saved group review) and for all preferences excluding curatorEnabled. Custom titles,
descriptions, membership pins, manual photo decisions and other settings remain intact.
No Photos library access or changes, exported-photo changes, network calls, app rebuild
or relaunch. This is a generated-state reset, not a deletion of user corrections.

Next: wait for the export folder, establish a separate evaluation dataset/reference
Moments, and improve grouping against that evidence before resuming broad curation.
Resetting caches alone does not fix the legacy diagnostic grouping fragmentation.
Do not resume analysis or discard preserved corrections implicitly.

# Export/reference audit checkpoint (2026-09-10, 00:10 CEST)

User supplied Pictures/Photo Relay Analysis and explicitly approved representative pixel
inspection in this conversation (not a claim of on-device AI). Audited exported files
read-only: 4,534 JPEGs, 108 MOVs, 261 media folders, 15,768,060,845 bytes. All JPEGs retain
DateTimeOriginal and offsets; 3,868 have GPS; no byte-identical duplicates. No sidecars or
keywords found. Favorites/People/PhotoKit-category fidelity not available from these files.
QuickTime CreationDate preserves movie recording dates; CreateDate/MediaCreateDate reflect
export time. Added tested precedence instead of incorrectly grouping videos on export day.

New developer-only macos/evaluation tooling: ExifTool/Node read-only manifest with content
hashes and private reports outside the export, source-change/symlink/output guards,
deterministic reference sampling and hash-checked Swift contact-sheet rendering. Four
Node audit tests pass. No production app changes or redeployment. Private report folder:
Pictures/Photo Relay Evaluation 2026-09-09 (run started before midnight).

Inspected 138 approved samples in eight reference cases. Reserved all 684 February JPEGs
before pixel inspection, keeping neighboring trip days together in the holdout. Folder
labels are reference hints, not grouping-model inputs or independently verified venues.
Private REFERENCE_REVIEW.md and provisional-review.json record sample choices, scene
relationships and evidence/display distinctions. These are NOT user-approved ground truth
or 4,534-photo visual acceptance. Do not turn each scene bin into a separate feed card.

Native opt-in metadata baseline calls existing MomentGrouping on complete development
folders (sample-only screenshots) with no Vision/model/PhotoKit calls. Verified full
coverage and holdout isolation. Restaurant case splits 16 into 13+3 at a 2h1m39s gap with
matching surroundings/GPS. Palace case retains 624 photos, above refinement limit. Coastal
day remains 160 although observed beach/harbour/later dinner occupy distinct locations.
These are concrete follow-up quality cases, not silently fixed or accepted behavior.
Full native suite at this checkpoint: 108 tests, 6 opt-in skips, 0 failures.

Next verification in progress: existing background OCR/classification on 66 approved
palace/restaurant/mixed-timeline samples, isolated in report/evidence-pilot. Determine
whether clues are missing at extraction or lost between evidence and caption preparation.
Live curator stays paused with only saved group-review files; no index recreation.

# Existing evidence-to-caption gap confirmed (2026-09-10, morning)

The local pilot completed on 66 approved exported samples (20 palace, 16 restaurant,
30 mixed-timeline) using CuratorWorker.prepareText, cached OCR and NarrativeVisualContext.
The harness initially requested 2048px and correctly hit the classifier's 1024px input
guard. Corrected the harness to the normal 1024px background size and discarded only its
partial evaluation cache before the fresh run. This was not a production extraction bug.
Fresh pilot passed in 8.6s; OCR found text in 7/20, 10/16 and 9/30 respective samples.

Local OCR already reads the restaurant brand words and miniature-park sign at reported
confidence 1.0. These recognition scores do not verify venue or event identity. Added
opt-in extraction assertions. Generic deterministic captions remain possible art scenes,
possible structure scenes and possible blue sky scenes. Favorites are unknown in exports;
the harness's zero placeholders must not be presented as actual library metadata.

Root cause confirmed in source: BackgroundMomentContext.prepare reads eight sampled label
caches, aggregates three labels and passes no OCR/textClue to MomentNarrativeMetadata.
AppleLocalNarrativeModel only selects a prewritten candidate index; it cannot rewrite a
caption or synthesize a context absent from the candidates. The pilot deliberately used
deterministic fallback, not a model call. Do not describe this as an unavailable model or
claim the evidence gap is fixed. Production code is unchanged in this evaluation chunk.

Next implementation priority: bounded, attributed evidence-to-caption handoff and richer
grounded event/activity candidates, with local OCR treated as untrusted evidence rather
than instructions or verified place names. Avoid text/PII spill from utility screenshots,
menu slogans as event names, and spreading one named clue over a mixed-venue collection.
Then address evidence/display roles, soft time boundaries and large-visit refinement.
Private pilot artifacts and provisional references remain in the evaluation directory;
no PhotoKit access, Google/API calls, app bundle deployment, or live database recreation.

Final verification, 07:57: full native suite 109 tests, 7 opt-in skips, no failures;
both opt-in reference tests passed separately (fresh evidence run 8.6s, cached rerun 1s).
Four audit tests passed. Private reference indexes and scene-bin coverage validate; all
embedded contact sheets exist. Verified curatorEnabled remains 0 and the live curator
directory still contains only preserved group-review files. No app redeployment needed
for this developer-only evaluation checkpoint.

# Evidence-to-caption implementation in progress (2026-09-10, 09:00)

Added MomentCaptionEvidence with deterministic bounded sampling (up to 128 across the
whole collection), repeated activity support and source/revision-attributed OCR clues.
BackgroundMomentContext now waits for both cached labels and OCR, passes structured
evidence to grounded caption candidates, and persists the evidence plus an input digest.
Evidence updates invalidate fallback captions without waiting for the model retry delay.
The local model remains a constrained candidate selector, not a free-form image model;
its prompt receives compact activity counts and a scoped clue, not raw OCR or asset IDs.

PhotoKit screenshot flags are captured at ingestion and excluded from caption evidence.
Unknown legacy categories cannot supply OCR clues until refreshed. Private/instruction
text, nonfinite/low OCR confidence and stale/foreign photo evidence are rejected. This is
conservative local filtering, not an anonymity/compliance guarantee. No external requests.

Compilation passed. Existing label-only caption test is intentionally being migrated to
require completed OCR, and new synthetic privacy/cache/mixed-timeline tests plus the
66-copy reference pilot are in progress. Not yet a verified completion checkpoint.
No live curator restart, database creation, deployment, Photos writes or manual edits.
Estimated restart path after this chunk: four bounded chunks for feed eligibility,
soft time boundaries, large visits, and holdout validation/redeployment respectively.

# Verified evidence-to-caption checkpoint (2026-09-10, 09:08)

The implementation above is complete and tested. Ten new builder/background tests and
one model-handoff test cover OCR provenance, repeated activity support, screenshot/unknown
categories, PII/instruction exclusions, invalid confidence, deterministic bounded sampling,
mixed compressed timelines, duplicate/stale/foreign evidence, cache refresh and cancellation.
Existing manual-correction and priority/background-pipeline tests still pass. Late OCR
updates bypass fallback retry delays; evidence engine/version changes invalidate captions.
The model receives compact activity counts rather than potentially oversized asset arrays.

Reused the approved 66-copy evidence pilot, with no new image scope or holdout inspection:
C03's 20 samples yield Art and interiors; C05's 16 yield Food and dining, retaining the
business-sign clue and source; C06's 30 yield Scenes from this collection, with one-photo
park text not promoted to a collection-wide venue. No venue strings hardcoded in production.
The pilot categories are explicit reviewed fixture assumptions, NOT exported PhotoKit flags.
Favorites remain unknown in exports; zero-count placeholders are not real-library findings.

Validation: full Swift suite 120 tests, 7 opt-in skips, 0 failures. Both exported reference
tests passed separately. Real Apple local-model synthetic-metadata test passed for old and
new evidence-aware prompts; real-copy pilot titles deliberately use deterministic fallback.
Four audit tests pass. Native release build passes. No app bundle rebuilding/redeployment,
no Photos/Google calls, source-file writes or live indexing. Verified curatorEnabled = 0
and only group-review.json + its lock remain in live curator directory.

Next: display/evidence eligibility, then event continuity, large visits, holdout/release.
Do not resume indexing yet. Remaining estimate and acceptance criteria are in CURATOR_PLAN.
Private REFERENCE_REVIEW and local-evidence-pilot.json contain the before/after evidence.

# Display eligibility implementation in progress (2026-09-10, evening)

Added version/revision-attributed PhotoDisplayEvidence for screenshots, corroborated maps,
menus and documents. Utility score alone is insufficient; people, artwork and meaningful
object labels veto uncertain utility suppression. Roles are derived from existing local
caches and persisted in the catalog, with every asset retained in its original Moment.
Selection removes context-only assets BEFORE similarity ranking. Favorites and explicit
Include remain eligible; explicit Exclude wins. User-named/reviewed groups stay visible.

Normal Moments separates context-only collections into one collapsed, accessible section,
not diagnostics or a new settings dialog. Its cards do not silently reuse a utility image
as a cover; opening a collection still exposes full-size previews and Include controls.
Older-collection pagination remains available even if the loaded page is all context-only.
Existing 120-test suite passes; targeted role/persistence/real-copy checks are in progress.
No app initialization/relaunch, live index recreation, Photos changes or network requests.

# Verified context/display separation (2026-09-10, evening)

Production overview uses CuratorWorker.prepareDisplaySelection, also exercised directly
without PhotoKit or an index. Conservative roles use current cached OCR/classification and
optional current aesthetics. Role version includes analyzer/classifier/OCR/OS versions;
asset edits invalidate it. Persisted PhotoMoment.displayEvidence and selection.contextOnly
are optional so older catalog snapshots still decode. Full membership and caption evidence
remain unchanged. Roles are regenerated from caches, not copied into user decisions.

Eleven targeted tests cover corroborated utility detection, meaningful object/people vetoes,
uncertain/stale signals, selection ordering, Favorites/manual precedence, catalog roundtrip,
legacy decode, version invalidation, cache-only worker path and 250px context-card rendering.
The normal feed folds context-only collections into an accessible collapsed section, with
no source thumbnail used as a fallback. Include returns a photo to display eligibility;
user-named/reviewed groups remain visible even without an automatic display candidate.
Older pagination remains reachable when an entire loaded page is contextual.

Expanded approved-copy pilot from 66 to 90 using already-reviewed C07/C08 samples, not the
February holdout. C03: one map retained for context; C05: two menu pages; C06: no contextual
suppression; C07: all 12 doll samples remain display candidates; C08: all 12 screenshots
are contextual, with no automatic cover or OCR-caption contribution. Screenshot category
is a reviewed test fixture assumption; exports do not preserve public PhotoKit categories.
The first menu test failed on plural vocabulary; fixed bounded food-family matching and
added a counterexample so repeating one dish name does not establish a menu. No private
venue terms or reference folder labels are production features.

These remain conservative rules, not complete utility recognition. Unknown/weak clues stay
display candidates. Pilot uses no aesthetics result, so it verifies roles and full coverage,
not final best-photo ranking or live UI acceptance. Captions still use deterministic fallback.
Native release/full-suite verification follows; live curatorEnabled remains 0 and only
preserved group-review files exist in the live directory. Next chunk is soft event continuity.

Final verification: 131 Swift tests, 7 opt-in skips, no failures; the expanded 90-copy
reference pilot and metadata baseline passed separately. Native release compilation passed.
Rendered and visually inspected the context-only placeholder card at 250px on a white/light
background; no clipped content or utility pixels. Full workspace interaction/relaunch still
requires release acceptance. Test render is /tmp/PhotoRelay-context-card.png (synthetic only).
No deployment or live restart. Active plan now starts with the current three remaining gates
to avoid mistaking historical GCP/earlier 'next' notes for current instructions.

# Event continuity implementation in progress (2026-09-10, evening)

New MomentContinuity evaluates adjacent unreviewed base groups before internal semantic
segmentation. Same-day gap >2h and <=3h, total span <=6h, combined <=512 photos; repeated
recorded GPS on both sides within 150m of a fixed anchor, multiple one-to-one display-photo
visual matches and no repeated contradictory scene/occasion clues are required. Screenshots
and corroborated utility images cannot act as visual bridges. No inferred GPS or venue names.

Versioned per-pair records persist both negative decisions and accepted visual source pairs.
Fingerprints include metadata, engine/OS and actual cached visual/OCR results. Scope includes
neighbors outside a priority range; accepted joins project before paging/priority selection.
Pair application is disjoint/newest-first, never transitive. Missing evidence defers evaluation.
Manual groups, named membership and protected automatic children block automatic joins.
Continuity reasons flow through existing About this grouping disclosure, no new UI controls.

Existing pipeline tests pass. New real 16-copy restaurant pipeline test and synthetic
counterexamples/persistence checks are in progress. Live index and Photos remain untouched.

# Verified provisional event continuity (2026-09-10, evening)

Production integration complete: raw full-scope groups -> persisted continuity projection ->
internal segmentation -> existing caption/display stages. A change invalidates the prepared
scope so the merged full membership, not a priority-clipped subset, is captioned. Continuity
provenance is preserved in catalog snapshots and existing grouping explanations. Records in
curator/event-continuity are derived data, distinct from user group-review files.

Conservative bounds: adjacent groups only, same calendar day, >2h to <=3h gap, <=6h combined
span, at most 512 photos and >=2 photos per side. Imported/compressed groups are ineligible.
Requires >=2 recorded GPS per side agreeing within 150m of a fixed anchor, plus at least two
one-to-one nonutility visual matches from six boundary candidates per side (<=36 distances).
Existing revision-specific distance cutoff 16 is unchanged. Repeated distinctive scene or
occasion contradictions veto the join. Same-location repeat visits can remain ambiguous;
these are provisional rules, not event recognition guarantees or identity/face matching.

Both positive and negative decisions persist with metadata/engine/OS and actual evidence
digests. Missing evidence writes no rejection; completed changed evidence can retract a join.
Application is deterministic, disjoint/newest-first: no transitive chains or skipping over
intervening groups. Saved split/merge, named membership and protected automatic children win.
Metadata changes invalidate immediately; changed cached evidence is reconsidered during the
next background preparation sweep. No new controls, PhotoKit mutations or network requests.

Real-copy test: all 16 previously approved restaurant photos, local Vision/OCR at 1024px,
temporary stores. Original 13+3 becomes 16; cross-gap matches include distances 13.35 and
13.76. Priority covers only the late three but resulting caption covers the whole joined
visit. Reopening the worker preserves its ID. Synthetic contradictory labels added only to
the temporary caches retract it to 13+3. Report: private continuity-pilot.json. Exported
Favorites are unknown; this test does not claim favorite ranking or general quality acceptance.

Ten synthetic continuity tests cover location-only/single-match/invalid metrics, missing or
conflicting GPS, scene/occasion conflict, utility-image veto, time/day/import/size limits,
no chaining, explicit corrections, record restart/revision invalidation and cancellation.
Full native suite: 142 tests, 8 opt-in skips, no failures. All three reference tests pass
separately, including the existing 90-copy caption/display regression checks. Holdout remains
untouched. Release build verification follows. Live curatorEnabled = 0, only group-review
files remain in its directory. No deployment or live indexing restart.

Next: large-visit refinement. Do not turn internal sections into extra feed cards. Two planned
chunks remain including validation/redeployment; holdout failures may add a correction pass.
# 2026-09-11: Large-Moment windowing foundation

Added LargeMomentWindows.swift and three synthetic tests. Work units own at most 256
photos and include two neighboring photos on either side for boundary comparisons.
Deterministic IDs incorporate parent ID, full metadata fingerprint and window size;
changed parent membership invalidates prior work. Internal records use the existing
validated atomic writer in an isolated internal-windows directory. A reopened store
finds the next unfinished window; no internal ID enters the catalog.

Verified: swift test, 145 tests / 8 opt-in skips / 0 failures; production build passed
(22.54 seconds). Tests cover 624-photo coverage, boundary overlap, reorder stability,
persisted completion, changed membership, namespace separation and invalid inputs.
This release build also includes the preceding event-continuity changes.

Scope: foundation only. Worker still rejects >512 photos. Next implementation must wire
bounded preparation, actual-evidence invalidation, missing-evidence handling and parent
aggregation before claiming large-visit support. No app deployment, live indexing,
Photos access, network research or private-photo inspection in this subchunk.
# 2026-09-12: Moments-native library editing and Google handoff

- Moment review now changes the public PhotoKit `isFavorite` flag directly and can delete an original only after a destructive confirmation. PhotoKit performs deletion, so the item enters Photos' Recently Deleted workflow and iCloud handles propagation.
- Merging is no longer local-only when source Moments have published albums. Photo Curator first creates/verifies the merged replacement, then removes only superseded album containers proven to be inside its own `Photo Curator/<year>` hierarchy. Merge never deletes assets; an uncertain cleanup fails closed and leaves duplicate albums.
- The legacy Albums & Sync workspace and user-visible staging directory were removed. Selected Moments now expose Save to Google Photos, with Curator Highlights or current Photos Favorites and an app-created destination album. Staging uses an app-private cache and the existing review-before-upload flow.
- Video and Live Photo export preferences moved to app Settings and persist across launches.
- Native mutation tests remain non-destructive: no developer test invokes a live Photos deletion.
# 2026-09-12: foreground polish and bounded storage

- Removed Photo Curator's redundant delete confirmation; PhotoKit's system confirmation remains authoritative and deletion still enters Recently Deleted.
- Curator-originated Favorite/Delete mutations now reconcile only the affected asset in SQLite and suppress their own PhotoKit observer echo. They no longer cancel and restart a full 109k-item metadata sweep.
- Metadata-only sweep batches adapt to use: 100 while the app is active, 1,000 while unattended, and 500 for an explicit prioritized range. Heavy Vision work remains gated by system idle state.
- Replaced the changing header command rows with a stable native window toolbar. Selection-dependent Google and merge actions remain visible but disabled until applicable; time prioritization stays consistently available.
- Added launch storage maintenance: derived OCR/scene caches expire after one year and are capped at 512 MB each; Google staging expires after seven days, is capped at 2 GB, and is removed after review cancellation or completed sync. SQLite now prunes orphan jobs, optimizes query statistics, and truncates its WAL. Existing JSONL and Python engine logs already rotate at approximately 4 MB and 8 MB total respectively.
- Current observed storage before this change: about 202 MB Application Support (144 MB SQLite, 51 MB derived evidence) and 2.3 MB logs. The durable index remains in Application Support; recreatable Google media remains in Caches per Apple file-system guidance.

## Follow-up: repeated metadata sweeps

- Telemetry proved the 109,179-item sweep completed and then restarted about every 14 minutes. Album auto-publication generated delayed PhotoKit notifications after the old three-second suppression window.
- Replaced the timing heuristic with a retained PhotoKit image fetch and `PHFetchResultChangeDetails`. Album/folder-only changes now produce no image-index work. Incremental image insertions, edits, Favorite changes, hides and removals reconcile only their affected identifiers; only a non-incremental PhotoKit change falls back to a full sweep.
- Added counts-only `libraryChange` telemetry so future restarts identify incremental versus non-incremental PhotoKit events without logging asset identifiers.
## Meaningful-place, venue, and Faces API research (2026-09-12)

- Public framework review confirms MapKit can geocode addresses, reverse-geocode coordinates
  into map items, and search a bounded radius for points of interest. `CLPlacemark` can also
  carry areas of interest, but the new MapKit geocoding requests are the forward API direction.
- Apple Maps' personal Home/Work/Favorites are not exposed to third-party apps. Planned an
  app-local Settings > Places model with address search, optional explicit current-location
  capture, custom labels/radii, local persistence, and user-label precedence.
- Venue names will require conservative evidence and caching. An attraction such as Efteling
  is a plausible POI result; a tenant/company office may not be, so custom Work labels remain
  the reliable override.
- Public PhotoKit does not expose Photos' named People/Faces graph. The production design stays
  on public APIs: PhotoKit metadata plus local Vision face count/quality. Private Photos database
  ingestion remains rejected because it is brittle across macOS releases and handles sensitive
  identity data.
- This checkpoint changes the plan only. It performs no location lookup, requests no permission,
  reads no photos, and does not rebuild or redeploy the app.

## Meaningful places and venue context implemented (2026-09-12)

- Added a persistent Settings > Places section for Home, Work, and custom labels. Address and
  place search use public MapKit results; an explicit Use Current Location action uses Core
  Location and is the only path that requests location permission. Each place has a configurable
  50–1,000 metre matching radius and can be removed from Settings.
- Added a photographer-oriented Moments tip only while the place list is empty. It links to the
  standard app Settings and does not block browsing or background curation.
- Location presentation now prefers a matching user label, then a reverse-geocoded area of
  interest, then a conservative nearby POI, then the existing neighborhood/city. Nearby POIs are
  accepted only within 100 metres with a 50-metre advantage over the next candidate; ambiguous
  businesses fail closed to locality. Lookups retain the existing rounded-coordinate cache.
- Meaningful labels produce natural “At Home” / “... at Studio” title grammar. User-written Moment
  titles still override all generated place context. The underlying venue and address evidence is
  retained when a user label wins, allowing future explanation and reprocessing.
- Added Photos-independent tests for matching radii, isolated persistence/deletion, title grammar,
  and meaningful-place precedence over venue/locality evidence. Full verification: 187 tests,
  10 opt-in skips, zero failures.
## Narrative UX planning checkpoint (2026-09-12)

- User acceptance screenshot showed a factual but robotic regression after meaningful-place
  support: most home cards became `At Home · date`, repeated Home in the status line, and lost the
  subject visible in the cover photo.
- Code review found narrative responsibility split among deterministic candidate construction,
  local-model candidate choice, card presentation, and Photos publication. Publication can prefer
  stored `suggestedText` while cards apply separate place formatting, so surfaces can disagree.
- Planned a versioned, persistent, evidence-grounded Moment narrative shared by cards, review,
  accessibility, Photos album names, and Google handoff. Subject/activity/occasion leads; place and
  date support it. Home/Work become modifiers; venues lead only when they are destinations.
- Planned six resumable chunks with a frozen acceptance corpus and repetition tests. This checkpoint
  intentionally makes no source change, build, deployment, Photos mutation, or location request.

## Mathematical architecture review checkpoint (2026-09-12)

- Reviewed the supplied “Unified Mathematical Architecture for Photo Curator” and mapped its HMM
  segmentation, graph continuity, submodular selection, TF-IDF salience, Bayesian occasion, POI,
  and MMR proposals against the current implementation.
- Adopted the core direction but rejected unsafe assumptions: missing GPS/OCR cannot be numeric
  evidence, Vision distance has no promised universal 0...1 scale, Home is not a latent sequence
  state, and example weights/thresholds are not production parameters without calibration.
- Added a nine-chunk plan built around typed evidence, user-derived calibration, shadow evaluation,
  duration-aware sequence inference, adaptive facility-location selection, and one stable grounded
  narrative. Existing user corrections and public-API-only boundaries remain hard constraints.
- This checkpoint changes documentation only. It performs no build, deployment, indexing, photo
  inspection, Photos mutation, location request, or cache migration.

## Mathematical architecture implementation checkpoint 1 (2026-09-12)

- Added a shared typed-evidence model carrying optional values, confidence, provenance, and engine
  version. Missing GPS, OCR, and Vision evidence remains unavailable rather than becoming numeric
  evidence for a join or split.
- Added empirical Vision-distance percentile calibration, an explainable logistic boundary posterior,
  and conservative two-sided duration smoothing. Automatic grouping records now persist the shadow
  estimates while retaining the current production segmentation decision.
- Added a monotone coverage/quality/role highlight optimizer with hard protected-photo constraints,
  plus reusable narrative salience and grounded-candidate scoring primitives.
- Added deterministic tests for missingness, location-conflict direction, protected Favorites,
  visual/role diversity, minimum semantic support, and repetition penalties. Focused verification:
  14 tests, zero failures. No deployment, live indexing, photo access, or Photos mutation occurred.
- Remaining work starts with frozen corpus metrics and calibration data, then production promotion,
  continuity integration, representative-selector integration, shared narrative persistence/surfaces,
  and final export/live-library acceptance. These gates are intentionally not bypassed.

## Mathematical architecture implementation checkpoint 2 (2026-09-12)

- Promoted the set-level optimizer into representative compaction. It combines normalized aesthetic
  quality, facility-location coverage, temporal/place/people/context roles, and an adaptive stopping
  floor rather than filling a fixed count unconditionally.
- Photos Favorites are hard constraints and may legitimately exceed the automatic upper budget.
  Earliest/latest evidence and a temporal-similarity fallback preserve visit span when Vision feature
  prints are unavailable; available feature prints use the existing conservative similarity scale.
- Existing manual selection still takes precedence downstream. Removed photos remain alternatives,
  not deletions, and can be restored by Include or Favorite.
- Focused representative tests pass, including oversized Favorite sets and full-visit temporal spread.
  No app deployment, live indexing, private-photo access, or Photos mutation occurred.

## Mathematical architecture implementation checkpoint 3 (2026-09-12)

- Cross-gap continuity records now retain a calibrated, explainable boundary posterior derived from
  time gap, recorded GPS, robust one-to-one visual matches, and positively observed shared OCR.
- Missing GPS and missing OCR remain unavailable. They cannot silently become same-place or
  different-scene evidence. Existing GPS/scene/occasion conflict gates, utility exclusion, bounded
  six-photo edges, one-to-one matching, and no-chain application remain intact.
- During calibration the posterior is a conservative veto only at near-certain boundary confidence;
  it cannot independently join groups. User merges/splits and named groups remain authoritative.
- All 12 continuity tests pass. No deployment, live indexing, Photos mutation, or private-photo
  inspection occurred.

## Mathematical architecture implementation checkpoint 4 (2026-09-12)

- Extended narrative metadata with a place role, allowing Home and Work to act as natural modifiers
  while ordinary localities and destinations use separate grammar.
- Replaced deterministic `Photos from`, `in pictures`, `possible ... scenes`, punctuation-built
  place/date titles, and audit-like fallback prose with subject-first or gentle date-based language.
- Generic Vision labels cannot become headlines. A concrete label may lead only as a bounded visual
  subject; activity evidence remains multi-photo, OCR remains attributed, and no occasion/person/place
  is invented.
- Deterministic fallback now scores candidates for grounding, specificity, and forbidden robotic
  patterns instead of blindly selecting candidate zero. Prompt/cache versioning invalidates old
  automatic choices; manual narrative remains authoritative.
- All 9 narrative tests pass with 2 explicit opt-in skips. No packaged-app deployment or Photos
  mutation occurred.

## Mathematical architecture implementation checkpoint 5 (2026-09-12)

- Added versioned `MomentNarrative` with canonical headline, deck/story, place/date, confidence,
  provenance, and processing/customization state.
- Centralized precedence in `MomentPresentation.narrative`: explicit user text, saved grouping title,
  unresolved-safe fallback, automatic local narrative, then natural place/date fallback.
- Cards, review/accessibility title helpers, auto-publication, manual Photos publication, and Google
  handoff now resolve through the same canonical headline/story path. Publication no longer bypasses
  presentation by selecting `suggestedText` independently.
- Unresolved collections cannot borrow a stale automatic subject. Home and Work use natural lowercase
  modifiers in fallback titles. Existing `suggestedText` remains the backward-compatible persisted
  cache payload while the canonical schema is rolled through storage.
- Full verification: 193 tests, 10 opt-in skips, zero failures. No packaged-app deployment, live
  indexing, Photos mutation, or Google upload occurred.

## Clean canonical-narrative reset (2026-09-12)

- At the user's explicit request, a one-shot signed-app maintenance run enumerated only album
  containers directly beneath `Photo Curator/<year>` and deleted all 7 found containers through
  public PhotoKit. No photo assets were deleted. The temporary maintenance argument was then removed
  from source.
- Deleted the derived `~/Library/Application Support/Photo Relay/curator` tree without backup. The
  parent application-support directory fell from about 200 MB to 332 KB; Google credentials/config
  outside the curator tree were preserved.
- Removed `PhotoMoment.suggestedText` and all compatibility reads. `PhotoMoment.narrative` and
  `BackgroundCaption.narrative` now persist the versioned canonical `MomentNarrative` directly.
  Existing caches need no migration because the curator state was intentionally reset.
- Updated corpus/report tests to consume canonical headline/story/provenance. Full verification:
  193 tests, 10 opt-in skips, zero failures.

## Honest title-preparation UI and place management (2026-09-12)

- Removed the repeated `A look back at ...` placeholder from both presentation fallback and local
  narrative candidates. Until grounded narrative evidence arrives, a card keeps a neutral date/place
  heading and shows `Title preparation is in progress...` as a smaller amber status.
- Once a narrative exists, the status distinguishes remaining highlight preparation instead of
  implying that the visible title is still a placeholder. Customized and unresolved states retain
  their existing precedence.
- Significant Places in Settings now have explicit Edit and Delete buttons. Editing preserves the
  stable place identity and saved coordinate unless the user deliberately chooses a new search result
  or current location; label, address/venue, and matching radius remain editable.
- Full verification: 194 tests, 10 opt-in skips, zero failures.

## Utility-priority title preparation (2026-09-12)

- After metadata reconciliation, local Vision, OCR, highlight, and narrative preparation now continue
  in a utility-priority task while the Mac is in use; they no longer wait for two minutes of system
  idle before replacing title placeholders.
- Low Power Mode, thermal pressure, and active export/sync still pause this work. Automatic Photos
  album publication remains gated on system idle (or an explicit foreground priority run), keeping
  externally visible changes separate from low-priority local preparation.
- Full verification: 194 tests, 10 opt-in skips, zero failures.

## Foreground analysis starvation fix (2026-09-12)

- Live telemetry exposed a scheduler loop after a prioritized range completed metadata: the active
  foreground flag repeatedly re-entered the already-finished 2,659-photo metadata pass every two
  seconds, preventing the visual queue from running. At diagnosis, only 341 of 109,182 jobs were
  complete and 108,841 remained pending.
- Metadata scheduling now distinguishes an incomplete foreground scan from a foreground analysis
  session. Once metadata is ready, that session advances to utility-priority Vision/OCR/narrative
  work; explicit library reconciliation can still request a metadata pass independently.
- Added a regression test for the completed-foreground transition. Full verification: 195 tests,
  10 opt-in skips, zero failures.

## Continuous utility analysis (2026-09-12)

- Removed the timer-imposed pause between visual jobs. After one single-flight PhotoKit/Vision/OCR
  unit completes, the controller yields and immediately re-enters its policy gate before claiming the
  next job instead of waiting for the next two-second timer tick.
- The gate still checks authorization, sync, Low Power Mode, thermal state, metadata reconciliation,
  cancellation revision, and idle-only publication between every photo. The chain stops when caught
  up or when a failure occurs before a job is claimed, avoiding a tight retry loop.
- Concurrency remains one because the current thumbnail loader intentionally supports one outstanding
  PhotoKit request. This improves utilization without weakening analysis scope or introducing request
  races. Full verification: 196 tests, 10 opt-in skips, zero failures.

## Non-blocking startup reconciliation (2026-09-12)

- A populated curator index is usable immediately after launch; rebuilding or relaunching no longer
  makes the full PhotoKit metadata pass block visual analysis and title preparation.
- PhotoKit is still reconciled newest-first in bounded maintenance slices, with visual work between
  slices. Completing that generation still removes stale assets safely.
- A genuinely empty index continues to require its first metadata pass before analysis, so the
  pipeline never works from a missing catalog.
- Full verification: 196 tests, 10 opt-in skips, zero failures.

## Incremental presentation refresh (2026-09-12)

- Moment preparation now distinguishes structural grouping changes from presentation-only narrative
  changes. A new title or highlight state updates only the affected visible card instead of rebuilding
  grouping across the full 109k-photo index.
- Removed the periodic full catalog refresh after ordinary photo-analysis completions and intermediate
  metadata batches. Full refreshes remain for structural changes, completed reconciliation, explicit
  user operations, and final catch-up.
- The targeted refresh reuses persisted analysis and narrative evidence and recalculates selection for
  only that Moment. Full verification: 196 tests, 10 opt-in skips, zero failures.

## Deletion-time place resolution fix (2026-09-13)

- A live sample after deleting all photos from a Moment found the main thread spending nearly all of
  its time in place extrapolation. Every Moment independently filtered the full visible photo set by
  calendar day, producing quadratic work, more than 17 GB of resident memory, and an unresponsive UI.
- Place enrichment now builds one GPS-by-day index and gives each Moment only its relevant day. All
  refresh triggers share one cancellable task, so successive PhotoKit and activation notifications
  replace stale work rather than stacking duplicate passes.
- The runaway process was stopped without changing Photos. The curator index had already reconciled
  the deletion correctly. Full verification: 196 tests, 10 opt-in skips, zero failures.
- A second live sample found another allocation spike during overview refresh: representative
  selection repeatedly unarchived the same Vision feature prints inside its pairwise scoring loops.
  Each candidate's feature print is now decoded once per Moment selection pass and reused without
  changing similarity scoring or shortlist behavior.

## Moments keyboard navigation (2026-09-13)

- The Moments grid now maintains a visible keyboard cursor. Arrow keys move between cards, Return
  opens the active Moment, and Space enters selection mode and toggles the active Moment.
- While selecting, users can continue navigating and toggling with Space; Return opens the existing
  merge confirmation when at least two Moments are selected. The key handler is scoped to the main
  Moments window and does not intercept typing or review-window controls.
- Return commits and closes Moment review. Escape restores the title, description, and local photo
  inclusion choices captured when the review opened, then closes it. Confirmed Photos deletions and
  Favorite changes remain external system operations and are intentionally not rolled back.
- Merge review exposes selectable source names and live matching title suggestions; native macOS
  text editing and spell checking remain available in the title field.
- Cursor movement now scrolls the grid to reveal the active Moment. Escape exits selection mode and
  clears its selected IDs and range anchor when no modal review or merge sheet is handling Escape.

## Durable PhotoKit reconciliation checkpoint (2026-09-13)

- A normal launch no longer unconditionally walks every image in Photos. After a completed full
  reconciliation, Photo Curator stores an atomic checkpoint containing the public PhotoKit image
  count, a small newest-assets fingerprint, and the full-verification date.
- Startup trusts the existing SQLite catalog when that fingerprint still matches and the checkpoint
  is less than seven days old. Visual/OCR work can resume immediately without a 109k metadata pass.
- Curator-owned deletion and Favorite changes update the affected SQLite record directly, then
  refresh the checkpoint fingerprint. Incremental `PHPhotoLibraryChangeObserver` updates do the same.
- A full reconciliation remains fail-safe when the fingerprint differs, PhotoKit reports a
  non-incremental change, the checkpoint is missing, or seven days have elapsed. Its status now says
  `Checking library changes` rather than suggesting cached photos are being analyzed again.
- Existing installations migrate without one extra full pass when the populated SQLite count exactly
  matches PhotoKit at first checkpoint-aware launch; the normal seven-day verification still follows.

## Google Photos Favorites and album maintenance (2026-09-13)

- Save to Google Photos no longer requires selecting a Moment. With no Moment selection it opens in
  library-wide Photos Favorites mode and exports the current public PhotoKit Favorites collection.
- Existing app-created Google albums can receive appended photos through the existing reviewed sync
  flow. The destination sheet now makes that behavior explicit.
- A confirmed Clear Album action removes all media membership visible to Photo Curator from the
  selected app-created album and verifies the result. Photos remain in the Google Photos library;
  inaccessible items remain untouched. The supported Google Photos API does not offer account-wide
  media deletion, so Photo Curator does not claim to provide it.

## Holistic library curation audit (2026-09-21)

- Audited the full current catalog as one family photographic history: 108,999 photos, 5,224 Moments,
  and 14,279 highlights.
- The flat catalog is polarized. Moments of at most three photos are 56.6% of all Moments but only
  4.3% of photos; Moments over 100 photos are 5.1% of Moments but hold 63.9% of photos.
- Capture density is strongly seasonal. July and August hold 41.1% of photos and average about 49-62
  photos per active shooting day, versus about 12-16 in several quieter months. Historical GPS
  availability also varies sharply and cannot be treated as a stable absence signal.
- Added `HOLISTIC_LIBRARY_AUDIT_2026-09-21.md` and expanded the stabilization plan with a minimal
  `Story -> Moment -> Highlight` hierarchy, adaptive local-density boundaries, hierarchical highlight
  budgets, a Library Overview, and measurable shadow curation generations.
- Maintenance is now separated into a normal versioned curation rebuild, full evidence reanalysis,
  and the destructive clean-room reset. This preserves a convenient full rerun without making catalog
  deletion the algorithm-development workflow.
- Research-alignment review tightened the plan: Stories are optional and evidence-gated; calendar,
  season, and place are views rather than semantic Stories; seasonality cannot change event
  boundaries; false joins cost more than false splits; highlight dimensions remain separately
  visible; and an owner-reviewed benchmark is frozen in Phase 0 before migration. Alpha owners judge
  family meaning while independent reviewers judge engineering and usability.
