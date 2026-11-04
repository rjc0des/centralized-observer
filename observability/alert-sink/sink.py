"""Local stand-in for Slack: logs each POST as one JSON line.

Unless SLACK_WEBHOOK_URL is set, Alertmanager's Slack messages (/slack) arrive here.
(Its webhook goes to the incident API.) Payloads are alert notifications (labels,
annotations, summaries), never customer data. Nothing is stored: stdout, and
therefore Loki, is the record.

ponytail: stdlib only. Threaded, so one stalled client can't hold up Alertmanager
(it did when single-threaded).
"""
import json
import os
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def log(level, msg, **fields):
    line = {"time": datetime.now(timezone.utc).isoformat(timespec="milliseconds"), "level": level,
            "service": "alert-sink", "environment": os.environ.get("ENVIRONMENT", "local"), "msg": msg}
    print(json.dumps(line | fields), flush=True)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # healthcheck
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try:
            payload = json.loads(body)
        except ValueError:
            log("warn", "notification is not JSON", path=self.path, size=len(body))
            self.send_response(400)
        else:
            log("info", "notification received", path=self.path, payload=payload)
            self.send_response(200)
        self.end_headers()
        # Slack webhooks answer "ok"; Alertmanager treats any other body as a failed send
        # (and then skips the resolved message, since the firing one never "went out").
        self.wfile.write(b"ok")

    def log_message(self, *args):  # the JSON line above replaces the default access log
        pass


if __name__ == "__main__":
    log("info", "listening on :8080")
    ThreadingHTTPServer(("", 8080), Handler).serve_forever()
