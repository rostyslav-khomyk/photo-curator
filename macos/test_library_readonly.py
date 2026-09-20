"""Explicit local acceptance probe; emits aggregate counts only, removes snapshots."""
import collections
import contextlib
import importlib.metadata
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from icloudpd.curator_context import FIELDS, read_photo_context


def main():
    library = Path(sys.argv[1]).resolve(strict=True)
    if library.suffix != ".photoslibrary":
        raise ValueError("Expected an explicit Photos library")
    start = time.monotonic()
    def expired(*_):
        raise TimeoutError("Acceptance probe exceeded 180 seconds")
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(180)
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="photo-relay-readonly-") as temporary:
        snapshot = Path(temporary) / "database" / "Photos.sqlite"
        snapshot.parent.mkdir()
        # Clone DB and WAL, accepting only a copy interval with unchanged source metadata.
        # Never open SQLite against the live library (even read-only may need SHM access).
        clone = Path(temporary) / "clone"
        clone.mkdir()
        paths = [library / "database" / name for name in ("Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm")]
        def signatures():
            return [(p.stat().st_ino, p.stat().st_size, p.stat().st_mtime_ns, p.stat().st_ctime_ns) if p.exists() else None for p in paths]
        before = signatures()
        for path in paths:
            if path.exists():
                subprocess.run(["/bin/cp", "-c", str(path), str(clone / path.name)], check=True, capture_output=True)
        if signatures() != before:
            raise RuntimeError("Source changed during snapshot; retry when Photos is quiet")
        with sqlite3.connect((clone / "Photos.sqlite").as_uri() + "?mode=ro", uri=True) as source:
            with sqlite3.connect(snapshot) as destination:
                source.backup(destination, pages=4096, sleep=0.05)
        print(json.dumps({"stage": "snapshot_ready", "seconds": round(time.monotonic()-start, 2)}), flush=True)
        with open(os.devnull, "w") as quiet, contextlib.redirect_stdout(quiet), contextlib.redirect_stderr(quiet):
            import osxphotos
            # Search store is separate; do not quietly access it in the live library.
            db = osxphotos.PhotosDB(dbfile=str(snapshot), _skip_searchinfo=True)
            photos = [p for p in db.photos(images=True, movies=False, intrash=False) if not p.hidden]
            sample = photos[::max(1, len(photos)//120)][:120]
            coverage = collections.Counter()
            people = collections.Counter()
            for photo in sample:
                for field in read_photo_context(photo, frozenset(FIELDS)):
                    coverage[f"{field.key}:{field.status}"] += 1
                    if field.status == "available" and field.value:
                        coverage[f"{field.key}:nonempty"] += 1
                try:
                    people["photos_with_named_people"] += any(p.name for p in photo.person_info)
                    people["photos_with_faces"] += bool(photo.face_info)
                except Exception:
                    people["reader_errors"] += 1
        print(json.dumps({"reader_version": importlib.metadata.version("osxphotos"),
                          "database_version": db.db_version, "visible_images": len(photos),
                          "sample_size": len(sample), "people": dict(people),
                          "coverage": dict(coverage), "seconds": round(time.monotonic()-start, 2),
                          "search_store_tested": False}), flush=True)
    print(json.dumps({"snapshot_removed": True}), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"failed": type(error).__name__, "sqlite_code": getattr(error, "sqlite_errorname", None), "private_details_omitted": True}), flush=True)
        sys.exit(1)
