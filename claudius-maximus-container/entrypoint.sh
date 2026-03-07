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
  mkdir -p /workspace/persistent/logs /workspace/persistent/repos /workspace/persistent/attachments
  # Replace build-time directories with symlinks (skip if already linked)
  for dir in logs repos attachments; do
    if [[ -d "/workspace/${dir}" && ! -L "/workspace/${dir}" ]]; then
      rm -rf "/workspace/${dir}"
    fi
    ln -sfn "/workspace/persistent/${dir}" "/workspace/${dir}"
  done
  echo "[entrypoint] Linked persistent volume for logs, repos, and attachments"
fi

# ── Playwright session persistence ──────────────────────────────
PLAYWRIGHT_STORAGE="/workspace/logs/playwright-storage.json"
if [[ ! -f "${PLAYWRIGHT_STORAGE}" ]]; then
  echo '{"cookies":[],"origins":[]}' > "${PLAYWRIGHT_STORAGE}"
  echo "[entrypoint] Created empty Playwright storage state"
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
# Priority chain for OAuth credentials:
#   1. CLAUDE_REFRESH_TOKEN set + differs from persisted → bootstrap fresh
#   2. Persisted file exists → use it (tokens refreshed at runtime)
#   3. CLAUDE_CREDENTIALS_JSON → legacy full-JSON path (backward compat)
#   4. Else → warn (bind-mount or API key path)
#
# The refresh-token-first approach (like xdeca-pm-bot) avoids the stale
# credentials problem: refresh tokens are single-use, so snapshotting a
# full credentials JSON at deploy time races with local token refreshes.
# By deploying just the refresh token and bootstrapping on startup, the
# container gets its own fresh token pair immediately.
# Source token-refresh library for bootstrap_from_refresh_token()
# (also defines CRED_FILE and PERSISTENT_CRED)
source /usr/local/bin/token-refresh

CRED_RESOLVED=false

# ── Path 1: CLAUDE_REFRESH_TOKEN (preferred) ────────────────────
if [[ -n "${CLAUDE_REFRESH_TOKEN:-}" ]]; then
  PERSISTED_RT=""
  if [[ -f "${PERSISTENT_CRED}" ]]; then
    PERSISTED_RT=$(jq -r '.claudeAiOauth.refreshToken // empty' "${PERSISTENT_CRED}" 2>/dev/null)
  fi

  if [[ -n "${PERSISTED_RT}" && "${CLAUDE_REFRESH_TOKEN}" == "${PERSISTED_RT}" ]]; then
    # Same token as persisted — runtime has already refreshed past this
    cp "${PERSISTENT_CRED}" "${CRED_FILE}"
    echo "[entrypoint] Loaded credentials from persistent volume (refresh token unchanged)"
    CRED_RESOLVED=true
  elif [[ -n "${PERSISTED_RT}" && "${CLAUDE_REFRESH_TOKEN}" != "${PERSISTED_RT}" ]]; then
    # Operator pushed a new refresh token — bootstrap fresh
    echo "[entrypoint] New refresh token detected — bootstrapping fresh credentials..."
    if bootstrap_from_refresh_token "${CLAUDE_REFRESH_TOKEN}"; then
      echo "[entrypoint] Bootstrapped fresh credentials from CLAUDE_REFRESH_TOKEN"
      CRED_RESOLVED=true
    else
      echo "[entrypoint] WARNING: Bootstrap failed — falling back to persisted credentials"
      cp "${PERSISTENT_CRED}" "${CRED_FILE}"
      CRED_RESOLVED=true
    fi
  else
    # No persisted file — first deploy
    echo "[entrypoint] First deploy — bootstrapping credentials from CLAUDE_REFRESH_TOKEN..."
    if bootstrap_from_refresh_token "${CLAUDE_REFRESH_TOKEN}"; then
      echo "[entrypoint] Bootstrapped fresh credentials from CLAUDE_REFRESH_TOKEN"
      CRED_RESOLVED=true
    else
      echo "[entrypoint] WARNING: Bootstrap failed from CLAUDE_REFRESH_TOKEN"
    fi
  fi
fi

# ── Path 2: Persisted credentials (runtime-refreshed) ───────────
if [[ "${CRED_RESOLVED}" != true && -f "${PERSISTENT_CRED}" ]]; then
  cp "${PERSISTENT_CRED}" "${CRED_FILE}"
  echo "[entrypoint] Loaded credentials from persistent volume"
  CRED_RESOLVED=true
fi

# ── Path 3: CLAUDE_CREDENTIALS_JSON (legacy backward compat) ────
if [[ "${CRED_RESOLVED}" != true && -n "${CLAUDE_CREDENTIALS_JSON:-}" ]]; then
  printf '%s\n' "${CLAUDE_CREDENTIALS_JSON}" > "${CRED_FILE}"
  if [[ -d "/workspace/persistent" ]]; then
    cp "${CRED_FILE}" "${PERSISTENT_CRED}"
    echo "[entrypoint] Seeded persistent credentials from CLAUDE_CREDENTIALS_JSON"
  fi
  echo "[entrypoint] Wrote credentials from CLAUDE_CREDENTIALS_JSON (legacy path)"
  CRED_RESOLVED=true
fi

if [[ -f "${CRED_FILE}" ]]; then
  echo "[entrypoint] Found credentials at ${CRED_FILE}"
else
  echo "[entrypoint] WARNING: No credentials file at ${CRED_FILE}"
  echo "[entrypoint] Set CLAUDE_REFRESH_TOKEN, CLAUDE_CREDENTIALS_JSON, or ANTHROPIC_API_KEY"
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

# Clone or pull the email archive repo (same pattern as journal)
ARCHIVE_REPO="${ARCHIVE_REPO:-}"
if [[ -n "${ARCHIVE_REPO}" ]]; then
  ARCHIVE_DIR="/workspace/repos/${ARCHIVE_REPO}"
  if [[ -d "${ARCHIVE_DIR}/.git" ]]; then
    echo "[entrypoint] Pulling email archive (${ARCHIVE_REPO})..."
    git -C "${ARCHIVE_DIR}" pull --ff-only 2>&1 || echo "[entrypoint] WARNING: archive pull failed — continuing with local copy"
  else
    echo "[entrypoint] Cloning email archive (${ARCHIVE_REPO})..."
    mkdir -p "$(dirname "${ARCHIVE_DIR}")"
    if ! gh repo clone "${ARCHIVE_REPO}" "${ARCHIVE_DIR}" 2>&1; then
      echo "[entrypoint] Archive repo not found — creating as private repo..."
      if gh repo create "${ARCHIVE_REPO}" --private --description "Email archive" 2>&1; then
        gh repo clone "${ARCHIVE_REPO}" "${ARCHIVE_DIR}" 2>&1 || true
      else
        echo "[entrypoint] WARNING: could not create archive repo — archiving will be disabled"
      fi
    fi
  fi
else
  echo "[entrypoint] ARCHIVE_REPO not set — email archiving disabled"
fi

# Hand off to the agent loop
exec agent-loop "$@"
