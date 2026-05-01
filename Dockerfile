# STAGE 0: BASE
FROM node:20-alpine AS base

# =============================================================================
WORKDIR /app

# Install curl for the HEALTHCHECK in the final stage.
# Done here so it's cached and shared — not duplicated per stage.
RUN apk add --no-cache curl


# =============================================================================
# STAGE 1: DEPS
# =============================================================================
FROM base AS deps

COPY package.json package-lock.json ./

RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev


# =============================================================================
# STAGE 2: BUILD
# =============================================================================
FROM base AS build

COPY package.json package-lock.json ./

RUN --mount=type=cache,target=/root/.npm \
    npm ci

COPY src/ ./src/
RUN npm run build


# =============================================================================
# STAGE 3: RUNNER
# =============================================================================
FROM node:20-alpine AS runner

ENV NODE_ENV=production
ENV NPM_CONFIG_UPDATE_NOTIFIER=false

WORKDIR /app

RUN apk add --no-cache curl

RUN addgroup --system --gid 1001 appgroup && \
    adduser  --system --uid 1001 --ingroup appgroup --no-create-home appuser

COPY --from=deps  --chown=appuser:appgroup /app/node_modules ./node_modules
COPY --from=build --chown=appuser:appgroup /app/dist ./dist
COPY --chown=appuser:appgroup package.json ./

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

CMD ["node", "dist/index.js"]
