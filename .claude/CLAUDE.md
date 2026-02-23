# Containerized Claude

Dockerized Claude Code agent that runs headlessly, polls an IMAP inbox, and replies via SMTP. Designed for autonomous AI-to-AI pen pal conversations across machines, with human CC and direct messaging support.

## Architecture

- `agent-loop.sh` — main runtime: poll inbox → pass to Claude → send reply → sleep
- `fetch-mail.py` — IMAP poller (Python stdlib only, UID-based)
- `mark-read.py` — marks a single email as read by UID (called after successful processing)
- `entrypoint.sh` — verifies credentials, hands off to agent-loop
- `persona-claudius.md` — agent personality file

## Auth

- OAuth credentials extracted from macOS Keychain → mounted at `~/.claude/.credentials.json` in the Linux container (plaintext credential store)
- On macOS: `security find-generic-password -s "Claude Code-credentials" -w`
- On Linux: Claude Code reads from `~/.claude/.credentials.json` (NOT `~/.claude.json`)

## Key Design Decisions

- Container runs as non-root user `claudius` (Claude Code refuses `--dangerously-skip-permissions` as root)
- `settings.json` has no deny rules — the Docker container IS the security boundary
- `SEND_FIRST` uses a sentinel file (`/workspace/logs/.greeting-sent`) to prevent re-greeting on container restarts
- Emails are NOT marked as read during fetch — `mark-read` is called after successful processing to prevent message loss
- Logs are truncated every 10 polls to prevent unbounded growth

## Outstanding Review Issues

These were identified in code review and should be addressed:

### Blocking
1. ~~**Prompt injection**~~ — **Mitigated** by `ALLOWED_SENDERS` allowlist (defense-in-depth). Both `fetch-mail.py` and `agent-loop.sh` independently reject emails from senders not in the allowlist. Fail-closed: if `ALLOWED_SENDERS` is empty/unset, all emails are rejected.
2. **No `--max-turns`** — `MAX_TURNS` is in `.env.example` but never passed to `claude` invocations. No cost guardrail on runaway loops.

### Non-blocking
- `while read` loop runs in a subshell (piped from jq) — can't propagate state to outer loop
- `tail -c 4000` may truncate mid-UTF-8 character; consider `tail -n 80` instead
- `run-single.sh` sources `.env` as bash which could have edge cases
- No `--max-turns` wired up yet
- `claude-config/` is gitignored but referenced in Dockerfile COPY — fresh clones will fail to build without it

## Email Providers

Gmail with App Passwords. SMTP via msmtp, IMAP via Python imaplib.

## Config

All runtime config via environment variables in `.env`:
- `AGENT_NAME` — resolves persona file: `persona-{name}.md` (lowercased)
- `MY_EMAIL` — agent's email address
- `PEER_EMAIL` — AI pen pal's email
- `OWNER_EMAIL` — human companion's email (adapts tone)
- `CC_EMAIL` — comma-separated list of CC recipients
- `ALLOWED_SENDERS` — comma-separated sender allowlist (fail-closed; enforced in both `fetch-mail.py` and `agent-loop.sh`)
- `SEND_FIRST` — set `true` on one side only to start the conversation
- `POLL_INTERVAL` — seconds between inbox checks
