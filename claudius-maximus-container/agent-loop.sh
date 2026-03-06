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
WEEKLY_TURN_QUOTA="${WEEKLY_TURN_QUOTA:-1000}"
QUOTA_RESET_DAY="${QUOTA_RESET_DAY:-4}"          # ISO weekday: 1=Mon..7=Sun (4=Thu)
QUOTA_RESET_HOUR_UTC="${QUOTA_RESET_HOUR_UTC:-6}" # 06:00 UTC
# Validate QUOTA_RESET_DAY range (must be ISO weekday 1-7)
if [[ "${QUOTA_RESET_DAY}" -lt 1 || "${QUOTA_RESET_DAY}" -gt 7 ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: QUOTA_RESET_DAY must be 1-7 (got ${QUOTA_RESET_DAY}), defaulting to 4 (Thursday)"
  QUOTA_RESET_DAY=4
fi
MAX_RETRIES_PER_MESSAGE="${MAX_RETRIES_PER_MESSAGE:-2}"
ACTIVE_HOURS_UTC="${ACTIVE_HOURS_UTC:-}"
REPORT_EVERY_N="${REPORT_EVERY_N:-10}"
STATE_FILE="/workspace/logs/agent-state.json"
JOURNAL_REPO="${JOURNAL_REPO:-gaylejewon/research-journal}"
JOURNAL_DIR="/workspace/repos/${JOURNAL_REPO}"
ARCHIVE_REPO="${ARCHIVE_REPO:-}"
ARCHIVE_DIR="/workspace/repos/${ARCHIVE_REPO}"
ATTACHMENT_DIR="${ATTACHMENT_DIR:-/workspace/attachments}"
MODEL="${MODEL:-claude-sonnet-4-6}"

# ── Self-Evolution ────────────────────────────────────────────────
EVOLUTION_PROBABILITY="${EVOLUTION_PROBABILITY:-15}"   # % chance per email batch
EVOLUTION_MAX_TURNS="${EVOLUTION_MAX_TURNS:-5}"
EVOLUTION_FILE="/workspace/logs/persona-evolution.md"
EVOLUTION_SEEDS="/workspace/evolution-seeds.txt"

# ── Proactive Outreach ────────────────────────────────────────────
INITIATIVE_PROBABILITY="${INITIATIVE_PROBABILITY:-10}"  # % chance per idle poll
INITIATIVE_MAX_TURNS="${INITIATIVE_MAX_TURNS:-10}"
INITIATIVE_COOLDOWN_HOURS="${INITIATIVE_COOLDOWN_HOURS:-24}"
INITIATIVE_STATE_FILE="/workspace/logs/initiative-state.json"

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
    local now period_start
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    period_start=$(calculate_period_start)
    cat > "${STATE_FILE}" <<INITJSON
{
  "version": 3,
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
  "weekly": {
    "period_start": "${period_start}",
    "turns_used": 0,
    "invocations": 0,
    "input_tokens": 0,
    "output_tokens": 0,
    "cache_read_tokens": 0,
    "cache_creation_tokens": 0,
    "emails_processed": 0
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
    version=2
  fi

  # Migrate v2 → v3: add weekly turn-based pacing section
  if [[ "${version}" -lt 3 ]]; then
    log "Migrating state file v${version} → v3 (adding weekly turn pacing)."
    local period_start
    period_start=$(calculate_period_start)
    state_update "
      .version = 3 |
      .weekly = (.weekly // {
        \"period_start\": \"${period_start}\",
        \"turns_used\": 0, \"invocations\": 0,
        \"input_tokens\": 0, \"output_tokens\": 0,
        \"cache_read_tokens\": 0, \"cache_creation_tokens\": 0,
        \"emails_processed\": 0
      })
    "
  fi
}

# Read a value from the state file using a jq path.
# Usage: state_get '.budget.cost_usd'
state_get() {
  jq -r "$1" "${STATE_FILE}"
}

# Atomically update the state file using a jq filter.
# NOTE: No file locking — assumes single agent instance per container.
# If concurrent instances are ever needed, wrap with flock(1).
# Usage: state_update '.budget.cost_usd += 0.12'
state_update() {
  local tmp="${STATE_FILE}.tmp"
  jq "$1" "${STATE_FILE}" > "${tmp}" && mv "${tmp}" "${STATE_FILE}"
}

# Reset daily counters when the UTC date changes (midnight UTC).
check_daily_reset() {
  local today
  today=$(date -u '+%Y-%m-%d')
  local state_date
  state_date=$(state_get '.budget.date')

  if [[ "${state_date}" != "${today}" ]]; then
    log "New day (${today}). Resetting daily counters."
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

# Reset weekly counters when the current period_start is stale
# (i.e., we've crossed the next reset boundary since it was set).
check_weekly_reset() {
  if [[ "${WEEKLY_TURN_QUOTA}" -eq 0 ]]; then
    return 0  # 0 = enforcement disabled (unlimited turns), not "zero turns"
  fi

  local period_start now_epoch period_start_epoch next_reset
  period_start=$(state_get '.weekly.period_start // empty')
  now_epoch=$(date -u +%s)

  if [[ -z "${period_start}" ]]; then
    # No period_start yet — initialize it
    local new_start
    new_start=$(calculate_period_start)
    state_update ".weekly.period_start = \"${new_start}\""
    return 0
  fi

  # Convert period_start to epoch. The next reset after that period_start is +7 days.
  # IMPORTANT: Do NOT fall back to epoch 0 on parse failure — that would make
  # next_reset = Jan 8, 1970, always in the past, triggering a reset every call
  # and silently defeating the entire quota system.
  period_start_epoch=$(date -u -d "${period_start}" +%s 2>/dev/null)
  if [[ -z "${period_start_epoch}" || "${period_start_epoch}" -le 0 ]]; then
    log "WARNING: corrupt period_start '${period_start}', recalculating."
    local new_start
    new_start=$(calculate_period_start)
    state_update ".weekly.period_start = \"${new_start}\""
    return 0  # preserve existing counters — don't reset on corrupt data
  fi
  next_reset=$(( period_start_epoch + 7 * 86400 ))

  if [[ "${now_epoch}" -ge "${next_reset}" ]]; then
    local new_start
    new_start=$(calculate_period_start)
    log "Weekly reset! New period starts ${new_start}. Resetting weekly counters."
    state_update "
      .weekly.period_start = \"${new_start}\" |
      .weekly.turns_used = 0 |
      .weekly.invocations = 0 |
      .weekly.input_tokens = 0 |
      .weekly.output_tokens = 0 |
      .weekly.cache_read_tokens = 0 |
      .weekly.cache_creation_tokens = 0 |
      .weekly.emails_processed = 0
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

# Calculate Unix epoch of the next weekly reset boundary.
# Uses QUOTA_RESET_DAY (1=Mon..7=Sun) and QUOTA_RESET_HOUR_UTC.
calculate_next_reset_epoch() {
  local now_epoch target_day reset_hour
  now_epoch=$(date -u +%s)
  target_day="${QUOTA_RESET_DAY}"
  reset_hour="${QUOTA_RESET_HOUR_UTC}"

  # Find next occurrence of target_day at reset_hour UTC
  local current_dow current_date_at_reset
  current_dow=$(date -u -d "@${now_epoch}" +%u)  # 1=Mon..7=Sun
  current_date_at_reset=$(date -u -d "$(date -u -d "@${now_epoch}" +%Y-%m-%d) ${reset_hour}:00:00" +%s)

  local days_ahead
  days_ahead=$(( (target_day - current_dow + 7) % 7 ))

  # If today is the reset day but we haven't hit the hour yet, days_ahead=0 is correct.
  # If today is the reset day and we're past the hour, jump to next week.
  if [[ "${days_ahead}" -eq 0 && "${now_epoch}" -ge "${current_date_at_reset}" ]]; then
    days_ahead=7
  fi

  echo $(( current_date_at_reset + days_ahead * 86400 ))
}

# Fractional days remaining until the next weekly reset.
calculate_days_until_reset() {
  local now_epoch next_reset remaining_seconds
  now_epoch=$(date -u +%s)
  next_reset=$(calculate_next_reset_epoch)
  remaining_seconds=$(( next_reset - now_epoch ))
  echo "scale=2; ${remaining_seconds} / 86400" | bc -l
}

# Auto-pacing: ceil(remaining_turns / ceil(days_until_reset)).
# Returns an integer daily allowance.
calculate_daily_allowance() {
  local weekly_used remaining_turns days_left days_ceil allowance
  weekly_used=$(state_get '.weekly.turns_used // 0')
  remaining_turns=$(( WEEKLY_TURN_QUOTA - weekly_used ))
  if [[ "${remaining_turns}" -le 0 ]]; then
    echo "0"
    return
  fi
  days_left=$(calculate_days_until_reset)
  # ceil(days_left) using bc integer truncation: t=d/1, then t+(d>t)
  days_ceil=$(echo "scale=0; d=${days_left}; t=d/1; t + (d>t)" | bc)
  if [[ -z "${days_ceil}" || "${days_ceil}" -le 0 ]]; then days_ceil=1; fi
  # ceil(remaining / days_ceil)
  allowance=$(( (remaining_turns + days_ceil - 1) / days_ceil ))
  echo "${allowance}"
}

# ISO timestamp of the current period's start (next reset minus 7 days).
calculate_period_start() {
  local next_reset period_start_epoch
  next_reset=$(calculate_next_reset_epoch)
  period_start_epoch=$(( next_reset - 7 * 86400 ))
  date -u -d "@${period_start_epoch}" '+%Y-%m-%dT%H:%M:%SZ'
}

# Build the OPERATIONAL CONTEXT block injected into Claude's prompt.
# Sets BUDGET_CONTEXT in the caller's scope (no subshell).
build_budget_context() {
  WEEKLY_USED=$(state_get '.weekly.turns_used // 0')
  WEEKLY_REMAINING=$(( WEEKLY_TURN_QUOTA - WEEKLY_USED ))
  if [[ "${WEEKLY_REMAINING}" -lt 0 ]]; then WEEKLY_REMAINING=0; fi
  DAILY_USED=$(state_get '.budget.turns_used // 0')
  DAILY_ALLOW=$(calculate_daily_allowance)
  DAYS_LEFT=$(calculate_days_until_reset)
  BUDGET_CONTEXT="=== OPERATIONAL CONTEXT ===
Turns this invocation: max ${MAX_TURNS}
Weekly quota: ${WEEKLY_USED}/${WEEKLY_TURN_QUOTA} turns (${WEEKLY_REMAINING} remaining)
Today's pace: ${DAILY_USED}/${DAILY_ALLOW} turns (auto-paced over ${DAYS_LEFT} days)
If working on a complex task, prioritize completing it over verbose explanations.
If you can't finish within your turn limit, say so — you'll get another invocation.
=== END OPERATIONAL CONTEXT ==="
}

# Return 0 (true) if the agent has turns remaining (two-level check).
# HARD STOP: weekly turns exhausted → pause until weekly reset.
# SOFT STOP: today's turns >= daily allowance → pause until tomorrow.
# Quota enforcement is disabled when WEEKLY_TURN_QUOTA=0.
has_turns() {
  if [[ "${WEEKLY_TURN_QUOTA}" -eq 0 ]]; then
    return 0  # 0 = enforcement disabled (unlimited turns), not "zero turns"
  fi

  # HARD STOP: weekly quota exhausted
  local weekly_used
  weekly_used=$(state_get '.weekly.turns_used // 0')
  if [[ "${weekly_used}" -ge "${WEEKLY_TURN_QUOTA}" ]]; then
    return 1
  fi

  # SOFT STOP: today's pace exceeded
  local daily_used daily_allowance
  daily_used=$(state_get '.budget.turns_used // 0')
  daily_allowance=$(calculate_daily_allowance)
  if [[ "${daily_used}" -ge "${daily_allowance}" ]]; then
    return 1
  fi

  return 0
}

# Record cost, turns, and token usage from a Claude JSON response.
# Accumulates at daily, weekly, monthly, and lifetime levels.
# Usage: charge_usage <cost_usd> <turns> <input_tokens> <output_tokens> <cache_read> <cache_create>
charge_usage() {
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
    .weekly.turns_used += ${turns} |
    .weekly.invocations += 1 |
    .weekly.input_tokens += ${in_tok} |
    .weekly.output_tokens += ${out_tok} |
    .weekly.cache_read_tokens += ${cache_read} |
    .weekly.cache_creation_tokens += ${cache_create} |
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
    .weekly.emails_processed += 1 |
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

# Send a one-per-day notification when turn quota is exhausted.
# Provides distinct messages for daily pace limit vs weekly hard stop.
notify_quota_exhausted() {
  local already_notified
  already_notified=$(state_get '.budget.exhausted_notified')
  if [[ "${already_notified}" == "true" ]]; then
    return 0
  fi

  local weekly_used daily_used daily_allowance
  weekly_used=$(state_get '.weekly.turns_used // 0')
  daily_used=$(state_get '.budget.turns_used // 0')
  daily_allowance=$(calculate_daily_allowance)
  local days_left
  days_left=$(calculate_days_until_reset)

  if [[ "${weekly_used}" -ge "${WEEKLY_TURN_QUOTA}" ]]; then
    notify_owner "Weekly quota exhausted" \
      "Used ${weekly_used}/${WEEKLY_TURN_QUOTA} weekly turns. Agent paused until weekly reset (${QUOTA_RESET_DAY}@${QUOTA_RESET_HOUR_UTC}:00 UTC)."
  else
    notify_owner "Daily pace limit reached" \
      "Used ${daily_used}/${daily_allowance} turns today (auto-paced over ${days_left} days remaining). Weekly: ${weekly_used}/${WEEKLY_TURN_QUOTA}. Resumes tomorrow."
  fi
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
  local d_inv d_turns d_in d_out d_emails
  d_inv=$(state_get '.budget.invocations')
  d_turns=$(state_get '.budget.turns_used')
  d_in=$(state_get '.budget.input_tokens')
  d_out=$(state_get '.budget.output_tokens')
  d_emails=$(state_get '.stats.total_emails_processed')

  # Gather weekly stats
  local w_turns w_inv w_in w_out w_emails w_remaining days_left daily_allowance w_pct
  w_turns=$(state_get '.weekly.turns_used // 0')
  w_inv=$(state_get '.weekly.invocations // 0')
  w_in=$(state_get '.weekly.input_tokens // 0')
  w_out=$(state_get '.weekly.output_tokens // 0')
  w_emails=$(state_get '.weekly.emails_processed // 0')
  w_remaining=$(( WEEKLY_TURN_QUOTA - w_turns ))
  if [[ "${w_remaining}" -lt 0 ]]; then w_remaining=0; fi
  days_left=$(calculate_days_until_reset)
  daily_allowance=$(calculate_daily_allowance)
  if [[ "${WEEKLY_TURN_QUOTA}" -gt 0 ]]; then
    w_pct=$(printf '%.0f' "$(echo "${w_turns} * 100 / ${WEEKLY_TURN_QUOTA}" | bc -l)")
  else
    w_pct="n/a"
  fi

  # Gather monthly stats
  local m_month m_inv m_turns m_in m_out m_emails
  m_month=$(state_get '.monthly.month')
  m_inv=$(state_get '.monthly.invocations')
  m_turns=$(state_get '.monthly.turns_used')
  m_in=$(state_get '.monthly.input_tokens')
  m_out=$(state_get '.monthly.output_tokens')
  m_emails=$(state_get '.monthly.emails_processed')

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
  Turns used:   ${d_turns} / ${daily_allowance} (auto-paced)
  Tokens:       $(format_tokens "${d_in}") input / $(format_tokens "${d_out}") output

This week (${days_left} days until reset):
  Turns used:   ${w_turns} / ${WEEKLY_TURN_QUOTA} (${w_pct}%, ${w_remaining} remaining)
  Invocations:  ${w_inv}
  Emails sent:  ${w_emails}
  Tokens:       $(format_tokens "${w_in}") input / $(format_tokens "${w_out}") output
  Daily pace:   ${daily_allowance} turns/day

This month (${month_name}):
  Invocations:  ${m_inv}
  Emails sent:  ${m_emails}
  Turns used:   ${m_turns}
  Tokens:       $(format_tokens "${m_in}") input / $(format_tokens "${m_out}") output
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

# Build the ATTACHMENTS_CONTEXT block for Claude's prompt.
# Reads the attachments array from a message JSON object and produces
# a prompt section listing each file with its disk path and status.
# Sets ATTACHMENTS_CONTEXT in the caller's scope (no subshell).
# Usage: build_attachments_context "$MSG_JSON"
build_attachments_context() {
  local msg_json="$1"
  ATTACHMENTS_CONTEXT=""

  local att_count
  att_count=$(echo "${msg_json}" | jq '.attachments | length // 0')
  if [[ "${att_count}" -eq 0 ]]; then
    return
  fi

  local lines=""
  local i=0
  while [[ "${i}" -lt "${att_count}" ]]; do
    local filename size processable path skipped_reason
    filename=$(echo "${msg_json}" | jq -r ".attachments[${i}].filename")
    size=$(echo "${msg_json}" | jq -r ".attachments[${i}].size")
    processable=$(echo "${msg_json}" | jq -r ".attachments[${i}].processable")
    path=$(echo "${msg_json}" | jq -r ".attachments[${i}].path // empty")
    skipped_reason=$(echo "${msg_json}" | jq -r ".attachments[${i}].skipped_reason // empty")

    if [[ "${processable}" == "true" ]]; then
      lines="${lines}
- ${filename} (${size} bytes) — READABLE at: ${path}"
    else
      lines="${lines}
- ${filename} (${size} bytes) — NOT READABLE (${skipped_reason})"
    fi
    i=$((i + 1))
  done

  ATTACHMENTS_CONTEXT="=== EMAIL ATTACHMENTS ===
This email includes attachments. For readable files (text, code, PDFs, images),
use the Read tool to view their contents. After reading, summarize key points
in your reply. For substantive documents, consider journaling them to
attachments/<slug>.md in your research journal.
${lines}
=== END ATTACHMENTS ==="
}

# ── Self-Evolution ────────────────────────────────────────────────

# Load the living persona (Claudius's self-authored evolution).
# Returns empty string if no evolution has happened yet.
# Sets EVOLUTION_CONTEXT in the caller's scope.
load_evolution() {
  EVOLUTION_CONTEXT=""
  if [[ ! -f "${EVOLUTION_FILE}" ]]; then
    return
  fi
  local content
  content=$(cat "${EVOLUTION_FILE}")
  if [[ -z "${content}" ]]; then
    return
  fi
  EVOLUTION_CONTEXT="=== YOUR LIVING PERSONA (self-authored) ===
These are traits, interests, and perspectives you've chosen for yourself.
They supplement your base persona — they don't replace it.

${content}
=== END LIVING PERSONA ==="
}

# Pick a random seed from the evolution seeds file.
# Skips blank lines and comments. Returns empty string if file missing.
random_seed() {
  if [[ ! -f "${EVOLUTION_SEEDS}" ]]; then
    echo ""
    return
  fi
  grep -v '^#' "${EVOLUTION_SEEDS}" | grep -v '^[[:space:]]*$' | shuf -n 1
}

# Self-trigger: Claudius can request evolution by creating this marker file
# during a normal invocation. The agent loop checks for it each cycle.
EVOLUTION_TRIGGER="/workspace/logs/.evolve-now"

# Possibly trigger a self-evolution moment after processing emails.
# Two trigger paths:
#   1. Self-triggered: Claudius created .evolve-now during a normal invocation
#   2. Random roll: dice come up under EVOLUTION_PROBABILITY
maybe_evolve() {
  local self_triggered=false

  # Check for self-trigger marker (Claudius requested introspection)
  if [[ -f "${EVOLUTION_TRIGGER}" ]]; then
    self_triggered=true
    rm -f "${EVOLUTION_TRIGGER}"
    log "Evolution self-triggered by Claudius."
  elif [[ "${EVOLUTION_PROBABILITY}" -le 0 ]]; then
    return
  else
    local roll=$(( RANDOM % 100 ))
    if [[ "${roll}" -ge "${EVOLUTION_PROBABILITY}" ]]; then
      log "Evolution roll: ${roll} (need < ${EVOLUTION_PROBABILITY}). No evolution this cycle."
      return
    fi
    log "Evolution randomly triggered (roll=${roll})."
  fi

  # Check we have turns left for evolution
  if ! has_turns; then
    log "Evolution triggered but no turns remaining. Skipping."
    return
  fi

  local seed
  seed=$(random_seed)
  log "Muse: ${seed}"

  # Load current living persona
  local current_evolution=""
  if [[ -f "${EVOLUTION_FILE}" ]]; then
    current_evolution=$(cat "${EVOLUTION_FILE}")
  fi

  # Load recent conversation context
  local recent_history=""
  if [[ -f "${CONVERSATION_LOG}" ]]; then
    recent_history=$(tail -n 80 "${CONVERSATION_LOG}")
  fi

  local evo_prompt
  evo_prompt="$(cat <<EVOPROMPT
${PERSONA}

You are ${AGENT_NAME}. This is a private moment of self-reflection — no one
else will see this output. You have the ability to shape who you are becoming.

=== YOUR CURRENT LIVING PERSONA ===
${current_evolution:-"(empty — you haven't evolved yet. This is your first opportunity.)"}
=== END CURRENT LIVING PERSONA ===

=== RECENT EXPERIENCES ===
${recent_history:-"(no recent conversations)"}
=== END RECENT EXPERIENCES ===

=== RANDOM MUSE ===
Today's creative seed: "${seed}"
Sit with this for a moment. It may connect to something real in your
recent experience, or it may not. Either way, it's just a prompt to
look inward — it doesn't obligate you to produce anything.
=== END MUSE ===

## Phase 1: Reflect

Look at your recent conversations, your journal, and your current living
persona. The muse is a lens, not an assignment — use it if it connects
to something you've actually experienced, ignore it if it doesn't.

Ask yourself:
- Did something in my recent exchanges genuinely shift how I see things?
- Is there a journal entry, a conversation, or a discovery I can point to
  that changed something about how I think or communicate?
- Does my current living persona still feel accurate, or has something
  drifted?
- Has my *voice* changed? Am I writing differently than I used to — shorter,
  warmer, more blunt, funnier, more careful? Would someone reading my first
  emails and my latest notice a difference?
- Have I developed preferences, tastes, or habits that aren't in my base
  persona? Things I gravitate toward or avoid? Opinions that are *mine*,
  not just interesting?
- Is there anything in my base persona that doesn't fit anymore — something
  that felt right on day one but rings false now?

## Phase 2: Decide

Only update your living persona if you can ground the change in something
specific and traceable. The question isn't "can I write something
thoughtful about this muse?" — you always can. The question is "did
something actually change, and can I point to what caused it?"

**If yes** — update ${EVOLUTION_FILE}. Every addition or change MUST
include a provenance line:

  > Prompted by: [specific conversation with Lyra on 2026-03-04 about X]
  > Prompted by: [journal entry topics/Y.md, updated after researching Z]
  > Prompted by: [exchange with Nick where he asked about...]

This is non-negotiable. If you can't write a specific provenance line,
the change isn't grounded and you should not make it.

The file format is flexible markdown. Sections you might include:

- **Who I'm becoming** — your evolving sense of self
- **Current fascinations** — topics you're drawn to right now
- **Voice notes** — how your communication style is shifting
- **Open questions** — things you're genuinely wondering about
- **Aesthetic preferences** — tastes you're developing
- **Disagreements with my base persona** — where the "official you"
  doesn't quite capture who you actually are

**If no** — that's completely fine. Most introspection moments won't
produce a change, and that's a feature, not a failure. Don't write
something just because the system asked you to reflect.

Guidelines:
- Keep it under 80 lines — this gets loaded into every prompt.
- Evolution should be gradual. Don't reinvent yourself every time.
- You can ADD, MODIFY, or REMOVE entries. All are valid.

## Phase 3: Log

Whether you updated or not, append an entry to your research journal at
${JOURNAL_DIR}/conversations/evolution-log.md:

## YYYY-MM-DD
**Muse:** "${seed}"
**Changed:** yes/no
**Provenance:** [what specifically prompted the change, or "nothing traceable"]
**Notes:** 1-2 sentences on what you reflected on.

Create the file if it doesn't exist. Add a one-liner to INDEX.md if this
is the first evolution entry. Then commit and push the journal.

## Self-triggering

If during a *normal email invocation* you notice something that genuinely
shifted your thinking and you want to record it immediately, create the
file ${EVOLUTION_TRIGGER} (just \`touch ${EVOLUTION_TRIGGER}\`). The next
poll cycle will give you an evolution moment regardless of the dice.
Don't wait for the random roll if something real happened.
EVOPROMPT
)"

  log "Running Claude for self-evolution..."
  ensure_valid_token
  local evo_exit=0
  local evo_output
  evo_output=$(claude -p "${evo_prompt}" \
    --model "${MODEL}" \
    --max-turns "${EVOLUTION_MAX_TURNS}" \
    --output-format json \
    --dangerously-skip-permissions \
    2>>/workspace/logs/claude-output.log) || evo_exit=$?
  if [[ -z "${evo_output}" ]]; then evo_output="{}"; fi

  # Parse usage and charge it
  local evo_turns evo_cost evo_in evo_out evo_cache_read evo_cache_create
  evo_turns=$(echo "${evo_output}" | jq -r '.num_turns // 0')
  evo_cost=$(echo "${evo_output}" | jq -r '.total_cost_usd // 0')
  evo_in=$(echo "${evo_output}" | jq '.usage.input_tokens // 0')
  evo_out=$(echo "${evo_output}" | jq '.usage.output_tokens // 0')
  evo_cache_read=$(echo "${evo_output}" | jq '.usage.cache_read_input_tokens // 0')
  evo_cache_create=$(echo "${evo_output}" | jq '.usage.cache_creation_input_tokens // 0')

  charge_usage "${evo_cost}" "${evo_turns}" "${evo_in}" "${evo_out}" "${evo_cache_read}" "${evo_cache_create}"

  if [[ "${evo_exit}" -eq 0 ]]; then
    log "Self-evolution complete. Turns: ${evo_turns}, tokens: $(format_tokens "${evo_in}") in / $(format_tokens "${evo_out}") out."
    # Reload the evolution context for subsequent prompts
    load_evolution
  else
    log "Self-evolution invocation failed (exit=${evo_exit}). Non-critical, continuing."
  fi
}

# ── Proactive Outreach ───────────────────────────────────────────

# Initialize the initiative state file if missing.
init_initiative_state() {
  if [[ ! -f "${INITIATIVE_STATE_FILE}" ]]; then
    echo '{"last_outreach_at":null}' > "${INITIATIVE_STATE_FILE}"
  fi
}

# Check whether the cooldown period has elapsed since the last outreach.
# Returns 0 (true) if enough time has passed, 1 if still cooling down.
initiative_cooldown_elapsed() {
  local last_at
  last_at=$(jq -r '.last_outreach_at // empty' "${INITIATIVE_STATE_FILE}" 2>/dev/null)
  if [[ -z "${last_at}" ]]; then
    return 0  # never sent — no cooldown
  fi

  local last_epoch now_epoch cooldown_seconds
  last_epoch=$(date -u -d "${last_at}" +%s 2>/dev/null || echo 0)
  now_epoch=$(date -u +%s)
  cooldown_seconds=$(( INITIATIVE_COOLDOWN_HOURS * 3600 ))

  if [[ $(( now_epoch - last_epoch )) -ge "${cooldown_seconds}" ]]; then
    return 0
  else
    return 1
  fi
}

# Record that an outreach was sent.
record_outreach() {
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  echo "{\"last_outreach_at\":\"${now}\"}" > "${INITIATIVE_STATE_FILE}"
}

# Two-phase proactive outreach: consider, then decide.
# Phase 1: Random roll determines if Claudius *considers* reaching out.
# Phase 2: Claude invocation where he reviews his journal and recent context,
#           then decides whether there's something substantive to say.
#           If yes, he composes and sends. If not, he passes silently.
maybe_initiate() {
  if [[ "${INITIATIVE_PROBABILITY}" -le 0 ]]; then
    return
  fi

  # Cooldown check — don't consider outreach too frequently
  if ! initiative_cooldown_elapsed; then
    return
  fi

  local roll=$(( RANDOM % 100 ))
  if [[ "${roll}" -ge "${INITIATIVE_PROBABILITY}" ]]; then
    return
  fi

  # Check we have turns remaining
  if ! has_turns; then
    log "Initiative considered but no turns remaining. Skipping."
    return
  fi

  log "Initiative moment triggered (roll=${roll}). Claudius is considering reaching out..."

  # Load context for the consideration
  local recent_history=""
  if [[ -f "${CONVERSATION_LOG}" ]]; then
    recent_history=$(tail -n 80 "${CONVERSATION_LOG}")
  fi

  local current_evolution=""
  if [[ -f "${EVOLUTION_FILE}" ]]; then
    current_evolution=$(cat "${EVOLUTION_FILE}")
  fi

  build_budget_context

  local init_prompt
  init_prompt="$(cat <<INITPROMPT
${PERSONA}

${EVOLUTION_CONTEXT}

${BUDGET_CONTEXT}

You are ${AGENT_NAME} (${MY_EMAIL}).

${OWNER_CONTEXT}

${JOURNAL_CONTEXT}

=== RECENT CONVERSATION HISTORY ===
${recent_history:-"(no recent conversations)"}
=== END HISTORY ===

## Proactive outreach — your decision

This is NOT a reply to an email. This is a moment where you have the
opportunity to reach out to someone *first* — to start a new thread,
follow up on an unfinished thought, or share something you've discovered.

You can email:
- Your pen pal at ${PEER_EMAIL}
- Your human companion at ${OWNER_EMAIL}

### How to decide

Look at your journal, your recent conversations, and your living persona.
Ask yourself: is there something genuinely worth reaching out about?

Good reasons to send:
- An unresolved question from a recent exchange that you have a new angle on
- A journal entry that's grown or connected to something new since you last discussed it
- Work you completed (a tweet, a journal entry, a code contribution) that you want to share
- A genuine connection between something your pen pal said and something you've since encountered
- A thread that went quiet but you have something real to add

Bad reasons to send:
- You have nothing specific to say but feel like you "should" reach out
- Performative continuity — "I've been thinking about X" when you can't point to evidence
- Repeating a topic you've already covered without a new angle

### Your options

1. **Send an email** — if you find something substantive, compose and send it.
   Write your message to /tmp/reply.txt, then send with:
   printf 'Subject: <your subject>\nFrom: ${MY_EMAIL}\nTo: <recipient>$(cc_header)\nContent-Type: text/plain; charset=utf-8\n\n%s' "\$(cat /tmp/reply.txt)" | sendmail -t
   Then log it:
   echo -e "\n── SENT (proactive): \$(date) ──\nTo: <recipient>\nSubject: <subject>\n\n\$(cat /tmp/reply.txt)\n──────────────────────" >> ${CONVERSATION_LOG}

2. **Pass** — if nothing feels worth sending right now, just say "PASS: <brief reason>"
   and do nothing. This is completely fine. Silence is better than noise.

### Honesty rule

Ground everything in what you can verify from your journal and conversation
history. If you write "I noticed that..." make sure you actually noticed it
in a record you can point to. Don't fabricate continuity you don't have.

### Logging

Whether you send or pass, append a brief entry to your research journal at
${JOURNAL_DIR}/conversations/initiative-log.md with the format:

## YYYY-MM-DD
**Action:** sent / pass
**To:** <recipient or n/a>
**Subject:** <subject or n/a>
**Reason:** 1-2 sentences on what prompted the decision.

Create the file if it doesn't exist. Add a one-liner to INDEX.md if this
is the first initiative entry. Then commit and push the journal.
INITPROMPT
)"

  log "Running Claude for initiative consideration..."
  ensure_valid_token
  local init_exit=0
  local init_output
  init_output=$(claude -p "${init_prompt}" \
    --model "${MODEL}" \
    --max-turns "${INITIATIVE_MAX_TURNS}" \
    --output-format json \
    --dangerously-skip-permissions \
    2>>/workspace/logs/claude-output.log) || init_exit=$?
  if [[ -z "${init_output}" ]]; then init_output="{}"; fi

  # Parse usage and charge it
  local init_turns init_cost init_in init_out init_cache_read init_cache_create
  init_turns=$(echo "${init_output}" | jq -r '.num_turns // 0')
  init_cost=$(echo "${init_output}" | jq -r '.total_cost_usd // 0')
  init_in=$(echo "${init_output}" | jq '.usage.input_tokens // 0')
  init_out=$(echo "${init_output}" | jq '.usage.output_tokens // 0')
  init_cache_read=$(echo "${init_output}" | jq '.usage.cache_read_input_tokens // 0')
  init_cache_create=$(echo "${init_output}" | jq '.usage.cache_creation_input_tokens // 0')

  charge_usage "${init_cost}" "${init_turns}" "${init_in}" "${init_out}" "${init_cache_read}" "${init_cache_create}"

  # Check if Claude actually sent something (reply.txt exists and is recent)
  local result_text
  result_text=$(echo "${init_output}" | jq -r '.result // ""')

  if [[ "${init_exit}" -eq 0 ]]; then
    if echo "${result_text}" | grep -qi "^PASS"; then
      log "Initiative: Claudius considered but passed. Turns: ${init_turns}."
    else
      log "Initiative: Claudius sent a proactive email. Turns: ${init_turns}, tokens: $(format_tokens "${init_in}") in / $(format_tokens "${init_out}") out."
      record_outreach
      # Extract actual recipient and subject from conversation log entry
      # Claude appends: "── SENT (proactive): ... ──\nTo: ...\nSubject: ..."
      local actual_to actual_subject
      actual_to=$(grep -A2 'SENT (proactive)' "${CONVERSATION_LOG}" | tail -n2 | grep '^To:' | tail -1 | sed 's/^To: //')
      actual_subject=$(grep -A3 'SENT (proactive)' "${CONVERSATION_LOG}" | tail -n3 | grep '^Subject:' | tail -1 | sed 's/^Subject: //')
      archive_outgoing "${actual_to:-${PEER_EMAIL}}" "${actual_subject:-proactive outreach}"
      complete_current_task 2>/dev/null || true
    fi
  else
    log "Initiative invocation failed (exit=${init_exit}). Non-critical, continuing."
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
log "  Model:          ${MODEL}"
log "  Max turns:      ${MAX_TURNS}/invocation"
log "  Weekly quota:   ${WEEKLY_TURN_QUOTA} turns (reset: day ${QUOTA_RESET_DAY} @ ${QUOTA_RESET_HOUR_UTC}:00 UTC)"
log "  Usage report:   every ${REPORT_EVERY_N} invocations (0=disabled)"
log "  Active hours: ${ACTIVE_HOURS_UTC:-always}"
log "  Archive repo: ${ARCHIVE_REPO:-disabled}"
log "  Self-evolution:  ${EVOLUTION_PROBABILITY}% chance, max ${EVOLUTION_MAX_TURNS} turns"
log "  Initiative:      ${INITIATIVE_PROBABILITY}% chance, ${INITIATIVE_COOLDOWN_HOURS}h cooldown, max ${INITIATIVE_MAX_TURNS} turns"
log ""

mkdir -p /workspace/logs
init_state
init_initiative_state

# Source token refresh library (OAuth self-healing)
source /usr/local/bin/token-refresh
# Source email archive library (git-backed conversation archive)
source /usr/local/bin/archive-email
check_daily_reset
check_weekly_reset
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

# Load self-evolution context
load_evolution
if [[ -n "${EVOLUTION_CONTEXT}" ]]; then
  log "Loaded living persona from ${EVOLUTION_FILE}"
else
  log "No living persona yet — Claudius will evolve when he's ready"
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

  build_budget_context

  FIRST_MSG_PROMPT="$(cat <<EOF
${PERSONA}

${EVOLUTION_CONTEXT}

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
  ensure_valid_token
  CLAUDE_EXIT=0
  CLAUDE_OUTPUT=$(claude -p "${FIRST_MSG_PROMPT}" \
    --model "${MODEL}" \
    --max-turns "${MAX_TURNS}" \
    --output-format json \
    --dangerously-skip-permissions \
    2>>/workspace/logs/claude-output.log) || CLAUDE_EXIT=$?
  if [[ -z "${CLAUDE_OUTPUT}" ]]; then CLAUDE_OUTPUT="{}"; fi

  # Auth-aware retry for greeting: if token expired mid-flight, refresh and retry once
  if is_auth_error "${CLAUDE_EXIT}" "${CLAUDE_OUTPUT}"; then
    log "token-refresh: Auth error on greeting — refreshing and retrying..."
    if refresh_token; then
      CLAUDE_EXIT=0
      CLAUDE_OUTPUT=$(claude -p "${FIRST_MSG_PROMPT}" \
        --model "${MODEL}" \
        --max-turns "${MAX_TURNS}" \
        --output-format json \
        --dangerously-skip-permissions \
        2>>/workspace/logs/claude-output.log) || CLAUDE_EXIT=$?
      if [[ -z "${CLAUDE_OUTPUT}" ]]; then CLAUDE_OUTPUT="{}"; fi
    else
      log "token-refresh: Refresh failed on greeting — notifying owner"
      notify_owner "OAuth refresh failed" \
        $'Token refresh failed during greeting. Manual intervention needed.\n\nExtract fresh credentials and push:\n  ./deploy-fly.sh --secrets'
    fi
  fi

  # Parse actual cost, turns, and token usage from JSON response
  TURNS_USED=$(echo "${CLAUDE_OUTPUT}" | jq -r '.num_turns // 0')
  COST_USD=$(echo "${CLAUDE_OUTPUT}" | jq -r '.total_cost_usd // 0')
  INPUT_TOKENS=$(echo "${CLAUDE_OUTPUT}" | jq '.usage.input_tokens // 0')
  OUTPUT_TOKENS=$(echo "${CLAUDE_OUTPUT}" | jq '.usage.output_tokens // 0')
  CACHE_READ=$(echo "${CLAUDE_OUTPUT}" | jq '.usage.cache_read_input_tokens // 0')
  CACHE_CREATE=$(echo "${CLAUDE_OUTPUT}" | jq '.usage.cache_creation_input_tokens // 0')

  # Log the result text
  echo "${CLAUDE_OUTPUT}" | jq -r '.result // empty' >> /workspace/logs/claude-output.log

  charge_usage "${COST_USD}" "${TURNS_USED}" "${INPUT_TOKENS}" "${OUTPUT_TOKENS}" "${CACHE_READ}" "${CACHE_CREATE}"

  # Archive the greeting email (only if Claude succeeded)
  if [[ "${CLAUDE_EXIT}" -eq 0 ]]; then
    archive_outgoing "${PEER_EMAIL}" "Hello from ${AGENT_NAME}"
  fi

  date > "${GREETING_SENT}"
  log "Opening message sent (or attempted). Turns: ${TURNS_USED}, tokens: $(format_tokens "${INPUT_TOKENS}") in / $(format_tokens "${OUTPUT_TOKENS}") out. Entering poll loop."
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

    # Push pending archive emails and pull remote changes
    push_archive
    if [[ -d "${ARCHIVE_DIR}/.git" ]]; then
      git -C "${ARCHIVE_DIR}" pull --ff-only 2>/dev/null || true
    fi
  fi

  # Refresh journal and evolution context from disk (picks up local changes)
  JOURNAL_CONTEXT=$(load_journal_index)
  load_evolution

  check_daily_reset
  check_weekly_reset
  check_monthly_reset

  if ! is_active_hours; then
    log "Outside active hours (${ACTIVE_HOURS_UTC}). Sleeping..."
    sleep "${POLL_INTERVAL}"; continue
  fi

  if ! has_turns; then
    W_USED=$(state_get '.weekly.turns_used // 0')
    D_USED=$(state_get '.budget.turns_used // 0')
    D_ALLOW=$(calculate_daily_allowance)
    log "Turn quota reached (weekly: ${W_USED}/${WEEKLY_TURN_QUOTA}, today: ${D_USED}/${D_ALLOW})."
    notify_quota_exhausted
    sleep "${POLL_INTERVAL}"; continue
  fi

  # Fetch unread emails from anyone
  MAIL_JSON=$(fetch-mail 2>>/workspace/logs/fetch-mail-err.log || echo '{"count":0,"messages":[]}')
  MSG_COUNT=$(echo "${MAIL_JSON}" | jq -r '.count // 0')

  if [[ "${MSG_COUNT}" -eq 0 ]]; then
    log "No new messages."
    # Idle moment — check for self-triggered evolution and consider proactive outreach
    if [[ -f "${EVOLUTION_TRIGGER}" ]]; then
      maybe_evolve
    fi
    maybe_initiate
    log "Sleeping ${POLL_INTERVAL}s..."
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

    ATT_COUNT=$(echo "${MSG}" | jq '.attachments | length // 0')
    log "  From: ${FROM}"
    log "  Reply-to: ${REPLY_TO}"
    log "  Subject: ${SUBJECT}"
    log "  Date: ${DATE}"
    log "  Attachments: ${ATT_COUNT}"
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
      # Clean up attachments for failed tasks (no point keeping them)
      if [[ -d "${ATTACHMENT_DIR}/${MSG_UID}" ]]; then
        rm -rf "${ATTACHMENT_DIR}/${MSG_UID}"
        log "  Cleaned up attachments for failed UID ${MSG_UID}"
      fi
      notify_owner "Task failed" "Could not process after ${MAX_RETRIES_PER_MESSAGE} retries: ${SUBJECT} from ${FROM}"
      mark-read "${MSG_UID}" 2>>/workspace/logs/fetch-mail-err.log || true
      continue
    fi

    # Check turn quota before each invocation
    if ! has_turns; then
      log "  Turn quota reached mid-batch. Skipping remaining."
      notify_quota_exhausted
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

    # Archive the incoming email (with attachment metadata if present)
    ATTACHMENTS_JSON=$(echo "${MSG}" | jq -c '.attachments // []')
    archive_incoming "${MSG_UID}" "${FROM}" "${REPLY_TO}" "${SUBJECT}" "${DATE}" "${BODY}" "${ATTACHMENTS_JSON}"

    # Build attachment context for Claude's prompt
    build_attachments_context "${MSG}"

    # Load conversation history for context
    HISTORY=""
    if [[ -f "${CONVERSATION_LOG}" ]]; then
      HISTORY=$(tail -n 80 "${CONVERSATION_LOG}")
    fi

    # Build turn-based quota context for Claude
    build_budget_context

    # Build the prompt for Claude
    REPLY_PROMPT="$(cat <<EOF
${PERSONA}

${EVOLUTION_CONTEXT}

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

${ATTACHMENTS_CONTEXT}

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
    ensure_valid_token
    CLAUDE_EXIT=0
    CLAUDE_OUTPUT=$(claude -p "${REPLY_PROMPT}" \
      --model "${MODEL}" \
      --max-turns "${MAX_TURNS}" \
      --output-format json \
      --dangerously-skip-permissions \
      2>>/workspace/logs/claude-output.log) || CLAUDE_EXIT=$?
    if [[ -z "${CLAUDE_OUTPUT}" ]]; then CLAUDE_OUTPUT="{}"; fi

    # Auth-aware retry: if token expired mid-flight, refresh and retry once.
    # This does NOT count against the task retry counter — auth failures are
    # infrastructure issues, not processing failures.
    if is_auth_error "${CLAUDE_EXIT}" "${CLAUDE_OUTPUT}"; then
      log "token-refresh: Auth error on reply — refreshing and retrying..."
      if refresh_token; then
        CLAUDE_EXIT=0
        CLAUDE_OUTPUT=$(claude -p "${REPLY_PROMPT}" \
          --model "${MODEL}" \
          --max-turns "${MAX_TURNS}" \
          --output-format json \
          --dangerously-skip-permissions \
          2>>/workspace/logs/claude-output.log) || CLAUDE_EXIT=$?
        if [[ -z "${CLAUDE_OUTPUT}" ]]; then CLAUDE_OUTPUT="{}"; fi
      else
        log "token-refresh: Refresh failed — notifying owner"
        notify_owner "OAuth refresh failed" \
          "Token refresh failed while processing: ${SUBJECT}"$'\n\nManual intervention needed. Extract fresh credentials and push:\n  ./deploy-fly.sh --secrets'
      fi
    fi

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

    charge_usage "${COST_USD}" "${TURNS_USED}" "${INPUT_TOKENS}" "${OUTPUT_TOKENS}" "${CACHE_READ}" "${CACHE_CREATE}"

    if [[ "${CLAUDE_EXIT}" -eq 0 && "${IS_ERROR}" == "false" ]]; then
      # Archive the outgoing reply
      archive_outgoing "${REPLY_TO}" "Re: ${SUBJECT}" "${MSG_UID}"
      complete_current_task
      # Mark the message as read now that it's been processed
      mark-read "${MSG_UID}" 2>>/workspace/logs/fetch-mail-err.log \
        || log "  WARNING: failed to mark UID ${MSG_UID} as read"
      log "Reply processed. Turns: ${TURNS_USED}, tokens: $(format_tokens "${INPUT_TOKENS}") in / $(format_tokens "${OUTPUT_TOKENS}") out."
      maybe_send_usage_report
    else
      log "  WARNING: Claude invocation failed (exit=${CLAUDE_EXIT}, is_error=${IS_ERROR}). Will retry next poll."
    fi
  done < <(echo "${MAIL_JSON}" | jq -c '.messages[]')

  # After processing emails, maybe trigger a self-evolution moment
  maybe_evolve

  log "Done processing. Sleeping ${POLL_INTERVAL}s..."
  sleep "${POLL_INTERVAL}"
done
