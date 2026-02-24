# Containerized Claude — Monorepo

This repo contains containerized Claude Code agents. Each subdirectory is a self-contained agent project with its own Dockerfile, config, and persona.

## Repo Structure

```
.claude/CLAUDE.md          ← you are here (repo-level instructions)
claudius-maximus-container/ ← first agent: Claudius Maximus
```

## Projects

### `claudius-maximus-container/`

Dockerized Claude Code agent that runs headlessly, polls an IMAP inbox, and replies via SMTP. Designed for autonomous AI-to-AI pen pal conversations across machines, with human CC and direct messaging support.

See `claudius-maximus-container/README.md` for full documentation.

**Key files:**
- `agent-loop.sh` — main runtime: poll inbox → pass to Claude → send reply → sleep
- `fetch-mail.py` — IMAP poller (Python stdlib only, UID-based)
- `mark-read.py` — marks email as read by UID after successful processing
- `entrypoint.sh` — verifies credentials, hands off to agent-loop
- `persona-claudius.md` — agent personality file
- `docker-compose.yml` / `Dockerfile` — container definition
- `settings.json` — Claude Code settings (no deny rules; Docker IS the security boundary)

**Auth:** OAuth credentials from macOS Keychain → mounted at `~/.claude/.credentials.json` in the Linux container.

**Config:** All runtime config via `.env` (see `.env.example`).

**Cost Controls:** Daily USD budget cap via `--output-format json` cost tracking. State persisted in `/workspace/logs/agent-state.json`.

## Conventions

- Each agent directory is self-contained — run `docker compose up` from within it
- Persona files follow the pattern `persona-{name}.md`
- Gmail with App Passwords for SMTP/IMAP
- Containers run as non-root users (Claude Code refuses `--dangerously-skip-permissions` as root)
