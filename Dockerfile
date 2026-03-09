# syntax=docker/dockerfile:1

# =============================================================================
# Stage 1: Build Go API backend
# =============================================================================
FROM golang:1.25-alpine AS go-builder

WORKDIR /src

RUN apk add --no-cache git

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /fabric ./cmd/fabric

# =============================================================================
# Stage 2: Build SvelteKit frontend with adapter-node
# =============================================================================
FROM node:22-alpine AS web-builder

WORKDIR /web

# Copy pattern_descriptions needed by prebuild script
COPY scripts/pattern_descriptions/pattern_descriptions.json /scripts/pattern_descriptions/pattern_descriptions.json

COPY web/package.json web/pnpm-lock.yaml web/.npmrc ./
RUN corepack enable && corepack prepare pnpm@latest --activate \
    && npm install -g patch-package \
    && pnpm install --no-frozen-lockfile

COPY web/ .

# Install adapter-node (replacing adapter-auto for production)
RUN pnpm add @sveltejs/adapter-node

# Swap adapter-auto for adapter-node in svelte.config.js
RUN sed -i "s|import adapter from '@sveltejs/adapter-auto'|import adapter from '@sveltejs/adapter-node'|" svelte.config.js \
    && sed -i '/pages:/d; /assets:/d; /fallback:/d; /precompress:/d; /strict:/d' svelte.config.js

# Set the Fabric API URL for build time (internal Docker networking)
ENV FABRIC_BASE_URL=http://localhost:8080

RUN pnpm run build

# =============================================================================
# Stage 3: Final image — Nginx + Node + Go
# =============================================================================
FROM alpine:latest

LABEL org.opencontainers.image.description="Fabric full-stack: Go API + SvelteKit frontend behind Nginx"

# Install runtime dependencies
RUN apk add --no-cache \
    ca-certificates \
    yt-dlp \
    nginx \
    nodejs \
    supervisor \
    && mkdir -p /root/.config/fabric \
    && mkdir -p /var/log/supervisor

# Copy Go binary
COPY --from=go-builder /fabric /usr/local/bin/fabric

# Copy SvelteKit build output (adapter-node produces a standalone server)
COPY --from=web-builder /web/build /app/web

# Copy node_modules needed at runtime by adapter-node
COPY --from=web-builder /web/node_modules /app/node_modules
COPY --from=web-builder /web/package.json /app/package.json

# Nginx config
COPY <<'NGINX_CONF' /etc/nginx/http.d/default.conf
server {
    listen 80;
    server_name _;

    # API routes → Go backend
    location /api/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 900s;
        proxy_buffering off;
    }

    location /patterns/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_read_timeout 900s;
    }

    location /models/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }

    location /sessions/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }

    location /contexts/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }

    location /swagger/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }

    # Everything else → SvelteKit Node server
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX_CONF

# Supervisord config to manage all 3 processes
COPY <<'SUPERVISOR_CONF' /etc/supervisord.conf
[supervisord]
nodaemon=true
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid

[program:fabric-api]
command=/usr/local/bin/fabric --serve
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:sveltekit]
command=node /app/web/index.js
directory=/app
environment=PORT="3000",HOST="127.0.0.1",FABRIC_BASE_URL="http://127.0.0.1:8080"
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:nginx]
command=nginx -g "daemon off;"
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
SUPERVISOR_CONF

EXPOSE 80

CMD ["supervisord", "-c", "/etc/supervisord.conf"]