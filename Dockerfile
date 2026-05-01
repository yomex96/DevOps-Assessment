# STAGE 0: BASE

# =============================================================================
WORKDIR /app

# Install curl for the HEALTHCHECK in the final stage.
# Done here so it's cached and shared — not duplicated per stage.
RUN apk add --no-cache curl


# =============================================================================
# STAGE 1: DEPS  (runs in parallel with STAGE 2)
# Installs ONLY production node_modules.
# BuildKit mount cache persists the npm cache directory across builds —
# even when package.json changes, already-downloaded tarballs are reused.
# =============================================================================
FROM base AS deps

COPY package.json package-lock.json ./

# --mount=type=cache: npm's download cache is stored on the BuildKit daemon,
# NOT baked into the image layer. Subsequent builds skip re-downloading packages.
# --omit=dev: no devDependencies reach the production image.
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev


# =============================================================================
# STAGE 2: BUILD  (runs in parallel with STAGE 1)
# Installs ALL dependencies (including dev) and compiles TypeScript / bundles.
# For a plain JS project this stage is still useful for running linting/tests.
# BuildKit starts this stage at the same time as STAGE 1 — no waiting.
# =============================================================================
FROM base AS build

COPY package.json package-lock.json ./

# Full install including devDependencies (tsc, esbuild, etc.)
RUN --mount=type=cache,target=/root/.npm \
    npm ci

# Copy source and compile. Adjust "npm run build" to match your package.json script.
COPY src/ ./src/
RUN npm run build


# =============================================================================
# STAGE 3: RUNNER  (starts only after STAGE 1 and STAGE 2 both complete)
# Minimal, clean production image. Zero build tools, zero devDependencies.
# Copies compiled output from build stage and prod modules from deps stage.
# =============================================================================
FROM node:20-alpine AS runner

# Production environment flag — disables dev middleware, verbose logging, etc.
ENV NODE_ENV=production
# Disable npm update checks at runtime (noise in container logs)
ENV NPM_CONFIG_UPDATE_NOTIFIER=false

WORKDIR /app

# Install curl for HEALTHCHECK — smallest possible addition to the runner image
RUN apk add --no-cache curl

# Create a dedicated non-root system user and group.
# UID/GID 1001 — avoids collisions with default system accounts (root=0, nobody=65534).
RUN addgroup --system --gid 1001 appgroup && \
    adduser  --system --uid 1001 --ingroup appgroup --no-create-home appuser

# Copy ONLY production node_modules from the deps stage (not devDependencies)
COPY --from=deps  --chown=appuser:appgroup /app/node_modules ./node_modules

# Copy compiled application output from the build stage (not raw source)
COPY --from=build --chown=appuser:appgroup /app/dist ./dist

# Copy package.json so Node can resolve the "main" field if needed
COPY --chown=appuser:appgroup package.json ./

# Drop to non-root. Every instruction after this line runs as appuser.
# An attacker who escapes the app process has no write access to the filesystem.
USER appuser

# Document the port — does not publish it; that is done at docker run / ECS task def.
EXPOSE 3000

# HEALTHCHECK: Docker / ECS / Kubernetes will poll this endpoint every 30s.
# If it fails 3 times consecutively the container is marked unhealthy and restarted.
# Adjust the path to match your actual health endpoint.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

# Exec form (array syntax) — Node receives SIGTERM directly for graceful shutdown.
# Shell form would make /bin/sh PID 1, which swallows signals.
CMD ["node", "dist/index.js"]
