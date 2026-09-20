"""Private native-app pipe transport. No listening socket or web pages."""
import json
import sys

NATIVE_ROUTES = frozenset({"/auth-state", "/google-access", "/frame-albums",
    "/prepare-frame-sync", "/start-frame-sync", "/abort-frame-sync", "/control-state",
    "/clear-google-album"})
PREFIX = "PHOTO_CURATOR_RPC "

def serve_native_pipe(app, input_stream=None, output_stream=None):
    source = input_stream or sys.stdin
    destination = output_stream or sys.stdout
    client = app.test_client()
    for line in source:
        identifier = None
        try:
            if len(line) > 16 * 1024 * 1024:
                raise ValueError("Request too large")
            message = json.loads(line)
            identifier = message["id"]
            if message["path"] not in NATIVE_ROUTES:
                result = {"id": identifier, "status": 404, "body": "{}"}
            else:
                response = client.open(message["path"], method=message.get("method", "GET"),
                    data=message.get("body", ""), headers=message.get("headers", {}))
                result = {"id": identifier, "status": response.status_code,
                          "body": response.get_data(as_text=True)}
        except KeyError:
            result = {
                "id": identifier,
                "status": 400,
                "body": json.dumps({"error": "Invalid local sync request."}),
            }
        except ValueError as error:
            result = {
                "id": identifier,
                "status": 413 if str(error) == "Request too large" else 400,
                "body": json.dumps({"error": str(error)}),
            }
        except Exception:
            # Keep private exception details out of IPC, but preserve a useful failure.
            result = {
                "id": identifier,
                "status": 500,
                "body": json.dumps({"error": "The local sync transport failed. Please try again."}),
            }
        destination.write(PREFIX + json.dumps(result) + "\n")
        destination.flush()
