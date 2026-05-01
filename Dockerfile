# =============================================================================
# BASE
# =============================================================================
FROM node:20-alpine AS base
WORKDIR /app
RUN apk add --no-cache curl

# =============================================================================
# DEPS
# =============================================================================
FROM base AS deps
COPY package.json package-lock.json ./
RUN npm ci

# =============================================================================
# BUILD
# =============================================================================
FROM base AS build
COPY package.json package-lock.json ./
RUN npm ci
COPY src/ ./src/
RUN npm run build

# =============================================================================
# RUNTIME (ZERO TRUST)
# =============================================================================
FROM node:20-alpine AS runner

WORKDIR /app

ENV NODE_ENV=production
ENV NPM_CONFIG_UPDATE_NOTIFIER=false

RUN apk add --no-cache curl

# non-root user
RUN addgroup -S appgroup && \
    adduser -S appuser -G appgroup

# copy ONLY build output
COPY --from=build /app/dist ./dist
COPY package.json ./

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

CMD ["node", "dist/index.js"]
