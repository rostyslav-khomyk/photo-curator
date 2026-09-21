# Phase 1 Catalog v2

Status: shadow catalog implemented and validated; no application cutover or catalog wipe  
Prepared: 2026-09-21

## Implementation

Catalog v2 is a WAL-mode SQLite database owned by one Swift actor. Its synchronous transaction
blocks contain no suspension points. It normalizes assets, Moments, membership, user edits, manual
asset decisions, meaningful places, reviewed groups, and Photos publication markers. Automatic
narrative data remains attached to the derived Moment while user-authored text is stored separately.
Publication state has one normalized authority.

The migration reads the existing SQLite index, `moments-catalog.json`, `group-review.json`, and the
app's UserDefaults snapshot. It estimates free-space requirements, imports in one transaction, checks
every expected row count and all foreign keys, and writes its completion marker only after those
checks pass. An interrupted or invalid migration rolls back and can be rerun safely.

Catalog v2 exposes compact `MomentSummary` rows and detail-on-demand loading. Durable manual-include
and protected-membership anchors feed the stable identity resolver. A unique anchored candidate
inherits the old UUID even when its surrounding membership changes; split or conflicting anchors
fail closed.

The shipping workspace still reads the legacy stores. There is no dual-write, UI change, Photos
mutation, automatic launch migration, or cutover in this phase.

## Real-Catalog Rehearsal

The opt-in test migrated the current owner catalog into the separate
`catalog-v2.sqlite3` shadow file without modifying the source catalog:

| Measure | Validated value |
| --- | ---: |
| Source assets | 108,999 |
| Moments | 5,222 |
| Membership rows | 108,999 |
| User-edited Moments | 17 |
| Manual asset decisions | 9 |
| Meaningful places | 2 |
| Reviewed groups | 18 |
| Photos publication markers | 2,982 |
| Foreign-key violations | 0 |
| Shadow database size | about 90 MB |
| Migration and query test | 1.8 s |

The test also loaded all compact summaries, opened one full Moment detail, and checked that its photo
count matched the summary. It compared every user title, description, protected membership, manual
photo decision, Photos album ID, and publication timestamp with the source snapshot. The source can
evolve while the old app remains authoritative, so these numbers describe the rehearsal snapshot
rather than a permanent library total.

Run the private rehearsal explicitly with:

```bash
PHOTO_CURATOR_PHASE1_CATALOG="$HOME/Library/Application Support/Photo Relay/curator" \
  swift test --filter CatalogV2Tests/testOptInCopiedRealCatalogMigration
```

Without that environment variable the private test is skipped and no owner data is read.

## Verification

- Full native suite: 210 tests, 12 intentional skips, zero failures.
- Catalog/identity suite: 7 tests, one opt-in skip, zero failures.
- Real-catalog rehearsal: passed, zero failures.
- Complete-concurrency build of the new Catalog v2 code: no Catalog v2 warnings.
- Clean production compilation: completed, but exposed pre-existing PhotoKit and publication
  concurrency warnings that the incremental Phase 0 check had missed. The Phase 0 warning gate is
  reopened until the baseline script performs a clean build and those warnings are resolved.

## Exit Gate

- [x] Normalized schema, constraints, WAL mode, and serialized writer ownership exist.
- [x] Legacy SQLite/JSON/UserDefaults state imports transactionally and idempotently.
- [x] Compact summary and detail-on-demand queries are tested.
- [x] Stable identity honors durable anchors and fails closed on ambiguity.
- [x] A copied real catalog passes count, query, and foreign-key validation.
- [x] Existing algorithms and UI behavior remain unchanged.
- [ ] Cutover remains blocked by the open Phase 0 interactive and warning gates.
