#!/bin/sh
# Runs once, on first start with an empty data volume (postgres image convention).
#
# Two roles per application database (least privilege):
#   ecommerce_owner  owns the database and schema; used only by the migration job.
#   ecommerce_app    used by the running API; gets row-level grants from migrations
#                    (003_app_grants.sql), so it cannot create, alter or drop tables.
#
# Passwords are passed as psql variables (:'pw'), so psql quotes them, not the shell.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v owner_pw="$ECOMMERCE_OWNER_PASSWORD" -v app_pw="$ECOMMERCE_APP_PASSWORD" <<'SQL'
-- By default every role may connect to these; only superusers need them.
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;

CREATE ROLE ecommerce_owner LOGIN PASSWORD :'owner_pw';
CREATE ROLE ecommerce_app LOGIN PASSWORD :'app_pw';

CREATE DATABASE ecommerce OWNER ecommerce_owner;
REVOKE ALL ON DATABASE ecommerce FROM PUBLIC;
GRANT CONNECT ON DATABASE ecommerce TO ecommerce_app;

\connect ecommerce
-- Postgres 15+ already denies CREATE on schema public to PUBLIC; make the owner
-- explicit and let the app role look up objects in the schema.
ALTER SCHEMA public OWNER TO ecommerce_owner;
GRANT USAGE ON SCHEMA public TO ecommerce_app;
SQL
