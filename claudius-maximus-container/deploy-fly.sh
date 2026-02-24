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

# ── Read .env into an associative array ───────────────────────────
declare -A env_vars
while IFS= read -r line; do
  # Skip blank lines and comments
  [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
  key="${line%%=*}"
  value="${line#*=}"
  env_vars["${key}"]="${value}"
done < .env

# ── Add SMTP vars (generate msmtprc from env on the server) ──────
# Default to Gmail settings matching the existing msmtprc
env_vars["SMTP_HOST"]="${env_vars[SMTP_HOST]:-smtp.gmail.com}"
env_vars["SMTP_PORT"]="${env_vars[SMTP_PORT]:-587}"
# SMTP_USER and SMTP_PASS default to MY_EMAIL and IMAP_PASS in entrypoint

# ── Add Claude credentials JSON ──────────────────────────────────
if [[ -f .claude-credentials.json ]]; then
  env_vars["CLAUDE_CREDENTIALS_JSON"]="$(cat .claude-credentials.json)"
  echo "Loaded Claude credentials from .claude-credentials.json"
else
  echo "WARNING: .claude-credentials.json not found."
  echo "Set ANTHROPIC_API_KEY in .env or provide credentials later."
fi

# ── Push secrets to Fly ───────────────────────────────────────────
echo "Setting Fly.io secrets..."
secret_args=()
for key in "${!env_vars[@]}"; do
  secret_args+=("${key}=${env_vars[${key}]}")
done

fly secrets set "${secret_args[@]}"
echo "Secrets set successfully."

# ── Deploy ────────────────────────────────────────────────────────
if [[ "${SECRETS_ONLY}" == true ]]; then
  echo "Done (secrets only). Run 'fly deploy' when ready."
else
  echo "Deploying..."
  fly deploy
fi
