# STAGE 0: BASE
FROM node:20-alpine AS base
WORKDIR /app
# Install curl once here so it is available in all subsequent stages
RUN apk add --no-cache curl

# =============================================================================
# STAGE 1: DEPS (Production only)
# =============================================================================
FROM base AS deps
COPY package.json package-lock.json ./
# Install only production dependencies
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev && mkdir -p node_modules

# =============================================================================
# STAGE 2: BUILD (Optional but kept for workflow)
# =============================================================================
FROM base AS build
COPY package.json package-lock.json ./
# Install all dependencies (including dev) to run build/tests
RUN --mount=type=cache,target=/root/.npm \
    npm ci
COPY . .
# Only runs if "build" script exists in package.json; otherwise, this is a no-op
RUN npm run build --if-present

# =============================================================================
# STAGE 3: RUNNER
# =============================================================================
FROM base AS runner

ENV NODE_ENV=production
ENV NPM_CONFIG_UPDATE_NOTIFIER=false

# Setup permissions
RUN addgroup --system --gid 1001 appgroup && \
    adduser --system --uid 1001 --ingroup appgroup --no-create-home appuser

# Copy production node_modules from deps stage
COPY --from=deps /app/node_modules ./node_modules

# Copy source code (since your tree shows src/index.js)
COPY --from=build /app/src ./src
COPY package.json ./

USER appuser
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

# Updated path to match your project structure
CMD ["node", "src/index.js"]
