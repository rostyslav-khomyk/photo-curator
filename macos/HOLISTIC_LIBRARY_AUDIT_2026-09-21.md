# Holistic Library Curation Audit

Status: baseline for algorithm redesign
Prepared: 2026-09-21
Catalog generation: current `moments-catalog.json` on baseline `fdca2bae`

## Purpose

This audit treats the current catalog as one family photographic history, not as 5,224 isolated
cards. Its purpose is to make the next full-library run measurably more meaningful: coherent events,
useful parent stories, balanced highlights, and titles that help a family find and remember its life.

The measurements are descriptive, not a judgment of what matters. A single family portrait can be
more important than 500 museum photographs. Photo volume measures the photographer's activity, not
the value of the memory.

## Corpus

| Measure | Current result |
| --- | ---: |
| Photos | 108,999 |
| Moments | 5,224 |
| Selected highlights | 14,279 |
| Photos with GPS | 40,540 (37.2%) |
| Median Moment | 3 photos |
| 75th percentile Moment | 9 photos |
| 95th percentile Moment | 103 photos |
| Largest Moment | 1,586 photos |
| Days split into at least 2 Moments | 1,210 |
| Days split into at least 5 Moments | 33 |

The distribution is highly uneven:

| Moment size | Share of Moments | Photos represented | Share of photos |
| --- | ---: | ---: | ---: |
| 1 photo | 32.1% | 1,677 | 1.5% |
| 2-3 photos | 24.5% | 3,034 | 2.8% |
| 4-10 photos | 20.9% | 6,522 | 6.0% |
| 11-30 photos | 11.2% | 10,371 | 9.5% |
| 31-100 photos | 6.2% | 17,763 | 16.3% |
| 101+ photos | 5.1% | 69,632 | 63.9% |

The smallest 56.6% of Moments contain only 4.3% of the photos. The largest 5.1% contain 63.9%.
The top 1% of Moments contain 26.3% of all photos; the top 10% contain 78.1%. This is evidence that
one flat unit is serving incompatible purposes: tiny everyday observations and entire days, venues,
or trips.

## Seasonal Rhythm

The table uses each photo's capture date, not only its assigned Moment date. `Photos / active day`
normalizes for how often the camera was used in that calendar month across the library's years.

| Month | Photos | Active shooting days | Photos / active day | Approx. GPS cells | Highlights / photos |
| --- | ---: | ---: | ---: | ---: | ---: |
| Jan | 5,407 | 279 | 19.4 | 106 | 16.4% |
| Feb | 3,229 | 208 | 15.5 | 127 | 16.7% |
| Mar | 3,363 | 256 | 13.1 | 107 | 18.5% |
| Apr | 15,388 | 347 | 44.3 | 199 | 10.4% |
| May | 6,949 | 293 | 23.7 | 165 | 14.8% |
| Jun | 7,162 | 295 | 24.3 | 163 | 15.4% |
| Jul | 24,827 | 404 | 61.5 | 334 | 10.9% |
| Aug | 20,015 | 409 | 48.9 | 365 | 12.9% |
| Sep | 4,204 | 278 | 15.1 | 85 | 18.2% |
| Oct | 9,937 | 279 | 35.6 | 155 | 10.5% |
| Nov | 2,240 | 191 | 11.7 | 89 | 21.7% |
| Dec | 6,278 | 297 | 21.1 | 123 | 14.4% |

July and August contain 41.1% of all photos but 25.2% of Moments. April and October are secondary
bursts. February, March, September, and November are much sparser and receive a substantially higher
highlight ratio. That is consistent with vacations and outings producing dense sequences while
ordinary periods produce occasional observations.

The GPS-cell count rounds coordinates to about one kilometre and is only a relative diversity signal.
GPS coverage also changes historically: it is nearly absent in the oldest years but exceeds 90% in
recent years. Missing GPS must never be interpreted as evidence that old photographs occurred at one
place or are less interesting.

### Across the years

| Year | Photos | Active days | Moments | Highlights | GPS coverage |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1998-2000 | 3 | 3 | 3 | 3 | 0.0% |
| 2001 | 178 | 9 | 11 | 17 | 0.0% |
| 2002 | 111 | 16 | 17 | 24 | 0.0% |
| 2003 | 1,269 | 56 | 94 | 207 | 0.0% |
| 2004 | 859 | 57 | 74 | 173 | 0.0% |
| 2005 | 1,089 | 73 | 92 | 143 | 0.0% |
| 2006 | 1,056 | 97 | 118 | 200 | 0.0% |
| 2007 | 2,147 | 117 | 158 | 297 | 0.0% |
| 2008 | 4,186 | 91 | 126 | 386 | 0.0% |
| 2009 | 4,660 | 69 | 90 | 390 | 0.1% |
| 2010 | 1,454 | 70 | 88 | 188 | 3.2% |
| 2011 | 1,983 | 75 | 91 | 183 | 6.5% |
| 2012 | 3,053 | 149 | 216 | 340 | 5.5% |
| 2013 | 4,598 | 174 | 297 | 734 | 38.3% |
| 2014 | 5,292 | 183 | 283 | 675 | 32.2% |
| 2015 | 9,751 | 186 | 257 | 808 | 16.4% |
| 2016 | 5,771 | 247 | 416 | 982 | 34.8% |
| 2017 | 8,064 | 223 | 334 | 1,044 | 28.7% |
| 2018 | 6,465 | 170 | 245 | 813 | 21.3% |
| 2019 | 6,652 | 234 | 350 | 890 | 23.3% |
| 2020 | 4,589 | 180 | 248 | 583 | 18.3% |
| 2021 | 5,263 | 200 | 286 | 802 | 9.7% |
| 2022 | 13,038 | 204 | 339 | 1,151 | 79.4% |
| 2023 | 890 | 113 | 144 | 231 | 94.4% |
| 2024 | 4,565 | 140 | 210 | 645 | 95.0% |
| 2025 | 7,791 | 245 | 449 | 1,217 | 95.1% |
| 2026 | 4,222 | 155 | 188 | 1,153 | 85.1% |

The overview should make discontinuities such as 2009, 2015, 2022, and 2023 visible without guessing
their cause. They may reflect life events, devices, imports, deletions, or incomplete years. The
curator should adapt to the evidence and invite review rather than normalize them away.

## Boundary And Narrative Findings

- 2,959 Moments, 56.6% of the catalog, contain at most three photos.
- 265 Moments exceed 100 photos; 20 exceed 500 photos.
- 162 Moments span more than six hours; 37 cross a UTC date boundary.
- 216 Moments over 100 photos still have a generic category or date/place headline. They contain
  56,342 photos.
- 3,530 headlines are date or date-plus-place forms, 1,448 use a generic category prefix, 189 are
  specific/custom, and 57 are empty. Date/place titles are safe fallbacks, but they do not yet expose
  much of the family's story.
- One shooting day is split into 19 Moments. Thirty-three days are split into five or more.
- Large venue examples include 1,586 photos under `Art and interiors`, 1,284 at Keukenhof, and
  hundreds at museums, palaces, cathedrals, and destination days. These need internal scenes without
  losing the larger outing.

The current selection ratio falls from 88% for singleton Moments to 7% for 101+ photo Moments. A
sublinear highlight budget is sensible, but count alone cannot choose the right family record. A good
set should cover roles such as arrival/establishing view, people, activity, place detail, transition,
and closing image while avoiding near duplicates.

## Photographer Interpretation

The flat catalog asks one `Moment` to mean both “this one photograph worth keeping” and “our whole day
at Efteling.” Tightening a global time gap will improve one and damage the other. The smallest robust
model is a hierarchy:

1. An optional **Story** is a grounded memorable container: a trip day, attraction visit, birthday,
   family gathering, holiday, or another evidenced occasion.
2. A **Moment** is a coherent scene, either standalone or inside a Story: arrival, meal, ride,
   performance, family portrait, walk, hotel room, or another continuous activity/place.
3. A **Highlight** is a representative photo with a role in that Moment or Story.

Sparse everyday photos should not be merged merely to make larger cards. They can remain honest
standalone single-photo Moments and still be browsed through calendar, season, place, or Significant
Place views. Those views are not Stories. Dense vacation captures should receive more scene
boundaries, then be reunited by a parent Story only when continuity evidence supports it.

## Proposed Whole-Library Model

### Adaptive boundaries

Estimate a boundary from evidence relative to the local shooting session, not a fixed global gap:

- time gap normalized by the day's capture cadence;
- distance or venue transition when GPS exists;
- visual discontinuity and repeated-shot continuity;
- activity/scene changes and face-count continuity without claiming face identity;
- logical-day boundary, travel movement, and return to a Significant Place;
- uncertainty when historical metadata is absent.

Month/year seasonality does not enter this boundary score. It informs the Library Overview and
cross-library summary allocation only. This prevents a summer photograph and an otherwise identical
winter photograph from receiving different event semantics merely because one month is busier.

Evaluation assigns a higher cost to joining unrelated events than to temporarily splitting one
event. Both errors remain visible; the exact weights are calibrated from the owner's benchmark.

The first implementation should remain deterministic and inspectable. It does not require a new
machine-learning service. Existing time, location, Vision, OCR, and user-decision evidence can feed a
calibrated score whose components are logged for every proposed split or join.

### Story construction

Build optional Stories after scene-level Moments. Join adjacent Moments conservatively when there is
evidence of one outing or occasion: same logical day and venue, continuous travel path, recurring
people count, shared activity, or a user merge. Multi-day travel can receive a trip parent without
turning every day into one Moment. If positive evidence is absent, keep the Moment standalone.

### Highlight allocation

For a Story, allocate a Story budget first and then Moment budgets with diminishing returns. For
standalone Moments, allocate directly. Score these dimensions independently before combining them:

- personal intent: explicit choices and Favorites when present, never requiring Favorites;
- quality: technical and aesthetic evidence;
- coverage: people, activity, place, and visual roles;
- chronology: opening, progression, transition, and closing coverage where present;
- diversity: penalize near duplicates;
- contextual rarity: do not let a high-volume vacation erase sparse milestones;
- owner-signaled importance: titles, manual choices, merges, and other explicit corrections.

This follows established photo-summary principles of quality, diversity, and coverage, but the
weights must be validated against this family's edits rather than treated as universal truth. The
comparison report keeps the dimension scores visible so one aggregate cannot conceal a regression.

## Product View

Add a lightweight `Library Overview`, backed by aggregate SQL rather than loaded photos:

- a year/month timeline comparing photo, Moment, Story, and highlight counts;
- visible dense seasons and quiet periods, described neutrally rather than as “boring”;
- likely trips/outings, family occasions, everyday life, and unresolved periods;
- fragmentation and over-aggregation indicators that link to filtered Moments;
- analysis coverage, algorithm generation, storage use, and last complete rebuild;
- a before/after report when testing a new curation generation.

The overview should say what the app knows and where it is uncertain. It should not infer emotional
importance from volume or pretend that generic visual labels are memories.

## Versioned Full-Library Runs

Algorithm work needs a repeatable full-corpus experiment, not a destructive reset each time:

1. `Rebuild Curation with Latest Algorithm` keeps source metadata, expensive Vision/OCR evidence,
   Significant Places, and user decisions. It computes a new generation beside the active one.
2. The app presents a comparison: Moment/Story counts, size distribution, split/join changes,
   generic-title rate, highlight coverage, and affected user decisions.
3. The candidate becomes active only after validation. The old generation remains available for one
   rollback window.
4. `Reanalyze Entire Library` additionally invalidates derived evidence when the analyzer itself
   changed. It is expected to be slow.
5. `Reset Photo Curator` is the true nuclear option: remove managed Photos albums, catalog, caches,
   edits, and operation state, then rebuild from zero. It exists for clean-room testing and recovery,
   not as the normal algorithm upgrade path.

Every generated row carries an algorithm generation. User merges, splits, titles, selections, and
publication choices are durable evaluation labels, not obsolete data to discard casually.

## Acceptance Measures

A benchmark must be frozen before schema or algorithm migration. The library owner reviews stable
asset IDs spanning dense vacations, quiet months, old scans, recent GPS-rich photos, home, work,
birthdays, and venues, recording expected boundaries, optional Stories, titles, and highlights. Every
candidate generation is compared with this same versioned fixture.

- Fewer giant flat Moments without increasing unrelated joins.
- Fewer unnecessary tiny adjacent fragments without suppressing honest single-photo memories.
- False joins and false splits reported separately, with false joins assigned the higher cost.
- Lower date/generic-title reliance after evidence is ready.
- Stable or better quality, diversity, coverage, chronology, and personal-intent scores at the same
  highlight budget, with no dimension hidden inside one aggregate.
- Balanced library browsing across standalone Moments and optional Stories; volume may affect detail,
  not erase sparse periods.
- No loss or silent reassignment of user decisions.
- A readable explanation for representative split, join, title, and highlight decisions.

There is no credible “better than Photos or Google Photos” claim until library owners prefer the
candidate on their own libraries. Independent reviewers judge safety, architecture, performance, and
usability; they cannot overrule the owner's understanding of family significance. Closed alpha should
collect merge, split, retitle, include, and exclude actions as private local evaluation signals and
export only an explicit diagnostic summary.

## Research Basis

- Cao et al., [Image Annotation Within the Context of Personal Photo Collections Using Hierarchical
  Event and Scene Models](https://www.cs.virginia.edu/~rmw7my/papers/personal-image.pdf): personal
  collections benefit from event/scene hierarchy and must tolerate partially missing GPS.
- Datia et al., [Time and space for segmenting personal photo sets](https://doi.org/10.1007/s11042-016-3341-2):
  personal capture is bursty; logical days, temporal cycles, and spatial evidence help balance
  over-segmentation and under-segmentation.
- Pigeau and Gelgon, [MyOwnLife: Incremental and hierarchical classification of a personal image
  collection](https://hal.science/hal-00424925): hierarchical temporal and geographic views support
  browsing at different scales.
- Sinha et al., [Effective summarization of large collections of personal photos](https://doi.org/10.1145/1963192.1963257):
  useful summaries jointly consider quality, diversity, and coverage.

## Method And Caveats

The audit parsed the current local catalog, converted Apple reference dates to UTC, counted each
photo by its own capture date, and counted highlights from current selected IDs. Approximate GPS cells
use coordinates rounded to two decimals. It did not inspect private image pixels outside the existing
local evidence and did not assign emotional meaning. UTC can place photographs around midnight on an
adjacent calendar day; production logical days should use capture timezone when known and location-
appropriate fallback otherwise.
