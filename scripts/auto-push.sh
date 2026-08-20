#!/bin/bash
# Auto-syncs the utah-stories repo to GitHub.
# Installed as a macOS launchd job, runs daily at 6:30am.
# Commits and pushes ONLY if there are actual changes in the working tree.

set -uo pipefail

export PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

REPO_DIR="/Users/mikeperry1234/sandbox/utah-stories"
LOG_DIR="$REPO_DIR/logs"
LOG_FILE="$LOG_DIR/auto-push.log"

mkdir -p "$LOG_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] $1" >> "$LOG_FILE"
}

cd "$REPO_DIR" || { log "ERROR: could not cd to $REPO_DIR"; exit 1; }

if [ ! -d .git ]; then
  log "ERROR: $REPO_DIR is not a git repo"
  exit 1
fi

# Clear any stale lock left by a previous interrupted run
if [ -f .git/index.lock ]; then
  log "WARNING: removing stale .git/index.lock from a previous run"
  rm -f .git/index.lock
fi

git add -A

if git diff --cached --quiet; then
  log "No changes to sync."
  exit 0
fi

TIMESTAMP="$(date '+%Y-%m-%d %H:%M %Z')"
COMMIT_MSG="Automated sync - ${TIMESTAMP} (macOS launchd cron)"

if git commit -m "$COMMIT_MSG" >> "$LOG_FILE" 2>&1; then
  log "Committed: $COMMIT_MSG"
else
  log "ERROR: git commit failed"
  exit 1
fi

if git push >> "$LOG_FILE" 2>&1; then
  log "Pushed successfully."
else
  log "ERROR: git push failed - check credentials/network"
  exit 1
fi
