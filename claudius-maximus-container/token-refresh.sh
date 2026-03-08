#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# Token Refresh — OAuth token refresh library for headless Claude.
#
# Claude Code does not refresh OAuth tokens in headless (pipe) mode.
# Access tokens expire every ~8 hours. This library detects expiry,
# refreshes tokens via the Anthropic OAuth endpoint, and persists
# them to survive container restarts.
#
# Source this file; do not execute it directly.
# Usage: source /usr/local/bin/token-refresh
# ─────────────────────────────────────────────────────────────────

# Provide a log() fallback if not already defined (e.g., when sourced
# from entrypoint.sh before agent-loop.sh defines its own log function).
if ! declare -f log &>/dev/null; then
  log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fi

# ── Long-lived OAuth token (setup-token) ─────────────────────────
# If CLAUDE_CODE_OAUTH_TOKEN is set, Claude Code uses it directly and
# bypasses .credentials.json entirely. No refresh needed (1-year token).
# All refresh functions become no-ops.
OAUTH_TOKEN_MODE=false
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  OAUTH_TOKEN_MODE=true
fi

# Claude Code's public OAuth client ID (hardcoded in the CLI)
OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
OAUTH_TOKEN_URL="https://console.anthropic.com/v1/oauth/token"

# Paths
CRED_FILE="${HOME}/.claude/.credentials.json"
PERSISTENT_CRED="/workspace/persistent/claude-credentials.json"

# Refresh 30 minutes before actual expiry to avoid races
REFRESH_MARGIN_MS=$((30 * 60 * 1000))

# ── _do_oauth_refresh ─────────────────────────────────────────
# Shared helper: POSTs to the Anthropic OAuth endpoint with a
# refresh token, validates the response, and prints the parsed
# JSON to stdout. Callers handle credential file writes.
# Returns 0 on success, 1 on failure.
_do_oauth_refresh() {
  local refresh_token="$1"
  local caller="${2:-refresh}"  # label for log messages

  local request_body
  request_body=$(jq -n \
    --arg grant_type "refresh_token" \
    --arg refresh_token "${refresh_token}" \
    --arg client_id "${OAUTH_CLIENT_ID}" \
    '{grant_type: $grant_type, refresh_token: $refresh_token, client_id: $client_id}')

  local response http_code
  response=$(curl -s --max-time 10 -w "\n%{http_code}" \
    -X POST "${OAUTH_TOKEN_URL}" \
    -H "Content-Type: application/json" \
    -d "${request_body}" \
    2>/dev/null)

  http_code=$(echo "${response}" | tail -n1)
  response=$(echo "${response}" | sed '$d')

  if [[ "${http_code}" != "200" ]]; then
    local error_msg
    error_msg=$(echo "${response}" | jq -r '.error // .message // "unknown error"' 2>/dev/null || echo "HTTP ${http_code}")
    log "token-refresh: ${caller} failed (HTTP ${http_code}): ${error_msg}"
    return 1
  fi

  # Validate required fields are present
  local access_token new_rt
  access_token=$(echo "${response}" | jq -r '.access_token // empty')
  new_rt=$(echo "${response}" | jq -r '.refresh_token // empty')

  if [[ -z "${access_token}" || -z "${new_rt}" ]]; then
    log "token-refresh: ${caller} response missing tokens"
    return 1
  fi

  # Emit the raw response JSON for callers to consume
  echo "${response}"
  return 0
}

# ── _persist_credentials ─────────────────────────────────────
# Writes the active credentials file and copies to persistent
# volume (if available) using atomic temp+mv.
_persist_credentials() {
  if [[ -d "/workspace/persistent" ]]; then
    cp "${CRED_FILE}" "${PERSISTENT_CRED}.tmp" && mv "${PERSISTENT_CRED}.tmp" "${PERSISTENT_CRED}"
  fi
}

# ── bootstrap_from_refresh_token ──────────────────────────────
# Creates a fresh credentials file from a bare refresh token.
# Calls the OAuth endpoint, builds the full credentials JSON,
# and writes it to both active and persistent paths.
# Returns 0 on success, 1 on failure.
bootstrap_from_refresh_token() {
  local refresh_token="$1"

  if [[ -z "${refresh_token}" ]]; then
    log "token-refresh: bootstrap — no refresh token provided"
    return 1
  fi

  log "token-refresh: Bootstrapping credentials from refresh token..."

  local response
  response=$(_do_oauth_refresh "${refresh_token}" "Bootstrap") || return 1

  local new_access_token new_refresh_token expires_in new_expires_at
  new_access_token=$(echo "${response}" | jq -r '.access_token')
  new_refresh_token=$(echo "${response}" | jq -r '.refresh_token')
  expires_in=$(echo "${response}" | jq -r '.expires_in // empty')
  new_expires_at=$(( $(date -u +%s) * 1000 + ${expires_in:-28800} * 1000 ))

  # Build the full credentials JSON from scratch, including metadata
  # fields that Claude Code may read at runtime.
  mkdir -p "$(dirname "${CRED_FILE}")"
  jq -n \
    --arg at "${new_access_token}" \
    --arg rt "${new_refresh_token}" \
    --argjson ea "${new_expires_at}" \
    '{claudeAiOauth: {
        accessToken: $at,
        refreshToken: $rt,
        expiresAt: $ea,
        scopes: ["user:inference", "user:profile", "user:sessions:claude_code"],
        subscriptionType: "max",
        rateLimitTier: "default_claude_max_20x"
     }}' \
    > "${CRED_FILE}.tmp" && mv "${CRED_FILE}.tmp" "${CRED_FILE}"

  _persist_credentials

  local expires_in_hrs=$(( ${expires_in:-28800} / 3600 ))
  log "token-refresh: Bootstrap successful — fresh tokens (valid for ~${expires_in_hrs}h)"
  return 0
}

# ── token_needs_refresh ────────────────────────────────────────
# Returns 0 (true) if the token is expired or within the refresh
# margin. Returns 1 (false) if the token is still valid.
token_needs_refresh() {
  if [[ "${OAUTH_TOKEN_MODE}" == true ]]; then
    return 1  # long-lived token, no refresh needed
  fi

  if [[ ! -f "${CRED_FILE}" ]]; then
    log "token-refresh: No credentials file found"
    return 0  # needs refresh (or at least, something is wrong)
  fi

  local expires_at
  expires_at=$(jq -r '.claudeAiOauth.expiresAt // empty' "${CRED_FILE}" 2>/dev/null)

  if [[ -z "${expires_at}" ]]; then
    log "token-refresh: No expiresAt in credentials — assuming valid (API key?)"
    return 1  # no expiry = not an OAuth token, skip refresh
  fi

  # expiresAt is epoch milliseconds; convert current time to ms
  local now_ms
  now_ms=$(( $(date -u +%s) * 1000 ))

  local threshold=$(( expires_at - REFRESH_MARGIN_MS ))

  if [[ "${now_ms}" -ge "${threshold}" ]]; then
    local remaining_min=$(( (expires_at - now_ms) / 60000 ))
    log "token-refresh: Token expires in ${remaining_min} minutes — needs refresh"
    return 0
  fi

  return 1
}

# ── refresh_token ──────────────────────────────────────────────
# Refreshes tokens in an existing credentials file. Reads the
# current refresh token, calls the OAuth endpoint, and updates
# the file in place (preserving any extra fields).
# Returns 0 on success, 1 on failure.
refresh_token() {
  if [[ "${OAUTH_TOKEN_MODE}" == true ]]; then
    return 0  # long-lived token, no refresh needed
  fi

  if [[ ! -f "${CRED_FILE}" ]]; then
    log "token-refresh: Cannot refresh — no credentials file"
    return 1
  fi

  local current_refresh_token
  current_refresh_token=$(jq -r '.claudeAiOauth.refreshToken // empty' "${CRED_FILE}" 2>/dev/null)

  if [[ -z "${current_refresh_token}" ]]; then
    log "token-refresh: Cannot refresh — no refreshToken in credentials"
    return 1
  fi

  log "token-refresh: Attempting OAuth token refresh..."

  local response
  response=$(_do_oauth_refresh "${current_refresh_token}" "Refresh") || return 1

  local new_access_token new_refresh_token expires_in new_expires_at
  new_access_token=$(echo "${response}" | jq -r '.access_token')
  new_refresh_token=$(echo "${response}" | jq -r '.refresh_token')
  expires_in=$(echo "${response}" | jq -r '.expires_in // empty')
  new_expires_at=$(( $(date -u +%s) * 1000 + ${expires_in:-28800} * 1000 ))

  # Update the credentials file atomically (preserves extra fields like scopes)
  jq \
    --arg at "${new_access_token}" \
    --arg rt "${new_refresh_token}" \
    --argjson ea "${new_expires_at}" \
    '.claudeAiOauth.accessToken = $at | .claudeAiOauth.refreshToken = $rt | .claudeAiOauth.expiresAt = $ea' \
    "${CRED_FILE}" > "${CRED_FILE}.tmp" && mv "${CRED_FILE}.tmp" "${CRED_FILE}"

  _persist_credentials

  local expires_in_hrs=$(( ${expires_in:-28800} / 3600 ))
  log "token-refresh: Token refreshed successfully (valid for ~${expires_in_hrs}h)"
  return 0
}

# ── ensure_valid_token ─────────────────────────────────────────
# Proactive wrapper: checks if refresh is needed and does it.
# Safe to call frequently — no-ops when token is still valid.
ensure_valid_token() {
  if token_needs_refresh; then
    refresh_token || log "token-refresh: Pre-check refresh failed — will retry after Claude invocation"
  fi
}

# ── is_auth_error ──────────────────────────────────────────────
# Checks Claude output and exit code for OAuth expiration patterns.
# Usage: is_auth_error <exit_code> <claude_output>
# Returns 0 (true) if the error is an auth/token issue.
is_auth_error() {
  local exit_code="$1"
  local output="$2"

  # Only check if Claude actually failed
  if [[ "${exit_code}" -eq 0 ]]; then
    return 1
  fi

  # Check the output for known OAuth error patterns
  local result_text
  result_text=$(echo "${output}" | jq -r '.result // empty' 2>/dev/null)

  # Patterns from confirmed Claude Code OAuth errors
  if echo "${result_text}" | grep -qi "OAuth token has expired"; then
    return 0
  fi
  if echo "${result_text}" | grep -qi "token.*expired"; then
    return 0
  fi
  if echo "${result_text}" | grep -q "Unauthorized\|401"; then
    return 0
  fi
  if echo "${result_text}" | grep -qi "authentication.*failed"; then
    return 0
  fi

  # Also check raw output in case error isn't in .result
  if echo "${output}" | grep -qi "OAuth token has expired"; then
    return 0
  fi

  return 1
}
