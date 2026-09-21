# Phase 2 Compact Moments Read Model

Status: implemented; automated gates pass, interactive performance qualification remains
Prepared: 2026-09-22

## Implementation

The Moments workspace now reads compact `MomentSummary` rows from Catalog v2. A card contains only
identity, revision, dates, display text, counts, publication flags, readiness flags, and up to three
cover asset identifiers. Full `PhotoMoment` membership and evidence are loaded only when review,
merge, publication, or Google export needs them.

The workspace no longer owns a growing array of full Moments or exposes `Load Older Moments`.
Summary filtering covers Photos and Google publication state, while the existing cursor and scroll
anchor restoration operate on stable Moment IDs. Legacy generation remains the writer until Phase 3;
each committed overview refresh mirrors its bounded changed projection into Catalog v2 in one
synchronous SQLite transaction.

Visible cards use a shared `PHCachingImageManager`, preheat their cover candidates, cancel stale
requests by summary revision, and retain an already-valid image while a newer request is pending.
The in-memory thumbnail cache is bounded to 96 MB and 360 entries.

## Production-Scale Validation

The current owner catalog was copied into the Catalog v2 workspace without deleting the legacy
catalog or changing Photos:

| Measure | Result |
| --- | ---: |
| Moments | 5,222 |
| Membership rows | 108,999 |
| Foreign-key violations | 0 |
| Optimized full workspace synchronization | 9.755 s |
| Warm all-summary query | 0.041 s |
| Full native suite | 210 tests, 12 skipped, 0 failures |
| Strict production concurrency build | 0 warnings |

An early synchronization attempt took about 27 minutes and peaked near 494 MB because
`INSERT OR REPLACE` deleted asset rows and triggered cascading membership work. True SQLite UPSERT
reduced the same synchronization to under ten seconds. Persisting two fallback cover IDs on the
summary row removed a 108,999-membership scan and reduced the warm query from 0.344 s to 0.041 s.

## Concurrency Boundary Cleanup

The strict build exposed old warnings outside Catalog v2. PhotoKit export now uses async operations
instead of global-queue completion chains and a semaphore-protected shared error variable.
Publication adapters have explicit `Sendable` contracts. The per-window keyboard monitor tracks a
scalar window number rather than reading an AppKit view from its callback. A clean
`-strict-concurrency=complete` production build now emits no warnings.

## Exit Gate

- [x] Moments workspace renders `MomentSummary` rather than full `PhotoMoment` graphs.
- [x] Detail, merge, publication, and Google export hydrate full Moments on demand.
- [x] Filters, cursor, and scroll restoration use stable summary identity.
- [x] Manual `Load Older Moments` pagination is removed.
- [x] Thumbnail requests are revision-aware, preheated, and memory-bounded.
- [x] Warm production-scale summary query is below the 50 ms target.
- [x] Native tests and complete strict-concurrency production build pass.
- [ ] Record packaged-app full-history scroll latency and steady-state RSS with Instruments.
- [ ] Verify keyboard, filtering, review, merge, Photos publication, and Google export in the
  packaged app on the owner library.
- [ ] Repeat responsiveness and memory measurements on the oldest supported Mac.

No catalog wipe or managed Photos-album deletion occurred in this phase.
