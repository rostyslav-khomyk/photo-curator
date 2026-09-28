# Resume checkpoint — Release Candidate

Recorded 2026-09-28 midday after owner confirmed Journey sidebar quality
(“relevant Journeys only, few of them but gold”).

## Memorized gold UX

- Sidebar lists **only finalized** Journeys (`Journey to` / `Journey via`).
  Unresolved `Journey from Home` shells stay in the catalog for enrichment but
  do not flicker in the side panel.
- Titles ignore secondary Home places (`Home in Ukraine`) and street-level labels;
  street stop places are re-geocoded to city/region. Bucharest-style round-trips
  title from city evidence, not a 1-photo secondary-home ping.
- Adaptive evidence **defers** GPS-rich Vision/OCR while claimable thin work
  remains; soft-deferred thin retries must not stall the claim gate.
- Journey stop geocode runs **before** the OCR interleave on the shared scheduler.
- Photos full-access clicker must target process name `PhotoCurator` (ad-hoc
  resign re-prompts; a missed click stalls prep while telemetry can still look ok).

Peak finalized titles observed this soak (quality bar to preserve): Bucharest,
Barcelona/France/Reims, Bruges/Ghent, Athens/Greece, Rhodes/Symi, Paris, Cologne/Lviv,
and similar multi-city grounded names — not dozens of identical `Journey from Home`.

## Open gaps (not blocking this RC)

1. **Preserve geocoded Journey evidence across `rebuildStories`** — DELETE+rebuild
   still wipes city titles; count oscillates until geocode refills. Highest UX debt.
2. MapKit / route visualization (planned).
3. Hierarchical Story highlight allocator (tested, not wired).
4. Adaptive-cadence / routine-singleton candidate activation (gated on owner benchmark).
5. Pre-2007 / unlocated-history Stories; broader transport OCR coverage.
6. Optional lighter treatment of the large modern no-GPS (priority 65) band.

Current source audit: [Curation algorithm](CURATION_ALGORITHM.md).
Soak ops: [SOAK_AGENT.md](SOAK_AGENT.md), [SOAK_FIX_LOG.md](SOAK_FIX_LOG.md).
