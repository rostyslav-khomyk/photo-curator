"""Local web dashboard and browser-based iCloud authentication UI."""

import json
import os
import secrets
import sys
import tempfile
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from logging import Formatter, Logger
from logging.handlers import RotatingFileHandler
from pathlib import Path
from threading import Lock, Thread
from typing import Any, TypeVar

import waitress
from flask import Flask, Response, abort, jsonify, make_response, render_template, request

from icloudpd.frame_sync import SyncAborted
from icloudpd.status import Status, StatusExchange

BrowseResult = TypeVar("BrowseResult")


@dataclass(frozen=True)
class ControlSnapshot:
    running: bool
    last_exit_code: int | None
    error: str | None
    progress: dict[str, Any] | None = None


class WebControl:
    """Run at most one dashboard-started sync in a background thread."""

    def __init__(self, runner: Callable[[list[str]], int], logger: Logger):
        self._runner = runner
        self._logger = logger
        self._lock = Lock()
        self._running = False
        self._last_exit_code: int | None = None
        self._error: str | None = None
        self._icloud_browser: Callable[[str], list[str]] | None = None
        self._google_browser: Callable[[str], list[str]] | None = None
        self._browser_lock = Lock()
        self._progress: dict[str, Any] = {}
        self._prepared_plan: tuple[str, Any] | None = None
        self._active_frame: tuple[str, Any] | None = None

    def set_cloud_browsers(
        self,
        icloud_browser: Callable[[str], list[str]],
        google_browser: Callable[[str], list[str]],
    ) -> None:
        self._icloud_browser = icloud_browser
        self._google_browser = google_browser

    def browse_icloud(self, username: str) -> list[str]:
        browser = self._icloud_browser
        if not browser:
            raise RuntimeError("iCloud album browsing is unavailable.")
        return self._browse(lambda: browser(username))

    def browse_google(self, credentials_path: str) -> list[str]:
        browser = self._google_browser
        if not browser:
            raise RuntimeError("Google album browsing is unavailable.")
        return self._browse(lambda: browser(credentials_path))

    def _browse(self, browser: Callable[[], BrowseResult]) -> BrowseResult:
        if not self._browser_lock.acquire(blocking=False):
            raise RuntimeError("Another cloud browser is already open.")
        try:
            with self._lock:
                if self._running:
                    raise RuntimeError(
                        "Wait for the current sync to finish before browsing albums."
                    )
            return browser()
        finally:
            self._browser_lock.release()

    def google_catalog(self, credentials: str) -> list[dict[str, Any]]:
        from icloudpd.google_photos_client import GooglePhotosClient

        return self._browse(
            lambda: GooglePhotosClient(
                credentials, self._logger, identify_account=True
            ).list_albums()
        )

    def clear_google_album(self, credentials: str, album_id: str) -> int:
        from icloudpd.google_photos_client import GooglePhotosClient

        def clear() -> int:
            client = GooglePhotosClient(credentials, self._logger, identify_account=True)
            albums = {str(album["id"]): album for album in client.list_albums()}
            if album_id not in albums:
                raise ValueError("The selected Google album is no longer accessible to Photo Curator.")
            media_ids = client.album_media_ids(album_id)
            if not media_ids:
                return 0
            client.enable_album_editing()
            client.change_album_membership(album_id, media_ids, remove=True)
            remaining = client.album_media_ids(album_id)
            if media_ids & remaining:
                raise RuntimeError("Google did not confirm that the album was cleared. Check it before retrying.")
            return len(media_ids)

        return self._browse(clear)

    def google_access(self, credentials: str, interactive: bool) -> dict:
        from icloudpd.google_oauth_server import SimplifiedGoogleAuth, GOOGLE_APP_SCOPES

        def check():
            auth = SimplifiedGoogleAuth(credentials, self._logger)
            scopes = GOOGLE_APP_SCOPES
            if auth.authenticate(scopes, interactive=interactive):
                return {"status": "connected"}
            # A failed refresh can be an outage; do not label it revoked or erase tokens.
            missing = auth.refresh_revoked or not auth.refresh_token or not set(scopes) <= auth.granted_scopes
            return {"status": "needs_connection" if missing else "unavailable"}

        return self._browse(check)

    def prepare_frame(self, payload: dict[str, Any]) -> dict[str, Any]:
        from icloudpd.frame_sync import FrameSyncPlan
        from icloudpd.google_photos_client import GooglePhotosClient

        def prepare() -> dict[str, Any]:
            credentials = payload.get("credentials")
            raw_items = payload.get("items")
            choices = payload.get("destinations", {})
            if not isinstance(credentials, str) or not credentials:
                raise ValueError("Connect Google Photos first.")
            if not isinstance(raw_items, list) or not raw_items:
                raise ValueError("Select photos to sync first.")
            items: list[tuple[str, str]] = []
            for item in raw_items:
                if not isinstance(item, dict) or not all(
                    isinstance(item.get(key), str) and item[key] for key in ("path", "album")
                ):
                    raise ValueError("Invalid exported photo.")
                items.append((os.path.abspath(item["path"]), item["album"]))
            if not isinstance(choices, dict) or not all(
                isinstance(key, str)
                and isinstance(value, dict)
                and all(isinstance(k, str) and isinstance(v, str) for k, v in value.items())
                for key, value in choices.items()
            ):
                raise ValueError("Choose a valid destination album.")
            path = Path(credentials).expanduser().resolve()
            plan = FrameSyncPlan(
                GooglePhotosClient(str(path), self._logger, identify_account=True),
                items,
                choices,
                path.with_name("photo_relay_uploads.sqlite3"),
            )
            token = secrets.token_urlsafe(32)
            with self._lock:
                self._prepared_plan = (token, plan)
            return {"token": token, **plan.summary()}

        return self._browse(prepare)

    def start_frame(
        self, token: str, mode: str, *, skip_unresolved: bool = False
    ) -> tuple[bool, str]:
        if mode not in {"append", "replace"}:
            return False, "Choose Add photos or Replace Photo Relay photos."
        with self._lock:
            prepared = self._prepared_plan
            if not prepared or not secrets.compare_digest(token, prepared[0]):
                return False, "Review your Google destination before syncing."
            plan = prepared[1]

        def report(progress: dict[str, Any]) -> None:
            with self._lock:
                self._progress.update(progress)

        def run() -> int:
            report({"run_id": token})
            self._logger.info(
                "Starting reviewed Google sync: mode=%s, leave_unresolved_out=%s",
                mode,
                skip_unresolved,
            )
            return plan.run(mode, report, skip_unresolved=skip_unresolved)

        accepted, message = self._start_task(run, active_frame=(token, plan))
        if accepted:
            with self._lock:
                self._prepared_plan = None
        return accepted, message

    def abort_frame(self, token: str) -> tuple[bool, str]:
        with self._lock:
            if (
                not self._running
                or not self._active_frame
                or not secrets.compare_digest(token, self._active_frame[0])
            ):
                return False, "This upload is no longer running."
            self._active_frame[1].abort_requested.set()
            self._progress.update(
                phase="aborting",
                message="Aborting; waiting for any in-flight Google request to finish…",
                eta_seconds=None,
            )
        return True, "Abort requested. Completed changes will be kept."

    def start(self, args: list[str]) -> tuple[bool, str]:
        return self._start_task(lambda: self._runner(args))

    def start_local(
        self,
        items: list[tuple[str, str]],
        credentials_path: str | None,
        mapping_path: str | None,
        google_enabled: bool,
        dry_run: bool,
    ) -> tuple[bool, str]:
        """Upload files exported by the native Photos framework."""

        def run() -> int:
            if dry_run or not google_enabled:
                return 0
            from icloudpd.google_photos_sync import build_google_photos_uploader

            uploader = build_google_photos_uploader(
                credentials_path, mapping_path, self._logger, enabled=True
            )
            if uploader is None:
                raise RuntimeError("Google Photos could not be initialized.")
            failures = 0
            for path, album in items:
                if not uploader(path, album):
                    failures += 1
            if failures:
                raise RuntimeError(f"Google Photos could not upload {failures} exported item(s).")
            return 0

        message = (
            f"Exported {len(items)} item(s); Google Photos upload started."
            if google_enabled and not dry_run
            else f"Exported {len(items)} item(s) from Photos."
        )
        return self._start_task(run, message)

    def _start_task(
        self,
        task: Callable[[], int],
        message: str = "Sync started. This page will update automatically.",
        active_frame: tuple[str, Any] | None = None,
    ) -> tuple[bool, str]:
        if not self._browser_lock.acquire(blocking=False):
            return False, "Wait for the current Google album review to finish."
        try:
            with self._lock:
                if self._running:
                    return False, "A sync is already running."
                self._running = True
                self._last_exit_code = None
                self._error = None
                self._active_frame = active_frame
                self._progress = {"phase": "preparing", "message": "Preparing Google Photos sync"}
        finally:
            self._browser_lock.release()
        Thread(target=self._run_task, args=(task,), daemon=True).start()
        return True, message

    def _run_task(self, task: Callable[[], int]) -> None:
        try:
            exit_code = task()
            with self._lock:
                self._last_exit_code = exit_code
        except SyncAborted as error:
            with self._lock:
                self._last_exit_code = 130
                self._progress.update(phase="aborted", message=str(error), eta_seconds=None)
        except Exception as error:
            self._logger.exception("Dashboard sync failed")
            with self._lock:
                self._error = str(error)
                self._last_exit_code = 1
                self._progress.update(phase="failed", message=str(error), eta_seconds=None)
        finally:
            with self._lock:
                self._running = False
                self._active_frame = None

    def snapshot(self) -> ControlSnapshot:
        with self._lock:
            return ControlSnapshot(
                self._running, self._last_exit_code, self._error, dict(self._progress)
            )


def form_to_cli_args(form: Mapping[str, str]) -> list[str]:
    """Validate dashboard fields and translate them into normal CLI options."""
    username = form.get("username", "").strip()
    directory = os.path.abspath(os.path.expanduser(form.get("directory", "").strip()))
    if not username:
        raise ValueError("Enter your Apple ID email address.")
    if not form.get("directory", "").strip():
        raise ValueError("Choose a download directory.")

    args = ["--username", username, "--directory", directory]
    for album in form.get("albums", "").splitlines():
        if album.strip():
            args.extend(["--album", album.strip()])

    size = form.get("size", "original")
    if size not in {"original", "medium", "thumb", "adjusted", "alternative"}:
        raise ValueError("Choose a valid photo size.")
    args.extend(["--size", size])

    folder_structure = form.get("folder_structure", "{:%Y/%m/%d}").strip()
    args.extend(["--folder-structure", folder_structure or "none"])

    for field, option in (
        ("skip_videos", "--skip-videos"),
        ("skip_live_photos", "--skip-live-photos"),
        ("dry_run", "--dry-run"),
    ):
        if form.get(field):
            args.append(option)

    recent = form.get("recent", "").strip()
    if recent:
        if not recent.isdigit() or int(recent) < 1:
            raise ValueError("Recent photos must be a positive number.")
        args.extend(["--recent", recent])

    watch_interval = form.get("watch_interval", "").strip()
    if watch_interval:
        if not watch_interval.isdigit() or int(watch_interval) < 10:
            raise ValueError("Watch interval must be at least 10 seconds.")
        args.extend(["--watch-with-interval", watch_interval])

    if form.get("google_photos_sync"):
        credentials = form.get("google_credentials", "").strip()
        mapping = form.get("google_album_mapping", "").strip()
        if not credentials or not mapping:
            raise ValueError("Google sync requires both credentials and album mapping files.")
        args.extend(
            [
                "--google-photos-sync",
                "--google-photos-credentials",
                os.path.abspath(os.path.expanduser(credentials)),
                "--google-photos-album-mapping",
                os.path.abspath(os.path.expanduser(mapping)),
            ]
        )
    return args


def update_album_mapping_from_form(form: Mapping[str, str]) -> None:
    """Create missing source-to-destination mappings selected in the dashboard."""
    if not form.get("google_photos_sync"):
        return
    source_albums = [
        album.strip() for album in form.get("albums", "").splitlines() if album.strip()
    ]
    if not source_albums:
        raise ValueError("Choose at least one iCloud album when Google Photos sync is enabled.")

    mapping_value = form.get("google_album_mapping", "").strip()
    if not mapping_value:
        raise ValueError("Choose an album mapping file.")
    mapping_path = os.path.abspath(os.path.expanduser(mapping_value))
    destination = form.get("google_destination_album", "").strip()
    data: dict[str, object] = {}
    try:
        with open(mapping_path, encoding="utf-8") as file_obj:
            loaded = json.load(file_obj)
            if isinstance(loaded, dict):
                data = loaded
    except FileNotFoundError:
        pass
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"Could not read the album mapping file: {error}") from error

    mappings = data.get("album_mappings", {})
    if not isinstance(mappings, dict):
        mappings = {}
    for source_album in source_albums:
        mappings[source_album] = destination or mappings.get(source_album) or source_album
    data["album_mappings"] = mappings

    parent = os.path.dirname(mapping_path)
    os.makedirs(parent, exist_ok=True)
    temporary_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=parent, prefix=".albums.", delete=False
        ) as file_obj:
            json.dump(data, file_obj, indent=2, sort_keys=True)
            file_obj.write("\n")
            temporary_path = file_obj.name
        os.replace(temporary_path, mapping_path)
    finally:
        if temporary_path and os.path.exists(temporary_path):
            os.unlink(temporary_path)


def serve_app(
    logger: Logger,
    status_exchange: StatusExchange,
    control: WebControl | None = None,
    host: str = "127.0.0.1",
    port: int = 8080,
) -> None:
    if sys.platform == "darwin" and os.environ.get("ICLOUDPD_PARENT_PID"):
        log_path = Path.home() / "Library" / "Logs" / "Photo Relay" / "engine.log"
        try:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            if not any(
                isinstance(handler, RotatingFileHandler) and handler.baseFilename == str(log_path)
                for handler in logger.handlers
            ):
                handler = RotatingFileHandler(
                    log_path, maxBytes=2_000_000, backupCount=3, encoding="utf-8"
                )
                os.chmod(log_path, 0o600)
                handler.setFormatter(Formatter("%(asctime)s %(levelname)s %(message)s"))
                logger.addHandler(handler)
            logger.info("Photo Relay local service started")
        except OSError:
            logger.warning("Could not open the persistent Photo Relay log")
    app = Flask(__name__)
    app.logger = logger
    bundle_dir = getattr(sys, "_MEIPASS", None)
    if bundle_dir is not None:
        app.template_folder = os.path.join(bundle_dir, "templates")
        app.static_folder = os.path.join(bundle_dir, "static")

    csrf_token = secrets.token_urlsafe(32)

    @app.context_processor
    def inject_csrf_token() -> dict[str, str]:
        return {"csrf_token": csrf_token}

    @app.before_request
    def protect_local_actions() -> None:
        if request.method == "POST" and not secrets.compare_digest(
            request.headers.get("X-CSRF-Token", ""), csrf_token
        ):
            abort(403)

    @app.route("/")
    def index() -> Response | str:
        return render_template(
            "index.html",
            control_mode=control is not None,
            control=control.snapshot() if control else None,
            native_photos_directory=os.path.join(os.path.expanduser("~/Pictures"), "Photo Relay"),
        )

    @app.route("/start", methods=["POST"])
    def start_sync() -> Response | str:
        if not control:
            return make_response("Dashboard controls are disabled.", 404)
        try:
            update_album_mapping_from_form(request.form)
            args = form_to_cli_args(request.form)
        except ValueError as error:
            return make_response(
                render_template("launch_result.html", success=False, message=str(error)), 400
            )
        accepted, message = control.start(args)
        return make_response(
            render_template("launch_result.html", success=accepted, message=message),
            202 if accepted else 409,
        )

    @app.route("/start-local", methods=["POST"])
    def start_local_sync() -> Response:
        if not control:
            return make_response("Dashboard controls are disabled.", 404)
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return make_response(
                render_template(
                    "launch_result.html", success=False, message="Invalid Photos export request."
                ),
                400,
            )
        raw_items = payload.get("items")
        if not isinstance(raw_items, list):
            return make_response(
                render_template(
                    "launch_result.html", success=False, message="Photos did not export any items."
                ),
                400,
            )
        items: list[tuple[str, str]] = []
        for item in raw_items:
            if not isinstance(item, dict):
                continue
            path, album = item.get("path"), item.get("album")
            if isinstance(path, str) and path and isinstance(album, str) and album:
                items.append((os.path.abspath(path), album))

        google_enabled = payload.get("google_photos_sync") is True
        credentials = payload.get("google_credentials")
        mapping = payload.get("google_album_mapping")
        if google_enabled and (not isinstance(credentials, str) or not isinstance(mapping, str)):
            return make_response(
                render_template(
                    "launch_result.html",
                    success=False,
                    message="Google sync requires OAuth credentials and album mapping files.",
                ),
                400,
            )
        if google_enabled:
            assert isinstance(mapping, str)
            album_names = sorted({album for _, album in items})
            try:
                custom_mappings = payload.get("album_mappings")
                if isinstance(custom_mappings, dict):
                    for album_name in album_names:
                        destination = custom_mappings.get(album_name)
                        if not isinstance(destination, str) or not destination:
                            raise ValueError(f"Choose a Google album for '{album_name}'.")
                        update_album_mapping_from_form(
                            {
                                "google_photos_sync": "on",
                                "google_album_mapping": mapping,
                                "google_destination_album": destination,
                                "albums": album_name,
                            }
                        )
                else:
                    for album_name in album_names:
                        update_album_mapping_from_form(
                            {
                                "google_photos_sync": "on",
                                "google_album_mapping": mapping,
                                "google_destination_album": album_name,
                                "albums": album_name,
                            }
                        )
            except ValueError as error:
                return make_response(
                    render_template("launch_result.html", success=False, message=str(error)), 400
                )

        accepted, message = control.start_local(
            items,
            os.path.abspath(os.path.expanduser(credentials))
            if isinstance(credentials, str)
            else None,
            os.path.abspath(os.path.expanduser(mapping)) if isinstance(mapping, str) else None,
            google_enabled,
            payload.get("dry_run") is True,
        )
        return make_response(
            render_template("launch_result.html", success=accepted, message=message),
            202 if accepted else 409,
        )

    @app.route("/browse/icloud", methods=["POST"])
    def browse_icloud() -> Response | str:
        if not control:
            return make_response("Dashboard controls are disabled.", 404)
        username = request.form.get("username", "").strip()
        if not username:
            return make_response(
                render_template(
                    "cloud_albums.html",
                    kind="icloud",
                    albums=[],
                    error="Enter your Apple ID email first.",
                ),
                400,
            )
        try:
            albums = control.browse_icloud(username)
            return render_template("cloud_albums.html", kind="icloud", albums=albums, error=None)
        except Exception as error:
            logger.error("Could not browse iCloud albums: %s", error)
            return make_response(
                render_template("cloud_albums.html", kind="icloud", albums=[], error=str(error)),
                400,
            )

    @app.route("/browse/google", methods=["POST"])
    def browse_google() -> Response | str:
        if not control:
            return make_response("Dashboard controls are disabled.", 404)
        credentials = request.form.get("google_credentials", "").strip()
        if not credentials:
            return make_response(
                render_template(
                    "cloud_albums.html",
                    kind="google",
                    albums=[],
                    error="Choose your Google OAuth credentials file first.",
                ),
                400,
            )
        try:
            credentials_path = os.path.abspath(os.path.expanduser(credentials))
            albums = control.browse_google(credentials_path)
            return render_template("cloud_albums.html", kind="google", albums=albums, error=None)
        except Exception as error:
            logger.error("Could not browse Google albums: %s", error)
            return make_response(
                render_template("cloud_albums.html", kind="google", albums=[], error=str(error)),
                400,
            )

    @app.route("/run-state", methods=["GET"])
    def run_state() -> Response | str:
        return render_template("run_state.html", control=control.snapshot() if control else None)

    @app.route("/control-state", methods=["GET"])
    def control_state() -> Response:
        snapshot = control.snapshot() if control else ControlSnapshot(False, None, None)
        return jsonify(
            running=snapshot.running,
            last_exit_code=snapshot.last_exit_code,
            error=snapshot.error,
            progress=snapshot.progress,
        )

    @app.route("/frame-albums", methods=["POST"])
    def frame_albums() -> Response:
        payload = request.get_json(silent=True)
        credentials = payload.get("credentials") if isinstance(payload, dict) else None
        if not control or not isinstance(credentials, str) or not credentials:
            return make_response(jsonify(error="Connect Google Photos first."), 400)
        try:
            return jsonify(
                albums=control.google_catalog(os.path.abspath(os.path.expanduser(credentials)))
            )
        except Exception as error:
            return make_response(jsonify(error=str(error)), 400)

    @app.route("/google-access", methods=["POST"])
    def google_access() -> Response:
        payload = request.get_json(silent=True)
        if not control or not isinstance(payload, dict):
            return make_response(jsonify(error="Invalid access check."), 400)
        credentials = payload.get("credentials")
        if not isinstance(credentials, str) or not credentials:
            return make_response(jsonify(error="Google sign-in is not configured."), 400)
        try:
            return jsonify(control.google_access(
                os.path.abspath(os.path.expanduser(credentials)),
                payload.get("interactive") is True))
        except Exception:
            return make_response(jsonify(error="Google access could not be checked. Try again later."), 503)

    @app.route("/clear-google-album", methods=["POST"])
    def clear_google_album() -> Response:
        payload = request.get_json(silent=True)
        credentials = payload.get("credentials") if isinstance(payload, dict) else None
        album_id = payload.get("album_id") if isinstance(payload, dict) else None
        if (
            not control
            or not isinstance(credentials, str)
            or not credentials
            or not isinstance(album_id, str)
            or not album_id
        ):
            return make_response(jsonify(error="Choose a Google Photos album to clear."), 400)
        try:
            removed = control.clear_google_album(
                os.path.abspath(os.path.expanduser(credentials)), album_id
            )
            return jsonify(removed=removed)
        except Exception as error:
            return make_response(jsonify(error=str(error)), 400)

    @app.route("/prepare-frame-sync", methods=["POST"])
    def prepare_frame_sync() -> Response:
        payload = request.get_json(silent=True)
        if not control or not isinstance(payload, dict):
            return make_response(jsonify(error="Invalid sync review request."), 400)
        try:
            return jsonify(control.prepare_frame(payload))
        except Exception as error:
            return make_response(jsonify(error=str(error)), 400)

    @app.route("/start-frame-sync", methods=["POST"])
    def start_frame_sync() -> Response:
        payload = request.get_json(silent=True)
        if (
            not control
            or not isinstance(payload, dict)
            or not all(isinstance(payload.get(key), str) for key in ("token", "mode"))
        ):
            return make_response(jsonify(error="Review the destination first."), 400)
        accepted, message = control.start_frame(
            payload["token"],
            payload["mode"],
            skip_unresolved=payload.get("skip_unresolved") is True,
        )
        return make_response(
            jsonify(message=message, error=None if accepted else message), 202 if accepted else 409
        )

    @app.route("/abort-frame-sync", methods=["POST"])
    def abort_frame_sync() -> Response:
        payload = request.get_json(silent=True)
        token = payload.get("token") if isinstance(payload, dict) else None
        if not control or not isinstance(token, str):
            return make_response(jsonify(error="Choose a running upload to abort."), 400)
        accepted, message = control.abort_frame(token)
        return make_response(
            jsonify(message=message, error=None if accepted else message), 202 if accepted else 409
        )

    @app.route("/google-albums", methods=["POST"])
    def native_google_albums() -> Response:
        if not control:
            return make_response(jsonify(error="Dashboard controls are disabled."), 404)
        payload = request.get_json(silent=True)
        credentials = payload.get("credentials") if isinstance(payload, dict) else None
        if not isinstance(credentials, str) or not credentials:
            return make_response(jsonify(error="Choose your Google OAuth credentials file."), 400)
        try:
            albums = control.browse_google(os.path.abspath(os.path.expanduser(credentials)))
            return jsonify(albums=albums)
        except Exception as error:
            logger.error("Could not browse Google albums: %s", error)
            return make_response(jsonify(error=str(error)), 400)

    @app.route("/status", methods=["GET"])
    def get_status() -> Response | str:
        status = status_exchange.get_status()
        global_config = status_exchange.get_global_config()
        user_configs = status_exchange.get_user_configs()
        current_user = status_exchange.get_current_user()
        progress = status_exchange.get_progress()
        error = status_exchange.get_error()

        if status == Status.NO_INPUT_NEEDED:
            return render_template(
                "no_input.html",
                status=status,
                error=error,
                progress=progress,
                global_config=vars(global_config) if global_config else None,
                user_configs=[vars(user_config) for user_config in user_configs],
                current_user=current_user,
            )
        if status == Status.NEED_MFA:
            return render_template("code.html", error=error, current_user=current_user)
        if status == Status.NEED_PASSWORD:
            return render_template("password.html", error=error, current_user=current_user)
        return render_template("status.html", status=status)

    @app.route("/auth-state", methods=["GET"])
    def auth_state() -> Response:
        """Return the minimal state needed by the native macOS auth dialog."""
        status = status_exchange.get_status()
        return jsonify(
            status=status.value,
            current_user=status_exchange.get_current_user(),
            error=status_exchange.get_error(),
            csrf_token=csrf_token,
        )

    @app.route("/auth", methods=["POST"])
    def set_native_auth() -> Response:
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return make_response(jsonify(error="Invalid authentication request."), 400)

        kind = payload.get("kind")
        value = payload.get("value")
        current_status = status_exchange.get_status()
        expected_kind = (
            "code"
            if current_status == Status.NEED_MFA
            else "password"
            if current_status == Status.NEED_PASSWORD
            else None
        )
        if not isinstance(value, str) or not value or kind != expected_kind:
            return make_response(
                jsonify(error="Authentication input is not expected right now."), 409
            )
        if kind == "code" and (len(value) != 6 or not value.isdigit()):
            return make_response(
                jsonify(error="Enter the six-digit verification code from Apple."), 400
            )
        if not status_exchange.set_payload(value):
            return make_response(jsonify(error="Authentication input could not be accepted."), 409)
        return make_response(jsonify(accepted=True), 202)

    @app.route("/code", methods=["POST"])
    def set_code() -> Response | str:
        current_user = status_exchange.get_current_user()
        code = request.form.get("code")
        if code is not None and status_exchange.set_payload(code):
            return render_template("code_submitted.html", current_user=current_user)
        logger.error("Cannot accept an MFA code in the current state")
        return make_response(
            render_template("auth_error.html", type="Two-Factor Code", current_user=current_user),
            400,
        )

    @app.route("/password", methods=["POST"])
    def set_password() -> Response | str:
        current_user = status_exchange.get_current_user()
        password = request.form.get("password")
        if password is not None and status_exchange.set_payload(password):
            return render_template("password_submitted.html", current_user=current_user)
        logger.error("Cannot accept a password in the current state")
        return make_response(
            render_template("auth_error.html", type="password", current_user=current_user), 400
        )

    @app.route("/resume", methods=["POST"])
    def resume() -> Response | str:
        status_exchange.get_progress().resume = True
        return make_response("Ok", 200)

    @app.route("/cancel", methods=["POST"])
    def cancel() -> Response | str:
        status_exchange.get_progress().cancel = True
        return make_response("Ok", 200)

    if os.environ.get("PHOTO_CURATOR_NATIVE_PIPE") == "1":
        from icloudpd.native_ipc import serve_native_pipe
        serve_native_pipe(app)
        return
    logger.info("Web dashboard available at http://%s:%d", host, port)
    waitress.serve(app, host=host, port=port)
