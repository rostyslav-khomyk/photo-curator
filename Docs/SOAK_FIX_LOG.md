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

## 2026-09-28 — Journey wipe + telemetry silence missed by soak probe

- **Symptom:** Sidebar showed only France Journey; owner report of stuck app; soak ticks still “healthy.” Telemetry last event ~10:51Z while UI spinner/`Analyzing…` persisted hours later; 35/36 Journeys were `Journey from Home` shells.
- **Root cause:** (1) `rebuildStories` deleted and rewrote Stories without preserving geocoded stop places, wiping finalized titles. (2) Soak watch only checked failure bursts / process alive — not telemetry age or finalized-vs-shell Journey counts.
- **Fix:** Preserve non-street Journey stop labels across rebuild and retitle; soak watch errors on ≥12m telemetry stall and warns when shells dominate finalized titles.
- **Files:** `CatalogV2.swift`, `CuratorGeocodingTests`, `Scripts/soak_watch_telemetry.py`, `Docs/SOAK_AGENT.md`, `Docs/CURATION_ALGORITHM.md`, `Docs/SOAK_FIX_LOG.md`.
- **Verification:** `swift test --filter CuratorGeocodingTests.testRebuildStoriesPreservesGeocodedCityTitles`; probe returns `telemetry_stalled` / `journey_titles_wiped`; rebuild + relaunch.
- **Relaunch:** Required.

## 2026-09-28 — One Journey left; probe warn ignored while geocode starved

- **Symptom:** Owner screenshot: single France Journey in sidebar, `Analyzing…` spinner; probe only `warn`/`journey_titles_wiped` while analysis `saved` climbed and `journeyLookups` stayed 0.
- **Root cause:** (1) Normal geocode cadence (`contextStep % 15`, 4 lookups) is too slow after a wipe (~200 nil stops). (2) Probe treated wipe as warn-only, so soak ticks did not escalate when Vision advanced without any Journey geocode attempts.
- **Fix:** `JourneyEnrichmentScheduling` recovers every step with 8 lookups while shells dominate finalized titles; probe errors on `journey_geocode_stalled` (wipe + analysis events + zero lookups).
- **Files:** `AdaptiveEvidenceScheduling.swift`, `CuratorController.swift`, `AdaptiveEvidenceSchedulingTests`, `Scripts/soak_watch_telemetry.py`, `Docs/SOAK_AGENT.md`, `Docs/CURATION_ALGORITHM.md`, `Docs/PROJECT_STATE.md`, `Docs/SOAK_FIX_LOG.md`.
- **Verification:** `swift test --filter AdaptiveEvidenceSchedulingTests`; probe exit 2 on stall; rebuild + relaunch; watch `journeyLookups`/`journeyUpdates` and finalized count climb.
- **Relaunch:** Required.

## 2026-09-28 — Post-rebuild Photos dialog title miss (“Allow All Photos”)

- **Symptom:** After rebuild/relaunch, telemetry stuck on `waiting reason=1` (Photos access); analysis/`journeyLookups` silent; sample showed `PLPrivacy` semaphore wait. Clicker reported `no_photos_access_dialog`.
- **Root cause:** UserNotificationCenter dialog button is **Allow All Photos**, which was not in the clicker title list.
- **Fix:** Add `Allow All Photos` to `click_photos_full_access.sh`; document in SOAK_AGENT.
- **Files:** `Scripts/click_photos_full_access.sh`, `Docs/SOAK_AGENT.md`, `Docs/SOAK_FIX_LOG.md`.
- **Verification:** Clicker clicks dialog; analysis resumes; Journey recovery cadence emits lookups.
- **Relaunch:** Not required once access granted.

## 2026-10-02 — Window not scrollable during library overview

- **Symptom:** Owner report: nothing in the window scrolled for 7+ minutes after relaunch. Process at ~93% CPU. Sample showed the main thread idle in the event loop and a utility thread inside `photos(in:)` decoding every indexed payload.
- **Root cause:** (1) Window inset repair resized a content-view sibling to the full window bounds, so a non-scrolling view covered the grid and sidebar and took scroll events. (2) Each of ~110k photo rows constructed a new `JSONDecoder`, so a background overview held a core for many minutes.
- **Fix:** Inset repair only clears negative safe-area insets and does not resize siblings. Background AppKit views return nil from `hitTest`. The Moments scroll view is height-bounded. `photos(in:)` reuses one decoder per scan.
- **Files:** `PhotoCuratorApp.swift`, `MomentGridKeyHandler.swift`, `MomentsWorkspace.swift`, `CuratorStore.swift`, `Docs/CURATION_ALGORITHM.md`, `Docs/PROJECT_STATE.md`.
- **Verification:** `./Scripts/build_app.sh` release build succeeded.
- **Relaunch:** Required.

## 2026-10-02 — Photos grant still left an access ribbon

- **Symptom:** After the system Photos dialog, a thin “Allow access to your full Photos library” ribbon stayed across the Moments grid and had to be clicked again.
- **Root cause:** The access bar kept its pre-dialog status until that bar’s own button ran, and as a top safe-area inset it stretched across the grid.
- **Fix:** Read authorization until the system grant is visible, then remove the bar. Place it as a compact top row instead of a safe-area inset.
- **Files:** `LibraryAccessBanner.swift`, `DashboardView.swift`, `Docs/CURATION_ALGORITHM.md`.
- **Verification:** `./Scripts/build_app.sh` release build.
- **Relaunch:** Required.

## 2026-10-03 — Journey home circles, thin pings, country retitles

- **Symptom:** Map showed no home start circle; one messenger ping bent routes; many Journeys kept `Journey via` landmark lists; owner could not find France vacation (it was already titled but easy to miss among old names).
- **Root cause:** Home Moments never became map anchors; only primary Home closed trips; landmark/street labels blocked country titles; France/Spain and Ireland/UK coarse boxes overlapped.
- **Fix:** Multi-home start/end anchors; drop thin stops from the route; country titles from coordinates with overlap resolution; Refresh Journey Names + story projection epoch bump.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, `CuratorGeocoding.swift`, `JourneyRouteMap.swift`, `MomentsWorkspace.swift`, `CuratorController.swift`, docs, tests.
- **Verification:** `swift test --filter HolisticCurationGenerationTests`; `./Scripts/build_app.sh`; relaunch.
- **Relaunch:** Done. Ad-hoc resign may show Photos dialog again.

## 2026-10-02 — Story list and Moments grid still outside the window

- **Symptom:** After the earlier scroll repair and the access-ribbon fix, the window still did not scroll. The split group sat above the window at height 2845 inside a 1307-point window.
- **Root cause:** SwiftUI sized the split to the Story list's ideal height after the parent had already grown to that height, so clamping the split to its parent did nothing. The scroll viewports were then taller than the window; the window clipped them and they had nothing to scroll.
- **Fix:** Pin the dashboard to the window layout size. Keep the split, and each scroll viewport, inside that rect. Leave document views content-sized.
- **Files:** `PhotoCuratorApp.swift`, `Docs/CURATION_ALGORITHM.md`, `Docs/PROJECT_STATE.md`.
- **Verification:** Release build. Accessibility frames place the split and both scroll areas inside the window. AppKit reports the Story document taller than its viewport and the Moments document far taller than its viewport.
- **Relaunch:** Done. Ad-hoc resign can show the Photos dialog again; Allow All Photos is enough.

## 2026-10-03 — Americas circuit split + ocean zigzag after merge

- **Symptom:** Dec 2025 Grand Rapids and Panama stayed two Journeys after rule rebuild; manual merge to “Journey to USA” still mapped Home↔Michigan and Home↔Panama ocean round-trips.
- **Root cause:** (1) Dense NL Home Moments outside the tiny geofence were treated as local-orbit returns and closed the Journey (`shouldKeepJourneyOpen` required geofence). (2) `JourneyMergePlan` concatenated each leg’s Home start/end anchors without stripping interior Homes.
- **Fix:** Home-orbit layover bridge without geofence requirement; strip mid-route Home stops in `JourneyStopSanitizer`; sanitize on merge; US box titles as USA; delete saved “Journey to USA” merge and bump `storyProjectionEpoch` to v7.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, `Docs/CURATION_ALGORITHM.md`, `Docs/PROJECT_STATE.md`.
- **Verification:** `swift test --filter HolisticCurationGenerationTests`; `./Scripts/build_app.sh`; relaunch + story rebuild.
- **Relaunch:** Required.

## 2026-10-03 — San Blas titled as town list instead of USA and Panama

- **Symptom:** After the Americas circuit merge, Dec 2025 became one Journey but stayed `Journey via San Blas, Panama City, and Aeropuerto…` with a mid-ocean Home pin.
- **Root cause:** San Blas sits in Panama∩Colombia coarse boxes → country naming failed the known-weight gate; Spanish `Aeropuerto` was not treated as transit; preserved “Home” labels could reattach to messenger coords after sanitizing.
- **Fix:** Panama-over-Colombia overlap; `aeropuerto` landmark hint; never preserve Home labels; re-sanitize after place adoption; NORAM+LATAM titles collapse to `Journey to Americas in {year}`; detour outlier floor so unlabeled mid-ocean pins between nearby Panama stays drop; epoch v9.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, `CuratorGeocoding.swift`, tests, docs.
- **Verification:** HolisticCurationGenerationTests; rebuild + relaunch → live title `Journey to Americas in 2025`, route Home → Grand Rapids → Panama (no ocean zigzag).
- **Relaunch:** Done.

## 2026-10-03 — Panama return Home missing on Americas map

- **Symptom:** `Journey to Americas in 2025` ended at Panama City; no Panama → Home leg despite Home GPS on Dec 16.
- **Root cause:** Return `homeAnchor` required ≥2 Home photos and a 7-day window from last distant morning that excluded Dec 20 Home Moments; the Dec 16 unlock was only 1 photo.
- **Fix:** Return Home allows 1 photo within 10 days after last abroad stop; epoch v10.
- **Files:** `HolisticCurationGeneration.swift`, tests, docs.
- **Verification:** `testReturnHomeAfterPanamaClosesCircuitWithThinHomePing`; rebuild + relaunch.
- **Relaunch:** Done.

## 2026-10-03 — Reprocess return-Home + route arrows/colors

- **Symptom:** Many Journeys still open-ended without Home return; long-haul legs gray; no travel direction on the map.
- **Root cause:** Return-Home rules not applied library-wide; air inference rejected multi-day gaps; map lacked arrows and matching chip colors.
- **Fix:** Epoch v11 full story rebuild; air for ≥400 km within 5 days; merge nearby consecutive stops; direction arrows + shared purple/blue/gray styling.
- **Files:** `HolisticCurationGeneration.swift`, `JourneyRouteMap.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** Holistic + JourneyRouteMap tests; rebuild + relaunch.
- **Relaunch:** Done — 44/48 Journeys now end at Home; Americas Home→GR→Panama→Home with air legs.

## 2026-10-03 — Owner calibration: France 2026 was a car trip

- **Symptom:** Summer holidays in France drew Home→Fontainebleau and Bollène→Reims as air after the Panama multi-day-gap shortcut.
- **Root cause:** “≥400 km + multi-day gap = air” leaked from Panama into European road holidays. Thin A7/Meyreuil pins became stops; Mâcon motel had no GPS.
- **Fix:** Multi-day air only ≥2,000 km; slower Europe hops stay overland; drop ≤4-photo interior pins between rich stays; highway/cours/basilique labels treated as transit/street/landmark. Epoch v13.
- **Files:** `HolisticCurationGeneration.swift`, `CuratorGeocoding.swift`, tests, docs.
- **Verification:** `testFranceDriveDropsHighwayMotelPinsAndStaysOverland`; rebuild + relaunch.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: Ireland was a flight, not a UK drive

- **Symptom:** Ireland/UK kept a 2-photo Warrington pin and drew Dublin → Home as overland (523 km / 41 h) after the France “keep Europe under 1,000 km = drive” cap.
- **Root cause:** Home (7 photos) did not count as a substantial stay, so Warrington could not drop as thin transit. Home-bound air required ≥1,000 km, which misses the Irish Sea.
- **Fix:** Home is a substantial neighbor for interior-transit drop; Ireland/UK ↔ Home ≥200 km is air. Epoch v18.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testIrelandDropsWarringtonAndFliesHome`; France/Americas tests still pass.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: Portugal + Greece was one flight circuit

- **Symptom:** Jul 2025 titled `Journey via Caparica, Athens, and Greece`; Home → Caparica drawn as a 40-hour drive.
- **Root cause:** Spain’s coarse box covers Lisbon, so Caparica was an ambiguous country and the title fell back to the town list. Home-bound air already covers ≥1,000 km; catalog was stale.
- **Fix:** Portugal/Spain overlap splits at the Guadiana (~-7.4°). Epoch v19 rebuild applies existing Home-bound air. One Journey, three flight legs.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testPortugalGreeceCircuitFliesEachLegAndTitlesCountries`.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: April Barcelona was a flight (Schiphol photos)

- **Symptom:** Asked fly vs drive for Apr 2025 Barcelona; library already had Schiphol + BCN airport GPS and in-flight no-GPS shots.
- **Root cause:** Schiphol sits in the 80 km Home orbit, so those photos were folded into the Home start circle and then merged (25 km < 30 km).
- **Fix:** Keep a Home-orbit cluster ≥8 km from the pin when a ≥400 km hop starts within 6 h; do not merge Home with a non-Home neighbor; Home anchors use the 8 km pin, not the 80 km orbit. Epoch v20.
- **Files:** `HolisticCurationGeneration.swift`, `CuratorGeocoding.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testBarcelonaWeekendKeepsSchipholFlightPhotosAndFlies`; Greece/Badhoevedorp split still holds.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: Steigra was not a Germany stop

- **Symptom:** Jul 2024 Rhodes titled `Ialysos and Steigra`; 13 photos / 1 h in Germany on the flight day.
- **Root cause:** 13 photos exceeds the 4-photo transit cap, so the inland ping survived as a destination.
- **Fix:** Drop a brief non-airport stop after Home (<20 photos, ≤4 h, outside the Home orbit) when the next stay is ≥400 km. Epoch v21.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testRhodesDropsSteigraAndFliesFromHome`.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: Crete 2023 is a summer flight from Home

- **Symptom:** `Summer in Ravdoucha` had no Home circles (last NL GPS 5 days before, Home 11 days after) and used the village name.
- **Root cause:** Home lookback was 2 days and return 10 days; a single town titles as the village, and Crete sat only inside the Greece box.
- **Fix:** 7-day depart / 14-day return Home windows; Crete region box beats Greece and village names. Epoch v22.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testCreteSummerClosesAtHomeAfterQuietDaysAndTitlesIsland`.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: Italy 2022 was one road trip from Home

- **Symptom:** Jul–Aug 2022 started at Neustadt with no Home circle; Steigra’s brief-departure rule could have dropped that German stop (450 km to Bavaria).
- **Root cause:** Home photos exist the same morning (catalog was stale). Brief-departure used ≥400 km, which matches a drive day.
- **Fix:** Brief inland drop only when the next hop is ≥2,000 km (flight). Epoch v23 rebuild attaches Home.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testItalyRoadTripKeepsGermanStopsStartsAtHomeAndStaysOverland`; Rhodes still drops Steigra.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: Bukovel was an NL↔Ukraine drive

- **Symptom:** Jan 2022 was Ukraine Home → Bukovel → NL Home as unknown/air; interior Ukraine Home after the ski days was stripped.
- **Root cause:** Interior-home sanitizer treated every Home* label as a fake waypoint. Home-bound air treated 1,450 km + quiet days as a flight (Bucharest pattern).
- **Fix:** Keep secondary residences as stays; primary Home still bookends; two mapped homes with car-like speed are overland. Epoch v24.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testUkraineHomeCircuitIsOneDriveFromNLAndBack`.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: Hungary 2021 was a road trip from Ukraine Home

- **Symptom:** Aug 2021 started at Košice with no Home; Slovakia was missing from the title. Assuming NL Home would invent a hop that skipped a week already in Lviv.
- **Root cause:** No Slovakia box; assumed NL start always fired when primary GPS was missing.
- **Fix:** Slovakia box (Košice); assume NL only when the Ukraine stay before departure is short (<5 days). Epoch v25.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testHungaryAustriaRoadTripStartsAtUkraineHomeKeepsKosiceAndStaysOverland`; Bukovel still starts at NL.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: summer 2021 is one road trip

- **Symptom:** Jul 2021 Dresden/Prague/Kraków and Aug 2021 Hungary were two Journeys split by a month at Home in Ukraine.
- **Root cause:** Any mapped-home geofence finished the trip; a 7-day gap between Kraków and Košice also finished it.
- **Fix:** Secondary residence keeps a Journey open for 40 days if travel resumes; 7-day gaps bridged by Ukraine Home do not finish. Epoch v26.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testSummer2021RoadTripStaysOpenAcrossUkraineHome`.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: France 2020 was a car holiday

- **Symptom:** `Summer holidays in France` 2020 started in Paris and drew Pampelonne → Home (986 km / 6 days) as unknown.
- **Root cause:** Overland under 1,000 km required ≤36 h; the 5-day fallback still missed a 6-day quiet return.
- **Fix:** Home ↔ away under 1,000 km with car-like speed stays overland up to 14 days. Epoch v27.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testFrance2020DriveClosesAtHomeAfterQuietDays`.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: Mini-Europe was a Brussels drive

- **Symptom:** Oct 2019 titled `Journey to Mini-Europe`.
- **Root cause:** The park name was treated as a destination, not an attraction.
- **Fix:** `mini-europe` is a landmark; landmark-only stays take the country title (Belgium).
  France/Belgium/Netherlands box overlap at Brussels resolves to Belgium. Epoch v28.
- **Files:** `CuratorGeocoding.swift`, `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testBrusselsDriveTitlesBelgiumNotMiniEurope`.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: Ukraine 2019 + Berlin is one drive

- **Symptom:** Jul–Aug 2019 split into two Carpathian Journeys and a Berlin hop.
- **Root cause:** Drive-back GPS in the Ukraine-home orbit, plus quiet weeks
  without GPS, finished the Journey before Berlin.
- **Fix:** Secondary-home orbit and 250 km theater stay open for 40 days;
  week+ already at the second home does not invent an NL start. Epoch v29.
- **Files:** `HolisticCurationGeneration.swift`, `CuratorGeocoding.swift`,
  `CatalogV2.swift`, tests, docs.
- **Verification:** `testUkraine2019CarpathiansAndBerlinStayOneOverlandCircuit`.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: London school pin was a UK flight

- **Symptom:** Jun 2019 titled `Journey to City of London School`, Home hop drawn as a drive.
- **Root cause:** School POI named the Journey; UK ↔ Home under 400 km / same day matched overland.
- **Fix:** `school` is a landmark; Ireland/UK ↔ Home ≥200 km is air before the overland
  <1,000 km rule. Epoch v30.
- **Files:** `CuratorGeocoding.swift`, `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testLondonSchoolVisitFliesAndTitlesUnitedKingdom`.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: Barcelona church pin was a Spain flight

- **Symptom:** Nov 2018 titled `Journey to Temple of the Sacred Heart of Jesus`, Home hop drawn as a drive.
- **Root cause:** Church POI named the Journey; 1,200 km Home hop lost to the overland catch-all when the return was under 12 hours.
- **Fix:** `temple`/`church` are landmarks; Home ↔ away ≥1,000 km is air before overland.
  Epoch v31.
- **Files:** `CuratorGeocoding.swift`, `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testBarcelonaChurchVisitFliesAndTitlesSpain`.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: 2018 Berlin+Pylypets is one drive; DSLR needs Vision

- **Symptom:** Jul 2018 Berlin and Aug 2018 Pylypets were two Journeys; mountain
  weeks had almost no GPS (dedicated still camera).
- **Root cause:** One distant stop then Home in Ukraine finished the trip; quiet
  DSLR weeks without GPS could not bridge 21 days; Pylypets → NL looked like air.
- **Fix:** Secondary-home stay after a single distant stop stays open 40 days;
  NL ↔ Ukraine is overland; no-GPS dedicated-camera / RAW photos get priority 80.
  Epoch v32.
- **Files:** `HolisticCurationGeneration.swift`, `AdaptiveEvidenceScheduling.swift`,
  `CuratorModels.swift`, `PhotoKitIndexedPhoto.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testUkraine2018BerlinAndPylypetsStayOneOverlandCircuit`,
  `testDedicatedCameraWithoutGPSGetsPreGeotagPriority`.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: Jan 2018 Bukovel assumes NL start

- **Symptom:** Jan 2018 started at Home in Ukraine with no NL circle.
- **Root cause:** Departing GPS missing (DSLR / quiet start); live catalog lagged the
  assume-Home rule used for Jan 2022.
- **Fix:** Same short Ukraine-arrival rule: assume NL start, keep Ivano-Frankivsk,
  all overland. Epoch v33.
- **Files:** tests, docs, `CatalogV2.swift`.
- **Verification:** `testUkraine2018BukovelAssumesNLStartKeepsIvanoAndStaysOverland`.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: May 2017 was a Paris drive, not Disneyland

- **Symptom:** May 2017 titled around Disneyland / Pont d'Iéna.
- **Root cause:** Park and bridge pins named the Journey.
- **Fix:** `disneyland` and `pont ` are landmarks; Home ↔ Paris stays overland.
  Epoch v34.
- **Files:** `CuratorGeocoding.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testFrance2017DriveTitlesParisNotDisneyland`.
- **Relaunch:** Required.

## 2026-10-03 — Owner calibration: May 2016 flew Berlin, drove Gorzów

- **Symptom:** May 2016 Home hops drawn as drives; titled with a Polish street and a garden.
- **Root cause:** Berlin–NL ~580 km matched overland; `al Róż` / Kleingarten named the route.
- **Fix:** Compact Berlin-area weekends fly Home hops (not Ukraine/Bavaria road trips);
  Polish `al ` streets and Kleingarten pins wipe. Epoch v35.
- **Files:** `HolisticCurationGeneration.swift`, `CuratorGeocoding.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testBerlin2016WeekendFliesHomeHopsAndKeepsGorzowDrive`.
- **Relaunch:** Required.

## 2026-10-04 — Owner calibration: Jan 2016 flew Berlin, drove Viechtach

- **Symptom:** Jan 2016 titled as a town list; Home hops drawn as drives.
- **Root cause:** Bavaria on the route blocked the compact-Berlin air rule; Hof /
  Sandersdorf named the Journey.
- **Fix:** Home ↔ Berlin-metro ≥400 km is air unless Ukraine is on the route;
  thin Hof / Sandersdorf drop. Epoch v36.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testViechtach2016FliesBerlinHopsDropsThinTransit`.
- **Relaunch:** Required.

## 2026-10-04 — Owner calibration: Stanicki Las is not a civil airport

- **Symptom:** Aug 2015 marked a forest pin as an air hop (Ukraine → Stanicki Las).
- **Root cause:** Fast-air speed matched a 650 km forest ping; no check for a passenger airport.
- **Fix:** Interior forest pins drop; fast air needs a civil-airport / Berlin-metro
  endpoint; Ukraine Home → Berlin with no NL bookend is a flight. Epoch v37.
- **Files:** `CuratorGeocoding.swift`, `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testUkraine2015DropsStanickiLasForestAndFliesToBerlin`.
- **Relaunch:** Required.

## 2026-10-04 — Owner calibration: June 2015 Berlin was a drive

- **Symptom:** Home ↔ Berlin ≥400 km was always air unless Ukraine+NL were both
  on the route, so the June 2015 car trip would flip to a flight after rebuild.
- **Root cause:** May/Jan 2016 flights and the June 2015 drive share the same
  corridor; elapsed time and stay size were ignored.
- **Fix:** NL ↔ Berlin is air only for a same-travel-day hop (≤18 h) or a thin
  Berlin bookend. Assumed departing Home is not flight evidence. Ukraine Home →
  Berlin with no NL bookend stays a flight. Epoch v38.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testJune2015BerlinDriveStaysOverland`;
  `testBerlin2016WeekendFliesHomeHopsAndKeepsGorzowDrive`;
  `testViechtach2016FliesBerlinHopsDropsThinTransit`;
  `testUkraine2015DropsStanickiLasForestAndFliesToBerlin`.
- **Relaunch:** Required.

## 2026-10-04 — Owner calibration: May 2015 Ivano-Frankivsk was a flight

- **Symptom:** Home ↔ Rynok Square (Ivano-Frankivsk) 1,447 km was overland and
  titled from the market square.
- **Root cause:** Any Ukraine destination blocked the ≥1,000 km Home-bound air
  rule, including a weekend that never visited Home in Ukraine.
- **Fix:** Ukraine stays overland only when Home in Ukraine is on the route.
  Square / Rynok labels wipe like other landmarks. Epoch v39.
- **Files:** `HolisticCurationGeneration.swift`, `CuratorGeocoding.swift`,
  `CatalogV2.swift`, tests, docs.
- **Verification:** `testMay2015IvanoWeekendFliesAndDropsRynokSquareTitle`;
  `testUkraine2018BukovelAssumesNLStartKeepsIvanoAndStaysOverland`.
- **Relaunch:** Required.

## 2026-10-04 — Owner calibration: April 2015 Berlin was overland

- **Symptom:** Title could leak Münster Hbf / Tiergarten; return Home hop was unknown.
- **Root cause:** `Hbf` / `Tiergarten` were not landmark wipes; the long Berlin →
  Home gap is still a drive (June 2015 rule).
- **Fix:** Treat Hbf / Bahnhof / Tiergarten as landmarks. Epoch v40.
- **Files:** `CuratorGeocoding.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testApril2015BerlinDriveWipesStationAndParkTitles`.
- **Relaunch:** Required.

## 2026-10-04 — Owner calibration: Nov 2014 left Ukraine via Kyiv

- **Symptom:** Journey started at Kyiv, skipped Home in Ukraine, and would invent
  an NL start after rebuild; Kyiv → NL looked like a Ukraine drive.
- **Root cause:** Any Ukraine hop with Home in Ukraine on the route stayed
  overland; assume-NL still fired when the trip ended at NL.
- **Fix:** Kyiv is a flight city (NL ↔ Kyiv air). Via-Kyiv one-way trips start
  at Home in Ukraine and do not invent NL. Epoch v41.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testNovember2014LeavesUkraineViaKyivWithoutInventingNLStart`;
  `testUkraine2018BukovelAssumesNLStartKeepsIvanoAndStaysOverland`.
- **Relaunch:** Required.

## 2026-10-04 — Owner calibration: Aug 2014 Turkey was a flight

- **Symptom:** Home in Ukraine ↔ Antalya 1,600 km was marked drive; Muratpaşa
  could leak into the title.
- **Root cause:** Live catalog predated the ≥1,000 km home-bound air rule;
  district label was not wiped.
- **Fix:** Lock Ukraine Home ↔ Turkey as air; wipe Muratpaşa. Epoch v42.
- **Files:** `CuratorGeocoding.swift`, `HolisticCurationGeneration.swift`,
  `CatalogV2.swift`, tests, docs.
- **Verification:** `testAugust2014TurkeyFliesFromUkraineHomeAndDropsMuratpasaTitle`.
- **Relaunch:** Required.

## 2026-10-04 — Owner calibration: June 2014 Slavs'ka keeps the village

- **Symptom:** Carpathian weekend started at Slavs'ka with no Home in Ukraine
  circle; a country retitle would drop the village.
- **Fix:** Assume/keep the Lviv start on a Ukraine-only return; a single-country
  village title stays. Epoch v43.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testJune2014SlavskaKeepsVillageTitleAndStartsAtUkraineHome`.
- **Relaunch:** Required.

## 2026-10-04 — Owner calibration: Apr 2014 USA already in California

- **Symptom:** California → Lviv 5.6 days later was unknown; a later Kyiv ping
  could keep the US trip open and invent a Ukraine start.
- **Fix:** Intercontinental home hops stay air up to 14 days. Arrival at Home
  in Ukraine after an ocean hop ends the Journey. Epoch v44.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testApril2014USAAlreadyInCaliforniaFliesHomeAndDropsLaterKyiv`.
- **Relaunch:** Required.

## 2026-10-04 — Owner calibration: Jan 2014 Bukovel is not an ocean airport

- **Symptom:** Ski weekend at Polianyts'ka was glued to California as if Bukovel
  had a transatlantic field; title listed Germany + Ukraine + USA.
- **Fix:** Return to Lviv after a Carpathian outing ends that Journey when the
  next hop is an ocean. Lviv ↔ Munich is air on a US circuit; Munich is a via
  and does not name it. Epoch v45.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testJanuary2014SplitsBukovelOutingFromMunichCaliforniaCircuit`.
- **Relaunch:** Required.

## 2026-10-04 — Owner calibration: Dec 2013 Kraków is a separate drive

- **Symptom:** San Carlos → Kraków → Lviv was one amalgam; California → Lviv
  22 days later was unknown.
- **Fix:** Split a 7-day gap before Kraków; allow a single ocean stay to close
  at Home in Ukraine within 28 days; Kraków (~295 km) is a Lviv car outing.
  Epoch v46.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testDecember2013SplitsKrakowDriveFromCaliforniaFlightHome`.
- **Relaunch:** Required.

## 2026-10-04 — Owner calibration: Jun 2013 already in California

- **Symptom:** Synevyr, California, Azov/Mariupol, and a Kyiv ping were one
  USA+Ukraine amalgam.
- **Fix:** Keep one ocean stay when a non-ocean week sits in the middle and
  California resumes; peel that week as a CA ↔ Ukraine flight; leftover
  Carpathian day is a Lviv outing; thin Kyiv after Azov drops. Epoch v47.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testJune2013SplitsCarpathianOutingAndAzovFlightFromCaliforniaStay`.
- **Relaunch:** Required.

## 2026-10-04 — Owner calibration: Apr 2013 is California, not Brisbane

- **Symptom:** A Bay Area spring stay titled *Spring in Brisbane* (Brisbane, CA).
- **Fix:** Wipe a famous city label when GPS is in another country; title from
  the USA box. Do not re-preserve or re-geocode the mismatch. Epoch v48.
- **Files:** `CuratorGeocoding.swift`, `HolisticCurationGeneration.swift`,
  `CatalogV2.swift`, tests, docs.
- **Verification:** `testApril2013CaliforniaStayDoesNotTitleBrisbane`.
- **Relaunch:** Required.

## 2026-10-04 — Owner calibration: 2012 Ukraine is three trips

- **Symptom:** Mariupol, Yaremche, and Odesa were one Romania+Ukraine amalgam.
- **Fix:** A 7-day gap finishes; a Carpathian theater stay does not absorb a far
  Ukraine city; a single far-Ukraine stay still qualifies; Yaremche is Ukraine
  not Romania. Epoch v49.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testJanuary2012SplitsMariupolCarpathiansAndOdesa`.
- **Relaunch:** Required.

## 2026-10-04 — Owner calibration: 2010–11 is Lviv life + Yaremche ski

- **Symptom:** Thin Berlin + months of no-GPS Lviv life + Yaremche titled
  Romania and Poland.
- **Fix:** Finish a thin leftover when back at Home in Ukraine; do not keep
  unlocated home weeks open for a ski trip months later. Epoch v50.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`, tests, docs.
- **Verification:** `testWinter2010YaremcheIsLvivSkiTripNotBerlinPoland`.
- **Relaunch:** Required.

## 2026-10-04 — Owner calibration: Jan 2010 Yasinya village title

- **Symptom:** Last catalog Journey is a Lviv ski weekend titled Yasinians'ka.
- **Fix:** Same as Slavs'ka — keep the village name, Home in Ukraine start/end.
  No epoch bump (already the v50 theater outing).
- **Files:** tests, docs.
- **Verification:** `testJanuary2010YasinyaKeepsVillageTitleAndStartsAtUkraineHome`.
- **Relaunch:** Not required for this lock.

## 2026-10-04 — Story rebuild modal on unique Home membership

- **Symptom:** After v50 relaunch, a Moments alert fired (`UNIQUE story_moments`)
  and the epoch never wrote; sidebar stayed on old amalgams.
- **Fix:** Exclusive Moment membership (newer Journey wins); persist skips
  duplicates; summary reload no longer surfaces projection errors as a modal.
- **Files:** `HolisticCurationGeneration.swift`, `CatalogV2.swift`,
  `CuratorController.swift`, tests, docs.
- **Verification:** `testDecember2013SplitsKrakowDriveFromCaliforniaFlightHome`.
- **Relaunch:** Required.