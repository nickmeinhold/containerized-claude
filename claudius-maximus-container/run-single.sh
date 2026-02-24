#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# Run a single one-off Claude prompt in the container.
# Useful for testing or ad-hoc tasks (doesn't start the agent loop).
#
# Usage:
#   ./run-single.sh "Browse https://example.com and summarize it"
#   ./run-single.sh "Send an email to bob@example.com saying hello"
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

PROMPT="${1:?Usage: ./run-single.sh \"your prompt here\"}"

if [[ ! -f .env ]]; then
  echo "Error: .env not found. Copy .env.example to .env and fill in your keys."
  exit 1
fi

# Read .env safely without executing values as shell code
while IFS='=' read -r key value; do
  # Skip comments and blank lines
  [[ "${key}" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${key// }" ]] && continue
  key="${key// }"
  # Strip surrounding quotes (single or double) from values
  value="${value#\"}" ; value="${value%\"}"
  value="${value#\'}" ; value="${value%\'}"
  export "${key}=${value}"
done < .env

# Mount OAuth credentials if available; fall back to API key if set
CRED_ARGS=()
if [[ -f .claude-credentials.json ]]; then
  CRED_ARGS+=(-v "$(pwd)/.claude-credentials.json:/home/claudius/.claude/.credentials.json:ro")
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  CRED_ARGS+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
else
  echo "Error: No credentials found. Provide .claude-credentials.json (OAuth) or ANTHROPIC_API_KEY in .env."
  exit 1
fi

docker run --rm \
  "${CRED_ARGS[@]}" \
  -v "$(pwd)/workspace:/workspace" \
  --entrypoint claude \
  containerized-claude \
  -p "${PROMPT}" \
  --dangerously-skip-permissions \
  --max-turns "${MAX_TURNS:-25}"
