# syntax=docker/dockerfile:1.7

# =============================================================================
# STAGE 1: BASE
# =============================================================================
FROM node:20-alpine AS base

WORKDIR /app


# =============================================================================
# STAGE 2: DEPENDENCIES
# =============================================================================
FROM base AS deps

COPY package.json package-lock.json ./

RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev


# =============================================================================
# STAGE 3: BUILD
# =============================================================================
FROM base AS build

COPY package.json package-lock.json ./

RUN --mount=type=cache,target=/root/.npm \
    npm ci

COPY src/ ./src/

RUN npm run build


# =============================================================================
# STAGE 4: RUNTIME (PRODUCTION)
# =============================================================================
FROM node:20-alpine AS runner

ENV NODE_ENV=production
ENV NPM_CONFIG_UPDATE_NOTIFIER=false

WORKDIR /app

# Create non-root user (security requirement)
RUN addgroup --system --gid 1001 appgroup && \
    adduser --system --uid 1001 --ingroup appgroup --no-create-home appuser

# Copy dependencies and build output
COPY --from=deps  /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./

# Set ownership
RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 3000

CMD ["node", "dist/index.js"]
