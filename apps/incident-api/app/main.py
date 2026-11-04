"""Incident API: Alertmanager webhook -> deduplicated alerts -> correlated incidents.

Writes (webhook, acknowledge, resolve, notes) need `Authorization: Bearer $INCIDENT_API_TOKEN`.
Reads are open: the port is bound to 127.0.0.1 locally.
ponytail: one shared token, and `actor` is whoever the caller says they are. Per-user
auth (SSO in front, or per-user tokens) before anyone outside the team can reach it.
"""
import hmac
import json
import logging
import os
import threading
import time
import urllib.request
from contextlib import asynccontextmanager
from typing import Literal

import psycopg
from fastapi import FastAPI, HTTPException, Path, Query, Request
from fastapi.responses import JSONResponse, PlainTextResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, REGISTRY, Counter, Gauge, Histogram, generate_latest
from prometheus_client.core import GaugeMetricFamily
from pydantic import AwareDatetime, BaseModel, Field

from . import db, report, spool

log = logging.getLogger("incident-api")
TOKEN = os.environ.get("INCIDENT_API_TOKEN", "")
if len(TOKEN) < 32:
    raise SystemExit("INCIDENT_API_TOKEN must be set (at least 32 characters: openssl rand -hex 24)")

# --- Reconciliation with Alertmanager (see db.reconcile) -------------------------------

ALERTMANAGER_ALERTS = "http://alertmanager:9093/api/v2/alerts"   # active, silenced and inhibited
RECONCILE_EVERY = 15        # seconds
# Longer than any group_interval (5m), so a real resolved notification always wins and
# keeps the true end time; longer than Prometheus' re-send after an Alertmanager restart (1m).
RESOLVE_AFTER = 600


def reconcile_forever():
    last_error = None
    while True:
        time.sleep(RECONCILE_EVERY)
        try:
            spool.drain(_record_payload)   # webhooks accepted while incident-db was down
            with urllib.request.urlopen(ALERTMANAGER_ALERTS, timeout=5) as response:
                active = {a["fingerprint"] for a in json.load(response)}
            resolved = db.reconcile(active, RESOLVE_AFTER)
        except Exception as err:   # an uncaught error would end the thread silently
            # Alertmanager or incident-db unreachable: decide nothing, try again later.
            # Logged once per kind of failure, not every 15 seconds.
            if type(err).__name__ != last_error:
                log.warning("reconciliation skipped", extra={"fields": {"error": type(err).__name__, "detail": str(err)}})
            last_error = type(err).__name__
            continue
        if last_error:
            log.info("reconciliation working again")
            last_error = None
        if resolved:
            log.warning("resolved alerts gone from Alertmanager", extra={"fields": {"alerts": resolved}})


@asynccontextmanager
async def lifespan(app):
    threading.Thread(target=reconcile_forever, name="reconcile", daemon=True).start()
    yield


app = FastAPI(title="COP incident API", docs_url="/docs", redoc_url=None, lifespan=lifespan)


# --- Metrics (same HTTP metric names as ecommerce-api, so the alert and SLO rules cover it) ---

REQUESTS = Counter("http_requests_total", "HTTP requests", ["method", "route", "status_code"])
DURATION = Histogram("http_request_duration_seconds", "HTTP request duration", ["method", "route", "status_code"],
                     buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5))
WEBHOOK_ALERTS = Counter("incident_webhook_alerts_total", "Alerts received through the webhook", ["outcome"])
Gauge("incident_spool_pending", "Webhooks spooled during an incident-db outage, not yet recorded").set_function(
    lambda: len(spool.pending()))
METHODS = {"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"}
# Polled every few seconds by probes and Prometheus. Counting them would make probe
# traffic the SLO: a few minutes of incident-db outage (/health 503) paged as a critical
# error-budget burn (seen). Same rule as ecommerce-api.
QUIET_ROUTES = {"/health", "/metrics"}


class OpenIncidents:
    """incidents_open{environment, severity}, read from the database at scrape time."""
    def describe(self):   # lets register() skip a collect(), i.e. a DB query at import
        return [GaugeMetricFamily("incidents_open", "Unresolved incidents")]

    def collect(self):
        try:
            rows = db.open_counts()
        except psycopg.Error:
            return   # absent while incident-db is down; /health (EndpointDown) reports that
        gauge = GaugeMetricFamily("incidents_open", "Unresolved incidents", labels=["environment", "severity"])
        for r in rows:
            gauge.add_metric([r["environment"], r["severity"]], r["n"])
        yield gauge


REGISTRY.register(OpenIncidents())


def token_ok(authorization):
    return hmac.compare_digest(authorization.encode(), f"Bearer {TOKEN}".encode())


# Every write needs the token, checked before the body is read: as a route dependency it
# ran after FastAPI had parsed the body (an unauthenticated bad body got 422, not 401).
# Registered before `observe`, so it runs inside it and 401s are still counted.
@app.middleware("http")
async def require_token_for_writes(request: Request, call_next):
    if request.method not in ("GET", "HEAD", "OPTIONS") and not token_ok(request.headers.get("authorization", "")):
        return JSONResponse({"detail": "missing or wrong bearer token"}, status_code=401,
                            headers={"WWW-Authenticate": "Bearer"})
    return await call_next(request)


@app.middleware("http")
async def observe(request: Request, call_next):
    start, status = time.perf_counter(), 500
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        route = request.scope.get("route")   # the path template, never the raw path (ids)
        path = route.path if route else "unmatched"
        if path not in QUIET_ROUTES:
            labels = (request.method if request.method in METHODS else "other", path, str(status))
            REQUESTS.labels(*labels).inc()
            DURATION.labels(*labels).observe(time.perf_counter() - start)


@app.exception_handler(psycopg.OperationalError)
async def database_unavailable(request, exc):
    # Nothing is half-written (one transaction). Webhooks don't get here: they're spooled.
    log.error("incident database unavailable", extra={"fields": {"error": type(exc).__name__, "detail": str(exc)}})
    return JSONResponse({"detail": "incident database unavailable"}, status_code=503)


# --- Alertmanager webhook ------------------------------------------------------------

class Alert(BaseModel):
    status: Literal["firing", "resolved"]
    labels: dict[str, str]
    annotations: dict[str, str] = {}
    startsAt: AwareDatetime
    endsAt: AwareDatetime | None = None
    fingerprint: str = Field(min_length=1, max_length=64)


class Notification(BaseModel):
    """Alertmanager webhook payload (version 4). Fields not listed are ignored.
    No cap on the number of alerts: a 4xx is never retried, so it would drop the group."""
    alerts: list[Alert]


def _record(notification):
    # An alert without a name can't be correlated; skip it rather than reject the whole
    # notification (Alertmanager doesn't retry 4xx, so its group would be lost for good).
    alerts = [a for a in notification.alerts if a.labels.get("alertname")]
    outcomes = db.ingest(alerts) | {"skipped": len(notification.alerts) - len(alerts)}
    for outcome, n in outcomes.items():
        WEBHOOK_ALERTS.labels(outcome).inc(n)
    log.info("webhook processed", extra={"fields": outcomes})
    return outcomes


def _record_payload(payload):
    return _record(Notification.model_validate(payload))


@app.post("/alertmanager")
def webhook(notification: Notification):
    try:
        spool.drain(_record_payload)   # older spooled notifications first, to keep the order
        return _record(notification)
    except psycopg.OperationalError as err:
        try:
            spool.save(notification.model_dump(mode="json"))
        except OSError:
            raise err from None   # can't spool either: 503, Alertmanager retries
        log.warning("incident database unavailable, webhook spooled",
                    extra={"fields": {"error": type(err).__name__, "alerts": len(notification.alerts),
                                      "environments": sorted({a.labels.get("environment", "unknown")
                                                              for a in notification.alerts})}})
        return {"spooled": len(notification.alerts)}


# --- Incidents -----------------------------------------------------------------------

IncidentId = Path(ge=1, le=2**63 - 1)


class Action(BaseModel):
    actor: str = Field(min_length=1, max_length=100)
    note: str | None = Field(default=None, max_length=2000)


class Note(BaseModel):
    actor: str = Field(min_length=1, max_length=100)
    text: str = Field(min_length=1, max_length=2000)


@app.get("/incidents")
def list_incidents(status: Literal["open", "acknowledged", "resolved"] | None = None,
                   environment: str | None = None, limit: int = Query(50, ge=1, le=500)):
    return db.list_incidents(status, environment, limit)


def _incident(incident_id):
    incident = db.get_incident(incident_id)
    if not incident:
        raise HTTPException(404, "no such incident")
    return incident


@app.get("/incidents/{incident_id}")
def get_incident(incident_id: int = IncidentId):
    return _incident(incident_id)


@app.get("/incidents/{incident_id}/report", response_class=PlainTextResponse)
def incident_report(incident_id: int = IncidentId):
    return PlainTextResponse(report.markdown(_incident(incident_id)), media_type="text/markdown; charset=utf-8")


def _transition(incident_id, to, action):
    changed, status = db.transition(incident_id, to, action.actor, action.note)
    if status is None:
        raise HTTPException(404, "no such incident")
    if not changed:
        raise HTTPException(409, f"incident is {status}")
    log.info(f"incident {to}", extra={"fields": {"incident_id": incident_id, "actor": action.actor}})
    return {"id": incident_id, "status": status}


@app.post("/incidents/{incident_id}/acknowledge")
def acknowledge(action: Action, incident_id: int = IncidentId):
    return _transition(incident_id, "acknowledged", action)


@app.post("/incidents/{incident_id}/resolve")
def resolve(action: Action, incident_id: int = IncidentId):
    return _transition(incident_id, "resolved", action)


@app.post("/incidents/{incident_id}/notes", status_code=201)
def add_note(note: Note, incident_id: int = IncidentId):
    if not db.add_note(incident_id, note.actor, note.text):
        raise HTTPException(404, "no such incident")
    return {"id": incident_id}


@app.get("/reports/summary")
def summary(days: int = Query(30, ge=1, le=365), environment: str | None = None):
    return db.summary(days, environment)


# --- Operations ----------------------------------------------------------------------

@app.get("/health")
def health():
    db.check()   # OperationalError -> 503 via the handler above
    return {"status": "ok"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(REGISTRY), media_type=CONTENT_TYPE_LATEST)
