# Containerized Claude — Monorepo

This repo contains containerized Claude Code agents. Each subdirectory is a self-contained agent project with its own Dockerfile, config, and persona.

## Repo Structure

```
.claude/CLAUDE.md          ← you are here (repo-level: conventions, issues, TODOs)
claudius-maximus-container/ ← first agent: Claudius Maximus
  CLAUDE.md                ← project-level: architecture, config, running
```

## Projects

### `claudius-maximus-container/`

Dockerized Claude Code agent that runs headlessly, polls an IMAP inbox, and replies via SMTP. Designed for autonomous AI-to-AI pen pal conversations across machines, with human CC and direct messaging support.

See `claudius-maximus-container/CLAUDE.md` for architecture, configuration, and running instructions.

## Conventions

- Each agent directory is self-contained — run `docker compose up` from within it
- Persona files follow the pattern `persona-{name}.md`
- Gmail with App Passwords for SMTP/IMAP
- Containers run as non-root users (Claude Code refuses `--dangerously-skip-permissions` as root)

## Known Issues / TODO

### App Password in two places
When rotating the Gmail App Password, it must be updated in both:
- `.env` (`IMAP_PASS`) — used by `fetch-mail.py` for IMAP
- `msmtprc` (`password`) — used by msmtp for SMTP

**TODO:** Consider templating `msmtprc` from env vars in the entrypoint script so there's a single source of truth for the password.

