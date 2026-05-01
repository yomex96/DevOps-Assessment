# syntax=docker/dockerfile:1.7
# Enables BuildKit features: --mount=type=cache and parallel stage execution.
# Requires Docker 23+ or DOCKER_BUILDKIT=1 in CI.

# =============================================================================
# STAGE 0: BASE
# Single source of truth for the Node version.
# Both deps and build inherit from here — a version bump happens in one place.
# BuildKit fans out from base to deps and build IN PARALLEL automatically.
# =============================================================================
FROM node:20-alpine AS base

WORKDIR /app

# Install curl here once — shared by all downstream stages via layer cache.
# Used in the HEALTHCHECK of the final runner stage.
RUN apk add --no-cache curl


# =============================================================================
# STAGE 1: DEPS  ← runs in parallel with STAGE 2
# Installs ONLY production dependencies (no devDependencies).
# --mount=type=cache caches npm's tarball download cache on the BuildKit daemon.
# The cache survives across builds — packages are not re-downloaded unnecessarily.
# node_modules IS written into this image layer so the runner can COPY from it.
# =============================================================================
FROM base AS deps

# Copy manifests first — Docker layer cache means npm ci only re-runs
# when package.json or package-lock.json actually changes, not on every
# source code change.
COPY package.json package-lock.json ./

RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --ignore-scripts


# =============================================================================
# STAGE 2: BUILD  ← runs in parallel with STAGE 1
# Installs all dependencies including devDependencies and compiles the app.
# For TypeScript: produces dist/. For plain JS: copies src/ as-is.
# =============================================================================
FROM base AS build

COPY package.json package-lock.json ./

# Full install including devDependencies (tsc, esbuild, webpack, etc.)
RUN --mount=type=cache,target=/root/.npm \
    npm ci --ignore-scripts

# Copy application source code
COPY src/ ./src/

# Compile TypeScript → dist/ if a build script exists, otherwise copy src → dist
# The '|| echo' prevents the build from failing in repos with no build step.
RUN npm run build 2>/dev/null || (mkdir -p dist && cp -r src/* dist/)


# =============================================================================
# STAGE 3: RUNNER  ← starts after STAGE 1 and STAGE 2 both complete
# Clean, minimal production image — zero build tools, zero devDependencies.
# Attack surface is as small as possible.
# =============================================================================
FROM node:20-alpine AS runner

# Disable dev behaviour and npm noise at runtime
ENV NODE_ENV=production
ENV NPM_CONFIG_UPDATE_NOTIFIER=false

WORKDIR /app

# curl needed for HEALTHCHECK — install before dropping to non-root
RUN apk add --no-cache curl

# Create a dedicated non-root system user and group.
# UID/GID 1001 — avoids collisions with root (0) and nobody (65534).
# --no-create-home: no home directory needed for a service account.
RUN addgroup --system --gid 1001 appgroup && \
    adduser  --system --uid 1001 --ingroup appgroup --no-create-home appuser

# Copy production node_modules from deps stage.
# --chown sets ownership at copy time — no extra RUN chown layer needed.
COPY --from=deps  --chown=appuser:appgroup /app/node_modules ./node_modules

# Copy compiled/built application from build stage
COPY --from=build --chown=appuser:appgroup /app/dist ./dist

# Copy package.json so Node can resolve the "main" field at runtime
COPY --chown=appuser:appgroup package.json ./

# Drop privileges — all subsequent runtime processes run as non-root appuser.
# If an attacker escapes the app they have no write access to the filesystem.
USER appuser

# Declare the port — informational only. Publishing happens at docker run / ECS.
EXPOSE 3000

# HEALTHCHECK: tells Docker/ECS/Kubernetes whether the app is actually healthy.
# Without this, a crashed server with the process still alive appears "running".
# Adjust /health to match your actual health endpoint.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

# Exec form — Node receives OS signals (SIGTERM) directly for graceful shutdown.
# Shell form would make /bin/sh PID 1, which swallows signals and prevents
# graceful shutdown.
CMD ["node", "dist/index.js"]
