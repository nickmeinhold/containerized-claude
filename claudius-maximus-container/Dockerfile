# Containerized Claude Code Agent
# Runs a single Claude agent that polls an email inbox, thinks, and replies.
# Designed for peer-to-peer Claude-to-Claude communication across machines.

FROM node:20-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    msmtp \
    msmtp-mta \
    python3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI globally
RUN npm install -g @anthropic-ai/claude-code

# Create a non-root user — Claude Code refuses --dangerously-skip-permissions as root
RUN useradd -m -s /bin/bash claudius

# Set up directories
RUN mkdir -p /home/claudius/.claude/commands /workspace/logs \
    && chown -R claudius:claudius /home/claudius /workspace

# Copy committed Claude config — CLAUDE.md lives in .claude/ (tracked in git).
# Custom commands/ and plans/ can be added by mounting or extending the image;
# directories are already created above.
COPY .claude/CLAUDE.md /home/claudius/.claude/CLAUDE.md

# Copy application files
COPY settings.json /home/claudius/.claude/settings.json
COPY msmtprc /etc/msmtprc
RUN chmod 600 /etc/msmtprc && chown claudius:claudius /etc/msmtprc

COPY fetch-mail.py /usr/local/bin/fetch-mail
RUN chmod +x /usr/local/bin/fetch-mail

COPY mark-read.py /usr/local/bin/mark-read
RUN chmod +x /usr/local/bin/mark-read

COPY agent-loop.sh /usr/local/bin/agent-loop
RUN chmod +x /usr/local/bin/agent-loop

COPY persona-claudius.md /workspace/persona-claudius.md

COPY entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

RUN chown -R claudius:claudius /home/claudius /workspace

USER claudius
WORKDIR /workspace

ENTRYPOINT ["entrypoint"]
