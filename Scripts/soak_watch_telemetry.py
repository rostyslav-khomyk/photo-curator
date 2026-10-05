#!/usr/bin/env python3
"""Photo Curator soak telemetry check.

Reads counts-only curator.jsonl. Emits a machine-readable status line for the soak agent.
Does not print photo IDs, titles, OCR, or coordinates.
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

LOG_DIR = Path.home() / "Library/Logs/Photo Curator"
PRIMARY = LOG_DIR / "curator.jsonl"
STATE = Path.home() / "Library/Caches/Photo Curator/soak-watch-state.json"
CATALOG = (
    Path.home()
    / "Library/Application Support/Photo Curator/curator/catalog-v2.sqlite3"
)

PAUSE_MARKERS = (
    "Moment preparation paused",
    "Curator paused",
)
# Soft OCR/evidence failures use code 1 heavily; only burst+pause should escalate.
FAILURE_BURST = 25
WINDOW = 80
# Telemetry silence while the app claims to be alive = stuck (Photos dialog, dead scheduler).
TELEMETRY_STALL_SECONDS = 12 * 60
# Finalized Journey sidebar empty while many shells exist = rebuild wiped geocodes.
JOURNEY_SHELL_WARN_MIN = 8
# Analysis advancing without any journeyLookups while shells dominate = recovery stalled.


def journey_titles_wiped(journeys: dict) -> bool:
    """Shells dominate finalized titles (same rule as JourneyEnrichmentScheduling)."""
    total = int(journeys.get("journeys") or 0)
    finalized = int(journeys.get("finalized") or 0)
    shells = int(journeys.get("shells") or 0)
    if shells < JOURNEY_SHELL_WARN_MIN or total <= 0:
        return False
    return finalized * 2 < total


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
    import subprocess

    r = subprocess.run(
        ["pgrep", "-f", "Photo Curator.app/Contents/MacOS/PhotoCurator"],
        capture_output=True,
        text=True,
    )
    return r.returncode == 0 and bool(r.stdout.strip())


def parse_utc(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def journey_sidebar_health() -> dict | None:
    """Counts-only Journey health from Catalog v2 (no titles)."""
    if not CATALOG.exists():
        return None
    try:
        con = sqlite3.connect(f"file:{CATALOG}?mode=ro", uri=True)
        try:
            row = con.execute(
                """
                SELECT
                  SUM(CASE WHEN kind='journey' THEN 1 ELSE 0 END),
                  SUM(CASE WHEN kind='journey'
                            AND (title LIKE 'Journey to %' OR title LIKE 'Journey via %')
                           THEN 1 ELSE 0 END),
                  SUM(CASE WHEN kind='journey' AND title LIKE 'Journey from %'
                           THEN 1 ELSE 0 END)
                FROM stories
                """
            ).fetchone()
        finally:
            con.close()
    except sqlite3.Error:
        return None
    if not row:
        return None
    total, finalized, shells = (int(row[0] or 0), int(row[1] or 0), int(row[2] or 0))
    return {"journeys": total, "finalized": finalized, "shells": shells}


def main() -> int:
    events = load_events(PRIMARY)
    recent = events[-WINDOW:]
    counts = Counter(e.get("event") for e in recent)
    failures = [e for e in recent if e.get("event") == "failure"]
    last = events[-1] if events else None
    last_time = last.get("time") if last else None
    last_catalog = next((e for e in reversed(events) if e.get("event") == "catalog"), None)
    running = app_running()
    journeys = journey_sidebar_health()

    storm = len(failures) >= FAILURE_BURST
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
    elif not running:
        severity = "warn"
        reason = "app_not_running"
    elif last_catalog is None and len(events) > 10:
        severity = "warn"
        reason = "no_recent_catalog"
    else:
        last_dt = parse_utc(last_time)
        if last_dt is not None:
            age = (datetime.now(timezone.utc) - last_dt).total_seconds()
            if age >= TELEMETRY_STALL_SECONDS:
                severity = "error"
                reason = f"telemetry_stalled age_s={int(age)}"
        wiped = journeys is not None and journey_titles_wiped(journeys)
        if severity == "ok" and wiped:
            journey_lookups = sum(
                int((e.get("counts") or {}).get("journeyLookups") or 0)
                for e in recent
                if e.get("event") == "catalog"
            )
            analysis_events = int(counts.get("analysis") or 0)
            # Sidebar empty + Vision still ticking + zero geocode attempts = false "healthy".
            if journey_lookups == 0 and analysis_events >= 5:
                severity = "error"
                reason = (
                    "journey_geocode_stalled "
                    f"finalized={journeys['finalized']} shells={journeys['shells']} "
                    f"analysis={analysis_events} lookups=0"
                )
            else:
                severity = "warn"
                reason = (
                    "journey_titles_wiped "
                    f"finalized={journeys['finalized']} shells={journeys['shells']}"
                )

    state = load_state()
    status = {
        "severity": severity,
        "reason": reason,
        "app_running": running,
        "recent_events": dict(counts),
        "trailing_failures": trailing_failures,
        "last_event_time": last_time,
        "catalog": (last_catalog or {}).get("counts"),
        "journeys": journeys,
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
