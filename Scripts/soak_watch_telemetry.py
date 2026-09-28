#!/usr/bin/env python3
"""Photo Curator soak telemetry check.

Reads counts-only curator.jsonl. Emits a machine-readable status line for the soak agent.
Does not print photo IDs, titles, OCR, or coordinates.
"""
from __future__ import annotations

import json
import os
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

LOG_DIR = Path.home() / "Library/Logs/Photo Curator"
PRIMARY = LOG_DIR / "curator.jsonl"
STATE = Path.home() / "Library/Caches/Photo Curator/soak-watch-state.json"

PAUSE_MARKERS = (
    "Moment preparation paused",
    "Curator paused",
)
# Soft OCR/evidence failures use code 1 heavily; only burst+pause should escalate.
FAILURE_BURST = 25
WINDOW = 80


def load_events(path: Path, limit: int = 400) -> list[dict]:
    if not path.exists():
        return []
    lines = path.read_text(errors="replace").splitlines()
    out: list[dict] = []
    for line in lines[-limit:]:
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def load_state() -> dict:
    if STATE.exists():
        try:
            return json.loads(STATE.read_text())
        except json.JSONDecodeError:
            pass
    return {"last_failure_time": None, "last_action": None}


def save_state(state: dict) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state, indent=2) + "\n")


def app_running() -> bool:
    # Avoid shell injection; simple pgrep by path fragment.
    import subprocess

    r = subprocess.run(
        ["pgrep", "-f", "Photo Curator.app/Contents/MacOS/PhotoCurator"],
        capture_output=True,
        text=True,
    )
    return r.returncode == 0 and bool(r.stdout.strip())


def main() -> int:
    events = load_events(PRIMARY)
    recent = events[-WINDOW:]
    counts = Counter(e.get("event") for e in recent)
    failures = [e for e in recent if e.get("event") == "failure"]
    last = events[-1] if events else None
    last_time = last.get("time") if last else None
    last_catalog = next((e for e in reversed(events) if e.get("event") == "catalog"), None)

    # Activity strings are not in telemetry; detect repeated failure storms + stalled catalog.
    storm = len(failures) >= FAILURE_BURST
    # Also scan rotated log for pause evidence is not available in jsonl (counts only).
    # Use consecutive failures at end of stream as escalation signal.
    trailing_failures = 0
    for e in reversed(recent):
        if e.get("event") == "failure":
            trailing_failures += 1
        else:
            break

    severity = "ok"
    reason = "healthy"
    if trailing_failures >= 8 or storm:
        severity = "error"
        reason = f"failure_burst trailing={trailing_failures} window_failures={len(failures)}"
    elif not app_running():
        severity = "warn"
        reason = "app_not_running"
    elif last_catalog is None and len(events) > 10:
        severity = "warn"
        reason = "no_recent_catalog"

    state = load_state()
    status = {
        "severity": severity,
        "reason": reason,
        "app_running": app_running(),
        "recent_events": dict(counts),
        "trailing_failures": trailing_failures,
        "last_event_time": last_time,
        "catalog": (last_catalog or {}).get("counts"),
        "log": str(PRIMARY),
        "checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "prior_action": state.get("last_action"),
    }
    print(json.dumps(status, separators=(",", ":")))
    if severity == "error":
        state["last_failure_time"] = last_time
        save_state(state)
        return 2
    if severity == "warn":
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
