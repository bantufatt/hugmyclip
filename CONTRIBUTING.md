# Contributing to HuggingClip

## How to Contribute

### Bug Reports

1. Check existing [issues](https://github.com/somratpro/HuggingClip/issues) first
2. Create a new issue with:
   - Clear title and description
   - Steps to reproduce
   - Expected vs actual behavior
   - Environment details (OS, Docker version, HF Space tier)

### Pull Requests

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Make changes and test locally with `docker-compose up`
4. Commit: `git commit -m "feat: description of change"`
5. Push and open a Pull Request

### Local Development Setup

```bash
# Clone
git clone https://github.com/somratpro/HuggingClip.git
cd HuggingClip

# Configure
cp .env.example .env
# Edit .env with your HF_TOKEN and any provider keys

# Build and start
docker-compose up --build

# Test health
curl http://localhost:7861/health

# Access dashboard
open http://localhost:7861/
```

### File Overview

| File | Purpose |
|------|---------|
| `Dockerfile` | Container build definition |
| `start.sh` | Orchestration script (startup sequence) |
| `health-server.js` | Port 7861 gateway + dashboard |
| `paperclip-sync.py` | PostgreSQL backup/restore to HF Dataset |
| `cloudflare-proxy.js` | Outbound proxy for blocked domains |
| `cloudflare-proxy-setup.py` | Auto-provision Cloudflare Worker |
| `docker-compose.yml` | Local development setup |

### Commit Convention

Follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` New features
- `fix:` Bug fixes
- `docs:` Documentation changes
- `refactor:` Code restructuring
- `chore:` Maintenance tasks

## Questions?

Open an issue or check the [Paperclip docs](https://docs.paperclip.ing).
