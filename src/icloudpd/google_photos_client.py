"""Google Photos API client used by the iCloud download pipeline."""

import io
import json
import logging
import mimetypes
import os
import random
import time
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Any, Callable

import requests
from requests import Response
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from icloudpd.google_oauth_server import GOOGLE_PHOTOS_SCOPES, SimplifiedGoogleAuth


class GooglePhotosError(RuntimeError):
    """Base error for Google Photos integration failures."""


class GooglePhotosPermissionError(GooglePhotosError):
    """Raised when the token lacks access needed for album lookup."""


class GoogleCreateRejected(GooglePhotosError):
    """Google explicitly rejected creation, rather than losing its response."""


class GoogleRateLimited(GoogleCreateRejected):
    """Google declined the request because a rate or quota limit was reached."""


class GooglePhotosClient:
    """Upload media and manage albums created by this application."""

    API_BASE_URL = "https://photoslibrary.googleapis.com/v1"
    UPLOAD_URL = f"{API_BASE_URL}/uploads"

    def __init__(
        self,
        credentials_path: str,
        logger: logging.Logger | None = None,
        *,
        identify_account: bool = False,
    ):
        self.logger = logger or logging.getLogger(__name__)
        self.credentials_path = credentials_path
        self.access_token: str | None = None
        self.refresh_token: str | None = None
        self.token_data: dict[str, Any] = {}
        self.scopes = (
            ("openid", *GOOGLE_PHOTOS_SCOPES) if identify_account else GOOGLE_PHOTOS_SCOPES
        )
        self.client_id: str | None = None
        self.check_cancelled: Callable[[], None] = lambda: None
        self.on_rate_limit: Callable[[int], None] = lambda seconds: None

        self.session = requests.Session()
        retry_strategy = Retry(
            total=3,
            backoff_factor=1,
            status_forcelist=[500, 502, 503, 504],
            # Retrying album creation can create duplicates if Google accepted the
            # first request but its response was lost.
            allowed_methods=["HEAD", "GET", "OPTIONS"],
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        self.session.mount("https://", adapter)
        self.session.mount("http://", adapter)
        self._load_or_authenticate()

    @property
    def token_file(self) -> Path:
        credentials_path = Path(self.credentials_path)
        return credentials_path.with_name(f"{credentials_path.stem}_token{credentials_path.suffix}")

    def _load_or_authenticate(self) -> None:
        auth = SimplifiedGoogleAuth(self.credentials_path, self.logger)
        if not auth.authenticate(self.scopes):
            raise GooglePhotosError("Google Photos authentication was not completed")
        self.client_id = auth.client_id

        with open(self.token_file, encoding="utf-8") as file_obj:
            self.token_data = json.load(file_obj)
        self.access_token = self.token_data.get("access_token")
        self.refresh_token = self.token_data.get("refresh_token")
        if not self.access_token:
            raise GooglePhotosError("Google Photos token does not contain an access token")

    def _refresh_access_token(self) -> None:
        auth = SimplifiedGoogleAuth(self.credentials_path, self.logger)
        if not auth.authenticate(self.scopes, interactive=False):
            raise GooglePhotosError("Google Photos session expired. Sign in again before retrying.")
        with open(self.token_file, encoding="utf-8") as file_obj:
            self.token_data = json.load(file_obj)
        self.access_token = self.token_data.get("access_token")
        self.refresh_token = self.token_data.get("refresh_token")

    def _headers(self, content_type: str = "application/json") -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self.access_token}",
            "Content-Type": content_type,
        }

    def _retry_after_unauthorized(
        self,
        method: str,
        url: str,
        **kwargs: Any,
    ) -> Response:
        kwargs.setdefault("timeout", (15, 120))
        response = self._request_with_backoff(method, url, **kwargs)
        if response.status_code == 401:
            self.check_cancelled()
            self._refresh_access_token()
            headers = dict(kwargs.get("headers", {}))
            headers["Authorization"] = f"Bearer {self.access_token}"
            kwargs["headers"] = headers
            body = kwargs.get("data")
            if body is not None and hasattr(body, "seek"):
                body.seek(0)
            response = self._request_with_backoff(method, url, **kwargs)
        return response

    def _request_with_backoff(self, method: str, url: str, **kwargs: Any) -> Response:
        for attempt in range(4):
            self.check_cancelled()
            response = self.session.request(method, url, **kwargs)
            if response.status_code != 429:
                return response
            delay = self._rate_limit_delay(response.headers.get("Retry-After"), attempt)
            self.logger.warning(
                "Google rate/quota limit (HTTP 429), attempt %s; suggested wait %.0fs",
                attempt + 1,
                delay,
            )
            response.close()
            if attempt == 3 or delay > 300:
                raise GoogleRateLimited(
                    "Google is still limiting requests. Completed uploads were kept. "
                    "Try again later; a daily quota may need to reset. This rejected request did not create a photo."
                )
            self._wait_rate_limit(delay)
            body = kwargs.get("data")
            if body is not None and hasattr(body, "seek"):
                body.seek(0)
        raise AssertionError("Unreachable retry state")

    @staticmethod
    def _rate_limit_delay(retry_after: str | None, attempt: int) -> float:
        delay = 30 * 2**attempt + random.uniform(0, 3)
        if retry_after:
            try:
                requested = float(retry_after)
            except ValueError:
                try:
                    requested = parsedate_to_datetime(retry_after).timestamp() - time.time()
                except (TypeError, ValueError, OverflowError):
                    requested = 0
            delay = max(delay, requested)
        return delay

    def _wait_rate_limit(self, seconds: float) -> None:
        deadline = time.monotonic() + seconds
        last_remaining = -1
        while True:
            self.check_cancelled()
            remaining = max(0, int(deadline - time.monotonic() + 0.999))
            if remaining != last_remaining:
                self.on_rate_limit(remaining)
                last_remaining = remaining
            if remaining == 0:
                return
            time.sleep(min(0.25, max(0, deadline - time.monotonic())))

    def enable_album_editing(self) -> None:
        """Request additional consent only when the user chooses replacement."""
        auth = SimplifiedGoogleAuth(self.credentials_path, self.logger)
        scopes = (
            *self.scopes,
            "https://www.googleapis.com/auth/photoslibrary.edit.appcreateddata",
        )
        if not auth.authenticate(scopes):
            raise GooglePhotosError("Google album editing was not authorized. Nothing was removed.")
        self.scopes = scopes
        self._load_or_authenticate()

    def account_identifier(self) -> str:
        response = self._retry_after_unauthorized(
            "GET",
            "https://openidconnect.googleapis.com/v1/userinfo",
            headers=self._headers(),
        )
        response.raise_for_status()
        subject = response.json().get("sub")
        if not subject or not self.client_id:
            raise GooglePhotosError(
                "Google could not confirm the connected account. Sign in again."
            )
        return f"{self.client_id}:{subject}"

    def album_media_ids(self, album_id: str) -> set[str]:
        """Return only media accessible to this app, across all pages."""
        result: set[str] = set()
        page_token = None
        while True:
            body: dict[str, Any] = {"albumId": album_id, "pageSize": 100}
            if page_token:
                body["pageToken"] = page_token
            response = self._retry_after_unauthorized(
                "POST",
                f"{self.API_BASE_URL}/mediaItems:search",
                headers=self._headers(),
                json=body,
            )
            response.raise_for_status()
            data = response.json()
            result.update(str(item["id"]) for item in data.get("mediaItems", []))
            page_token = data.get("nextPageToken")
            if not page_token:
                return result

    def change_album_membership(
        self, album_id: str, media_ids: set[str], *, remove: bool = False
    ) -> None:
        method = "batchRemoveMediaItems" if remove else "batchAddMediaItems"
        ordered = sorted(media_ids)
        for offset in range(0, len(ordered), 50):
            response = self._retry_after_unauthorized(
                "POST",
                f"{self.API_BASE_URL}/albums/{album_id}:{method}",
                headers=self._headers(),
                json={"mediaItemIds": ordered[offset : offset + 50]},
            )
            if not response.ok:
                try:
                    reason = response.json().get("error", {}).get("message")
                except (TypeError, ValueError):
                    reason = None
                detail = f": {reason}" if reason else ""
                raise GooglePhotosError(
                    f"Google rejected an album update (HTTP {response.status_code}){detail}"
                )

    def existing_media_ids(self, media_ids: set[str]) -> set[str]:
        """Return cached app-created media IDs that still exist in Google Photos."""
        existing: set[str] = set()
        ordered = sorted(media_ids)
        for offset in range(0, len(ordered), 50):
            self.check_cancelled()
            batch = ordered[offset : offset + 50]
            response = self._retry_after_unauthorized(
                "GET",
                f"{self.API_BASE_URL}/mediaItems:batchGet",
                headers=self._headers(),
                params=[("mediaItemIds", media_id) for media_id in batch],
            )
            response.raise_for_status()
            for result in response.json().get("mediaItemResults", []):
                media_id = result.get("mediaItem", {}).get("id")
                if media_id:
                    existing.add(str(media_id))
        return existing

    def upload_bytes(self, path: str, progress: Callable[[int], None]) -> str:
        """Stream a file without loading the full original into memory."""
        headers = self._headers("application/octet-stream")
        headers.update(
            {
                "X-Goog-Upload-Content-Type": mimetypes.guess_type(path)[0]
                or "application/octet-stream",
                "X-Goog-Upload-Protocol": "raw",
                "X-Goog-Upload-File-Name": os.path.basename(path),
            }
        )
        with _ProgressReader(path, progress) as stream:
            response = self._retry_after_unauthorized(
                "POST",
                self.UPLOAD_URL,
                headers=headers,
                data=stream,
            )
        response.raise_for_status()
        if not response.text.strip():
            raise GooglePhotosError("Google did not return an upload token.")
        return response.text

    def create_uploaded_media(self, token: str, filename: str) -> str:
        response = self._retry_after_unauthorized(
            "POST",
            f"{self.API_BASE_URL}/mediaItems:batchCreate",
            headers=self._headers(),
            json={
                "newMediaItems": [{"simpleMediaItem": {"uploadToken": token, "fileName": filename}}]
            },
        )
        self._check_create_response(response)
        results = response.json().get("newMediaItemResults", [])
        if results and results[0].get("status", {}).get("code", 0) != 0:
            status = results[0]["status"]
            raise GoogleCreateRejected(
                f"Google rejected '{filename}' (code {status.get('code')}): {status.get('message', 'No reason provided')}"
            )
        if not results:
            raise GooglePhotosError("Google could not finish creating the uploaded photo.")
        media_id = results[0].get("mediaItem", {}).get("id")
        if not media_id:
            raise GooglePhotosError("Google did not confirm the uploaded photo's identity.")
        return str(media_id)

    @staticmethod
    def _check_create_response(response: Response) -> None:
        if response.status_code in {400, 401, 403, 404, 413, 415}:
            raise GoogleCreateRejected(
                f"Google rejected the creation request (HTTP {response.status_code}). No item was created by this request."
            )
        response.raise_for_status()

    def create_album(self, album_title: str) -> str:
        response = self._retry_after_unauthorized(
            "POST",
            f"{self.API_BASE_URL}/albums",
            headers=self._headers(),
            json={"album": {"title": album_title}},
        )
        self._check_create_response(response)
        album_id = response.json().get("id")
        if not album_id:
            raise GooglePhotosError("Google created an album without returning its ID")
        self.logger.info("Created Google Photos album: %s", album_title)
        return str(album_id)

    def list_albums(self) -> list[dict[str, Any]]:
        """List albums created by this OAuth client, following all pages."""
        albums: list[dict[str, Any]] = []
        page_token: str | None = None
        while True:
            params: dict[str, Any] = {"pageSize": 50}
            if page_token:
                params["pageToken"] = page_token
            response = self._retry_after_unauthorized(
                "GET",
                f"{self.API_BASE_URL}/albums",
                headers=self._headers(),
                params=params,
            )
            if response.status_code == 403:
                raise GooglePhotosPermissionError(
                    "Google denied album lookup. Reconnect Google Photos to grant the "
                    "app-created album read permission. No album was created."
                )
            response.raise_for_status()
            data = response.json()
            albums.extend(data.get("albums", []))
            page_token = data.get("nextPageToken")
            if not page_token:
                return albums

    def find_album_by_title(self, album_title: str) -> str | None:
        matches = [album for album in self.list_albums() if album.get("title") == album_title]
        if not matches:
            return None
        if len(matches) > 1:
            self.logger.warning(
                "Found %d Google Photos albums named '%s'; reusing one and storing its ID.",
                len(matches),
                album_title,
            )
        album_ids = sorted(str(album["id"]) for album in matches if album.get("id"))
        return album_ids[0] if album_ids else None

    def get_or_create_album(self, album_title: str) -> str:
        album_id = self.find_album_by_title(album_title)
        if album_id:
            self.logger.info("Reusing Google Photos album: %s", album_title)
            return album_id
        return self.create_album(album_title)

    def upload_photo(self, file_path: str, description: str | None = None) -> str | None:
        if not os.path.exists(file_path):
            self.logger.error("File not found: %s", file_path)
            return None

        mime_type = mimetypes.guess_type(file_path)[0] or "application/octet-stream"
        try:
            with open(file_path, "rb") as file_obj:
                file_bytes = file_obj.read()
            headers = self._headers("application/octet-stream")
            headers.update(
                {
                    "X-Goog-Upload-Content-Type": mime_type,
                    "X-Goog-Upload-Protocol": "raw",
                }
            )
            response = self._retry_after_unauthorized(
                "POST", self.UPLOAD_URL, headers=headers, data=file_bytes
            )
            response.raise_for_status()
            self.logger.debug("Uploaded file bytes: %s", os.path.basename(file_path))
            return response.text
        except (OSError, requests.RequestException, GooglePhotosError) as error:
            self.logger.error("Failed to upload '%s': %s", file_path, error)
            return None

    def create_media_item(
        self,
        upload_token: str,
        filename: str,
        description: str | None = None,
        album_id: str | None = None,
    ) -> bool:
        item: dict[str, Any] = {
            "simpleMediaItem": {"uploadToken": upload_token, "fileName": filename}
        }
        if description:
            item["description"] = description
        data: dict[str, Any] = {"newMediaItems": [item]}
        if album_id:
            data["albumId"] = album_id

        try:
            response = self._retry_after_unauthorized(
                "POST",
                f"{self.API_BASE_URL}/mediaItems:batchCreate",
                headers=self._headers(),
                json=data,
            )
            response.raise_for_status()
            results = response.json().get("newMediaItemResults", [])
            if not results:
                return False
            status = results[0].get("status", {})
            if status.get("code") or status.get("message") not in (None, "", "Success"):
                self.logger.error(
                    "Failed to create media item '%s': %s",
                    filename,
                    status.get("message", "unknown Google Photos error"),
                )
                return False
            return True
        except (requests.RequestException, GooglePhotosError) as error:
            self.logger.error("Failed to create media item '%s': %s", filename, error)
            return False

    def upload_and_create(
        self,
        file_path: str,
        album_id: str | None = None,
        description: str | None = None,
    ) -> bool:
        upload_token = self.upload_photo(file_path, description)
        if not upload_token:
            return False
        return self.create_media_item(
            upload_token, os.path.basename(file_path), description, album_id
        )


class _ProgressReader(io.BufferedReader):
    def __init__(self, path: str, progress: Callable[[int], None]):
        super().__init__(io.FileIO(path, "r"))
        self.progress = progress

    def read(self, size: int | None = -1) -> bytes:
        data = super().read(size)
        self.progress(self.tell())
        return data
