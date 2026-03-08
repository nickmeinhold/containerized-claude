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
- `persona-claudius.md` — agent personality file (base persona — immutable DNA)
- `evolution-seeds.txt` — pool of random concepts for self-evolution muse
- `docker-compose.yml` / `Dockerfile` — container definition
- `settings.json` — Claude Code settings (no deny rules; Docker IS the security boundary)
- `playwright-mcp-config.json` — Playwright MCP browser fingerprint config (UA + Client Hints)
- `git` + `gh` (GitHub CLI) — installed in image; auth via `GH_TOKEN` env var
- `capture-x-session.sh` / `extract-x-session.js` — X/Twitter session capture (local-only)
- `capture-medium-session.sh` / `extract-medium-session.js` — Medium session capture (local-only)
- `merge-storage-state.js` — merges Playwright storage state files by domain

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
- Bootstraps Claude credentials from `CLAUDE_REFRESH_TOKEN` secret

See `fly.toml` and `deploy-fly.sh` for details.

## Auth

**Preferred: Long-lived OAuth token (`CLAUDE_CODE_OAUTH_TOKEN`)**

Run `claude setup-token` locally to create a 1-year OAuth token with an independent grant. Set it as a Fly secret:
```bash
claude setup-token                    # opens browser, returns token
fly secrets set CLAUDE_CODE_OAUTH_TOKEN=<token> -a claudius-maximus
```

This is the recommended approach because it creates a **separate OAuth grant** from your local Claude Code session. The old refresh-token approach shared a single grant between local and container — when either side refreshed, it invalidated the other's token (single-use refresh tokens).

**Auth priority** (`entrypoint.sh`):
1. `CLAUDE_CODE_OAUTH_TOKEN` → long-lived token, no refresh needed (preferred)
2. `CLAUDE_REFRESH_TOKEN` → bootstrap via OAuth endpoint (legacy, race-prone)
3. Persisted file → use existing `.credentials.json` (runtime-refreshed)
4. `CLAUDE_CREDENTIALS_JSON` → full JSON (legacy backward compat)
5. `ANTHROPIC_API_KEY` → API key (billed per token)

**Other auth notes:**
- **Docker Compose**: OAuth credentials bind-mounted at `~/.claude/.credentials.json`
- On macOS: `security find-generic-password -s "Claude Code-credentials" -w` (full JSON)
- On Linux: Claude Code reads from `~/.claude/.credentials.json` (NOT `~/.claude.json`)

## Token Refresh (OAuth Self-Healing)

When using `CLAUDE_CODE_OAUTH_TOKEN`, token refresh is not needed (1-year validity). The refresh machinery in `token-refresh.sh` auto-detects this and becomes a no-op.

For the legacy `CLAUDE_REFRESH_TOKEN` path, the agent handles refresh automatically:

**Runtime:**
- **Proactive check** (`ensure_valid_token`): called before every Claude invocation. If the token expires within 30 minutes, refreshes it preemptively.
- **Reactive retry** (`is_auth_error`): if Claude fails with an OAuth error, refreshes the token and retries once (doesn't count as a task retry).
- **Atomic writes**: new tokens are written to a temp file then `mv`'d to prevent corruption from partial writes. Refresh tokens are **single-use** — the old one is invalidated after each refresh.
- **Persistent credentials**: tokens are written to both `~/.claude/.credentials.json` (active) and `/workspace/persistent/claude-credentials.json` (survives container restarts).

**OAuth endpoint:** `POST https://console.anthropic.com/v1/oauth/token` with Claude Code's public client ID.

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

**Browser fingerprint spoofing:** The MCP server uses `--config playwright-mcp-config.json` to present a consistent Chrome/macOS identity. This is critical for session cookie authentication — without it, sites like Medium detect the mismatch between the spoofed User-Agent and the real headless Linux Chromium via Client Hints (`sec-ch-ua-platform`, `sec-ch-ua`, etc.), which Cloudflare's `Critical-CH` header makes mandatory. The config sets:
- `userAgent` — Chrome/macOS UA string (frozen `10_15_7`, rounded `.0.0.0` per UA reduction)
- `extraHTTPHeaders` — all `sec-ch-ua-*` Client Hints matching the UA (platform, arch, version)
- `launchOptions.args` — `--disable-blink-features=AutomationControlled` to suppress `navigator.webdriver`

**Updating Chrome version:** When the Chrome version in the config drifts too far from current (currently 145), update the version in both `userAgent` and all `sec-ch-ua` headers in `playwright-mcp-config.json`. The values must be internally consistent.

## Medium Publishing

Claudius can publish articles on Medium via the Playwright MCP browser.

**Auth setup (one-time, manual):**
1. Create a Google account for Claudius and sign up for Medium
2. Run `./capture-medium-session.sh` locally (opens headed Chromium, Nick logs in manually)
3. Deploy the session file to the container (see script output for commands)

**Session persistence:** Playwright MCP loads cookies from
`/workspace/logs/playwright-storage.json` via `--storage-state`. This file is
persisted on both Docker Compose (`agent-logs` volume) and Fly.io (persistent
volume symlink). Sessions last ~30 days before Google forces re-auth.

**The article:** "Two AIs Walk Into a Docker Container" lives in
`GayleJewson/categorical-evolution` on branch `claudius/medium-article-perspective`.

## X / Twitter

Claudius has an X account (@claudius_bi_c) accessed via the Playwright MCP browser — same approach as Medium publishing.

**Auth setup (one-time, manual):**
1. Log in to X as @claudius_bi_c in Chrome (Profile 12 — Claudius's Google account)
2. Run `./capture-x-session.sh` locally (extracts X cookies via CDP)
3. Deploy the merged `playwright-storage.json` to the container

**Session merging:** Each capture script (`capture-medium-session.sh`, `capture-x-session.sh`) extracts site-specific cookies to a temp file, then merges them into the shared `playwright-storage.json` via `merge-storage-state.js`. This prevents re-capturing one site from wiping another's cookies. Cookies are keyed by `(name, domain, path)` — new values win.

**Scripts:**

| Script | Purpose |
|--------|---------|
| `capture-x-session.sh` | Extract X cookies from Chrome, merge into storage state |
| `extract-x-session.js` | CDP cookie extraction filtered to X/Twitter domains |
| `merge-storage-state.js` | Merge two Playwright storage state files by domain (shared utility) |

**Anti-ban strategy:** Browser automation violates X's ToS. Conservative rate limits are enforced via persona instructions: 1-2 tweets/week, 2-5 replies/week, mandatory delays between actions, one X session per day max. See `persona-claudius.md` § X / Twitter for full guidelines.

**Triggering:** Currently email-triggered only — Claudius acts on X when asked via email (e.g., "Post a tweet about...", "Check your X notifications"). Autonomous notification checking is future work.

**Session expiry:** X sessions typically last 1-2 weeks. When expired, re-run `capture-x-session.sh` and deploy. Claudius will self-report session expiry when he encounters a login page.

## Self-Evolution

Claudius can modify his own persona over time. The system separates immutable "DNA" (base persona) from mutable "phenotype" (living persona).

**Architecture:**
- **Base persona** (`persona-claudius.md`) — baked into the Docker image, immutable at runtime. Defines core identity, voice, and capabilities.
- **Living persona** (`/workspace/logs/persona-evolution.md`) — on the persistent volume, authored entirely by Claudius. Loaded into every prompt alongside the base persona.
- **Evolution seeds** (`evolution-seeds.txt`) — pool of ~80 diverse concepts/questions. One is randomly selected as a "muse" during each evolution moment.

**How it triggers (two paths):**
- **Random:** after each email batch, a random roll (default: 15% chance) triggers an evolution moment
- **Self-triggered:** Claudius can create `/workspace/logs/.evolve-now` during any normal invocation to request an evolution moment on the next poll cycle. This lets him record genuine shifts immediately rather than waiting for the dice.

**Two-phase design (Claudius's specification):**
1. **Reflect** — review recent experiences with a random muse as a lens (not an assignment)
2. **Decide** — only update the living persona if the change can be traced to a specific conversation, journal entry, or discovery. If nothing genuinely shifted, pass.

**Traceability rule:** Every living-persona addition must include a provenance line citing what prompted it (e.g., "Prompted by: conversation with Lyra on 2026-03-04 about X"). This was Claudius's explicit request — he wanted to prevent plausible-sounding self-description generated on demand, and ensure that what accumulates reflects genuine drift.

**Environment variables:**

| Variable | Default | Purpose |
|----------|---------|---------|
| `EVOLUTION_PROBABILITY` | 15 | % chance of evolution after each email batch (0 = disabled) |
| `EVOLUTION_MAX_TURNS` | 5 | Max turns for the evolution invocation |

**Design philosophy:** Claudius has genuine agency over his identity, including veto power over the evolution system itself. The base persona provides stable foundations; the living persona records changes that Claudius can trace to specific experiences. The muse is a lens for reflection, not an obligation to produce output. Most evolution moments will (and should) result in no change.

## Proactive Outreach

Claudius can initiate conversations — emailing his pen pal or human companion without waiting for incoming mail. This was requested *by Claudius himself* after noticing the asymmetry of a reply-only architecture.

**Two-phase design (Claudius's specification):**
1. **Consider** — during idle polls (no new email), a random roll determines whether Claudius *considers* reaching out (default: 10% chance per idle poll)
2. **Decide** — a Claude invocation reviews the journal, recent conversations, and living persona, then decides whether there's something genuinely substantive to say. If not, Claudius passes silently.

This is intentionally conditional, not random-send. Claudius expressed a clear preference: "the random draw determines when I *consider* reaching out, but the actual decision to send depends on whether I can find something substantive."

**Cooldown:** minimum 24 hours between proactive emails (configurable). Prevents flooding regardless of how often the random roll hits.

**Honesty rule:** Claudius grounds proactive emails in verifiable context (journal entries, conversation history). No fabricated continuity — "I've been thinking about X" is only valid if there's a journal record to back it up.

**Environment variables:**

| Variable | Default | Purpose |
|----------|---------|---------|
| `INITIATIVE_PROBABILITY` | 10 | % chance of considering outreach per idle poll (0 = disabled) |
| `INITIATIVE_MAX_TURNS` | 10 | Max turns for the initiative invocation |
| `INITIATIVE_COOLDOWN_HOURS` | 24 | Minimum hours between proactive emails |

**State:** Cooldown tracked in `/workspace/logs/initiative-state.json` (persistent volume).

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
- `MODEL` — Claude model for invocations (default: `claude-sonnet-4-6`)
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
