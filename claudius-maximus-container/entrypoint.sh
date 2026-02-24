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

# Configure git identity
git config --global user.name "${GIT_USER_NAME:-Claudius}"
git config --global user.email "${GIT_USER_EMAIL:-gaylejewon@users.noreply.github.com}"

# Clone or pull the research journal repo
JOURNAL_REPO="${JOURNAL_REPO:-gaylejewon/research-journal}"
JOURNAL_DIR="/workspace/repos/${JOURNAL_REPO}"
if [[ -d "${JOURNAL_DIR}/.git" ]]; then
  echo "[entrypoint] Pulling research journal (${JOURNAL_REPO})..."
  git -C "${JOURNAL_DIR}" pull --ff-only 2>&1 || echo "[entrypoint] WARNING: journal pull failed — continuing with local copy"
else
  echo "[entrypoint] Cloning research journal (${JOURNAL_REPO})..."
  mkdir -p "$(dirname "${JOURNAL_DIR}")"
  git clone "https://github.com/${JOURNAL_REPO}.git" "${JOURNAL_DIR}" 2>&1 \
    || echo "[entrypoint] Research journal repo not found — Claudius will create it on first need"
fi

# Hand off to the agent loop
exec agent-loop "$@"
