import json
import logging
from pathlib import Path
from unittest import mock

import pytest

from icloudpd.google_oauth_server import (
    GOOGLE_PHOTOS_APPEND_SCOPE,
    GOOGLE_PHOTOS_READ_APP_SCOPE,
    GOOGLE_PHOTOS_SCOPES,
    SimplifiedGoogleAuth,
)
from icloudpd.google_photos_client import GooglePhotosClient, GooglePhotosPermissionError
from icloudpd.google_photos_sync import AlbumMapping


class FakeGoogleClient:
    def __init__(self, album_id: str = "album-123") -> None:
        self.album_id = album_id
        self.calls = 0

    def get_or_create_album(self, _album_name: str) -> str:
        self.calls += 1
        return self.album_id


def write_json(path: Path, data: dict[str, object]) -> None:
    path.write_text(json.dumps(data), encoding="utf-8")


def test_album_id_is_persisted_and_reused_across_runs(tmp_path: Path) -> None:
    mapping_path = tmp_path / "albums.json"
    write_json(mapping_path, {"album_mappings": {"Family": "Family archive"}})

    first_client = FakeGoogleClient()
    first_mapping = AlbumMapping(str(mapping_path))
    assert first_mapping.get_or_cache_album_id("Family archive", first_client) == "album-123"
    assert first_client.calls == 1

    second_client = FakeGoogleClient("duplicate-album")
    second_mapping = AlbumMapping(str(mapping_path))
    assert second_mapping.get_or_cache_album_id("Family archive", second_client) == "album-123"
    assert second_client.calls == 0
    assert json.loads(mapping_path.read_text(encoding="utf-8"))["google_album_ids"] == {
        "Family archive": "album-123"
    }


def test_album_is_not_created_when_lookup_is_denied() -> None:
    client = GooglePhotosClient.__new__(GooglePhotosClient)
    client.logger = logging.getLogger("test")
    client.list_albums = mock.Mock(side_effect=GooglePhotosPermissionError("missing scope"))
    client.create_album = mock.Mock(return_value="duplicate")

    with pytest.raises(GooglePhotosPermissionError):
        client.get_or_create_album("Family")

    client.create_album.assert_not_called()


def test_album_lookup_reuses_an_existing_album() -> None:
    client = GooglePhotosClient.__new__(GooglePhotosClient)
    client.logger = logging.getLogger("test")
    client.list_albums = mock.Mock(return_value=[{"id": "album-123", "title": "Family"}])
    client.create_album = mock.Mock(return_value="duplicate")

    assert client.get_or_create_album("Family") == "album-123"
    client.create_album.assert_not_called()


def test_old_google_token_requests_scope_upgrade(tmp_path: Path) -> None:
    credentials_path = tmp_path / "google.json"
    token_path = tmp_path / "google_token.json"
    write_json(
        credentials_path,
        {"installed": {"client_id": "client", "client_secret": "secret"}},
    )
    write_json(
        token_path,
        {
            "access_token": "access",
            "refresh_token": "refresh",
            "scope": GOOGLE_PHOTOS_APPEND_SCOPE,
        },
    )
    auth = SimplifiedGoogleAuth(str(credentials_path))

    with (
        mock.patch.object(auth, "_refresh_access_token") as refresh,
        mock.patch.object(auth, "_oauth_flow", return_value=True) as oauth_flow,
    ):
        assert auth.authenticate() is True

    refresh.assert_not_called()
    oauth_flow.assert_called_once_with(GOOGLE_PHOTOS_SCOPES)


def test_google_token_with_both_scopes_refreshes_without_consent(tmp_path: Path) -> None:
    credentials_path = tmp_path / "google.json"
    token_path = tmp_path / "google_token.json"
    write_json(
        credentials_path,
        {"installed": {"client_id": "client", "client_secret": "secret"}},
    )
    write_json(
        token_path,
        {
            "access_token": "access",
            "refresh_token": "refresh",
            "scope": f"{GOOGLE_PHOTOS_APPEND_SCOPE} {GOOGLE_PHOTOS_READ_APP_SCOPE}",
        },
    )
    auth = SimplifiedGoogleAuth(str(credentials_path))

    with (
        mock.patch.object(auth, "_refresh_access_token", return_value=True) as refresh,
        mock.patch.object(auth, "_oauth_flow") as oauth_flow,
    ):
        assert auth.authenticate() is True

    refresh.assert_called_once_with()
    oauth_flow.assert_not_called()
