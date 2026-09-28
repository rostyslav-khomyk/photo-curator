---
name: photocurator-soak
description: >-
  Watch Photo Curator soak telemetry, click Photos full-access dialogs, quit and
  fix on error bursts, and log fixes. Use when running overnight/clean-room soak
  monitoring or when AGENT_LOOP_TICK_photocurator_soak fires.
---

# Photo Curator soak watch

Follow [Docs/SOAK_AGENT.md](../../../Docs/SOAK_AGENT.md) exactly.

On each `AGENT_LOOP_TICK_photocurator_soak`:

1. Trust the tick payload (`click`, `telemetry_exit`, embedded status JSON).
2. If a Photos access button was clicked, note it briefly.
3. If `severity` is `error`: quit dist Photo Curator only → diagnose → fix →
   append [Docs/SOAK_FIX_LOG.md](../../../Docs/SOAK_FIX_LOG.md) → test →
   `./Scripts/build_app.sh` → relaunch → Curate While Idle.
4. If `ok`, one-line confirmation. Do not rebuild.
5. Never nuclear-reset, never commit unless asked, never log PII from photos.
