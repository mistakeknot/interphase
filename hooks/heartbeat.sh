#!/usr/bin/env bash
# PostToolUse heartbeat — refresh claim timestamp at most once per 60s
# Uses temp file mtime for throttle (reliable across concurrent hooks)

[[ -n "${CLAVAIN_BEAD_ID:-}" ]] || exit 0
command -v bd &>/dev/null || exit 0

_hb_file="/tmp/clavain-heartbeat-${CLAVAIN_BEAD_ID}-${CLAUDE_SESSION_ID:-unknown}"
_hb_mtime=$(stat -c %Y "$_hb_file" 2>/dev/null || echo 0)
now=$(date +%s)
(( now - _hb_mtime < 60 )) && exit 0

# Touch lockfile atomically, then update claim freshness
touch "$_hb_file" 2>/dev/null || true
bd set-state "$CLAVAIN_BEAD_ID" "claimed_at=$now" >/dev/null 2>&1 || true

exit 0
