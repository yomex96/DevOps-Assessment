# =========================================================
# BUILD STAGE
# =========================================================
FROM node:20-alpine AS builder

WORKDIR /app

# Copy only manifests first (cache optimization)
COPY package*.json ./

# Install deps (include dev for build if needed, but lock scripts)
RUN npm ci --ignore-scripts

# Copy source
COPY src/ ./src/

# Build-safe output
RUN mkdir -p dist && cp -r src/* dist/


# =========================================================
# RUNTIME STAGE (SECURE)
# =========================================================
FROM node:20-alpine AS runner

WORKDIR /app

# Create non-root user
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Copy only built artifacts
COPY --from=builder /app/dist ./dist
COPY package*.json ./

# Install ONLY production deps (hardened)
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
    && npm cache clean --force

# Drop privileges
USER appuser

ENV NODE_ENV=production

EXPOSE 3000

# Healthcheck (aligned with /health endpoint)
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
CMD node -e "require('http').get('http://localhost:3000/health', (res) => process.exit(res.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

CMD ["node", "dist/index.js"]
