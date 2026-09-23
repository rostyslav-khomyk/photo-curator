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
  before local data can be erased. Folder/album absence is verified with bounded backoff because
  PhotoKit can briefly return a stale hierarchy after a successful change.
- Settings prepares an exact reset summary, revalidates it at confirmation, pauses curator work,
  waits for metadata/analysis tasks, blocks publication, and runs only the Photos-facing phases.
- Local erasure uses a restart boundary. The app quits after Photos verification; on the next launch
  generated state and Curator logs are removed and empty SQLite schemas are created before any
  controller opens them. The reset receipt remains outside the erased directories.
- `Reanalyze Entire Library...` reports the indexed-photo count, current cache size, and a rough
  utility-priority duration before confirmation. It requeues every Vision job in one transaction,
  clears rebuildable derived evidence, and resumes the event-driven scheduler without forcing a
  PhotoKit metadata rescan. Titles, choices, merges, publications, Significant Places, Favorites,
  and Google state remain intact.

## Current safety boundary

The destructive Settings action is enabled, but has not been exercised against the owner's live
library. Existing legacy albums have no creation proof and therefore cannot be deleted automatically;
the confirmation calls out that count and leaves those albums for manual review. Reset requires the
user to reopen the app after its safe quit boundary.

## Remaining gate

- Add `Rebuild Curation with Latest Algorithm...` and comparison acceptance.
- Test interruption at every durable phase, including app termination between Photos verification
  and local catalog erasure.
- Verify on a copied owner catalog and a Photos test library that unrelated same-named containers,
  assets, Favorites, Significant Places, Google authorization, and ordinary preferences survive.
