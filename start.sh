#!/bin/bash
set -euo pipefail

umask 0077

# ── Config ────────────────────────────────────────────────────────────────────
export DATABASE_URL="${DATABASE_URL:-postgres://postgres:paperclip@localhost:5432/paperclip}"
export PORT="${PORT:-3100}"
export SERVE_UI="${SERVE_UI:-true}"
export NODE_ENV="${NODE_ENV:-production}"
export HOST="${HOST:-0.0.0.0}"
export PAPERCLIP_HOME="${PAPERCLIP_HOME:-/paperclip}"
export PAPERCLIP_DEPLOYMENT_MODE="${PAPERCLIP_DEPLOYMENT_MODE:-authenticated}"
export PAPERCLIP_DEPLOYMENT_EXPOSURE="${PAPERCLIP_DEPLOYMENT_EXPOSURE:-private}"
export PAPERCLIP_INSTANCE_ID="${PAPERCLIP_INSTANCE_ID:-default}"
export PAPERCLIP_CONFIG="${PAPERCLIP_CONFIG:-${PAPERCLIP_HOME}/instances/default/config.json}"
export PAPERCLIP_TELEMETRY_DISABLED="${PAPERCLIP_TELEMETRY_DISABLED:-1}"
export DO_NOT_TRACK="${DO_NOT_TRACK:-1}"
export OPENCODE_ALLOW_ALL_MODELS="${OPENCODE_ALLOW_ALL_MODELS:-true}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/home/paperclip/.config}"
export SYNC_INTERVAL="${SYNC_INTERVAL:-3600}"
export SYNC_MAX_FILE_BYTES="${SYNC_MAX_FILE_BYTES:-52428800}"
export BACKUP_DATASET_NAME="${BACKUP_DATASET_NAME:-huggingclip-backup}"
SYNC_INTERVAL="$(printf '%s' "${SYNC_INTERVAL}" | tr -cd '0-9')"
if [ -z "${SYNC_INTERVAL}" ] || [ "${SYNC_INTERVAL}" -lt 60 ]; then
    SYNC_INTERVAL=60
fi
export SYNC_INTERVAL

# Derive public URL from HF Space host
if [ -z "${PAPERCLIP_PUBLIC_URL:-}" ] && [ -n "${SPACE_HOST:-}" ]; then
    export PAPERCLIP_PUBLIC_URL="https://${SPACE_HOST}"
fi

# Allowed hostnames
_ALLOWED="localhost,127.0.0.1,0.0.0.0"
if [ -n "${SPACE_HOST:-}" ]; then
    _ALLOWED="${_ALLOWED},${SPACE_HOST}"
fi
export PAPERCLIP_ALLOWED_HOSTNAMES="${PAPERCLIP_ALLOWED_HOSTNAMES:-${_ALLOWED}}"

# LLM API keys
export GEMINI_API_KEY="${GEMINI_API_KEY:-}"
export NVAPI_KEYS="${NVAPI_KEYS:-}"
export NVIDIA_API_KEY="${NVIDIA_API_KEY:-}"
export NVIDIA_BASE_URL="${NVIDIA_BASE_URL:-}"

mapfile -t NVIDIA_API_KEYS_PARSED < <(
    python3 <<'PYEOF'
import os

values = []
for name in ("NVAPI_KEYS", "NVIDIA_API_KEY"):
    raw = os.environ.get(name, "")
    if raw:
        values.extend(raw.split(","))

for value in values:
    value = value.strip()
    if value:
        print(value)
PYEOF
)
NVIDIA_KEY_COUNT=${#NVIDIA_API_KEYS_PARSED[@]}

if { [ -n "${NVAPI_KEYS:-}" ] || [ -n "${NVIDIA_API_KEY:-}" ]; } && [ "${NVIDIA_KEY_COUNT}" -eq 0 ]; then
    echo "ERROR: NVAPI_KEYS/NVIDIA_API_KEY is set but no usable NVIDIA API keys were found"
    echo "       Provide one or more non-empty comma-separated keys"
    exit 1
fi

mkdir -p "${PAPERCLIP_HOME}"

# Auth secrets (generate + persist so they survive restarts)
AUTH_SECRET_FILE="${PAPERCLIP_HOME}/.auth-secret"
if [ -z "${BETTER_AUTH_SECRET:-}" ]; then
    if [ -f "${AUTH_SECRET_FILE}" ]; then
        export BETTER_AUTH_SECRET=$(cat "${AUTH_SECRET_FILE}")
    else
        export BETTER_AUTH_SECRET=$(openssl rand -base64 32)
        echo "${BETTER_AUTH_SECRET}" > "${AUTH_SECRET_FILE}"
        chmod 600 "${AUTH_SECRET_FILE}"
    fi
fi

JWT_SECRET_FILE="${PAPERCLIP_HOME}/.jwt-secret"
if [ -z "${PAPERCLIP_AGENT_JWT_SECRET:-}" ]; then
    if [ -f "${JWT_SECRET_FILE}" ]; then
        export PAPERCLIP_AGENT_JWT_SECRET=$(cat "${JWT_SECRET_FILE}")
    else
        export PAPERCLIP_AGENT_JWT_SECRET=$(openssl rand -base64 32)
        echo "${PAPERCLIP_AGENT_JWT_SECRET}" > "${JWT_SECRET_FILE}"
        chmod 600 "${JWT_SECRET_FILE}"
    fi
fi

# ── Validate LLM providers ───────────────────────────────────────────────────
if [ -z "${GEMINI_API_KEY:-}" ] && [ "${NVIDIA_KEY_COUNT}" -eq 0 ] && [ -z "${NVIDIA_BASE_URL:-}" ]; then
    echo "⚠️  WARNING: No LLM provider configured"
    echo "   Set at least one of: GEMINI_API_KEY, NVAPI_KEYS, NVIDIA_BASE_URL"
    echo "   Agents will fail to run without an LLM provider"
    echo ""
fi

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "  ╔════════════════════════════════════╗"
echo "  ║          HuggingClip               ║"
echo "  ╚════════════════════════════════════╝"
echo ""
echo "Public host  : ${SPACE_HOST:-not detected}"
echo "Public URL   : ${PAPERCLIP_PUBLIC_URL:-http://localhost:${PORT}}"
echo "App port     : ${PORT}"
echo "Deploy mode  : ${PAPERCLIP_DEPLOYMENT_MODE}"
echo "Sync every   : ${SYNC_INTERVAL}s"
echo ""

# ── PostgreSQL ────────────────────────────────────────────────────────────────
PG_VERSION=$(ls /usr/lib/postgresql/ 2>/dev/null | sort -V | tail -1)
if [ -z "$PG_VERSION" ]; then
    echo "ERROR: PostgreSQL not found"
    exit 1
fi
PG_DATA="/var/lib/postgresql/${PG_VERSION}/main"

if [ ! -f "${PG_DATA}/PG_VERSION" ]; then
    echo "Initializing PostgreSQL cluster..."
    pg_createcluster "${PG_VERSION}" main --locale=C.UTF-8 >/dev/null 2>&1
fi

if ! pg_ctlcluster "${PG_VERSION}" main status 2>/dev/null | grep -q "online"; then
    echo "Starting PostgreSQL..."
    pg_ctlcluster "${PG_VERSION}" main start >/dev/null 2>&1
fi

until pg_isready -h localhost -U postgres >/dev/null 2>&1; do
    sleep 1
done

# Generate random DB password on first run (don't hardcode 'paperclip')
DB_PASSWORD_FILE="${PAPERCLIP_HOME}/.db-password"
if [ ! -f "${DB_PASSWORD_FILE}" ]; then
    DB_PASSWORD=$(openssl rand -hex 24)
    echo "$DB_PASSWORD" > "${DB_PASSWORD_FILE}"
    chmod 600 "${DB_PASSWORD_FILE}"
else
    DB_PASSWORD=$(cat "${DB_PASSWORD_FILE}")
fi
export PGPASSWORD="${DB_PASSWORD}"

su - postgres -c "psql -c \"ALTER USER postgres WITH PASSWORD '${DB_PASSWORD}';\"" >/dev/null 2>&1 || true
su - postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname = 'paperclip'\" | grep -q 1 || psql -c \"CREATE DATABASE paperclip OWNER postgres;\"" >/dev/null 2>&1 || true

# Update DATABASE_URL with generated password (if not explicitly set)
# URL-encode the password to handle special chars (e.g. / + = from old base64 passwords)
if [[ "$DATABASE_URL" == *"postgres:paperclip"* ]]; then
    DB_PASSWORD_ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${DB_PASSWORD}")
    export DATABASE_URL="postgres://postgres:${DB_PASSWORD_ENCODED}@localhost:5432/paperclip"
fi

echo "PostgreSQL ready (v${PG_VERSION})"

# ── Restore from HF Dataset ───────────────────────────────────────────────────
SYNC_STATUS_FILE="/tmp/sync-status.json"
if [ -n "${HF_TOKEN:-}" ]; then
    echo "Restoring persisted data from HF Dataset..."
    python3 /app/paperclip-sync.py restore 2>&1 || true

    # Re-stamp .db-password with current session's password so restore can't
    # overwrite it with an old base64 value that breaks DATABASE_URL next restart
    echo "${DB_PASSWORD}" > "${DB_PASSWORD_FILE}"
    chmod 600 "${DB_PASSWORD_FILE}"

    # Update PostgreSQL password to match (restore may have re-created the DB)
    su - postgres -c "psql -c \"ALTER USER postgres WITH PASSWORD '${DB_PASSWORD}';\"" >/dev/null 2>&1 || true

    # Check if last sync failed
    if [ -f "${SYNC_STATUS_FILE}" ]; then
        LAST_ERROR=$(python3 -c "import json; f=open('${SYNC_STATUS_FILE}'); d=json.load(f); print(d.get('last_error') or '')" 2>/dev/null || true)
        if [ -n "$LAST_ERROR" ]; then
            echo "⚠️  WARNING: Last backup sync failed: $LAST_ERROR"
            echo "   Data may not be persisted to HF Dataset"
        fi
    fi
else
    echo "HF_TOKEN not set — running without backup persistence"
fi

# ── Cloudflare Proxy ──────────────────────────────────────────────────────────
if [ -n "${CLOUDFLARE_WORKERS_TOKEN:-}" ]; then
    echo "Setting up Cloudflare proxy..."
    python3 /app/cloudflare-proxy-setup.py 2>&1 || echo "Cloudflare setup failed, continuing without proxy"
fi

# Source CF proxy env if the setup script wrote it (provides CLOUDFLARE_PROXY_URL + SECRET)
_CF_ENV="/tmp/huggingclaw-cloudflare-proxy.env"
if [ -f "${_CF_ENV}" ]; then
    # shellcheck source=/dev/null
    . "${_CF_ENV}"
fi

# ── Cloudflare proxy flag (applied inline to Paperclip only, not exported globally)
# Only enable if proxy is actually configured. Otherwise agent runtimes inherit
# it via subprocess env and break their HTTP requests.
_CF_NODE_OPTS=""
if [ -n "${CLOUDFLARE_PROXY_URL:-}" ] && [ -f /app/cloudflare-proxy.js ]; then
    _CF_NODE_OPTS="--require /app/cloudflare-proxy.js"
fi

# ── Gemini CLI environment ───────────────────────────────────────────────────
# Disable sandbox (would try to start Docker inside Docker)
export GEMINI_SANDBOX=false
# Trust the workspace — paperclip user runs from /app/paperclip (root-owned).
export GEMINI_CLI_TRUST_WORKSPACE=true
# Kill-switch for relaunch.ts::relaunchAppInChildProcess() — the spawn inside
# fails when Paperclip pipes gemini's stdio (IPC channel setup fails).
# With this set, relaunchAppInChildProcess() returns early and gemini runs
# as the main process without spawning a child.
export GEMINI_CLI_NO_RELAUNCH=1

# ── Background sync loop ──────────────────────────────────────────────────────
if [ -n "${HF_TOKEN:-}" ]; then
    (
        while true; do
            sleep "$SYNC_INTERVAL"
            python3 /app/paperclip-sync.py sync 2>&1 || true
        done
    ) &
    SYNC_PID=$!
else
    SYNC_PID=""
fi

# ── Health server ─────────────────────────────────────────────────────────────
node /app/health-server.js &
HEALTH_PID=$!

if [ -n "${CLOUDFLARE_WORKERS_TOKEN:-}" ]; then
  echo "Setting up Cloudflare KeepAlive monitor..."
  python3 /app/cloudflare-keepalive-setup.py || true
fi

sleep 2

# ── Paperclip instance config ─────────────────────────────────────────────────
cd /app/paperclip

if [ ! -d "node_modules" ]; then
    echo "Installing Paperclip dependencies..."
    pnpm install 2>&1 | tail -5 || npm install 2>&1 | tail -5
fi

if [ ! -f "${PAPERCLIP_CONFIG}" ]; then
    echo "Creating instance config (first boot)..."
    mkdir -p "$(dirname "${PAPERCLIP_CONFIG}")"
    python3 <<'PYEOF'
import json, os

home = os.environ.get("PAPERCLIP_HOME", "/paperclip")
port = int(os.environ.get("PORT", "3100"))
public_url = os.environ.get("PAPERCLIP_PUBLIC_URL", f"http://localhost:{port}")

# Paperclip treats llm as optional, so leave it unset here and let runtime
# adapters provide OpenCode/Gemini configuration instead of seeding Claude/OpenAI.
config = {
    "$meta": {"version": 1, "updatedAt": "2024-01-01T00:00:00Z", "source": "onboard"},
    "database": {
        "mode": "postgres",
        "connectionString": os.environ.get("DATABASE_URL", "postgres://postgres:paperclip@localhost:5432/paperclip")
    },
    "logging": {"mode": "file", "logDir": f"{home}/instances/default/logs"},
    "server": {
        "deploymentMode": os.environ.get("PAPERCLIP_DEPLOYMENT_MODE", "authenticated"),
        "exposure": os.environ.get("PAPERCLIP_DEPLOYMENT_EXPOSURE", "private"),
        "host": "0.0.0.0",
        "port": port,
        "allowedHostnames": [],
        "serveUi": True
    },
    "auth": {
        "baseUrlMode": "explicit",
        "publicBaseUrl": public_url,
        "disableSignUp": False
    },
    "storage": {
        "provider": "local_disk",
        "localDisk": {"baseDir": f"{home}/instances/default/data/storage"}
    },
    "secrets": {
        "provider": "local_encrypted",
        "strictMode": False,
        "localEncrypted": {"keyFilePath": f"{home}/instances/default/secrets/master.key"}
    },
    "telemetry": {"enabled": False}
}

config_path = os.environ.get("PAPERCLIP_CONFIG", f"{home}/instances/default/config.json")
os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
print(f"  Config written to {config_path}")
PYEOF
fi

# ── Graceful shutdown ─────────────────────────────────────────────────────────
cleanup() {
    echo "Shutting down — syncing data..."

    # Stop services
    [ -n "${HEALTH_PID:-}" ]    && kill "$HEALTH_PID"    2>/dev/null || true
    [ -n "${PAPERCLIP_PID:-}" ] && kill "$PAPERCLIP_PID" 2>/dev/null || true

    # Kill background sync loop, then wait for it to exit before running final sync
    # (avoids concurrent writes: kill stops the loop, wait confirms it's done)
    if [ -n "${SYNC_PID:-}" ]; then
        kill "$SYNC_PID" 2>/dev/null || true
        wait "$SYNC_PID" 2>/dev/null || true
    fi

    # Run final backup sync
    if [ -n "${HF_TOKEN:-}" ]; then
        python3 /app/paperclip-sync.py sync 2>&1 || true
    fi

    exit 0
}
trap cleanup SIGTERM SIGINT

# ── OpenCode NVIDIA config ───────────────────────────────────────────────────
OPENCODE_CONFIG_DIR="${XDG_CONFIG_HOME}/opencode"
OPENCODE_CONFIG_FILE="${OPENCODE_CONFIG_DIR}/opencode.json"
OPENCODE_NVIDIA_KEYS_FILE="${OPENCODE_CONFIG_DIR}/nvidia-api-keys.txt"
OPENCODE_NVIDIA_KEY_STATE_FILE="${OPENCODE_CONFIG_DIR}/nvidia-api-key-index"
mkdir -p "${OPENCODE_CONFIG_DIR}"

if [ "${NVIDIA_KEY_COUNT}" -gt 0 ]; then
    printf '%s\n' "${NVIDIA_API_KEYS_PARSED[@]}" > "${OPENCODE_NVIDIA_KEYS_FILE}"
    chmod 600 "${OPENCODE_NVIDIA_KEYS_FILE}"
    if [ ! -f "${OPENCODE_NVIDIA_KEY_STATE_FILE}" ]; then
        printf '0\n' > "${OPENCODE_NVIDIA_KEY_STATE_FILE}"
    fi
    chmod 600 "${OPENCODE_NVIDIA_KEY_STATE_FILE}"
    export OPENCODE_NVIDIA_KEYS_FILE
    export OPENCODE_NVIDIA_KEY_STATE_FILE
else
    rm -f "${OPENCODE_NVIDIA_KEYS_FILE}" "${OPENCODE_NVIDIA_KEY_STATE_FILE}"
fi

if [ "${NVIDIA_KEY_COUNT}" -gt 0 ] || [ -n "${NVIDIA_BASE_URL:-}" ]; then
    export OPENCODE_CONFIG_FILE
    python3 <<'PYEOF'
import json
import os

provider = {"nvidia": {}}
base_url = os.environ.get("NVIDIA_BASE_URL", "").strip()
if base_url:
    provider["nvidia"]["options"] = {"baseURL": base_url}

config = {
    "$schema": "https://opencode.ai/config.json",
    "provider": {
        **provider,
        "anthropic": {"disabled": True},
        "openai": {"disabled": True},
    },
}

config_path = os.environ["OPENCODE_CONFIG_FILE"]
os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PYEOF
    chmod 600 "${OPENCODE_CONFIG_FILE}"
else
    rm -f "${OPENCODE_CONFIG_FILE}"
fi

# ── Ensure paperclip user owns runtime dirs ──────────────────────────────────
chown -R paperclip:paperclip /app /paperclip /home/paperclip/.config 2>/dev/null || true

# ── Launch Paperclip as non-root ──────────────────────────────────────────────
# Run Paperclip as 'paperclip' user so all spawned subprocesses are non-root.
echo "Starting Paperclip..."
HOME=/home/paperclip NODE_OPTIONS="${_CF_NODE_OPTS}" runuser -u paperclip -- \
    node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js &
PAPERCLIP_PID=$!

# Wait for API ready (max 90s)
PAPERCLIP_READY=false
for i in $(seq 1 45); do
    if curl -sf http://127.0.0.1:3100/api/health >/dev/null 2>&1; then
        echo "Paperclip ready (${i}s)"
        PAPERCLIP_READY=true
        break
    fi
    sleep 2
done

if [ "$PAPERCLIP_READY" = true ]; then
    BOOTSTRAP_OUTPUT=$(HOME=/home/paperclip runuser -u paperclip -- pnpm paperclipai auth bootstrap-ceo 2>&1 || true)
    INVITE_URL=$(echo "$BOOTSTRAP_OUTPUT" | grep "Invite URL:" 2>/dev/null | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' | grep -o 'https\?://[^ ]*' | head -1 || true)
    if [ -n "$INVITE_URL" ]; then
        echo "$INVITE_URL" > /tmp/invite-url.txt
        echo ""
        echo "  ┌─────────────────────────────────────────────────────┐"
        echo "  │  ADMIN SETUP — open this URL in your browser:       │"
        echo "  │                                                     │"
        echo "  │  ${INVITE_URL}"
        echo "  │                                                     │"
        echo "  └─────────────────────────────────────────────────────┘"
        echo ""
    else
        rm -f /tmp/invite-url.txt
        echo "Admin account already configured"
    fi


else
    echo "Warning: Paperclip did not become ready in 90s"
fi

echo "HuggingClip is ready!"
echo ""
echo "  Health dashboard : http://localhost:7861/"
echo "  Paperclip UI     : http://localhost:7861/app/"
echo "  API              : http://localhost:7861/api/"
echo ""

wait $PAPERCLIP_PID
