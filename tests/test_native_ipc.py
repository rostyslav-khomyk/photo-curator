import io
import json
import logging

from flask import Flask, jsonify

from icloudpd.native_ipc import PREFIX, serve_native_pipe
from icloudpd.server import serve_app
from icloudpd.status import StatusExchange


def test_pipe_allows_api_but_never_pages():
    app = Flask(__name__)
    app.add_url_rule('/control-state', view_func=lambda: jsonify(running=False))
    app.add_url_rule('/', endpoint='legacy', view_func=lambda: 'legacy page')
    output = io.StringIO()
    source = io.StringIO('\n'.join(json.dumps({'id': str(i), 'path': p})
                                  for i, p in enumerate(['/control-state', '/', '/static/foo', '/start'])))
    serve_native_pipe(app, source, output)
    replies = [json.loads(line[len(PREFIX):]) for line in output.getvalue().splitlines()]
    assert [r['status'] for r in replies] == [200, 404, 404, 404]


def test_native_mode_does_not_listen(monkeypatch):
    monkeypatch.setenv('PHOTO_CURATOR_NATIVE_PIPE', '1')
    monkeypatch.delenv('ICLOUDPD_PARENT_PID', raising=False)
    output = io.StringIO()
    monkeypatch.setattr('sys.stdin', io.StringIO('{"id":"a","path":"/auth-state"}\n'))
    monkeypatch.setattr('sys.stdout', output)
    monkeypatch.setattr('icloudpd.server.waitress.serve', lambda *a, **k: (_ for _ in ()).throw(AssertionError('No HTTP listener')))
    serve_app(logging.getLogger('test'), StatusExchange())
    assert json.loads(output.getvalue().split(PREFIX)[1])['status'] == 200


def test_bad_request_does_not_echo_secret():
    output = io.StringIO()
    serve_native_pipe(Flask(__name__), io.StringIO('{"secret":"not-for-logs"}\n'), output)
    assert 'not-for-logs' not in output.getvalue()
    assert '400' in output.getvalue()


def test_native_pipe_returns_structured_transport_errors():
    output = io.StringIO()
    serve_native_pipe(Flask(__name__), io.StringIO('{"id":"request-without-path"}\n'), output)
    reply = json.loads(output.getvalue().split(PREFIX)[1])
    assert reply['status'] == 400
    assert json.loads(reply['body'])['error'] == 'Invalid local sync request.'


def test_native_pipe_allows_clear_google_album():
    app = Flask(__name__)
    app.add_url_rule(
        '/clear-google-album',
        view_func=lambda: jsonify(removed=2),
        methods=['POST'],
    )
    output = io.StringIO()
    request = json.dumps({
        'id': 'clear',
        'path': '/clear-google-album',
        'method': 'POST',
        'body': '{}',
    })
    serve_native_pipe(app, io.StringIO(request + '\n'), output)
    reply = json.loads(output.getvalue().split(PREFIX)[1])
    assert reply['status'] == 200
