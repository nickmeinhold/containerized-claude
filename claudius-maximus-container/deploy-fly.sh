#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# deploy-fly.sh — Push .env secrets to Fly.io and deploy.
#
# Usage:
#   ./deploy-fly.sh              # set secrets + deploy
#   ./deploy-fly.sh --secrets    # set secrets only (no deploy)
#
# Reads .env and .claude-credentials.json from the current directory.
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")"

SECRETS_ONLY=false
[[ "${1:-}" == "--secrets" ]] && SECRETS_ONLY=true

# ── Validate prerequisites ────────────────────────────────────────
if ! command -v fly &>/dev/null; then
  echo "Error: flyctl not found. Install with: brew install flyctl"
  exit 1
fi

if [[ ! -f .env ]]; then
  echo "Error: .env not found. Copy .env.example and fill in your values."
  exit 1
fi

# ── Build secrets payload ─────────────────────────────────────────
# Pipe KEY=VALUE lines to `fly secrets import` (bash 3 compatible).
SECRETS_FILE=$(mktemp)
trap 'rm -f "${SECRETS_FILE}"' EXIT

# Start with .env (strip comments and blank lines)
grep -v '^\s*#' .env | grep -v '^\s*$' > "${SECRETS_FILE}"

# Add SMTP defaults if not already in .env (generates msmtprc on server)
grep -q '^SMTP_HOST=' "${SECRETS_FILE}" || echo "SMTP_HOST=smtp.gmail.com" >> "${SECRETS_FILE}"
grep -q '^SMTP_PORT=' "${SECRETS_FILE}" || echo "SMTP_PORT=587" >> "${SECRETS_FILE}"
# SMTP_USER and SMTP_PASS default to MY_EMAIL and IMAP_PASS in entrypoint

# Extract Claude refresh token — prefer macOS Keychain, fall back to file.
# Only the refresh token is needed; the container bootstraps fresh access
# tokens on startup (like xdeca-pm-bot). This avoids the stale-credentials
# problem caused by snapshotting a full credentials JSON.
REFRESH_TOKEN=""
if [[ "$(uname)" == "Darwin" ]]; then
  CRED_JSON=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
  if [[ -n "${CRED_JSON}" ]]; then
    REFRESH_TOKEN=$(printf '%s' "${CRED_JSON}" | jq -r '.claudeAiOauth.refreshToken // empty' 2>/dev/null)
    if [[ -n "${REFRESH_TOKEN}" ]]; then
      echo "Extracted refresh token from macOS Keychain"
    fi
  fi
fi
if [[ -z "${REFRESH_TOKEN}" && -f .claude-credentials.json ]]; then
  REFRESH_TOKEN=$(jq -r '.claudeAiOauth.refreshToken // empty' .claude-credentials.json 2>/dev/null)
  if [[ -n "${REFRESH_TOKEN}" ]]; then
    echo "Extracted refresh token from .claude-credentials.json"
  fi
fi
if [[ -n "${REFRESH_TOKEN}" ]]; then
  printf 'CLAUDE_REFRESH_TOKEN=%s\n' "${REFRESH_TOKEN}" >> "${SECRETS_FILE}"
else
  echo "WARNING: No Claude refresh token found."
  echo "Set ANTHROPIC_API_KEY in .env or provide credentials later."
fi

# ── Push secrets to Fly ───────────────────────────────────────────
echo "Setting Fly.io secrets..."
fly secrets import < "${SECRETS_FILE}"
echo "Secrets set successfully."

# ── Deploy ────────────────────────────────────────────────────────
if [[ "${SECRETS_ONLY}" == true ]]; then
  echo "Done (secrets only). Run 'fly deploy' when ready."
else
  echo "Deploying..."
  fly deploy
fi
