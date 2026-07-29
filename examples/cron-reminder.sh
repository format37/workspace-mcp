#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cron-reminder.sh — create a reminder with no model in the loop.
#
# The MCP server is the only thing that talks to Google; this script is just
# another OAuth client of it, via `workspace-cli`. Use it for reminders whose
# schedule is known in advance and does not need a conversation.
#
# Install (on the always-on box, not a laptop):
#
#   uv tool install workspace-mcp          # provides workspace-cli
#   cp .env.example .env && chmod 600 .env # fill in, see below
#   crontab -e
#
#     # 09:00 Europe/Berlin daily stand-up reminder (cron runs in UTC: 07:00)
#     0 7 * * 1-5  /home/USER/workspace-mcp/examples/cron-reminder.sh >> /home/USER/cron-reminder.log 2>&1
#
# Write cron lines in UTC and put the local time in the comment. Do not rely on
# the box's timezone; do not encode a fixed UTC offset in the event itself
# either — the IANA zone name is what keeps it correct across DST.
#
# FIRST AUTH cannot happen here. workspace-cli opens a browser and waits on a
# random loopback port. Authenticate once on a desktop AGAINST THE PRODUCTION
# URL, then transplant the cache — see README, "workspace-cli on a headless
# box".
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/.."

# .env carries WORKSPACE_MCP_URL, GOOGLE_ACCOUNT_EMAIL, REMINDER_TIMEZONE,
# TELEGRAM_TOKEN, TELEGRAM_CHAT.
set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${WORKSPACE_MCP_URL:?set WORKSPACE_MCP_URL in .env}"
: "${GOOGLE_ACCOUNT_EMAIL:?set GOOGLE_ACCOUNT_EMAIL in .env}"
: "${REMINDER_TIMEZONE:?set REMINDER_TIMEZONE in .env}"

SUMMARY="Daily stand-up"
LEAD_MINUTES=0          # 0 = the notification fires exactly at the event start
DURATION_MINUTES=15

# --- What this script alerts on --------------------------------------------
# A reminder system that fails quietly is worse than none. The realistic
# failure is credential rot: when the cached token can no longer be refreshed,
# workspace-cli tries to open a browser, blocks for its full 300-second
# callback timeout, and then dies into unread cron mail. So: hard timeout, and
# a push on any non-zero exit.
alert() {
    local text="$1"
    if [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT:-}" ]; then
        curl -fsS -m 20 -X POST \
            "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT}" \
            -d "text=${text}" >/dev/null || true
    fi
    echo "$text" >&2
}

# --- Compute the reminder moment -------------------------------------------
# Naive local time plus an explicit IANA zone. manage_event does NOT normalise
# these strings — whatever you send goes to Google essentially verbatim — so a
# bare local datetime with no zone would simply be rejected.
#
# `date` here runs in the container-host's clock (UTC by convention), so ask it
# for the target zone explicitly rather than assuming.
# Derive END from START rather than from "today 09:00 + N minutes": GNU date
# reads the "+N" in that phrasing as a timezone offset and silently returns a
# time on the wrong day.
START=$(TZ="$REMINDER_TIMEZONE" date -d "today 09:00" +%Y-%m-%dT%H:%M:%S)
END=$(TZ="$REMINDER_TIMEZONE" date -d "${START} ${DURATION_MINUTES} minutes" +%Y-%m-%dT%H:%M:%S)

# The context block. Its first line is the marker that makes agent- and
# cron-created items findable later; `Source:` says which script wrote it, so a
# read-back can tell them apart.
read -r -d '' DESCRIPTION <<EOF || true
#claude-reminder
Why: daily stand-up.
Source: cron examples/cron-reminder.sh on $(hostname -s)
EOF

# --- Fire -------------------------------------------------------------------
# `--url` must precede the subcommand (it is a top-level flag), so exporting
# WORKSPACE_MCP_URL and omitting the flag is the more robust habit.
#
# Argument values are parsed as JSON with a plain-string fallback, which is how
# the reminders array survives. Single-quote each key=value so the shell does
# not eat the braces.
#
# send_updates=none: the tool's effective default is "all". With no attendees
# nothing would be sent anyway, but a cron job should never be one edit away
# from mailing people.
if ! timeout 120 workspace-cli call manage_event \
        action=create \
        "user_google_email=${GOOGLE_ACCOUNT_EMAIL}" \
        calendar_id=primary \
        "summary=${SUMMARY}" \
        "start_time=${START}" \
        "end_time=${END}" \
        "timezone=${REMINDER_TIMEZONE}" \
        "description=${DESCRIPTION}" \
        send_updates=none \
        "reminders=[{\"method\":\"popup\",\"minutes\":${LEAD_MINUTES}}]" ; then
    alert "workspace-mcp cron: FAILED to create reminder '${SUMMARY}' for ${START} ${REMINDER_TIMEZONE}. Check the cached credentials on $(hostname -s)."
    exit 1
fi

echo "created: ${SUMMARY} @ ${START} ${REMINDER_TIMEZONE}"
