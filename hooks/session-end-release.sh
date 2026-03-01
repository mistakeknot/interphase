#!/usr/bin/env bash
# Best-effort bead claim release on clean session exit.
# May not fire on crash — heartbeat TTL (45min) is the fallback.
#
# Sentinel convention: claimed_by=released, claimed_at=0
# (bd set-state rejects empty values, so we use sentinels instead)

# Discover bead ID: env var (set by route/CLAUDE_ENV_FILE) or marker file (set by autoclaim)
if [[ -z "${CLAVAIN_BEAD_ID:-}" ]]; then
    _marker="/tmp/interphase-bead-${CLAUDE_SESSION_ID:-unknown}"
    [[ -f "$_marker" ]] && CLAVAIN_BEAD_ID=$(cat "$_marker" 2>/dev/null) || true
fi
[[ -n "${CLAVAIN_BEAD_ID:-}" ]] || exit 0
command -v bd &>/dev/null || exit 0

_our_session="${CLAUDE_SESSION_ID:-unknown}"
_claimer=$(bd state "$CLAVAIN_BEAD_ID" claimed_by 2>/dev/null) || _claimer=""

# Release if unclaimed, released, or owned by us
if [[ -z "$_claimer" \
    || "$_claimer" == "(no claimed_by state set)" \
    || "$_claimer" == "released" \
    || "$_claimer" == "$_our_session" ]]; then
    bd update "$CLAVAIN_BEAD_ID" --assignee="" --status=open >/dev/null 2>&1 || true
    bd set-state "$CLAVAIN_BEAD_ID" "claimed_by=released" >/dev/null 2>&1 || true
    bd set-state "$CLAVAIN_BEAD_ID" "claimed_at=0" >/dev/null 2>&1 || true
fi

# Clean up temp files
rm -f "/tmp/clavain-heartbeat-${CLAVAIN_BEAD_ID}-${_our_session}" 2>/dev/null || true
rm -f "/tmp/interphase-bead-${_our_session}" 2>/dev/null || true

exit 0
