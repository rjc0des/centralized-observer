"""All SQL. Connects as the incident_app role (row access only; see migrations/002).

ponytail: one short-lived connection per call. The service handles a few requests a
minute, and a fresh connection never goes stale across incident-db restarts. Add
psycopg_pool if traffic grows.
"""
from datetime import datetime, timezone

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from .correlation import SEVERITY_RANK, match

# Arbitrary constant for pg_advisory_xact_lock (see ingest).
WEBHOOK_LOCK = 727002


def connect():
    # libpq reads PGHOST, PGDATABASE, PGUSER and PGPASSWORD from the environment.
    # `with connect() as conn:` commits on success, rolls back on error, then closes.
    return psycopg.connect(connect_timeout=3, row_factory=dict_row,
                           options="-c TimeZone=UTC -c statement_timeout=5s")


def check():
    with connect() as conn:
        conn.execute("SELECT 1")


def _event(conn, incident_id, kind, detail, actor="alertmanager", at=None):
    conn.execute("INSERT INTO events (incident_id, at, kind, actor, detail) VALUES (%s, coalesce(%s, now()), %s, %s, %s)",
                 (incident_id, at, kind, actor, detail))


# --- Webhook ---------------------------------------------------------------------

def ingest(alerts):
    """Record one webhook's alerts in one transaction. Returns counts per outcome."""
    outcomes = {"new": 0, "duplicate": 0, "resolved": 0}
    with connect() as conn:
        # ponytail: one global lock serialises webhooks, so two concurrent notifications
        # can't each open an incident for related alerts. Alert volume is tiny; lock per
        # environment if it ever isn't.
        conn.execute("SELECT pg_advisory_xact_lock(%s)", (WEBHOOK_LOCK,))
        for alert in alerts:
            outcomes[_ingest(conn, alert)] += 1
    return outcomes


def _ingest(conn, a):
    # The exact firing, else a row of this fingerprint that is still firing: one alert
    # can't fire twice at once. After Prometheus and Alertmanager restart, a still-firing
    # alert comes back with a new startsAt; matching only (fingerprint, startsAt) recorded
    # its end as a second firing and left the first one open (seen).
    row = conn.execute("""SELECT id, incident_id, status FROM alerts
                          WHERE fingerprint = %(fp)s AND (starts_at = %(starts)s OR status = 'firing')
                          ORDER BY starts_at = %(starts)s DESC, id DESC LIMIT 1""",
                       {"fp": a.fingerprint, "starts": a.startsAt}).fetchone()
    if row and (a.status == "firing" or row["status"] == "resolved"):
        # Re-sent notification (repeat_interval, group change), or a late firing for an
        # alert already resolved: resolved is final.
        conn.execute("UPDATE alerts SET last_received_at = now() WHERE id = %s", (row["id"],))
        return "duplicate"
    if row:
        _resolve_alert(conn, row["id"], row["incident_id"], a.labels["alertname"], a.endsAt)
        return "resolved"

    labels, name = a.labels, a.labels["alertname"]
    env = labels.get("environment", "unknown")
    severity = labels.get("severity", "none")
    summary = a.annotations.get("summary") or name
    candidates = conn.execute("""
        SELECT i.id, json_agg(a.labels ORDER BY a.id) AS labels
        FROM incidents i JOIN alerts a ON a.incident_id = i.id
        WHERE i.environment = %s AND i.status <> 'resolved'
        GROUP BY i.id ORDER BY i.id""", (env,)).fetchall()
    incident_id, rule = match(labels, [(c["id"], c["labels"]) for c in candidates])
    if incident_id is None:
        incident_id = conn.execute(
            "INSERT INTO incidents (title, severity, environment, opened_at) VALUES (%s, %s, %s, %s) RETURNING id",
            (summary, severity, env, a.startsAt)).fetchone()["id"]

    alert_id = conn.execute("""
        INSERT INTO alerts (incident_id, fingerprint, starts_at, status, alertname, severity, labels, annotations)
        VALUES (%s, %s, %s, 'firing', %s, %s, %s, %s) RETURNING id""",
        (incident_id, a.fingerprint, a.startsAt, name, severity, Jsonb(labels), Jsonb(a.annotations))).fetchone()["id"]
    how = f"correlated by rule {rule}" if rule else "opened the incident"
    _event(conn, incident_id, "alert_firing", f"{name} ({severity}) firing: {summary} [{how}]", at=a.startsAt)

    current = conn.execute("SELECT severity FROM incidents WHERE id = %s", (incident_id,)).fetchone()["severity"]
    if SEVERITY_RANK.get(severity, 0) > SEVERITY_RANK.get(current, 0):
        conn.execute("UPDATE incidents SET severity = %s WHERE id = %s", (severity, incident_id))
        _event(conn, incident_id, "severity_raised", f"{current} -> {severity} ({name})", at=a.startsAt)

    if a.status == "resolved":
        # The firing notification never arrived (e.g. incident-db was down and
        # Alertmanager's retries gave out before it recovered). Record both ends.
        _resolve_alert(conn, alert_id, incident_id, name, a.endsAt)
    return "new"


def _resolve_alert(conn, alert_id, incident_id, alertname, ends, why=""):
    ends = ends or datetime.now(timezone.utc)
    conn.execute("UPDATE alerts SET status = 'resolved', ends_at = %s, last_received_at = now() WHERE id = %s",
                 (ends, alert_id))
    _event(conn, incident_id, "alert_resolved", f"{alertname} resolved{why}", at=ends)
    # Auto-resolve once none of the incident's alerts is firing, at the latest end:
    # notifications can arrive out of order (critical groups within 1m, warnings within 5m).
    done = conn.execute("""
        UPDATE incidents SET status = 'resolved',
               resolved_at = (SELECT max(ends_at) FROM alerts WHERE incident_id = %(id)s)
        WHERE id = %(id)s AND status <> 'resolved'
          AND NOT EXISTS (SELECT 1 FROM alerts WHERE incident_id = %(id)s AND status = 'firing')
        RETURNING resolved_at""", {"id": incident_id}).fetchone()
    if done:
        _event(conn, incident_id, "resolved", "all alerts resolved", at=done["resolved_at"])


def reconcile(active_fingerprints, after_seconds):
    """Resolve firing alerts that Alertmanager hasn't had for `after_seconds`.

    Alertmanager keeps alerts in memory only. If it restarts while an alert fires and the
    alert clears before Prometheus re-sends it, no resolved notification ever comes and
    the incident would stay open forever (seen after `make down && make up`).
    Returns the names of the alerts resolved here.
    """
    active = list(active_fingerprints)
    with connect() as conn:
        conn.execute("SELECT pg_advisory_xact_lock(%s)", (WEBHOOK_LOCK,))
        conn.execute("UPDATE alerts SET missing_since = NULL WHERE status = 'firing' AND fingerprint = ANY(%s)",
                     (active,))
        conn.execute("UPDATE alerts SET missing_since = now() "
                     "WHERE status = 'firing' AND missing_since IS NULL AND NOT fingerprint = ANY(%s)", (active,))
        stale = conn.execute("SELECT id, incident_id, alertname FROM alerts "
                             "WHERE status = 'firing' AND missing_since < now() - make_interval(secs => %s)",
                             (after_seconds,)).fetchall()
        for a in stale:
            _resolve_alert(conn, a["id"], a["incident_id"], a["alertname"], None,
                           " (gone from Alertmanager; its resolved notification never arrived)")
        return [a["alertname"] for a in stale]


# --- Lifecycle: open -> acknowledged -> resolved (open -> resolved also allowed) -----

FROM_STATES = {"acknowledged": ["open"], "resolved": ["open", "acknowledged"]}


def transition(incident_id, to, actor, note=None):
    """Returns (changed, status): status is the incident's status now, None if it doesn't exist."""
    column = {"acknowledged": "acknowledged_at", "resolved": "resolved_at"}[to]
    with connect() as conn:
        # Same lock as the webhook: otherwise a resolve could commit between a webhook
        # choosing this (open) incident and inserting its alert into it (reproduced).
        conn.execute("SELECT pg_advisory_xact_lock(%s)", (WEBHOOK_LOCK,))
        changed = conn.execute(f"UPDATE incidents SET status = %s, {column} = now() "
                               "WHERE id = %s AND status = ANY(%s) RETURNING id",
                               (to, incident_id, FROM_STATES[to])).fetchone()
        if changed:
            _event(conn, incident_id, to, note or f"{to} manually", actor=actor)
            return True, to
        row = conn.execute("SELECT status FROM incidents WHERE id = %s", (incident_id,)).fetchone()
        return False, row and row["status"]


def add_note(incident_id, actor, text):
    """False if the incident doesn't exist."""
    with connect() as conn:
        if not conn.execute("SELECT 1 FROM incidents WHERE id = %s", (incident_id,)).fetchone():
            return False
        _event(conn, incident_id, "note", text, actor=actor)
        return True


# --- Reads ---------------------------------------------------------------------------

def list_incidents(status, environment, limit):
    with connect() as conn:
        return conn.execute("""
            SELECT i.*, array_agg(DISTINCT a.alertname ORDER BY a.alertname) AS alertnames
            FROM incidents i JOIN alerts a ON a.incident_id = i.id
            WHERE (%(status)s::text IS NULL OR i.status = %(status)s)
              AND (%(env)s::text IS NULL OR i.environment = %(env)s)
            GROUP BY i.id ORDER BY i.id DESC LIMIT %(limit)s""",
            {"status": status, "env": environment, "limit": limit}).fetchall()


def get_incident(incident_id):
    with connect() as conn:
        incident = conn.execute("SELECT * FROM incidents WHERE id = %s", (incident_id,)).fetchone()
        if incident:
            incident["alerts"] = conn.execute("""
                SELECT alertname, severity, status, starts_at, ends_at, fingerprint, labels, annotations
                FROM alerts WHERE incident_id = %s ORDER BY starts_at, id""", (incident_id,)).fetchall()
            incident["events"] = conn.execute(
                "SELECT at, kind, actor, detail FROM events WHERE incident_id = %s ORDER BY at, id",
                (incident_id,)).fetchall()
        return incident


def summary(days, environment):
    """Counts and mean times to acknowledge / resolve for incidents opened in the window."""
    params = {"days": days, "env": environment}
    where = "opened_at >= now() - make_interval(days => %(days)s) AND (%(env)s::text IS NULL OR environment = %(env)s)"
    with connect() as conn:
        result = conn.execute(f"""
            SELECT count(*) AS incidents,
                   count(*) FILTER (WHERE status <> 'resolved') AS unresolved,
                   round(avg(extract(epoch FROM acknowledged_at - opened_at))) AS mean_time_to_acknowledge_seconds,
                   round(avg(extract(epoch FROM resolved_at - opened_at))) AS mean_time_to_resolve_seconds
            FROM incidents WHERE {where}""", params).fetchone()
        result["by_severity"] = {r["severity"]: r["n"] for r in conn.execute(
            f"SELECT severity, count(*) AS n FROM incidents WHERE {where} GROUP BY severity", params)}
        return {"days": days, "environment": environment, **result}


def open_counts():
    # severity comes from alert labels (free text): only known values become label values.
    with connect() as conn:
        return conn.execute("""
            SELECT environment, CASE WHEN severity = ANY(%s) THEN severity ELSE 'other' END AS severity,
                   count(*) AS n
            FROM incidents WHERE status <> 'resolved' GROUP BY 1, 2""", (list(SEVERITY_RANK),)).fetchall()
