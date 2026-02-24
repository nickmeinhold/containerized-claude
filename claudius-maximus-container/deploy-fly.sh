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

# Add Claude credentials JSON
if [[ -f .claude-credentials.json ]]; then
  # fly secrets import handles multi-line values when quoted
  printf 'CLAUDE_CREDENTIALS_JSON=%s\n' "$(cat .claude-credentials.json)" >> "${SECRETS_FILE}"
  echo "Loaded Claude credentials from .claude-credentials.json"
else
  echo "WARNING: .claude-credentials.json not found."
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
