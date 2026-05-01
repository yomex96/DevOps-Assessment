# syntax=docker/dockerfile:1.7

# =========================================================
# STAGE 1: build (single source of truth)
# =========================================================
FROM node:20-alpine AS builder

WORKDIR /app

COPY package.json package-lock.json ./

# install ALL deps needed for build
RUN npm ci

COPY src/ ./src/

# build-safe output folder
RUN mkdir -p dist && cp -r src/* dist/


# =========================================================
# STAGE 2: production runtime (clean + secure)
# =========================================================
FROM node:20-alpine AS runner

WORKDIR /app

# security patching
RUN apk update && apk upgrade --no-cache

# non-root user (REQUIRED)
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

USER appuser

ENV NODE_ENV=production

# ONLY COPY FINAL BUILD OUTPUT
COPY --from=builder /app/dist ./dist
COPY package.json ./

EXPOSE 3000

CMD ["node", "dist/index.js"]
