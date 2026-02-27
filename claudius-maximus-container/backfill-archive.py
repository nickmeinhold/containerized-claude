#!/usr/bin/env python3
"""
Backfill email archive — one-time IMAP export.

Fetches ALL emails (read + unread) from INBOX and [Gmail]/Sent Mail,
writes them as markdown files with YAML frontmatter in the same format
used by archive-email.sh. Deduplicates by message UID + folder against
existing files in the archive directory.

Uses only Python stdlib — no pip dependencies.

Usage:
    backfill-archive                     # run for real
    backfill-archive --dry-run           # preview without writing files

Environment variables:
    IMAP_HOST       IMAP server hostname (default: imap.gmail.com)
    IMAP_PORT       IMAP port (default: 993)
    IMAP_USER       Login username / email address
    IMAP_PASS       Login password or app-specific password
    MY_EMAIL        Agent's email address (for direction detection)
    ARCHIVE_REPO    Archive repo in owner/repo format
"""

import email
import email.header
import email.message
import email.utils
import imaplib
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def decode_header(raw: str) -> str:
    """Decode an RFC 2047 encoded header value."""
    parts = email.header.decode_header(raw)
    decoded = []
    for data, charset in parts:
        if isinstance(data, bytes):
            decoded.append(data.decode(charset or "utf-8", errors="replace"))
        else:
            decoded.append(data)
    return " ".join(decoded)


def get_body(msg: email.message.Message) -> str:
    """Extract the plain-text body from a message, handling multipart."""
    if msg.is_multipart():
        for part in msg.walk():
            content_type = part.get_content_type()
            disposition = str(part.get("Content-Disposition", ""))
            if content_type == "text/plain" and "attachment" not in disposition:
                payload = part.get_payload(decode=True)
                charset = part.get_content_charset() or "utf-8"
                return payload.decode(charset, errors="replace")
        for part in msg.walk():
            if part.get_content_maintype() == "text":
                payload = part.get_payload(decode=True)
                charset = part.get_content_charset() or "utf-8"
                return payload.decode(charset, errors="replace")
        return ""
    else:
        payload = msg.get_payload(decode=True)
        charset = msg.get_content_charset() or "utf-8"
        return payload.decode(charset, errors="replace") if payload else ""


def sanitize_slug(subject: str) -> str:
    """Convert a subject line to a filesystem-safe slug."""
    s = subject.lower()
    s = re.sub(r"^(re|fwd):\s*", "", s)
    s = re.sub(r"[^a-z0-9]", "-", s)
    s = re.sub(r"-+", "-", s)
    s = s.strip("-")
    return s[:60] or "no-subject"


def parse_date(date_str: str) -> datetime:
    """Parse an email date string into a datetime object."""
    try:
        parsed = email.utils.parsedate_to_datetime(date_str)
        return parsed.astimezone(timezone.utc)
    except (ValueError, TypeError):
        return datetime.now(timezone.utc)


def find_existing_uids(archive_dir: Path) -> set:
    """Scan existing archive files for message UIDs to avoid duplicates."""
    uids = set()
    if not archive_dir.exists():
        return uids

    for md_file in archive_dir.rglob("*.md"):
        try:
            content = md_file.read_text(encoding="utf-8", errors="replace")
            # Look for message_uid in YAML frontmatter
            match = re.search(r'^message_uid:\s*"?(\S+?)"?\s*$', content, re.MULTILINE)
            if match:
                uids.add(match.group(1))
        except OSError:
            continue

    return uids


def fetch_folder(
    conn: imaplib.IMAP4_SSL,
    folder: str,
    direction: str,
    my_email: str,
    archive_dir: Path,
    existing_uids: set,
    dry_run: bool,
) -> int:
    """Fetch all messages from a folder and write archive files."""
    try:
        status, _ = conn.select(folder, readonly=True)
        if status != "OK":
            print(f"  Could not select folder '{folder}' — skipping", file=sys.stderr)
            return 0
    except imaplib.IMAP4.error as e:
        print(f"  Error selecting folder '{folder}': {e} — skipping", file=sys.stderr)
        return 0

    # Search for ALL messages (not just UNSEEN)
    _, data = conn.uid("search", None, "ALL")
    uids = data[0].split()
    count = 0

    print(f"  Found {len(uids)} messages in '{folder}'")

    for uid_bytes in uids:
        uid = uid_bytes.decode()
        # Dedup key includes folder context to distinguish inbox vs sent
        dedup_key = f"{folder}-{uid}"
        if dedup_key in existing_uids:
            continue

        try:
            _, msg_data = conn.uid("fetch", uid_bytes, "(BODY.PEEK[])")
            raw = msg_data[0][1]
            msg = email.message_from_bytes(raw)
        except (TypeError, IndexError, imaplib.IMAP4.error) as e:
            print(f"  Error fetching UID {uid}: {e}", file=sys.stderr)
            continue

        sender = decode_header(msg.get("From", ""))
        _, reply_to = email.utils.parseaddr(msg.get("From", ""))
        to_header = decode_header(msg.get("To", ""))
        subject = decode_header(msg.get("Subject", "(no subject)"))
        date_str = msg.get("Date", "")
        body = get_body(msg).strip()
        msg_date = parse_date(date_str)

        # Determine direction from the folder or sender
        if direction == "outgoing":
            actual_direction = "outgoing"
        elif reply_to.lower() == my_email.lower():
            actual_direction = "outgoing"
        else:
            actual_direction = "incoming"

        slug = sanitize_slug(subject)
        year_month = msg_date.strftime("%Y/%m")
        timestamp = msg_date.strftime("%Y-%m-%dT%H%M%SZ")
        filename = f"{timestamp}-{actual_direction}-{slug}.md"

        dir_path = archive_dir / year_month
        filepath = dir_path / filename

        # Build the frontmatter
        lines = ["---"]
        lines.append(f'direction: {actual_direction}')
        lines.append(f'message_uid: "{dedup_key}"')
        lines.append(f'date: "{date_str}"')
        lines.append(f'from: "{sender}"')
        if actual_direction == "incoming":
            lines.append(f'reply_to: "{reply_to}"')
            lines.append(f'to: "{my_email}"')
        else:
            lines.append(f'to: "{to_header}"')
        lines.append(f'subject: "{subject}"')
        lines.append(f'archived_at: "{datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}"')
        lines.append("---")
        lines.append("")
        lines.append(body)
        lines.append("")

        content = "\n".join(lines)

        if dry_run:
            print(f"  [dry-run] Would write: {year_month}/{filename} ({len(body)} chars)")
        else:
            dir_path.mkdir(parents=True, exist_ok=True)
            filepath.write_text(content, encoding="utf-8")
            print(f"  Wrote: {year_month}/{filename}")

        count += 1

    return count


def main():
    dry_run = "--dry-run" in sys.argv

    host = os.environ.get("IMAP_HOST", "imap.gmail.com")
    port = int(os.environ.get("IMAP_PORT", "993"))
    user = os.environ.get("IMAP_USER", "")
    password = os.environ.get("IMAP_PASS", "")
    my_email = os.environ.get("MY_EMAIL", user)
    archive_repo = os.environ.get("ARCHIVE_REPO", "")

    if not archive_repo:
        print("ERROR: ARCHIVE_REPO not set", file=sys.stderr)
        sys.exit(1)

    archive_dir = Path(f"/workspace/repos/{archive_repo}")
    if not archive_dir.exists():
        print(f"ERROR: Archive directory not found: {archive_dir}", file=sys.stderr)
        print("Run 'init_archive_repo' first (entrypoint does this on startup)", file=sys.stderr)
        sys.exit(1)

    if not user or not password:
        print("ERROR: IMAP_USER and IMAP_PASS are required", file=sys.stderr)
        sys.exit(1)

    if dry_run:
        print("=== DRY RUN — no files will be written ===\n")

    # Scan existing files for deduplication
    print("Scanning existing archive for deduplication...")
    existing_uids = find_existing_uids(archive_dir)
    print(f"  Found {len(existing_uids)} existing archived emails\n")

    # Connect to IMAP
    print(f"Connecting to {host}:{port}...")
    try:
        conn = imaplib.IMAP4_SSL(host, port, timeout=60)
        conn.login(user, password)
    except imaplib.IMAP4.error as e:
        print(f"ERROR: IMAP login failed: {e}", file=sys.stderr)
        sys.exit(1)

    total = 0

    # Fetch from INBOX (mostly incoming)
    print("\nFetching from INBOX...")
    total += fetch_folder(conn, "INBOX", "incoming", my_email, archive_dir, existing_uids, dry_run)

    # Fetch from Sent Mail (outgoing)
    print("\nFetching from [Gmail]/Sent Mail...")
    total += fetch_folder(conn, "[Gmail]/Sent Mail", "outgoing", my_email, archive_dir, existing_uids, dry_run)

    conn.logout()

    action = "Would archive" if dry_run else "Archived"
    print(f"\n{action} {total} new email(s)")
    if not dry_run and total > 0:
        print(f"\nDon't forget to commit and push:")
        print(f"  cd {archive_dir}")
        print(f"  git add -A && git commit -m 'backfill: {total} historical emails' && git push")


if __name__ == "__main__":
    main()
