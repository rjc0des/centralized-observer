# syntax=docker/dockerfile:1
# checkov:skip=CKV_DOCKER_7:The base image is an ARG pinned to tag + digest (checkov sees only the variable).
# checkov:skip=CKV_DOCKER_2:Healthchecks are defined in docker-compose.yml, where the probe and timing live.
ARG NODE_IMAGE=node:24.22.2-alpine3.24@sha256:8a32c8cf649a49915a66e81e7a609223c708d0adabf288ee3f4077d765542f85

# Production dependencies only, installed exactly from the lockfile.
FROM ${NODE_IMAGE} AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

# `docker build --target test .` runs the unit tests (used by make and CI).
FROM deps AS test
COPY src ./src
COPY migrations ./migrations
COPY test ./test
RUN npm test

FROM ${NODE_IMAGE} AS runtime
ENV NODE_ENV=production
# Package managers (npm, npx, corepack, yarn) are not needed at runtime; removing
# them shrinks the attack surface and the image-scan findings.
RUN rm -rf /usr/local/lib/node_modules /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
           /usr/local/bin/yarn /usr/local/bin/yarnpkg /opt/yarn-*
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
COPY migrations ./migrations
# Files stay root-owned and read-only to the app user.
USER node
EXPOSE 3000
CMD ["node", "--require", "./src/tracing.js", "src/server.js"]
