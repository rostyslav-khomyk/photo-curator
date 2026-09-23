# Phase 6: Holistic Curation Generations

## Implemented foundation

- Catalog schema version 6 stores immutable candidate Moment snapshots and aggregate metrics without
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
- Optional Story parents require repeated strong place identity across adjacent Moments. They do not
  replace Moments or infer meaning from busy months.
- Hierarchical highlights first allocate representative photos per Moment, then allocate Story-level
  highlights from those representatives. Favorites and manual includes are hard constraints when
  present, but the allocator works without Favorites.

## Library Overview

The Moments toolbar now exposes an aggregate-only monthly density view built from compact summaries.
It loads no photo pixels and describes low-volume periods as quiet capture periods, not unimportant
life periods.

## Deliberate hold

The shipping UI does not yet start or activate a full-library candidate. Before that switch is
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
- Integrate current evidence, narrative, and hierarchical-highlight pipelines, then rerun the copied
  owner-corpus comparison until the structural gate passes.
- Freeze and execute the private reviewed benchmark.
- Measure generation time, peak RSS, WAL growth, and overview query latency on the owner library.
- Connect the scheduler's bounded full-library generation job and candidate comparison sheet only
  after those results pass independent review.
