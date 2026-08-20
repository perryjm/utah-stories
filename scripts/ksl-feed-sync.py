#!/usr/bin/env python3
"""Runs the /ksl-feed Claude Code skill on a schedule and pushes any resulting
feed changes. Invoked hourly by local.utahstories.ksl-feed.plist (launchd);
enforces its own 24h minimum interval via the sqlite runbook so back-to-back
launchd fires don't double-run.
"""

import fcntl
import os
import shutil
import sqlite3
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_DIR = Path(os.environ.get("REPO_DIR", SCRIPT_DIR.parent))
RUNBOOK_DB = Path(os.environ.get("RUNBOOK_DB", REPO_DIR / ".ksl-feed-runbook.sqlite3"))
LOG_DIR = Path(os.environ.get("LOG_DIR", REPO_DIR / "logs"))
LOG_FILE = Path(os.environ.get("LOG_FILE", LOG_DIR / "ksl-feed-sync.log"))
LOCK_FILE = Path(os.environ.get("LOCK_FILE", REPO_DIR / ".ksl-feed-sync.lock"))
CLAUDE_BIN = os.environ.get("CLAUDE_BIN", "/opt/homebrew/bin/claude")
MIN_INTERVAL_SECONDS = 86400

_log_fh = None


def log(message):
    stamp = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
    _log_fh.write(f"[{stamp}] {message}\n")
    _log_fh.flush()


def die(message, code=1):
    log(message)
    sys.exit(code)


def acquire_lock():
    """Exclusive, non-blocking flock; kernel releases it if we crash, so
    unlike a pid-file scheme there's no stale-lock cleanup to worry about."""
    lock_fh = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("Another sync is already running; skipping.")
        sys.exit(0)
    lock_fh.write(f"{os.getpid()}\n")
    lock_fh.flush()
    return lock_fh  # keep open for the life of the process to hold the lock


def run_logged(cmd):
    """Run cmd with stdout+stderr appended to the log file, like `>> LOG_FILE 2>&1`."""
    return subprocess.run(cmd, stdout=_log_fh, stderr=subprocess.STDOUT)


def git_output(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def resolve_claude_bin():
    if os.access(CLAUDE_BIN, os.X_OK):
        return CLAUDE_BIN
    resolved = shutil.which(CLAUDE_BIN)
    if not resolved:
        die(f"ERROR: claude executable not found: {CLAUDE_BIN}")
    return resolved


def init_runbook():
    RUNBOOK_DB.parent.mkdir(parents=True, exist_ok=True)
    try:
        conn = sqlite3.connect(RUNBOOK_DB)
        with conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS runbook (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    last_success_epoch INTEGER NOT NULL CHECK (last_success_epoch >= 0)
                )
                """
            )
        return conn
    except sqlite3.Error as exc:
        die(f"ERROR: could not initialize runbook database: {RUNBOOK_DB} ({exc})")


def read_last_success_epoch(conn):
    try:
        row = conn.execute(
            "SELECT COALESCE((SELECT last_success_epoch FROM runbook WHERE id = 1), 0)"
        ).fetchone()
        return row[0]
    except sqlite3.Error as exc:
        die(f"ERROR: could not read the last successful run from the runbook ({exc})")


def record_success(conn, success_epoch):
    try:
        with conn:
            conn.execute(
                """
                INSERT INTO runbook (id, last_success_epoch) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET last_success_epoch = excluded.last_success_epoch
                """,
                (success_epoch,),
            )
    except sqlite3.Error as exc:
        die(f"ERROR: push succeeded, but recording the successful run failed ({exc})")


def main():
    os.chdir(REPO_DIR)
    if not (REPO_DIR / ".git").is_dir():
        die(f"ERROR: {REPO_DIR} is not a git repository")

    lock_fh = acquire_lock()  # noqa: F841 - held open for the process lifetime

    conn = init_runbook()

    now_epoch = int(time.time())
    last_success_epoch = read_last_success_epoch(conn)
    elapsed_seconds = now_epoch - last_success_epoch
    if last_success_epoch > 0 and elapsed_seconds < MIN_INTERVAL_SECONDS:
        log(
            f"Skipping: last full success was {elapsed_seconds}s ago; "
            f"minimum interval is {MIN_INTERVAL_SECONDS}s."
        )
        return 0

    status = git_output(["git", "status", "--porcelain=v1", "--untracked-files=all"])
    if status.returncode != 0:
        _log_fh.write(status.stderr)
        die("ERROR: could not inspect the git working tree")
    if status.stdout.strip():
        log("ERROR: working tree is not clean; refusing to run or commit unrelated changes.")
        _log_fh.write(status.stdout)
        return 1

    claude_bin = resolve_claude_bin()

    log("Starting: claude -p /ksl-feed --permission-mode auto")
    result = run_logged([claude_bin, "-p", "/ksl-feed", "--permission-mode", "auto"])
    if result.returncode != 0:
        log(f"ERROR: Claude command failed with exit code {result.returncode}")
        return result.returncode
    log("Claude completed successfully.")

    if git_output(["git", "diff", "--quiet", "--", "ksl-utah-news.xml"]).returncode == 0:
        log("Claude completed, but no new stories changed ksl-utah-news.xml; runbook unchanged.")
        return 0

    if run_logged(["git", "add", "-A"]).returncode != 0:
        die("ERROR: git add failed")

    if git_output(["git", "diff", "--cached", "--quiet"]).returncode == 0:
        log("Claude completed, but there were no staged changes to commit; runbook unchanged.")
        return 0

    commit_timestamp = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")
    commit_message = f"Automated KSL feed sync - {commit_timestamp}"
    if run_logged(["git", "commit", "-m", commit_message]).returncode != 0:
        die("ERROR: git commit failed")
    log(f"Committed: {commit_message}")

    if run_logged(["git", "push"]).returncode != 0:
        die("ERROR: git push failed; runbook unchanged so a later hourly attempt can retry.")
    log("Pushed successfully.")

    record_success(conn, int(time.time()))
    log("SUCCESS: new stories were added, committed, pushed, and recorded in the runbook.")
    return 0


if __name__ == "__main__":
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    _log_fh = open(LOG_FILE, "a")
    try:
        sys.exit(main())
    except Exception:
        import traceback

        _log_fh.write(traceback.format_exc())
        _log_fh.flush()
        sys.exit(1)
