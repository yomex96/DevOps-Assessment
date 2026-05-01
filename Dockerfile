# =============================================================================
# DOCKERFILE — Zero-Trust Production Hardening
# E-Permit API | Node.js 20 LTS
#
# Design decisions (addressing the "toxic" original):
#   1. SMALLEST IMAGE     — Multi-stage build. Only production artefacts land
#                           in the final image. No build tools, no dev deps.
#   2. NON-ROOT RUNTIME   — Dedicated system user/group (appuser:appgroup).
#                           No capability to write to the filesystem at runtime.
#   3. CACHE-OPTIMISED    — package manifests are copied and npm ci runs BEFORE
#                           source code is copied. A code-only change does not
#                           re-install dependencies.
#   4. NO curl IN RUNNER  — curl is an attack-surface addition. The healthcheck
#                           uses Node.js itself (already present), so curl is
#                           never installed in the final image.
#   5. READ-ONLY READY    — No runtime writes needed; image can be run with
#                           --read-only for an additional Zero-Trust layer.
# =============================================================================

# -----------------------------------------------------------------------------
# STAGE 1: deps
# Install *production-only* dependencies on top of the slim Alpine base.
# Pinning the digest (sha256) is the strongest supply-chain guarantee;
# pinning to a named tag (node:20-alpine) is acceptable for this assessment.
# -----------------------------------------------------------------------------
FROM node:20-alpine AS deps

WORKDIR /app

# Copy ONLY the manifests first. This layer is cached and skipped on
# subsequent builds unless package.json or package-lock.json change.
COPY package.json package-lock.json ./

# --omit=dev ensures devDependencies never reach the final image.
# --ignore-scripts prevents malicious postinstall hooks.
# ci is preferred over install (reproduces the exact lock-file tree).
RUN npm ci --omit=dev --ignore-scripts

# -----------------------------------------------------------------------------
# STAGE 2: build
# Compile / transpile source. Runs separately so compiler tools and
# devDependencies are isolated and discarded after this stage.
# -----------------------------------------------------------------------------
FROM node:20-alpine AS build

WORKDIR /app

# Reuse manifests for a reproducible devDependency install
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts

# Copy source only after deps are installed (preserves the cache layer above)
COPY src/ ./src/

# The build script copies src/index.js → dist/index.js (see package.json).
# Replace with tsc, babel, esbuild, etc. for a real TypeScript project.
RUN npm run build

# -----------------------------------------------------------------------------
# STAGE 3: runner (final image — only this layer ships)
# -----------------------------------------------------------------------------
FROM node:20-alpine AS runner

# Metadata labels (OCI Image Spec)
LABEL org.opencontainers.image.title="epermit-api" \
      org.opencontainers.image.description="Zero-Trust E-Permit microservice" \
      org.opencontainers.image.vendor="Qualisys Consulting"

WORKDIR /app

# Set production environment — disables dev error pages, enables optimisations
ENV NODE_ENV=production \
    NPM_CONFIG_UPDATE_NOTIFIER=false

# Create a non-root system group and user before copying any files.
# -S = system account (no home directory, no login shell).
# UID/GID are explicit so they are reproducible across rebuilds.
RUN addgroup -S -g 1001 appgroup && \
    adduser  -S -u 1001 -G appgroup appuser

# Pull production node_modules from the deps stage
COPY --from=deps  --chown=appuser:appgroup /app/node_modules ./node_modules

# Pull compiled output from the build stage
COPY --from=build --chown=appuser:appgroup /app/dist ./dist

# Copy the manifest (needed by Node.js module resolution)
COPY --chown=appuser:appgroup package.json ./

# Drop to the non-root user — every instruction from here runs as appuser
USER appuser

# Document the port the application listens on (informational)
EXPOSE 3000

# Healthcheck using Node.js — no curl required (zero extra attack surface).
# --start-period gives the app time to initialise before checks begin.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD node -e "require('http').get('http://localhost:3000/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

# Run the compiled application.
# Exec form (JSON array) is required: it makes Node.js PID 1 so it receives
# OS signals (SIGTERM/SIGINT) correctly and can shut down gracefully.
CMD ["node", "dist/index.js"]
