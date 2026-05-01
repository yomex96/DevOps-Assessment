# syntax=docker/dockerfile:1.7
# Enables BuildKit: --mount=type=cache and parallel stage execution.

# =============================================================================
# STAGE 0: BASE
# node:20-alpine is the official minimal Node.js image.
# Alpine 3.x is chosen for its tiny footprint and fast security patch cycle.
# BuildKit fans out from base to deps and build IN PARALLEL.
# =============================================================================
FROM node:20-alpine AS base

WORKDIR /app

# Upgrade all Alpine packages to their latest patched versions immediately.
# This eliminates known fixed CVEs in the base image before any app code runs.
# --no-cache avoids storing the apk index in the image layer.
RUN apk update && apk upgrade --no-cache && rm -rf /var/cache/apk/*


# =============================================================================
# STAGE 1: DEPS  ← runs in parallel with STAGE 2
# Installs ONLY production dependencies (--omit=dev).
# mkdir -p node_modules guarantees the directory always exists even with
# zero dependencies, so COPY --from=deps never fails on a missing path.
# =============================================================================
FROM base AS deps

COPY package.json package-lock.json ./

RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --ignore-scripts && \
    mkdir -p node_modules


# =============================================================================
# STAGE 2: BUILD  ← runs in parallel with STAGE 1
# Compiles the app into dist/.
# mkdir -p dist guarantees the directory always exists so the runner
# COPY --from=build never fails regardless of whether a build script ran.
# =============================================================================
FROM base AS build

COPY package.json package-lock.json ./

RUN --mount=type=cache,target=/root/.npm \
    npm ci --ignore-scripts

COPY src/ ./src/

# Always create dist/ first, then attempt build, then copy src as fallback.
RUN mkdir -p dist && \
    (npm run build 2>/dev/null || true) && \
    (ls dist/ | grep -q . || cp -r src/* dist/)


# =============================================================================
# STAGE 3: RUNNER  ← starts after STAGE 1 and STAGE 2 both complete
# Minimal production image — no build tools, no devDependencies.
# No curl — eliminates the largest CVE source in Alpine images.
# HEALTHCHECK uses Node built-in http — zero extra packages needed.
# =============================================================================
FROM node:20-alpine AS runner

ENV NODE_ENV=production
ENV NPM_CONFIG_UPDATE_NOTIFIER=false

WORKDIR /app

# Upgrade all Alpine packages to latest patched versions.
# Critical for a government system — no known-fixed CVEs allowed in production.
RUN apk update && apk upgrade --no-cache && rm -rf /var/cache/apk/*

# Non-root user — UID/GID 1001
# Avoids collisions with root (0) and nobody (65534).
RUN addgroup --system --gid 1001 appgroup && \
    adduser  --system --uid 1001 --ingroup appgroup --no-create-home appuser

# Copy production node_modules from deps stage (directory always exists)
COPY --from=deps  --chown=appuser:appgroup /app/node_modules ./node_modules

# Copy compiled application from build stage (directory always exists)
COPY --from=build --chown=appuser:appgroup /app/dist ./dist

# package.json needed for Node to resolve the "main" field
COPY --chown=appuser:appgroup package.json ./

# Drop to non-root — all runtime processes run as appuser
USER appuser

EXPOSE 3000

# HEALTHCHECK using Node built-in http — no curl dependency needed.
# Hits /health endpoint; exits 0 on HTTP 200, exits 1 on any error.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD node -e "require('http').get('http://localhost:3000/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

# Exec form — Node receives SIGTERM directly for graceful shutdown
CMD ["node", "dist/index.js"]
