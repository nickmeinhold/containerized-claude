#!/usr/bin/env python3
"""
Mark a single email as read by UID.

Usage: mark-read <uid>

Environment variables:
    IMAP_HOST    IMAP server hostname
    IMAP_PORT    IMAP port (default: 993)
    IMAP_USER    Login username
    IMAP_PASS    Login password
    IMAP_FOLDER  Folder (default: INBOX)
"""

import imaplib
import os
import sys


def main():
    if len(sys.argv) < 2:
        print("Usage: mark-read <uid>", file=sys.stderr)
        sys.exit(1)

    uid = sys.argv[1].encode()
    host = os.environ.get("IMAP_HOST", "imap.gmail.com")
    port = int(os.environ.get("IMAP_PORT", "993"))
    user = os.environ.get("IMAP_USER", "")
    password = os.environ.get("IMAP_PASS", "")
    folder = os.environ.get("IMAP_FOLDER", "INBOX")

    conn = imaplib.IMAP4_SSL(host, port, timeout=30)
    conn.login(user, password)
    conn.select(folder)
    conn.uid("store", uid, "+FLAGS", "\\Seen")
    conn.close()
    conn.logout()


if __name__ == "__main__":
    main()
