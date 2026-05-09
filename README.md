---
title: HuggingClip
emoji: 📎
colorFrom: gray
colorTo: purple
sdk: docker
app_port: 7861
pinned: true
license: mit
secrets:
  - name: HF_TOKEN
    description: Hugging Face API token for database backup.
  - name: CLAUDE_CODE_OAUTH_TOKEN
    description: Anthropic Claude API key for Claude-powered agents.
  - name: GEMINI_API_KEY
    description: Google Gemini API key for Gemini-powered agents.
  - name: OPENAI_API_KEY
    description: OpenAI API key for GPT-powered agents.
  - name: CLOUDFLARE_WORKERS_TOKEN
    description: "Cloudflare API token — auto-creates a Worker proxy and KeepAlive monitor."
---

<!-- Badges -->
[![GitHub Stars](https://img.shields.io/github/stars/somratpro/huggingclip?style=flat-square)](https://github.com/somratpro/huggingclip)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](https://opensource.org/licenses/MIT)
[![HF Space](https://img.shields.io/badge/🤗%20HuggingFace-Space-blue?style=flat-square)](https://huggingface.co/spaces/somratpro/HuggingClip)
[![Paperclip](https://img.shields.io/badge/Paperclip-AI%20Agents-purple?style=flat-square)](https://paperclip.ing)

**Run your own AI agent orchestration platform — free, no server needed.** HuggingClip deploys [Paperclip](https://paperclip.ing) on Hugging Face Spaces, giving you a persistent AI agent platform that works with any LLM (Claude, GPT, Gemini, etc.). Deploy in minutes on the free HF Spaces tier (2 vCPU, 16GB RAM) with automatic database backup to a private HF Dataset so your agents, tasks, and conversations survive restarts.

## Table of Contents

- [✨ Features](#-features)
- [🚀 Quick Start](#-quick-start)
- [🔑 Configuration](#-configuration)
- [🤖 LLM Providers](#-llm-providers)
- [🌐 Cloudflare Proxy *(Optional)*](#-cloudflare-proxy-optional)
- [💾 Database Backup *(Optional)*](#-database-backup-optional)
- [💓 Staying Alive](#-staying-alive)
- [💻 Local Development](#-local-development)
- [🏗️ Architecture](#️-architecture)
- [🐛 Troubleshooting](#-troubleshooting)
- [📚 Links](#-links)
- [🤝 Contributing](#-contributing)
- [📄 License](#-license)

## ✨ Features

- 🤖 **Any LLM:** Use Claude, OpenAI GPT, Google Gemini, and more — just set the API key.
- ⚡ **One-click deploy:** Duplicate the Space and add your API key — nothing else needed to get started.
- 💾 **Persistent Database:** PostgreSQL database auto-backed up to a private HF Dataset and restored on every restart — no data loss.
- 📊 **Visual Dashboard:** Real-time status dashboard at `/` with Paperclip service health, backup status, and uptime.
- ⏰ **Keep-Alive:** Uses `CLOUDFLARE_WORKERS_TOKEN` to automatically set up a cron-triggered keep-awake worker at boot.
- 🌐 **Cloudflare Proxy:** Auto-provisions a Cloudflare Worker proxy for blocked outbound connections.
- 🔒 **Secure by Default:** Auth secrets randomly generated on first boot and persisted across restarts.
- 🏠 **100% HF-Native:** Runs entirely on Hugging Face's free infrastructure.

## 🚀 Quick Start

### Step 1: Duplicate this Space

[![Duplicate this Space](https://huggingface.co/datasets/huggingface/badges/resolve/main/duplicate-this-space-xl.svg)](https://huggingface.co/spaces/somratpro/HuggingClip?duplicate=true)

### Step 2: Add Your Secrets

In your new Space's **Settings → Variables and secrets**, add at least one LLM key under **Secrets**:

| Secret | Description |
| :--- | :--- |
| `ANTHROPIC_API_KEY` | Claude API key from [console.anthropic.com](https://console.anthropic.com) |
| `GEMINI_API_KEY` | Google AI Studio key from [ai.google.dev](https://ai.google.dev) |
| `OPENAI_API_KEY` | OpenAI key from [platform.openai.com](https://platform.openai.com) |

> [!TIP]
> Add `HF_TOKEN` (a token with write access to your account) to enable database backup persistence. Without it, data is lost on restart.

### Step 3: Deploy & Run

The Space builds automatically. Monitor progress in the **Logs** tab. First build takes ~60s; subsequent builds are cached.

### Step 4: Set Up Admin Account

On first boot, the dashboard at `/` shows an admin setup link. Click it to create your admin account and complete Paperclip onboarding.

## 🔑 Configuration

### Required

No secrets are strictly required to start, but you need at least one LLM key to use agents:

| Variable | Description |
| :--- | :--- |
| `ANTHROPIC_API_KEY` | Claude agents |
| `GEMINI_API_KEY` | Gemini agents |
| `OPENAI_API_KEY` | OpenAI agents |

### Recommended

| Variable | Default | Description |
| :--- | :--- | :--- |
| `HF_TOKEN` | — | HF token with write access — enables DB backup persistence |
| `BACKUP_DATASET_NAME` | `huggingclip-backup` | Dataset name for backup repo |
| `SYNC_INTERVAL` | `180` | Backup interval in seconds |

### Advanced

| Variable | Default | Description |
| :--- | :--- | :--- |
| `PAPERCLIP_DEPLOYMENT_MODE` | `authenticated` | `authenticated` or `local` |
| `BETTER_AUTH_SECRET` | auto-generated | Auth secret (auto-persisted on first boot) |
| `PAPERCLIP_AGENT_JWT_SECRET` | auto-generated | Agent JWT secret (auto-persisted on first boot) |
| `SYNC_MAX_FILE_BYTES` | `52428800` | Max backup size in bytes (50MB default) |
| `CLOUDFLARE_KEEPALIVE_ENABLED` | `true` | Set to `false` to disable the automatic Cloudflare KeepAlive worker |

## 🤖 LLM Providers

Set the relevant API key and Paperclip will use it automatically when you configure agents:

| Provider | Secret | Get Key |
| :--- | :--- | :--- |
| **Anthropic (Claude)** | `ANTHROPIC_API_KEY` | [console.anthropic.com](https://console.anthropic.com) |
| **Google (Gemini)** | `GEMINI_API_KEY` | [ai.google.dev](https://ai.google.dev) |
| **OpenAI (GPT)** | `OPENAI_API_KEY` | [platform.openai.com](https://platform.openai.com) |

You can add multiple providers — Paperclip lets you choose the model per-agent.

## 🌐 Cloudflare Proxy *(Optional)*

Hugging Face Spaces sometimes blocks outbound connections to external APIs. HuggingClip includes the same transparent Cloudflare proxy approach used in HuggingClaw and Hugging8n.

**Automatic setup:**

1. Create a Cloudflare API Token (`Workers Scripts: Edit` permission).
2. Add `CLOUDFLARE_WORKERS_TOKEN` as a Space secret.
3. Restart the Space.

HuggingClip will:

- Create or update a Worker named from your Space host
- Generate a private shared secret automatically
- Transparently route outbound traffic through Cloudflare

| Variable | Default | Description |
| :--- | :--- | :--- |
| `CLOUDFLARE_WORKERS_TOKEN` | — | Cloudflare API token |
| `CLOUDFLARE_ACCOUNT_ID` | auto | Optional account ID override |
| `CLOUDFLARE_PROXY_DOMAINS` | — | Extra domains to proxy, merged with built-in defaults. Set to `*` to proxy all external traffic. |

## 💾 Database Backup *(Optional)*

HuggingClip automatically backs up your Paperclip PostgreSQL database to a private HF Dataset on every sync cycle and restores it on startup.

**What's backed up:**

- Full PostgreSQL SQL dump
- Paperclip config, secrets, and data files
- Packaged as `snapshots/latest.tar.gz` in your `huggingclip-backup` dataset

**Setup:** Add `HF_TOKEN` (write-access token) to Space secrets. The dataset `<your-username>/huggingclip-backup` is created automatically on first sync.

> [!NOTE]
> Without `HF_TOKEN`, the app runs fine but all data is lost on Space restart. Set it up from the start to avoid losing agent configurations.

## 💓 Staying Alive *(Recommended on Free HF Spaces)*

Your Space will automatically be kept awake by a background Cloudflare Worker when you configure the `CLOUDFLARE_WORKERS_TOKEN` secret. The worker uses a cron trigger to regularly ping your Space's `/health` endpoint. The dashboard displays the current keep-alive worker status.

## 💻 Local Development

```bash
git clone https://github.com/somratpro/huggingclip.git
cd huggingclip
cp .env.example .env
# Edit .env with your API keys and HF_TOKEN
```

**With Docker:**

```bash
docker build -t huggingclip .
docker run -p 7861:7861 \
  -e HF_TOKEN=hf_xxxx \
  -e ANTHROPIC_API_KEY=sk-ant-xxxx \
  -v paperclip_data:/paperclip \
  huggingclip
```

**With Docker Compose:**

```bash
docker-compose up -d
# Dashboard: http://localhost:7861/
# Paperclip UI: http://localhost:7861/app/
```

## 🏗️ Architecture

```
HuggingClip/
├── Dockerfile           # Multi-stage build: compile Paperclip from source
├── start.sh             # Orchestrator: PostgreSQL, restore, config, launch
├── health-server.js     # Dashboard, /health endpoint, reverse proxy to Paperclip
├── paperclip-sync.py    # PostgreSQL backup/restore to HF Dataset
├── cloudflare-proxy.js  # Transparent outbound proxy for blocked domains
├── .env.example         # Environment variable reference
└── README.md
```

**Startup sequence:**

1. Validate LLM provider keys (warn if none configured).
2. Start PostgreSQL and create database.
3. Generate or restore auth secrets (persist across restarts).
4. Restore database and data files from HF Dataset backup (if `HF_TOKEN` set).
5. Start background sync loop (every `SYNC_INTERVAL` seconds).
6. Launch health server on port 7861 (dashboard + reverse proxy).
7. Generate Paperclip instance config on first boot.
8. Launch Paperclip server on port 3100.
9. Bootstrap first admin account (shows invite URL in dashboard).
10. On `SIGTERM`, wait for any in-flight sync, run final backup, exit cleanly.

**Port layout:**

| Port | Service | Public? |
| :--- | :--- | :--- |
| `7861` | Health server (dashboard + proxy) | ✅ Yes |
| `3100` | Paperclip API + UI | ❌ Internal only |
| `5432` | PostgreSQL | ❌ Internal only |

## 🐛 Troubleshooting

**No LLM providers configured warning**
Set at least one of `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, or `OPENAI_API_KEY` in Space secrets.

**Admin setup link not showing**
Check Space logs — if Paperclip started but admin setup link is missing, the bootstrap ran but found an existing account. Log in at `/app/`.

**Backup not uploading**
Verify `HF_TOKEN` is set and has write access. Check the dashboard backup status. Run manually: `python3 /app/paperclip-sync.py sync` from inside the container.

**Data lost after restart**
`HF_TOKEN` is not set. Add it and the next restart will restore from backup. The backup also needs to have been run at least once before the restart.

**Space keeps sleeping**
Add `CLOUDFLARE_WORKERS_TOKEN` as a Space secret to enable automatic keep-awake monitoring via Cloudflare Workers.

**Paperclip unreachable (502 errors)**
Wait 60–90s after boot for Paperclip to initialize. If it stays unreachable, check logs for PostgreSQL connection errors or memory issues.

**Backup too large (>50MB)**
Reduce `SYNC_MAX_FILE_BYTES` to skip large backups, or increase it. Alternatively, archive old agent runs inside Paperclip to reduce DB size.

**Stack overflow in recovery chains**
Deep issue-dependency chains (1000+ nodes) created by runaway agents can hit a 500-node limit in the upstream recovery graph traversal. This is patched conservatively in the Dockerfile. File an issue upstream at [paperclipai/paperclip](https://github.com/paperclipai/paperclip) if you need larger chains.

## 🌟 More Projects

Similar projects by [@somratpro](https://github.com/somratpro) — all free, one-click deploy on HF Spaces:

| Project | What it runs | HF Space | GitHub |
| :--- | :--- | :--- | :--- |
| **HuggingFlow** | DeerFlow — deep research agent | [Space](https://huggingface.co/spaces/somratpro/HuggingFlow) | [Repo](https://github.com/somratpro/HuggingFlow) |
| **HuggingMes** | Hermes — Self-hosted agent gateway | [Space](https://huggingface.co/spaces/somratpro/HuggingMes) | [Repo](https://github.com/somratpro/huggingmes) |
| **HuggingClaw** | OpenClaw — Claude Code in the browser | [Space](https://huggingface.co/spaces/somratpro/HuggingClaw) | [Repo](https://github.com/somratpro/huggingclaw) |
| **Hugging8n** | n8n — workflow & automation platform | [Space](https://huggingface.co/spaces/somratpro/Hugging8n) | [Repo](https://github.com/somratpro/hugging8n) |
| **HuggingPost** | Postiz — social media scheduler | [Space](https://huggingface.co/spaces/somratpro/HuggingPost) | [Repo](https://github.com/somratpro/HuggingPost) |

## 📚 Links

- [Paperclip Docs](https://paperclip.ing)
- [Paperclip GitHub](https://github.com/paperclipai/paperclip)
- [HuggingFace Spaces Docs](https://huggingface.co/docs/hub/spaces)

## ❤️ Support

If HuggingClip saves you time, consider buying me a coffee to keep the projects alive!

**USDT (TRC-20 / TRON network only)**

```
TELx8TJz1W1h7n6SgpgGNNGZXpJCEUZrdB
```

> [!WARNING]
> Send **USDT on TRC-20 network only**. Sending other tokens or using a different network will result in permanent loss.

## 🤝 Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## 📄 License

MIT — see [LICENSE](LICENSE) for details.

*Made with ❤️ by [@somratpro](https://github.com/somratpro) for the Paperclip community.*
