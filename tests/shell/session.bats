#!/usr/bin/env bats
# mk-rd9f: interphase hooks key claim state on the session they run in.
#
# Claude Code hands every hook its session_id on stdin and exports
# CLAUDE_CODE_SESSION_ID into the Bash tool. CLAUDE_SESSION_ID exists only after
# clavain's session-start hook wrote it, so a hook keyed on it alone wrote
# claimed_by=unknown in every session whose start hook did not fire — and
# "unknown" is the value the collision check treats as unclaimed. These tests
# run the real hooks with CLAUDE_SESSION_ID unset and prove the claim, the
# marker, the heartbeat and the release are all keyed on the stdin session.

setup() {
    load test_helper
    TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"
    unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAVAIN_BEAD_ID

    # A stub bd that logs every call and keeps set-state values on disk so a
    # later `bd state` reads them back — enough for the claim protocol.
    export STUB_BD_LOG="$TEST_HOME/bd.log"
    export STUB_STATE_DIR="$TEST_HOME/state"
    mkdir -p "$TEST_HOME/bin" "$STUB_STATE_DIR"
    cat > "$TEST_HOME/bin/bd" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_BD_LOG"
case "${1:-}" in
    state)
        f="$STUB_STATE_DIR/$2.$3"
        if [[ -f "$f" ]]; then cat "$f"; else echo "(no $3 state set)"; fi ;;
    set-state)
        kv="$3"; printf '%s\n' "${kv#*=}" > "$STUB_STATE_DIR/$2.${kv%%=*}" ;;
esac
exit 0
EOF
    chmod +x "$TEST_HOME/bin/bd"
    export PATH="$TEST_HOME/bin:$PATH"

    SID="s-test-$$-$RANDOM"
    BEAD="mk-t$RANDOM"
    UNKNOWN_MARKER_BEFORE=0
    if [[ -f /tmp/interphase-bead-unknown ]]; then UNKNOWN_MARKER_BEFORE=1; fi
}

teardown() {
    rm -f "/tmp/interphase-bead-${SID}" "/tmp/clavain-heartbeat-${BEAD}-${SID}"
    rm -rf "$TEST_HOME"
}

# ─── the helper ──────────────────────────────────────────────────────────────

@test "_interphase_session_id: stdin session_id wins over both env registers" {
    source "$HOOKS_DIR/lib-phase.sh"
    export CLAUDE_SESSION_ID=env-start CLAUDE_CODE_SESSION_ID=env-app
    run _interphase_session_id '{"session_id":"stdin-1"}'
    assert_success
    assert_output "stdin-1"
}

@test "_interphase_session_id: CLAUDE_SESSION_ID, then CLAUDE_CODE_SESSION_ID, then the fallback" {
    source "$HOOKS_DIR/lib-phase.sh"
    export CLAUDE_SESSION_ID=env-start CLAUDE_CODE_SESSION_ID=env-app
    run _interphase_session_id ""
    assert_output "env-start"
    unset CLAUDE_SESSION_ID
    run _interphase_session_id ""
    assert_output "env-app"
    unset CLAUDE_CODE_SESSION_ID
    run _interphase_session_id "" "nobody"
    assert_output "nobody"
    run _interphase_session_id
    assert_output "unknown"
}

@test "_interphase_session_id: malformed stdin falls through silently" {
    source "$HOOKS_DIR/lib-phase.sh"
    export CLAUDE_CODE_SESSION_ID=env-app
    run _interphase_session_id 'not json at all'
    assert_success
    assert_output "env-app"
}

# ─── bead-autoclaim: the statusline's claim state ────────────────────────────

@test "bead-autoclaim: claims under the stdin session when the start hook never fired" {
    local payload
    payload="{\"session_id\":\"${SID}\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bd update ${BEAD} --status=in_progress\"},\"tool_result\":{\"exit_code\":0}}"
    run bash -c "printf '%s' '$payload' | bash '$HOOKS_DIR/bead-autoclaim.sh'"
    assert_success
    run cat "$STUB_STATE_DIR/${BEAD}.claimed_by"
    assert_output "$SID"
    [[ -f "/tmp/interphase-bead-${SID}" ]]
    run cat "/tmp/interphase-bead-${SID}"
    assert_output "$BEAD"
    if [[ $UNKNOWN_MARKER_BEFORE -eq 0 ]]; then
        [[ ! -f /tmp/interphase-bead-unknown ]]
    fi
}

@test "bead-autoclaim: a fresh claim by another session is not stomped by a start-hook-less one" {
    printf '%s\n' "s-other" > "$STUB_STATE_DIR/${BEAD}.claimed_by"
    date +%s > "$STUB_STATE_DIR/${BEAD}.claimed_at"
    local payload
    payload="{\"session_id\":\"${SID}\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bd update ${BEAD} --status=in_progress\"},\"tool_result\":{\"exit_code\":0}}"
    run bash -c "printf '%s' '$payload' | bash '$HOOKS_DIR/bead-autoclaim.sh'"
    assert_success
    assert_output --partial "Auto-claim skipped"
    run cat "$STUB_STATE_DIR/${BEAD}.claimed_by"
    assert_output "s-other"
}

# ─── heartbeat and release ───────────────────────────────────────────────────

@test "heartbeat: throttle file and claimed_at refresh are keyed on the stdin session" {
    export CLAVAIN_BEAD_ID="$BEAD"
    run bash -c "printf '%s' '{\"session_id\":\"${SID}\",\"tool_name\":\"Read\"}' | bash '$HOOKS_DIR/heartbeat.sh'"
    assert_success
    [[ -f "/tmp/clavain-heartbeat-${BEAD}-${SID}" ]]
    run grep -c "set-state ${BEAD} claimed_at=" "$STUB_BD_LOG"
    assert_output "1"
}

@test "session-end-release: releases our own claim, found through the marker keyed on the stdin session" {
    echo "$BEAD" > "/tmp/interphase-bead-${SID}"
    printf '%s\n' "$SID" > "$STUB_STATE_DIR/${BEAD}.claimed_by"
    run bash -c "printf '%s' '{\"session_id\":\"${SID}\",\"hook_event_name\":\"SessionEnd\"}' | bash '$HOOKS_DIR/session-end-release.sh'"
    assert_success
    run cat "$STUB_STATE_DIR/${BEAD}.claimed_by"
    assert_output "released"
    [[ ! -f "/tmp/interphase-bead-${SID}" ]]
}

@test "session-end-release: leaves another session's claim alone" {
    echo "$BEAD" > "/tmp/interphase-bead-${SID}"
    printf '%s\n' "s-other" > "$STUB_STATE_DIR/${BEAD}.claimed_by"
    run bash -c "printf '%s' '{\"session_id\":\"${SID}\",\"hook_event_name\":\"SessionEnd\"}' | bash '$HOOKS_DIR/session-end-release.sh'"
    assert_success
    run cat "$STUB_STATE_DIR/${BEAD}.claimed_by"
    assert_output "s-other"
}
