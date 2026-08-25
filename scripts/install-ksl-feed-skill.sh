#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
SOURCE="$REPO_DIR/.claude/skills/ksl-feed/SKILL.md"
SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
TARGET_DIR="$SKILLS_DIR/ksl-feed"
TARGET="$TARGET_DIR/SKILL.md"

if [ ! -f "$SOURCE" ]; then
    printf 'error: tracked skill not found: %s\n' "$SOURCE" >&2
    exit 1
fi

mkdir -p "$TARGET_DIR"
install -m 0644 "$SOURCE" "$TARGET"
printf 'Installed %s\n' "$TARGET"
