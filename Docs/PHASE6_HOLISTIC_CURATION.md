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

- Run the opt-in copied owner catalog migration and full candidate comparison.
- Freeze and execute the private reviewed benchmark.
- Measure generation time, peak RSS, WAL growth, and overview query latency on the owner library.
- Connect the scheduler's bounded full-library generation job and candidate comparison sheet only
  after those results pass independent review.
