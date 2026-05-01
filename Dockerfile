# syntax=docker/dockerfile:1.7

FROM node:20-alpine AS builder

WORKDIR /app

# Copy dependencies first (cache optimized)
COPY package.json package-lock.json ./

RUN npm ci --omit=dev

# Copy source
COPY src/ ./src/

# Build step (safe even if no build tool)
RUN npm run build || echo "No build step required"


# =============================================================================
# RUNTIME STAGE
# =============================================================================
FROM node:20-alpine AS runner

WORKDIR /app

ENV NODE_ENV=production

# Create non-root user
RUN addgroup --system --gid 1001 appgroup && \
    adduser --system --uid 1001 --ingroup appgroup --no-create-home appuser

# Copy ONLY what is guaranteed to exist
COPY --from=builder /app/package.json ./
COPY --from=builder /app/src ./src

# Install production dependencies INSIDE runtime (key fix)
RUN npm ci --omit=dev

USER appuser

EXPOSE 3000

CMD ["node", "src/index.js"]
