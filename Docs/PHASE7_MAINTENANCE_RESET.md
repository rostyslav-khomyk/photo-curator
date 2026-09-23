# Phase 7: Maintenance and Nuclear Reset

## Implemented foundation

- Catalog v2 schema 7 records PhotoKit containers only when the publication operation proves that
  Photo Curator created them. Each record keeps its stable local identifier, kind, and recorded
  parent identifier.
- Publication verification preserves creation evidence from the durable apply receipt. A recovery
  that began without a receipt remains conservatively unowned rather than inferring ownership from
  a title.
- PhotoKit reset operations verify exact identifiers and parent-child relationships. They never use
  `Photo Curator`, year, or album titles as deletion authority.
- The reset journal lives outside data intended for erasure and advances through requested,
  container deletion, Photos verification, local erasure, catalog recreation, and completion.
- Reset replay is idempotent. Photos asset and Favorite counts must match the pre-reset snapshot
  before local data can be erased.

## Current safety boundary

The destructive Settings action is not enabled yet. Existing legacy albums have no creation proof
and therefore cannot be deleted automatically. They remain visible for manual review. The next
checkpoint must quiesce all owners, finish local erasure/recreation at launch without open SQLite
handles, resume an interrupted journal, and expose exact counts in the confirmation sheet.

## Remaining gate

- Add `Rebuild Curation with Latest Algorithm...` and comparison acceptance.
- Add full evidence invalidation with time and disk estimates.
- Add the nuclear confirmation and safe relaunch path.
- Test interruption at every durable phase, including app termination between Photos verification
  and local catalog erasure.
- Verify on a copied owner catalog and a Photos test library that unrelated same-named containers,
  assets, Favorites, Significant Places, Google authorization, and ordinary preferences survive.
