#!/bin/bash

set -u
set -o pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
REPO_DIR="${REPO_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd -P)}"
RUNBOOK_DB="${RUNBOOK_DB:-$REPO_DIR/.ksl-feed-runbook.sqlite3}"
LOG_DIR="${LOG_DIR:-$REPO_DIR/logs}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/ksl-feed-sync.log}"
LOCK_DIR="${LOCK_DIR:-$REPO_DIR/.ksl-feed-sync.lock}"
CLAUDE_BIN="${CLAUDE_BIN:-/opt/homebrew/bin/claude}"
MIN_INTERVAL_SECONDS=86400

if ! mkdir -p "$LOG_DIR"; then
  printf 'ERROR: could not create log directory: %s\n' "$LOG_DIR" >&2
  exit 1
fi

if ! : >> "$LOG_FILE"; then
  printf 'ERROR: could not write log file: %s\n' "$LOG_FILE" >&2
  exit 1
fi

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$1" >> "$LOG_FILE"
}

if ! cd "$REPO_DIR"; then
  log "ERROR: could not cd to $REPO_DIR"
  exit 1
fi

if [ ! -d .git ]; then
  log "ERROR: $REPO_DIR is not a git repository"
  exit 1
fi

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    if ! printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
      rmdir "$LOCK_DIR" 2>/dev/null || true
      log "ERROR: could not write lock owner"
      return 1
    fi
    return 0
  fi

  owner_pid=""
  if [ -r "$LOCK_DIR/pid" ]; then
    owner_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  fi

  case "$owner_pid" in
    ''|*[!0-9]*)
      ;;
    *)
      if kill -0 "$owner_pid" 2>/dev/null; then
        log "Another sync is already running (pid $owner_pid); skipping."
        return 2
      fi
      ;;
  esac

  rm -f "$LOCK_DIR/pid"
  if ! rmdir "$LOCK_DIR" 2>/dev/null; then
    log "Another sync acquired the lock; skipping."
    return 2
  fi

  if ! mkdir "$LOCK_DIR" || ! printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
    log "ERROR: could not acquire sync lock"
    return 1
  fi

  return 0
}

release_lock() {
  if [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

lock_status=0
acquire_lock || lock_status=$?
case "$lock_status" in
  0)
    trap release_lock EXIT
    ;;
  2)
    exit 0
    ;;
  *)
    exit 1
    ;;
esac

if ! mkdir -p "$(dirname "$RUNBOOK_DB")"; then
  log "ERROR: could not create runbook database directory"
  exit 1
fi

if ! sqlite3 -batch "$RUNBOOK_DB" >> "$LOG_FILE" 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS runbook (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  last_success_epoch INTEGER NOT NULL CHECK (last_success_epoch >= 0)
);
SQL
then
  log "ERROR: could not initialize runbook database: $RUNBOOK_DB"
  exit 1
fi

now_epoch="$(date +%s)"
if ! [[ "$now_epoch" =~ ^[0-9]+$ ]]; then
  log "ERROR: could not determine the current time"
  exit 1
fi

last_success_epoch="$(sqlite3 -batch -noheader "$RUNBOOK_DB" \
  'SELECT COALESCE((SELECT last_success_epoch FROM runbook WHERE id = 1), 0);' \
  2>> "$LOG_FILE")"
sqlite_status=$?
if [ "$sqlite_status" -ne 0 ] || ! [[ "$last_success_epoch" =~ ^[0-9]+$ ]]; then
  log "ERROR: could not read the last successful run from the runbook"
  exit 1
fi

elapsed_seconds=$((now_epoch - last_success_epoch))
if [ "$last_success_epoch" -gt 0 ] && [ "$elapsed_seconds" -lt "$MIN_INTERVAL_SECONDS" ]; then
  log "Skipping: last full success was ${elapsed_seconds}s ago; minimum interval is ${MIN_INTERVAL_SECONDS}s."
  exit 0
fi

working_tree_status="$(git status --porcelain=v1 --untracked-files=all 2>> "$LOG_FILE")"
if [ "$?" -ne 0 ]; then
  log "ERROR: could not inspect the git working tree"
  exit 1
fi
if [ -n "$working_tree_status" ]; then
  log "ERROR: working tree is not clean; refusing to run or commit unrelated changes."
  printf '%s\n' "$working_tree_status" >> "$LOG_FILE"
  exit 1
fi

if [ ! -x "$CLAUDE_BIN" ]; then
  resolved_claude_bin="$(command -v "$CLAUDE_BIN" 2>/dev/null || true)"
  if [ -z "$resolved_claude_bin" ]; then
    log "ERROR: claude executable not found: $CLAUDE_BIN"
    exit 1
  fi
  CLAUDE_BIN="$resolved_claude_bin"
fi

log "Starting: claude -p /ksl-feed --execution-mode auto"
if "$CLAUDE_BIN" -p "/ksl-feed" --execution-mode auto >> "$LOG_FILE" 2>&1; then
  log "Claude completed successfully."
else
  claude_status=$?
  log "ERROR: Claude command failed with exit code $claude_status"
  exit "$claude_status"
fi

if git diff --quiet -- ksl-utah-news.xml; then
  log "Claude completed, but no new stories changed ksl-utah-news.xml; runbook unchanged."
  exit 0
fi

if ! git add -A >> "$LOG_FILE" 2>&1; then
  log "ERROR: git add failed"
  exit 1
fi

if git diff --cached --quiet; then
  log "Claude completed, but there were no staged changes to commit; runbook unchanged."
  exit 0
fi

commit_timestamp="$(date '+%Y-%m-%d %H:%M %Z')"
commit_message="Automated KSL feed sync - ${commit_timestamp}"
if ! git commit -m "$commit_message" >> "$LOG_FILE" 2>&1; then
  log "ERROR: git commit failed"
  exit 1
fi
log "Committed: $commit_message"

if ! git push >> "$LOG_FILE" 2>&1; then
  log "ERROR: git push failed; runbook unchanged so a later hourly attempt can retry."
  exit 1
fi
log "Pushed successfully."

success_epoch="$(date +%s)"
if ! sqlite3 -batch "$RUNBOOK_DB" \
  "INSERT INTO runbook (id, last_success_epoch) VALUES (1, $success_epoch)
   ON CONFLICT(id) DO UPDATE SET last_success_epoch = excluded.last_success_epoch;" \
  >> "$LOG_FILE" 2>&1
then
  log "ERROR: push succeeded, but recording the successful run failed."
  exit 1
fi

log "SUCCESS: new stories were added, committed, pushed, and recorded in the runbook."
