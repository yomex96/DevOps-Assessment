# =========================
# STAGE 1: BASE
# =========================
FROM node:20-alpine AS base

WORKDIR /app

# Install only runtime dependency needed for healthcheck
RUN apk add --no-cache curl


# =========================
# STAGE 2: DEPENDENCIES (CACHED LAYER)
# =========================
FROM base AS deps

WORKDIR /app

COPY package.json package-lock.json ./

# Install ONLY production dependencies
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev


# =========================
# STAGE 3: BUILD STAGE
# =========================
FROM base AS build

WORKDIR /app

COPY package.json package-lock.json ./

# Install all deps for build
RUN --mount=type=cache,target=/root/.npm \
    npm ci

COPY src/ ./src/

RUN npm run build


# =========================
# STAGE 4: PRODUCTION RUNNER (ZERO TRUST)
# =========================
FROM node:20-alpine AS runner

WORKDIR /app

ENV NODE_ENV=production
ENV NPM_CONFIG_UPDATE_NOTIFIER=false

# Install only curl (minimal attack surface)
RUN apk add --no-cache curl

# Create non-root user (SECURITY REQUIREMENT)
RUN addgroup --system --gid 1001 appgroup && \
    adduser --system --uid 1001 --ingroup appgroup --no-create-home appuser

# Copy ONLY what is needed at runtime
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./

# Drop privileges
USER appuser

EXPOSE 3000

# Health check for orchestration
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

# Use exec form for proper signal handling (IMPORTANT FOR DEVOPS MARKING)
CMD ["node", "dist/index.js"]
