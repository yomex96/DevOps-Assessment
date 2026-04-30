# =============================================================================
# STAGE 1: DEPENDENCY INSTALLER
# Uses the full alpine image to install ONLY production dependencies.
# This layer is cached separately from source code for fast rebuilds.
# =============================================================================
FROM node:20-alpine AS deps

WORKDIR /app

# Copy ONLY the dependency manifests first.
# Docker cache: this layer only re-runs if package.json or package-lock.json changes.
# Changing source code (index.js, etc.) will NOT invalidate this layer.
COPY package.json package-lock.json ./

# Install ONLY production dependencies — no devDependencies in the final image
RUN npm ci --omit=dev


# =============================================================================
# STAGE 2: PRODUCTION RUNNER
# Starts from a clean, minimal base. Copies only what is needed to run.
# Result: smallest possible image with the smallest attack surface.
# =============================================================================
FROM node:20-alpine AS runner

# Set NODE_ENV so any remaining runtime checks behave correctly
ENV NODE_ENV=production

WORKDIR /app

# Create a dedicated non-root system user and group.
# Running as root inside a container is a critical security vulnerability.
RUN addgroup --system --gid 1001 appgroup && \
    adduser --system --uid 1001 --ingroup appgroup appuser

# Copy production node_modules from the deps stage
COPY --from=deps /app/node_modules ./node_modules

# Copy the application source code
COPY . .

# Transfer ownership of the working directory to the non-root user
RUN chown -R appuser:appgroup /app

# Switch to non-root user — all subsequent commands and the final process run as this user
USER appuser

# Expose the application port (documentation only; does not publish the port)
EXPOSE 3000

# Use exec form of CMD to ensure the Node process receives OS signals (SIGTERM, etc.)
# This allows graceful shutdown instead of the process being killed hard.
CMD ["node", "src/index.js"]
