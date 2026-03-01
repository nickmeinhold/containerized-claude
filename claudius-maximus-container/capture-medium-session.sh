#!/usr/bin/env bash
# Capture Medium login session for Claudius.
#
# Two modes:
#   ./capture-medium-session.sh            — extract from existing Chrome profile
#   ./capture-medium-session.sh --fresh    — open fresh Chrome for new login
#
# Medium cookies are extracted separately then MERGED into playwright-storage.json,
# preserving any existing cookies from other sites (e.g. X/Twitter).
#
# Then deploy:
#   fly ssh sftp shell → put playwright-storage.json /workspace/logs/
set -euo pipefail
cd "$(dirname "$0")"

# Ensure Playwright is available as a local module (needed by extract-medium-session.js)
if ! node -e "require('playwright')" 2>/dev/null; then
  echo "Installing Playwright..."
  npm install --no-save playwright
fi

CDP_PORT=9222

# These scripts are local-only (macOS) — they extract cookies from your Chrome
# profile via CDP. They don't run inside the Docker container.
if [[ "$(uname)" != "Darwin" ]]; then
  echo "ERROR: This script requires macOS (Chrome profile access via CDP)."
  echo "Run it on your Mac, then deploy playwright-storage.json to the container."
  exit 1
fi

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
CHROME_USER_DATA_DIR="${HOME}/Library/Application Support/Google/Chrome"
# Profile 12 = xdeca (Claudius's Google account)
CHROME_PROFILE="Profile 12"
CHROME_PID=""
TEMP_DATA_DIR=""

cleanup() {
  [[ -n "${CHROME_PID}" ]] && kill "${CHROME_PID}" 2>/dev/null || true
  [[ -n "${TEMP_DATA_DIR}" ]] && rm -rf "${TEMP_DATA_DIR}" 2>/dev/null || true
  rm -f medium-session.json 2>/dev/null || true
}
trap cleanup EXIT

if [[ "${1:-}" == "--fresh" ]]; then
  # Fresh profile mode: for first-time login (if Google allows it)
  PROFILE_DIR=$(mktemp -d)
  cleanup() {
    [[ -n "${CHROME_PID}" ]] && kill "${CHROME_PID}" 2>/dev/null || true
    rm -rf "${PROFILE_DIR}"
    rm -f medium-session.json 2>/dev/null || true
  }
  trap cleanup EXIT

  echo ""
  echo "=== Medium Session Capture (fresh profile) ==="
  echo "Chrome will open with a fresh profile. Please:"
  echo "  1. Sign in to Medium with Claudius's Google account"
  echo "  2. Verify you're logged in (profile icon visible)"
  echo "  3. Come back here and press Enter (leave Chrome open)"
  echo ""

  "${CHROME}" \
    --user-data-dir="${PROFILE_DIR}" \
    --remote-debugging-port=${CDP_PORT} \
    --no-first-run \
    --no-default-browser-check \
    https://medium.com &
  CHROME_PID=$!

  read -rp "Press Enter when you're logged in to Medium..."
else
  # Default: extract from existing Chrome profile where Claudius is signed in
  echo ""
  echo "=== Medium Session Capture (existing profile) ==="
  echo ""
  echo "This will:"
  echo "  1. Quit Chrome (if running)"
  echo "  2. Relaunch with profile '${CHROME_PROFILE}' + remote debugging"
  echo "  3. Extract Medium cookies via CDP"
  echo "  4. Merge into playwright-storage.json (preserving other site cookies)"
  echo ""

  # Gracefully quit Chrome if running
  if pgrep -x "Google Chrome" >/dev/null 2>&1; then
    echo "Quitting Chrome..."
    osascript -e 'tell application "Google Chrome" to quit' 2>/dev/null || true
    sleep 2
    # Force kill if still running
    if pgrep -x "Google Chrome" >/dev/null 2>&1; then
      echo "Force-closing Chrome..."
      pkill -x "Google Chrome" || true
      sleep 1
    fi
  fi

  # Chrome refuses --remote-debugging-port on its default data directory.
  # Workaround: create a temp data dir with a symlink to the real profile.
  TEMP_DATA_DIR=$(mktemp -d)
  ln -s "${CHROME_USER_DATA_DIR}/${CHROME_PROFILE}" "${TEMP_DATA_DIR}/Default"
  cp "${CHROME_USER_DATA_DIR}/Local State" "${TEMP_DATA_DIR}/" 2>/dev/null || true

  echo "Launching Chrome with profile '${CHROME_PROFILE}' and CDP on port ${CDP_PORT}..."
  "${CHROME}" \
    --user-data-dir="${TEMP_DATA_DIR}" \
    --profile-directory=Default \
    --remote-debugging-port=${CDP_PORT} \
    --no-first-run \
    --no-default-browser-check \
    https://medium.com &
  CHROME_PID=$!
fi

# Wait for Chrome to start and CDP to be ready
echo "Waiting for Chrome CDP..."
for i in $(seq 1 15); do
  if curl -s "http://localhost:${CDP_PORT}/json/version" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -s "http://localhost:${CDP_PORT}/json/version" >/dev/null 2>&1; then
  echo "ERROR: Chrome CDP not responding on port ${CDP_PORT}"
  exit 1
fi

echo "Connected. Waiting for page to load..."
sleep 5

echo "Extracting Medium session..."
node extract-medium-session.js "${CDP_PORT}"

# Merge Medium cookies into the shared storage state file
echo ""
echo "Merging into playwright-storage.json..."
node merge-storage-state.js playwright-storage.json medium-session.json

echo ""
echo "Deploy to Fly.io:"
echo "  fly ssh sftp shell"
echo "  put playwright-storage.json /workspace/logs/playwright-storage.json"
echo ""
echo "Deploy to Docker Compose:"
echo "  docker compose cp playwright-storage.json claudius:/workspace/logs/"
echo ""
echo "Chrome is still open — you can close it when ready."
