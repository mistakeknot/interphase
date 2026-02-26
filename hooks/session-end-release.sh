#!/usr/bin/env bash
# Best-effort bead claim release on clean session exit.
# May not fire on crash — heartbeat TTL (45min) is the fallback.

[[ -n "${CLAVAIN_BEAD_ID:-}" ]] || exit 0
command -v bd &>/dev/null || exit 0

_our_session="${CLAUDE_SESSION_ID:-unknown}"
_claimer=$(bd state "$CLAVAIN_BEAD_ID" claimed_by 2>/dev/null) || _claimer=""

if [[ -z "$_claimer" || "$_claimer" == "(no claimed_by state set)" || "$_claimer" == "$_our_session" ]]; then
    bd update "$CLAVAIN_BEAD_ID" --assignee="" --status=open >/dev/null 2>&1 || true
    bd set-state "$CLAVAIN_BEAD_ID" "claimed_by=" >/dev/null 2>&1 || true
    bd set-state "$CLAVAIN_BEAD_ID" "claimed_at=" >/dev/null 2>&1 || true
fi

# Clean up heartbeat temp file
rm -f "/tmp/clavain-heartbeat-${CLAVAIN_BEAD_ID}-${_our_session}" 2>/dev/null || true

exit 0
