# =========================================================
# BUILD STAGE
# =========================================================
FROM node:20-alpine AS builder

WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY src/ ./src/
RUN mkdir -p dist && cp -r src/* dist/


# =========================================================
# RUNTIME STAGE (SECURE)
# =========================================================
FROM node:20-alpine AS runner

WORKDIR /app

# create non-root user
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# copy only built artifacts
COPY --from=builder /app/dist ./dist
COPY package*.json ./

# install ONLY production deps (important fix)

RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

USER appuser

ENV NODE_ENV=production

EXPOSE 3000

# healthcheck 
HEALTHCHECK --interval=30s --timeout=5s CMD node -e "require('http').get('http://localhost:3000', (res) => process.exit(res.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"


CMD ["node", "dist/index.js"]
