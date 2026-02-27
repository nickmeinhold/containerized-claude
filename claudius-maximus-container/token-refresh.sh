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

# Claude Code's public OAuth client ID (hardcoded in the CLI)
OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
OAUTH_TOKEN_URL="https://console.anthropic.com/v1/oauth/token"

# Paths
CRED_FILE="${HOME}/.claude/.credentials.json"
PERSISTENT_CRED="/workspace/persistent/claude-credentials.json"

# Refresh 30 minutes before actual expiry to avoid races
REFRESH_MARGIN_MS=$((30 * 60 * 1000))

# ── token_needs_refresh ────────────────────────────────────────
# Returns 0 (true) if the token is expired or within the refresh
# margin. Returns 1 (false) if the token is still valid.
token_needs_refresh() {
  if [[ ! -f "${CRED_FILE}" ]]; then
    log "token-refresh: No credentials file found"
    return 0  # needs refresh (or at least, something is wrong)
  fi

  local expires_at
  expires_at=$(jq -r '.expiresAt // empty' "${CRED_FILE}" 2>/dev/null)

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
# Calls the Anthropic OAuth endpoint to get new access + refresh
# tokens. Writes them atomically to both the active and persistent
# credential files.
# Returns 0 on success, 1 on failure.
refresh_token() {
  if [[ ! -f "${CRED_FILE}" ]]; then
    log "token-refresh: Cannot refresh — no credentials file"
    return 1
  fi

  local current_refresh_token
  current_refresh_token=$(jq -r '.refreshToken // empty' "${CRED_FILE}" 2>/dev/null)

  if [[ -z "${current_refresh_token}" ]]; then
    log "token-refresh: Cannot refresh — no refreshToken in credentials"
    return 1
  fi

  log "token-refresh: Attempting OAuth token refresh..."

  # Build the request body using jq for safe JSON encoding
  local request_body
  request_body=$(jq -n \
    --arg grant_type "refresh_token" \
    --arg refresh_token "${current_refresh_token}" \
    --arg client_id "${OAUTH_CLIENT_ID}" \
    '{grant_type: $grant_type, refresh_token: $refresh_token, client_id: $client_id}')

  local response http_code
  response=$(curl -s --max-time 10 -w "\n%{http_code}" \
    -X POST "${OAUTH_TOKEN_URL}" \
    -H "Content-Type: application/json" \
    -d "${request_body}" \
    2>/dev/null)

  # Split response body and HTTP status code
  http_code=$(echo "${response}" | tail -n1)
  response=$(echo "${response}" | sed '$d')

  if [[ "${http_code}" != "200" ]]; then
    local error_msg
    error_msg=$(echo "${response}" | jq -r '.error // .message // "unknown error"' 2>/dev/null || echo "HTTP ${http_code}")
    log "token-refresh: Refresh failed (HTTP ${http_code}): ${error_msg}"
    return 1
  fi

  # Extract new tokens from response
  local new_access_token new_refresh_token expires_in
  new_access_token=$(echo "${response}" | jq -r '.access_token // empty')
  new_refresh_token=$(echo "${response}" | jq -r '.refresh_token // empty')
  expires_in=$(echo "${response}" | jq -r '.expires_in // empty')

  if [[ -z "${new_access_token}" || -z "${new_refresh_token}" ]]; then
    log "token-refresh: Refresh response missing tokens"
    return 1
  fi

  # Calculate new expiresAt (epoch milliseconds)
  local new_expires_at
  new_expires_at=$(( $(date -u +%s) * 1000 + ${expires_in:-28800} * 1000 ))

  # Update the credentials file atomically using jq
  local tmp_cred="${CRED_FILE}.tmp"
  jq \
    --arg at "${new_access_token}" \
    --arg rt "${new_refresh_token}" \
    --argjson ea "${new_expires_at}" \
    '.accessToken = $at | .refreshToken = $rt | .expiresAt = $ea' \
    "${CRED_FILE}" > "${tmp_cred}" && mv "${tmp_cred}" "${CRED_FILE}"

  # Also persist to the volume (survives container restarts on Fly.io)
  if [[ -d "/workspace/persistent" ]]; then
    cp "${CRED_FILE}" "${PERSISTENT_CRED}.tmp" && mv "${PERSISTENT_CRED}.tmp" "${PERSISTENT_CRED}"
  fi

  local expires_in_hrs
  expires_in_hrs=$(( ${expires_in:-28800} / 3600 ))
  log "token-refresh: Token refreshed successfully (valid for ~${expires_in_hrs}h)"
  return 0
}

# ── ensure_valid_token ─────────────────────────────────────────
# Proactive wrapper: checks if refresh is needed and does it.
# Safe to call frequently — no-ops when token is still valid.
ensure_valid_token() {
  if token_needs_refresh; then
    refresh_token
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
