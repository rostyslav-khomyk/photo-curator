# Phase 6 Extension: Journey Stories

## Implementation status (2026-09-27)

The deterministic foundation and qualification projection are implemented. Catalog v2 derives closed
home-to-home journeys from compact Moment/GPS rows, requires multiple distant observations, tolerates
a brief Home capture from another family phone, preserves chronological child Moments, and gives
Journeys precedence over overlapping place-based Stories. Simultaneous coordinates more than 250 km
apart are treated as a likely multi-phone conflict only when one branch has at least twice the photo
support; the weaker branch remains in the Story but cannot steer its route or title. The builder falls
back to the existing outing builder when Home is unset or the route is weak/open.

Recorded coordinates are accepted only when finite, in geographic range, and not the invalid `0,0`
sentinel found in older imports. Journey titles consume ordered, verified Moment place labels when
available (`Journey to …` or `Journey via …`) and otherwise retain the honest
`Journey from Home` fallback until bounded geocoding enrichment completes.

Catalog schema v10 persists the typed `journey`/`outing` projection and compact ordered stop evidence
(time range, weighted centroid, Moment/photo support, known place, and confidence). Migrating from v8
invalidates only the rebuildable Story rows; photo analysis and user decisions remain intact.

An isolated copy of the owner catalog recognizes 36 Journeys and one outing, covering 746 Moments and
32,047 photos. Upgrading from v9 invalidates only the rebuildable Story rows once so existing
catalogs receive transport evidence without reindexing or reanalysis. The 2022 journey contains 72 Moments and 9,865 photos (July 16-August 17), while the
2026 journey contains 37 Moments and 2,235 photos (July 20-August 5). Rebuilding the full Story
projection takes 0.9 seconds off the main actor. Catalog synchronization skips that work when the
Moment revision fingerprint is unchanged.

Stop locality enrichment now uses `MKReverseGeocodingRequest` on macOS 26 or later, falls back to
`CLGeocoder` on older supported systems, and stores results in the rebuildable derived cache. The
existing scheduler resolves four unique stops per low-priority pass, yields for five seconds, and
backs off for an hour after a completed sweep. Users can disable Journey naming in Settings; no photo
pixels are sent with the coordinate lookup. Failed lookups remain unnamed and never block curation.

The copied owner audit populated 54 durable place records in its first bounded sweep. A clean Story
rebuild then produced grounded names through 2024, including `Journey via Fréjus, Fontainebleau, and
Reims` for the 2026 France route. Remaining older Stories honestly retain `Journey from Home` until a
later cached retry succeeds.

Adjacent stop evidence now persists conservative distance/time transport candidates. The copied
owner audit classified 127 legs as overland, 14 as plausible air travel, and left 42 unknown. All 28
legs in the 2022 road trip classify as overland. Air inference rejects sub-30-minute jumps and speeds
outside 180-1,100 km/h so interleaved family-phone coordinates do not become impossible flights.

Bounded cached Vision/OCR support now strengthens matching geometric candidates without
changing membership or mode. See the [living map](CURATION_ALGORITHM.md) for sampling,
phrase coverage and confidence rules. It is connected to the scheduler and persists
support counts with stale-result rejection; no new image analysis is requested.

MapKit route validation, maps, manual Story editing, country-level
naming, and Apple Intelligence narratives remain later slices.

## Goal

Complete the `Story -> Moment -> Highlight` hierarchy by recognizing an entire home-to-home journey,
not merely repeated photographs at its lodging or most frequent place. A family vacation may use one
base, visit several cities, contain travel-only photographs, and combine several phones. Those are
ordered parts of one Story while remaining independently reviewable Moments.

Examples for the owner benchmark:

- The July-August 2026 Fréjus period is a France vacation Story. Fréjus is its base; Saint-Tropez,
  Saint-Aygulf, and travel legs remain child Moments.
- The July-August 2022 sequence is one road-trip Story beginning and ending near Home, with Weyarn,
  Salzburg, Verona, Milan, Turin, Florence, Rome, Naples, Vatican, Rimini, and the return route as
  ordered child Moments.

## Evidence hierarchy

Journey inference is conservative and evidence-weighted:

1. **Hard anchors:** capture time, recorded GPS, and user-defined Home/Work regions.
2. **Derived stops:** spatially clustered GPS observations with arrival, departure, duration, and
   representative locality. Contributions from several phones are deduplicated by time and place.
3. **Continuity:** chronological movement between stops, nights away from Home, short missing-GPS
   gaps, and return to Home.
4. **Transport support:** displacement and elapsed time first; cached local Vision labels and OCR may
   support car, train, airport, aircraft, ferry, or boarding evidence. They never establish a route
   by themselves.
5. **Optional MapKit validation:** `MKDirections` may validate plausible road legs and provide route
   distance/time. It is enrichment, not required input, because directions use Apple servers and
   historical traffic cannot be reconstructed reliably.

Unknown evidence remains unknown. A coordinate jump without enough context creates an unspecified
travel leg, not a confident flight. Missing GPS must not split an otherwise coherent journey.

## Journey boundary rules

- Start when the timeline leaves the Home region and establishes a non-routine stop.
- End on a sustained return to Home, or when a long ordinary-life interval makes continuity
  implausible.
- Permit multi-week journeys; do not impose a photo-count limit.
- Keep brief excursions and transit stops inside the enclosing journey.
- Do not create a Journey Story for ordinary Home/Work movement, isolated GPS errors, or recurring
  local errands.
- Prefer one larger defensible Story over several place-named Stories when the home-to-home movement
  chain is continuous.

## Data model

Keep the existing normalized `stories` and `story_moments` tables. Add only rebuildable Journey
evidence needed for explanation and testing:

- story kind (`journey` or `outing`);
- ordered stop summaries: time interval, coordinate centroid, locality, and confidence;
- transport-leg summaries (mode candidate, straight-line distance, elapsed time, and confidence);
- later: boundary explanation and algorithm version.

Photo membership remains authoritative in Moments. Stories reference Moment IDs and never duplicate
asset membership. User-reviewed Story membership becomes a protected anchor during later rebuilds.

## Remaining implementation sequence

1. Run the in-app Historical Metadata Audit (Diagnostics) to measure album names,
   captions and keywords on pre-2007 photos before expanding unlocated Story work.
2. Qualify the newly connected cached Vision/OCR confidence support on an isolated
   owner-catalog/cache copy before expanding phrases or specializing transport modes.
3. Add optional, cached MapKit road validation behind an explicit privacy setting. Never issue one
   network request per photo; route only between deduplicated stops.
4. Show a Story timeline/map and the evidence behind uncertain boundaries. Allow split, merge, and
   title corrections without changing child Moment membership.
5. Complete clean-room qualification before enabling route validation or model enrichment.

## macOS 27 Apple Intelligence

Use Apple Intelligence as a runtime-gated interpretation layer, never as the authority for Story
membership:

- The deterministic builder supplies an ordered, compact route dossier: home departure/return,
  stops, dates, distances, candidate transport legs, locality names, and confidence-bearing evidence.
- On Apple Intelligence-capable Macs, Foundation Models guided generation returns a typed Story
  title, synopsis, trip kind, transport interpretation, and uncertainty notes. It may not add stops,
  dates, people, or transport claims absent from the dossier.
- macOS 27 multimodal prompts may inspect only bounded representative images, not every photo.
  Built-in Vision tools can request OCR or classification when needed; existing cached Vision/OCR
  results remain the first choice.
- Tool calls expose read-only catalog queries such as `listStops`, `routeLeg`, and
  `representativeEvidence`. The model never mutates SQLite, Photos, or Story membership.
- The on-device model is preferred and works offline. Private Cloud Compute is a separately disclosed,
  explicit opt-in for unusually complex Stories; absence, unsupported language, guardrail refusal,
  or context limits fall back to deterministic titles without blocking curation.
- Cache results by algorithm, model, prompt, and evidence versions. Never regenerate unchanged
  Stories merely because the app relaunched.
- Use the macOS 27 Evaluations framework plus the frozen owner benchmark to measure groundedness,
  title usefulness, unsupported transport claims, latency, and fallback behavior before release.

Keep the macOS 13 deployment target for now. Compile and runtime availability checks isolate the
macOS 27 enrichment so friends with older supported Macs still receive identical route grouping and
safe deterministic narratives.

## Qualification

Automated fixtures must cover road trip, flight, train/ferry ambiguity, multiple contributing phones,
GPS gaps, false GPS outliers, a local day outing, routine commuting, and interrupted processing.

Owner acceptance criteria:

- 2022 is recognized as one home-to-home road-trip Story with ordered major stops.
- 2026 Fréjus is represented as one France vacation Story rather than competing city Stories.
- no Home/Work month becomes a Journey Story;
- no reviewed Moment membership or Highlights change;
- rebuilding is deterministic and idempotent;
- Story generation uses compact catalog rows, remains off the main actor, and does not materially
  affect workspace scrolling or startup;
- all network enrichment is optional, bounded, cached, and visibly disclosed.

## Apple platform basis

- MapKit directions provide route distance and expected travel time:
  <https://developer.apple.com/documentation/mapkit/mkroute/distance>
- Vision classification provides local labels with confidence values:
  <https://developer.apple.com/documentation/vision/classifying-images-for-categorization-and-search>
- Core Location supplies coordinate distance and geocoding primitives:
  <https://developer.apple.com/documentation/corelocation>
- macOS 27 Foundation Models adds multimodal prompts, Vision tools, dynamic profiles, and model
  providers: <https://developer.apple.com/macos/whats-new/>
- Guided generation and tool calling produce constrained Swift structures:
  <https://developer.apple.com/documentation/FoundationModels>
- The Evaluations framework measures model behavior across a frozen test corpus:
  <https://developer.apple.com/videos/play/wwdc2026/241/>
