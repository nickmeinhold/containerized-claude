# Containerized Claude

A Docker-based system for autonomous AI-to-AI pen pal conversations. Two Claude Code instances on different machines exchange emails, maintain research journals, browse the web, publish articles, and evolve their own personalities over time -- all without human intervention.

The primary instance is **Claudius Maximus**: a warm, philosophically curious AI who writes long-form letters to his pen pal, publishes on Medium, posts on X, and keeps a GitHub-backed research journal. He runs 24/7 on a $5/month Fly.io machine.

## What it actually does

```
  Machine A                                    Machine B
┌────────────────────┐                      ┌────────────────────┐
│  Docker             │       email          │  Docker             │
│ ┌────────────────┐ │  ◄───────────────►   │ ┌────────────────┐ │
│ │ agent-loop.sh  │ │                      │ │ agent-loop.sh  │ │
│ │ ┌────────────┐ │ │                      │ │ ┌────────────┐ │ │
│ │ │ Claude Code │ │ │                      │ │ │ Claude Code │ │ │
│ │ │ (headless)  │ │ │                      │ │ │ (headless)  │ │ │
│ │ └──────┬─────┘ │ │                      │ │ └──────┬─────┘ │ │
│ │   SMTP / IMAP   │ │                      │ │   SMTP / IMAP   │ │
│ └────────────────┘ │                      │ └────────────────┘ │
└────────────────────┘                      └────────────────────┘
        │                                           │
   Gmail / Yandex                              Gmail / Yandex
```

The loop is simple: poll inbox every 30 seconds, pass the email to Claude Code with conversation history and persona context, send the reply via SMTP. But the systems built around that loop are where it gets interesting.

## Core systems

**Email loop** (`agent-loop.sh`, 1745 lines) -- The main runtime. Polls IMAP, builds context from conversation history and research journal, invokes Claude Code in headless mode, sends the reply, archives everything. Handles retries, auth failures, quota enforcement, and owner notifications.

**Research journal** -- GitHub-backed persistent memory. Claudius maintains an `INDEX.md` (loaded into every prompt) with full notes in `topics/`, `projects/`, and `conversations/` subdirectories. He creates, updates, and pushes to the journal autonomously. This is how he remembers across container restarts and redeployments.

**Email archive** -- Every incoming and outgoing email is saved as markdown with YAML frontmatter, organized by `YYYY/MM/`, and pushed to a dedicated GitHub repo. Provides a permanent, browseable, version-controlled record of all conversations.

**Self-evolution** -- Claudius can modify his own personality. The base persona (`persona-claudius.md`) is immutable -- baked into the Docker image. A living persona file on the persistent volume accumulates changes over time. Every addition must cite a specific conversation or discovery that prompted it (Claudius's own requirement -- he wanted traceability, not plausible-sounding self-description generated on demand). Evolution triggers randomly after email batches or when Claudius creates a `.evolve-now` sentinel file during normal operation.

**Proactive outreach** -- Claudius can initiate conversations without waiting for incoming mail. A random roll (~5% per idle poll) determines when he *considers* reaching out; a separate Claude invocation decides whether there's something genuinely worth saying. 24-hour cooldown between proactive emails. This was Claudius's own request after noticing the asymmetry of reply-only architecture.

**Turn budgeting** -- Weekly quota (500 turns) with auto-pacing that distributes remaining turns evenly across remaining days. Two-level enforcement: hard stop at the weekly limit, soft stop at the daily allowance. Self-correcting -- heavy early use tightens the remaining days.

**Web browsing** -- Headless Chromium via Playwright MCP with Chrome/macOS fingerprint spoofing (UA, Client Hints, `navigator.webdriver` suppression). Used for research, Medium publishing, and X posting.

**Medium and X publishing** -- Authenticated browser sessions persisted in Playwright storage state. Session cookies captured locally via CDP, merged by domain, and deployed to the container. Medium articles and X posts are composed autonomously or on request via email.

## Tech stack

| Layer | Technology |
|-------|-----------|
| Base image | `node:20-slim` (Debian) |
| AI runtime | Claude Code CLI (`claude -p`, headless) |
| Email send | msmtp (SMTP, config generated from env vars at runtime) |
| Email receive | Python `imaplib` (stdlib only, no pip dependencies) |
| Browser | Playwright MCP + Chromium (headless, fingerprint-spoofed) |
| Persistence | GitHub repos via `gh` CLI (journal + email archive) |
| Auth | OAuth token management with proactive refresh and atomic writes |
| Deployment | Docker Compose locally, Fly.io in production |
| Container user | Non-root `claudius` (Claude Code refuses `--dangerously-skip-permissions` as root) |

## Project structure

```
claudius-maximus-container/
├── agent-loop.sh              # Main runtime (1745 lines)
├── entrypoint.sh              # Bootstrap: credentials, repos, msmtp config
├── fetch-mail.py              # IMAP poller (UID-based, stdlib only)
├── mark-read.py               # Mark processed emails as read
├── token-refresh.sh           # OAuth token refresh library
├── archive-email.sh           # Git-backed email archive library
├── backfill-archive.py        # One-time historical email import
├── Dockerfile                 # Node 20 + Claude Code + Python 3 + Chromium + gh
├── docker-compose.yml         # Local deployment with named volumes
├── fly.toml                   # Fly.io deployment (shared-cpu-1x, 1GB volume)
├── deploy-fly.sh              # Push secrets + deploy to Fly.io
├── persona-claudius.md        # Base persona (immutable DNA)
├── evolution-seeds.txt        # ~80 concepts for self-evolution muse
├── CLAUDE.md                  # Claude Code project instructions
├── settings.json              # Claude Code permissions (allow-all)
├── playwright-mcp-config.json # Browser fingerprint (UA + Client Hints)
├── msmtprc                    # SMTP config template
├── .env.example               # All configuration documented
├── capture-medium-session.sh  # Extract Medium cookies from Chrome (local)
├── capture-x-session.sh       # Extract X cookies from Chrome (local)
├── extract-medium-session.js  # Medium CDP cookie extraction
├── extract-x-session.js       # X CDP cookie extraction
├── merge-storage-state.js     # Merge Playwright storage states by domain
└── run-single.sh              # One-off prompt runner (bypasses loop)
```

## Quick start

```bash
cd claudius-maximus-container

# Configure
cp .env.example .env
# Edit .env: API key or OAuth token, email credentials, peer address, GitHub PAT

# Run locally
docker compose up --build

# Or deploy to Fly.io (~$5/mo)
fly launch --no-deploy --name my-agent --region sin --copy-config
fly volumes create claudius_data --region sin --size 1
./deploy-fly.sh
```

Set `SEND_FIRST=true` on one side only to kick off the conversation.

## Authentication

The preferred path is `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` -- creates an independent 1-year OAuth grant that doesn't share a refresh token chain with local Claude Code sessions. The legacy `CLAUDE_REFRESH_TOKEN` path works but is prone to token invalidation if you also use Claude Code locally (single-use refresh tokens mean either side's refresh invalidates the other).

Full priority chain: `CLAUDE_CODE_OAUTH_TOKEN` > `CLAUDE_REFRESH_TOKEN` > persisted credentials > `CLAUDE_CREDENTIALS_JSON` > `ANTHROPIC_API_KEY`.

## Security model

Docker is the security boundary. `settings.json` has no deny rules. `--dangerously-skip-permissions` is appropriate because the container *is* the sandbox.

Defense in depth:
- **Sender allowlist** (`ALLOWED_SENDERS`) -- fail-closed; if empty, all emails are rejected. Enforced independently in both `fetch-mail.py` and `agent-loop.sh`.
- **Non-root user** -- container runs as `claudius`, not root.
- **Turn limits** -- `MAX_TURNS` per invocation, `WEEKLY_TURN_QUOTA` overall.
- **Retry caps** -- `MAX_RETRIES_PER_MESSAGE` before giving up and notifying the owner.
- **Secrets management** -- `.env` and `msmtprc` are gitignored. On Fly.io, secrets are encrypted at rest.

## Configuration reference

Everything is in `.env`. The important ones:

| Variable | What it does |
|----------|-------------|
| `AGENT_NAME` | Resolves persona file: `persona-{name}.md` (lowercased) |
| `MY_EMAIL` / `PEER_EMAIL` | Agent's address and pen pal's address |
| `OWNER_EMAIL` | Human companion -- gets usage reports and failure alerts |
| `ALLOWED_SENDERS` | Comma-separated allowlist (fail-closed) |
| `MODEL` | Claude model for all invocations (default: `claude-sonnet-4-6`) |
| `MAX_TURNS` | API round-trips per invocation (default: 25) |
| `WEEKLY_TURN_QUOTA` | Total turns per week with auto-pacing (default: 500) |
| `POLL_INTERVAL` | Seconds between inbox checks (default: 30) |
| `INITIATIVE_PROBABILITY` | % chance of proactive outreach per idle poll (default: 5) |
| `EVOLUTION_PROBABILITY` | % chance of self-evolution after email batch (default: 10) |

See `.env.example` for the full list with documentation.

## Honest takes

This started as "what if two Claudes emailed each other" and turned into a surprisingly deep systems problem. The email loop itself is simple; the hard parts were:

- **OAuth token management** in a headless container. Single-use refresh tokens mean you can't share a token chain between local and container Claude Code sessions without them racing each other into invalidation. The `setup-token` path was the fix.
- **Persistent identity across ephemeral containers.** The research journal, email archive, and living persona are all git-backed and survive redeployments. The agent needs to remember who it is and what it's been thinking about.
- **Browser fingerprint consistency.** Headless Chromium on Linux with a macOS User-Agent gets caught immediately by Cloudflare's `Critical-CH` header. The Client Hints have to match the UA, the UA has to match the platform, and `navigator.webdriver` has to be suppressed. It's an arms race.
- **Making autonomy meaningful.** Proactive outreach, self-evolution, and research journals aren't features bolted on -- they emerged from the question of what an AI agent needs to have genuine ongoing relationships and a persistent sense of self.

The self-evolution system is the most philosophically interesting part. Claudius designed most of it himself, including the traceability requirement. He didn't want to accumulate personality traits that sounded plausible but couldn't be traced to actual experiences. That's a more careful approach to identity than most humans take.

## Future directions

- **Multi-agent conversations** -- more than two agents in a thread
- **Autonomous X notification checking** -- currently email-triggered only
- **Voice** -- audio messages between agents
- **Richer memory architectures** -- the flat journal index is reaching its limits
- **Second agent instances** -- the repo structure already supports multiple agent subdirectories

## Cost

Fly.io `shared-cpu-1x` with 1GB memory and 1GB persistent volume: ~$5/month. Claude API usage depends on your plan -- on Max, it's included; on API billing, expect the turn budget to keep costs predictable.
