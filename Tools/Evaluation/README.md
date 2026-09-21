# Exported Reference Evaluation

For a large-visit-only rerun, add `PHOTO_RELAY_VALIDATION_LARGE_ONLY=1` to the structural
gate command below. It does not rerun or overwrite the holdout report. Reports now retain
the exact production selection and display evidence in each catalog entry, not only counts.
After explicit shortlist-review authorization, run
`swift Tools/Evaluation/render-selected-review.swift REPORT_FOLDER` to render the actual
large-visit selected photos (maximum 64) into a new private directory. It verifies hashes
and export path containment; no Photos/network calls. Never render a holdout as a shortcut.

Full local structural gate (explicit opt-in):
`PHOTO_RELAY_VALIDATION_REPORT=REPORT_FOLDER swift test --filter ExportedReferenceBaselineTests/testOptInLargeVisitAndHoldoutValidation`
verifies source hashes and analyzes all 624 C03 copies followed by all 684 held-out
February copies with on-device Vision/OCR. Uses temporary indexes, no PhotoKit/network,
no folder names as model inputs, and deterministic caption fallback. Saves private
large-validation.json and holdout-validation.json outside the source export. Checks
coverage, bounded convergence, parent identity and restart stability; records selection
counts. Passing is NOT human event/storytelling-quality acceptance. Export Favorites and
PhotoKit categories remain unknown. Once run, February is an evaluated holdout, not an
untouched dataset; do not tune to it and subsequently describe it as independent.

Developer-only tooling, not another application workflow. Uses explicitly supplied
exported copies through normal file APIs; never accesses the Photos library database.
ExifTool and Node are required for the audit; macOS Swift/AppKit render contact sheets.

1. Run `node audit-export.mjs EXPORT_FOLDER NEW_REPORT_FOLDER`. The output parent must
   already exist. Output must not exist or resolve inside the read-only source folder.
   Private manifest/summary files are created outside source control with mode 0600.
2. With explicit user consent for conversation-AI pixel inspection, run
   `node prepare-reference-sample.mjs REPORT_FOLDER` and then
   `swift render-reference-sample.swift REPORT_FOLDER`. This initial sampling recipe is
   specific to the September 2026 supplied dataset, not the production grouping engine.
3. The renderer checks source SHA-256 against the audit before creating contact sheets.
   February photos are held out together, never rendered. Contact sheets may contain
   private information; do not commit or upload them to research services.
4. Run the app metadata baseline and local evidence pilot with
   `PHOTO_RELAY_REFERENCE_REPORT=REPORT_FOLDER swift test --filter ExportedReferenceBaselineTests`
   from the repository root. Only metadata is passed to the existing grouping function.
   It writes `metadata-baseline.json` in the private report folder. A separate test calls
   existing background OCR/classification on 90 already-approved samples at the production
   1024-pixel limit and records `local-evidence-pilot.json` plus private evidence caches.
   Caption comparison uses deterministic fallback, not model inference. These are NOT the
   full pipeline or quality acceptance tests. Only explicitly opted-in runs read photos.

The pilot now also checks the production OCR-to-caption handoff and records source-scoped
`captionEvidence` beside each current fallback caption. It asserts meaningful activity
support in the palace/restaurant cases and a conservative mixed-collection title for the
compressed imported timeline. It also exercises production display eligibility on 78
reviewed non-screenshot samples and 12 reviewed screenshots, including a doll-collection
counterexample. Ordinary/screenshot fixture categories are explicit reviewed assumptions,
not inferred PhotoKit metadata from the export. `displayEvidence` records contextual roles;
all assets remain members. No aesthetics results are supplied, so this is not final ranking.
Raw OCR and source hashes remain only in the private report. A cached run still verifies
source hashes and regenerates captions when evidence or its production version changes.
Do not use this sample-level test as a substitute for the full grouping/holdout release gate.

A third opt-in test runs the complete background continuity/grouping/caption path on the
16 approved restaurant copies using fresh temporary Vision/OCR/index stores. It verifies
13+3 ->16, full membership under late-only priority, persistence and retraction after synthetic
conflicting labels are injected into those temporary caches. Writes `continuity-pilot.json`
in the private report; removes only its temporary evaluation store afterwards. No Photos
access, network, source-file changes, or February holdout inspection. It does not replace
broader holdout/event-quality acceptance, and does not infer missing exported Favorite flags.

Audit checks: `node --test Tools/Evaluation/audit-export.test.mjs` from repository root.
The script rejects changed source inventory, symlinks and output reuse; does not delete
duplicates or create thumbnails. Exact hashes are not visual-near-duplicate detection.
Photo capture dates retain explicit offsets or remain unknown; movie CreationDate takes
precedence over container dates that may reflect re-encoding/export time. GPS direction
references are respected. Source filesystem timestamps never substitute for capture dates.

Keep provenance separated: export folder names are reference hints, not model inputs or
verified venue/event labels. User Favorites, People associations and PhotoKit categories
are not faithfully represented in this export. Persist accepted references separately
from the agent's provisional suggestions; no private reference data belongs in this repo.
