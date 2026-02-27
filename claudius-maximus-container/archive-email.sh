#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# Archive Email — git-backed email archive library.
#
# Saves every incoming and outgoing email as a markdown file with
# YAML frontmatter, organized by YYYY/MM/ in a dedicated GitHub
# repo. Batch-pushed alongside the journal sync (every 10 polls).
#
# Source this file; do not execute it directly.
# Usage: source /usr/local/bin/archive-email
# ─────────────────────────────────────────────────────────────────

ARCHIVE_REPO="${ARCHIVE_REPO:-}"
ARCHIVE_DIR="/workspace/repos/${ARCHIVE_REPO}"

# ── sanitize_slug ─────────────────────────────────────────────
# Converts a subject line to a filesystem-safe slug.
# Usage: slug=$(sanitize_slug "Re: The Nature of Consciousness!")
sanitize_slug() {
  local input="$1"
  echo "${input}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/^re: *//; s/^fwd: *//' \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/--*/-/g; s/^-//; s/-$//' \
    | cut -c1-60
}

# ── init_archive_repo ─────────────────────────────────────────
# Clone the archive repo, or create it via gh if it doesn't exist.
# Called from entrypoint.sh at startup. Safe to call repeatedly.
init_archive_repo() {
  if [[ -z "${ARCHIVE_REPO}" ]]; then
    return 0
  fi

  if [[ -d "${ARCHIVE_DIR}/.git" ]]; then
    log "archive: Pulling latest from ${ARCHIVE_REPO}..."
    git -C "${ARCHIVE_DIR}" pull --ff-only 2>/dev/null || true
    return 0
  fi

  log "archive: Cloning ${ARCHIVE_REPO}..."
  mkdir -p "$(dirname "${ARCHIVE_DIR}")"
  if ! gh repo clone "${ARCHIVE_REPO}" "${ARCHIVE_DIR}" 2>/dev/null; then
    log "archive: Repo not found — creating ${ARCHIVE_REPO} (private)..."
    if gh repo create "${ARCHIVE_REPO}" --private --description "Email archive" 2>/dev/null; then
      gh repo clone "${ARCHIVE_REPO}" "${ARCHIVE_DIR}" 2>/dev/null || true
      # Seed with a README
      if [[ -d "${ARCHIVE_DIR}/.git" ]]; then
        echo "# Email Archive" > "${ARCHIVE_DIR}/README.md"
        echo "" >> "${ARCHIVE_DIR}/README.md"
        echo "Automated archive of email conversations. Each email is stored as a markdown file with YAML frontmatter." >> "${ARCHIVE_DIR}/README.md"
        git -C "${ARCHIVE_DIR}" add README.md
        git -C "${ARCHIVE_DIR}" commit -m "chore: initialize email archive" 2>/dev/null || true
        git -C "${ARCHIVE_DIR}" push 2>/dev/null || true
      fi
    else
      log "archive: WARNING — could not create repo. Archiving disabled."
    fi
  fi
}

# ── archive_incoming ──────────────────────────────────────────
# Write an incoming email to the archive as a markdown file.
# Usage: archive_incoming <uid> <from> <reply_to> <subject> <date> <body>
archive_incoming() {
  if [[ -z "${ARCHIVE_REPO}" || ! -d "${ARCHIVE_DIR}/.git" ]]; then
    return 0
  fi

  local uid="$1" from="$2" reply_to="$3" subject="$4" date="$5" body="$6"
  local now_iso
  now_iso=$(date -u '+%Y-%m-%dT%H%M%SZ')
  local year_month
  year_month=$(date -u '+%Y/%m')
  local slug
  slug=$(sanitize_slug "${subject}")
  if [[ -z "${slug}" ]]; then slug="no-subject"; fi

  local dir="${ARCHIVE_DIR}/${year_month}"
  mkdir -p "${dir}"
  local filename="${now_iso}-incoming-${slug}.md"
  local filepath="${dir}/${filename}"

  cat > "${filepath}" <<ARCHIVE
---
direction: incoming
message_uid: "INBOX-${uid}"
date: "${date}"
from: "${from}"
reply_to: "${reply_to}"
to: "${MY_EMAIL}"
subject: "${subject}"
archived_at: "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
---

${body}
ARCHIVE

  log "archive: Saved incoming email → ${year_month}/${filename}"
}

# ── archive_outgoing ──────────────────────────────────────────
# Write an outgoing email to the archive as a markdown file.
# Reads the reply body from /tmp/reply.txt (where Claude writes it).
# Usage: archive_outgoing <to> <subject> [in_reply_to_uid]
archive_outgoing() {
  if [[ -z "${ARCHIVE_REPO}" || ! -d "${ARCHIVE_DIR}/.git" ]]; then
    return 0
  fi

  local to="$1" subject="$2" in_reply_to_uid="${3:-}"

  # Claude writes reply body to /tmp/reply.txt per prompt instructions
  if [[ ! -f /tmp/reply.txt ]]; then
    log "archive: No /tmp/reply.txt found — skipping outgoing archive"
    return 0
  fi

  local body
  body=$(cat /tmp/reply.txt)
  if [[ -z "${body}" ]]; then
    log "archive: /tmp/reply.txt is empty — skipping outgoing archive"
    return 0
  fi

  local now_iso
  now_iso=$(date -u '+%Y-%m-%dT%H%M%SZ')
  local year_month
  year_month=$(date -u '+%Y/%m')
  local slug
  slug=$(sanitize_slug "${subject}")
  if [[ -z "${slug}" ]]; then slug="no-subject"; fi

  local dir="${ARCHIVE_DIR}/${year_month}"
  mkdir -p "${dir}"
  local filename="${now_iso}-outgoing-${slug}.md"
  local filepath="${dir}/${filename}"

  # Build optional in_reply_to field
  local reply_field=""
  if [[ -n "${in_reply_to_uid}" ]]; then
    reply_field="
in_reply_to_uid: \"${in_reply_to_uid}\""
  fi

  cat > "${filepath}" <<ARCHIVE
---
direction: outgoing
date: "$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
from: "${MY_EMAIL}"
to: "${to}"
subject: "${subject}"${reply_field}
archived_at: "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
---

${body}
ARCHIVE

  log "archive: Saved outgoing email → ${year_month}/${filename}"
}

# ── push_archive ──────────────────────────────────────────────
# Commit and push any pending archive files to GitHub.
# Designed to be called periodically (every 10 polls), not per-email.
push_archive() {
  if [[ -z "${ARCHIVE_REPO}" || ! -d "${ARCHIVE_DIR}/.git" ]]; then
    return 0
  fi

  # Check if there are any changes to commit
  if git -C "${ARCHIVE_DIR}" diff --quiet && \
     git -C "${ARCHIVE_DIR}" diff --cached --quiet && \
     [[ -z "$(git -C "${ARCHIVE_DIR}" ls-files --others --exclude-standard)" ]]; then
    return 0  # nothing to push
  fi

  local count
  count=$(git -C "${ARCHIVE_DIR}" ls-files --others --modified --exclude-standard | wc -l | tr -d ' ')

  git -C "${ARCHIVE_DIR}" add -A
  git -C "${ARCHIVE_DIR}" commit -m "archive: ${count} email(s) — $(date -u '+%Y-%m-%d %H:%M UTC')" 2>/dev/null || return 0
  git -C "${ARCHIVE_DIR}" push 2>/dev/null \
    || log "archive: WARNING — push failed (will retry next cycle)"
  log "archive: Pushed ${count} email(s) to ${ARCHIVE_REPO}"
}
