#!/usr/bin/env bash
# PostToolUse heartbeat — refresh claim timestamp with adaptive throttle.
# Fires on every tool call; throttle file mtime prevents redundant refreshes.
# Adaptive: active agents heartbeat every 15s (default), idle agents stop naturally
# since PostToolUse only fires when tools are used.
#
# Override throttle: CLAVAIN_HEARTBEAT_INTERVAL=30 (seconds)

# shellcheck source=hooks/lib-phase.sh
source "${BASH_SOURCE[0]%/*}/lib-phase.sh" 2>/dev/null || true
# The session this heartbeat belongs to: the hook payload first, then the env
# registers (mk-rd9f). Keyed on the session so two sessions on one bead do not
# share a throttle file.
_hb_input=""
[[ -t 0 ]] || _hb_input="$(cat 2>/dev/null || true)"
_hb_session="$(_interphase_session_id "$_hb_input" 2>/dev/null)" || _hb_session=""
[[ -n "$_hb_session" ]] || _hb_session="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-unknown}}"

# Discover bead ID: env var (set by route/CLAUDE_ENV_FILE) or marker file (set by autoclaim)
if [[ -z "${CLAVAIN_BEAD_ID:-}" ]]; then
    _marker="/tmp/interphase-bead-${_hb_session}"
    [[ -f "$_marker" ]] && CLAVAIN_BEAD_ID=$(cat "$_marker" 2>/dev/null) || true
fi
[[ -n "${CLAVAIN_BEAD_ID:-}" ]] || exit 0
command -v bd &>/dev/null || exit 0

_hb_interval="${CLAVAIN_HEARTBEAT_INTERVAL:-15}"
_hb_file="/tmp/clavain-heartbeat-${CLAVAIN_BEAD_ID}-${_hb_session}"
_hb_mtime=$(stat -c %Y "$_hb_file" 2>/dev/null || stat -f %m "$_hb_file" 2>/dev/null || echo 0)
now=$(date +%s)
(( now - _hb_mtime < _hb_interval )) && exit 0

# Touch lockfile atomically, then update claim freshness
touch "$_hb_file" 2>/dev/null || true
bd set-state "$CLAVAIN_BEAD_ID" "claimed_at=$now" >/dev/null 2>&1 || true

exit 0
