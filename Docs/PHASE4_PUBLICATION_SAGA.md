# Phase 4 Publication Saga

Status: implemented; automated gates pass, live forced-termination qualification remains
Prepared: 2026-09-23

## Durable State

Photos publication is now a Catalog v2 saga with four explicit states: `requested`, `applying`,
`verifying`, and `succeeded`. The immutable request, provisional receipt, verification attempts,
retry time, and last typed failure live in the WAL-mode SQLite catalog. The former per-Moment JSON
publication journal and legacy JSON publication-marker write path are no longer used.

The `succeeded` transition and the user-visible `publications` marker commit in one SQLite
transaction. Moment regeneration preserves both the saga row and marker while replacing derived
Moment membership, so an overview refresh cannot lose a confirmed receipt.

No SQLite transaction crosses an `await`. PhotoKit mutation and verification happen outside the
Catalog actor; each state transition is a short synchronous transaction.

## One Coordinator

`PublicationCoordinator` owns every manual and automatic Photos save. It serializes work per Moment,
recovers unfinished operations at startup, and rejects a changed request while an immutable operation
is active. Automatic publication schedules another verification rather than blacklisting a Moment
while Photos is still converging.

PhotoKit recovery distinguishes three outcomes:

- confirmed album with exact asset membership;
- confirmed absence, which permits a bounded retry through the title-idempotent managed-album path;
- conflicting membership, which fails closed and leaves the album unchanged.

Verification uses short bounded backoff so a cold or asynchronously updated Photos library has time
to expose the change. Errors shown to the user are typed and actionable instead of raw enum codes.

## Automated Coverage

- success followed by relaunch does not repeat the PhotoKit effect;
- a lost PhotoKit response recovers the existing album;
- termination after `applying` recovers a confirmed effect;
- repeated confirmed absence retries through the idempotent adapter;
- conflicting destination contents never trigger another mutation;
- cancellation before the external effect leaves resumable durable state;
- a changed request cannot replace an in-flight immutable intent;
- Moment refresh preserves the saga and publication marker;
- only the atomic `succeeded` transition makes a Moment appear in Photos.

## Exit Gate

- [x] Publication operation state and published marker share Catalog v2.
- [x] SQLite transactions contain no asynchronous suspension points.
- [x] Manual and automatic saves route through one coordinator.
- [x] Startup reconciles unfinished publication operations.
- [x] Verification has bounded backoff and fails closed on conflicting membership.
- [x] Automated forced-interruption matrix produces no duplicate effects or lost receipts.
- [x] Full native suite passes: 214 tests, 12 opt-in skips, zero failures.
- [x] Strict production build passes complete concurrency checking with zero warnings.
- [ ] Repeat the forced-termination matrix against a copied owner Photos library.
- [ ] Record packaged-app publication and UI-responsiveness signposts with Instruments.

No catalog wipe, managed Photos-album deletion, packaged-app deployment, or live Photos mutation
occurred in this phase.
