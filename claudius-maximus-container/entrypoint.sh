#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# Entrypoint — verifies credentials are present, then runs agent-loop.
# Works with both docker-compose (bind mounts) and Fly.io (env secrets).
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Persistent volume (Fly.io) ────────────────────────────────────
# Fly.io mounts a single volume at /workspace/persistent.
# Symlink logs/ and repos/ into it so paths stay consistent.
if [[ -d /workspace/persistent ]]; then
  mkdir -p /workspace/persistent/logs /workspace/persistent/repos
  # Replace build-time directories with symlinks (skip if already linked)
  for dir in logs repos; do
    if [[ -d "/workspace/${dir}" && ! -L "/workspace/${dir}" ]]; then
      rm -rf "/workspace/${dir}"
    fi
    ln -sfn "/workspace/persistent/${dir}" "/workspace/${dir}"
  done
  echo "[entrypoint] Linked persistent volume for logs and repos"
fi

# ── Generate msmtprc from env vars ───────────────────────────────
# Single source of truth for SMTP password — no more duplicating it
# in both .env and msmtprc. Falls back to the bind-mounted file if
# SMTP_HOST is not set (docker-compose path).
if [[ -n "${SMTP_HOST:-}" ]]; then
  cat > /etc/msmtprc <<MSMTP
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        default
host           ${SMTP_HOST}
port           ${SMTP_PORT:-587}
from           ${MY_EMAIL}
user           ${SMTP_USER:-${MY_EMAIL}}
password       ${SMTP_PASS:-${IMAP_PASS}}
MSMTP
  chmod 600 /etc/msmtprc
  echo "[entrypoint] Generated /etc/msmtprc from env vars"
fi

# ── Claude credentials ────────────────────────────────────────────
CRED_FILE="${HOME}/.claude/.credentials.json"

# Write credentials from env var (Fly.io secrets path)
if [[ -n "${CLAUDE_CREDENTIALS_JSON:-}" ]]; then
  echo "${CLAUDE_CREDENTIALS_JSON}" > "${CRED_FILE}"
  echo "[entrypoint] Wrote credentials from CLAUDE_CREDENTIALS_JSON"
fi

if [[ -f "${CRED_FILE}" ]]; then
  echo "[entrypoint] Found credentials at ${CRED_FILE}"
else
  echo "[entrypoint] WARNING: No credentials file at ${CRED_FILE}"
  echo "[entrypoint] Mount .claude-credentials.json, set CLAUDE_CREDENTIALS_JSON, or set ANTHROPIC_API_KEY"
fi

# Configure git identity
git config --global user.name "${GIT_USER_NAME:-Claudius}"
git config --global user.email "${GIT_USER_EMAIL:-gaylejewon@users.noreply.github.com}"

# Clone or pull the research journal repo
# Uses gh CLI for clone so GH_TOKEN auth is respected (works with private repos)
JOURNAL_REPO="${JOURNAL_REPO:-gaylejewon/research-journal}"
JOURNAL_DIR="/workspace/repos/${JOURNAL_REPO}"
if [[ -d "${JOURNAL_DIR}/.git" ]]; then
  echo "[entrypoint] Pulling research journal (${JOURNAL_REPO})..."
  git -C "${JOURNAL_DIR}" pull --ff-only 2>&1 || echo "[entrypoint] WARNING: journal pull failed — continuing with local copy"
else
  echo "[entrypoint] Cloning research journal (${JOURNAL_REPO})..."
  mkdir -p "$(dirname "${JOURNAL_DIR}")"
  gh repo clone "${JOURNAL_REPO}" "${JOURNAL_DIR}" 2>&1 \
    || echo "[entrypoint] Research journal repo not found — Claudius will create it on first need"
fi

# Hand off to the agent loop
exec agent-loop "$@"
