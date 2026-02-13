#!/usr/bin/env bats
# Tests for hooks/lib-gates.sh shared gate library

setup() {
    load test_helper

    # Create isolated temp project directory for each test
    TEST_PROJECT="$(mktemp -d)"
    export GATES_PROJECT_DIR="$TEST_PROJECT"
    export HOME="$TEST_PROJECT"

    # Create .beads directory
    mkdir -p "$TEST_PROJECT/.beads"

    # Reset the double-source guards so we can re-source in each test
    unset _GATES_LOADED
    unset _PHASE_LOADED
    source "$HOOKS_DIR/lib-gates.sh"

    # Default mock: bd available, no phase set
    mock_bd_no_phase
}

teardown() {
    rm -rf "$TEST_PROJECT"
}

# ─── Mock helpers ─────────────────────────────────────────────────────

# Mock bd that returns a given phase for `bd state` and succeeds for `bd set-state`
mock_bd_with_phase() {
    local phase="$1"
    export MOCK_BD_PHASE="$phase"
    bd() {
        if [[ "$1" == "state" ]]; then
            echo "$MOCK_BD_PHASE"
            return 0
        fi
        if [[ "$1" == "set-state" ]]; then
            return 0
        fi
        return 1
    }
    export -f bd
}

# Mock bd that returns empty for `bd state`
mock_bd_no_phase() {
    bd() {
        if [[ "$1" == "state" ]]; then
            echo ""
            return 0
        fi
        if [[ "$1" == "set-state" ]]; then
            return 0
        fi
        return 1
    }
    export -f bd
}

# Mock bd that is unavailable
mock_bd_unavailable() {
    unset -f bd 2>/dev/null || true
    local old_path="$PATH"
    export PATH="/nonexistent"
    # Need to re-source since phase_get checks command -v bd
    unset _GATES_LOADED _PHASE_LOADED
    source "$HOOKS_DIR/lib-gates.sh"
    export PATH="$old_path"
}

# ─── Source & init ────────────────────────────────────────────────────

@test "gates: sources without errors" {
    unset _GATES_LOADED _PHASE_LOADED
    run source "$HOOKS_DIR/lib-gates.sh"
    assert_success
}

@test "gates: double-source guard prevents reloading" {
    # _GATES_LOADED is already set from setup()
    [[ -n "$_GATES_LOADED" ]]
    # Source again — should return immediately
    source "$HOOKS_DIR/lib-gates.sh"
    # If we get here, guard worked (no errors from double-source)
    [[ "$_GATES_LOADED" == "1" ]]
}

@test "gates: inherits CLAVAIN_PHASES from lib-phase.sh" {
    [[ ${#CLAVAIN_PHASES[@]} -gt 0 ]]
    [[ "${CLAVAIN_PHASES[0]}" == "brainstorm" ]]
    [[ "${CLAVAIN_PHASES[-1]}" == "done" ]]
}

# ─── VALID_TRANSITIONS ───────────────────────────────────────────────

@test "transitions: array is non-empty" {
    [[ ${#VALID_TRANSITIONS[@]} -gt 0 ]]
}

@test "transitions: contains linear forward transitions" {
    local found_brainstorm_review=false
    local found_plan_execute=false
    local entry
    for entry in "${VALID_TRANSITIONS[@]}"; do
        [[ "$entry" == "brainstorm:brainstorm-reviewed" ]] && found_brainstorm_review=true
        [[ "$entry" == "plan-reviewed:executing" ]] && found_plan_execute=true
    done
    [[ "$found_brainstorm_review" == "true" ]]
    [[ "$found_plan_execute" == "true" ]]
}

@test "transitions: first-touch entry exists" {
    local found=false
    local entry
    for entry in "${VALID_TRANSITIONS[@]}"; do
        [[ "$entry" == ":brainstorm" ]] && found=true
    done
    [[ "$found" == "true" ]]
}

@test "transitions: all CLAVAIN_PHASES are reachable" {
    # Every phase should appear as a 'to' in at least one transition
    local phase
    for phase in "${CLAVAIN_PHASES[@]}"; do
        local found=false
        local entry
        for entry in "${VALID_TRANSITIONS[@]}"; do
            local to="${entry##*:}"
            if [[ "$to" == "$phase" ]]; then
                found=true
                break
            fi
        done
        [[ "$found" == "true" ]]
    done
}

# ─── is_valid_transition ─────────────────────────────────────────────

@test "is_valid_transition: valid forward transition" {
    run is_valid_transition "brainstorm" "brainstorm-reviewed"
    assert_success
}

@test "is_valid_transition: valid skip transition" {
    run is_valid_transition "brainstorm" "strategized"
    assert_success
}

@test "is_valid_transition: first-touch (empty to brainstorm)" {
    run is_valid_transition "" "brainstorm"
    assert_success
}

@test "is_valid_transition: first-touch (empty to executing)" {
    run is_valid_transition "" "executing"
    assert_success
}

@test "is_valid_transition: invalid backward transition" {
    run is_valid_transition "executing" "brainstorm"
    assert_failure
}

@test "is_valid_transition: invalid arbitrary skip" {
    run is_valid_transition "brainstorm" "done"
    assert_failure
}

@test "is_valid_transition: empty target returns failure" {
    run is_valid_transition "brainstorm" ""
    assert_failure
}

# ─── check_phase_gate ────────────────────────────────────────────────

@test "check_phase_gate: passes on valid transition" {
    mock_bd_with_phase "brainstorm"
    run check_phase_gate "Test-001" "brainstorm-reviewed"
    assert_success
}

@test "check_phase_gate: returns 1 on invalid transition" {
    mock_bd_with_phase "executing"
    run check_phase_gate "Test-001" "brainstorm"
    assert_failure
}

@test "check_phase_gate: stderr warning on invalid" {
    mock_bd_with_phase "executing"
    run check_phase_gate "Test-001" "brainstorm"
    assert_output --partial "WARNING: phase gate blocked"
}

@test "check_phase_gate: first-touch passes" {
    mock_bd_no_phase
    run check_phase_gate "Test-001" "brainstorm"
    assert_success
}

@test "check_phase_gate: fail-safe on empty bead_id" {
    run check_phase_gate "" "brainstorm"
    assert_success
}

@test "check_phase_gate: fail-safe on empty target" {
    run check_phase_gate "Test-001" ""
    assert_success
}

# ─── advance_phase ───────────────────────────────────────────────────

@test "advance_phase: calls phase_set (bead persistence)" {
    # Track whether bd set-state was called
    export MOCK_SET_STATE_CALLED=""
    bd() {
        if [[ "$1" == "set-state" ]]; then
            export MOCK_SET_STATE_CALLED="$2:$3"
            return 0
        fi
        return 0
    }
    export -f bd

    advance_phase "Test-001" "brainstorm" "Created brainstorm"
    [[ "$MOCK_SET_STATE_CALLED" == "Test-001:phase=brainstorm" ]]
}

@test "advance_phase: writes artifact header for brainstorms dir" {
    mkdir -p "$TEST_PROJECT/docs/brainstorms"
    local artifact="$TEST_PROJECT/docs/brainstorms/test-brainstorm.md"
    echo "# My Brainstorm" > "$artifact"

    advance_phase "Test-001" "brainstorm" "Created" "$artifact"

    grep -q '^\*\*Phase:\*\*' "$artifact"
    grep -q 'brainstorm' "$artifact"
}

@test "advance_phase: writes artifact header for plans dir" {
    mkdir -p "$TEST_PROJECT/docs/plans"
    local artifact="$TEST_PROJECT/docs/plans/test-plan.md"
    echo "# My Plan" > "$artifact"

    advance_phase "Test-001" "planned" "Planned" "$artifact"

    grep -q '^\*\*Phase:\*\*' "$artifact"
    grep -q 'planned' "$artifact"
}

@test "advance_phase: skips PRD (not in ARTIFACT_PHASE_DIRS)" {
    mkdir -p "$TEST_PROJECT/docs/prds"
    local artifact="$TEST_PROJECT/docs/prds/test-prd.md"
    echo "# My PRD" > "$artifact"

    advance_phase "Test-001" "strategized" "PRD created" "$artifact"

    # PRD should NOT have Phase header
    ! grep -q '^\*\*Phase:\*\*' "$artifact"
}

@test "advance_phase: skips empty artifact path" {
    # Should succeed without errors even with no path
    run advance_phase "Test-001" "executing" "Started execution" ""
    assert_success
}

@test "advance_phase: fail-safe on empty bead_id" {
    run advance_phase "" "brainstorm" "test"
    assert_success
}

# ─── _gate_write_artifact_phase ──────────────────────────────────────

@test "_gate_write_artifact_phase: inserts after Bead line" {
    mkdir -p "$TEST_PROJECT/docs/brainstorms"
    local file="$TEST_PROJECT/docs/brainstorms/test.md"
    cat > "$file" << 'EOF'
# Brainstorm
**Bead:** Test-001
Some content here.
EOF

    _gate_write_artifact_phase "$file" "brainstorm"

    # Phase line should appear after Bead line
    local bead_line phase_line
    bead_line=$(grep -n '^\*\*Bead:\*\*' "$file" | head -1 | cut -d: -f1)
    phase_line=$(grep -n '^\*\*Phase:\*\*' "$file" | head -1 | cut -d: -f1)
    [[ "$phase_line" -eq $((bead_line + 1)) ]]
}

@test "_gate_write_artifact_phase: updates existing Phase line" {
    mkdir -p "$TEST_PROJECT/docs/brainstorms"
    local file="$TEST_PROJECT/docs/brainstorms/test.md"
    cat > "$file" << 'EOF'
# Brainstorm
**Bead:** Test-001
**Phase:** brainstorm (as of 2026-01-01T00:00:00Z)
Some content here.
EOF

    _gate_write_artifact_phase "$file" "brainstorm-reviewed"

    # Should have only one Phase line, updated to new value
    local count
    count=$(grep -c '^\*\*Phase:\*\*' "$file")
    [[ "$count" -eq 1 ]]
    grep -q 'brainstorm-reviewed' "$file"
    ! grep -q 'Phase:\*\* brainstorm ' "$file"
}

@test "_gate_write_artifact_phase: inserts after heading when no Bead line" {
    mkdir -p "$TEST_PROJECT/docs/plans"
    local file="$TEST_PROJECT/docs/plans/test.md"
    cat > "$file" << 'EOF'
# My Plan
Some content here.
EOF

    _gate_write_artifact_phase "$file" "planned"

    grep -q '^\*\*Phase:\*\*' "$file"
    # Phase line should be after heading
    local heading_line phase_line
    heading_line=$(grep -n '^# ' "$file" | head -1 | cut -d: -f1)
    phase_line=$(grep -n '^\*\*Phase:\*\*' "$file" | head -1 | cut -d: -f1)
    [[ "$phase_line" -eq $((heading_line + 1)) ]]
}

@test "_gate_write_artifact_phase: skips file outside allowed dirs" {
    mkdir -p "$TEST_PROJECT/docs/prds"
    local file="$TEST_PROJECT/docs/prds/test.md"
    echo "# PRD" > "$file"

    _gate_write_artifact_phase "$file" "strategized"

    ! grep -q '^\*\*Phase:\*\*' "$file"
}

@test "_gate_write_artifact_phase: includes timestamp" {
    mkdir -p "$TEST_PROJECT/docs/brainstorms"
    local file="$TEST_PROJECT/docs/brainstorms/test.md"
    echo "# Brainstorm" > "$file"

    _gate_write_artifact_phase "$file" "brainstorm"

    grep -q 'as of' "$file"
}

@test "_gate_write_artifact_phase: silent on missing file" {
    run _gate_write_artifact_phase "/nonexistent/file.md" "brainstorm"
    assert_success
}

# ─── _gate_read_artifact_phase ───────────────────────────────────────

@test "_gate_read_artifact_phase: extracts phase value" {
    mkdir -p "$TEST_PROJECT/docs/brainstorms"
    local file="$TEST_PROJECT/docs/brainstorms/test.md"
    cat > "$file" << 'EOF'
# Brainstorm
**Bead:** Test-001
**Phase:** brainstorm-reviewed (as of 2026-02-12T10:00:00Z)
Content.
EOF

    run _gate_read_artifact_phase "$file"
    assert_success
    assert_output "brainstorm-reviewed"
}

@test "_gate_read_artifact_phase: empty when no Phase header" {
    local file="$TEST_PROJECT/test.md"
    echo "# No phase" > "$file"

    run _gate_read_artifact_phase "$file"
    assert_success
    assert_output ""
}

@test "_gate_read_artifact_phase: strips timestamp" {
    local file="$TEST_PROJECT/test.md"
    echo '**Phase:** executing (as of 2026-02-12T10:00:00Z)' > "$file"

    run _gate_read_artifact_phase "$file"
    assert_success
    assert_output "executing"
}

@test "_gate_read_artifact_phase: empty for missing file" {
    run _gate_read_artifact_phase "/nonexistent/file.md"
    assert_success
    assert_output ""
}

# ─── phase_get_with_fallback ─────────────────────────────────────────

@test "phase_get_with_fallback: returns beads phase when available" {
    mock_bd_with_phase "planned"
    run phase_get_with_fallback "Test-001"
    assert_success
    assert_output "planned"
}

@test "phase_get_with_fallback: falls back to artifact" {
    mock_bd_no_phase
    mkdir -p "$TEST_PROJECT/docs/brainstorms"
    local file="$TEST_PROJECT/docs/brainstorms/test.md"
    echo '**Phase:** brainstorm (as of 2026-02-12T00:00:00Z)' > "$file"

    run phase_get_with_fallback "Test-001" "$file"
    assert_success
    assert_output "brainstorm"
}

@test "phase_get_with_fallback: warns on desync" {
    mock_bd_with_phase "executing"
    mkdir -p "$TEST_PROJECT/docs/plans"
    local file="$TEST_PROJECT/docs/plans/test.md"
    echo '**Phase:** planned (as of 2026-02-12T00:00:00Z)' > "$file"

    run phase_get_with_fallback "Test-001" "$file"
    assert_success
    # Should return beads phase (primary)
    [[ "${lines[0]}" == *"WARNING: phase desync"* || "${lines[-1]}" == "executing" ]]
    assert_output --partial "executing"
}

@test "phase_get_with_fallback: empty when both fail" {
    mock_bd_no_phase
    run phase_get_with_fallback "Test-001" "/nonexistent.md"
    assert_success
    assert_output ""
}

# ─── Telemetry ────────────────────────────────────────────────────────

@test "telemetry: gate_check event is valid JSONL" {
    _gate_log_check "Test-001" "brainstorm" "brainstorm-reviewed" "pass"

    local file="$TEST_PROJECT/.clavain/telemetry.jsonl"
    [[ -f "$file" ]]
    local line
    line=$(cat "$file")
    echo "$line" | jq empty  # Validate JSON
    [[ $(echo "$line" | jq -r '.event') == "gate_check" ]]
    [[ $(echo "$line" | jq -r '.bead') == "Test-001" ]]
    [[ $(echo "$line" | jq -r '.result') == "pass" ]]
}

@test "telemetry: phase_advance event is valid JSONL" {
    _gate_log_advance "Test-001" "planned" "Plan written" "docs/plans/test.md"

    local file="$TEST_PROJECT/.clavain/telemetry.jsonl"
    [[ -f "$file" ]]
    local line
    line=$(cat "$file")
    echo "$line" | jq empty
    [[ $(echo "$line" | jq -r '.event') == "phase_advance" ]]
    [[ $(echo "$line" | jq -r '.phase') == "planned" ]]
    [[ $(echo "$line" | jq -r '.artifact') == "docs/plans/test.md" ]]
}

# ─── _gate_update_statusline ─────────────────────────────────────────

@test "_gate_update_statusline: writes state file when CLAUDE_SESSION_ID is set" {
    export CLAUDE_SESSION_ID="test-session-abc"
    _gate_update_statusline "Clavain-021h" "planned" "Plan: docs/plans/test.md"

    local state_file="/tmp/clavain-bead-test-session-abc.json"
    [[ -f "$state_file" ]]
    # Validate JSON structure
    jq empty "$state_file"
    [[ $(jq -r '.id' "$state_file") == "Clavain-021h" ]]
    [[ $(jq -r '.phase' "$state_file") == "planned" ]]
    [[ $(jq -r '.reason' "$state_file") == "Plan: docs/plans/test.md" ]]
    [[ $(jq -r '.ts' "$state_file") =~ ^[0-9]+$ ]]

    rm -f "$state_file"
}

@test "_gate_update_statusline: skips silently when CLAUDE_SESSION_ID is unset" {
    unset CLAUDE_SESSION_ID
    run _gate_update_statusline "Clavain-021h" "planned" "reason"
    assert_success
    # No file should exist with empty session id
    [[ ! -f "/tmp/clavain-bead-.json" ]]
}

@test "_gate_update_statusline: overwrites on phase change" {
    export CLAUDE_SESSION_ID="test-session-overwrite"
    _gate_update_statusline "Clavain-021h" "planned" "Plan created"
    _gate_update_statusline "Clavain-021h" "executing" "Started work"

    local state_file="/tmp/clavain-bead-test-session-overwrite.json"
    [[ $(jq -r '.phase' "$state_file") == "executing" ]]

    rm -f "$state_file"
}

@test "advance_phase: writes statusline state file" {
    export CLAUDE_SESSION_ID="test-session-advance"
    advance_phase "Test-001" "brainstorm" "Created brainstorm"

    local state_file="/tmp/clavain-bead-test-session-advance.json"
    [[ -f "$state_file" ]]
    [[ $(jq -r '.id' "$state_file") == "Test-001" ]]
    [[ $(jq -r '.phase' "$state_file") == "brainstorm" ]]

    rm -f "$state_file"
}

# ─── Telemetry ────────────────────────────────────────────────────────

@test "telemetry: phase_desync event is valid JSONL" {
    _gate_log_desync "Test-001" "executing" "planned" "docs/plans/test.md"

    local file="$TEST_PROJECT/.clavain/telemetry.jsonl"
    [[ -f "$file" ]]
    local line
    line=$(cat "$file")
    echo "$line" | jq empty
    [[ $(echo "$line" | jq -r '.event') == "phase_desync" ]]
    [[ $(echo "$line" | jq -r '.bead_phase') == "executing" ]]
    [[ $(echo "$line" | jq -r '.artifact_phase') == "planned" ]]
}

# ─── Enforcement Mock Helpers ──────────────────────────────────────

# Mock bd that returns a given phase AND priority for enforcement testing
mock_bd_enforce() {
    local phase="$1"
    local priority="${2:-2}"
    export MOCK_BD_PHASE="$phase"
    export MOCK_BD_PRIORITY="$priority"
    export MOCK_BD_NOTES=""
    bd() {
        case "$1" in
            state)
                echo "$MOCK_BD_PHASE"
                return 0
                ;;
            set-state)
                return 0
                ;;
            show)
                if [[ "$*" == *"--json"* ]]; then
                    echo "{\"id\":\"$2\",\"priority\":$MOCK_BD_PRIORITY,\"status\":\"open\"}"
                fi
                return 0
                ;;
            update)
                if [[ "$*" == *"--append-notes"* ]]; then
                    # Capture the notes argument
                    shift 2  # skip 'update <id>'
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --append-notes) export MOCK_BD_NOTES="$2"; shift 2 ;;
                            *) shift ;;
                        esac
                    done
                fi
                return 0
                ;;
        esac
        return 1
    }
    export -f bd
}

# ─── Phase Cycling (H1) ──────────────────────────────────────────────

@test "transitions: shipping to planned is valid (phase cycling)" {
    run is_valid_transition "shipping" "planned"
    assert_success
}

@test "transitions: shipping to brainstorm is valid (phase cycling)" {
    run is_valid_transition "shipping" "brainstorm"
    assert_success
}

@test "transitions: done to brainstorm is valid (new iteration)" {
    run is_valid_transition "done" "brainstorm"
    assert_success
}

@test "transitions: done to planned is valid (follow-up work)" {
    run is_valid_transition "done" "planned"
    assert_success
}

# ─── get_enforcement_tier ────────────────────────────────────────────

@test "get_enforcement_tier: P0 returns hard" {
    mock_bd_enforce "brainstorm" 0
    run get_enforcement_tier "Test-001"
    assert_success
    assert_output "hard"
}

@test "get_enforcement_tier: P1 returns hard" {
    mock_bd_enforce "brainstorm" 1
    run get_enforcement_tier "Test-001"
    assert_success
    assert_output "hard"
}

@test "get_enforcement_tier: P2 returns soft" {
    mock_bd_enforce "brainstorm" 2
    run get_enforcement_tier "Test-001"
    assert_success
    assert_output "soft"
}

@test "get_enforcement_tier: P3 returns soft" {
    mock_bd_enforce "brainstorm" 3
    run get_enforcement_tier "Test-001"
    assert_success
    assert_output "soft"
}

@test "get_enforcement_tier: P4 returns none" {
    mock_bd_enforce "brainstorm" 4
    run get_enforcement_tier "Test-001"
    assert_success
    assert_output "none"
}

@test "get_enforcement_tier: empty bead_id returns none" {
    run get_enforcement_tier ""
    assert_success
    assert_output "none"
}

@test "get_enforcement_tier: bd unavailable returns none" {
    # Mock bd to always fail (simulates unavailable)
    bd() { return 127; }
    export -f bd
    run get_enforcement_tier "Test-001"
    assert_success
    assert_output "none"
}

# ─── enforce_gate ────────────────────────────────────────────────────

@test "enforce_gate: valid transition passes for hard tier" {
    mock_bd_enforce "brainstorm" 0
    run enforce_gate "Test-001" "brainstorm-reviewed"
    assert_success
}

@test "enforce_gate: invalid transition blocks for hard tier (P0)" {
    mock_bd_enforce "brainstorm" 0
    run enforce_gate "Test-001" "shipping"
    assert_failure
    assert_output --partial "ERROR: phase gate blocked"
}

@test "enforce_gate: invalid transition blocks for hard tier (P1)" {
    mock_bd_enforce "brainstorm" 1
    run enforce_gate "Test-001" "shipping"
    assert_failure
    assert_output --partial "ERROR: phase gate blocked"
}

@test "enforce_gate: invalid transition warns for soft tier (P2)" {
    mock_bd_enforce "brainstorm" 2
    run enforce_gate "Test-001" "shipping"
    assert_success
    assert_output --partial "WARNING: phase gate would block"
}

@test "enforce_gate: invalid transition warns for soft tier (P3)" {
    mock_bd_enforce "brainstorm" 3
    run enforce_gate "Test-001" "shipping"
    assert_success
    assert_output --partial "WARNING: phase gate would block"
}

@test "enforce_gate: no gate for P4" {
    mock_bd_enforce "brainstorm" 4
    run enforce_gate "Test-001" "shipping"
    assert_success
    # No warning for P4
    refute_output --partial "WARNING"
    refute_output --partial "ERROR"
}

@test "enforce_gate: CLAVAIN_SKIP_GATE overrides hard block" {
    mock_bd_enforce "brainstorm" 0
    export CLAVAIN_SKIP_GATE="Emergency hotfix"
    run enforce_gate "Test-001" "shipping"
    assert_success
    unset CLAVAIN_SKIP_GATE
}

@test "enforce_gate: CLAVAIN_SKIP_GATE records in bead notes" {
    mock_bd_enforce "brainstorm" 0
    export CLAVAIN_SKIP_GATE="Emergency hotfix"
    enforce_gate "Test-001" "shipping" 2>/dev/null
    [[ "$MOCK_BD_NOTES" == *"Gate skipped"* ]]
    [[ "$MOCK_BD_NOTES" == *"Emergency hotfix"* ]]
    unset CLAVAIN_SKIP_GATE
}

@test "enforce_gate: CLAVAIN_DISABLE_GATES bypasses all enforcement" {
    mock_bd_enforce "brainstorm" 0
    export CLAVAIN_DISABLE_GATES=true
    run enforce_gate "Test-001" "shipping"
    assert_success
    assert_output --partial "WARNING: gate enforcement DISABLED"
    unset CLAVAIN_DISABLE_GATES
}

@test "enforce_gate: fail-safe on empty bead_id" {
    run enforce_gate "" "brainstorm"
    assert_success
}

@test "enforce_gate: fail-safe on empty target" {
    run enforce_gate "Test-001" ""
    assert_success
}

@test "enforce_gate: fail-safe when bd unavailable" {
    # Mock bd to always fail (simulates unavailable)
    bd() { return 127; }
    export -f bd
    run enforce_gate "Test-001" "brainstorm"
    assert_success
}

# ─── enforce_gate: telemetry ─────────────────────────────────────────

@test "enforce_gate: logs enforcement decision to telemetry" {
    mock_bd_enforce "brainstorm" 0
    enforce_gate "Test-001" "brainstorm-reviewed" 2>/dev/null

    local file="$TEST_PROJECT/.clavain/telemetry.jsonl"
    [[ -f "$file" ]]
    # Find the gate_enforce event (skip gate_check events)
    local enforce_line
    enforce_line=$(grep '"gate_enforce"' "$file" | tail -1)
    echo "$enforce_line" | jq empty
    [[ $(echo "$enforce_line" | jq -r '.event') == "gate_enforce" ]]
    [[ $(echo "$enforce_line" | jq -r '.decision') == "pass" ]]
}

@test "enforce_gate: logs block decision to telemetry" {
    mock_bd_enforce "brainstorm" 0
    enforce_gate "Test-001" "shipping" 2>/dev/null || true

    local file="$TEST_PROJECT/.clavain/telemetry.jsonl"
    local enforce_line
    enforce_line=$(grep '"gate_enforce"' "$file" | tail -1)
    [[ $(echo "$enforce_line" | jq -r '.decision') == "block" ]]
}

@test "enforce_gate: logs skip decision to telemetry" {
    mock_bd_enforce "brainstorm" 0
    export CLAVAIN_SKIP_GATE="test skip"
    enforce_gate "Test-001" "shipping" 2>/dev/null
    unset CLAVAIN_SKIP_GATE

    local file="$TEST_PROJECT/.clavain/telemetry.jsonl"
    local enforce_line
    enforce_line=$(grep '"gate_enforce"' "$file" | tail -1)
    [[ $(echo "$enforce_line" | jq -r '.decision') == "skip" ]]
    [[ $(echo "$enforce_line" | jq -r '.reason') == "test skip" ]]
}

# ─── check_review_staleness ─────────────────────────────────────────

@test "check_review_staleness: returns none when no review dir" {
    run check_review_staleness "Test-001" "docs/plans/test.md"
    assert_success
    assert_output "none"
}

@test "check_review_staleness: returns none when no findings.json" {
    mkdir -p "$TEST_PROJECT/docs/research/flux-drive/test"
    run check_review_staleness "Test-001" "docs/plans/test.md"
    assert_success
    assert_output "none"
}

@test "check_review_staleness: returns fresh when artifact not modified" {
    # Create a review that references our bead
    mkdir -p "$TEST_PROJECT/docs/research/flux-drive/test-review"
    local future_date
    future_date=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+1H +%Y-%m-%dT%H:%M:%SZ)
    echo "{\"bead_id\":\"Test-001\",\"reviewed\":\"$future_date\",\"input\":\"docs/plans/test.md\"}" \
        > "$TEST_PROJECT/docs/research/flux-drive/test-review/findings.json"

    # Create the artifact
    mkdir -p "$TEST_PROJECT/docs/plans"
    echo "# Plan" > "$TEST_PROJECT/docs/plans/test.md"

    # Init git repo for git log check
    cd "$TEST_PROJECT"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    git add -A && git commit -q -m "init"

    run check_review_staleness "Test-001" "docs/plans/test.md"
    assert_success
    assert_output "fresh"
}

@test "check_review_staleness: returns stale when artifact modified after review" {
    # Create a review with a past date
    mkdir -p "$TEST_PROJECT/docs/research/flux-drive/test-review"
    echo '{"bead_id":"Test-001","reviewed":"2026-02-10T10:00:00Z","input":"docs/plans/test.md"}' \
        > "$TEST_PROJECT/docs/research/flux-drive/test-review/findings.json"

    # Create and commit the artifact after the review date
    mkdir -p "$TEST_PROJECT/docs/plans"
    echo "# Plan" > "$TEST_PROJECT/docs/plans/test.md"
    cd "$TEST_PROJECT"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    git add -A && git commit -q -m "init" --date="2026-02-11T10:00:00Z"

    run check_review_staleness "Test-001" "docs/plans/test.md"
    assert_success
    assert_output "stale"
}

@test "check_review_staleness: returns unknown when reviewed date missing" {
    mkdir -p "$TEST_PROJECT/docs/research/flux-drive/test-review"
    echo '{"bead_id":"Test-001","input":"docs/plans/test.md"}' \
        > "$TEST_PROJECT/docs/research/flux-drive/test-review/findings.json"

    run check_review_staleness "Test-001" "docs/plans/test.md"
    assert_success
    assert_output "unknown"
}

@test "check_review_staleness: returns none with empty artifact_path" {
    run check_review_staleness "Test-001" ""
    assert_success
    assert_output "none"
}

@test "check_review_staleness: matches by bead_id not stem" {
    # Review dir has a different name than the artifact
    mkdir -p "$TEST_PROJECT/docs/research/flux-drive/totally-different-name"
    local future_date
    future_date=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+1H +%Y-%m-%dT%H:%M:%SZ)
    echo "{\"bead_id\":\"Test-001\",\"reviewed\":\"$future_date\",\"input\":\"docs/plans/old-name.md\"}" \
        > "$TEST_PROJECT/docs/research/flux-drive/totally-different-name/findings.json"

    mkdir -p "$TEST_PROJECT/docs/plans"
    echo "# Plan" > "$TEST_PROJECT/docs/plans/renamed-plan.md"
    cd "$TEST_PROJECT"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    git add -A && git commit -q -m "init"

    # Should find the review by bead_id even though artifact name doesn't match
    run check_review_staleness "Test-001" "docs/plans/renamed-plan.md"
    assert_success
    assert_output "fresh"
}
