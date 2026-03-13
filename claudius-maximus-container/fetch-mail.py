#!/usr/bin/env python3
"""
Fetch unread emails from an IMAP mailbox and print them as JSON.

Uses only Python stdlib (imaplib, email, json) — no pip dependencies.

Environment variables:
    IMAP_HOST           IMAP server hostname (e.g. imap.gmail.com)
    IMAP_PORT           IMAP port (default: 993)
    IMAP_USER           Login username / email address
    IMAP_PASS           Login password or app-specific password
    IMAP_FOLDER         Folder to check (default: INBOX)
    MARK_READ           Set to "true" to mark fetched messages as read (default: false)
    ALLOWED_SENDERS     Comma-separated list of allowed sender emails (fail-closed)
    ATTACHMENT_DIR      Directory to save attachments (default: /workspace/attachments)
    MAX_ATTACHMENT_SIZE Max attachment size in bytes (default: 5242880 = 5MB)
"""

import email
import email.header
import email.message
import email.utils
import imaplib
import json
import os
import re
import sys


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


def sanitize_filename(raw: str) -> str:
    """Decode an RFC 2047 filename, strip path components, and make filesystem-safe.

    Guards against directory traversal (../../etc/passwd) and special characters.
    Truncates to 100 chars to avoid filesystem limits.
    """
    # Decode RFC 2047 encoding (=?utf-8?B?...?=)
    decoded = decode_header(raw) if raw else "attachment"
    # Strip any path components (directory traversal protection)
    decoded = os.path.basename(decoded)
    # Replace anything that isn't alphanumeric, dot, hyphen, or underscore
    decoded = re.sub(r"[^\w.\-]", "_", decoded)
    # Collapse runs of underscores
    decoded = re.sub(r"_+", "_", decoded).strip("_")
    # Truncate to 100 chars (preserving extension)
    if len(decoded) > 100:
        name, _, ext = decoded.rpartition(".")
        if ext and len(ext) <= 10:
            decoded = name[: 100 - len(ext) - 1] + "." + ext
        else:
            decoded = decoded[:100]
    return decoded or "attachment"


# Extensions and MIME types that Claude can meaningfully process.
# Claude Code's Read tool is multimodal — it handles text, PDFs, and images natively.
PROCESSABLE_EXTENSIONS = {
    # Text and code
    ".txt", ".md", ".csv", ".json", ".xml", ".yaml", ".yml", ".toml",
    ".py", ".js", ".ts", ".jsx", ".tsx", ".html", ".css", ".scss",
    ".sh", ".bash", ".zsh", ".fish",
    ".c", ".cpp", ".h", ".hpp", ".java", ".go", ".rs", ".rb", ".php",
    ".sql", ".r", ".m", ".swift", ".kt", ".scala", ".lua",
    ".ini", ".cfg", ".conf", ".env", ".properties",
    ".tex", ".bib", ".rst", ".org", ".adoc",
    ".log", ".diff", ".patch",
    # Documents
    ".pdf",
    # Images (Claude Code reads these visually)
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp", ".ico",
}

PROCESSABLE_MIME_PREFIXES = ("text/", "image/")


def is_processable(filename: str, content_type: str) -> bool:
    """Return True if the attachment is something Claude can meaningfully process.

    Covers text files, code, PDFs, and images — all formats that Claude Code's
    multimodal Read tool can handle natively.
    """
    ext = os.path.splitext(filename)[1].lower()
    if ext in PROCESSABLE_EXTENSIONS:
        return True
    if any(content_type.startswith(p) for p in PROCESSABLE_MIME_PREFIXES):
        return True
    if content_type == "application/pdf":
        return True
    return False


def get_attachments(
    msg: email.message.Message,
    uid: str,
    attachment_dir: str,
    max_size: int,
) -> list[dict]:
    """Walk MIME parts, save processable attachments to disk, return metadata.

    Saves files to <attachment_dir>/<uid>/<filename>. Handles filename
    collisions within the same email by appending a counter suffix.

    Returns a list of dicts with: filename, content_type, size, processable,
    path (on disk, only for processable), and skipped_reason.
    """
    attachments = []
    seen_names: dict[str, int] = {}  # track filenames for collision handling

    for part in msg.walk():
        # Skip multipart containers — they're just wrappers
        if part.get_content_maintype() == "multipart":
            continue

        disposition = str(part.get("Content-Disposition", ""))
        filename_raw = part.get_filename()

        # Only consider parts that are actual attachments (have a filename
        # or explicit attachment disposition). Inline text/plain is the email
        # body — handled by get_body().
        if not filename_raw and "attachment" not in disposition:
            continue

        content_type = part.get_content_type()
        filename = sanitize_filename(filename_raw or f"unnamed.{content_type.split('/')[-1]}")

        # Handle filename collisions within the same email
        if filename in seen_names:
            seen_names[filename] += 1
            name, dot, ext = filename.rpartition(".")
            if dot:
                filename = f"{name}_{seen_names[filename]}.{ext}"
            else:
                filename = f"{filename}_{seen_names[filename]}"
        else:
            seen_names[filename] = 0

        payload = part.get_payload(decode=True)
        size = len(payload) if payload else 0

        # Check for empty
        if size == 0:
            attachments.append({
                "filename": filename,
                "content_type": content_type,
                "size": 0,
                "processable": False,
                "path": None,
                "skipped_reason": "empty",
            })
            continue

        # Check size limit
        if size > max_size:
            attachments.append({
                "filename": filename,
                "content_type": content_type,
                "size": size,
                "processable": False,
                "path": None,
                "skipped_reason": "too_large",
            })
            continue

        processable = is_processable(filename, content_type)

        if not processable:
            attachments.append({
                "filename": filename,
                "content_type": content_type,
                "size": size,
                "processable": False,
                "path": None,
                "skipped_reason": "binary_type",
            })
            continue

        # Save processable attachment to disk
        uid_dir = os.path.join(attachment_dir, uid)
        os.makedirs(uid_dir, exist_ok=True)
        filepath = os.path.join(uid_dir, filename)

        with open(filepath, "wb") as f:
            f.write(payload)

        attachments.append({
            "filename": filename,
            "content_type": content_type,
            "size": size,
            "processable": True,
            "path": filepath,
            "skipped_reason": None,
        })
        print(f"Saved attachment: {filepath} ({size} bytes)", file=sys.stderr)

    return attachments


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
        # Fallback: return first text part of any type
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


def main():
    host = os.environ.get("IMAP_HOST", "imap.gmail.com")
    port = int(os.environ.get("IMAP_PORT", "993"))
    user = os.environ.get("IMAP_USER", "")
    password = os.environ.get("IMAP_PASS", "")
    folder = os.environ.get("IMAP_FOLDER", "INBOX")
    # Mark-as-read is deferred to the caller (agent-loop) after successful processing
    mark_read = os.environ.get("MARK_READ", "false").lower() == "true"
    attachment_dir = os.environ.get("ATTACHMENT_DIR", "/workspace/attachments")
    max_attachment_size = int(os.environ.get("MAX_ATTACHMENT_SIZE", "5242880"))

    # Sender allowlist — fail-closed: if unset/empty, reject ALL emails
    allowed_raw = os.environ.get("ALLOWED_SENDERS", "").strip()
    allowed_senders = {
        addr.strip().lower()
        for addr in allowed_raw.split(",")
        if addr.strip()
    }
    if not allowed_senders:
        print(
            "ALLOWED_SENDERS is empty or unset — rejecting all emails (fail-closed)",
            file=sys.stderr,
        )
        print(json.dumps({"count": 0, "messages": []}))
        return

    if not user or not password:
        print(json.dumps({"error": "IMAP_USER and IMAP_PASS are required"}))
        sys.exit(1)

    try:
        conn = imaplib.IMAP4_SSL(host, port, timeout=30)
        conn.login(user, password)
        conn.select(folder)

        # Search for unseen messages by UID (stable across sessions, unlike
        # sequence numbers which shift when other clients modify the mailbox)
        _, data = conn.uid("search", None, "UNSEEN")

        uids = data[0].split()
        messages = []

        for uid in uids:
            _, msg_data = conn.uid("fetch", uid, "(BODY.PEEK[])")
            raw = msg_data[0][1]
            msg = email.message_from_bytes(raw)

            sender = decode_header(msg.get("From", ""))
            subject = decode_header(msg.get("Subject", ""))
            date = msg.get("Date", "")
            body = get_body(msg)

            # Extract just the email address for replies
            _, reply_to = email.utils.parseaddr(msg.get("From", ""))

            # Check sender against allowlist (case-insensitive)
            if reply_to.lower() not in allowed_senders:
                print(
                    f"Sender not in allowlist, skipping: {reply_to}",
                    file=sys.stderr,
                )
                continue

            # Extract and save attachments
            attachments = get_attachments(msg, uid.decode(), attachment_dir, max_attachment_size)

            # Extract To and Cc recipients for reply-all support.
            # Headers may contain comma-separated addresses, so split first.
            to_addresses = [
                email.utils.parseaddr(part.strip())[1]
                for header in (msg.get_all("To") or [])
                for part in header.split(",")
            ]
            cc_addresses = [
                email.utils.parseaddr(part.strip())[1]
                for header in (msg.get_all("Cc") or [])
                for part in header.split(",")
            ]
            # Filter out empty strings from malformed headers
            to_addresses = [a for a in to_addresses if a]
            cc_addresses = [a for a in cc_addresses if a]

            messages.append({
                "uid": uid.decode(),
                "from": sender,
                "reply_to": reply_to,
                "to": to_addresses,
                "cc": cc_addresses,
                "subject": subject,
                "date": date,
                "body": body.strip(),
                "attachments": attachments,
            })

            # Mark as read so we don't process it again
            if mark_read:
                conn.uid("store", uid, "+FLAGS", "\\Seen")

        conn.close()
        conn.logout()

        print(json.dumps({"count": len(messages), "messages": messages}))

    except imaplib.IMAP4.error as e:
        print(json.dumps({"error": f"IMAP error: {e}"}))
        sys.exit(1)
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)


if __name__ == "__main__":
    main()
