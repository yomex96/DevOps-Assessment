# syntax=docker/dockerfile:1.7

# =========================================================
# STAGE 1: Dependencies (cached layer)
# =========================================================
FROM node:20-alpine AS deps

WORKDIR /app

COPY package.json package-lock.json ./

RUN npm ci --omit=dev


# =========================================================
# STAGE 2: Builder (optional build step)
# =========================================================
FROM node:20-alpine AS builder

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY src/ ./src/

# Create dist safely (prevents your earlier /dist errors)
RUN mkdir -p dist && cp -r src/* dist/


# =========================================================
# STAGE 3: Runtime (small + secure)
# =========================================================
FROM node:20-alpine AS runner

WORKDIR /app

# Security patching
RUN apk update && apk upgrade --no-cache

# Non-root user (REQUIRED by brief)
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

USER appuser

ENV NODE_ENV=production

# Only production artifacts
COPY --from=deps /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY package.json ./

EXPOSE 3000

CMD ["node", "dist/index.js"]
