#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# deadman-check.sh — weekly "is this thing still real" check.
#
#   crontab -e
#     # Mondays 08:00 UTC
#     0 8 * * 1  /home/USER/workspace-mcp/examples/deadman-check.sh >> /home/USER/deadman.log 2>&1
#
# A reminder system fails in ways nobody notices: a dead Google refresh token
# produces no error anywhere until the day you needed the reminder. Four checks,
# cheapest first, one Telegram message if any of them trips.
#
#   1. /health          — is the container serving at all?
#   2. list_calendars   — the ONLY check that exercises the full path: MCP
#                         auth -> stored Google refresh token -> Google API.
#                         /health passes happily with dead credentials.
#   3. stray accounts   — one credential file per authorised Google account.
#                         Anything but yours means somebody else completed a
#                         consent flow against this endpoint.
#   4. disk growth      — client registrations are persisted without a TTL, so
#                         anonymous registration spam accumulates.
#
# Note this is the real watchdog. The image ships a Docker HEALTHCHECK, but
# Docker does not restart a container for failing it — an unhealthy-but-running
# container will sit there indefinitely.
# ---------------------------------------------------------------------------
set -uo pipefail          # deliberately NOT -e: every check must run, then report

cd "$(dirname "$0")/.."

set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${WORKSPACE_MCP_URL:?set WORKSPACE_MCP_URL in .env}"
: "${GOOGLE_ACCOUNT_EMAIL:?set GOOGLE_ACCOUNT_EMAIL in .env}"

CONTAINER=mcp-workspace
CREDS_DIR=/app/store_creds/google
STATE_DIR=/app/store_creds
MAX_STATE_MB=200

HEALTH_URL="${WORKSPACE_MCP_URL%/mcp}/health"
problems=()

# --- 1. liveness ------------------------------------------------------------
if health=$(curl -fsS -m 20 "$HEALTH_URL" 2>&1); then
    case "$health" in
        *'"status":"healthy"'*) : ;;
        *) problems+=("health endpoint answered but not healthy: ${health}") ;;
    esac
else
    problems+=("health endpoint unreachable (${HEALTH_URL}): ${health}")
fi

# --- 2. the full OAuth + Google path ----------------------------------------
# `list` reports only an exception class name on failure, so use a real tool
# call: it surfaces the actual error. A dead refresh token shows up as
# invalid_grant in the server log and as a non-zero exit here.
#
# The 120 s leash matters: with unusable credentials workspace-cli waits 300 s
# for a browser callback that can never arrive on a headless box.
# No account argument: OAuth 2.1 mode removes user_google_email from the tool
# signature and derives the account from the token. GOOGLE_ACCOUNT_EMAIL is
# still needed below, for the stray-account check.
if ! calendars=$(timeout 120 workspace-cli call list_calendars 2>&1); then
    # Distinguish the two failures that need different responses, and NEVER
    # forward the raw output. When credentials are unusable the CLI prints a
    # live OAuth authorization URL and then blocks on a loopback callback; that
    # URL has no business being pushed into a chat, and the surrounding log
    # noise buries the actual signal. Both learned by running this for real.
    case "$calendars" in
        *"OAuth callback server started"*|*"authorization URL"*|*"Authorization URL"*)
            problems+=("RE-AUTHENTICATION REQUIRED — the cached workspace-cli credentials can no longer be refreshed, so cron reminders are silently dead. Fix: re-run the consent on a desktop against \$WORKSPACE_MCP_URL and copy ~/.workspace-mcp across (see README).") ;;
        *)
            # Sanitised: collapse whitespace, drop anything URL-shaped, cap length.
            detail=$(printf '%s' "$calendars" | tr '\n' ' ' | sed -E 's#[a-z]+://[^ ]*#<url-redacted>#g' | tr -s ' ' | tail -c 300)
            problems+=("list_calendars FAILED (not an auth prompt) — check the server. Tail: ${detail}") ;;
    esac
fi

# --- 3. accounts other than yours -------------------------------------------
# This endpoint is an open OAuth server by design: it has no user allowlist, so
# a stranger who finds the URL can consent with THEIR OWN Google account and
# use the tools against their own data. That is not a path into your calendar,
# but it burns unverified-app grant slots, attributes API traffic to your Google
# Cloud project, and leaves credential files behind. It is also what a
# successful consent-phishing attempt against you would look like.
if creds=$(sudo docker exec "$CONTAINER" sh -c "ls -1 ${CREDS_DIR} 2>/dev/null"); then
    stray=$(printf '%s\n' "$creds" | grep -v -F "$GOOGLE_ACCOUNT_EMAIL" | grep -v '^$' || true)
    if [ -n "$stray" ]; then
        problems+=("UNEXPECTED credential file(s) in ${CREDS_DIR}: $(printf '%s' "$stray" | tr '\n' ' ') — someone else authorised against this endpoint. Delete the file, then consider rotating the OAuth client secret.")
    fi
else
    problems+=("could not list ${CREDS_DIR} in container ${CONTAINER}")
fi

# --- 4. state growth --------------------------------------------------------
if used=$(sudo docker exec "$CONTAINER" sh -c "du -sm ${STATE_DIR} 2>/dev/null | cut -f1"); then
    if [ -n "$used" ] && [ "$used" -gt "$MAX_STATE_MB" ]; then
        problems+=("${STATE_DIR} has grown to ${used} MB (threshold ${MAX_STATE_MB} MB) — likely registration spam. Purge procedure is in the README.")
    fi
else
    problems+=("could not measure ${STATE_DIR} in container ${CONTAINER}")
fi

# --- report -----------------------------------------------------------------
if [ ${#problems[@]} -eq 0 ]; then
    echo "$(date -u +%FT%TZ) workspace-mcp deadman: all checks passed"
    exit 0
fi

msg="workspace-mcp deadman check FAILED on $(hostname -s):"
for p in "${problems[@]}"; do
    msg="${msg}"$'\n'"- ${p}"
done

if [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT:-}" ]; then
    curl -fsS -m 20 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT}" \
        --data-urlencode "text=${msg}" >/dev/null || true
fi

echo "$msg" >&2
exit 1
