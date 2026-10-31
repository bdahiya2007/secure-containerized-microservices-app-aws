# syntax=docker/dockerfile:1

# ---- Stage 1: install production dependencies only ----
FROM node:26.13.0-alpine3.24 AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

# ---- Stage 2: minimal runtime image: plain Alpine plus the node binary only ----
FROM alpine:3.24.3 AS runtime
ENV NODE_ENV=production

# node is dynamically linked against libstdc++, libgcc and libatomic; add an unprivileged user
RUN apk add --no-cache libstdc++ libatomic \
 && addgroup -g 1000 node \
 && adduser -u 1000 -G node -s /bin/sh -D node

# Only the node binary comes from the official image: no npm, npx, corepack or yarn, so their
# bundled packages (and the CVEs in them, see docs/vulnerability-scan-report.md) are never in the image
COPY --from=deps /usr/local/bin/node /usr/local/bin/node

WORKDIR /app

# Copy only what is needed at runtime, owned by the unprivileged "node" user
COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node src ./src
# The schema ships in the image so the one-off migration task (node src/migrate.js) can use this same image
COPY --chown=node:node db ./db

# Run as non-root
USER node

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/health || exit 1

# Run node directly (not via npm) so SIGTERM reaches the process for graceful shutdown
CMD ["node", "src/server.js"]
