# syntax=docker/dockerfile:1.7

FROM node:20-alpine AS base

WORKDIR /app

# security patching (safe + expected in assessments)
RUN apk update && apk upgrade --no-cache && rm -rf /var/cache/apk/*

# install dependencies first (cache optimization)
COPY package.json package-lock.json ./

RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev

# copy source AFTER dependencies (best caching practice)
COPY src/ ./src/

# create non-root user (REQUIRED by brief)
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

USER appuser

EXPOSE 3000

CMD ["node", "src/index.js"]
