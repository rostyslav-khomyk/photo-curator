from unittest.mock import Mock
import logging
import requests
import pytest

from icloudpd.google_oauth_server import SimplifiedGoogleAuth, GOOGLE_APP_SCOPES


def test_reconsent_does_not_restore_retired_permissions():
    auth = SimplifiedGoogleAuth("unused.json")
    auth._load_credentials = Mock(return_value=True)
    auth.refresh_token = "synthetic"
    auth.granted_scopes = {"retired-cloud-scope"}
    auth._oauth_flow = Mock(return_value=True)
    assert auth.authenticate(GOOGLE_APP_SCOPES, interactive=True)
    auth._oauth_flow.assert_called_once_with(tuple(sorted(GOOGLE_APP_SCOPES)))


@pytest.mark.parametrize("error_code,revoked", [("invalid_grant", True), ("invalid_client", False)])
def test_refresh_distinguishes_revocation(monkeypatch, error_code, revoked):
    response = Mock(status_code=400)
    response.json.return_value = {"error": error_code}
    response.raise_for_status.side_effect = requests.HTTPError(response=response)
    monkeypatch.setattr("icloudpd.google_oauth_server.requests.post", Mock(return_value=response))
    auth = SimplifiedGoogleAuth("unused.json")
    assert not auth._refresh_access_token()
    assert auth.refresh_revoked is revoked


def test_transient_refresh_never_opens_consent():
    auth = SimplifiedGoogleAuth("unused.json")
    auth._load_credentials = Mock(return_value=True)
    auth.refresh_token = "synthetic"
    auth.granted_scopes = {"scope"}
    auth._refresh_access_token = Mock(return_value=False)
    auth._oauth_flow = Mock()
    assert not auth.authenticate(("scope",), interactive=True)
    auth._oauth_flow.assert_not_called()


def test_access_check_requires_only_photos_and_identity(monkeypatch):
    from icloudpd.server import WebControl
    auth = Mock()
    auth.authenticate.return_value = True
    monkeypatch.setattr("icloudpd.google_oauth_server.SimplifiedGoogleAuth", Mock(return_value=auth))
    control = WebControl(lambda _: 0, logging.getLogger(__name__))
    assert control.google_access("unused", False) == {"status": "connected"}
    auth.authenticate.assert_called_once_with(GOOGLE_APP_SCOPES, interactive=False)
    assert set(GOOGLE_APP_SCOPES) == {
        "openid",
        "https://www.googleapis.com/auth/photoslibrary.appendonly",
        "https://www.googleapis.com/auth/photoslibrary.readonly.appcreateddata",
        "https://www.googleapis.com/auth/photoslibrary.edit.appcreateddata",
    }
