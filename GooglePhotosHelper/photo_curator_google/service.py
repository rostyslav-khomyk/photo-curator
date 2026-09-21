"""Private JSON-line service used by the native Photo Curator app."""

import json
import logging
import os
import secrets
import sys
from collections.abc import Callable
from dataclasses import dataclass
from logging.handlers import RotatingFileHandler
from pathlib import Path
from threading import Lock, Thread
from typing import Any

from photo_curator_google.client import GooglePhotosClient
from photo_curator_google.frame_sync import FrameSyncPlan, SyncAborted
from photo_curator_google.oauth import GOOGLE_APP_SCOPES, SimplifiedGoogleAuth

PREFIX = "PHOTO_CURATOR_RPC "
ROUTES = frozenset({
    "/auth-state", "/google-access", "/frame-albums", "/prepare-frame-sync",
    "/start-frame-sync", "/abort-frame-sync", "/control-state", "/clear-google-album",
})


@dataclass(frozen=True)
class Snapshot:
    running: bool
    last_exit_code: int | None
    error: str | None
    progress: dict[str, Any]


class GoogleSyncControl:
    def __init__(self, logger: logging.Logger):
        self.logger = logger
        self.lock = Lock()
        self.operation_lock = Lock()
        self.running = False
        self.last_exit_code: int | None = None
        self.error: str | None = None
        self.progress: dict[str, Any] = {}
        self.prepared: tuple[str, FrameSyncPlan] | None = None
        self.active: tuple[str, FrameSyncPlan] | None = None

    def exclusive(self, work: Callable[[], Any]) -> Any:
        if not self.operation_lock.acquire(blocking=False):
            raise RuntimeError("Another Google Photos operation is already open.")
        try:
            with self.lock:
                if self.running:
                    raise RuntimeError("Wait for the current sync to finish.")
            return work()
        finally:
            self.operation_lock.release()

    def access(self, credentials: str, interactive: bool) -> dict[str, str]:
        def check() -> dict[str, str]:
            auth = SimplifiedGoogleAuth(credentials, self.logger)
            if auth.authenticate(GOOGLE_APP_SCOPES, interactive=interactive):
                return {"status": "connected"}
            missing = auth.refresh_revoked or not auth.refresh_token or not set(GOOGLE_APP_SCOPES) <= auth.granted_scopes
            return {"status": "needs_connection" if missing else "unavailable"}
        return self.exclusive(check)

    def albums(self, credentials: str) -> list[dict[str, Any]]:
        return self.exclusive(lambda: GooglePhotosClient(credentials, self.logger, identify_account=True).list_albums())

    def clear_album(self, credentials: str, album_id: str) -> int:
        def clear() -> int:
            client = GooglePhotosClient(credentials, self.logger, identify_account=True)
            if album_id not in {str(album["id"]) for album in client.list_albums()}:
                raise ValueError("The selected Google album is no longer accessible to Photo Curator.")
            media_ids = client.album_media_ids(album_id)
            if not media_ids:
                return 0
            client.enable_album_editing()
            client.change_album_membership(album_id, media_ids, remove=True)
            if media_ids & client.album_media_ids(album_id):
                raise RuntimeError("Google did not confirm that the album was cleared. Check it before retrying.")
            return len(media_ids)
        return self.exclusive(clear)

    def prepare(self, payload: dict[str, Any]) -> dict[str, Any]:
        def build() -> dict[str, Any]:
            credentials = payload.get("credentials")
            raw_items = payload.get("items")
            choices = payload.get("destinations", {})
            if not isinstance(credentials, str) or not credentials:
                raise ValueError("Connect Google Photos first.")
            if not isinstance(raw_items, list) or not raw_items:
                raise ValueError("Select photos to sync first.")
            items: list[tuple[str, str]] = []
            for item in raw_items:
                if not isinstance(item, dict) or not all(isinstance(item.get(key), str) and item[key] for key in ("path", "album")):
                    raise ValueError("Invalid exported photo.")
                items.append((os.path.abspath(item["path"]), item["album"]))
            if not isinstance(choices, dict) or not all(
                isinstance(key, str) and isinstance(value, dict)
                and all(isinstance(k, str) and isinstance(v, str) for k, v in value.items())
                for key, value in choices.items()
            ):
                raise ValueError("Choose a valid destination album.")
            path = Path(credentials).expanduser().resolve()
            plan = FrameSyncPlan(
                GooglePhotosClient(str(path), self.logger, identify_account=True),
                items, choices, path.with_name("photo_curator_uploads.sqlite3"),
            )
            token = secrets.token_urlsafe(32)
            with self.lock:
                self.prepared = (token, plan)
            return {"token": token, **plan.summary()}
        return self.exclusive(build)

    def start(self, token: str, mode: str, skip_unresolved: bool) -> tuple[bool, str]:
        if mode not in {"append", "replace"}:
            return False, "Choose Add photos or Replace Photo Curator photos."
        with self.lock:
            prepared = self.prepared
            if not prepared or not secrets.compare_digest(token, prepared[0]):
                return False, "Review your Google destination before syncing."
            plan = prepared[1]
        if not self.operation_lock.acquire(blocking=False):
            return False, "Wait for the current Google Photos operation to finish."
        with self.lock:
            if self.running:
                self.operation_lock.release()
                return False, "A sync is already running."
            self.running = True
            self.last_exit_code = None
            self.error = None
            self.active = (token, plan)
            self.prepared = None
            self.progress = {"phase": "preparing", "message": "Preparing Google Photos sync", "run_id": token}
        Thread(target=self._run, args=(plan, mode, skip_unresolved), daemon=True).start()
        return True, "Sync started."

    def _run(self, plan: FrameSyncPlan, mode: str, skip_unresolved: bool) -> None:
        def report(update: dict[str, Any]) -> None:
            with self.lock:
                self.progress.update(update)
        try:
            exit_code = plan.run(mode, report, skip_unresolved=skip_unresolved)
            with self.lock:
                self.last_exit_code = exit_code
        except SyncAborted as error:
            with self.lock:
                self.last_exit_code = 130
                self.progress.update(phase="aborted", message=str(error), eta_seconds=None)
        except Exception as error:
            self.logger.exception("Google Photos sync failed")
            with self.lock:
                self.error = str(error)
                self.last_exit_code = 1
                self.progress.update(phase="failed", message=str(error), eta_seconds=None)
        finally:
            with self.lock:
                self.running = False
                self.active = None
            self.operation_lock.release()

    def abort(self, token: str) -> tuple[bool, str]:
        with self.lock:
            if not self.running or not self.active or not secrets.compare_digest(token, self.active[0]):
                return False, "This upload is no longer running."
            self.active[1].abort_requested.set()
            self.progress.update(phase="aborting", message="Aborting; waiting for any in-flight Google request to finish...", eta_seconds=None)
        return True, "Abort requested. Completed changes will be kept."

    def snapshot(self) -> Snapshot:
        with self.lock:
            return Snapshot(self.running, self.last_exit_code, self.error, dict(self.progress))


class Service:
    def __init__(self, logger: logging.Logger | None = None):
        self.csrf = secrets.token_urlsafe(32)
        self.control = GoogleSyncControl(logger or logging.getLogger("photo_curator_google"))

    def dispatch(self, message: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        path = message.get("path")
        method = message.get("method", "GET")
        if path not in ROUTES:
            return 404, {}
        if method == "POST":
            headers = message.get("headers", {})
            token = next(
                (value for key, value in headers.items() if key.lower() == "x-csrf-token"),
                None,
            ) if isinstance(headers, dict) else None
            if token != self.csrf:
                return 403, {"error": "The local sync request could not be verified."}
        try:
            body = json.loads(message.get("body") or "{}")
            if not isinstance(body, dict):
                raise ValueError("Invalid local sync request.")
            if path == "/auth-state":
                return 200, {"csrf_token": self.csrf}
            if path == "/control-state":
                snapshot = self.control.snapshot()
                return 200, {"running": snapshot.running, "last_exit_code": snapshot.last_exit_code, "error": snapshot.error, "progress": snapshot.progress}
            credentials = body.get("credentials")
            if path in {"/google-access", "/frame-albums", "/clear-google-album"} and (not isinstance(credentials, str) or not credentials):
                raise ValueError("Connect Google Photos first.")
            if path == "/google-access":
                return 200, self.control.access(os.path.abspath(os.path.expanduser(credentials)), body.get("interactive") is True)
            if path == "/frame-albums":
                return 200, {"albums": self.control.albums(os.path.abspath(os.path.expanduser(credentials)))}
            if path == "/clear-google-album":
                album_id = body.get("album_id")
                if not isinstance(album_id, str) or not album_id:
                    raise ValueError("Choose a Google Photos album to clear.")
                return 200, {"removed": self.control.clear_album(os.path.abspath(os.path.expanduser(credentials)), album_id)}
            if path == "/prepare-frame-sync":
                return 200, self.control.prepare(body)
            if path == "/start-frame-sync":
                if not all(isinstance(body.get(key), str) for key in ("token", "mode")):
                    raise ValueError("Review the destination first.")
                accepted, reply = self.control.start(body["token"], body["mode"], body.get("skip_unresolved") is True)
                return (202 if accepted else 409), {"message": reply, "error": None if accepted else reply}
            token = body.get("token")
            if not isinstance(token, str):
                raise ValueError("Choose a running upload to abort.")
            accepted, reply = self.control.abort(token)
            return (202 if accepted else 409), {"message": reply, "error": None if accepted else reply}
        except ValueError as error:
            return 400, {"error": str(error)}
        except Exception as error:
            self.control.logger.exception("Google helper request failed")
            message = "Google access could not be checked. Try again later." if path == "/google-access" else str(error)
            return (503 if path == "/google-access" else 400), {"error": message}


def serve(input_stream: Any = None, output_stream: Any = None) -> None:
    source = input_stream or sys.stdin
    destination = output_stream or sys.stdout
    service = Service(configure_logging())
    for line in source:
        identifier = None
        try:
            if len(line) > 16 * 1024 * 1024:
                raise ValueError("Request too large")
            message = json.loads(line)
            identifier = message["id"]
            status, body = service.dispatch(message)
        except (KeyError, TypeError, json.JSONDecodeError):
            status, body = 400, {"error": "Invalid local sync request."}
        except ValueError as error:
            status, body = 413, {"error": str(error)}
        destination.write(PREFIX + json.dumps({"id": identifier, "status": status, "body": json.dumps(body)}) + "\n")
        destination.flush()


def configure_logging() -> logging.Logger:
    logger = logging.getLogger("photo_curator_google")
    if logger.handlers:
        return logger
    path = Path.home() / "Library" / "Logs" / "Photo Curator" / "google-helper.log"
    path.parent.mkdir(parents=True, exist_ok=True)
    handler = RotatingFileHandler(path, maxBytes=1_000_000, backupCount=2, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    return logger
