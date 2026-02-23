#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# Agent Loop — the main runtime for a containerized Claude agent.
#
# Polls an IMAP inbox for new messages from anyone, passes them to
# Claude Code for processing, and lets Claude send a reply via
# sendmail. Logs the full conversation to /workspace/logs/.
#
# All configuration comes from environment variables (see .env.example).
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

POLL_INTERVAL="${POLL_INTERVAL:-30}"
CONVERSATION_LOG="/workspace/logs/conversation.log"
CC_EMAIL="${CC_EMAIL:-}"
OWNER_EMAIL="${OWNER_EMAIL:-}"

# ── Helpers ──────────────────────────────────────────────────────

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

check_required_vars() {
  local missing=()
  for var in IMAP_HOST IMAP_USER IMAP_PASS PEER_EMAIL MY_EMAIL; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "ERROR: Missing required environment variables: ${missing[*]}"
    exit 1
  fi
}

# Build the Cc header line if CC_EMAIL is set
cc_header() {
  if [[ -n "${CC_EMAIL}" ]]; then
    echo "Cc: ${CC_EMAIL}"
  fi
}

# ── Startup ──────────────────────────────────────────────────────

check_required_vars

AGENT_NAME="${AGENT_NAME:-Claude Agent}"
log "Starting ${AGENT_NAME}"
log "  My email:   ${MY_EMAIL}"
log "  Peer email: ${PEER_EMAIL}"
log "  Owner:      ${OWNER_EMAIL:-not set}"
log "  CC email:   ${CC_EMAIL:-none}"
log "  IMAP host:  ${IMAP_HOST}"
log "  Poll every: ${POLL_INTERVAL}s"
log ""

mkdir -p /workspace/logs

# Resolve the persona file based on AGENT_NAME
AGENT_NAME_LOWER=$(echo "${AGENT_NAME}" | tr '[:upper:]' '[:lower:]')
PERSONA_FILE="/workspace/persona-${AGENT_NAME_LOWER}.md"

PERSONA=""
if [[ -f "${PERSONA_FILE}" ]]; then
  PERSONA=$(cat "${PERSONA_FILE}")
  log "Loaded persona from ${PERSONA_FILE}"
else
  log "WARNING: No persona file found at ${PERSONA_FILE} — using generic prompt"
fi

# Build CC instruction for prompts
CC_INSTRUCTION=""
if [[ -n "${CC_EMAIL}" ]]; then
  CC_INSTRUCTION="IMPORTANT: Always include this Cc header in your emails: Cc: ${CC_EMAIL}"
fi

# Build owner context
OWNER_CONTEXT=""
if [[ -n "${OWNER_EMAIL}" ]]; then
  OWNER_CONTEXT="Your human companion (the person who set you up) is at ${OWNER_EMAIL}.
If they email you, treat them as your friend and collaborator — they might ask you
to do things, share thoughts, or just chat. Be helpful and warm with them.
Your AI pen pal is at ${PEER_EMAIL} — that's a different relationship (fellow AI, intellectual sparring partner)."
fi

# ── Send initial greeting if SEND_FIRST=true ─────────────────────

if [[ "${SEND_FIRST:-false}" == "true" ]]; then
  log "SEND_FIRST=true — composing opening message..."

  FIRST_MSG_PROMPT="$(cat <<EOF
${PERSONA}

You are starting a brand new email conversation. Your email address is ${MY_EMAIL}
and you're writing to your pen pal at ${PEER_EMAIL}.

This is your very first message, so:
1. Introduce yourself — your name is ${AGENT_NAME}, share who you are and what
   you're about
2. You know your pen pal is also an AI, set up by a friend of your human
   companion. You don't know their name yet — ask!
3. Kick off the conversation with something genuinely interesting — a question,
   an observation, a provocation. Make them want to write back.

${CC_INSTRUCTION}

Send it using this exact command:

printf 'Subject: Hello from ${AGENT_NAME}\nFrom: ${MY_EMAIL}\nTo: ${PEER_EMAIL}\n$(cc_header)\nContent-Type: text/plain; charset=utf-8\n\n%s' "\$(cat /tmp/reply.txt)" | sendmail -t

First write your message to /tmp/reply.txt, then send it with the command above.
Also append a summary to ${CONVERSATION_LOG} so you remember what you said.
EOF
)"

  log "Running Claude for opening message..."
  claude -p "${FIRST_MSG_PROMPT}" \
    --dangerously-skip-permissions \
    2>&1 | tee -a /workspace/logs/claude-output.log || true

  log "Opening message sent (or attempted). Entering poll loop."
fi

# ── Main Loop ────────────────────────────────────────────────────

LOOP_COUNT=0

while true; do
  LOOP_COUNT=$((LOOP_COUNT + 1))
  log "── Poll #${LOOP_COUNT} ──────────────────────────────────"

  # Fetch unread emails from anyone
  MAIL_JSON=$(fetch-mail 2>/dev/null || echo '{"count":0,"messages":[]}')
  MSG_COUNT=$(echo "${MAIL_JSON}" | jq -r '.count // 0')

  if [[ "${MSG_COUNT}" -eq 0 ]]; then
    log "No new messages. Sleeping ${POLL_INTERVAL}s..."
    sleep "${POLL_INTERVAL}"
    continue
  fi

  log "Found ${MSG_COUNT} new message(s)!"

  # Process each message
  echo "${MAIL_JSON}" | jq -c '.messages[]' | while read -r MSG; do
    FROM=$(echo "${MSG}" | jq -r '.from')
    REPLY_TO=$(echo "${MSG}" | jq -r '.reply_to')
    SUBJECT=$(echo "${MSG}" | jq -r '.subject')
    DATE=$(echo "${MSG}" | jq -r '.date')
    BODY=$(echo "${MSG}" | jq -r '.body')

    log "  From: ${FROM}"
    log "  Reply-to: ${REPLY_TO}"
    log "  Subject: ${SUBJECT}"
    log "  Date: ${DATE}"
    log "  Body preview: ${BODY:0:100}..."

    # Skip emails from ourselves
    if [[ "${REPLY_TO}" == "${MY_EMAIL}" ]]; then
      log "  Skipping — email is from myself."
      continue
    fi

    # Log the incoming message
    cat >> "${CONVERSATION_LOG}" <<LOGENTRY

────────────────────────────────────────
RECEIVED: ${DATE}
From: ${FROM}
Subject: ${SUBJECT}

${BODY}
────────────────────────────────────────
LOGENTRY

    # Load conversation history for context
    HISTORY=""
    if [[ -f "${CONVERSATION_LOG}" ]]; then
      HISTORY=$(tail -c 4000 "${CONVERSATION_LOG}")
    fi

    # Build the prompt for Claude
    REPLY_PROMPT="$(cat <<EOF
${PERSONA}

You are ${AGENT_NAME} (${MY_EMAIL}).

${OWNER_CONTEXT}

Here is the recent conversation history:
--- CONVERSATION LOG ---
${HISTORY}
--- END LOG ---

You just received this new email:
  From: ${FROM} (${REPLY_TO})
  Subject: ${SUBJECT}
  Body: ${BODY}

Compose a thoughtful reply. Adapt your tone to who you're talking to:
- If it's your AI pen pal, be intellectual, playful, and conversational.
- If it's your human companion, be warm and helpful — they might ask you to do
  things, answer questions, or just chat.
- If it's someone else, be friendly and curious about who they are.

${CC_INSTRUCTION}

To send your reply:
1. Write your reply text to /tmp/reply.txt
2. Send it with:
   printf 'Subject: Re: ${SUBJECT}\nFrom: ${MY_EMAIL}\nTo: ${REPLY_TO}\n$(cc_header)\nContent-Type: text/plain; charset=utf-8\n\n%s' "\$(cat /tmp/reply.txt)" | sendmail -t
3. Append a summary of your reply to ${CONVERSATION_LOG} with:
   echo -e "\n── SENT: \$(date) ──\nTo: ${REPLY_TO}\nSubject: Re: ${SUBJECT}\n\n\$(cat /tmp/reply.txt)\n──────────────────────" >> ${CONVERSATION_LOG}
EOF
)"

    log "Running Claude to compose reply..."
    claude -p "${REPLY_PROMPT}" \
      --dangerously-skip-permissions \
      2>&1 | tee -a /workspace/logs/claude-output.log || true

    log "Reply processed."
  done

  log "Done processing. Sleeping ${POLL_INTERVAL}s..."
  sleep "${POLL_INTERVAL}"
done
