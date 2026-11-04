"""One-shot migration job (python -m app.migrate) run with the incident_owner role's
PG* credentials before the API starts. The API itself connects as incident_app, which
cannot change the schema.

ponytail: forward-only SQL files applied in name order, one transaction each, recorded
in schema_migrations (same scheme as ecommerce-api). Use a migration tool if
down-migrations are ever needed.
"""
import logging
import pathlib
import sys

import psycopg

from . import logs

MIGRATIONS = pathlib.Path(__file__).resolve().parent.parent / "migrations"
LOCK_ID = 727003   # serialises migrations if two jobs start at once
log = logging.getLogger("incident-migrate")


def migrate(conn):
    conn.autocommit = True
    conn.execute("SELECT pg_advisory_lock(%s)", (LOCK_ID,))   # released when the connection closes
    conn.execute("""CREATE TABLE IF NOT EXISTS schema_migrations (
        version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())""")
    applied = {version for (version,) in conn.execute("SELECT version FROM schema_migrations")}
    for path in sorted(MIGRATIONS.glob("*.sql")):
        if path.name not in applied:
            with conn.transaction():
                conn.execute(path.read_text())
                conn.execute("INSERT INTO schema_migrations (version) VALUES (%s)", (path.name,))
            log.info("migration applied", extra={"fields": {"migration": path.name}})


if __name__ == "__main__":
    logs.setup("incident-migrate")
    try:
        with psycopg.connect(connect_timeout=5) as conn:
            migrate(conn)
    except psycopg.Error as err:
        log.error("migration failed", extra={"fields": {"error": type(err).__name__, "detail": str(err)}})
        sys.exit(1)
    log.info("migrations complete")
