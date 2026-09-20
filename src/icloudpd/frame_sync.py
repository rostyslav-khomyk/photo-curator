"""Reviewed, identity-based Google album updates for the native Mac app."""

import hashlib
import os
import sqlite3
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from threading import Event
from typing import Any

from icloudpd.google_photos_client import (
    GoogleCreateRejected,
    GooglePhotosClient,
    GooglePhotosError,
)


class SyncAborted(RuntimeError):
    """The user stopped further work; completed remote changes are retained."""


@dataclass
class Destination:
    key: str
    title: str
    album_id: str | None
    old_ids: set[str]
    total_count: int
    paths: set[str] = field(default_factory=set)

    def summary(self) -> dict[str, Any]:
        return {
            "id": self.key,
            "title": self.title,
            "is_new": self.album_id is None,
            "existing_count": self.total_count,
            "managed_count": len(self.old_ids),
            "selected_count": len(self.paths),
        }


class UploadLedger:
    """Remember confirmed media IDs; never blindly retry uncertain creates."""

    def __init__(self, path: Path, account: str):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        os.chmod(path, 0o600)
        self.account = account
        self.db.execute(
            "CREATE TABLE IF NOT EXISTS uploads "
            "(account TEXT, digest TEXT, media_id TEXT, PRIMARY KEY (account, digest))"
        )
        self.db.execute(
            "CREATE TABLE IF NOT EXISTS album_creations "
            "(account TEXT, title TEXT, album_id TEXT, PRIMARY KEY (account, title))"
        )
        self.db.commit()

    def lookup(self, digest: str) -> str | None:
        row = self.db.execute(
            "SELECT media_id FROM uploads WHERE account=? AND digest=?", (self.account, digest)
        ).fetchone()
        if row is not None and row[0] is None:
            raise GooglePhotosError(
                "A previous upload has an uncertain Google response. No duplicate was created "
                "automatically. Check Google Photos before retrying this photo."
            )
        return str(row[0]) if row else None

    def uncertain_digests(self) -> set[str]:
        return {
            row[0]
            for row in self.db.execute(
                "SELECT digest FROM uploads WHERE account=? AND media_id IS NULL", (self.account,)
            )
        }

    def record(self, digest: str, media_id: str | None) -> None:
        self.db.execute(
            "INSERT OR REPLACE INTO uploads VALUES (?, ?, ?)", (self.account, digest, media_id)
        )
        self.db.commit()

    def close(self) -> None:
        self.db.close()

    def discard_pending(self, digest: str) -> None:
        self.db.execute(
            "DELETE FROM uploads WHERE account=? AND digest=? AND media_id IS NULL",
            (self.account, digest),
        )
        self.db.commit()

    def discard_pending_album(self, title: str) -> None:
        self.db.execute(
            "DELETE FROM album_creations WHERE account=? AND title=? AND album_id IS NULL",
            (self.account, title),
        )
        self.db.commit()

    def begin_album(self, title: str) -> None:
        if self.db.execute(
            "SELECT 1 FROM album_creations WHERE account=? AND title=?", (self.account, title)
        ).fetchone():
            raise GooglePhotosError(
                "This album was previously created or its creation response was lost. "
                "Refresh the Google album browser and select it explicitly; no duplicate was created."
            )
        self.db.execute("INSERT INTO album_creations VALUES (?, ?, NULL)", (self.account, title))
        self.db.commit()

    def finish_album(self, title: str, album_id: str) -> None:
        self.db.execute(
            "UPDATE album_creations SET album_id=? WHERE account=? AND title=?",
            (album_id, self.account, title),
        )
        self.db.commit()


class FrameSyncPlan:
    def __init__(
        self,
        client: GooglePhotosClient,
        items: list[tuple[str, str]],
        choices: dict[str, dict[str, str]],
        ledger_path: Path,
    ):
        if not items:
            raise ValueError("No photos were exported. Nothing will be changed in Google Photos.")
        self.client = client
        self.abort_requested = Event()
        self.account = client.account_identifier()
        self.ledger_path = ledger_path
        self.created_at = time.monotonic()
        self.destinations: dict[str, Destination] = {}
        self.files: dict[str, tuple[int, int]] = {}
        albums = client.list_albums()
        by_id = {str(album["id"]): album for album in albums}
        for path, source in items:
            if not Path(path).is_file():
                raise ValueError(f"The exported photo is unavailable: {Path(path).name}")
            stat = os.stat(path)
            if not stat.st_size:
                raise ValueError(f"The exported photo is empty: {Path(path).name}")
            self.files[path] = (stat.st_size, stat.st_mtime_ns)
            choice = choices.get(source, {"title": source})
            album_id = choice.get("id")
            title = choice.get("title", "").strip()
            if album_id:
                if album_id not in by_id:
                    raise ValueError(
                        "The chosen Google album is no longer accessible. Choose it again."
                    )
                album = by_id[album_id]
                title = str(album["title"])
            else:
                if not title:
                    raise ValueError("Enter a destination album name.")
                matches = [album for album in albums if album.get("title") == title]
                if len(matches) > 1:
                    raise ValueError(
                        f"Several Google albums are named '{title}'. Choose one from the album browser."
                    )
                album = matches[0] if matches else {}
                album_id = str(album["id"]) if album else None
            key = album_id or f"new:{title}"
            if key not in self.destinations:
                old_ids = client.album_media_ids(album_id) if album_id else set()
                self.destinations[key] = Destination(
                    key,
                    title,
                    album_id,
                    old_ids,
                    max(len(old_ids), int(album.get("mediaItemsCount", 0))),
                )
            self.destinations[key].paths.add(path)
        self.uncertain_paths: set[str] = set()
        ledger = UploadLedger(self.ledger_path, hashlib.sha256(self.account.encode()).hexdigest())
        try:
            unresolved = ledger.uncertain_digests()
            if unresolved:
                for path in self.files:
                    hasher = hashlib.sha256()
                    with open(path, "rb") as image_file:
                        for chunk in iter(lambda: image_file.read(1024 * 1024), b""):
                            hasher.update(chunk)
                    if hasher.hexdigest() in unresolved:
                        self.uncertain_paths.add(path)
        finally:
            ledger.close()

    def summary(self) -> dict[str, Any]:
        return {
            "destinations": [destination.summary() for destination in self.destinations.values()],
            "file_count": len(self.files),
            "total_bytes": sum(size for size, _ in self.files.values()),
            "unresolved_files": sorted({Path(path).name for path in self.uncertain_paths}),
        }

    def check_cancelled(self) -> None:
        if self.abort_requested.is_set():
            raise SyncAborted(
                "Upload aborted. Completed Google changes were kept; remaining work was stopped."
            )

    def run(
        self, mode: str, report: Callable[[dict[str, Any]], None], *, skip_unresolved: bool = False
    ) -> int:
        self.check_cancelled()
        if skip_unresolved and mode != "append":
            raise ValueError(
                "Use Add photos when leaving unresolved items out. Replacement is not allowed for an incomplete selection."
            )
        self.skip_unresolved = skip_unresolved
        self.client.check_cancelled = self.check_cancelled
        self.client.on_rate_limit = lambda seconds: report(
            {
                "phase": "rate_limited",
                "message": f"Waiting for Google: retrying in {seconds}s. You can Abort."
                if seconds
                else "Retrying the request after Google's rate limit…",
                "eta_seconds": None,
            }
        )
        try:
            return self._run_checked(mode, report)
        finally:
            self.client.check_cancelled = lambda: None
            self.client.on_rate_limit = lambda seconds: None

    def _run_checked(self, mode: str, report: Callable[[dict[str, Any]], None]) -> int:
        if mode not in {"append", "replace"}:
            raise ValueError("Choose Add photos or Replace Photo Relay photos.")
        if time.monotonic() - self.created_at > 1800:
            raise ValueError("The album review expired. Review the destination again.")
        if mode == "replace" and any(d.old_ids for d in self.destinations.values()):
            report(
                {
                    "phase": "authorizing",
                    "message": "Confirm album-editing permission in your browser if asked.",
                }
            )
            self.client.enable_album_editing()

        # No album mutation occurs until the reviewed files and destinations have been checked.
        for destination in self.destinations.values():
            if (
                destination.album_id
                and mode == "replace"
                and self.client.album_media_ids(destination.album_id) != destination.old_ids
            ):
                raise GooglePhotosError(
                    "The Google album changed since review. Review it again; nothing was removed."
                )

        if self.client.account_identifier() != self.account:
            raise GooglePhotosError(
                "The Google account changed during sign-in. Review the destination again."
            )
        account = hashlib.sha256(self.account.encode()).hexdigest()
        ledger = UploadLedger(self.ledger_path, account)
        try:
            return self._run(mode, report, ledger)
        finally:
            ledger.close()

    def _run(
        self, mode: str, report: Callable[[dict[str, Any]], None], ledger: UploadLedger
    ) -> int:
        hashes: dict[str, str] = {}
        unique: dict[str, str] = {}
        known: dict[str, str] = {}
        unresolved = ledger.uncertain_digests()
        skipped: set[str] = set()
        for index, (path, expected) in enumerate(self.files.items()):
            self.check_cancelled()
            report(
                {
                    "phase": "checking",
                    "message": f"Checking photo {index + 1} of {len(self.files)} for previous uploads",
                }
            )
            stat = os.stat(path)
            if (stat.st_size, stat.st_mtime_ns) != expected:
                raise GooglePhotosError(
                    "An exported photo changed since review. Prepare the selection again."
                )
            hasher = hashlib.sha256()
            with open(path, "rb") as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    self.check_cancelled()
                    hasher.update(chunk)
            key = hasher.hexdigest()
            if key in unresolved and self.skip_unresolved and path in self.uncertain_paths:
                skipped.add(path)
                continue
            hashes[path] = key
            unique[key] = path
            previous = ledger.lookup(key)
            if previous:
                known[key] = previous

        if not unique:
            raise GooglePhotosError(
                "Every selected item is unresolved. No Google album was changed. Choose other photos to continue."
            )
        if known:
            report({"phase": "checking", "message": "Confirming previous uploads with Google Photos"})
            existing = self.client.existing_media_ids(set(known.values()))
            known = {digest: media_id for digest, media_id in known.items() if media_id in existing}
        for destination in self.destinations.values():
            destination.paths -= skipped
        self.destinations = {key: d for key, d in self.destinations.items() if d.paths}
        report({"phase": "creating", "message": "Preparing your Google albums before uploading"})
        for destination in self.destinations.values():
            self.check_cancelled()
            if destination.album_id is None:
                if any(
                    album.get("title") == destination.title for album in self.client.list_albums()
                ):
                    raise GooglePhotosError(
                        "A destination album was created since review. Review it again to avoid a duplicate."
                    )
                ledger.begin_album(destination.title)
                try:
                    destination.album_id = self.client.create_album(destination.title)
                except (SyncAborted, GoogleCreateRejected):
                    ledger.discard_pending_album(destination.title)
                    raise
                ledger.finish_album(destination.title, destination.album_id)

        pending = {digest: path for digest, path in unique.items() if digest not in known}
        total_bytes = sum(self.files[path][0] for path in pending.values())
        completed = len(known)
        sent = 0
        started = time.monotonic()
        last_report = 0.0

        def progress(current: int = 0, *, phase: str = "uploading", force: bool = False) -> None:
            nonlocal last_report
            self.check_cancelled()
            now = time.monotonic()
            if not force and now - last_report < 0.25:
                return
            last_report = now
            elapsed = now - started
            transferred = min(total_bytes, sent + current)
            speed = transferred / elapsed if elapsed >= 1 else 0
            eta = (
                (total_bytes - transferred) / speed
                if elapsed >= 5 and speed > 0 and transferred < total_bytes
                else None
            )
            report(
                {
                    "phase": phase,
                    "message": "Sending photos to Google Photos"
                    if phase == "uploading"
                    else "Waiting for Google to finish processing",
                    "completed": completed,
                    "total": len(unique),
                    "reused": len(unique) - len(pending),
                    "sent_bytes": transferred,
                    "total_bytes": total_bytes,
                    "bytes_per_second": speed,
                    "eta_seconds": eta,
                }
            )

        progress(force=True)
        for digest, path in pending.items():
            token = self.client.upload_bytes(path, progress)
            sent += self.files[path][0]
            progress(phase="processing", force=True)
            # Persist the uncertainty before creating remote media. A lost response must
            # not turn a retry after restart into another copy of the same photo.
            ledger.record(digest, None)
            try:
                media_id = self.client.create_uploaded_media(token, Path(path).name)
            except (SyncAborted, GoogleCreateRejected):
                # Cancellation in the client's pre-request hook means Google has not
                # accepted this create. A response already in flight is recorded first.
                ledger.discard_pending(digest)
                raise
            ledger.record(digest, media_id)
            known[digest] = media_id
            completed += 1
            progress(force=True)

        report(
            {
                "phase": "updating",
                "message": "Adding the selection to your Google albums",
                "completed": completed,
                "total": len(unique),
                "eta_seconds": None,
            }
        )
        selected_by_album: dict[str, set[str]] = {}
        for destination in self.destinations.values():
            self.check_cancelled()
            assert destination.album_id
            selected = {known[hashes[path]] for path in destination.paths}
            selected_by_album[destination.album_id] = selected
            self.check_cancelled()
            self.client.change_album_membership(
                destination.album_id, selected - destination.old_ids
            )

        # Verify every addition before removing any old membership, including on retry.
        for destination in self.destinations.values():
            self.check_cancelled()
            assert destination.album_id
            actual = self.client.album_media_ids(destination.album_id)
            selected = selected_by_album[destination.album_id]
            if not selected <= actual:
                raise GooglePhotosError(
                    "Google has not confirmed all additions. Nothing old was removed; try again later."
                )
            if mode == "replace" and actual != destination.old_ids | selected:
                raise GooglePhotosError(
                    "The album changed during sync. New photos were added, but old photos were kept. Review again."
                )

        if mode == "replace":
            report(
                {
                    "phase": "replacing",
                    "message": "Removing the previous Photo Relay selection from the album",
                    "eta_seconds": None,
                }
            )
            for destination in self.destinations.values():
                self.check_cancelled()
                assert destination.album_id
                self.client.change_album_membership(
                    destination.album_id,
                    destination.old_ids - selected_by_album[destination.album_id],
                    remove=True,
                )
                actual = self.client.album_media_ids(destination.album_id)
                if (
                    not selected_by_album[destination.album_id] <= actual
                    or (destination.old_ids - selected_by_album[destination.album_id]) & actual
                ):
                    raise GooglePhotosError(
                        "Google has not confirmed the album replacement. Check the album before retrying."
                    )

        self.check_cancelled()
        report(
            {
                "phase": "complete",
                "message": (
                    f"Google album updated. {len(skipped)} unresolved item(s) were left out, not retried."
                    if skipped
                    else "Google album updated. Your Nest Hub will refresh on its own schedule."
                ),
                "skipped": len(skipped),
                "completed": completed,
                "total": len(unique),
                "eta_seconds": None,
                "destinations": [
                    {"id": d.album_id, "title": d.title} for d in self.destinations.values()
                ],
            }
        )
        return 0
