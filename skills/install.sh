#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install.sh — install the reminders skill for Claude Code, with your account
# email and timezone filled in.
#
#   ./skills/install.sh you@gmail.com Europe/Berlin
#   ./skills/install.sh you@gmail.com Europe/Berlin --zip ~/reminders-skill.zip
#
# A symlink would be tidier, but the skill needs two local values and those must
# not live in a public repo. So this copies and substitutes, and re-running it
# after a `git pull` re-applies your values on top of the new version.
#
# --zip additionally emits an archive for claude.ai (Customize -> Skills ->
# "+" -> Create skill). Same single source, two targets: the terminal reads the
# installed copy, the web and phone read the uploaded one, and neither drifts
# from the other.
# ---------------------------------------------------------------------------
set -euo pipefail

EMAIL="${1:-}"
TZONE="${2:-}"
ZIP=""
if [ "${3:-}" = "--zip" ]; then
    ZIP="${4:?--zip needs an output path}"
fi
DEST="${SKILLS_DIR:-$HOME/.claude/skills}/reminders"

if [ -z "$EMAIL" ] || [ -z "$TZONE" ]; then
    echo "usage: $0 <google-account-email> <iana-timezone>" >&2
    echo "example: $0 you@gmail.com Europe/Berlin" >&2
    echo "         $0 you@gmail.com Europe/Berlin --zip ~/reminders-skill.zip" >&2
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

if [ -n "$ZIP" ]; then
    # claude.ai wants a zip whose top level is the skill FOLDER, not a bare
    # SKILL.md, and the folder name must match the `name:` in the frontmatter.
    command -v zip >/dev/null || { echo "error: zip is not installed" >&2; exit 1; }
    STAGE=$(mktemp -d)
    mkdir -p "$STAGE/reminders"
    cp "$DEST/SKILL.md" "$STAGE/reminders/SKILL.md"
    rm -f "$ZIP"
    ( cd "$STAGE" && zip -q -r "$ZIP" reminders )
    rm -rf "$STAGE"
    echo "packaged: $ZIP  (claude.ai -> Customize -> Skills -> + -> Create skill)"
fi

echo "installed: $DEST/SKILL.md"
echo "  account:  $EMAIL"
echo "  timezone: $TZONE"
echo
echo "Re-run this after a git pull to re-apply your values."
