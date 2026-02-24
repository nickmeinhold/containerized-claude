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
"""

import email
import email.header
import email.utils
import imaplib
import json
import os
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
            _, msg_data = conn.uid("fetch", uid, "(RFC822)")
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

            messages.append({
                "uid": uid.decode(),
                "from": sender,
                "reply_to": reply_to,
                "subject": subject,
                "date": date,
                "body": body.strip(),
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
