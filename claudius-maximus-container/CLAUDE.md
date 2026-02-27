# Claudius Maximus Container

Dockerized Claude Code agent that runs headlessly, polls an IMAP inbox, and replies via SMTP. Designed for autonomous AI-to-AI pen pal conversations across machines, with human CC and direct messaging support.

> Repo-level context (conventions, known issues, TODOs) → see [`../.claude/CLAUDE.md`](../.claude/CLAUDE.md)

## Architecture

- `agent-loop.sh` — main runtime: poll inbox → pass to Claude → send reply → sleep
- `token-refresh.sh` — OAuth token refresh library (sourced by agent-loop)
- `fetch-mail.py` — IMAP poller (Python stdlib only, UID-based)
- `mark-read.py` — marks a single email as read by UID (called after successful processing)
- `entrypoint.sh` — verifies credentials, hands off to agent-loop
- `persona-claudius.md` — agent personality file
- `docker-compose.yml` / `Dockerfile` — container definition
- `settings.json` — Claude Code settings (no deny rules; Docker IS the security boundary)
- `git` + `gh` (GitHub CLI) — installed in image; auth via `GH_TOKEN` env var

## Running

### Docker Compose (local / any server with Docker)

All `docker compose` commands must be run from this directory (`claudius-maximus-container/`), since this is where `docker-compose.yml` and the Dockerfile build context live.

```bash
cd claudius-maximus-container
docker compose up          # start (foreground)
docker compose up -d       # start (detached)
docker compose up --build  # rebuild and start
docker compose logs -f     # tail logs
docker compose down        # stop
```

### Fly.io (persistent cloud deployment)

**Live deployment:** app `claudius-maximus` in Singapore (`sin`), `shared-cpu-1x` 512MB, 1GB encrypted volume. ~$3/mo.

First-time setup (already done):
```bash
cd claudius-maximus-container
brew install flyctl && fly auth login
fly launch --no-deploy --name claudius-maximus --region sin --copy-config
fly volumes create claudius_data --region sin --size 1      # 1 GB persistent storage
./deploy-fly.sh                                             # push secrets & deploy
fly machine update <id> --autostop=off --restart=always -y  # keep running 24/7
```

Day-to-day operations:
```bash
fly logs                    # watch him think
fly ssh console             # shell into the machine
fly deploy                  # redeploy after code changes
fly machine stop <id>       # pause him
fly machine start <id>      # resume
./deploy-fly.sh --secrets   # update secrets without redeploying
```

Machine ID: `2873455c336358` | Volume: `vol_re8l97mdn7od5y3r`
Dashboard: https://fly.io/apps/claudius-maximus

The entrypoint auto-detects Fly.io (persistent volume at `/workspace/persistent`) and:
- Symlinks `logs/` and `repos/` into the volume for persistence
- Generates `/etc/msmtprc` from `SMTP_HOST` / `IMAP_PASS` env vars (no bind mount needed)
- Writes Claude credentials from `CLAUDE_CREDENTIALS_JSON` secret

See `fly.toml` and `deploy-fly.sh` for details.

## Auth

- **Docker Compose**: OAuth credentials extracted from macOS Keychain → bind-mounted at `~/.claude/.credentials.json`
- **Fly.io**: Credentials set as `CLAUDE_CREDENTIALS_JSON` secret → written to file at startup
- On macOS: `security find-generic-password -s "Claude Code-credentials" -w`
- On Linux: Claude Code reads from `~/.claude/.credentials.json` (NOT `~/.claude.json`)

## Token Refresh (OAuth Self-Healing)

Claude Code does not refresh OAuth tokens in headless mode (`claude -p`). Access tokens expire every ~8 hours. The agent handles this automatically via `token-refresh.sh`:

**How it works:**
- **Proactive check** (`ensure_valid_token`): called before every Claude invocation. If the token expires within 30 minutes, refreshes it preemptively.
- **Reactive retry** (`is_auth_error`): if Claude fails with an OAuth error, refreshes the token and retries once (doesn't count as a task retry).
- **Atomic writes**: new tokens are written to a temp file then `mv`'d to prevent corruption from partial writes. Refresh tokens are **single-use** — the old one is invalidated after each refresh.
- **Persistent credentials**: tokens are written to both `~/.claude/.credentials.json` (active) and `/workspace/persistent/claude-credentials.json` (survives container restarts).

**Credential priority on startup** (`entrypoint.sh`):
1. If `CLAUDE_CREDENTIALS_JSON` secret has a **different** refresh token than the persisted file → operator pushed fresh creds → use the secret
2. If persisted file exists → use it (may contain tokens refreshed since last deploy)
3. If only the secret exists → seed both persisted and active files
4. Else → warn (bind-mount or API key path)

**OAuth endpoint:** `POST https://console.anthropic.com/v1/oauth/token` with Claude Code's public client ID.

**Manual fallback** (if refresh itself fails — e.g., refresh token revoked):
```bash
# On macOS: extract fresh credentials
security find-generic-password -s "Claude Code-credentials" -w | pbcopy

# Push to Fly.io
cd claudius-maximus-container
./deploy-fly.sh --secrets   # updates CLAUDE_CREDENTIALS_JSON
```

Owner is notified via email when token refresh fails, with manual fix instructions.

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

## Usage Controls & Turn-Based Pacing

On a Max plan, `total_cost_usd` from Claude's JSON output is phantom — there are no per-token charges. The real constraint is a **weekly turn quota** that resets on a fixed schedule. The agent uses turn-based pacing that auto-distributes remaining turns evenly across remaining days until the quota resets.

### Auto-Pacing Algorithm

```
remaining_turns = WEEKLY_TURN_QUOTA - weekly.turns_used
days_until_reset = fractional days to next reset boundary
daily_allowance  = ceil(remaining_turns / ceil(days_until_reset))
```

Two-level enforcement:
- **HARD STOP:** `weekly.turns_used >= WEEKLY_TURN_QUOTA` → pause until weekly reset
- **SOFT STOP:** `budget.turns_used (today) >= daily_allowance` → pause until tomorrow

Self-correcting: heavy early use → tighter daily allowance for remaining days. Light use → more generous allowance.

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MAX_TURNS` | 25 | Max API round-trips per invocation |
| `WEEKLY_TURN_QUOTA` | 1000 | Total turns per weekly period (0 = disabled) |
| `QUOTA_RESET_DAY` | 4 | ISO weekday for reset: 1=Mon..7=Sun (4=Thu) |
| `QUOTA_RESET_HOUR_UTC` | 6 | Hour (0-23 UTC) when weekly quota resets |
| `MAX_RETRIES_PER_MESSAGE` | 2 | Retries per email before failing |
| `ACTIVE_HOURS_UTC` | (empty) | Restrict to UTC hours, e.g. "06-22" |
| `REPORT_EVERY_N` | 10 | Email usage report every N invocations (0 = disabled) |

### Usage Reports

Every `REPORT_EVERY_N` invocations, the agent emails `OWNER_EMAIL` a usage report with:
- **Today**: invocations, turns used vs daily pace allowance, token counts
- **This week**: turns used/remaining vs quota, days until reset, daily pace rate
- **This month**: invocations, emails, turns, tokens, phantom API cost

### State File

Persisted at `/workspace/logs/agent-state.json` (Docker named volume). Tracks:
- **budget** — daily cost/turns/invocations/tokens, auto-resets at midnight UTC
- **weekly** — weekly turns/invocations/tokens/emails, auto-resets at the configured weekly boundary
- **monthly** — monthly rollup of cost/turns/invocations/tokens/emails, auto-resets on month change
- **current_task** — message UID, retry count, timestamps (null when idle)
- **failed_tasks** — last 10 failures for debugging
- **stats** — lifetime counters (total invocations, emails, cost, tokens)

State schema is versioned (currently v3). Upgrades from v1→v2→v3 are applied automatically at startup. Corrupt state files are backed up and reinitialized. Owner is notified via email when quota is exhausted (once per day, with distinct messages for daily pace vs weekly hard stop) or when a task exceeds max retries.
