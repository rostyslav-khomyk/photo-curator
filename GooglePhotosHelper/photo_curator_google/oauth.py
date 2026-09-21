"""Browser-based OAuth authentication for Google Photos."""

import json
import logging
import os
import secrets
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlencode, urlparse

import requests

GOOGLE_PHOTOS_APPEND_SCOPE = "https://www.googleapis.com/auth/photoslibrary.appendonly"
GOOGLE_PHOTOS_READ_APP_SCOPE = (
    "https://www.googleapis.com/auth/photoslibrary.readonly.appcreateddata"
)
GOOGLE_PHOTOS_SCOPES = (GOOGLE_PHOTOS_APPEND_SCOPE, GOOGLE_PHOTOS_READ_APP_SCOPE)
GOOGLE_APP_SCOPES = (
    "openid", *GOOGLE_PHOTOS_SCOPES,
    "https://www.googleapis.com/auth/photoslibrary.edit.appcreateddata",
)


def parse_scopes(value: Any) -> set[str]:
    """Normalize the scope representation used in Google's token response."""
    if isinstance(value, str):
        return set(value.split())
    if isinstance(value, list):
        return {str(scope) for scope in value}
    return set()


class GoogleOAuthServer:
    """Receive an OAuth callback on a temporary loopback HTTP server."""

    def __init__(self, logger: logging.Logger | None = None):
        self.logger = logger or logging.getLogger(__name__)
        self.auth_code: str | None = None
        self.error: str | None = None
        self.state = secrets.token_urlsafe(32)
        self._completed = threading.Event()
        self._server: ThreadingHTTPServer | None = None
        self._server_thread: threading.Thread | None = None
        self.redirect_uri: str | None = None
    def _handle_callback(self, query: dict[str, list[str]]) -> tuple[str, int]:
        value = lambda key: query.get(key, [None])[0]
        if value("state") != self.state:
            self.error = "The authentication response did not pass its security check."
            self._completed.set()
            return self._error_page(self.error), 400

        oauth_error = value("error")
        if oauth_error:
            self.error = f"Google authorization was not completed: {oauth_error}"
            self._completed.set()
            return self._error_page(self.error), 400

        self.auth_code = value("code")
        if not self.auth_code:
            self.error = "Google did not return an authorization code."
            self._completed.set()
            return self._error_page(self.error), 400

        self._completed.set()
        return (
            "<h1>Google Photos connected</h1>"
            "<p>You can close this tab and return to Photo Curator.</p>",
            200,
        )

    @staticmethod
    def _error_page(message: str) -> str:
        return f"<h1>Google Photos connection failed</h1><p>{message}</p>"

    def start(self) -> None:
        """Bind to a free loopback port and start serving in the background."""
        owner = self

        class CallbackHandler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                parsed = urlparse(self.path)
                body, status = owner._handle_callback(parse_qs(parsed.query)) if parsed.path == "/callback" else ("Not found", 404)
                encoded = body.encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def log_message(self, format: str, *args: Any) -> None:
                owner.logger.debug(format, *args)

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), CallbackHandler)
        self.redirect_uri = f"http://127.0.0.1:{self._server.server_port}/callback"
        self._server_thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._server_thread.start()

    def stop(self) -> None:
        if self._server:
            self._server.shutdown()
        if self._server_thread:
            self._server_thread.join(timeout=2)

    def authorization_url(self, client_id: str, scopes: tuple[str, ...]) -> str:
        if not self.redirect_uri:
            raise RuntimeError("OAuth callback server has not been started")
        params = {
            "client_id": client_id,
            "redirect_uri": self.redirect_uri,
            "response_type": "code",
            "scope": " ".join(scopes),
            "access_type": "offline",
            "prompt": "consent",
            "state": self.state,
        }
        return "https://accounts.google.com/o/oauth2/v2/auth?" + urlencode(params)

    def wait_for_authorization(self, timeout: int = 300) -> str | None:
        if not self._completed.wait(timeout):
            self.error = "Google authorization timed out after 5 minutes."
        return self.auth_code


class SimplifiedGoogleAuth:
    """Load, refresh, or interactively create Google OAuth credentials."""

    TOKEN_URL = "https://oauth2.googleapis.com/token"

    def __init__(
        self,
        credentials_file: str = "google_credentials.json",
        logger: logging.Logger | None = None,
    ):
        self.logger = logger or logging.getLogger(__name__)
        self.credentials_file = credentials_file
        credentials_path = Path(credentials_file)
        self.token_file = str(
            credentials_path.with_name(f"{credentials_path.stem}_token{credentials_path.suffix}")
        )
        self.client_id: str | None = None
        self.client_secret: str | None = None
        self.access_token: str | None = None
        self.refresh_token: str | None = None
        self.granted_scopes: set[str] = set()
        self.refresh_revoked = False

    def authenticate(
        self, scopes: tuple[str, ...] | None = None, *, interactive: bool = True
    ) -> bool:
        """Reuse a suitable token or guide the user through browser consent."""
        required_scopes = scopes or GOOGLE_PHOTOS_SCOPES
        if not self._load_credentials():
            self._show_manual_setup_instructions()
            return False

        missing_scopes = set(required_scopes) - self.granted_scopes
        if self.refresh_token and not missing_scopes:
            if self._refresh_access_token():
                self.logger.info("Google is connected.")
                return True
            if not self.refresh_revoked:
                return False

        if not interactive:
            return False

        if missing_scopes and self.refresh_token:
            self.logger.info(
                "Google Photos needs one updated permission to reuse albums. "
                "Your browser will open once to approve it."
            )
        else:
            self.logger.info("A browser window will open to connect Google Photos.")
        # Preserve Photos permissions, but never re-request retired Cloud permissions.
        consent_scopes = tuple(sorted(set(required_scopes) | (self.granted_scopes & set(GOOGLE_APP_SCOPES))))
        return self._oauth_flow(consent_scopes)

    def _load_credentials(self) -> bool:
        try:
            with open(self.credentials_file, encoding="utf-8") as file_obj:
                credentials = json.load(file_obj)
        except FileNotFoundError:
            return False
        except (KeyError, json.JSONDecodeError) as error:
            self.logger.error("Google OAuth credentials are invalid: %s", error)
            return False

        client = credentials.get("installed") or credentials.get("web")
        if not client:
            self.logger.error("Google credentials must contain an 'installed' or 'web' client.")
            return False
        self.client_id = client.get("client_id")
        self.client_secret = client.get("client_secret")

        try:
            with open(self.token_file, encoding="utf-8") as file_obj:
                token = json.load(file_obj)
        except (FileNotFoundError, json.JSONDecodeError):
            token = {}

        self.access_token = token.get("access_token")
        self.refresh_token = token.get("refresh_token")
        self.granted_scopes = parse_scopes(token.get("scope"))
        return bool(self.client_id and self.client_secret)

    def _oauth_flow(self, scopes: tuple[str, ...]) -> bool:
        oauth_server = GoogleOAuthServer(self.logger)
        try:
            oauth_server.start()
            auth_url = oauth_server.authorization_url(self.client_id or "", scopes)
            if not webbrowser.open(auth_url):
                self.logger.info("Open this URL in a browser:\n%s", auth_url)
            auth_code = oauth_server.wait_for_authorization()
            if not auth_code or not oauth_server.redirect_uri:
                self.logger.error(oauth_server.error or "Google authorization failed.")
                return False
            return self._exchange_code_for_tokens(auth_code, oauth_server.redirect_uri, scopes)
        except OSError as error:
            self.logger.error("Could not start the local OAuth callback server: %s", error)
            return False
        finally:
            oauth_server.stop()

    def _exchange_code_for_tokens(
        self, code: str, redirect_uri: str, requested_scopes: tuple[str, ...]
    ) -> bool:
        try:
            response = requests.post(
                self.TOKEN_URL,
                data={
                    "code": code,
                    "client_id": self.client_id,
                    "client_secret": self.client_secret,
                    "redirect_uri": redirect_uri,
                    "grant_type": "authorization_code",
                },
                timeout=30,
            )
            response.raise_for_status()
        except requests.RequestException as error:
            self.logger.error("Google token exchange failed: %s", error)
            return False

        token = response.json()
        self.access_token = token.get("access_token")
        self.refresh_token = token.get("refresh_token") or self.refresh_token
        self.granted_scopes = parse_scopes(token.get("scope")) or set(requested_scopes)
        if not self.access_token or not self.refresh_token:
            self.logger.error("Google did not return reusable OAuth credentials.")
            return False
        self._save_tokens()
        if not set(requested_scopes) <= self.granted_scopes:
            self.logger.warning("Some requested Google permissions were not granted.")
            return False
        self.logger.info("Google Photos connected successfully.")
        return True

    def _refresh_access_token(self) -> bool:
        self.refresh_revoked = False
        try:
            response = requests.post(
                self.TOKEN_URL,
                data={
                    "refresh_token": self.refresh_token,
                    "client_id": self.client_id,
                    "client_secret": self.client_secret,
                    "grant_type": "refresh_token",
                },
                timeout=30,
            )
            response.raise_for_status()
        except requests.RequestException as error:
            response = getattr(error, "response", None)
            if response is not None and response.status_code == 400:
                try:
                    self.refresh_revoked = response.json().get("error") == "invalid_grant"
                except (ValueError, AttributeError):
                    pass
            self.logger.warning("Google session refresh failed: %s", error)
            return False

        self.access_token = response.json().get("access_token")
        if not self.access_token:
            return False
        self._save_tokens()
        return True

    def _save_tokens(self) -> None:
        token_path = Path(self.token_file)
        with open(token_path, "w", encoding="utf-8") as file_obj:
            json.dump(
                {
                    "access_token": self.access_token,
                    "refresh_token": self.refresh_token,
                    "scope": " ".join(sorted(self.granted_scopes)),
                },
                file_obj,
                indent=2,
            )
            file_obj.write("\n")
        os.chmod(token_path, 0o600)

    def _show_manual_setup_instructions(self) -> None:
        self.logger.error(
            "Google OAuth credentials were not found at %s. Create a Desktop app OAuth "
            "client in Google Cloud Console, enable the Photos Library API, and place the "
            "downloaded JSON file at that location.",
            self.credentials_file,
        )
