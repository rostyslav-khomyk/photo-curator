# Photo Curator soak agent

Runs while a clean-room or overnight soak is active. Local only — cloud Automations
cannot read Mac telemetry or click Photos permission dialogs.

## Trigger

`Scripts/soak_agent_tick.sh` every few minutes (agent loop
`AGENT_LOOP_TICK_photocurator_soak`).

## Each tick

1. Run the Photos full-access clicker (`Scripts/click_photos_full_access.sh`).
   Click **Allow Full Access** / **Allow Access to All Photos** when present.
   The dist app’s Accessibility process name is `PhotoCurator` (also try
   `Photo Curator`). Cursor/Terminal need Accessibility permission.
   After ad-hoc rebuild/resign, expect this dialog again — a missed click stalls
   Moment preparation even when telemetry still looks “healthy”.
   On recent macOS the button title is often **Allow All Photos** (not only
   “Allow Full Access” / “Allow Access to All Photos”).
2. Run `Scripts/soak_watch_telemetry.py` against
   `~/Library/Logs/Photo Curator/curator.jsonl` (counts-only; never log photo IDs,
   OCR, titles, or coordinates).
3. Act on severity:
   - **ok** — one-line healthy note; do not thrash.
   - **warn** (`app_not_running`) — relaunch
     `dist/Photo Curator.app` if a soak is intended; leave Curate While Idle on.
   - **warn** (`journey_titles_wiped`) — catalog still has Journey shells but almost
     no finalized `Journey to` / `Journey via` titles (sidebar looks empty). Do not
     ignore; confirm geocode is running (`journeyLookups` in catalog events) and
     rebuild is not wiping stop places. Recovery cadence should geocode every step.
   - **error** (`journey_geocode_stalled`) — wipe condition plus analysis events but
     zero `journeyLookups` in the recent window. Treat as stuck recovery: fix
     cadence / preserve path, rebuild, relaunch.
   - **error** (`telemetry_stalled`) — no jsonl events for ≥12 minutes while the app
     binary is running (or was expected to). Treat as stuck: Photos access dialog,
     dead scheduler, or hung analysis. Quit dist binary, diagnose, fix, rebuild,
     relaunch.
   - **error** (failure burst / trailing failures) —
     1. Quit Photo Curator (`pkill` the dist binary only).
     2. Diagnose from telemetry + recent code paths (OCR pause, catalog lock,
        story membership, etc.).
     3. Fix with minimal change; soft-fail evidence gaps; never wipe user Photos.
     4. Append a dated entry to [SOAK_FIX_LOG.md](SOAK_FIX_LOG.md).
     5. Run relevant `swift test --filter …`, then `./Scripts/build_app.sh`.
     6. Relaunch the app; confirm Curate While Idle.

## Safety

- Do not run nuclear reset or delete Photos albums from the soak agent.
- Preserve worktree changes; no `git reset --hard`.
- Do not commit unless the owner asks.
- Prefer soft-fail for local Vision/OCR reader errors over pausing the queue.

## Stop

Owner says stop / end soak loop — kill the soak loop shell and do not re-arm.
