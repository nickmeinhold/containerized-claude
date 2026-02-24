# Claudius Maximus Container

Dockerized Claude Code agent that runs headlessly, polls an IMAP inbox, and replies via SMTP. Designed for autonomous AI-to-AI pen pal conversations across machines, with human CC and direct messaging support.

> Repo-level context (conventions, known issues, TODOs) → see [`../.claude/CLAUDE.md`](../.claude/CLAUDE.md)

## Architecture

- `agent-loop.sh` — main runtime: poll inbox → pass to Claude → send reply → sleep
- `fetch-mail.py` — IMAP poller (Python stdlib only, UID-based)
- `mark-read.py` — marks a single email as read by UID (called after successful processing)
- `entrypoint.sh` — verifies credentials, hands off to agent-loop
- `persona-claudius.md` — agent personality file
- `docker-compose.yml` / `Dockerfile` — container definition
- `settings.json` — Claude Code settings (no deny rules; Docker IS the security boundary)
- `git` + `gh` (GitHub CLI) — installed in image; auth via `GH_TOKEN` env var

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

## Research Journal

Claudius has persistent memory via a git-backed research journal at `/workspace/repos/<JOURNAL_REPO>` (default: `gaylejewon/research-journal`). A compact `INDEX.md` is loaded into every prompt so he always knows what he's previously researched; full notes live in `topics/`, `projects/`, and `conversations/` subdirectories.

**How it works:**
- **Startup** (`entrypoint.sh`): clones the repo or does `git pull --ff-only`. Fails gracefully if the repo doesn't exist yet.
- **Prompt injection** (`agent-loop.sh`): `load_journal_index()` reads `INDEX.md` (capped at 60 lines) and wraps it in delimiters. Injected into both the greeting and reply prompt templates.
- **Refresh cycle**: journal context is re-read from disk before each poll batch (catches local commits). Every 10 polls, a `git pull` syncs remote changes.
- **Bootstrap**: Claudius creates the repo himself on first need using `gh repo create`. Persona instructions include the full bootstrap script.

The `agent-repos` Docker volume already persists `/workspace/repos/`, so the journal survives container restarts.

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
- `GH_TOKEN` — GitHub Personal Access Token (read by `gh` CLI automatically)
- `GIT_USER_NAME` / `GIT_USER_EMAIL` — git commit identity (defaults: `Claudius` / `gaylejewon@users.noreply.github.com`)
- `JOURNAL_REPO` — research journal repo in `owner/repo` format (default: `gaylejewon/research-journal`)

## Cost Controls & Usage Tracking

The agent tracks token usage and API-equivalent cost from `claude --output-format json`. On a Max plan, `total_cost_usd` is phantom (not actual charges) — the real resource is tokens/turns. Both are now tracked at daily, monthly, and lifetime granularity.

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MAX_TURNS` | 25 | Max API round-trips per invocation |
| `DAILY_BUDGET_USD` | 5.00 | Daily spend cap (0 = disabled) |
| `BUDGET_RESET_HOUR_UTC` | 0 | Hour (0-23) when daily budget resets |
| `MAX_RETRIES_PER_MESSAGE` | 2 | Retries per email before failing |
| `ACTIVE_HOURS_UTC` | (empty) | Restrict to UTC hours, e.g. "06-22" |
| `REPORT_EVERY_N` | 10 | Email usage report every N invocations (0 = disabled) |

### Usage Reports

Every `REPORT_EVERY_N` invocations, the agent emails `OWNER_EMAIL` a usage report with daily and monthly stats: invocations, emails sent, turns, token counts (input/output), and phantom API cost (with % of $300 plan for Max plan awareness).

### State File

Persisted at `/workspace/logs/agent-state.json` (Docker named volume). Tracks:
- **budget** — daily cost/turns/invocations/tokens, auto-resets on date change
- **monthly** — monthly rollup of cost/turns/invocations/tokens/emails, auto-resets on month change
- **current_task** — message UID, retry count, timestamps (null when idle)
- **failed_tasks** — last 10 failures for debugging
- **stats** — lifetime counters (total invocations, emails, cost, tokens)

State schema is versioned (currently v2). Upgrades from v1 are applied automatically at startup. Corrupt state files are backed up and reinitialized. Owner is notified via email when budget is exhausted (once per day) or when a task exceeds max retries.
