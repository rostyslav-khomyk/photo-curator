#!/usr/bin/env bash
# One soak-agent tick: Photos permission clicker + telemetry status.
# Prints AGENT_LOOP_TICK_photocurator_soak with a JSON payload for the agent.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLICK_OUT="no_run"
TELEMETRY_JSON="{}"
CLICK_RC=0
TELE_RC=0

if [[ -x "$ROOT/Scripts/click_photos_full_access.sh" ]]; then
  CLICK_OUT="$("$ROOT/Scripts/click_photos_full_access.sh" 2>&1 || true)"
fi

set +e
TELEMETRY_JSON="$(python3 "$ROOT/Scripts/soak_watch_telemetry.py" 2>&1)"
TELE_RC=$?
set -e

# Escape for single-line JSON embedding
CLICK_ESC="${CLICK_OUT//$'\n'/ }"
CLICK_ESC="${CLICK_ESC//\"/\\\"}"

echo "AGENT_LOOP_TICK_photocurator_soak {\"prompt\":\"Photo Curator soak tick: click=${CLICK_ESC}; telemetry_exit=${TELE_RC}; status=${TELEMETRY_JSON}. Follow Docs/SOAK_AGENT.md: if severity=error quit app, fix root cause, append Docs/SOAK_FIX_LOG.md, rebuild, relaunch, ensure Curate While Idle. If click succeeded note it. If ok briefly confirm healthy.\",\"click\":\"${CLICK_ESC}\",\"telemetry_exit\":${TELE_RC}}"
