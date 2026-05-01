# ---------- Base image ----------
FROM node:20-alpine AS base
WORKDIR /app

# ---------- Dependencies (production only) ----------
FROM base AS deps

# Copy only dependency files (cache optimization)
COPY package.json package-lock.json ./

# Install ONLY production dependencies
RUN npm ci --omit=dev --ignore-scripts

# ---------- Build stage ----------
FROM base AS build

COPY package.json package-lock.json ./

# Install all deps (needed for build)
RUN npm ci --ignore-scripts

# Copy source code
COPY . .

# Build app (if applicable)
RUN npm run build || echo "No build step"

# ---------- Final runtime image ----------
FROM node:20-alpine AS runner

WORKDIR /app

# Create non-root user (ZERO TRUST principle)
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Copy production dependencies from deps stage
COPY --from=deps /app/node_modules ./node_modules

# Copy built app from build stage
COPY --from=build /app ./

# Switch to non-root user
USER appuser

# Expose app port
EXPOSE 3000

# Start app
CMD ["node", "src/index.js"]
