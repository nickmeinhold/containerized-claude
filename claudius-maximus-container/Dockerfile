# Containerized Claude Code Agent
# Runs a single Claude agent that polls an email inbox, thinks, and replies.
# Designed for peer-to-peer Claude-to-Claude communication across machines.

FROM node:20-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    bc \
    curl \
    git \
    jq \
    msmtp \
    msmtp-mta \
    python3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI globally
RUN npm install -g @anthropic-ai/claude-code

# Create a non-root user — Claude Code refuses --dangerously-skip-permissions as root
RUN useradd -m -s /bin/bash claudius

# Set up directories
RUN mkdir -p /home/claudius/.claude/commands /workspace/logs /workspace/repos /workspace/attachments \
    && chown -R claudius:claudius /home/claudius /workspace

# Copy committed Claude config — CLAUDE.md lives in .claude/ (tracked in git).
# Custom commands/ and plans/ can be added by mounting or extending the image;
# directories are already created above.
COPY CLAUDE.md /home/claudius/.claude/CLAUDE.md

# Copy application files
COPY settings.json /home/claudius/.claude/settings.json
# msmtprc is mounted at runtime via docker-compose.yml to keep SMTP
# credentials out of image layers. This placeholder is overlaid by the
# bind mount — actual permissions come from the host file.
RUN touch /etc/msmtprc && chmod 600 /etc/msmtprc && chown claudius:claudius /etc/msmtprc

COPY fetch-mail.py /usr/local/bin/fetch-mail
RUN chmod +x /usr/local/bin/fetch-mail

COPY mark-read.py /usr/local/bin/mark-read
RUN chmod +x /usr/local/bin/mark-read

COPY agent-loop.sh /usr/local/bin/agent-loop
RUN chmod +x /usr/local/bin/agent-loop

COPY token-refresh.sh /usr/local/bin/token-refresh
RUN chmod +x /usr/local/bin/token-refresh

COPY archive-email.sh /usr/local/bin/archive-email
RUN chmod +x /usr/local/bin/archive-email

COPY backfill-archive.py /usr/local/bin/backfill-archive
RUN chmod +x /usr/local/bin/backfill-archive

COPY persona-claudius.md /workspace/persona-claudius.md

COPY entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

RUN chown -R claudius:claudius /home/claudius /workspace

USER claudius
WORKDIR /workspace

ENTRYPOINT ["entrypoint"]
