"""Webhooks accepted while incident-db is down, kept on disk and replayed oldest first.

Alertmanager sends a receiver the "resolved" notification only if that receiver got the
"firing" one. Answering 503 during an incident-db outage therefore lost every alert that
fired and cleared before the database came back (reproduced: email had both, the
incident API nothing). Accepting the webhook into this spool keeps them.
ponytail: no size cap (the volume's disk is the limit); add one if outages get long.
"""
import json
import threading
import time
import uuid
from pathlib import Path

DIR = Path("/spool")   # named volume, writable by the app user
_lock = threading.Lock()   # the request path and the background loop both drain


def save(payload):
    tmp = DIR / f".{uuid.uuid4().hex}.tmp"
    tmp.write_text(json.dumps(payload))
    tmp.replace(DIR / f"{time.time_ns():020d}-{uuid.uuid4().hex[:8]}.json")   # atomic


def pending():
    return sorted(DIR.glob("*.json"))


def drain(handle):
    """Pass each spooled payload to handle(), oldest first. A failure stops the drain and
    keeps that file and the newer ones for next time; recording is idempotent."""
    with _lock:
        for path in pending():
            handle(json.loads(path.read_text()))
            path.unlink()
