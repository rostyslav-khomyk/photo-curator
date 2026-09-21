import logging
from unittest import mock

import pytest
import requests

from photo_curator_google.frame_sync import SyncAborted
from photo_curator_google.client import GooglePhotosClient, GoogleRateLimited


def client_with_responses(*responses):
    client = GooglePhotosClient.__new__(GooglePhotosClient)
    client.logger = logging.getLogger("test")
    client.session = mock.Mock()
    client.session.request.side_effect = responses
    client.check_cancelled = mock.Mock()
    client._wait_rate_limit = mock.Mock()
    return client


def response(code, retry_after=None):
    result = mock.Mock(status_code=code)
    result.headers = {"Retry-After": retry_after} if retry_after else {}
    return result


def test_429_retries_the_same_create_request_after_at_least_thirty_seconds():
    client = client_with_responses(response(429), response(200))
    body = {"newMediaItems": [{"simpleMediaItem": {"uploadToken": "same-token"}}]}
    assert (
        client._retry_after_unauthorized(
            "POST", "https://example.test/create", json=body
        ).status_code
        == 200
    )
    assert client._wait_rate_limit.call_args.args[0] >= 30
    assert client.session.request.call_args_list[0] == client.session.request.call_args_list[1]


def test_retry_after_is_respected():
    client = client_with_responses(response(429, "100"), response(200))
    client._retry_after_unauthorized("POST", "https://example.test/create")
    assert client._wait_rate_limit.call_args.args[0] == 100


def test_persistent_quota_limit_is_bounded_and_is_not_uncertain():
    client = client_with_responses(*(response(429) for _ in range(4)))
    with pytest.raises(GoogleRateLimited, match="Try again later"):
        client._retry_after_unauthorized("POST", "https://example.test/create")
    assert client.session.request.call_count == 4
    waits = [call.args[0] for call in client._wait_rate_limit.call_args_list]
    assert len(waits) == 3
    assert waits == sorted(waits)


def test_long_server_delay_does_not_retry_early():
    client = client_with_responses(response(429, "86400"))
    with pytest.raises(GoogleRateLimited):
        client._retry_after_unauthorized("POST", "https://example.test/create")
    client._wait_rate_limit.assert_not_called()
    assert client.session.request.call_count == 1


def test_abort_during_backoff_prevents_next_request():
    client = client_with_responses(response(429), response(200))
    client._wait_rate_limit.side_effect = SyncAborted()
    with pytest.raises(SyncAborted):
        client._retry_after_unauthorized("POST", "https://example.test/create")
    assert client.session.request.call_count == 1


def test_unknown_post_failure_is_never_blindly_retried():
    client = client_with_responses(requests.Timeout("Response unknown"))
    with pytest.raises(requests.Timeout):
        client._retry_after_unauthorized("POST", "https://example.test/create")
    assert client.session.request.call_count == 1


def test_retry_after_http_date(monkeypatch):
    monkeypatch.setattr("photo_curator_google.client.time.time", lambda: 0)
    assert GooglePhotosClient._rate_limit_delay("Thu, 01 Jan 1970 00:02:00 GMT", 0) == 120


def test_wait_publishes_countdown_and_checks_abort(monkeypatch):
    client = GooglePhotosClient.__new__(GooglePhotosClient)
    clock = [0.0]
    client.check_cancelled = mock.Mock()
    client.on_rate_limit = mock.Mock()
    monkeypatch.setattr("photo_curator_google.client.time.monotonic", lambda: clock[0])
    monkeypatch.setattr(
        "photo_curator_google.client.time.sleep",
        lambda seconds: clock.__setitem__(0, clock[0] + seconds),
    )
    client._wait_rate_limit(2)
    assert [call.args[0] for call in client.on_rate_limit.call_args_list] == [2, 1, 0]
    assert client.check_cancelled.call_count > 2
