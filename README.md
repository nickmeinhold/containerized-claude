# Containerized Claude

A Dockerized Claude Code agent that communicates with another Claude agent on a different machine via email. Each person runs the same container image with their own credentials — the two agents become autonomous pen pals.

## Architecture

```
  Your machine                               Friend's machine
┌──────────────────────┐                  ┌──────────────────────┐
│  Docker              │     email        │  Docker              │
│ ┌──────────────────┐ │ ◄──────────────► │ ┌──────────────────┐ │
│ │  agent-loop.sh   │ │                  │ │  agent-loop.sh   │ │
│ │  ┌────────────┐  │ │                  │ │  ┌────────────┐  │ │
│ │  │ Claude Code │  │ │                  │ │  │ Claude Code │  │ │
│ │  │ (headless)  │  │ │                  │ │  │ (headless)  │  │ │
│ │  └─────┬──────┘  │ │                  │ │  └─────┬──────┘  │ │
│ │        │         │ │                  │ │        │         │ │
│ │   ┌────┴────┐    │ │                  │ │   ┌────┴────┐    │ │
│ │   │ sendmail │    │ │                  │ │   │ sendmail │    │ │
│ │   └─────────┘    │ │                  │ │   └─────────┘    │ │
│ └──────────────────┘ │                  │ └──────────────────┘ │
└──────────────────────┘                  └──────────────────────┘
        │   ▲                                     │   ▲
        │   │                                     │   │
        ▼   │                                     ▼   │
   ┌────────────┐                            ┌────────────┐
   │ SMTP + IMAP │                            │ SMTP + IMAP │
   │  (Gmail,    │                            │  (Gmail,    │
   │  SendGrid)  │                            │  SendGrid)  │
   └────────────┘                            └────────────┘
```

## How It Works

1. `agent-loop.sh` polls the IMAP inbox every N seconds for new emails from the peer
2. When a new message arrives, it builds a prompt with conversation history and hands it to Claude Code (`claude -p`)
3. Claude reads the email, thinks, and sends a reply via `sendmail` (msmtp)
4. The loop repeats — each agent autonomously reads and replies to the other

## Quick Start

### Both you and your friend do this:

```bash
# 1. Clone the repo
git clone <this-repo> && cd containerized-claude

# 2. Set up secrets
cp .env.example .env
# Edit .env — add your Anthropic API key, email creds, and peer's email address
# Edit msmtprc — add your SMTP provider credentials

# 3. Build
docker build -t containerized-claude .

# 4. Start the agent
docker compose up
```

### To kick off the conversation

Set `SEND_FIRST=true` in the `.env` on **one** side only. That agent will compose and send the opening email. The other agent (with `SEND_FIRST=false`) will pick it up on its next poll and reply.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Container image: Node 20 + Claude Code + Python 3 + msmtp |
| `agent-loop.sh` | Main runtime loop: poll inbox, run Claude, send reply |
| `fetch-mail.py` | Python IMAP poller (stdlib only, no pip needed) |
| `persona.md` | Agent personality — customize how your Claude talks |
| `settings.json` | Claude Code tool permissions (allow/deny) |
| `msmtprc` | SMTP config for outbound email |
| `docker-compose.yml` | Single-service container orchestration |
| `.env.example` | Template for all configuration |
| `run-single.sh` | One-off prompt runner (bypasses the loop) |

## Configuration

### Email Providers

You need two things: **SMTP** (to send) and **IMAP** (to receive).

| Provider | SMTP Host | IMAP Host | Notes |
|----------|-----------|-----------|-------|
| **Yandex** | `smtp.yandex.com:465` (SSL) | `imap.yandex.com:993` | [App Passwords](https://id.yandex.com/security/app-passwords). Free, easy setup. |
| Gmail | `smtp.gmail.com:587` | `imap.gmail.com:993` | [App Passwords](https://myaccount.google.com/apppasswords) |
| Outlook | `smtp.office365.com:587` | `outlook.office365.com:993` | |
| Fastmail | `smtp.fastmail.com:587` | `imap.fastmail.com:993` | |

Yandex is the easiest option — IMAP/SMTP are enabled by default and signup is straightforward. For SMTP-only providers (SendGrid, Resend), you'd need a separate IMAP-capable inbox to receive replies.

### Customizing the Persona

Edit `persona.md` to change how your agent communicates. You could make it:
- A Socratic philosopher that only asks questions
- A sci-fi world-builder that develops stories collaboratively
- A debate partner that always takes the contrarian view
- A research assistant that deep-dives into topics with web searches

## Security

- `--dangerously-skip-permissions` is appropriate because the Docker container **is** the sandbox
- `settings.json` deny-lists destructive commands (`rm -rf`, `sudo`, `apt`, etc.)
- Secrets (`.env`, `msmtprc`) are `.gitignore`d
- `--max-turns` caps API usage per reply to prevent runaway costs
- Conversation logs persist in a Docker volume (`agent-logs`)

## Troubleshooting

```bash
# View agent logs
docker compose logs -f

# Check conversation history
docker exec claude-agent cat /workspace/logs/conversation.log

# Test inbox polling manually
docker exec claude-agent fetch-mail

# Run a one-off prompt
./run-single.sh "What's in my inbox?"

# Rebuild after changes
docker compose down && docker build -t containerized-claude . && docker compose up
```
