# syntax=docker/dockerfile:1
#
# One image for `web`, `worker`, `migrate` and the content import: compose overrides CMD per service.
# Build context is the repository root: infra/deploy.sh runs
#   docker build -f <worktree>/infra/Dockerfile <worktree>
# on a temporary git worktree of the release commit. Compose does not build images.
#
# Claude: before relying on this file verify against current docs
#   - Next.js "output: standalone" layout (server.js location, what must be copied by hand)
#   - Node 22 alpine image tag
# and keep `next.config.ts` in sync (output: "standalone").
#
# Packaging contract (one rule for every process in the image):
#   - Next.js web: `.next/standalone` (server.js), `.next/static`, `public`. Standalone tracing copies
#     only the packages the Next server itself imports.
#   - worker, migrate, import: esbuild bundles of our own code; npm packages stay external
#     (`--packages=external`) and come from a full production install (`npm ci --omit=dev`, stage
#     deps-prod), copied whole into the runner. So a package used only by the worker or the importer
#     (pg-boss, js-yaml, ...) is in the image because it is in "dependencies" of package.json, not because
#     Next happened to trace it. A package the server bundles import must be in "dependencies", not
#     "devDependencies".
#   - infra/check-runtime.mjs runs at the end of the runner stage: the four entry points exist and every
#     package they import is installed. A broken contract fails the image build in infra/deploy.sh,
#     before migrations and before anything is restarted.
#
# Expected package.json script (created by the start-project skill, see docs/09 section 6):
#   build:server  esbuild worker/index=src/worker/index.ts db/migrate=src/db/migrate.ts
#                 scripts/import-content=scripts/import-content.ts scripts/admin=scripts/admin.ts
#                 --bundle --platform=node --format=esm
#                 --target=node22 --packages=external --outdir=dist
#                 named entry points ("out=in") give exactly the paths compose calls:
#                   dist/worker/index.js, dist/db/migrate.js, dist/scripts/import-content.js

ARG NODE_VERSION=22

# ---------- deps: full install for the build, cached on package files only ----------
FROM node:${NODE_VERSION}-alpine AS deps
WORKDIR /app
RUN apk add --no-cache libc6-compat
COPY package.json package-lock.json ./
RUN npm ci

# ---------- deps-prod: production dependencies of all processes ----------
FROM node:${NODE_VERSION}-alpine AS deps-prod
WORKDIR /app
RUN apk add --no-cache libc6-compat
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# ---------- build: Next standalone + server bundles ----------
FROM deps AS build
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
COPY . .
RUN npm run build
# Required: compose starts dist/worker/index.js and dist/db/migrate.js, docs/09 runs dist/scripts/import-content.js.
RUN npm run build:server \
 && test -f dist/worker/index.js \
 && test -f dist/db/migrate.js \
 && test -f dist/scripts/import-content.js \
 && test -f dist/scripts/admin.js

# COPY below fails on a missing source; make sure the directories exist even before the first file lands there.
RUN mkdir -p drizzle content public

# ---------- runner: small, non-root ----------
FROM node:${NODE_VERSION}-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0
# tini reaps zombies and forwards signals so `docker stop` is fast
RUN apk add --no-cache tini \
 && addgroup -S app -g 1001 && adduser -S app -u 1001 -G app \
 && mkdir -p /data/media && chown app:app /data/media

# Production node_modules first, then the Next standalone output on top of it. The standalone
# node_modules holds traced copies of the same versions (same package-lock.json), so the overlay
# changes nothing in them and adds server.js and .next/server.
COPY --from=deps-prod --chown=app:app /app/node_modules ./node_modules
COPY --from=build --chown=app:app /app/.next/standalone ./
COPY --from=build --chown=app:app /app/.next/static ./.next/static
COPY --from=build --chown=app:app /app/public ./public
# Non-Next entry points, SQL migrations and file content (import runs inside the container)
COPY --from=build --chown=app:app /app/dist ./dist
COPY --from=build --chown=app:app /app/drizzle ./drizzle
COPY --from=build --chown=app:app /app/content ./content

# Check the finished layout without starting anything: importing a bundle would start the worker or
# run migrations, so the script reads the bundles as text (see the file header).
COPY infra/check-runtime.mjs /tmp/check-runtime.mjs
RUN node --check dist/worker/index.js \
 && node --check dist/db/migrate.js \
 && node --check dist/scripts/import-content.js \
 && node --check dist/scripts/admin.js \
 && node /tmp/check-runtime.mjs \
 && rm /tmp/check-runtime.mjs

USER app
EXPOSE 3000
ENTRYPOINT ["/sbin/tini", "--"]
# web by default; compose overrides it: worker ["node", "dist/worker/index.js"], migrate ["node", "dist/db/migrate.js"]
CMD ["node", "server.js"]
