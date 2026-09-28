# Journey audit: evidence coverage and difficult cases

## Verdict

The bounded transport-support pass preserves existing membership and transport
modes, but produced no confidence improvements on this snapshot. Do not interpret
the passing regression test as proof of useful transport enrichment. Evidence
availability and unlocated historical journeys require work before route enrichment.

## Method

SQLite online backups of the live catalog and derived cache were made independently
on 2026-09-27 into a temporary audit directory. No Photos operations, image requests,
network geocoding, resets or live catalog writes were performed. Independent backups
are not a cross-database atomic snapshot; small concurrent differences are possible.

The live catalog had no Story tables. Opening the copy with current code created
the schema, and `rebuildStories` derived the baseline. This audit therefore compares
current-code baseline against enriched current-code output, not the running app's
existing Stories. Locality network enrichment was not rerun, so titles differ from
earlier naming audits without proving a naming regression.

The opt-in `JourneyLibraryAuditTests.testOptInIsolatedJourneyTransportAudit`:

- builds all Stories from the copied catalog;
- exercises the production catalog enrichment method through all 183 legs;
- reads the same revision-validated label/OCR cache APIs as the worker;
- asserts unchanged Story IDs, child membership, photo counts and transport modes;
- checks that the August 2020 and July 2022/2026 target Journeys exist;
- inspects cache coverage for all 2020 and pre-2007 assets using UTC year boundaries.

Run with `PHOTO_CURATOR_JOURNEY_AUDIT_COPY` pointing to a temporary directory named
`photocurator-audit-*` containing `catalog.sqlite3` and `cache.sqlite3`, then
`swift test --filter JourneyLibraryAuditTests`. Use SQLite `.backup`, not a bare
copy of a database with an active WAL. The audit intentionally mutates the copies.

## Target results

| Case | Derived result | Transport | Qualification |
| --- | --- | --- | --- |
| 2020 France period | One Journey, Aug 9-30; 45 Moments, 3,549 photos, 7 stops | 6 overland legs | Detected despite sparse GPS; exact trip boundaries still require owner review |
| 2022 road trip | One Journey, Jul 16-Aug 17; 72 Moments, 9,865 photos, 29 stops | 28 overland legs | Membership retained; no new confidence support |
| 2026 France period | One Journey, Jul 20-Aug 5; 37 Moments, 2,235 photos, 7 stops | 5 overland, 1 unknown | Membership retained; unknown was not forced into a mode |
| Pre-2007 collection | 4,566 photos in 410 Moments, 79 singleton Moments; no Stories | No route inference | Historical local-journey discovery is unsupported by available evidence |

The 2020 year has 4,716 photos, 907 with coordinates and 3,809 without. The
identified August Journey includes unlocated photos through temporal membership;
it is not evidence that completely unlocated journeys are supported. Its stop
coordinates are compatible with the Paris area, Lyon area and southern France,
but precise place verification and owner acceptance were not performed.

All 4,566 pre-2007 photos lack coordinates. They also have no OCR cache entries,
no usable paired OCR/visual cache results, and no persisted Moment narratives.
This prevents distinguishing which of the 410 Moments represent local journeys.
The largest Moment has 339 photos over roughly three minutes: a useful compressed-
timestamp edge case, not proof by itself of an incorrect group. There is also one
1969-dated asset; its date validity needs separate evidence.

## Evidence coverage

| Measure | Result |
| --- | --- |
| Catalog assets | 110,953 |
| Assets with any OCR cache record | 96,499 |
| OCR records matching current catalog revision | 1,940 |
| 2020 assets with any OCR | 4,614 |
| 2020 OCR matching current revision | 2 |
| Transport sample, excluding screenshots | 2,113 photo inspections |
| Transport sample with usable paired caches | 107 (5.1%) |
| Sampled visual air / overland matches | 0 / 1 |
| Sampled photos with high-confidence OCR lines | 20 |
| Paired transport-support matches | 0 |
| Confidence changes | 0 |

Photo inspections can overlap between neighboring leg samples; these are not
unique-library-photo coverage counts. The production pass selects at most the
first 24 member assets per leg's time window. It may miss later evidence.

Sampled 2020 mismatches show newer catalog modification timestamps and older
cached revisions, even with the same dimensions. Both cache and runtime report
macOS build 26A428, so an OS-engine version mismatch does not explain those samples.
The snapshot cannot establish whether pixel edits, metadata-only changes or another
operation changed the dates. Do not bypass revision validation to inflate coverage.

## Performance and safety

The first run took 0.85 s to rebuild the projection and 1.47 s to enrich 183 legs.
A warm direct XCTest run (excluding compilation) measured 0.21 s and 1.24 s,
respectively; the complete test, including historical cache inspection, took 3.11 s.
Peak process RSS was 160,825,344 bytes (153.4 MiB); this includes the test runner,
not solely the algorithm. These are single-run observations, not a sustained UI
or scheduler benchmark. Production spreads legs across scheduled passes.

All 37 Stories (36 Journeys and one outing) retained IDs, membership and photo
counts. All 183 transport modes remained unchanged. The isolated audit passed,
and copied catalog integrity checking returned `ok`.

## Next work, ordered by evidence

1. Trace why catalog revisions changed so broadly and whether the current analysis
   queue is making progress. Separate legitimate image invalidation from metadata
   changes before considering any cache reuse policy.
2. Restore sufficient current evidence and rerun this same audit. Only then assess
   whether narrow phrases and first-24 sampling have useful recall.
3. Build an owner-reviewed historical benchmark with several known pre-2007 event
   intervals. Support unlocated event/Story candidates with explicit uncertainty;
   do not invent geographic routes from timestamps or generic scene labels.
4. Measure false joins, false splits, missed known journeys and unsupported claims
   against that benchmark. Current invariance assertions cannot supply those rates.
5. Resume optional route validation after the evidence gap is understood. Keep
   Story timeline/map UI work separate from grouping qualification.

Private raw logs and copied databases remain in the temporary audit directory;
they are not added to the repository. No app bundle was rebuilt or launched.

## Follow-up: revision churn and queue repair

Read-only observations later on 2026-09-27 found 1,817 completed jobs, 87,799
pending and 21,321 deferred jobs (the schema represents deferred jobs as `running`
with no token). Those totals were unchanged across several observations. Roughly
110,674 job revisions had a modification date on September 26. This establishes
bulk invalidation, not which application or operation caused it.

A two-second process sample showed substantial work in `claimAnalysis` and its
correlated photo-date lookup. The query sorted the eligible corpus to select one
photo. Index schema v4 now stores the queue's capture date with synchronization
triggers, and merges the first eligible pending/retry candidates from ordered
partial indexes. A copied-index migration took 1.95 seconds and preserved results.
Twenty repeated warm measurements returned the same asset: the old SELECT median
was 157.4 ms; the new complete claim median was 1.43 ms (maximum 6.20 ms). This is
about 110x for queue selection, not a measured overall analysis throughput gain.

The stale-revision path previously deferred the same fingerprint for an hour.
It now reconciles current PhotoKit metadata and idempotently enqueues the current
revision. Checks before image loading and after analysis/OCR prevent wasting work
on already-stale claims. Tests cover metadata-already-current repair, stale result
rejection, completion preservation, date changes, expired leases and v3 migration.
These changes have not yet been deployed to the running app or its live index.

Apple documents that modification dates change for content **or metadata**:
[PHAsset.modificationDate](https://developer.apple.com/documentation/photos/phasset/modificationdate).
The current fingerprint cannot distinguish them. A later content-specific revision
should consider dimensions, adjustment state/timestamp, source/resource identity
and analyzer version, with a conservative older-OS fallback. An absent adjustment
does not prove historical cached pixels are identical. Existing cache records must
not be mass-relabelled. [Adjustment timestamps](https://developer.apple.com/documentation/photos/phasset/adjustmenttimestamp)
also record a revert, making them useful evidence for a future policy.

## Follow-up: historical metadata before cloud models

Verified against Apple's documentation and the installed macOS 27 SDK:

| Source | Available evidence | Appropriate use |
| --- | --- | --- |
| Ordinary albums and enclosing folders | Membership, localized titles, album dates, location names and approximate location when populated | User-supplied grouping/place clues; not automatic GPS truth |
| macOS 27 extended asset metadata | Caption, keywords, original filename | Explicit descriptive/place clues; local reads, no model enrollment |
| Asset metadata | Creation/modification dates, dimensions, Favorites, source type, burst information, added date on supported OS | Chronology, import-batch and source context; import date is not capture date |
| Edit metadata/resources | Adjustment presence, timestamp, format identifier; resource type and filename | Diagnose revision churn and identify edited/imported content |
| Local original file properties, if needed | Potential embedded EXIF/IPTC camera/date/description fields | Later bounded local-only probe; not yet read or confirmed present |

Historical metadata collection lives in `HistoricalMetadataAudit` inside Photo
Curator. Settings → Open Diagnostics… → Export Historical Metadata Audit… writes a
private local JSON report (mode 0600) and requests no image downloads. The
standalone [CLI stub](../Tools/audit_historical_metadata.swift) is a different TCC
client without the app Info.plist, so it does not show a useful Photos prompt and
must not be used for measurement. **No actual album names, captions or keywords
have been inspected yet** until the in-app export is run. That absence is an
authorization-path issue, not evidence that those fields are empty.

Use album evidence before cloud AI. Preserve its provenance and membership; exclude
known Curator-generated albums from independent evidence to avoid feeding our own
output back into grouping. Folder-name exclusion in the probe is only a preliminary
marker; production integration must consult managed-container receipts as well.
Separate overlapping thematic albums from event albums. Treat ambiguous place names
as candidates until grounded; do not geocode every photo or invent missing routes.
Captions/keywords can describe a scene rather than its capture location.

Next qualification: measure how many historical photos have independent descriptive
albums/captions/keywords, select several owner-reviewed examples, and compare
time-only versus metadata-assisted Story candidates. No cloud inference is needed
for those steps. Production ingestion and unlocated Story grouping remain planned.

Sources: [PhotoKit fetches](https://developer.apple.com/documentation/photokit/fetching-objects-and-requesting-changes),
[PHAssetExtendedMetadata](https://developer.apple.com/documentation/photos/phassetextendedmetadata),
[keywords](https://developer.apple.com/documentation/photos/phassetextendedmetadata/keywords).
The macOS 27 extended API is documented as beta; availability checks remain required.
