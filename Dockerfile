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
    git \
    nginx \
    nodejs \
    && mkdir -p /root/.config/fabric

# Copy bundled patterns and strategies (avoids git clone on startup)
COPY data/patterns /root/.config/fabric/patterns
COPY data/strategies /root/.config/fabric/strategies
COPY data/unique_patterns.txt /root/.config/fabric/unique_patterns.txt

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
        proxy_pass http://127.0.0.1:8080/;
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

# Entrypoint script — starts all 3 services
COPY <<'ENTRYPOINT' /usr/local/bin/entrypoint.sh
#!/bin/sh
set -e

# Ensure fabric config directory exists
mkdir -p /root/.config/fabric

# Generate .env from Docker environment variables if it doesn't exist
if [ ! -f /root/.config/fabric/.env ]; then
    echo "Generating /root/.config/fabric/.env from environment variables..."
    cat > /root/.config/fabric/.env <<EOF
DEFAULT_VENDOR=${DEFAULT_VENDOR:-OpenAI}
DEFAULT_MODEL=${DEFAULT_MODEL:-gpt-4o-mini}
DEFAULT_MODEL_CONTEXT_LENGTH=${DEFAULT_MODEL_CONTEXT_LENGTH:-128000}
PATTERNS_LOADER_GIT_REPO_URL=${PATTERNS_LOADER_GIT_REPO_URL:-https://github.com/danielmiessler/fabric.git}
PATTERNS_LOADER_GIT_REPO_PATTERNS_FOLDER=${PATTERNS_LOADER_GIT_REPO_PATTERNS_FOLDER:-data/patterns}
PROMPT_STRATEGIES_GIT_REPO_URL=${PROMPT_STRATEGIES_GIT_REPO_URL:-https://github.com/danielmiessler/fabric.git}
PROMPT_STRATEGIES_GIT_REPO_STRATEGIES_FOLDER=${PROMPT_STRATEGIES_GIT_REPO_STRATEGIES_FOLDER:-data/strategies}
EOF
    # Append any API key env vars
    [ -n "$OPENAI_API_KEY" ] && echo "OPENAI_API_KEY=$OPENAI_API_KEY" >> /root/.config/fabric/.env
    [ -n "$ANTHROPIC_API_KEY" ] && echo "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" >> /root/.config/fabric/.env
    [ -n "$GEMINI_API_KEY" ] && echo "GEMINI_API_KEY=$GEMINI_API_KEY" >> /root/.config/fabric/.env
    [ -n "$OLLAMA_API_URL" ] && echo "OLLAMA_API_URL=$OLLAMA_API_URL" >> /root/.config/fabric/.env
    [ -n "$GROQ_API_KEY" ] && echo "GROQ_API_KEY=$GROQ_API_KEY" >> /root/.config/fabric/.env
    [ -n "$MISTRAL_API_KEY" ] && echo "MISTRAL_API_KEY=$MISTRAL_API_KEY" >> /root/.config/fabric/.env
    echo "Generated .env:"
    cat /root/.config/fabric/.env
fi

# Start Fabric Go API in background with auto-restart
(while true; do
    echo "[$(date)] Starting Fabric API..." >> /var/log/fabric-api.log
    /usr/local/bin/fabric --serve >> /var/log/fabric-api.log 2>&1
    echo "[$(date)] Fabric API exited, restarting in 5s..." >> /var/log/fabric-api.log
    sleep 5
done) &

# Start SvelteKit Node server in background
PORT=3000 HOST=127.0.0.1 FABRIC_BASE_URL=http://127.0.0.1:8080 \
    node /app/web/index.js > /var/log/sveltekit.log 2>&1 &

# Start Nginx in foreground (keeps container alive)
exec nginx -g "daemon off;"
ENTRYPOINT
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80

CMD ["/usr/local/bin/entrypoint.sh"]
