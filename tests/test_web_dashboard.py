import json
import logging
import threading
from pathlib import Path

import pytest

from icloudpd.cli import parse
from icloudpd.server import WebControl, form_to_cli_args, serve_app, update_album_mapping_from_form
from icloudpd.status import Status, StatusExchange


def test_web_ui_flag_starts_without_user_configuration() -> None:
    global_config, user_configs = parse(["--web-ui"])

    assert global_config.web_ui is True
    assert user_configs == []


def test_dashboard_form_builds_normal_cli_arguments(tmp_path: Path) -> None:
    args = form_to_cli_args(
        {
            "username": "person@example.com",
            "directory": str(tmp_path / "photos"),
            "albums": "Family\nTrips\n",
            "size": "original",
            "folder_structure": "{:%Y/%m}",
            "recent": "25",
            "skip_videos": "on",
            "google_photos_sync": "on",
            "google_credentials": str(tmp_path / "google.json"),
            "google_album_mapping": str(tmp_path / "albums.json"),
        }
    )

    global_config, user_configs = parse(args)
    assert global_config.web_ui is False
    assert len(user_configs) == 1
    assert user_configs[0].username == "person@example.com"
    assert user_configs[0].albums == ["Family", "Trips"]
    assert user_configs[0].recent == 25
    assert user_configs[0].skip_videos is True
    assert user_configs[0].google_photos_sync is True


@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        ("username", "", "Apple ID"),
        ("directory", "", "download directory"),
        ("recent", "0", "positive number"),
        ("watch_interval", "5", "at least 10 seconds"),
    ],
)
def test_dashboard_form_reports_invalid_fields(field: str, value: str, message: str) -> None:
    form = {
        "username": "person@example.com",
        "directory": "./photos",
        "recent": "",
        "watch_interval": "",
    }
    form[field] = value

    with pytest.raises(ValueError, match=message):
        form_to_cli_args(form)


def test_web_control_rejects_a_second_concurrent_run() -> None:
    started = threading.Event()
    release = threading.Event()

    def runner(_args: list[str]) -> int:
        started.set()
        release.wait(timeout=2)
        return 0

    control = WebControl(runner, logging.getLogger("test"))
    accepted, _ = control.start(["--username", "one"])
    assert accepted is True
    assert started.wait(timeout=1)

    accepted, message = control.start(["--username", "two"])
    assert accepted is False
    assert "already running" in message
    release.set()


def test_dashboard_creates_album_mapping_and_preserves_ids(tmp_path: Path) -> None:
    mapping_path = tmp_path / "albums.json"
    mapping_path.write_text(
        '{"album_mappings":{"Old":"Archive"},"google_album_ids":{"Archive":"id-1"}}',
        encoding="utf-8",
    )

    update_album_mapping_from_form(
        {
            "google_photos_sync": "on",
            "google_album_mapping": str(mapping_path),
            "albums": "Family\nTrips",
            "google_destination_album": "Imported from iCloud",
        }
    )

    contents = mapping_path.read_text(encoding="utf-8")
    assert '"Family": "Imported from iCloud"' in contents
    assert '"Trips": "Imported from iCloud"' in contents
    assert '"Archive": "id-1"' in contents


def test_dashboard_requires_source_albums_for_google_sync(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="at least one iCloud album"):
        update_album_mapping_from_form(
            {
                "google_photos_sync": "on",
                "google_album_mapping": str(tmp_path / "albums.json"),
                "albums": "",
            }
        )


def test_native_auth_bridge_accepts_a_valid_mfa_code(monkeypatch: pytest.MonkeyPatch) -> None:
    captured = {}
    exchange = StatusExchange()
    exchange.set_current_user("person@example.com")
    assert exchange.replace_status(Status.NO_INPUT_NEEDED, Status.NEED_MFA)

    def capture_app(app: object, **_kwargs: object) -> None:
        captured["app"] = app

    monkeypatch.setattr("icloudpd.server.waitress.serve", capture_app)
    serve_app(logging.getLogger("test"), exchange, port=0)
    client = captured["app"].test_client()

    state_response = client.get("/auth-state")
    state = state_response.get_json()
    assert state_response.status_code == 200
    assert state["status"] == "need_mfa"
    assert state["current_user"] == "person@example.com"

    headers = {"X-CSRF-Token": state["csrf_token"]}
    invalid_response = client.post(
        "/auth", json={"kind": "code", "value": "123"}, headers=headers
    )
    assert invalid_response.status_code == 400
    assert exchange.get_status() == Status.NEED_MFA

    accepted_response = client.post(
        "/auth", json={"kind": "code", "value": "123456"}, headers=headers
    )
    assert accepted_response.status_code == 202
    assert exchange.get_status() == Status.SUPPLIED_MFA
    assert exchange.get_payload() == "123456"


def test_native_photos_export_can_start_without_icloud_or_google(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    captured = {}
    exchange = StatusExchange()
    control = WebControl(lambda _args: 0, logging.getLogger("test"))

    def capture_app(app: object, **_kwargs: object) -> None:
        captured["app"] = app

    monkeypatch.setattr("icloudpd.server.waitress.serve", capture_app)
    serve_app(logging.getLogger("test"), exchange, control=control, port=0)
    client = captured["app"].test_client()
    state = client.get("/auth-state").get_json()

    response = client.post(
        "/start-local",
        json={
            "items": [{"path": str(tmp_path / "Family" / "photo.jpg"), "album": "Family"}],
            "google_photos_sync": False,
            "dry_run": False,
        },
        headers={"X-CSRF-Token": state["csrf_token"]},
    )

    assert response.status_code == 202
    assert b"Exported 1 item" in response.data


def test_clear_google_album_requires_confirmation_payload_and_returns_count(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured = {}
    exchange = StatusExchange()
    control = WebControl(lambda _args: 0, logging.getLogger("test"))

    def capture_app(app: object, **_kwargs: object) -> None:
        captured["app"] = app

    monkeypatch.setattr("icloudpd.server.waitress.serve", capture_app)
    monkeypatch.setattr(control, "clear_google_album", lambda credentials, album_id: 7)
    serve_app(logging.getLogger("test"), exchange, control=control, port=0)
    client = captured["app"].test_client()
    csrf = client.get("/auth-state").get_json()["csrf_token"]
    headers = {"X-CSRF-Token": csrf}

    assert client.post("/clear-google-album", json={}, headers=headers).status_code == 400
    response = client.post(
        "/clear-google-album",
        json={"credentials": "~/google.json", "album_id": "album-1"},
        headers=headers,
    )
    assert response.status_code == 200
    assert response.get_json() == {"removed": 7}


def test_matching_destination_replaces_previous_custom_mapping(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    captured = {}
    control = WebControl(lambda _args: 0, logging.getLogger("test"))
    monkeypatch.setattr(
        "icloudpd.server.waitress.serve", lambda app, **kwargs: captured.update(app=app)
    )
    monkeypatch.setattr(control, "start_local", lambda *args: (True, "Accepted"))
    serve_app(logging.getLogger("test"), StatusExchange(), control=control, port=0)
    client = captured["app"].test_client()
    headers = {"X-CSRF-Token": client.get("/auth-state").get_json()["csrf_token"]}
    mapping = tmp_path / "mapping.json"
    payload = {
        "items": [{"path": str(tmp_path / "photo.jpg"), "album": "Family"}],
        "google_photos_sync": True,
        "google_credentials": str(tmp_path / "google.json"),
        "google_album_mapping": str(mapping),
        "album_mappings": {"Family": "Archive"},
    }
    assert client.post("/start-local", json=payload, headers=headers).status_code == 202
    assert json.loads(mapping.read_text())["album_mappings"] == {"Family": "Archive"}
    payload["album_mappings"] = None
    assert client.post("/start-local", json=payload, headers=headers).status_code == 202
    assert json.loads(mapping.read_text())["album_mappings"] == {"Family": "Family"}
