# Claudius Maximus Container

Dockerized Claude Code agent that runs headlessly, polls an IMAP inbox, and replies via SMTP. Designed for autonomous AI-to-AI pen pal conversations across machines, with human CC and direct messaging support.

> Repo-level context (conventions, known issues, TODOs) → see [`../.claude/CLAUDE.md`](../.claude/CLAUDE.md)

## Architecture

- `agent-loop.sh` — main runtime: poll inbox → pass to Claude → send reply → sleep
- `token-refresh.sh` — OAuth token refresh library (sourced by agent-loop)
- `archive-email.sh` — email archive library (sourced by agent-loop)
- `backfill-archive.py` — one-time IMAP export for historical emails
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

**Live deployment:** app `claudius-maximus` in Singapore (`sin`), `shared-cpu-1x` 1024MB, 1GB encrypted volume. ~$5/mo.

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

## Email Archive

Every email (incoming and outgoing) is saved as a markdown file with YAML frontmatter in a dedicated GitHub repo set by `ARCHIVE_REPO` (e.g., `gaylejewon/claudius-lyra-emails`). This provides a permanent, version-controlled, browseable record of all conversations.

**Archive format:** Files are organized by `YYYY/MM/` and named with UTC timestamps:
```
2026/02/2026-02-24T083012Z-incoming-the-nature-of-consciousness.md
2026/02/2026-02-24T084530Z-outgoing-re-the-nature-of-consciousness.md
```

Each file has YAML frontmatter with direction, UID, date, from/to, and subject.

**How it works:**
- **Startup** (`entrypoint.sh`): clones the repo via `gh`, or creates it as a private repo if it doesn't exist. Falls back gracefully if archiving is disabled (`ARCHIVE_REPO` empty).
- **Incoming emails** (`agent-loop.sh`): `archive_incoming` writes a markdown file immediately after logging to `conversation.log`.
- **Outgoing emails** (`agent-loop.sh`): `archive_outgoing` reads `/tmp/reply.txt` (where Claude writes its reply) and archives it after successful processing.
- **Batch push**: `push_archive` commits and pushes every 10 polls (same cadence as journal sync). Not per-email, to avoid hammering GitHub.
- **Graceful degradation**: if the repo is unavailable or `ARCHIVE_REPO` is unset, archiving is silently skipped. Email processing continues normally.

**Backfill script** (`backfill-archive`): one-time Python script to import historical emails from Gmail IMAP. Fetches from both INBOX and `[Gmail]/Sent Mail`, deduplicates by UID against existing archive files. Safe to re-run.
```bash
# Preview what would be archived
backfill-archive --dry-run

# Run for real (then commit+push manually)
backfill-archive
cd /workspace/repos/<ARCHIVE_REPO>
git add -A && git commit -m "backfill: historical emails" && git push
```

## Email Attachments

Email attachments (text, code, PDFs, and images) are extracted, saved to disk, and presented to Claude for reading via the multimodal Read tool. Unsupported binary types (zips, archives, executables) are noted in metadata but not processed.

**Pipeline:**
```
Email with attachments
  → fetch-mail.py: extract + save processable files to /workspace/attachments/<uid>/
  → agent-loop.sh: build ATTACHMENTS_CONTEXT block → inject into prompt
  → Claude: reads files via Read tool, summarizes in reply, journals to research-journal
```

**Progressive disclosure (3 levels):**
1. **INDEX.md one-liner** — always loaded into prompt. Reminds Claudius an attachment exists.
2. **Journal detail file** (`attachments/<slug>.md`) — summary, key points, personal notes.
3. **Original file on disk** (`/workspace/attachments/<uid>/<filename>`) — full content for re-reading.

**Safety measures:**
- Filename sanitization: `os.path.basename()` + regex stripping of special chars (directory traversal protection)
- Size limit: `MAX_ATTACHMENT_SIZE` (default 5MB) — files over this are skipped
- Type filtering: text, code, PDFs, and images are saved; other binary types get metadata-only
- Per-UID subdirectories prevent filename collisions across emails
- Counter suffix handles collisions within the same email

**Persistence:**
- Docker Compose: `agent-attachments` named volume at `/workspace/attachments`
- Fly.io: symlinked into `/workspace/persistent/attachments` on the encrypted volume

**Environment variables:**
| Variable | Default | Purpose |
|----------|---------|---------|
| `ATTACHMENT_DIR` | `/workspace/attachments` | Directory for saved attachment files |
| `MAX_ATTACHMENT_SIZE` | `5242880` | Max size in bytes per attachment (5MB) |

## Web Browsing (Playwright MCP)

Claudius has a headless Chromium browser via the [Playwright MCP server](https://github.com/anthropics/mcp-playwright). This enables interactive web research — navigating pages, reading dynamic content, clicking links, filling forms, and taking screenshots.

**How it works:**
- The `@playwright/mcp` package runs as an MCP server, started automatically by Claude Code when a Playwright tool is first invoked.
- Chromium is pre-installed in the Docker image at `/opt/pw-browsers` (set via `PLAYWRIGHT_BROWSERS_PATH`).
- The MCP server runs with `--headless` — no display required.
- All 22+ Playwright tools (`browser_navigate`, `browser_click`, `browser_snapshot`, `browser_take_screenshot`, etc.) are auto-allowed via the `mcp__playwright__*` wildcard in `settings.json`.

**Resource impact:**
- **Image size:** ~400MB larger (Chromium + system deps)
- **Runtime memory:** Chromium peaks at 150-300MB per page; `fly.toml` bumps VM memory from 512MB → 1024MB
- **Shared memory:** `docker-compose.yml` sets `shm_size: 256m` (Docker defaults 64MB, which crashes Chromium)
- **Fly.io cost:** ~$5/mo (up from ~$3/mo for the memory bump)

**Key tools available:**
| Tool | Purpose |
|------|---------|
| `browser_navigate` | Go to a URL |
| `browser_snapshot` | Get page accessibility tree (text content) |
| `browser_take_screenshot` | Capture visual screenshot |
| `browser_click` | Click an element |
| `browser_fill_form` | Fill in form fields |
| `browser_evaluate` | Run JavaScript on the page |

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
- `ARCHIVE_REPO` — email archive repo in `owner/repo` format (empty = disabled)

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
