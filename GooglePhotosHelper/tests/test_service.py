import io
import json

from photo_curator_google.service import PREFIX, Service, serve
from photo_curator_google.oauth import GoogleOAuthServer


def request(service, path, body=None, *, csrf=True):
    message = {"path": path, "method": "POST" if body is not None else "GET"}
    if body is not None:
        message["body"] = json.dumps(body)
        message["headers"] = {"X-CSRF-Token": service.csrf} if csrf else {}
    return service.dispatch(message)


def test_pipe_exposes_only_native_google_routes():
    service = Service()
    assert request(service, "/auth-state")[0] == 200
    assert request(service, "/")[0] == 404
    assert request(service, "/static/app.js")[0] == 404


def test_post_requires_current_csrf_token():
    service = Service()
    assert request(service, "/start-frame-sync", {"token": "bad", "mode": "append"}, csrf=False)[0] == 403
    assert request(service, "/start-frame-sync", {"token": "bad", "mode": "append"})[0] == 409


def test_csrf_header_is_case_insensitive():
    service = Service()
    status, _ = service.dispatch({
        "path": "/start-frame-sync",
        "method": "POST",
        "headers": {"X-Csrf-Token": service.csrf},
        "body": json.dumps({"token": "bad", "mode": "append"}),
    })
    assert status == 409


def test_bad_request_does_not_echo_secret():
    output = io.StringIO()
    serve(io.StringIO('{"secret":"not-for-logs"}\n'), output)
    assert "not-for-logs" not in output.getvalue()
    reply = json.loads(output.getvalue().split(PREFIX)[1])
    assert reply["status"] == 400


def test_oauth_callback_rejects_wrong_state_and_accepts_code():
    server = GoogleOAuthServer()
    assert server._handle_callback({"state": ["wrong"]})[1] == 400
    server = GoogleOAuthServer()
    assert server._handle_callback({"state": [server.state], "code": ["code"]})[1] == 200
    assert server.auth_code == "code"
