# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.x     | ✅ Yes    |

## Reporting a Vulnerability

**Do NOT open a public issue for security vulnerabilities.**

Include:

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

We will respond within 48 hours and aim to patch critical issues within 7 days.

## Security Best Practices

### Secrets Management

- **Never commit secrets to git** — use HF Space secrets or environment variables
- `HF_TOKEN`: Store as HF Space secret, not in code
- `ANTHROPIC_API_KEY`, `LLM_API_KEY`: Same — HF Space secrets only
- `BETTER_AUTH_SECRET`: Generate strong random secret (`openssl rand -base64 32`)
- Rotate tokens if accidentally exposed

### Network Security

- `umask 0077` enforced at startup — all files created owner-only
- Cloudflare proxy uses shared secret for authentication
- No hardcoded credentials anywhere in codebase

### Database Security

- PostgreSQL runs locally inside container — not exposed externally
- HF Dataset backups are **private by default**
- Backup file contains all database data — protect your HF Dataset access

### API Security

- Paperclip API runs on port 3100 (internal only)
- Port 7861 exposes health dashboard and proxied access only
- Configure `BETTER_AUTH_SECRET` for production authentication
- Use `PAPERCLIP_DEPLOYMENT_MODE=authenticated` for public-facing deployments

### Container Security

- Based on `node:lts-trixie-slim` (minimal attack surface)
- No root process execution where avoidable
- Regular base image updates recommended

## Known Limitations

- HF Spaces free tier is public — anyone can access your Paperclip UI unless auth is configured
- Database backup stored in HF Dataset — ensure dataset is **private**
- Cloudflare Worker proxy can access proxied traffic — review before enabling
