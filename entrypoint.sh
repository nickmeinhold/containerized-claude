#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# Entrypoint — verifies credentials are present, then runs agent-loop.
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

CRED_FILE="${HOME}/.claude/.credentials.json"

if [[ -f "${CRED_FILE}" ]]; then
  echo "[entrypoint] Found credentials at ${CRED_FILE}"
else
  echo "[entrypoint] WARNING: No credentials file at ${CRED_FILE}"
  echo "[entrypoint] Mount your .claude-credentials.json there or set ANTHROPIC_API_KEY"
fi

# Hand off to the agent loop
exec agent-loop "$@"
