# Soak agent fix log

Append-only. Each entry: UTC time, symptom (from telemetry counts only), root cause,
files changed, verification, relaunch result.

## 2026-09-28 — OCR CRImageReaderError paused overnight prep

- **Symptom:** Menu/status `Moment preparation paused: TextRecognition.CRImageReaderError error 1.`; telemetry hundreds of `failure` code 1 overnight after clean-room.
- **Root cause:** Local Vision OCR framework error was treated as a hard pause when `claimed == nil`. Timeouts already soft-failed; reader errors did not.
- **Fix:** Map Vision OCR failures to `TextRecognitionFailure.unavailable`; `prepareText` caches empty OCR and continues; label capture soft-fails; analysis step no longer pauses on TextRecognition/Vision soft evidence failures.
- **Files:** `Sources/PhotoCurator/MomentTextEvidence.swift`, `Sources/PhotoCurator/CuratorController.swift`, tests, `Docs/CURATION_ALGORITHM.md`, `Docs/PROJECT_STATE.md`.
- **Verification:** `swift test --filter MomentTextEvidenceTests` passed; `./Scripts/build_app.sh`; app relaunched.
- **Relaunch:** Yes — Curate While Idle expected on.

## 2026-09-28 — Adaptive evidence scheduling (clean-room gap)

- **Symptom:** Soak ran expensive OCR/Vision equally on recent geotagged photos; Journeys stayed `Journey from Home` while analysis backlog drained.
- **Root cause:** Analysis/text queues were “fill every missing cache,” not attribute-thinness scheduling.
- **Fix:** `AdaptiveEvidenceScheduling` priorities on enqueue + startup rescore; text candidates ordered thin-first; screenshots skipped for OCR; Journey stop geocode interleaved as the cheap GPS path.
- **Files:** `AdaptiveEvidenceScheduling.swift`, `CuratorStore.swift`, `CuratorController.swift`, tests, `Docs/CURATION_ALGORITHM.md`.
- **Verification:** `swift test --filter AdaptiveEvidenceSchedulingTests`; rebuild + relaunch.
- **Relaunch:** Required for live soak.

## 2026-09-28 — Adaptive deferral + Journey geocode cadence

- **Symptom:** After priority reorder, soak ETA and Journey titles barely improved; telemetry had zero `journeyLookups` while analysis ran; 33/36 Journeys stayed `Journey from Home`.
- **Root cause:** (1) Adaptiveness only reordered the same full Vision/OCR work; OCR interleave still burned cycles on GPS-rich photos. (2) Journey geocode on `contextStep % 15` always lost to OCR on `% 5` because every 15th step is also a 5th step.
- **Fix:** Claim parks jobs at/below `refinementMaxPriority` while thinner work remains; text candidates skip `isMetadataRichRefinement`; Journey `enrichJourneyStops` runs before the OCR interleave. Docs/Mermaid updated to defer-not-reorder.
- **Files:** `AdaptiveEvidenceScheduling.swift`, `CuratorStore.swift`, `CuratorController.swift`, tests, `Docs/CURATION_ALGORITHM.md`, `Docs/PROJECT_STATE.md`, `Docs/ARCHITECTURE_STABILIZATION_PLAN.md`.
- **Verification:** `swift test --filter AdaptiveEvidenceSchedulingTests`; rebuild + relaunch.
- **Relaunch:** Required for live soak.

## 2026-09-28 — Analysis stall: deferred thin blocked claim gate

- **Symptom:** UX timing flatlined (~24+ min): `analysis` saved stuck at 1328; 466 priority-80 jobs `state=running` with future leases; geocode barely moving.
- **Root cause:** Adaptive deferral treated any thin `running` row as outstanding, including soft-deferred retries (`deferAnalysis` keeps `running` + future lease + null token). That made `claimAnalysis` require `priority > 35` while no claimable thin work existed → empty claims forever.
- **Fix:** Park GPS-rich refinement only when thin work is pending, actively token-leased, or lease-expired; ignore soft-deferred running rows.
- **Files:** `CuratorStore.swift`, `AdaptiveEvidenceSchedulingTests`, `Docs/SOAK_FIX_LOG.md`.
- **Verification:** `swift test --filter AdaptiveEvidenceSchedulingTests`; rebuild + relaunch.
- **Relaunch:** Required.

## 2026-09-28 — Photos access clicker missed `PhotoCurator` process

- **Symptom:** Soak ticks reported `click=no_photos_access_dialog` while analysis stalled after ad-hoc rebuild/resign; owner had to grant “Allow access to all photos” manually.
- **Root cause:** `click_photos_full_access.sh` only inspected process name `Photo Curator`; the running binary’s Accessibility name is `PhotoCurator`.
- **Fix:** Include `PhotoCurator` in the clicker’s process list (before the spaced name).
- **Files:** `Scripts/click_photos_full_access.sh`, `Docs/SOAK_FIX_LOG.md`.
- **Verification:** Clicker re-run; dialog absent now; analysis resumed (`saved` climbing after relaunch).
- **Relaunch:** Not required for clicker script; keep monitoring Curate While Idle.
