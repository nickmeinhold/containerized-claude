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
  export "${key}=${value}"
done < .env

docker run --rm \
  -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  -v "$(pwd)/workspace:/workspace" \
  --entrypoint claude \
  containerized-claude \
  -p "${PROMPT}" \
  --dangerously-skip-permissions \
  --max-turns 20
