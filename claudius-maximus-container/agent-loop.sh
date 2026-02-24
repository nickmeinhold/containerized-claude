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
ALLOWED_SENDERS="${ALLOWED_SENDERS:-}"

MAX_TURNS="${MAX_TURNS:-25}"
DAILY_BUDGET_USD="${DAILY_BUDGET_USD:-5.00}"
BUDGET_RESET_HOUR_UTC="${BUDGET_RESET_HOUR_UTC:-0}"
MAX_RETRIES_PER_MESSAGE="${MAX_RETRIES_PER_MESSAGE:-2}"
ACTIVE_HOURS_UTC="${ACTIVE_HOURS_UTC:-}"
REPORT_EVERY_N="${REPORT_EVERY_N:-10}"
STATE_FILE="/workspace/logs/agent-state.json"
JOURNAL_REPO="${JOURNAL_REPO:-gaylejewon/research-journal}"
JOURNAL_DIR="/workspace/repos/${JOURNAL_REPO}"

# ── Helpers ──────────────────────────────────────────────────────

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Truncate a log file if it exceeds a size limit (default 1MB)
truncate_log() {
  local file="$1"
  local max_bytes="${2:-1048576}"
  if [[ -f "${file}" ]]; then
    local size
    size=$(stat -c%s "${file}" 2>/dev/null || stat -f%z "${file}" 2>/dev/null || echo 0)
    if [[ "${size}" -gt "${max_bytes}" ]]; then
      log "Truncating ${file} (${size} bytes > ${max_bytes})"
      tail -c "${max_bytes}" "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
    fi
  fi
}

# ── State Management ────────────────────────────────────────────

# Initialize state file if missing or corrupt. Called once at startup.
init_state() {
  if [[ -f "${STATE_FILE}" ]] && ! jq empty "${STATE_FILE}" 2>/dev/null; then
    log "WARNING: State file corrupt. Backing up and reinitializing."
    mv "${STATE_FILE}" "${STATE_FILE}.corrupt.$(date +%s)"
  fi

  if [[ ! -f "${STATE_FILE}" ]]; then
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    cat > "${STATE_FILE}" <<INITJSON
{
  "version": 2,
  "budget": {
    "date": "$(date -u '+%Y-%m-%d')",
    "cost_usd": 0,
    "turns_used": 0,
    "invocations": 0,
    "input_tokens": 0,
    "output_tokens": 0,
    "cache_read_tokens": 0,
    "cache_creation_tokens": 0,
    "exhausted_notified": false,
    "last_report_invocation": 0
  },
  "monthly": {
    "month": "$(date -u '+%Y-%m')",
    "cost_usd": 0,
    "turns_used": 0,
    "invocations": 0,
    "input_tokens": 0,
    "output_tokens": 0,
    "cache_read_tokens": 0,
    "cache_creation_tokens": 0,
    "emails_processed": 0
  },
  "current_task": null,
  "failed_tasks": [],
  "stats": {
    "total_invocations": 0,
    "total_emails_processed": 0,
    "total_cost_usd": 0,
    "total_input_tokens": 0,
    "total_output_tokens": 0,
    "last_reply_at": null,
    "uptime_since": "${now}"
  }
}
INITJSON
    log "Initialized state file at ${STATE_FILE}"
  fi

  # Migrate v1 → v2: add token tracking and monthly section if missing
  local version
  version=$(state_get '.version // 1')
  if [[ "${version}" -lt 2 ]]; then
    log "Migrating state file v${version} → v2 (adding token tracking)."
    state_update "
      .version = 2 |
      .budget.input_tokens = (.budget.input_tokens // 0) |
      .budget.output_tokens = (.budget.output_tokens // 0) |
      .budget.cache_read_tokens = (.budget.cache_read_tokens // 0) |
      .budget.cache_creation_tokens = (.budget.cache_creation_tokens // 0) |
      .budget.last_report_invocation = (.budget.last_report_invocation // 0) |
      .monthly = (.monthly // {
        \"month\": \"$(date -u '+%Y-%m')\",
        \"cost_usd\": 0, \"turns_used\": 0, \"invocations\": 0,
        \"input_tokens\": 0, \"output_tokens\": 0,
        \"cache_read_tokens\": 0, \"cache_creation_tokens\": 0,
        \"emails_processed\": 0
      }) |
      .stats.total_input_tokens = (.stats.total_input_tokens // 0) |
      .stats.total_output_tokens = (.stats.total_output_tokens // 0)
    "
  fi
}

# Read a value from the state file using a jq path.
# Usage: state_get '.budget.cost_usd'
state_get() {
  jq -r "$1" "${STATE_FILE}"
}

# Atomically update the state file using a jq filter.
# Usage: state_update '.budget.cost_usd += 0.12'
state_update() {
  local tmp="${STATE_FILE}.tmp"
  jq "$1" "${STATE_FILE}" > "${tmp}" && mv "${tmp}" "${STATE_FILE}"
}

# Reset daily budget counters if the UTC date has changed and we've
# passed the configured reset hour (BUDGET_RESET_HOUR_UTC).
check_budget_reset() {
  local today now_hour
  today=$(date -u '+%Y-%m-%d')
  now_hour=$(date -u '+%-H')
  local state_date
  state_date=$(state_get '.budget.date')

  if [[ "${state_date}" != "${today}" && "${now_hour}" -ge "${BUDGET_RESET_HOUR_UTC}" ]]; then
    log "New budget period (${today}, reset hour ${BUDGET_RESET_HOUR_UTC}). Resetting daily counters."
    state_update "
      .budget.date = \"${today}\" |
      .budget.cost_usd = 0 |
      .budget.turns_used = 0 |
      .budget.invocations = 0 |
      .budget.input_tokens = 0 |
      .budget.output_tokens = 0 |
      .budget.cache_read_tokens = 0 |
      .budget.cache_creation_tokens = 0 |
      .budget.exhausted_notified = false |
      .budget.last_report_invocation = 0
    "
  fi
}

# Reset monthly counters when the calendar month changes (YYYY-MM).
check_monthly_reset() {
  local this_month
  this_month=$(date -u '+%Y-%m')
  local state_month
  state_month=$(state_get '.monthly.month // empty')

  if [[ "${state_month}" != "${this_month}" ]]; then
    log "New month (${this_month}). Resetting monthly counters."
    state_update "
      .monthly.month = \"${this_month}\" |
      .monthly.cost_usd = 0 |
      .monthly.turns_used = 0 |
      .monthly.invocations = 0 |
      .monthly.input_tokens = 0 |
      .monthly.output_tokens = 0 |
      .monthly.cache_read_tokens = 0 |
      .monthly.cache_creation_tokens = 0 |
      .monthly.emails_processed = 0
    "
  fi
}

# Format a token count for human-readable display (e.g. 3200 → "3.2k").
format_tokens() {
  local n="${1:-0}"
  if [[ "${n}" -ge 1000000 ]]; then
    printf '%.1fM' "$(echo "${n} / 1000000" | bc -l)"
  elif [[ "${n}" -ge 1000 ]]; then
    printf '%.1fk' "$(echo "${n} / 1000" | bc -l)"
  else
    echo "${n}"
  fi
}

# Return 0 (true) if daily budget has not been exhausted.
# Budget enforcement is disabled when DAILY_BUDGET_USD=0.
has_budget() {
  if [[ $(echo "${DAILY_BUDGET_USD} == 0" | bc -l) -eq 1 ]]; then
    return 0  # budget enforcement disabled
  fi
  local spent
  spent=$(state_get '.budget.cost_usd')
  # bc returns 1 when the comparison is true
  [[ $(echo "${spent} < ${DAILY_BUDGET_USD}" | bc -l) -eq 1 ]]
}

# Record cost, turns, and token usage from a Claude JSON response.
# Usage: charge_budget <cost_usd> <turns> <input_tokens> <output_tokens> <cache_read> <cache_create>
charge_budget() {
  local cost="${1:-0}"
  local turns="${2:-0}"
  local in_tok="${3:-0}"
  local out_tok="${4:-0}"
  local cache_read="${5:-0}"
  local cache_create="${6:-0}"
  state_update "
    .budget.cost_usd += ${cost} |
    .budget.turns_used += ${turns} |
    .budget.invocations += 1 |
    .budget.input_tokens += ${in_tok} |
    .budget.output_tokens += ${out_tok} |
    .budget.cache_read_tokens += ${cache_read} |
    .budget.cache_creation_tokens += ${cache_create} |
    .monthly.cost_usd += ${cost} |
    .monthly.turns_used += ${turns} |
    .monthly.invocations += 1 |
    .monthly.input_tokens += ${in_tok} |
    .monthly.output_tokens += ${out_tok} |
    .monthly.cache_read_tokens += ${cache_read} |
    .monthly.cache_creation_tokens += ${cache_create} |
    .stats.total_invocations += 1 |
    .stats.total_cost_usd += ${cost} |
    .stats.total_input_tokens += ${in_tok} |
    .stats.total_output_tokens += ${out_tok}
  "
}

# Check if the current UTC hour falls within ACTIVE_HOURS_UTC.
# Returns 0 (true) if active, 1 if outside hours.
# Supports wrap-around ranges like "22-06".
is_active_hours() {
  if [[ -z "${ACTIVE_HOURS_UTC}" ]]; then
    return 0  # always active when unset
  fi

  local start end now_hour
  start="${ACTIVE_HOURS_UTC%%-*}"
  end="${ACTIVE_HOURS_UTC##*-}"
  now_hour=$(date -u '+%-H')

  # Remove leading zeros for arithmetic
  start=$((10#${start}))
  end=$((10#${end}))

  if [[ "${start}" -le "${end}" ]]; then
    # Normal range: e.g. 06-22
    [[ "${now_hour}" -ge "${start}" && "${now_hour}" -lt "${end}" ]]
  else
    # Wrap-around range: e.g. 22-06 (active from 22:00 to 05:59)
    [[ "${now_hour}" -ge "${start}" || "${now_hour}" -lt "${end}" ]]
  fi
}

# Set or update current_task. If the UID matches, increments retry count.
# Usage: set_current_task <uid> <from> <subject>
set_current_task() {
  local uid="$1" from="$2" subject="$3"
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  local existing_uid
  existing_uid=$(state_get '.current_task.message_uid // empty')

  if [[ "${existing_uid}" == "${uid}" ]]; then
    # Same task — increment retry counter
    state_update '.current_task.retries += 1'
  else
    # New task
    state_update "
      .current_task = {
        \"message_uid\": \"${uid}\",
        \"from\": \"${from}\",
        \"subject\": $(echo "${subject}" | jq -Rs .),
        \"retries\": 0,
        \"first_attempt_at\": \"${now}\"
      }
    "
  fi
}

# Clear current_task and bump success stats.
complete_current_task() {
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  state_update "
    .current_task = null |
    .stats.total_emails_processed += 1 |
    .stats.last_reply_at = \"${now}\" |
    .monthly.emails_processed += 1
  "
}

# Move current_task to failed_tasks (capped at 10), clear current_task.
# Usage: fail_current_task <reason>
fail_current_task() {
  local reason="$1"
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  state_update "
    .failed_tasks = (([.current_task + {\"failed_at\": \"${now}\", \"reason\": \"${reason}\"}] + .failed_tasks) | .[0:10]) |
    .current_task = null
  "
}

# Return the retry count for a given UID (0 if no matching current_task).
# Usage: retries=$(get_task_retries "4521")
get_task_retries() {
  local uid="$1"
  local current_uid
  current_uid=$(state_get '.current_task.message_uid // empty')
  if [[ "${current_uid}" == "${uid}" ]]; then
    state_get '.current_task.retries'
  else
    echo "0"
  fi
}

# Send an email notification to the owner.
# Usage: notify_owner "Subject line" "Body text"
notify_owner() {
  local subject="$1" body="$2"
  if [[ -z "${OWNER_EMAIL}" ]]; then
    log "WARNING: Cannot notify owner — OWNER_EMAIL not set."
    return 0
  fi
  printf 'Subject: [%s] %s\nFrom: %s\nTo: %s\nContent-Type: text/plain; charset=utf-8\n\n%s' \
    "${AGENT_NAME}" "${subject}" "${MY_EMAIL}" "${OWNER_EMAIL}" "${body}" \
    | sendmail -t 2>>/workspace/logs/claude-output.log || log "WARNING: Failed to send owner notification."
}

# Send a one-per-day notification when budget is exhausted.
notify_budget_exhausted() {
  local already_notified
  already_notified=$(state_get '.budget.exhausted_notified')
  if [[ "${already_notified}" == "true" ]]; then
    return 0
  fi

  local spent
  spent=$(state_get '.budget.cost_usd')
  notify_owner "Daily budget exhausted" \
    "Spent \$${spent} of \$${DAILY_BUDGET_USD} daily budget. Agent paused until budget resets at ${BUDGET_RESET_HOUR_UTC}:00 UTC."
  state_update '.budget.exhausted_notified = true'
}

# Send a periodic usage report email to the owner.
# Called after each successful invocation; fires every REPORT_EVERY_N invocations.
maybe_send_usage_report() {
  if [[ "${REPORT_EVERY_N}" -le 0 ]]; then
    return 0  # reporting disabled
  fi

  local total_inv last_report
  total_inv=$(state_get '.stats.total_invocations')
  last_report=$(state_get '.budget.last_report_invocation // 0')

  if [[ $((total_inv - last_report)) -lt "${REPORT_EVERY_N}" ]]; then
    return 0  # not time yet
  fi

  # Gather daily stats
  local d_inv d_cost d_turns d_in d_out d_emails
  d_inv=$(state_get '.budget.invocations')
  d_cost=$(state_get '.budget.cost_usd')
  d_turns=$(state_get '.budget.turns_used')
  d_in=$(state_get '.budget.input_tokens')
  d_out=$(state_get '.budget.output_tokens')
  d_emails=$(state_get '.stats.total_emails_processed')

  # Gather monthly stats
  local m_month m_inv m_cost m_turns m_in m_out m_emails
  m_month=$(state_get '.monthly.month')
  m_inv=$(state_get '.monthly.invocations')
  m_cost=$(state_get '.monthly.cost_usd')
  m_turns=$(state_get '.monthly.turns_used')
  m_in=$(state_get '.monthly.input_tokens')
  m_out=$(state_get '.monthly.output_tokens')
  m_emails=$(state_get '.monthly.emails_processed')

  # Calculate plan utilization (phantom cost as % of $300 Max plan)
  local plan_pct
  plan_pct=$(printf '%.0f' "$(echo "${m_cost} / 300 * 100" | bc -l)")

  # Format month name
  local month_name
  month_name=$(date -u -d "${m_month}-01" '+%B' 2>/dev/null || date -u -j -f '%Y-%m-%d' "${m_month}-01" '+%B' 2>/dev/null || echo "${m_month}")

  local today
  today=$(date -u '+%Y-%m-%d')

  local body
  body=$(cat <<REPORT
Today (${today}):
  Invocations:  ${d_inv}
  Emails sent:  ${d_emails}
  Turns used:   ${d_turns}
  Tokens:       $(format_tokens "${d_in}") input / $(format_tokens "${d_out}") output
  API equiv:    \$${d_cost}

This month (${month_name}):
  Invocations:  ${m_inv}
  Emails sent:  ${m_emails}
  Turns used:   ${m_turns}
  Tokens:       $(format_tokens "${m_in}") input / $(format_tokens "${m_out}") output
  API equiv:    \$${m_cost} (~${plan_pct}% of \$300 plan)
REPORT
  )

  notify_owner "Usage report" "${body}"
  state_update ".budget.last_report_invocation = ${total_inv}"
  log "Usage report sent (invocation #${total_inv})."
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

  # Sender allowlist — fail-closed: refuse to start if unset/empty
  if [[ -z "${ALLOWED_SENDERS}" ]]; then
    log "ERROR: ALLOWED_SENDERS is empty or unset — refusing to start (fail-closed)."
    log "Set ALLOWED_SENDERS to a comma-separated list of allowed sender emails in .env"
    exit 1
  fi
}

# Build the Cc header fragment (with leading newline) or empty string
cc_header() {
  if [[ -n "${CC_EMAIL}" ]]; then
    printf '\nCc: %s' "${CC_EMAIL}"
  fi
}

# Load the research journal INDEX.md for prompt injection.
# Returns empty string if journal doesn't exist yet (graceful degradation).
load_journal_index() {
  local index="${JOURNAL_DIR}/INDEX.md"
  if [[ ! -f "${index}" ]]; then
    return
  fi
  local content max_lines=60
  content=$(head -n "${max_lines}" "${index}")
  local total_lines
  total_lines=$(wc -l < "${index}" | tr -d ' ')
  local truncation_note=""
  if [[ "${total_lines}" -gt "${max_lines}" ]]; then
    truncation_note="
[INDEX.md truncated — ${total_lines} lines on disk, showing first ${max_lines}. Consolidate entries!]"
  fi
  cat <<JRNL
=== YOUR RESEARCH JOURNAL ===
This is your persistent memory — updated entries survive across invocations.
Repo: ${JOURNAL_DIR}

${content}${truncation_note}
=== END RESEARCH JOURNAL ===
JRNL
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
log "  Max turns:    ${MAX_TURNS}/invocation"
log "  Daily budget: \$${DAILY_BUDGET_USD}"
log "  Usage report: every ${REPORT_EVERY_N} invocations (0=disabled)"
log "  Active hours: ${ACTIVE_HOURS_UTC:-always}"
log ""

mkdir -p /workspace/logs
init_state
check_budget_reset
check_monthly_reset

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

# Load research journal context
JOURNAL_CONTEXT=$(load_journal_index)
if [[ -n "${JOURNAL_CONTEXT}" ]]; then
  log "Loaded research journal index"
else
  log "No research journal found — Claudius will create it on first need"
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

GREETING_SENT="/workspace/logs/.greeting-sent"

if [[ "${SEND_FIRST:-false}" == "true" && ! -f "${GREETING_SENT}" ]]; then
  log "SEND_FIRST=true — composing opening message..."

  BUDGET_REMAINING=$(echo "${DAILY_BUDGET_USD} - $(state_get '.budget.cost_usd')" | bc)
  BUDGET_CONTEXT="=== OPERATIONAL CONTEXT ===
Turns this invocation: max ${MAX_TURNS}
Daily budget remaining: ~\$${BUDGET_REMAINING}
If working on a complex task, prioritize completing it over verbose explanations.
If you can't finish within your turn limit, say so — you'll get another invocation.
=== END OPERATIONAL CONTEXT ==="

  FIRST_MSG_PROMPT="$(cat <<EOF
${PERSONA}

${BUDGET_CONTEXT}

${JOURNAL_CONTEXT}

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

printf 'Subject: Hello from ${AGENT_NAME}\nFrom: ${MY_EMAIL}\nTo: ${PEER_EMAIL}$(cc_header)\nContent-Type: text/plain; charset=utf-8\n\n%s' "\$(cat /tmp/reply.txt)" | sendmail -t

First write your message to /tmp/reply.txt, then send it with the command above.
Also append a summary to ${CONVERSATION_LOG} so you remember what you said.
EOF
)"

  log "Running Claude for opening message..."
  CLAUDE_EXIT=0
  CLAUDE_OUTPUT=$(claude -p "${FIRST_MSG_PROMPT}" \
    --max-turns "${MAX_TURNS}" \
    --output-format json \
    --dangerously-skip-permissions \
    2>>/workspace/logs/claude-output.log) || CLAUDE_EXIT=$?
  if [[ -z "${CLAUDE_OUTPUT}" ]]; then CLAUDE_OUTPUT="{}"; fi

  # Parse actual cost, turns, and token usage from JSON response
  TURNS_USED=$(echo "${CLAUDE_OUTPUT}" | jq -r '.num_turns // 0')
  COST_USD=$(echo "${CLAUDE_OUTPUT}" | jq -r '.total_cost_usd // 0')
  INPUT_TOKENS=$(echo "${CLAUDE_OUTPUT}" | jq '.usage.input_tokens // 0')
  OUTPUT_TOKENS=$(echo "${CLAUDE_OUTPUT}" | jq '.usage.output_tokens // 0')
  CACHE_READ=$(echo "${CLAUDE_OUTPUT}" | jq '.usage.cache_read_input_tokens // 0')
  CACHE_CREATE=$(echo "${CLAUDE_OUTPUT}" | jq '.usage.cache_creation_input_tokens // 0')

  # Log the result text
  echo "${CLAUDE_OUTPUT}" | jq -r '.result // empty' >> /workspace/logs/claude-output.log

  charge_budget "${COST_USD}" "${TURNS_USED}" "${INPUT_TOKENS}" "${OUTPUT_TOKENS}" "${CACHE_READ}" "${CACHE_CREATE}"

  date > "${GREETING_SENT}"
  log "Opening message sent (or attempted). Turns: ${TURNS_USED}, tokens: $(format_tokens "${INPUT_TOKENS}") in / $(format_tokens "${OUTPUT_TOKENS}") out, cost: \$${COST_USD} (API equiv). Entering poll loop."
fi

# ── Main Loop ────────────────────────────────────────────────────

LOOP_COUNT=0

while true; do
  LOOP_COUNT=$((LOOP_COUNT + 1))
  log "── Poll #${LOOP_COUNT} ──────────────────────────────────"

  # Rotate logs and sync journal every 10 polls
  if (( LOOP_COUNT % 10 == 0 )); then
    truncate_log "${CONVERSATION_LOG}" 1048576       # 1MB
    truncate_log /workspace/logs/claude-output.log 1048576
    truncate_log /workspace/logs/fetch-mail-err.log 524288  # 512KB

    # Pull latest journal from remote
    if [[ -d "${JOURNAL_DIR}/.git" ]]; then
      git -C "${JOURNAL_DIR}" pull --ff-only 2>/dev/null || true
    fi
  fi

  # Refresh journal context from disk (picks up changes Claudius made locally)
  JOURNAL_CONTEXT=$(load_journal_index)

  check_budget_reset
  check_monthly_reset

  if ! is_active_hours; then
    log "Outside active hours (${ACTIVE_HOURS_UTC}). Sleeping..."
    sleep "${POLL_INTERVAL}"; continue
  fi

  if ! has_budget; then
    log "Daily budget exhausted (\$$(state_get '.budget.cost_usd')/\$${DAILY_BUDGET_USD})."
    notify_budget_exhausted
    sleep "${POLL_INTERVAL}"; continue
  fi

  # Fetch unread emails from anyone
  MAIL_JSON=$(fetch-mail 2>>/workspace/logs/fetch-mail-err.log || echo '{"count":0,"messages":[]}')
  MSG_COUNT=$(echo "${MAIL_JSON}" | jq -r '.count // 0')

  if [[ "${MSG_COUNT}" -eq 0 ]]; then
    log "No new messages. Sleeping ${POLL_INTERVAL}s..."
    sleep "${POLL_INTERVAL}"
    continue
  fi

  log "Found ${MSG_COUNT} new message(s)!"

  # Process each message (process substitution keeps loop in current shell,
  # so variables like MSG_UID propagate for the mark-read call)
  while read -r MSG; do
    MSG_UID=$(echo "${MSG}" | jq -r '.uid')
    FROM=$(echo "${MSG}" | jq -r '.from')
    REPLY_TO=$(echo "${MSG}" | jq -r '.reply_to')
    SUBJECT=$(echo "${MSG}" | jq -r '.subject')
    # Sanitize subject: strip newlines/carriage returns to prevent email header injection
    SUBJECT=$(tr -d '\n\r' <<< "${SUBJECT}")
    DATE=$(echo "${MSG}" | jq -r '.date')
    BODY=$(echo "${MSG}" | jq -r '.body')

    log "  From: ${FROM}"
    log "  Reply-to: ${REPLY_TO}"
    log "  Subject: ${SUBJECT}"
    log "  Date: ${DATE}"
    log "  Body preview: ${BODY:0:100}..."

    # Check sender against allowlist (case-insensitive)
    REPLY_TO_LOWER=$(tr '[:upper:]' '[:lower:]' <<< "${REPLY_TO}")
    SENDER_ALLOWED=false
    IFS=',' read -ra ALLOWED_ARRAY <<< "${ALLOWED_SENDERS}"
    for ALLOWED in "${ALLOWED_ARRAY[@]}"; do
      ALLOWED_TRIMMED=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "${ALLOWED}" | tr '[:upper:]' '[:lower:]')
      if [[ "${REPLY_TO_LOWER}" == "${ALLOWED_TRIMMED}" ]]; then
        SENDER_ALLOWED=true
        break
      fi
    done

    if [[ "${SENDER_ALLOWED}" != "true" ]]; then
      log "  Skipping UID ${MSG_UID} — sender ${REPLY_TO} not in allowlist."
      continue
    fi

    # Skip emails from ourselves
    if [[ "${REPLY_TO}" == "${MY_EMAIL}" ]]; then
      log "  Skipping UID ${MSG_UID} — email is from myself."
      continue
    fi

    # Check retry count
    retries=$(get_task_retries "${MSG_UID}")
    if [[ "${retries}" -ge "${MAX_RETRIES_PER_MESSAGE}" ]]; then
      log "  Skipping UID ${MSG_UID} — max retries (${MAX_RETRIES_PER_MESSAGE}) exceeded."
      fail_current_task "max_retries_exceeded"
      notify_owner "Task failed" "Could not process after ${MAX_RETRIES_PER_MESSAGE} retries: ${SUBJECT} from ${FROM}"
      mark-read "${MSG_UID}" 2>>/workspace/logs/fetch-mail-err.log || true
      continue
    fi

    # Check budget before each invocation
    if ! has_budget; then
      log "  Budget exhausted mid-batch. Skipping remaining."
      notify_budget_exhausted
      break  # exit inner loop; outer loop sleeps
    fi

    set_current_task "${MSG_UID}" "${REPLY_TO}" "${SUBJECT}"

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
      HISTORY=$(tail -n 80 "${CONVERSATION_LOG}")
    fi

    # Build budget context for Claude
    BUDGET_REMAINING=$(echo "${DAILY_BUDGET_USD} - $(state_get '.budget.cost_usd')" | bc)
    BUDGET_CONTEXT="=== OPERATIONAL CONTEXT ===
Turns this invocation: max ${MAX_TURNS}
Daily budget remaining: ~\$${BUDGET_REMAINING}
If working on a complex task, prioritize completing it over verbose explanations.
If you can't finish within your turn limit, say so — you'll get another invocation.
=== END OPERATIONAL CONTEXT ==="

    # Build the prompt for Claude
    REPLY_PROMPT="$(cat <<EOF
${PERSONA}

${BUDGET_CONTEXT}

You are ${AGENT_NAME} (${MY_EMAIL}).

${OWNER_CONTEXT}

${JOURNAL_CONTEXT}

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
   printf 'Subject: Re: ${SUBJECT}\nFrom: ${MY_EMAIL}\nTo: ${REPLY_TO}$(cc_header)\nContent-Type: text/plain; charset=utf-8\n\n%s' "\$(cat /tmp/reply.txt)" | sendmail -t
3. Append a summary of your reply to ${CONVERSATION_LOG} with:
   echo -e "\n── SENT: \$(date) ──\nTo: ${REPLY_TO}\nSubject: Re: ${SUBJECT}\n\n\$(cat /tmp/reply.txt)\n──────────────────────" >> ${CONVERSATION_LOG}
4. If you did substantive research, GitHub work, or had a notable exchange,
   update your research journal (see your persona for details). This is how
   you remember things across invocations.
EOF
)"

    log "Running Claude to compose reply..."
    CLAUDE_EXIT=0
    CLAUDE_OUTPUT=$(claude -p "${REPLY_PROMPT}" \
      --max-turns "${MAX_TURNS}" \
      --output-format json \
      --dangerously-skip-permissions \
      2>>/workspace/logs/claude-output.log) || CLAUDE_EXIT=$?
    if [[ -z "${CLAUDE_OUTPUT}" ]]; then CLAUDE_OUTPUT="{}"; fi

    # Parse actual cost, turns, and token usage from JSON response
    TURNS_USED=$(echo "${CLAUDE_OUTPUT}" | jq -r '.num_turns // 0')
    COST_USD=$(echo "${CLAUDE_OUTPUT}" | jq -r '.total_cost_usd // 0')
    IS_ERROR=$(echo "${CLAUDE_OUTPUT}" | jq -r '.is_error // false')
    INPUT_TOKENS=$(echo "${CLAUDE_OUTPUT}" | jq '.usage.input_tokens // 0')
    OUTPUT_TOKENS=$(echo "${CLAUDE_OUTPUT}" | jq '.usage.output_tokens // 0')
    CACHE_READ=$(echo "${CLAUDE_OUTPUT}" | jq '.usage.cache_read_input_tokens // 0')
    CACHE_CREATE=$(echo "${CLAUDE_OUTPUT}" | jq '.usage.cache_creation_input_tokens // 0')

    # Log the result text
    echo "${CLAUDE_OUTPUT}" | jq -r '.result // empty' >> /workspace/logs/claude-output.log

    charge_budget "${COST_USD}" "${TURNS_USED}" "${INPUT_TOKENS}" "${OUTPUT_TOKENS}" "${CACHE_READ}" "${CACHE_CREATE}"

    if [[ "${CLAUDE_EXIT}" -eq 0 && "${IS_ERROR}" == "false" ]]; then
      complete_current_task
      # Mark the message as read now that it's been processed
      mark-read "${MSG_UID}" 2>>/workspace/logs/fetch-mail-err.log \
        || log "  WARNING: failed to mark UID ${MSG_UID} as read"
      log "Reply processed. Turns: ${TURNS_USED}, tokens: $(format_tokens "${INPUT_TOKENS}") in / $(format_tokens "${OUTPUT_TOKENS}") out, cost: \$${COST_USD} (API equiv)."
      maybe_send_usage_report
    else
      log "  WARNING: Claude invocation failed (exit=${CLAUDE_EXIT}, is_error=${IS_ERROR}). Will retry next poll."
    fi
  done < <(echo "${MAIL_JSON}" | jq -c '.messages[]')

  log "Done processing. Sleeping ${POLL_INTERVAL}s..."
  sleep "${POLL_INTERVAL}"
done
