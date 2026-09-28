# Phase 6: Holistic Curation Generations and Stories

## Implemented foundation

- Catalog schema version 10 stores immutable candidate Moment snapshots, aggregate metrics, and
  normalized Story parents without
  duplicating indexed photo payloads.
- Candidate staging is one synchronous SQLite transaction. Unknown, duplicate, missing, or partial
  asset membership fails before a candidate becomes complete.
- Active and candidate summaries are separate read models. Building a candidate cannot alter the
  Moments workspace.
- Activation requires equal corpus coverage and reviewed false-join/false-split measurements. False
  joins carry three times the comparison cost of false splits.
- A separate structural gate rejects increased fragmented days, generic titles, or complete loss of
  an existing highlight layer even if benchmark error counts improve. Raw Moment size is diagnostic,
  not a failure: a coherent first visit to a significant venue may legitimately contain hundreds of
  photos from several family phones.
- Activation and rollback replace the active derived projection in one transaction. User edits,
  protected membership, Photos publication receipts, and unfinished publication operations must
  retain their Moment identities or activation fails closed.
- A source catalog fingerprint rejects a candidate if active Moments changed while it was built.
- Identity reconciliation gives protected asset anchors precedence and rejects ambiguous protected
  splits or merges.

## Candidate algorithm

- Logical days use the supplied calendar and time zone.
- Within each day, local capture cadence sets a bounded gap threshold. Strong place conflicts,
  recorded distance, calibrated boundary evidence, and long pauses can create a boundary.
- Missing GPS, OCR, or visual evidence remains unknown rather than negative evidence.
- Season and capture density never alter event boundaries.
- Large Moments split only on supported event boundaries, never because they exceed a photo-count
  threshold. Overlapping captures and near-duplicates from family phones remain in the shared event;
  highlight selection suppresses redundant alternatives without fragmenting the Moment.
- A bounded second pass may combine uncurated singleton captures across days when they share a
  user-defined habitual place and calendar month. Everyday photographs and reference-memory photos
  remain separate roles. Favorites, reviewed/customized Moments, published Moments, and large event
  visits are never changed by this pass.
- Optional Story parents require repeated non-routine place identity across adjacent Moments. City
  districts roll up to their city, a base place may bridge short excursions, and arrival/departure
  shoulders are retained. Stories do not replace Moments or infer meaning from busy months.
- Hierarchical highlights first allocate representative photos per Moment, then allocate Story-level
  highlights from those representatives. Favorites and manual includes are hard constraints when
  present, but the allocator works without Favorites.

## Library Overview

The Moments toolbar now exposes an aggregate-only monthly density view built from compact summaries.
It loads no photo pixels and describes low-volume periods as quiet capture periods, not unimportant
life periods.

## Shipping hierarchy

The workspace now presents `Story -> Moment -> Highlight`: a compact Story shelf opens the ordered
child Moments, and each Moment retains its independently editable highlights. Story membership is a
small rebuildable SQLite projection, not duplicated photo membership. The owner-catalog rehearsal
rebuilds the projection in roughly 30 ms and recognizes the Fréjus family trip while preserving its
scene-level Moments. Same-day continuations such as Efteling and city districts such as Amsterdam
are covered by deterministic tests.

The deterministic foundation of [Journey Stories](PHASE6_JOURNEY_STORIES.md) now infers closed
home-to-home trips from the complete GPS timeline, preserves ordered child Moments, bridges bounded
missing-location gaps, and supersedes treating a vacation base such as Fréjus as the whole Story.
Distance/time transport candidates and bounded cached locality naming are now implemented.
Bounded cached Vision/OCR transport support is connected; route validation and maps remain planned. See the
[living algorithm map](CURATION_ALGORITHM.md) for the distinction between shipping
paths, candidate-generation gates and the disconnected Story highlight allocator.

## Deliberate hold

The shipping UI still does not activate a full-library candidate generation. Stories are safe to
derive because they do not change Moment membership, titles, reviews, or publication. Before the
candidate activation switch is
exposed, run the current 108,999-photo corpus audit and the private owner-reviewed benchmark through
the generation API. The benchmark must report false joins and false splits separately. Candidate
activation is intentionally impossible when either measurement is missing.

Grounded narrative generation continues to use the existing local evidence and information scoring
pipeline. Candidate generation must reuse that pipeline rather than introduce a second title system.

## Automated coverage

- isolated candidate staging and transaction rollback;
- exact corpus membership validation;
- atomic activation and rollback;
- stale-source rejection;
- timezone-aware logical days and adaptive cadence;
- strong GPS/place conflict and missing-evidence behavior;
- deterministic identities, protected anchors, and ambiguous-split rejection;
- false-join-weighted comparison and benchmark-required activation;
- seasonality-only overview aggregation;
- conservative Stories and highlight allocation without Favorites.

## Remaining qualification

- The 2026-09-23 copied owner-catalog migration passed for 109,007 assets and 5,206 Moments in 8.3
  seconds, with zero validation failures, a 27 ms warm summary query, and about 348 MB maximum RSS.
- The first complete-corpus candidate generated and staged in 3.24 seconds with about 500 MB maximum
  test-process RSS. It was correctly rejected: Moments increased from 5,206 to 7,269, fragmented
  days from 28 to 316, and the candidate did not yet carry narratives or highlights. The isolated
  candidate snapshot grew the copied catalog from about 127 MB to 269 MB.
- A second candidate used the active catalog as its trusted event baseline and added only habitual-
  place singleton refinement. On the same 109,007-photo corpus it staged in 2.85 seconds and reduced
  Moments from 5,206 to 5,001, singletons from 1,677 to 1,385, small Moments from 2,952 to 2,719, and
  fragmented days from 31 to 29. It preserved all 14,261 highlights, 266 large Moments, and 20 giant
  Moments. The result contained 77 everyday rollups (269 photos) and 10 reference-memory rollups
  (23 photos). It passes the structural gate but remains ineligible for activation without reviewed
  false-join and false-split measurements.
- Freeze and execute the private reviewed benchmark.
- Measure generation time, peak RSS, WAL growth, and overview query latency on the owner library.
- Connect the scheduler's bounded full-library generation job and candidate comparison sheet only
  after those results pass independent review.
