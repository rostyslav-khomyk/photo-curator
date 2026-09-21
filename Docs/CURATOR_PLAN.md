# Curator Plan

## Architecture stabilization proposal (2026-09-21)

The current product plan is now complemented by
[`ARCHITECTURE_STABILIZATION_PLAN.md`](ARCHITECTURE_STABILIZATION_PLAN.md). That proposal is the
authoritative next-work plan for persistence, concurrency ownership, UI responsiveness, migration,
performance gates, versioned full-library curation, a safe nuclear reset, and closed-alpha
qualification. The measured family-library baseline and proposed optional
`Story -> Moment -> Highlight` model are documented in
[`HOLISTIC_LIBRARY_AUDIT_2026-09-21.md`](HOLISTIC_LIBRARY_AUDIT_2026-09-21.md). Feature work should
remain paused until the stabilization plan has been independently reviewed and its Phase 0 baseline
is accepted.

## Current Checkpoint: Full-Library Moments Are Reachable (2026-09-21)

- The persistent index covers 108,999 Photos assets and is not rebuilt after ordinary app
  recompilation when the library checkpoint still matches.
- The Moments workspace now exposes the complete prepared catalog without a manual
  "Load older moments" action. Live verification reached all 5,224 Moments and the oldest
  collection dated August 25, 1998.
- Catalog extension prepares only the new suffix, while real PhotoKit metadata edits still
  invalidate the affected projection. Resource-only PhotoKit notifications no longer force
  a catalog rebuild.
- Scroll position remains persistent. Thumbnail work is held until a deep restored anchor
  is in place, avoiding a burst of off-screen preview requests.
- The 32 MB derived-catalog ceiling that caused the misleading
  `PublicationFailure error 0` was raised to 96 MB; the verified full catalog is 56.5 MB.
- Verification: 202 tests, 10 opt-in skips, zero failures; release build deployed.

Next quality work should assess old-library titles, boundaries, and highlight choices. Do
not clear the index merely to evaluate those results: the full-history catalog and local
evidence are now available for longitudinal review.

## Current Checkpoint: Grounded Place Narratives, Multi-Candidate Suggestions & Accessible Review UI (Chunk 10) (2026-09-11)

Completed and polished Chunk 10 (Local Narrative Model & Grounded Text Generation):
- Integrated reverse geocoding into title and story generation: `BackgroundMomentContext` and `MomentNarrativeSheet` now pass resolved place names (direct GPS or extrapolated) into `MomentNarrativeMetadata`.
- Enhanced `LocalMomentNarrative.candidates(_:)` to generate location-grounded titles (*"Food and dining in Fréjus"*, *"Fréjus · Aug 29, 2026"*, *"Fréjus in pictures"*) and narrative descriptions with zero robotic disclaimers.
- Promoted "Suggest Title & Story…" to a primary button in `MomentReviewView` next to the title field (previously hidden behind `advancedTools: false`).
- Replaced the single suggestion view in `MomentNarrativeSheet` with an interactive multi-candidate suggestion list offering 1-click adoption (*"Use Title"*, *"Use Story"*, *"Apply Both"*).
- Applied full font accessibility across `MomentNarrativeSheet` and `MomentTextEvidenceView` linked to `@AppStorage("curator.fontSizeScale")` for glasses wearers.
- 177 tests executed, 10 opt-in skips, 0 failures. Single batched release build completed via `Scripts/build_app.sh`, code signature verified, and relaunched at PID 49623.

## Previous Checkpoint: Photographer Persona UI Cleanup, macOS ? Help Popovers, Resizable Review Sheet & Reverse Geocoding (2026-09-11)

Redesigned the Photo Curator interface for family photographers:
- Completely eliminated robotic disclaimers across the entire app (`"place not verified"`, `"unverified venue"`, `"pilot"`, `"logging is on"`, `"kept for context"`).
- Replaced database actions with photography-first terminology: `"In Moment: Curator's Pick / Always Include / Hide from Moment"`.
- Added native macOS Settings-style `?` help popovers to the Moments workspace and Review dialog headers, reassuring users that Apple Photos library originals are read-only and never modified or deleted.
- Made the "Review Moment" sheet smoothly resizable via an interactive diagonal corner drag grip (`SheetResizeHandle`), persisting custom window dimensions in `@AppStorage("curator.reviewSheet.width/height")` across launches.
- Integrated native macOS `CLGeocoder` with persistent local caching and a multi-signal same-day timestamp extrapolation engine ($\ge 0.70$ confidence) for photos without GPS, falling back gracefully to clean dates and activities.
- 171 tests executed, 10 opt-in skips, 0 failures. Single batched release build completed and verified via `Scripts/build_app.sh` (`dist/Photo Curator.app`, strict deep code signature verified). Relaunched at PID 44819.

## Representative Selection Compaction and Robust Context (2026-09-11)

Implemented RepresentativeSelector in MomentSelection to resolve oversized display
shortlists (such as the 99/149 and 137/587 collections observed in the August pilot).
Bounds automatic selections to curated budgets (natural <=20, 20 for 20..60, 25 for 60..200,
max 35 for >200) using uniform temporal quantile distribution across visit duration.
Prioritizes Favorites and aesthetic scores while keeping role coverage intact; unselected
candidates safely move to alternatives with clear explanations, preserving user choices.

Updated BackgroundMomentContext to collect all available cached evidence rather than blocking
on 100% completion across sampled photos. Requires min(sampled, 4) analyzed photos to prepare
early grounded captions, refreshing automatically as remaining evidence settles.

Integrated into CuratorController display pipeline. 165 tests executed, 10 opt-in skips,
zero failures. Single batched release build completed and verified via Scripts/build_app.sh
(dist/Photo Curator.app, strict deep code signature verified).

## Discovery and Explicit Moment Merge (2026-09-11)

Chunk 2 implementation now includes feed promotion plus evidence-gated reconciliation
of adjacent automatic scene sections within each parent visit. Continuity v2 accepts
non-overlapping gaps 0..3 hours, retains same-day/6-hour-span/512-member bounds, two
distinct matches, agreeing recorded GPS, conflict/utility/compressed-time checks,
no chaining or skipping intermediates, and manual-review protection. No missing-GPS
heuristic or broad similarity threshold relaxation. This is NOT a claim of Memories
quality; real-output acceptance remains part of production validation.

Workspace: Select Moments, independent toggle clicks, Shift-click ranges in displayed
order, Merge Selected confirmation with required editable name and source names/text.
Atomic revision-checked merge gets a fresh ID, preserves existing unavailable saved
members and original text provenance, per-photo choices untouched. Reviewed membership
wins over future automatic grouping. No Photos or Google mutation. Main and More
Collections participate; collapsed collections are not implicitly range-selected.

160 tests executed, 10 opt-in skips, zero failures. Targeted MomentMergeTests rerun
passed (3 tests, 0.009s). Combined release build completed and verified via Scripts/build_app.sh
(dist/Photo Curator.app, strict deep code signature verified). Bundles permission-safe guard,
feed promotion triage, continuity v2, and workspace range-selection/merge. Live merge is user
acceptance: no real user Moments merged by the agent merely to test the control.

## Current Implementation Checkpoint (2026-09-11)

Startup authorization guard implemented: keep saved projection until authorized; live
permission-cycle acceptance pending. Feed promotion first slice implemented: More
Collections retains unendorsed singletons/empty/unprepared selections without deleting
or merging. Favorite/Include/user-text/review protection; pairs remain eligible.
155 tests executed, 10 skipped, zero failures. Not deployed; August pilot left running.
This only starts quality chunk 2. Stronger semantic continuity, large-shortlist quality,
grounded titles, long-run validation and final Photos publisher/sync remain unfinished.

## Active Checkpoint: Logged Native Pilot Deployment (2026-09-11)

Consent follow-up: access recognized at 12:29 UTC; waiting reason changed from 1
(permission) to 5 (activity). Catalog returned to 446 automatic selections with zero
pending. Only native app remains running; pipe helper stopped. Keep August scope.
Metadata-only audit: 27/47 candidates have <=2 photos, 25 date-only suggested titles,
one zero-selection candidate; largest shortlists are 99/149 and 137/587. Next quality
work should evaluate candidate promotion and representative selection across multiple
collections, not expand indexing or tune one palace example. Preserve custom edits.
Startup bug to fix/test before next deployment: refreshOverview recomputes and persists
selections before Photos authorization; category lookup returns empty and falls back
to indexed categories. Preserve saved projection until authorized rather than exposing
temporary recommendations. The observed 437->446 recovery is consistent with this path.

Live result: August pilot completed 1,132 photos, zero deferred/pending, 47 Moments
and 16 singletons. Initial automatic selection count 446; final relaunch restored 437.
Investigate that difference during quality audit, not as an assumed improvement.
Final release/name cleanup deployed and signature verified. Relaunch preserved enabled
bounded pilot and catalog, but macOS requires Photos consent again (waiting reason 1).
User notified; final UI/album-loading recheck is outstanding due UI automation failure.
Next: after consent, inspect logged output and representative Moment quality before
expanding pilot dates. No album creation, uploads, or full-library expansion yet.

User authorized deployment and unattended bounded background pilot, logging, native-only
cleanup, and rebranding. Visible name is Photo Curator; bundle ID, executable, existing
support/log paths and credentials stay stable. Icon now uses a curator sparkle, not relay
arrow. Dashboard opens Moments. Pilot defaults curatorPilotStart/End constrain metadata,
analysis, text and preparation requests; intended month August 2026. UI shows dates.

Native Google transport now uses stdin/stdout request/reply to existing sync handlers.
No Waitress listener, legacy page routes inaccessible, template/static assets excluded
from native build. CLI web functionality remains in repository for CLI users. Engine
starts on demand for startup credential validation or user sync and stops when operation
ends; kept alive through sync review/upload/abort. OAuth can still use a temporary callback.
Google sync is NOT automated. No Photos albums created.

Counts-only rotated curator.jsonl (1 MB + three archives, 0600) records launches,
metadata/analysis/catalog progress, completion, failure codes and throttled wait reasons.
No OCR, pixels, GPS or tokens in curator telemetry. Derived Moment catalog and existing
private evidence caches support later content evaluation. Wait codes: 1 permission,
2 sync, 3 low power, 4 thermal, 5 activity/idle. Live acceptance results follow deployment.

Tests: 154 Swift tests, 10 opt-in skips, zero failures; 20 targeted Python tests passed.
Packaged engine pipe probe returned 200 and exited without serving HTTP. Build/deployment
must be verified before claiming the pilot is running. Earlier checkpoints are historical.

## Active Checkpoint: Full Shortlist and Conservative Variety Pass (2026-09-11)

Reviewed actual 25-photo full-visit shortlist. Coverage is reasonable, but gallery,
corridor and lake-view repetition remains. Added bounded ScenerySelection after balanced
selection: shared scenery clue, zero detected faces/no people labels, recorded GPS <=150m,
valid aesthetics and existing scene distance cutoff. No chained suppression. Favorites
and explicit Include preserved; alternatives are not duplicates or deletions.

Real reruns remain 25 selected / 624, 26 context-only; sample role audits unchanged and
passing. Do NOT claim observed repetition is fixed. Gallery pair GPS differs ~1970m;
corridor pair has missing GPS; lake-view pair differs ~194m. Next needs an explicit
uncertainty-aware policy and positive/negative examples before relaxing location guards.
No silent GPS rewriting to make this example pass. February not rerun or tuned.

Full suite: 152 tests, 10 opt-in skips, zero failures. No deployment/live restart.
Signing precheck: zero valid identities; ad-hoc builds may re-request Photos consent.
curatorEnabled remains 0. Exact shortlist reports and private rendering now reproducible.

Older active headings below are historical.

## Active Checkpoint: Reviewed Sample Quality (2026-09-11)

Added evaluation/QUALITY_CRITERIA.md and an opt-in production-selection audit against
private provisional role annotations. Reinspected only approved C03/C05 contact sheets.
Palace sample: 11/20 selected, all four annotated roles represented, map not selected.
Restaurant: 4/16 selected, all three roles represented, no annotated menu pages selected.
Actual selections were cross-checked against those sheets. No selection/grouping rules
changed; singletons are not suppressed based on count. Sample role coverage is not full
story/composition acceptance and is not user-approved ground truth.

Next bounded acceptance work: review the full large-visit shortlist (not just the sample),
then deployed UI/Favorites/manual corrections and controlled indexing restart. Existing
structural gate and sample-quality evidence support proceeding to that acceptance work,
not declaring all remaining quality questions solved. Live indexing remains paused.

Earlier active headings below are historical checkpoints.

## Active Checkpoint: Real-export Structural Gate (2026-09-11)

Fresh on-device Vision/OCR evaluation of all 624 C03 copies and all 684 February holdout
copies passed in 153 seconds. Source hashes verified; temporary indexes removed. Large
visit: 1 -> 1 parent, 25 selected, 26 context-only, six preparation steps. Holdout: 53 ->
53 groups, 111 selected, 36 context-only, 68 steps. Complete unique membership and stable
restart IDs in both; no still-preparing groups. Large parent remains conservative.

This is NOT curation-quality acceptance. Holdout has 19 singleton groups; no independent
event labels establish whether its 53 groups are appropriate. Selection is still a
30-minute/type/location coverage heuristic, not semantic variety. Export Favorites and
PhotoKit categories are unknown; no live model used. February is now evaluated, no longer
an untouched holdout. Do not tune to these results then claim independent validation.

Next: define and review meaningful-Moment/selection quality criteria and evaluate
representative output against them before controlled deployment/indexing restart.
No production grouping rules changed during this frozen validation. App not redeployed,
live indexing remains paused, no Photos writes or network research.

Previous active checkpoints below are historical.

## Active Checkpoint: Large-Moment Worker Integration (2026-09-11)

The worker now analyzes one bounded internal window per large-parent visit, cycling
through all windows even when evidence is missing. Records fingerprint actual Vision,
classification and OCR inputs, not just photo metadata. Changed evidence refreshes a
checkpoint; missing evidence invalidates it. Cancellation, metadata generation and saved
group-review revision are checked before writes. Restart reuses completed records.

Catalog projection retains one full parent and reports completed internal sections.
Completed processing remains conservative: local section findings are not proof of one
event, and cross-window semantic reconciliation is not implemented. Named parents and
protected legacy children bypass automatic refinement. No new UI or Photos writes.

Synthetic 624-photo worker tests cover restart, full membership, evidence refresh and
missing-first-window non-starvation. Full suite: 147 tests, 8 skipped, zero failures;
production build passed. Next gate: real 624-copy
local evaluation, development metrics, untouched February holdout and controlled
release/relaunch acceptance. Live indexing remains paused. Quality failures may require
another correction chunk; do not resume solely because synthetic tests pass.

## Previous Checkpoint: Large-Moment Work Windows (2026-09-11)

LargeMomentWindows and LargeMomentWindowStore now provide deterministic 256-photo
ownership windows with two context photos on each side, separate atomic internal records,
restart recovery and parent-metadata invalidation. The synthetic 624-photo test covers
every asset exactly once in ownership; overlap is context only. Internal IDs are never
published as Moment IDs. Full suite: 145 tests, 8 opt-in skips, zero failures.

This is a foundation subchunk, NOT completed large-Moment pipeline support. The worker
still has its 512-photo guard. Next: connect one bounded window per worker step, defer
missing evidence without starving other windows, check current evidence/review revisions
before committing, aggregate internal findings into one stable parent, and test the real
624-photo export locally. Metadata fingerprints alone must not be treated as sufficient
for changed cached evidence. Then run the holdout/release acceptance gate below.
No live indexing or app deployment was performed.

## Previous Checkpoint: Event Continuity (2026-09-10, evening)

Evidence-aware captions and context/display separation are implemented. Roles persist in
the derived catalog; context-only photos stay indexed and reviewable, but cannot displace
display photos during similarity selection or silently become cover fallbacks. Favorites,
explicit Include/Exclude, user titles and reviewed membership retain precedence. The normal
workspace has a collapsed Kept for context section; no new setup or diagnostic workflow.

Soft event continuity is now integrated before internal segmentation, paging and priority
selection. The real 16-copy restaurant test resolves 13+3 into one complete Moment, retains
its identity after restart and retracts the join when synthetic contradictory evidence is
introduced. Saved splits/names win. The bounded rule is provisional, not venue verification.

Two estimated chunks remain before live indexing resumes:
1. Bounded large-visit refinement beyond 512 photos, with stable parent identity and coverage.
2. Development metrics, untouched February holdout, release/relaunch acceptance and controlled
  restart. Validation failures may require a correction pass before resuming.

Live curator remains disabled; no new index, app deployment, Photos changes or network
research. Google Photos sync only; GCP/Gemini/cloud-platform research was removed. Photos
album creation is still last and separate from indexing readiness. Earlier dated checkpoints
below are historical; their former 'next', cloud setup and implementation status are superseded.

## Latest: Full-scope Saved Group Projection (2026-09-09)

Saved split/merge/names now drive main Moment cards and background caption membership.
Applied before paging or priority-range selection. Group save refreshes catalog. Existing
manual title overrides remain authoritative; automatic remainders cannot inherit old whole-
group identities. Tests cover full-scope projection, stable IDs and unique asset coverage.
Next: automatic semantic segmentation with evidence/confidence, while preserving this
manual precedence. No new automatic grouping algorithm landed in this checkpoint.


## Latest: Automatic Local Caption Stage (2026-09-09)

Local Vision classification + cached model-selected caption drafts now run automatically
under the idle/priority policy across indexed groups. Derived captions are distinct from
manual corrections and surfaced on cards. Grouping remains time/GPS-based, not semantic.
See latest development record for persistence, bounded sweep and fallback retry behavior.

Google verification progressed: enabled only Cloud Billing API; readback confirms the
existing project HAS billing enabled. No billing settings changed and no model requests.
Free-only research needs a separate unbilled project, pending user answer. Never disable
the existing project's billing or introduce paid fallback to solve this.


## Current Checkpoint: Collection-first Workspace (2026-09-09)

Implemented: cover-card Moments catalog, priority sheet independent of browsing,
native general Settings with optional web privacy toggle, diagnostics removed from
everyday flow, derived persistent catalog snapshots, newest-first analysis, automatic
OCR plus cached-results backfill. No Photos writes. See latest development record.

Free-only provider guard and 50/day persistent cap implemented; real billing-status
probe returned 403. Research remains paused, no paid fallback. EEA eligibility still
requires resolution. Do not broaden scopes or enable billing to hide this condition.

Next integrated stages: persist semantic group identity and evidence; automatically
consume cached OCR/classification/local LLM for grounded draft text; protect manual
split/merge/title edits during reconciliation; add meaningful questions only when
useful. Then wire eligible free-only research with cache/citations and cooldown.
Current cards are time-based candidates with honest incomplete-context status, not
Apple Memories-quality completed Moments. Snapshot persistence is not full pipeline
job persistence. Do not mistake moving tools to Diagnostics for finishing those stages.


Workflow acceptance is now part of every milestone: see WORKFLOW_ACCEPTANCE.md.
Permission-to-content transition fixed for Photos sidebar (launch, consent, Settings
return, deferred load after sync). Do not treat standalone test dialogs as finished
user workflows; document untested transitions explicitly.


## Unified Startup Access Correction (2026-09-09)

All Google access checks now use GOOGLE_APP_SCOPES: openid, Photos append/read/edit
app-created data, and cloud-platform research. One incremental consent, not separate
Photos/research setup. Startup checks Google noninteractively and PhotoKit full access,
then shows one recovery alert only for missing/revoked access. Continue requests Photos
or opens Privacy Settings and runs combined Google consent if needed. Not Now dismisses
for this launch. Busy restored uploads defer this check until idle. Temporary refresh
errors keep tokens and do not trigger consent; invalid_grant is classified as revocation.
This supersedes the separate research consent workflow below. Paid research stays off.


## Google Research Checkpoint (2026-09-09, supersedes access notes below)

User approved cloud Gemini processing of approved non-sensitive text clues, with
photos/names/precise GPS local and paid requests disabled pending cost agreement.
Implemented text-only Google interactions/search provider, bounded response parsing,
citations retained as unverified context, no automatic retries or worker consent UI.
Shared OAuth requests union of old/new permissions and checks partial grants.
Research Settings connects incrementally; no live research route is exposed yet.
Startup checks Photos-sync Google token noninteractively after upload restoration.
Photos access banner and signing support from earlier checkpoint remain included.

Next: choose/configure a supported project/model and explicit cost policy, implement
approved-public-clue extraction/review, persistent cache/queue with provenance and
provider attribution UI, then wire into automatic Moments. Do not set cost_authorized
from arbitrary client JSON. No Google project APIs/billing were enabled by this task.
Current provider is a tested building block, NOT active background enrichment.


## Active Request: Google Enrichment and Startup Access (2026-09-09)

Photos access banner implemented: check public authorization state, offer initial
request or Privacy Settings only when full access is absent, recheck on activation.
Build supports PHOTO_RELAY_SIGNING_IDENTITY and verifies its signature. This Mac has
no valid signing identities; ad-hoc signing remains the fallback and cannot promise
permission persistence. Not redeployed yet.

Google web enrichment is NOT implemented. Research confirms Gemini supports OAuth
and Google Search grounding, but this adds cloud-model text processing and project
configuration/possible billing, not merely another Photos scope. Obtain agreement
on this boundary before enabling requests. Preserve local-first analysis, never send
private OCR/names/precise GPS or images by default. Reuse existing login with incremental
consent only for the chosen provider; startup should refresh noninteractively and must
distinguish offline/service errors from revoked credentials. That Google startup check
is still pending. Do not mark the whole authentication request complete.

Sources: https://ai.google.dev/gemini-api/docs/oauth and
https://ai.google.dev/gemini-api/docs/google-search


Newest checkpoint: persistent split/merge/name review implemented in Suggest Groups,
explicit Save Groups, stable member-based overrides across rescans, conflict-safe local
archive and preservation of out-of-range members. Local specific scene clues now aid
grouping; generic labels cannot broaden matches. Real exported set: 20 groups, not yet
complete trip/event curation. Saved groups currently surface inside Suggest Groups,
not as replacements in the top-level Moments list. UI acceptance after relaunch remains
next, followed by top-level reviewed-group integration and broader semantic validation.

Newest checkpoint (2026-09-09): experimental Suggest Groups preview in Moment Review.
Time/fixed-anchor visuals/GPS conflict checks; OCR matches as supporting explanations;
direct GPS-source provenance and suspicious-timestamp guard. Default distance 16 after
real exported-photo calibration; 21 visual groups for 29 mixed-scene photos, NOT full
event grouping. UI has zoom, resize, threshold/reset, group counts and warning. No
saved group edits, background regrouping, album writes or sync changes. Validation:
79 tests / 4 skipped / zero failures; separate real-export grouping test passed.
See development record for limitations and remaining semantic/split-merge work.

Latest checkpoint (2026-09-09): on-demand local OCR evidence in Moment Text via
"Inspect Text in Photos". Per-photo revision/OS-version cache, source thumbnail zoom,
recognition confidence and editable user-selected caption clue. No automatic place
verification, network calls, background OCR or library writes. Tests: 69 total,
3 opt-in skipped, no failures; separate 30-export OCR acceptance passed. UI acceptance
after relaunch remains pending. See development record and August 30 case study.

Next: use OCR evidence with credible time proximity, distinctive scenery continuity
and GPS anchors for proposed grouping. Retain inferred-versus-recorded provenance;
do not propagate coordinates into Photos or through chains of inferred anchors.
Conflicting GPS/landmarks and suspicious imported timestamps reduce confidence.

Latest narrative correction: local Vision labels now inform cautious caption candidates;
real exported-photo backend smoke passed. Live UI verification blocked by CUA connection;
do not claim the reported empty suggestion sheet reproduced or fully resolved yet.

Newest deployed checkpoint: local narrative Suggest Text UI in moment review, explicit
draft/apply/save and description persistence. Ready for user acceptance after rebuild.
Next integration priorities: full-scope stable identity migration, then publisher preparation;
real Photos writes stay deferred. Narrative semantic understanding remains limited to metadata.

Local narrative checkpoint: real Apple FoundationModels adapter, grounded candidate
selection, bounded persistent cache and deterministic unavailable/error fallback. Tested with
synthetic metadata; UI/background wiring and richer controlled prose remain outstanding.

Newest backend checkpoints: scope-keyed stable identity resolver/archive and exclusive
publication journal locking/reload/cancellation tests. Identity resolver NOT wired to live
range previews; next integration needs complete-scope snapshots and legacy title migration.
Power-loss durability, aggregate retention and real-adapter soak testing remain open.

2026-09-08 backend-only checkpoints: publisher journal/recovery and sync handoff state
machines tested with fake adapters, disconnected from UI and Photos/Google. Chunks 8 and 9
are now started, NOT complete. Real Photos writes remain final. See development record for
remaining adapter, identity, locking, hierarchy and reconciliation requirements.

Latest: Balanced GPS coverage implemented (1 km anchor groups, unknown-location fallback),
with distant-place protection before similarity suppression. Next: evaluate real trips and
semantic diversity; no claim of complete Memories-equivalent selection. Photos writes LAST.

Newest selection checkpoint: opt-in experimental Balanced shortlist, preserving Favorites
and missing-quality photos while selecting time/type representatives. Alternatives remain
reviewable with manual overrides. Next evaluate real-trip usefulness before richer semantic
or location-aware diversity; publishing remains deferred.

2026-09-08 checkpoint: editable local titles and per-photo selection explanations added to
review. Next: human acceptance of review, then richer meaningful/diverse selection. Stable
identity across regrouping must precede publishing; current titles key to candidate anchors.

Review usability checkpoint: grid size, Fit/Square, type/Favorites filtering and larger
local-only individual photo preview. Next verify review choices and viewing with real library.

Latest implementation: durable thumbnail review is available per moment. Choices persist
locally by asset ID and affect displayed selection counts; no publication or sync handoff yet.
Next acceptance: review a moment, change choices, restart, verify persistence and Automatic.

Production follow-up accepted by user: broaden calibration sample discovery independently
of the 60-second suppression rule and show analysis coverage. Sparse samples acceptable
for current testing. Next active checkpoint: durable per-photo thumbnail review choices.

Newest checkpoint: public PhotoKit media-type calibration, Previous/Next pairs, enlarged
zoom comparison. Recheck Documents/Receipts/Handwriting public availability when a future
SDK ships; keep private database route parked. See development record for overlap policy.

Latest checkpoint: similarity calibration dialog with live boundary thumbnail pairs and
versioned Apply/Cancel settings. See CURATOR_SIMILARITY_RESEARCH.md for research and limits.
Next: durable thumbnail review decisions and real-pair calibration; Photos publication LAST.

Status: implementation authorized, 2026-09-07. Chunk 1 capability checkpoint and chunk 2
queue storage, chunk 3 thumbnail loader, and chunk 4 Vision layer completed in isolation.
See CURATOR_CAPABILITIES.md and CURATOR_DEVELOPMENT.md.
Queue is tested in isolation, not yet wired to scanning/image analysis.
Read alongside CURATOR_DEVELOPMENT.md, which records shipped code and verification.
This document records agreed requirements separately from proposed implementation.

## Agreed Experience

- Recreate the useful curation experience of Apple Photos/Apple TV Memories, not its
  movie/music presentation or an exact copy of Apple's private selection engine.
- Prepare meaningful, varied collections in the background across the library back to
  1998. Immediate date-range requests take priority, reusing saved analysis.
- Publish ordinary Photos albums referencing existing assets so they can feed the
  Google Nest Hub frame through the existing Google sync workflow.
- Local Vision and a local language/vision model should help select, understand, and
  title collections. Aesthetics alone must not dominate meaningful people and events.
- Optional internet context follows local analysis and text-only research. Uploading an
  image for identification is a last resort, governed by rules approved once, not a
  confirmation for every eligible lookup.
- No photos containing faces may be sent for background research. Perform privacy
  checks locally; strip embedded metadata; do not automatically blur faces as a workaround.
  Skip external image research if checks fail, are unavailable, or are uncertain.
- Face absence is not guaranteed by detection and does not establish GDPR compliance.
  Other identifiers and sensitive content matter. Keep text queries privacy-filtered too.
- Research restrictions are distinct from deliberate user-selected Google frame sync.
- Reuse the user's extensive Photos face labeling if feasible. Investigate OSXPhotos
  as an optional read-only local metadata source, not a direct database writer. Keep
  names/face associations local. Missing person labels never mean an image is face-free.
- Keep sources, confidence, and user corrections. Do not turn guesses into factual titles.

## Proposed Organization and Outstanding Choices

- Proposed Photos hierarchy: Photo Relay / Moments / Year / dated descriptive album.
  In our browser, separate My Albums and Photo Relay Moments by persisted ownership IDs.
- Raw metadata fragments stay in the index. Qualified sets can be published automatically
  once enabled; reviewed sets can use Save & Sync. Publication thresholds remain undecided.
- Still to decide: collection length and variety, trip vs day vs recurring-theme grouping,
  people preferences, video/Live Photo treatment, auto-publication limits, network budgets,
  iCloud-download policy, and how much personal location information text searches may send.
- Local model availability and OSXPhotos compatibility must be verified on the installed
  OS. Google Lens user-facing upload support is not proof of a supported automation API.

## Small Implementation Chunks (Proposed, Not Started)

2026-09-07 ordering change approved by user: all Photos library mutation, including
album/folder creation and updates, is the FINAL feature. Defer chunk 8 and the publishing
portion of 9 until read-only ingestion, curation, review and safety testing are validated.
Read-only real-library tests are now authorized; no album writes or external uploads.

Each numbered chunk is a separate stopping point. Split it further before starting if it
cannot reasonably include implementation, tests, and documentation in one short session.

1. Capability report: check installed SDK/model availability and optional face metadata
   reader compatibility without changing Photos. Deliver a documented capability matrix
   and graceful fallback decisions. No model download or library scan merely for testing.
2. Durable analysis queue: versioned per-asset jobs/results and edit invalidation with
   migrations. Test interruption/restart and priority changes using synthetic assets.
   Existing sync remains usable; no new UI claims of completed curation.
3. Bounded local thumbnail loading: cancellation, memory limits, missing/cloud-only states,
   explicit download policy. Test timeout/cancel paths without fetching the whole library.
4. Local Vision signals: cache face/privacy, aesthetics and similarity observations.
   Test unavailable requests and edited assets; no network behavior in this chunk.
5. Existing library context: optional read-only snapshot adapter with independently optional
   People, Places, user metadata (titles/captions/keywords/albums/Favorites), automatic
   categories (labels/activities/holidays/seasons/venues), capture types/bursts and stored
   scores. Reuse existing knowledge before new Vision analysis or internet research.
   Preserve source and availability per field; scores are advisory and must not be mixed
   with Vision's score scale without validation. User-entered metadata takes precedence
   over inferred titles. Names and precise/home locations remain local. Failures in one
   optional field must not erase other usable context or permit research uploads.
   Verify actual schema/dependency compatibility, consistent snapshot and PhotoKit ID mapping
   before enabling user-library ingestion. Burst/media basics should prefer public PhotoKit.
6. Meaningful set selection: combine time/place/similarity/quality/people with diversity.
   Test duplicate reduction, multi-day examples, missing metadata and stable identities.
   Evaluate human usefulness separately from deterministic unit-test correctness.
7. Review workspace: thumbnail selection, explanations, durable include/exclude/title edits.
   End with a useful local review feature even before Photos publishing is available.
8. Photos publisher: managed folder/year/album IDs and crash journal, edit reconciliation,
   rename/move/delete handling. Test fake PhotoKit adapter first; real writes require an
   explicitly scoped acceptance test. Never recreate albums blindly after unknown results.
9. Sync handoff: Save & Sync and managed album browser sections, reuse existing Add/Replace,
   Abort, progress and Google ID ledger. Test publication-success/upload-failure independently.
10. Local narrative model: grounded descriptions/titles and proposed queries from local
    evidence; unsupported-model fallback, cached versions, no invented people or locations.
11. Text enrichment: approved provider, query privacy rules, rate/cost limits, source/confidence
    records, cancellation and offline fallback. No image upload permission implied.
12. Last-resort image research: first establish a supported provider integration. Enforce
    one-time policy, local privacy checks, metadata stripping, minimized payloads, audit and
    revocation. Test all denial paths with a fake provider before any real outbound images.
13. Automatic publication and soak testing: opt-in continuous scheduling, storage ceilings,
    scan/analysis progress and recovery across long historical runs. Validate on a small
    approved real range before the full library. Keep existing manual sync independent.

Dependencies: 2 -> 3 -> 4 -> 6 -> 7 -> 8 -> 9 is the core offline-to-frame path;
5 enriches 6 but must remain optional. 10 -> 11 -> 12 is optional enrichment, not a blocker
for useful albums. Chunk 13 follows a stable publisher and measured selection quality.

## Usage-Limit-Safe Development Protocol

- Start each session by reading this plan and the latest development checkpoint; inspect
  actual files/status rather than assuming an interrupted change completed.
- Pick one small chunk, state its acceptance checks, and avoid unrelated refactors.
- Record a checkpoint after every significant edit, not only at the end of the turn.
  Include changed files, completed work, exact test commands/results, unverified behavior,
  known failures, pending processes, and the single next action.
- Keep unfinished capabilities disabled or unexposed. Build/package only from a verified
  stopping point; do not replace the user's working app with an unverified partial feature.
- A usage limit can interrupt at any time; no promise of an exact token allowance or
  guaranteed completion before it. Small durable checkpoints minimize lost context.
- Do not use reset credits, schedule continuation, or create separate tasks without an
  explicit request. Do not mark a chunk complete merely because the session is ending.
- Runtime safety is separate from development checkpoints: use local transactions for
  queue/results, and journals/reconciliation for Photos/Google external effects. A local
  SQLite transaction cannot atomically commit changes in those external systems.

## Research Grounding

- Apple Memories experience: https://support.apple.com/guide/tv/watch-photo-memories-atvb4928b087/26/tvos/26
- Vision: https://developer.apple.com/documentation/vision
- Similarity: https://developer.apple.com/documentation/vision/analyzing-image-similarity-with-feature-print
- On-device multimodal model: https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting
- Local face detection: https://developer.apple.com/documentation/vision/vndetectfacerectanglesrequest
- Read-only people metadata route: https://github.com/RhetTbull/osxphotos
- Google image-search UX (not an API guarantee): https://support.google.com/websearch/answer/1325808
- Identifiable personal data: https://commission.europa.eu/law/law-topic/data-protection/data-protection-explained_en
- Album folders: https://developer.apple.com/documentation/photos/phcollectionlistchangerequest
- Local transaction guarantees: https://www.sqlite.org/atomiccommit.html

## Latest Handoff

Latest selection checkpoint: conservative near-duplicate suppression and suggested/pending
counts implemented; 33 native tests passed. Next: thumbnail review with durable manual
include/exclude decisions, then calibrate broader quality/diversity on user-reviewed sets.
This does not complete the full meaningful-set selection milestone. Photos writes stay last.

Latest: queue-to-Vision runner connected via PhotoKit, with 31 native tests passing.
Small-range user acceptance of scheduler is next, then selection and thumbnail review.
No Photos mutations; album creation remains the final feature.

2026-09-07 correction: database/OSXPhotos integration is PARKED, not a prerequisite.
Use public PhotoKit inside Photo Relay with its Photos permission; no Codex Full Disk
Access required. Added explicit Moments > Test Local Photos diagnostic using 12 local
thumbnails and Vision. User-run acceptance remains pending. All Photos writes stay LAST.
Older database-adapter chunks below are historical proposals, not the active next step.

Chunk 5 broadened to library context. 5a now includes curator_context.py plus optional
context_components in curator_people.py: Places, user metadata, categories, capture flags,
and advisory scores. Per-field errors are isolated, including people failures. Thirteen
targeted tests cover both readers. No real-library access, dependency installation,
web endpoint, native consumer or app replacement.
Next action: 5b, validate a pinned OSXPhotos version against a controlled library fixture
before offering actual user-library import. Do not mark full chunk 5 complete yet.
Core selection may proceed independently if that optional compatibility work is blocked.
# Current scope decision: local curation, Google Photos sync only (2026-09-09)

User approved removal of Gemini/GCP web research. This supersedes older research
milestones and free-tier setup instructions below. Removed the provider, quota module,
Cloud OAuth scope, research settings and startup research consent copy. Google Photos
sync, app-created album permissions and identity scope remain. Local PhotoKit/Vision/OCR
and on-device narrative work remain in scope. Future web enrichment needs a separately
reviewed provider and is not part of the active pipeline.

Do not revoke saved Google tokens or delete Cloud projects: existing credentials may
still carry previously granted scopes, but this app no longer requests or uses Cloud
research permissions. Do not delete existing private caches simply as a migration step.
# Completed checkpoint: automatic grouping connected (2026-09-09)

The local grouping engine is now called by CuratorWorker's background/priority pipeline,
not a standalone diagnostic. Persistent projected collections feed the normal Moments
cards and local captions. Explicit split/merge membership and user text/selection are
preserved. Named/described groups pin identity across subsequent metadata regrouping;
legacy names are captured across the full available catalog, not just the visible page.
The processing loop requires a clean bounded sweep before reporting priority completion.

Validation: 100 Swift tests, 5 opt-in tests skipped, no failures. Separate opt-in test on
all 30 authorized August 30 exported originals passed using real local Vision/OCR and
temporary backend stores (no Photos access or mutation). It produced 2 collections,
29 afternoon photos plus 1 midday photo, with complete coverage and cached fallback
captions. Exported copies do not carry Photos favorite flags; this test does not validate
favorite-based ranking or live PhotoKit ingestion. No images or metadata sent online.

Remaining quality work: stronger venue/event grouping on interleaved/imported timelines;
the conservative rule found no defensible sub-boundaries in the 29-photo afternoon set.
Groups over 512 photos explicitly retain broad time/location grouping. Do not describe
these results as Apple Memories-quality or verified events. Automatic cross-day merging
is not implemented. Real app UI/relaunch acceptance remains separate from headless tests.
# Latest checkpoint: mixed-timeline scene refinement (2026-09-09, evening)

Supersedes the earlier 29+1 conservative test outcome for UNEDITED collections. Compressed
timelines now support repeated-scene sets using bounded fixed-reference comparisons plus
local scene clues and GPS conflict checks. Not a venue identification system. At least
three photos per set and two qualifying sets with >=25% coverage are required to subdivide;
uniform bursts and agreeing recorded locations remain together. Unassigned photos stay
explicitly unresolved, with no generated event caption. No two-photo fragment proliferation.

The private 30-copy fixture now yields garden scene (5), castle scene (3), unresolved
afternoon photos (21), and the separate midday photo (1). All assets retained exactly once.
These labels describe our test observations, not automatically verified place names.
The user's named/edited August 30 Moment is protected and is NOT regrouped by this update.
Do not ask them to reset their title/exclusions just to demonstrate new automatic behavior.

Presentation fixes included: user-authored Moments say Your edits saved, automatic title
does not repeat below their own title, card covers have no clipped timestamp row, full
titles on hover. Review thumbnails retain times. Strong scene labels are now retained
beyond generic top-four labels; derived evidence refresh is versioned and automatic.
Next quality gaps: interpreting the remaining 21 photos, combining scenes into verified
events/venues without inventing context, and filtering utility shots from the main feed.
Photos album creation and all network enrichment remain out of scope for this checkpoint.

# Active reference-driven evaluation (2026-09-10)

User requested a generated-state reset without backup, then supplied exported photos and
approved representative image inspection by the conversation AI. Reset completed; live
curation stays paused, manual corrections and Google sync state preserved. Do not resume
the live library or modify its albums as part of this evaluation.

Completed: read-only export audit, private manifest, 138-photo visual reference review,
684-photo February holdout, provisional selection/grouping notes and repeatable native
metadata baseline. Private dataset/report locations are recorded in CURATOR_DEVELOPMENT.
The references are agent proposals, not accepted user labels. Existing export folder
names must never become ground-truth grouping features or verified venue assertions.

Next bounded chunks:
1. Verify OCR/classification clue retention on selected real copies using existing app
   components. Keep model extraction/interpretation and template output limits distinct.
2. Separate context-evidence assets from display candidates; keep utility images indexed
   but out of automatic feed cards/covers, without discarding meaningful object collections.
3. Evaluate soft temporal boundaries with corroborating scene/location continuity. Include
   the restaurant gap case and counterexamples at the same location with separate events.
4. Support large visits through bounded internal sections without imposing the current
   512-photo semantic-refinement limitation on the user-visible Moment.
5. Measure reference grouping, representative coverage and unnecessary fragmentation;
   evaluate once on the untouched holdout after development cases stabilize. Preserve
   manual corrections, provenance and uncertainty. No public/Google photo research.

Evidence pilot completed on 66 approved samples: local OCR recovers useful named clues,
but background captions ignore the OCR cache and the model only chooses prewritten text.
Immediate next implementation is the attributed evidence-to-caption handoff, not another
SDK/model setup or a global similarity-threshold adjustment. Keep raw OCR/PII untrusted,
do not auto-verify place names, and do not spread one scene's context to every photo in a
mixed group. Current app behavior has been diagnosed and documented, not changed yet.

# Completed: evidence-to-caption handoff (2026-09-10, 09:08)

The production background path now combines local OCR with visual evidence instead of
passing only three generic labels. Deterministic sampling covers up to 128 photos across
the whole collection, waiting for both evidence caches. Repeated activity support creates
bounded meaningful caption choices; the on-device model selects among supported choices.
Fallback uses the same grounded candidates when the model is unavailable. This is not
free-form multimodal reasoning or verified event/place recognition.

OCR clues retain their source asset/revision and recognition confidence. Captions scope
a clue to one source photo, never every photo in a mixed set. Known screenshots cannot
contribute caption evidence; public PhotoKit screenshot flags are persisted at ingestion.
Private/instruction-like OCR is conservatively filtered. Missing/unknown metadata cannot
silently authorize a text clue. Updated evidence invalidates derived captions; manual
titles, selections and grouping corrections remain untouched. No new workflow dialog.

Verified on 66 approved exported samples: palace -> Art and interiors; restaurant ->
Food and dining with source-scoped business sign; mixed imports -> Scenes from this
collection, retaining park text only as an unverified clue. The sample pilot uses offline
fallback; a separate real Apple local-model smoke test passes with synthetic evidence.
120 native tests (7 opt-in skips), 2 separate reference tests, 4 audit tests and native
release compilation pass. The app bundle was not replaced or relaunched.

## Restart Estimate: Four Remaining Chunks

1. Display eligibility: separate context-only assets from frame/display candidates and
   automatic cards/covers. Screenshots, menus and maps remain indexed as appropriate;
   preserve meaningful object collections, explicit user choices and auditability.
2. Event continuity: soft temporal boundaries with corroborating scene/location evidence.
   Resolve the 13+3 restaurant split without merging separate same-location occasions or
   imported mixed venues. Keep scene sections internal, not one feed card per scene bin.
3. Large visits: bounded resumable internal sections for >512-photo groups, maintaining
   one parent identity, complete coverage, representative variety and corrections.
4. Validation and release: measure fragmentation/coverage on development cases, then run
   the untouched February holdout once. Check corrections/restart/consent/UI behavior,
   deploy the tested app and resume the live newest-first index in a controlled pass.

This is an estimate of three implementation chunks plus one validation/release chunk,
not a completion-date promise; holdout failures may require another correction pass.
The first three can use isolated copies and synthetic tests without user attendance.
Photos permission and visible release acceptance may need the user in chunk four.
Metadata indexing is already functional, but leave curatorEnabled false until these
quality gates pass to avoid rebuilding the same poor Moments. Album creation and any
future network enrichment are separate, not prerequisites for this indexing restart.
# Current Checkpoint: Auto-Publishing Recovery Fix (2026-09-12)

The first unattended full-library run analyzed thousands of photos but exposed a PhotoKit
publication feedback loop: self-generated library changes cancelled their own publication,
leaving 196 of 198 journals in `publishing`; recovery then conflicted with newly generated
operation UUIDs. The implementation now suppresses cancellation for self-generated changes,
reuses immutable journal requests, retries only when PhotoKit confirms the exact managed
album is absent, and treats routine task cancellation as non-user-facing. Automatic saving
also excludes unendorsed singleton/supporting collections. The private caption KVC write was
removed; public PhotoKit folder/album/membership APIs remain the publication path. Focused
publisher and display-policy verification passes 26 tests. Full-suite/release verification
and a new unattended acceptance run remain.
# 2026-09-12 workflow consolidation

- Implemented: explicit Favorite/unfavorite and confirmed Recently Deleted actions through public PhotoKit APIs.
- Implemented: published-album reconciliation on Moment merge, with create/verify-before-delete ordering and managed-hierarchy validation.
- Implemented: Moments-only primary workspace and selected-Moment Google Photos handoff; local staging is no longer a user workflow.
- Remaining hardening: persist a dedicated merge-cleanup retry record so a crash after replacement creation can resume removal of superseded managed album containers automatically.
# 2026-09-12 lifecycle follow-up

- Implemented targeted index reconciliation for Curator-originated Favorite and Recently Deleted changes; external Photos edits still request a full metadata reconciliation because broad library changes cannot safely be inferred from a single asset ID.
- Implemented stable macOS toolbar actions and adaptive metadata batches for foreground review versus unattended operation.
- Implemented bounded cleanup for transient staging, derived evidence, SQLite WAL/orphan jobs, and confirmed existing log rotation.
- Future refinement: retain a long-lived PhotoKit fetch result and consume `PHFetchResultChangeDetails` so external Photos edits can also reconcile incrementally.
- Completed that refinement after unattended telemetry exposed delayed album-publication notifications. The observer now distinguishes album-only changes, incremental asset changes, and the rare non-incremental fallback.
# 2026-09-12 research: meaningful places, venues, and people signals

## Meaningful places

- Photo Curator should maintain its own local list of meaningful places. Public MapKit does
  not expose the user's Apple Maps Home, Work, Favorites, or Guides, so those records must
  not be scraped or inferred from private stores.
- Add a **Places** pane to the standard macOS Settings window. Start with Home and Work and
  permit custom labels such as School, Family, or Studio. Each row stores a user-visible
  label, an Apple Maps result/address, coordinate, matching radius, and stable provenance.
- Adding a place opens one focused sheet: search with MapKit completion, select a result on
  a map, optionally adjust the radius, and save. **Use Current Location** is a secondary,
  explicit action and requests Core Location permission only when selected; address search
  must work without that permission.
- Keep labels and coordinates in local Application Support. Explain that place searches and
  reverse geocoding use Apple's network Maps service, while photo pixels and Moments remain
  on the Mac. Do not add a control to the Moments toolbar for this infrequent setup task.
- During presentation, a confident local-place match replaces generic geography: “Breakfast
  at Home” or “Team gathering at Work” instead of repeated “Woerden-West, Woerden” titles.
  The label is context, not an event by itself; time and visual evidence still decide Moment
  boundaries. User-authored Moment titles always win.

## Venue resolution

- Migrate the current `CLGeocoder` adapter to the current public MapKit geocoding API when
  the deployment target permits. Preserve an older-OS fallback during that transition.
- First consume the reverse-geocoder's named map item / area-of-interest result. If it is
  only an address or municipality, perform one cached `MKLocalPointsOfInterestRequest`
  around the Moment's representative GPS cluster.
- Use a venue name only when the GPS cluster is compact, the candidate is sufficiently near
  for its category/footprint, and there is no similarly plausible competing POI. OCR or a
  user-defined place can corroborate a result. Otherwise retain the locality. This can yield
  “Efteling” for a well-anchored park visit; a company office such as Booking.com is less
  reliably represented in map POIs and is better guaranteed through a custom Work place.
- Cache stable map-item identifiers, coordinates, display names, lookup date, and confidence.
  Never let a changed or unavailable Maps result overwrite a user label or manual title.

## Faces and people

- Public PhotoKit exposes asset metadata such as date, GPS, media subtype, dimensions,
  Favorite/hidden state, and burst information. It does **not** expose the Photos app's
  People/Faces identities or the relationship between a named person and `PHAsset` objects.
  Do not read Photos' private SQLite databases; that would reintroduce the OS-update and
  privacy fragility explicitly rejected for this app.
- Continue using public, on-device Vision face detection as evidence: face count, relative
  face size/position, and face-capture quality can improve covers, variety, group-photo
  selection, and privacy gates. Vision's public face detection does not identify a person or
  provide Photos' cross-photo identity clusters.
- A future named-people feature must be explicit and local-first (for example, user tagging
  inside Photo Curator). Do not present generic image feature prints or face crops as reliable
  biometric identity matching, and do not add such matching to the automatic pipeline without
  a separate privacy and accuracy design.

## Recommended implementation order

1. Extend resolved-place evidence and persistent cache to retain address, area of interest,
   map-item identifier, confidence, and source while preserving current locality behavior.
2. Add automatic, cached venue lookup with conservative ambiguity tests and synthetic provider
   tests; no new normal-workflow dialog.
3. Add the Settings > Places pane and local place store, then apply labels to titles and stories.
4. Add optional current-location setup after the address workflow, with just-in-time permission.
5. Expand cover/shortlist scoring with face count and face-capture quality. Keep identities out
   of scope until a supported public API or separately approved local tagging design exists.

Implementation status: steps 1–4 are complete using the macOS 13-compatible public MapKit and
Core Location APIs. The richer macOS 26 `MKReverseGeocodingRequest` migration remains optional;
current `CLPlacemark.areasOfInterest` plus conservative POI search already supplies venue context.
Step 5, face-aware cover and shortlist scoring, remains the next separate curation change.
# 2026-09-12 plan: a human Moment voice across the whole app

The meaningful-place release exposed a narrative regression: correct location evidence became
the headline itself, producing a wall of “At Home · date” cards. Place is evidence, not a story.
The next narrative implementation must be designed and shipped as one coherent pass rather than
another formatter patch.

## Voice and hierarchy

- Lead with what the photographs remember: occasion, activity, subject, season, or visual motif.
  Use place as supporting context. Examples: **Snow day at home**, **Flowers on the windowsill**,
  **A handmade January**, **New Year's Eve dinner**, **Winter lights at De Haar**, and **A day at
  Efteling**.
- Home and Work should normally be modifiers, not titles. A meaningful-place-only fallback may
  appear temporarily while analysis is incomplete, but it should read **January at home**, not
  **At Home · Jan 5, 2026**. Do not repeat Home/Work in both headline and subtitle.
- Let a venue lead only when it is the destination or organizing subject: a theme park, museum,
  landmark, performance venue, or named event. A nearby shop, station platform, office tenant,
  or reverse-geocoder artifact stays in metadata unless corroborated.
- Prefer warm, plain, specific language. Avoid database/report phrasing such as “photos from,”
  “collection in pictures,” “possible scenes,” “captured in,” counts inside prose, raw classifier
  labels, confidence disclaimers, and punctuation-built templates like `place · date`.
- Never fabricate an occasion, relationship, person, emotion, or exact venue. A graceful broad
  title is better than false specificity. User titles always remain final.

## Evidence-to-language ladder

1. User-authored title and story.
2. Corroborated occasion or activity supported by several photos, OCR, calendar/holiday timing,
   and scene continuity.
3. Repeated concrete subject or visual motif supported across the Moment.
4. Destination venue plus activity/season when the venue is strongly established.
5. Season/month plus meaningful place, for example **January at home**.
6. Neutral date fallback, localized naturally, while richer evidence is still processing.

Single generic labels such as `outdoor`, `people`, `sky`, `structure`, or `document` must never
become headlines. Labels need normalization into photographer language and multi-photo support.
Utility/reference collections should use an honest library description rather than imitating a
memory title.

## One narrative result, many surfaces

- Introduce a versioned `MomentNarrative` result containing headline, one-sentence deck, optional
  longer story, place/date display fields, confidence, evidence provenance, and processing state.
- Generate it once in the persistent pipeline. Moment cards, review windows, Photos album names,
  Google handoff, accessibility labels, and diagnostics all consume this same result. Eliminate
  the current divergent title precedence in `MomentPresentation`, `LocalMomentNarrative`, and
  publication methods.
- Keep card hierarchy clean: headline tells the memory; a secondary line may show place and date;
  the existing highlight/photo count remains metadata; status text reports preparation or user
  customization only. Never show the same place three times.
- Recompute automatic narratives when meaningful places, venue evidence, OCR, grouping, or the
  narrative engine version changes. Preserve manual titles/stories and manual photo choices.
  Published albums must be renamed only through the existing safe reconciliation path.

## Narrative generation

- Replace the current model's “choose one rigid candidate” role with bounded local generation from
  structured evidence, followed by deterministic validation. Keep a deterministic fallback for
  unavailable models, but make that fallback subject-first and season-aware.
- Give the local model only normalized, attributed evidence. Require concise headline output,
  reject unsupported proper nouns, relationships, occasions, and emotions, and cap repetition
  across adjacent cards. The model may improve language; it may not create facts.
- Add title-quality scoring: specificity, evidence coverage, natural grammar, distinctness from
  neighboring Moments, no metadata duplication, no forbidden robotic terms, and no unsupported
  claims. Select the best validated option, not simply candidate zero.
- Stories should read like captions, not audit records. Counts, confidence, and source explanations
  belong in “Why this Moment?” rather than the visible narrative.

## Acceptance set

- Build a frozen representative suite from the current screenshot and authorized export: home
  crafts, flowers, snow, holiday table, portraits, birds/pets, work interiors, stations, museums,
  attractions, travel days, mixed/uncertain sets, and utility photos.
- Snapshot-test every user-facing surface and publication title. Explicitly reject repeated
  `At Home · date`, raw POI strings, `possible ... scenes`, location/date duplication, and changed
  manual text.
- Add library-level diversity checks so a page cannot collapse into one repeated template even
  when many Moments share Home or Work. Evaluate factual grounding separately from writing quality.

## Implementation chunks for the next session

1. Narrative schema, shared formatter, migration, and frozen acceptance fixtures; no visible change.
2. Subject-first deterministic fallback and place/venue role classification with unit tests.
3. Grounded local-model generation, validation, cache-version invalidation, and unavailable fallback.
4. Replace card/review/accessibility surfaces and visually inspect light/dark, narrow/wide layouts.
5. Route Photos publication and Google handoff through the same narrative; safely reconcile existing
   managed album titles without touching user albums.
6. Run the export and live-library acceptance audit, tune repetition/diversity, then deploy once.

No implementation or rebuild was performed for this planning checkpoint.

# 2026-09-12 plan: calibrated mathematical curation architecture

The external architecture proposal is directionally strong: sequence inference is a better model
for Moment boundaries than isolated rules, set-level optimization is a better model for highlights
than independent ranking, and information value is a better narrative prior than always printing
the nearest place. Adopt those principles, but do not copy the proposal's example constants or its
handling of missing evidence into production.

## Non-negotiable corrections to the proposal

- Missing GPS is unknown, not zero metres. Missing OCR is unknown, not zero overlap. Every feature
  carries availability, confidence, provenance, and analyzer version; unavailable dimensions are
  marginalized or omitted rather than imputed as evidence for continuity or separation.
- `VNFeaturePrintObservation.computeDistance` yields a distance where smaller means more similar;
  Apple does not promise a universal 0...1 semantic scale. Normalize against observed distributions
  by Vision revision and media category, retaining the existing category-specific calibration.
- Home is context, not a hidden sequence state. The temporal model represents continuation,
  transition, soft boundary, and hard gap; meaningful places and venue evidence are observations.
- Fixed transition matrices, Gaussian parameters, merge thresholds, occasion likelihoods, and
  weights from the proposal are hypotheses only. Learn or calibrate them from frozen fixtures,
  authorized export data, and persistent user split/merge/highlight corrections.
- User merges, splits, titles, stories, includes, and exclusions remain hard constraints. A model
  version change may recompute automatic evidence but never silently overwrite those decisions.

## Layer 1: typed observations and calibrated boundaries

For each adjacent capture pair, persist transformed observations such as `log1p(timeGap)`, optional
geodesic distance, calibrated visual-distance percentile, optional OCR overlap, recorded-place
agreement or contradiction, photo type, and utility/face/scene evidence. Keep an explicit mask for
missing dimensions and retain the raw evidence used to derive every value.

Begin with an interpretable boundary posterior calibrated on labeled pairs. Add sequence smoothing
and duration priors only after that posterior is reliable; a hidden semi-Markov model is a better
event abstraction than treating each adjacent photograph as an independent four-state HMM. Hard
GPS contradictions and protected user boundaries remain vetoes. Every result stores boundary
probability, uncertainty, reason contributions, and model version.

Run this engine in shadow mode beside `AutomaticMomentSegmentation` first. Promote it only when it
reduces both fragmentation and accidental joins on home routines, trips, attractions, compressed
imports, GPS-sparse sequences, and the current year-to-date corpus.

## Layer 2: conservative cross-gap continuity

Retain the existing bounded, adjacent-only continuity pass and its protection against transitive
chains. Replace all-pairs average similarity from the proposal with a bounded set of representatives,
one-to-one visual matches, robust aggregate evidence, and explicit location-conflict vetoes. Unknown
location contributes no geographic evidence. A join requires several independent clues and remains
provisional until the calibrated boundary model supports it.

## Layer 3: adaptive set-level highlight selection

Select highlights as a set with a normalized monotone objective:

`quality + collection coverage + role coverage`, subject to near-duplicate and size constraints.

Facility-location coverage supplies diminishing returns and discourages repetition without relying
on an unbounded favorite bonus or a potentially negative temporal cosine. Manual includes and Photos
Favorites are protected constraints, not merely large numeric weights. Face quality, group portraits,
scenery, establishing shots, details, and useful contextual text are distinct roles; raw face count
must not reward crowding by itself. Utility images may supply context but do not displace memories.

Moment size remains content-dependent. Greedy selection stops when calibrated marginal value falls
below a threshold, with safe minimum/maximum budgets and coverage checks. Lazy evaluation is an
optimization after equivalence tests, not a change in behavior.

## Layer 4: information-weighted, grounded narrative

Normalize Vision/OCR concepts before computing evidence-weighted document frequency. Rare labels
are not automatically salient: a clue needs confidence, multi-photo support, and semantic quality;
generic or unstable classifier labels are excluded. Meaningful-place information is learned from
the user's own library and capped, so Home and Work normally become modifiers rather than headlines.

Generate several grounded headline/story candidates and score evidence coverage, specificity,
natural grammar, factual support, metadata duplication, and repetition. Occasion inference uses
multiple independent evidence families, capped log-likelihood contributions, calibrated priors,
and an abstention threshold; correlated labels must not multiply into false confidence. Structured
MapKit fields and POI categories drive venue cleanup rather than splitting legitimate names on
punctuation.

Feed-level MMR may break ties between equally grounded display candidates, but it must not make a
Moment's canonical narrative depend on card order or cosmetically disguise duplicate Moments.
Published Photos album names and Google handoff always use the stable canonical narrative.

## Evaluation and rollout gates

- Freeze the current engine output and a representative labeled suite before tuning.
- Measure boundary tolerance F1, pairwise grouping precision/recall, over/under-segmentation,
  calibration error, highlight coverage/redundancy/Favorite recall, narrative factuality, title
  repetition, and override survival.
- Split calibration and evaluation data by visit/day, not by photograph, to prevent leakage.
- Persist model/evidence versions and comparison telemetry without asset identifiers or image data.
- Shadow, compare, and migrate idempotently. No Photos album mutation is caused by a shadow result.

## Resumable implementation chunks

1. Freeze baseline outputs, define labeled boundary/highlight/narrative fixtures, and add metrics.
2. Add typed evidence, missingness masks, provenance, and Vision-distance calibration tables.
3. Implement an interpretable boundary posterior and explanation record; run it in shadow mode.
4. Add duration-aware sequence smoothing, then compare with the current boundary engine.
5. Rework continuity around calibrated evidence and robust bounded representatives.
6. Add adaptive facility-location highlight selection with hard user/Favorite constraints.
7. Add normalized concept salience, personal place priors, and conservative occasion scoring.
8. Complete the shared human-narrative work already planned, using the new scorer and stable
   canonical result; apply feed diversity only as a tie-breaker.
9. Audit the export and live library, promote only passing components, migrate caches, and deploy
   once after the related changes are bundled.

Each chunk ends in deterministic tests and a documented comparison checkpoint. This plan supersedes
the external proposal's direct four-step drop-in implementation, while preserving its useful HMM,
submodular-selection, information-theory, Bayesian-abstention, and MMR concepts.
