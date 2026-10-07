# Resume checkpoint — Release Candidate

Recorded 2026-10-03 after Americas circuit / merge-route repair (Grand Rapids +
Panama must be one Journey; mid-route Home zigzags removed).

## Memorized gold UX

- Sidebar lists **only finalized** Journeys. Unresolved `Journey from Home` shells
  stay in the catalog for enrichment but do not flicker in the side panel. Seasonal
  names (`Summer holidays in France`) and saved renames count as finalized.
- Titles ignore secondary Home places (`Home in Ukraine`) and street/landmark labels;
  country/season/year names replace town lists when coordinates agree (US box → **USA**;
  USA+Panama circuits → **Americas**). Owner-calibrated transport: Europe road
  holidays stay overland; Home hops ≥1,000 km are air even with a quiet week;
  Ireland/UK ↔ Home ≥200 km is air. Thin UK pings before return Home drop.
  Portugal + Greece in one week is one flight circuit (not a drive to Caparica).
  Schiphol / Home-orbit airport photos confirm air (Barcelona Apr 2025) and stay
  unmerged from the Home circle.   A one-hour German ping (Steigra) on a Rhodes
  flight day is dropped. Crete 2023 is `Summer holidays in Crete` with Home
  circles across quiet days (7-day lookback / 14-day return). Jul 2022 Italy is
  one Home-to-Home road trip (German stops stay; not a Steigra-style drop).
  Jan 2022 and Jan 2018 are drives NL ↔ Home in Ukraine with a Bukovel ski stay
  (not a flight). Missing departing GPS still assumes the NL start; Ivano-Frankivsk stays.
  Jul–Aug 2021 is one Central Europe road trip (Dresden–Prague–Kraków, Ukraine
  Home stay, then Košice–Hungary–Austria–NL).   France 2020 is a Home-to-Home
  drive (`Summer holidays in France`). May 2017 Paris is a drive, titled Paris / France,
  not Disneyland. Oct 2019 Brussels is a drive, titled
  Belgium, not Mini-Europe. Jul–Aug 2019 is one Ukraine circuit (Carpathian
  weekends plus the drive home via Berlin), not three Journeys. Jun 2019 London
  is a flight both ways, titled United Kingdom, not the school. Nov 2018
  Barcelona is a flight both ways, titled Spain, not the church. Jul–Aug 2018
  is one drive (NL → Berlin → Ukraine stay → Pylypets → NL). DSLR / RAW
  photos without GPS take the expensive Vision/OCR lane (priority 80).
  May 2016 Berlin is fly NL ↔ Berlin, drive to Gorzów and back, fly home
  (street/garden pins drop; Oranienburg stays local). Jan 2016 is fly NL ↔
  Berlin, drive the Viechtach loop, fly home (Hof / Sandersdorf drop).
  Aug 2015 Ukraine → Berlin is a flight; Stanicki Las is a forest, not an airport.
  June 2015 NL ↔ Berlin is a drive (not the 2016 flight pattern).
  May 2015 NL ↔ Ivano-Frankivsk is a flight, titled Ukraine, not Rynok Square.
  April 2015 NL ↔ Berlin is overland (train/car), titled Germany / Berlin,
  not Münster Hbf or Tiergarten.
  Nov 2014 is one-way Home in Ukraine → Kyiv → NL (no invented NL start);
  Kyiv → NL is air. Aug 2014 Turkey is a flight from Home in Ukraine and back;
  titled Turkey, not Muratpaşa. June 2014 Slavs'ka is a drive from Home in
  Ukraine; the village title stays (single-country stay). Apr 2014 USA starts
  already in California (no invented Home); Bay Area ↔ Austin and California →
  Lviv are air; a later Kyiv ping is leftover. Jan 2014 Bukovel is a Lviv
  outing (no ocean airport); the long hop is Lviv → Munich → California →
  Munich → Lviv, titled USA. Dec 2013 is a one-way California → Lviv flight;
  Kraków is a separate car outing from Home in Ukraine. Jun–Nov 2013 is already
  living in California (one USA stay); the Jun 16 Carpathians day is a leftover
  Lviv outing; August Azov/Mariupol is a separate CA ↔ Ukraine flight; the Kyiv
  ping is leftover. Apr 2013 is already in California; title USA, not Brisbane
  (the Bay Area town must not read as Australia). Jan–Mar 2012 is three Ukraine
  trips (Mariupol, Yaremche, Odesa), not one Romania+Ukraine amalgam.
  Sep 2010–Jan 2011 is living in Lviv plus a Yaremche ski trip — not Berlin / Poland /
  Romania. Thin Berlin leftover drops. Jan 2010 Yasinya is another Lviv ski trip;
  the village title stays. That is the oldest Journey in the catalog.
  Device EXIF/make-model will backfill from PhotoKit newest-first as a test signal
  (not a baked-in family phone list).
  Thin messenger pings do not bend the route. Mapped Homes can start/end a Journey
  (green/orange circles) but never sit mid-route. Owners can rename, merge, or
  Refresh Journey Names; map flags filter Moments. Merges re-sanitize stops.
- **Home orbit (~80 km) is not travel.** Zundert/Breda/Reeuwijk-style days and
  IJsselstein/Badhoevedorp evenings stay outings; a *sustained* return to that
  orbit ends a Journey so Ireland and Bucharest do not merge. Dense or thin Home
  Moments while distant GPS resumes within three days (Grand Rapids → Panama) keep
  one Americas Journey. Distant travel clears 100 km.
- Thin messenger abroad pings do not title beside richer destinations; a lone
  local outing + thin Lviv ping is not a Journey.
- Adaptive evidence **defers** GPS-rich Vision/OCR while claimable thin work
  remains; soft-deferred thin retries must not stall the claim gate.
- Journey stop geocode runs **before** the OCR interleave on the shared scheduler.
- Photos albums update in place after the first save, using the stored album ID:
  rename, move to the current Story folder, and exact membership. Automatic saving
  re-syncs changed published Moments. This is unit-tested with a fake adapter;
  the live PhotoKit path is unverified until the first real save.
- iCloud-only photos (optimized storage) download a ~1024 px derivative for
  Vision/OCR. OCR escalates to the original only on failure or low confidence.
  Downloads pause below 10 GB of free disk. Before this, every such photo was
  deferred hourly forever, which showed up as `deferred` ≫ `saved` in telemetry.
- Photos full-access clicker must target process name `PhotoCurator` (ad-hoc
  resign re-prompts; a missed click stalls prep while telemetry can still look ok).
- The Moments grid and Story list stay scrollable during a library overview.
  Workspace commands live in the window toolbar. Do not strip
  `fullSizeContentView` or force the title bar opaque: SwiftUI's safe-area top
  inset is what keeps All Moments and Journey titles below the toolbar. The
  sidebar List and detail column must keep `idealHeight: 0`, or a long Journey
  list sizes the split taller than the window and All Moments hangs off the top. Do not swizzle NSScrollView frames. Inset repair must not
  cover the window or take scroll events.

Peak finalized titles observed this soak (quality bar to preserve): Bucharest,
Barcelona/France/Reims, Bruges/Ghent, Athens/Greece, Rhodes/Symi, Paris, Cologne/Lviv,
and similar multi-city grounded names — not dozens of identical `Journey from Home`,
and not Greece+IJsselstein or Ireland+Bucharest amalgams.

## Open gaps (not blocking this RC)

1. ~~**Preserve geocoded Journey evidence across `rebuildStories`**~~ — shipped 2026-09-28 afternoon (retain city labels by coordinate; soak probe detects wipe + telemetry stall).
2. ~~**Fast Journey title recovery after wipe**~~ — shipped 2026-09-28 afternoon (every-step geocode + larger batch while shells dominate; probe errors on geocode stall).
3. ~~**MapKit / route visualization**~~ — shipped 2026-09-28 (Story map from stop evidence; optional Apple Maps road routes behind Settings).
4. ~~**Hierarchical Story highlight allocator**~~ — wired 2026-09-28 on `rebuildStories` (Story count/cover from curated set; Moments stay independently editable).
5. ~~**Journey local-orbit / split-trip common sense**~~ — shipped 2026-09-28 evening (100 km distant / 80 km orbit; Home-region return finishes; thin-ping title filter).
6. ~~**Adaptive day-gap in shipping Moments + candidate Maintenance UI**~~ — shipping day gaps use adaptive cadence; shadow routine-singleton build/compare/activate/rollback stay in the controller; Settings UI removed 2026-10-05 (Activate still needs owner false-join/false-split benchmark).
7. ~~**Broader transport OCR**~~ — expanded multilingual boarding/station/toll/ferry phrases; label∧OCR AND-gate kept; car/train/ferry mode split deferred.
8. ~~**Lighter modern no-GPS priority band**~~ — bursts/animated/livePhotos mid-band 45; ordinary modern no-GPS photos stay 65.
9. ~~**Grounded Story narratives + corrections/uncertainty**~~ — deterministic synopsis candidates, `story_edits`, Story chrome uncertainty line.

**Out of RC scope as GPS routes:** invented pins for pre-2010 life. Last-resort
experimental Journeys now project on `rebuildStories` (`v55-unlocated-full-names`)
from time + faces + filename leftovers. Empty stops; no year-glue. Same-season
rest days rejoin; sparse household-only months stay out. Titles list household
plus quieter guests by full name. Settings → Experimental → “Use experimental
extended access to Photos metadata” (default on) gates the whole pass. Settings
no longer shows storage summary, shadow curation, rollback, reanalyze, or
Diagnostics; Reset stays. Analysis uses up to 3 Vision/thumbnail lanes; one SQLite
writer. Pre-2010 no-GPS photos stay priority 80 so scene splits and highlights
can catch up. Sqlite signals are not guaranteed across macOS updates.

Current source audit: [Curation algorithm](CURATION_ALGORITHM.md).
Soak ops: [SOAK_AGENT.md](SOAK_AGENT.md), [SOAK_FIX_LOG.md](SOAK_FIX_LOG.md).
