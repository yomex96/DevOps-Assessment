# syntax=docker/dockerfile:1.7

# =============================================================================
# STAGE 1: BUILDER (PRODUCES ARTIFACTS)
# =============================================================================
FROM node:20-alpine AS builder

WORKDIR /app

COPY package.json package-lock.json ./

RUN npm ci

COPY src/ ./src/

RUN npm run build


# =============================================================================
# STAGE 2: RUNTIME (CONSUMES ARTIFACTS ONLY)
# =============================================================================
FROM node:20-alpine AS runner

WORKDIR /app

ENV NODE_ENV=production

# Create non-root user
RUN addgroup --system --gid 1001 appgroup && \
    adduser --system --uid 1001 --ingroup appgroup --no-create-home appuser

# Install ONLY production dependencies in runtime (safe + deterministic)
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# Copy build output ONLY (guaranteed to exist)
COPY --from=builder /app/dist ./dist

USER appuser

EXPOSE 3000

CMD ["node", "dist/index.js"]
