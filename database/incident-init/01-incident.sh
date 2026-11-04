#!/bin/sh
# Runs once, on first start with an empty incident-db-data volume (postgres image convention).
# Same pattern as database/init/01-ecommerce.sh:
#   incident_owner  owns the database and schema; used only by the incident-migrate job.
#   incident_app    used by the running incident API; row grants come from migrations.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v owner_pw="$INCIDENT_OWNER_PASSWORD" -v app_pw="$INCIDENT_APP_PASSWORD" <<'SQL'
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;

CREATE ROLE incident_owner LOGIN PASSWORD :'owner_pw';
CREATE ROLE incident_app LOGIN PASSWORD :'app_pw';

CREATE DATABASE incidents OWNER incident_owner;
REVOKE ALL ON DATABASE incidents FROM PUBLIC;
GRANT CONNECT ON DATABASE incidents TO incident_app;

\connect incidents
ALTER SCHEMA public OWNER TO incident_owner;
GRANT USAGE ON SCHEMA public TO incident_app;
SQL
