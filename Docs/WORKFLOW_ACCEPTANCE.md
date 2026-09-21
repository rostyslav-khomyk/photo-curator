# Workflow Acceptance: Required for Every Feature

## Export Gate (2026-09-11)

- Local real-copy structural test passed: 624-photo visit remains one parent; 684-photo
  February holdout retains all members across 53 groups; restart IDs stable.
- Selection counts: 25/624 and 111/684; context-only: 26 and 36 respectively.
- Holdout contains 19 singleton groups. No independent event-quality labels or selected
  photo review yet; do not treat processing state ready as user-experience acceptance.
- Live Photos permissions, actual Favorites/categories, model behavior, rendered output,
  and deployed-app restart still require acceptance. No redeployment/indexing restart.

Features are not complete when their isolated dialogs work. Review the user's whole
path before adding another control. Default to automatic continuation after consent
or successful setup; do not require a second button to perform the already intended work.

For each milestone, verify and document:

- Fresh launch with permission absent: explain the prerequisite, request once, then
  continue into usable content after success. Decline must leave a clear recovery path.
- Relaunch with valid permissions: load content without setup prompts or extra clicks.
- Return from System Settings: recheck authorization and resume the waiting workflow.
- Loading, genuinely empty, denied, offline and failed states must be distinguishable.
- Duplicate lifecycle events must not duplicate work, prompts or windows.
- Background refresh must not disrupt sync, selection, editing or foreground status.
- A recoverable failure gets a contextual retry, not a repeated permission request.
- Keep technical controls in settings/diagnostics; default UI presents user outcomes.
- Synthetic tests do not establish UI acceptance. Record what was actually exercised
  and what remains unverified; do not ask the user to discover predictable transitions.

Current Photos path: launch/activation -> read authorization -> automatically list
albums if accessible and not already attempted. Consent completion follows the same
path. Failure waits for explicit Retry; restored active sync defers until idle.
Photos authorization and Google readiness must not require one another to load albums.

Remaining wider audit: remember user workflow preferences across relaunches, unify
Moments presentation, and integrate enrichment into the end-to-end curator rather
than leaving separate diagnostic actions as the final product.
# Automatic grouping acceptance (2026-09-09)

User acceptance update, 20:17: user reports editing the August 30 Moment, excluding
Amsterdam photos, and restarting the app. Screenshots show the custom title retained
in both the card and review, and 7 selected of 29 photos. Individual excluded-photo
controls are not visible in these screenshots; exclusion persistence is user-reported,
not independently inspected. No selection or library changes were made during recording.
Reprocessing after these edits is not independently verified by the screenshots.

Visible follow-up issues: the review still displays the automatic title below the custom
title without clearly labeling it as a suggestion; cards still say "Local suggestion"
for user-named Moments; cover thumbnails show clipped timestamp text. These are UI
cleanup items, not reasons to reset user corrections. The title is user-authored context,
not verified geographic evidence or permission to regroup this corrected collection.

- Headless tests verified: priority range does not filter the catalog or clip groups;
  newest collections prepare first; grouping/captions settle before priority completion;
  persisted records survive restart; missing evidence remains pending.
- Headless tests verified: named membership survives date edits; explicit split/merge
  wins over title pins; per-photo exclusion and custom title survive reconstruction.
- Authorized exported-copy test verified: 30 photos covered exactly once, 29+1 groups,
  cached local captions and no network/Photos writes. Fine venue grouping remains limited.
- Manual after relaunch: open Moments, prioritize a period, observe cards progressing
  without opening diagnostics; expand About this grouping in the existing review.
  Rename a Moment, revisit/reprocess it, and confirm the name and selection persist.
  Large groups should say broad grouping, not imply semantic refinement is complete.
- This build does not automatically restart the running app, create albums, or sync.
# Mixed-timeline and presentation acceptance (2026-09-09, evening)

- Automated rendering verifies card cover height excludes the timestamp row; review
  previews still include it. User-title precedence and saved-edit status are tested.
- Synthetic grouping checks cover deterministic order, no neighbor chaining, missing
  evidence, conflict vetoes, uniform bursts, shared GPS, tiny-fragment rejection and
  comparison-budget exhaustion. New classification test preserves specific scene hints
  when generic labels rank higher.
- Opt-in test uses only authorized exported copies and temporary stores: garden/castle
  sets supported; unrelated buildings and miniature/real-city scenes must not be merged
  into a supported scene. Unresolved remainder does not receive a fabricated caption.
- Relaunch check still needed: named Moment shows Your edits saved with its title and
  exclusions intact, no duplicate auto title, no clipped times on covers. Do not clear
  existing corrections to test automatic grouping; the separate fixture covers that.

# Clean evaluation reset (2026-09-09, 23:34 CEST)

- User explicitly authorized clearing generated curation state without a backup.
- Verified the app/backend were closed; removed the index, analysis caches, generated
  groups and catalog snapshot. Only saved group-review files remain under curator.
- Verified curatorEnabled is false. Other preferences and preserved app-support files
  have matching before/after checksums, including manual corrections and Google sync state.
- Photos and exported files were not touched. App was not rebuilt or relaunched; empty
  Moments UI after a later launch is expected but was not visually exercised this turn.
- New reference-dataset evaluation is pending the user's export. Do not interpret this
  cleanup as improved grouping quality or as authorization to erase manual corrections.

# Exported reference evaluation (2026-09-10)

- Read-only audit covers 4,534 JPEGs and 108 MOVs; no source file writes or exact-duplicate
  deletions. Reports/contact sheets are separate private files outside the source tree.
- User explicitly approved conversation-AI inspection of representative images. Inspected
  138 samples; held out all 684 February JPEGs from pixel inspection and tuning.
- Native metadata baseline preserves full coverage and holdout isolation. Reproduced the
  restaurant's 13+3 split and the 624-photo palace refinement limit. These are quality gaps,
  not passing user acceptance merely because the diagnostic test completes successfully.
- Native evidence pilot uses 66 approved local copies and existing OCR/classification.
  Restaurant/park text is recognized, but the background caption stage omits that evidence.
  No actual language-model generation, full pipeline quality evaluation or user acceptance
  was performed in the pilot; comparison captions use deterministic fallback.
- Provisional reference Moments and sample preferences are recorded in the private report.
  Do not treat scene bins as separate required feed cards or infer user preferences from
  missing exported Favorite flags. No production defaults, UI or library state changed.
- Final automated verification: 109 native tests, 7 skipped opt-in tests, no failures;
  both reference tests passed in a separate authorized run, plus four audit tests.
  Live curator remains paused and empty of generated state; no app bundle redeployment.

# Evidence-Aware Captions (2026-09-10)

- Production background captions now consume completed OCR and visual caches automatically.
  No new dialog. Private/instruction-like text and known screenshots are excluded from
  caption evidence; this is not yet the display/cover eligibility feature.
- Headless checks verify source/revision attribution, conservative mixed-collection titles,
  missing-evidence waiting, edited-photo rejection, late-evidence refresh, cancellation,
  bounded sampling and unchanged user-correction precedence.
- Approved 66-copy pilot passes concrete restaurant/palace/mixed-timeline caption checks.
  No generalization claim from these development examples; February holdout remains unused.
- Full suite: 120 native tests, 7 opt-in skips, no failures. Reference tests and synthetic
  Apple local-model smoke test passed separately; four audit tests and release build pass.
- No live UI/redeployment acceptance in this chunk. Existing app bundle and cleared live
  index remain untouched; curatorEnabled is false. Wait for remaining restart gates.

# Context/Display Eligibility (2026-09-10, evening)

- Public screenshot flags and corroborated local menu/map/document clues remove only
  automatic display eligibility, not index membership or contextual evidence. Single utility
  scores, missing evidence and meaningful object/people clues do not reject photos.
- Context filtering runs before similarity and balanced selection. Favorite/Include keeps
  an asset eligible; Exclude wins. User text and split/merge corrections are unaffected.
- Context-only collections remain accessible in a collapsed section of normal Moments.
  They use a placeholder rather than silently showing a utility cover. Review preserves all
  thumbnails, zoom and Include controls. Pagination remains outside the main-card condition.
- Headless tests cover persistence/legacy decode, stale versions/revisions, cache-only worker
  preparation, cover eligibility, user overrides and placeholder-card rendering at 250px.
- Expanded 90-copy pilot: one map, two menu pages and 12 screenshots classified context-only;
  all 12 doll samples retained as display candidates. No source modifications or holdout use.
  This does not establish complete utility recognition or best-photo-selection quality.
- Live UI/relaunch acceptance is still pending the final release gate. Do not deploy or
  restart indexing merely because these isolated tests pass. Three restart chunks remain.
- Final checks: 131 native tests, 7 opt-in skips, no failures; two separate reference tests
  pass; release build passes. Context-only card visually inspected at minimum 250px width
  using synthetic metadata and no photo loading. No full live-workspace acceptance yet.

# Event Continuity (2026-09-10, evening)

- Background processing can bridge a bounded same-day gap only with repeated agreeing GPS
  and multiple independent visual matches, without conflicting scene/occasion evidence.
  Utility photos cannot provide the visual bridge. This is a provisional join, not a venue
  identification or assurance that every separate occasion can be distinguished.
- Existing About this grouping includes the explanation. No manual analysis step or new
  dialog. Full membership projects before paging and prioritization; context/display roles
  and manual choices continue through the same pipeline.
- Synthetic checks cover rejection conditions, deterministic disjoint pairing, no skipped
  intervening groups, saved splits/names/protected children, persistence and invalidation.
- Actual 16-copy restaurant pipeline: 13+3 ->16; full caption when only late photos are
  prioritized; stable ID after reopening; synthetic adverse cache evidence retracts the join.
  Neither GPS nor source assets are modified. Private report records the distinction between
  real positive evidence and injected synthetic negative evidence.
- 142 native tests, 8 opt-in skips, no failures; all three opted-in reference tests pass.
  Live UI/relaunch/holdout acceptance remains pending. Curator stays disabled and undeployed.
