#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install.sh — install the reminders skill for Claude Code, with your account
# email and timezone filled in.
#
#   ./skills/install.sh you@gmail.com Europe/Berlin
#
# A symlink would be tidier, but the skill needs two local values and those must
# not live in a public repo. So this copies and substitutes, and re-running it
# after a `git pull` re-applies your values on top of the new version.
# ---------------------------------------------------------------------------
set -euo pipefail

EMAIL="${1:-}"
TZONE="${2:-}"
DEST="${SKILLS_DIR:-$HOME/.claude/skills}/reminders"

if [ -z "$EMAIL" ] || [ -z "$TZONE" ]; then
    echo "usage: $0 <google-account-email> <iana-timezone>" >&2
    echo "example: $0 you@gmail.com Europe/Berlin" >&2
    exit 1
fi

# Reject an offset masquerading as a zone: "+04:00" would be silently accepted
# by Google on a one-off event and then drift by an hour across a DST boundary.
case "$TZONE" in
    */*) : ;;
    UTC) : ;;
    *) echo "error: '$TZONE' is not an IANA zone name (expected e.g. Europe/Berlin)" >&2; exit 1 ;;
esac

SRC="$(cd "$(dirname "$0")" && pwd)/reminders/SKILL.md"
[ -f "$SRC" ] || { echo "error: $SRC not found" >&2; exit 1; }

mkdir -p "$DEST"
sed -e "s|you@gmail.com|${EMAIL}|g" \
    -e "s|Europe/Berlin|${TZONE}|g" \
    "$SRC" > "$DEST/SKILL.md"

echo "installed: $DEST/SKILL.md"
echo "  account:  $EMAIL"
echo "  timezone: $TZONE"
echo
echo "Re-run this after a git pull to re-apply your values."
