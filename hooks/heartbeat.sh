#!/usr/bin/env bash
# PostToolUse heartbeat — refresh claim timestamp with adaptive throttle.
# Fires on every tool call; throttle file mtime prevents redundant refreshes.
# Adaptive: active agents heartbeat every 15s (default), idle agents stop naturally
# since PostToolUse only fires when tools are used.
#
# Override throttle: CLAVAIN_HEARTBEAT_INTERVAL=30 (seconds)

# Discover bead ID: env var (set by route/CLAUDE_ENV_FILE) or marker file (set by autoclaim)
if [[ -z "${CLAVAIN_BEAD_ID:-}" ]]; then
    _marker="/tmp/interphase-bead-${CLAUDE_SESSION_ID:-unknown}"
    [[ -f "$_marker" ]] && CLAVAIN_BEAD_ID=$(cat "$_marker" 2>/dev/null) || true
fi
[[ -n "${CLAVAIN_BEAD_ID:-}" ]] || exit 0
command -v bd &>/dev/null || exit 0

_hb_interval="${CLAVAIN_HEARTBEAT_INTERVAL:-15}"
_hb_file="/tmp/clavain-heartbeat-${CLAVAIN_BEAD_ID}-${CLAUDE_SESSION_ID:-unknown}"
_hb_mtime=$(stat -c %Y "$_hb_file" 2>/dev/null || echo 0)
now=$(date +%s)
(( now - _hb_mtime < _hb_interval )) && exit 0

# Touch lockfile atomically, then update claim freshness
touch "$_hb_file" 2>/dev/null || true
bd set-state "$CLAVAIN_BEAD_ID" "claimed_at=$now" >/dev/null 2>&1 || true

exit 0
