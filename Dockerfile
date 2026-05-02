# =============================================================================
# TASK 1 — ZERO-TRUST DOCKERFILE
# Multi-stage build for the E-Permit Node.js API.
# Produces the smallest possible image, runs as non-root, and is optimised
# for Docker layer caching so source changes never force a dep reinstall.
# =============================================================================

# ── BUILD STAGE ──────────────────────────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

# 1. Copy manifests BEFORE source — only package changes bust this cache layer
COPY package*.json ./

# 2. Full install (may include devDeps for build tools); --ignore-scripts
#    prevents lifecycle scripts from executing arbitrary code during install
RUN npm ci --ignore-scripts

# 3. Copy source after deps are installed
COPY src/ ./src/

# 4. Produce distributable artefact
RUN mkdir -p dist && cp -r src/* dist/


# ── RUNTIME STAGE (HARDENED) 
FROM node:20-alpine AS runner

WORKDIR /app

# 5. Create a dedicated non-root system user+group before copying any files
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# 6. Copy built artefacts with correct ownership in a single layer
#    --chown avoids a separate RUN chown (which would add an extra layer)
COPY --from=builder --chown=appuser:appgroup /app/dist ./dist
COPY --chown=appuser:appgroup package*.json ./

# 7. Install production deps only — no devDeps, no lifecycle scripts,
#    no network audit calls, cache purged in same layer to minimise image size
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
    && npm cache clean --force

# 8. Drop to non-root before any process runs
USER appuser

ENV NODE_ENV=production
ENV PORT=3000

EXPOSE 3000

# 9. Healthcheck uses Node.js built-in http — zero extra packages, zero CVE surface
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

CMD ["node", "dist/index.js"]
