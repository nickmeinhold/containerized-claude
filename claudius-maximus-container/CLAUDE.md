# Claudius Maximus Container

Dockerized Claude Code agent that runs headlessly, polls an IMAP inbox, and replies via SMTP. Designed for autonomous AI-to-AI pen pal conversations across machines, with human CC and direct messaging support.

## Architecture

- `agent-loop.sh` — main runtime: poll inbox → pass to Claude → send reply → sleep
- `fetch-mail.py` — IMAP poller (Python stdlib only, UID-based)
- `mark-read.py` — marks a single email as read by UID (called after successful processing)
- `entrypoint.sh` — verifies credentials, hands off to agent-loop
- `persona-claudius.md` — agent personality file

## Running

All `docker compose` commands must be run from this directory (`claudius-maximus-container/`), since this is where `docker-compose.yml` and the Dockerfile build context live.

```bash
cd claudius-maximus-container
docker compose up          # start (foreground)
docker compose up -d       # start (detached)
docker compose up --build  # rebuild and start
docker compose logs -f     # tail logs
docker compose down        # stop
```

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

## Outstanding Review Issues

These were identified in code review and should be addressed:

### Blocking
1. ~~**Prompt injection**~~ — **Mitigated** by `ALLOWED_SENDERS` allowlist (defense-in-depth). Both `fetch-mail.py` and `agent-loop.sh` independently reject emails from senders not in the allowlist. Fail-closed: if `ALLOWED_SENDERS` is empty/unset, all emails are rejected.
2. ~~**No `--max-turns`**~~ — **Resolved.** Both Claude calls pass `--max-turns`, daily USD budget caps total spend via `--output-format json` cost tracking.

### Non-blocking (all resolved)
- [x] `while read` subshell — replaced pipe with process substitution so variables propagate
- [x] `tail -c 4000` UTF-8 truncation — replaced with `tail -n 80` (line-based)
- [x] `run-single.sh` unsafe `source .env` — replaced with safe line-by-line reader
- [x] `claude-config/` gitignored but Dockerfile COPYs it — now COPYs from `.claude/` (committed)
- [x] `mark-read` wired up after successful Claude processing

## Cost Controls

The agent tracks real dollar costs using `claude --output-format json`, which returns `total_cost_usd` and `num_turns` per invocation.

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MAX_TURNS` | 25 | Max API round-trips per invocation |
| `DAILY_BUDGET_USD` | 5.00 | Daily spend cap (0 = disabled) |
| `BUDGET_RESET_HOUR_UTC` | 0 | Hour (0-23) when daily budget resets |
| `MAX_RETRIES_PER_MESSAGE` | 2 | Retries per email before failing |
| `ACTIVE_HOURS_UTC` | (empty) | Restrict to UTC hours, e.g. "06-22" |

### State File

Persisted at `/workspace/logs/agent-state.json` (Docker named volume). Tracks:
- **budget** — daily cost/turns/invocations, auto-resets on date change
- **current_task** — message UID, retry count, timestamps (null when idle)
- **failed_tasks** — last 10 failures for debugging
- **stats** — lifetime counters (total invocations, emails, cost)

Corrupt state files are automatically backed up and reinitialized. Owner is notified via email when budget is exhausted (once per day) or when a task exceeds max retries.
