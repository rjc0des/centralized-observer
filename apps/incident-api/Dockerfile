# syntax=docker/dockerfile:1
# checkov:skip=CKV_DOCKER_7:The base image is an ARG pinned to tag + digest (checkov sees only the variable).
# checkov:skip=CKV_DOCKER_2:Healthchecks are defined in docker-compose.yml, where the probe and timing live.
ARG PYTHON_IMAGE=python:3.14.9-alpine3.24@sha256:dbeb11d16bb95c3a7e3c25c842cb9f20cbc8c18f8be0461a4a0dcc861ad386a0

# Dependencies exactly as locked: every file's hash is checked, wheels only (no build step
# runs third-party code). Regenerate requirements.txt with:
#   uv pip compile requirements.in --generate-hashes --python-version 3.14 \
#     --python-platform aarch64-unknown-linux-musl --no-header -o requirements.txt
FROM ${PYTHON_IMAGE} AS deps
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir --require-hashes --only-binary :all: --target /app/deps -r requirements.txt

# `docker build --target test .` runs the unit tests (used by make unit and CI).
FROM deps AS test
ENV PYTHONPATH=/app/deps
COPY app ./app
COPY tests ./tests
RUN python -m unittest discover -s tests -v

FROM ${PYTHON_IMAGE} AS runtime
# pip is not needed at runtime.
RUN python -m pip uninstall -y -q pip
ENV PYTHONPATH=/app/deps PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    PROMETHEUS_DISABLE_CREATED_SERIES=true
WORKDIR /app
COPY --from=deps /app/deps ./deps
COPY app ./app
COPY migrations ./migrations
# Files stay root-owned and read-only to the app user (nobody). /spool is the one
# writable path (a named volume; Docker copies this directory's owner into a new volume).
RUN mkdir /spool && chown 65534:65534 /spool
USER 65534:65534
EXPOSE 8000
CMD ["python", "-m", "app"]
