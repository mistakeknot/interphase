#!/usr/bin/env bats
# Tests for hooks/lib-discovery.sh work discovery scanner

setup() {
    load test_helper

    # Create isolated temp project directory for each test
    TEST_PROJECT="$(mktemp -d)"
    export DISCOVERY_PROJECT_DIR="$TEST_PROJECT"

    # Create .beads directory (required for scanner to proceed)
    mkdir -p "$TEST_PROJECT/.beads"

    # Reset the double-source guards so we can re-source in each test
    unset _DISCOVERY_LOADED
    unset _PHASE_LOADED
    source "$HOOKS_DIR/lib-discovery.sh"
}

teardown() {
    rm -rf "$TEST_PROJECT"
}

# ─── Mock helpers ─────────────────────────────────────────────────────

# Create a mock bd command that returns given JSON for --status=open
# and empty array for --status=in_progress (unless MOCK_BD_IP_JSON is set)
mock_bd() {
    local json="$1"
    export MOCK_BD_JSON="$json"
    export MOCK_BD_IP_JSON="${2:-[]}"
    bd() {
        if [[ "$1" == "list" ]]; then
            if [[ "$*" == *"--status=in_progress"* ]]; then
                echo "$MOCK_BD_IP_JSON"
            else
                echo "$MOCK_BD_JSON"
            fi
            return 0
        fi
        return 1
    }
    export -f bd
}

# Create a mock bd that fails
mock_bd_error() {
    bd() { return 1; }
    export -f bd
}

# Create a mock bd that returns invalid JSON
mock_bd_garbage() {
    bd() {
        echo "Error: database locked"
        return 0
    }
    export -f bd
}

# ─── discovery_scan_beads: bd not available ───────────────────────────

@test "discovery: outputs DISCOVERY_UNAVAILABLE when bd not installed" {
    # Hide bd from PATH
    bd() { return 127; }
    unset -f bd
    # Temporarily remove bd from PATH
    local old_path="$PATH"
    PATH="/nonexistent"
    unset _DISCOVERY_LOADED
    source "$HOOKS_DIR/lib-discovery.sh"
    run discovery_scan_beads
    PATH="$old_path"
    assert_success
    assert_output "DISCOVERY_UNAVAILABLE"
}

@test "discovery: outputs DISCOVERY_UNAVAILABLE when .beads dir missing" {
    rmdir "$TEST_PROJECT/.beads"
    mock_bd '[]'
    run discovery_scan_beads
    assert_success
    assert_output "DISCOVERY_UNAVAILABLE"
}

# ─── discovery_scan_beads: bd error handling ──────────────────────────

@test "discovery: outputs DISCOVERY_ERROR when bd fails" {
    mock_bd_error
    run discovery_scan_beads
    assert_success
    assert_output "DISCOVERY_ERROR"
}

@test "discovery: outputs DISCOVERY_ERROR when bd returns invalid JSON" {
    mock_bd_garbage
    run discovery_scan_beads
    assert_success
    assert_output "DISCOVERY_ERROR"
}

# ─── discovery_scan_beads: empty results ──────────────────────────────

@test "discovery: outputs empty array when no open beads" {
    mock_bd '[]'
    run discovery_scan_beads
    assert_success
    assert_output "[]"
}

# ─── discovery_scan_beads: JSON output format ─────────────────────────

@test "discovery: outputs valid JSON with required fields" {
    mock_bd '[{"id":"Test-abc1","title":"Fix auth","status":"open","priority":1,"updated_at":"2026-02-12T10:00:00Z"}]'
    run discovery_scan_beads
    assert_success

    # Verify it's valid JSON
    echo "$output" | jq empty

    # Verify required fields exist
    local id title priority status action plan_path stale
    id=$(echo "$output" | jq -r '.[0].id')
    title=$(echo "$output" | jq -r '.[0].title')
    priority=$(echo "$output" | jq '.[0].priority')
    status=$(echo "$output" | jq -r '.[0].status')
    action=$(echo "$output" | jq -r '.[0].action')
    plan_path=$(echo "$output" | jq -r '.[0].plan_path')
    stale=$(echo "$output" | jq '.[0].stale')

    [[ "$id" == "Test-abc1" ]]
    [[ "$title" == "Fix auth" ]]
    [[ "$priority" == "1" ]]
    [[ "$status" == "open" ]]
    [[ -n "$action" ]]
    [[ "$stale" == "true" || "$stale" == "false" ]]

    # F8: verify phase and score fields exist
    local phase score
    phase=$(echo "$output" | jq -r '.[0].phase')
    score=$(echo "$output" | jq '.[0].score')
    [[ "$score" -gt 0 ]]
    # phase may be empty string (no phase set)
    [[ "$phase" == "" || "$phase" == "null" || -n "$phase" ]]
}

# ─── discovery_scan_beads: sorting ────────────────────────────────────

@test "discovery: sorts by multi-factor score (priority dominant)" {
    # All timestamps within 24h (same recency bucket, no staleness) so priority dominates
    local recent_iso
    recent_iso=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)

    mock_bd "[
        {\"id\":\"Test-low\",\"title\":\"Low priority\",\"status\":\"open\",\"priority\":3,\"updated_at\":\"${recent_iso}\"},
        {\"id\":\"Test-high\",\"title\":\"High priority\",\"status\":\"open\",\"priority\":1,\"updated_at\":\"${recent_iso}\"},
        {\"id\":\"Test-mid\",\"title\":\"Med priority\",\"status\":\"open\",\"priority\":2,\"updated_at\":\"${recent_iso}\"}
    ]"
    run discovery_scan_beads
    assert_success

    # Priority dominates when recency is equal: P1 (68) > P2 (56) > P3 (44)
    local first_id second_id third_id
    first_id=$(echo "$output" | jq -r '.[0].id')
    second_id=$(echo "$output" | jq -r '.[1].id')
    third_id=$(echo "$output" | jq -r '.[2].id')

    [[ "$first_id" == "Test-high" ]]
    [[ "$second_id" == "Test-mid" ]]
    [[ "$third_id" == "Test-low" ]]

    # Verify score field exists and is positive
    local first_score
    first_score=$(echo "$output" | jq '.[0].score')
    [[ "$first_score" -gt 0 ]]
}

# ─── discovery_scan_beads: skips invalid beads ────────────────────────

@test "discovery: skips beads with missing id" {
    mock_bd '[
        {"title":"No ID","status":"open","priority":1,"updated_at":"2026-02-12T10:00:00Z"},
        {"id":"Test-ok","title":"Has ID","status":"open","priority":2,"updated_at":"2026-02-12T10:00:00Z"}
    ]'
    run discovery_scan_beads
    assert_success

    local count
    count=$(echo "$output" | jq 'length')
    [[ "$count" == "1" ]]
    [[ $(echo "$output" | jq -r '.[0].id') == "Test-ok" ]]
}

# ─── infer_bead_action: state-based inference ─────────────────────────

@test "infer_bead_action: in_progress returns continue" {
    run infer_bead_action "Test-abc1" "in_progress"
    assert_success
    [[ "$output" == "continue|"* ]]
}

@test "infer_bead_action: open with plan returns execute" {
    mkdir -p "$TEST_PROJECT/docs/plans"
    echo "**Bead:** Test-abc1 (Feature)" > "$TEST_PROJECT/docs/plans/test-plan.md"

    run infer_bead_action "Test-abc1" "open"
    assert_success
    [[ "$output" == "execute|"* ]]
    [[ "$output" == *"test-plan.md"* ]]
}

@test "infer_bead_action: open with PRD but no plan returns plan" {
    mkdir -p "$TEST_PROJECT/docs/prds"
    echo "**Bead:** Test-abc1" > "$TEST_PROJECT/docs/prds/test-prd.md"

    run infer_bead_action "Test-abc1" "open"
    assert_success
    [[ "$output" == "plan|"* ]]
}

@test "infer_bead_action: open with brainstorm but no PRD returns strategize" {
    mkdir -p "$TEST_PROJECT/docs/brainstorms"
    echo "**Bead:** Test-abc1" > "$TEST_PROJECT/docs/brainstorms/test-brainstorm.md"

    run infer_bead_action "Test-abc1" "open"
    assert_success
    [[ "$output" == "strategize|"* ]]
}

@test "infer_bead_action: open with nothing returns brainstorm" {
    run infer_bead_action "Test-abc1" "open"
    assert_success
    assert_output "brainstorm|"
}

# ─── infer_bead_action: word-boundary matching ───────────────────────

@test "infer_bead_action: does not match substring of longer bead ID" {
    mkdir -p "$TEST_PROJECT/docs/plans"
    # Plan references "Test-abc12" (longer ID) — should NOT match "Test-abc1"
    echo "**Bead:** Test-abc12 (Feature)" > "$TEST_PROJECT/docs/plans/other-plan.md"

    run infer_bead_action "Test-abc1" "open"
    assert_success
    # Should return brainstorm (no match), not execute
    assert_output "brainstorm|"
}

@test "infer_bead_action: matches exact bead ID among others" {
    mkdir -p "$TEST_PROJECT/docs/plans"
    # Plan references multiple beads on same line
    echo "**Bead:** Test-abc1 (F1), Test-abc2 (F2)" > "$TEST_PROJECT/docs/plans/multi-plan.md"

    run infer_bead_action "Test-abc1" "open"
    assert_success
    [[ "$output" == "execute|"* ]]
    [[ "$output" == *"multi-plan.md"* ]]
}

# ─── discovery_log_selection: safe telemetry ──────────────────────────

@test "discovery_log_selection: writes valid JSONL" {
    export HOME="$TEST_PROJECT"
    run discovery_log_selection "Test-abc1" "execute" "true"
    assert_success

    # Verify file exists and contains valid JSON
    local line
    line=$(cat "$TEST_PROJECT/.clavain/telemetry.jsonl")
    echo "$line" | jq empty  # Will fail if not valid JSON

    [[ $(echo "$line" | jq -r '.event') == "discovery_select" ]]
    [[ $(echo "$line" | jq -r '.bead') == "Test-abc1" ]]
    [[ $(echo "$line" | jq -r '.action') == "execute" ]]
    [[ $(echo "$line" | jq '.recommended') == "true" ]]
}

@test "discovery_log_selection: handles special characters safely" {
    export HOME="$TEST_PROJECT"
    # Bead ID with characters that could cause printf injection
    run discovery_log_selection 'Test-%s%n"injection' "plan" "false"
    assert_success

    local line
    line=$(cat "$TEST_PROJECT/.clavain/telemetry.jsonl")
    echo "$line" | jq empty  # Must still be valid JSON

    # The special characters should be properly escaped in JSON
    [[ $(echo "$line" | jq -r '.bead') == 'Test-%s%n"injection' ]]
}

# ─── staleness ────────────────────────────────────────────────────────

@test "discovery: merges open and in_progress beads" {
    local open_json='[{"id":"Test-open1","title":"Open bead","status":"open","priority":2,"updated_at":"2026-02-12T10:00:00Z"}]'
    local ip_json='[{"id":"Test-ip1","title":"In progress","status":"in_progress","priority":1,"updated_at":"2026-02-12T11:00:00Z"}]'

    mock_bd "$open_json" "$ip_json"
    run discovery_scan_beads
    assert_success

    local count
    count=$(echo "$output" | jq 'length')
    [[ "$count" == "2" ]]

    # in_progress (P1) should sort before open (P2)
    [[ $(echo "$output" | jq -r '.[0].id') == "Test-ip1" ]]
    [[ $(echo "$output" | jq -r '.[1].id') == "Test-open1" ]]
}

@test "discovery: action priority — plan beats PRD beats brainstorm" {
    # Create all three artifact types for same bead
    mkdir -p "$TEST_PROJECT/docs/plans" "$TEST_PROJECT/docs/prds" "$TEST_PROJECT/docs/brainstorms"
    echo "**Bead:** Test-all1" > "$TEST_PROJECT/docs/plans/test-plan.md"
    echo "**Bead:** Test-all1" > "$TEST_PROJECT/docs/prds/test-prd.md"
    echo "**Bead:** Test-all1" > "$TEST_PROJECT/docs/brainstorms/test-brainstorm.md"

    mock_bd '[{"id":"Test-all1","title":"Has everything","status":"open","priority":1,"updated_at":"2026-02-12T10:00:00Z"}]'
    run discovery_scan_beads
    assert_success

    # Plan should win over PRD and brainstorm
    [[ $(echo "$output" | jq -r '.[0].action') == "execute" ]]
    [[ $(echo "$output" | jq -r '.[0].plan_path') == *"test-plan.md"* ]]
}

@test "discovery: marks bead as stale when plan file is old" {
    mkdir -p "$TEST_PROJECT/docs/plans"
    echo "**Bead:** Test-stale1" > "$TEST_PROJECT/docs/plans/old-plan.md"
    # Set mtime to 5 days ago using relative date
    local five_days_ago
    five_days_ago=$(date -d '5 days ago' +%Y%m%d%H%M 2>/dev/null || date -v-5d +%Y%m%d%H%M)
    touch -t "$five_days_ago" "$TEST_PROJECT/docs/plans/old-plan.md"

    mock_bd '[{"id":"Test-stale1","title":"Stale work","status":"open","priority":2,"updated_at":"2026-02-07T00:00:00Z"}]'
    run discovery_scan_beads
    assert_success

    [[ $(echo "$output" | jq '.[0].stale') == "true" ]]
}

@test "discovery: marks bead as not stale when plan file is recent" {
    mkdir -p "$TEST_PROJECT/docs/plans"
    echo "**Bead:** Test-fresh1" > "$TEST_PROJECT/docs/plans/fresh-plan.md"
    # mtime is now (just created) — not stale

    mock_bd '[{"id":"Test-fresh1","title":"Fresh work","status":"open","priority":2,"updated_at":"2026-02-12T10:00:00Z"}]'
    run discovery_scan_beads
    assert_success

    [[ $(echo "$output" | jq '.[0].stale') == "false" ]]
}

# ─── discovery_scan_orphans: detection ───────────────────────────────

@test "orphans: detects unlinked artifact (no bead header)" {
    mkdir -p "$TEST_PROJECT/docs/brainstorms"
    cat > "$TEST_PROJECT/docs/brainstorms/my-idea.md" <<'MDEOF'
# My Great Idea

Some brainstorm content without any bead reference.
MDEOF

    # Mock bd so bd show always fails (no beads exist)
    bd() { return 1; }
    export -f bd

    run discovery_scan_orphans
    assert_success

    local count
    count=$(echo "$output" | jq 'length')
    [[ "$count" == "1" ]]
    [[ $(echo "$output" | jq -r '.[0].type') == "brainstorm" ]]
    [[ $(echo "$output" | jq -r '.[0].title') == "My Great Idea" ]]
    [[ $(echo "$output" | jq -r '.[0].bead_id') == "" ]]
}

@test "orphans: detects artifact with deleted bead" {
    mkdir -p "$TEST_PROJECT/docs/plans"
    cat > "$TEST_PROJECT/docs/plans/old-plan.md" <<'MDEOF'
# Old Plan

**Bead:** Test-deleted1

Plan for something that was cleaned up.
MDEOF

    # Mock bd show to fail (bead was deleted)
    bd() {
        if [[ "$1" == "show" ]]; then return 1; fi
        return 0
    }
    export -f bd

    run discovery_scan_orphans
    assert_success

    local count
    count=$(echo "$output" | jq 'length')
    [[ "$count" == "1" ]]
    [[ $(echo "$output" | jq -r '.[0].type') == "plan" ]]
    [[ $(echo "$output" | jq -r '.[0].bead_id') == "Test-deleted1" ]]
}

@test "orphans: skips artifact linked to existing bead" {
    mkdir -p "$TEST_PROJECT/docs/prds"
    cat > "$TEST_PROJECT/docs/prds/active-prd.md" <<'MDEOF'
# Active PRD

**Bead:** Test-active1

This PRD is tracked by an active bead.
MDEOF

    # Mock bd show to succeed (bead exists)
    bd() {
        if [[ "$1" == "show" && "$2" == "Test-active1" ]]; then return 0; fi
        return 1
    }
    export -f bd

    run discovery_scan_orphans
    assert_success

    local count
    count=$(echo "$output" | jq 'length')
    [[ "$count" == "0" ]]
}

@test "orphans: returns empty array when no docs directories exist" {
    # Don't create any docs directories
    run discovery_scan_orphans
    assert_success
    assert_output "[]"
}

@test "orphans: detects across multiple directories" {
    mkdir -p "$TEST_PROJECT/docs/brainstorms" "$TEST_PROJECT/docs/plans"
    echo "# Orphan Brainstorm" > "$TEST_PROJECT/docs/brainstorms/orphan1.md"
    echo "# Orphan Plan" > "$TEST_PROJECT/docs/plans/orphan2.md"

    bd() { return 1; }
    export -f bd

    run discovery_scan_orphans
    assert_success

    local count
    count=$(echo "$output" | jq 'length')
    [[ "$count" == "2" ]]
}

# ─── discovery_scan_beads: orphan integration ────────────────────────

@test "discovery: includes orphans in scan results" {
    # Create an unlinked artifact
    mkdir -p "$TEST_PROJECT/docs/brainstorms"
    echo "# Untracked Idea" > "$TEST_PROJECT/docs/brainstorms/untracked.md"

    # Mock bd: no open beads, but bd show fails (for orphan check)
    mock_bd '[]'
    # Override bd to also handle 'show' calls
    bd() {
        if [[ "$1" == "list" ]]; then
            if [[ "$*" == *"--status=in_progress"* ]]; then
                echo "[]"
            else
                echo "[]"
            fi
            return 0
        fi
        if [[ "$1" == "show" ]]; then return 1; fi
        return 1
    }
    export -f bd

    run discovery_scan_beads
    assert_success

    local count
    count=$(echo "$output" | jq 'length')
    [[ "$count" -ge 1 ]]
    # Orphan entry should have action: "create_bead"
    [[ $(echo "$output" | jq -r '.[-1].action') == "create_bead" ]]
    [[ $(echo "$output" | jq '.[-1].id') == "null" ]]
}

# ─── discovery_brief_scan: cached output ─────────────────────────────

@test "brief_scan: outputs summary with open beads" {
    mock_bd '[
        {"id":"Test-b1","title":"Fix auth","status":"open","priority":1,"updated_at":"2026-02-12T10:00:00Z"},
        {"id":"Test-b2","title":"Add tests","status":"open","priority":3,"updated_at":"2026-02-12T10:00:00Z"}
    ]'

    run discovery_brief_scan
    assert_success

    # Should contain count and top priority item
    [[ "$output" == *"open beads"* ]]
    [[ "$output" == *"Test-b1"* ]]
    [[ "$output" == *"Fix auth"* ]]
}

@test "brief_scan: shows in-progress count" {
    local open_json='[{"id":"Test-o1","title":"Open","status":"open","priority":2,"updated_at":"2026-02-12T10:00:00Z"}]'
    local ip_json='[{"id":"Test-ip1","title":"Active","status":"in_progress","priority":1,"updated_at":"2026-02-12T10:00:00Z"}]'
    mock_bd "$open_json" "$ip_json"

    run discovery_brief_scan
    assert_success

    [[ "$output" == *"in-progress"* ]]
    [[ "$output" == *"2 open beads"* ]]
}

@test "brief_scan: returns nothing when bd unavailable" {
    # Hide bd from PATH
    local old_path="$PATH"
    PATH="/nonexistent"
    unset _DISCOVERY_LOADED
    source "$HOOKS_DIR/lib-discovery.sh"

    run discovery_brief_scan
    PATH="$old_path"
    assert_success
    assert_output ""
}

@test "brief_scan: returns nothing when no open beads" {
    mock_bd '[]'
    run discovery_brief_scan
    assert_success
    assert_output ""
}

@test "brief_scan: uses cache on second call" {
    mock_bd '[{"id":"Test-c1","title":"Cached","status":"open","priority":1,"updated_at":"2026-02-12T10:00:00Z"}]'

    # First call populates cache
    run discovery_brief_scan
    assert_success
    local first_output="$output"

    # Replace bd mock with something different
    bd() {
        if [[ "$1" == "list" ]]; then
            echo '[{"id":"Test-c2","title":"Different","status":"open","priority":1,"updated_at":"2026-02-12T10:00:00Z"}]'
            return 0
        fi
        return 1
    }
    export -f bd

    # Second call should return cached result (Test-c1, not Test-c2)
    run discovery_brief_scan
    assert_success
    [[ "$output" == *"Test-c1"* ]]
    [[ "$output" != *"Test-c2"* ]]
}

@test "brief_scan: returns nothing when .beads dir missing" {
    rmdir "$TEST_PROJECT/.beads"
    mock_bd '[]'
    run discovery_brief_scan
    assert_success
    assert_output ""
}

# ─── score_bead (F8) ────────────────────────────────────────────────

@test "score_bead: P0 scores highest priority" {
    run score_bead 0 "" "" false
    assert_success
    # P0=60 + phase=0 + recency=5 (empty date) + staleness=0 = 65
    [[ "$output" -eq 65 ]]
}

@test "score_bead: P4 scores lowest priority" {
    run score_bead 4 "" "" false
    assert_success
    # P4=12 + phase=0 + recency=5 + staleness=0 = 17
    [[ "$output" -eq 17 ]]
}

@test "score_bead: executing phase adds 28 points" {
    run score_bead 2 "executing" "" false
    assert_success
    # P2=36 + executing=28 + recency=5 + staleness=0 = 69
    [[ "$output" -eq 69 ]]
}

@test "score_bead: shipping phase adds 30 points" {
    run score_bead 2 "shipping" "" false
    assert_success
    # P2=36 + shipping=30 + recency=5 = 71
    [[ "$output" -eq 71 ]]
}

@test "score_bead: brainstorm phase adds 4 points" {
    run score_bead 2 "brainstorm" "" false
    assert_success
    # P2=36 + brainstorm=4 + recency=5 = 45
    [[ "$output" -eq 45 ]]
}

@test "score_bead: unknown phase adds 0 points" {
    run score_bead 2 "nonexistent" "" false
    assert_success
    # P2=36 + unknown=0 + recency=5 = 41
    [[ "$output" -eq 41 ]]
}

@test "score_bead: recent update (< 24h) adds 20 points" {
    local recent_iso
    recent_iso=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)
    run score_bead 2 "" "$recent_iso" false
    assert_success
    # P2=36 + phase=0 + recency=20 = 56
    [[ "$output" -eq 56 ]]
}

@test "score_bead: staleness penalty subtracts 10 points" {
    run score_bead 2 "" "" true
    assert_success
    # P2=36 + phase=0 + recency=5 - staleness=10 = 31
    [[ "$output" -eq 31 ]]
}

@test "score_bead: P2 fresh outscores P4 stale executing" {
    local recent_iso
    recent_iso=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)

    local p2_score p4_score
    p2_score=$(score_bead 2 "brainstorm" "$recent_iso" false)
    p4_score=$(score_bead 4 "executing" "$recent_iso" true)

    # P2: 36+4+20+0=60, P4: 12+28+20-10=50
    [[ "$p2_score" -gt "$p4_score" ]]
}

@test "score_bead: phase executing outscores brainstorm at same priority" {
    local exec_score brain_score
    exec_score=$(score_bead 2 "executing" "" false)
    brain_score=$(score_bead 2 "brainstorm" "" false)

    # executing=28 vs brainstorm=4 → 24 point difference
    [[ "$exec_score" -gt "$brain_score" ]]
}

# ─── infer_bead_action: phase-aware (F8) ────────────────────────────

@test "infer_bead_action: phase=brainstorm returns strategize" {
    # Mock phase_get to return brainstorm
    phase_get() { echo "brainstorm"; }
    export -f phase_get

    run infer_bead_action "Test-001" "open"
    assert_success
    [[ "$output" == "strategize|"* ]]
}

@test "infer_bead_action: phase=plan-reviewed returns execute" {
    # Create a plan file
    mkdir -p "$TEST_PROJECT/docs/plans"
    echo -e "# Plan\n**Bead:** Test-001" > "$TEST_PROJECT/docs/plans/test-plan.md"

    phase_get() { echo "plan-reviewed"; }
    export -f phase_get

    run infer_bead_action "Test-001" "open"
    assert_success
    [[ "$output" == "execute|"* ]]
}

@test "infer_bead_action: phase=executing returns continue" {
    phase_get() { echo "executing"; }
    export -f phase_get

    run infer_bead_action "Test-001" "open"
    assert_success
    [[ "$output" == "continue|"* ]]
}

@test "infer_bead_action: phase=shipping returns ship" {
    phase_get() { echo "shipping"; }
    export -f phase_get

    run infer_bead_action "Test-001" "open"
    assert_success
    [[ "$output" == "ship|"* ]]
}

@test "infer_bead_action: phase=done returns closed" {
    phase_get() { echo "done"; }
    export -f phase_get

    run infer_bead_action "Test-001" "open"
    assert_success
    assert_output "closed|"
}

@test "infer_bead_action: no phase falls back to filesystem" {
    # No phase_get available
    unset -f phase_get 2>/dev/null || true

    mkdir -p "$TEST_PROJECT/docs/plans"
    echo -e "# Plan\n**Bead:** Test-001" > "$TEST_PROJECT/docs/plans/test-plan.md"

    run infer_bead_action "Test-001" "open"
    assert_success
    [[ "$output" == "execute|"* ]]
}

# ─── discovery_scan_beads: phase field (F8) ─────────────────────────

@test "discovery: includes phase field in output" {
    local recent_iso
    recent_iso=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)

    mock_bd "[{\"id\":\"Test-p1\",\"title\":\"Test\",\"status\":\"open\",\"priority\":2,\"updated_at\":\"${recent_iso}\"}]"

    # Mock phase_get to return a phase
    phase_get() {
        if [[ "$1" == "Test-p1" ]]; then echo "planned"; fi
    }
    export -f phase_get

    run discovery_scan_beads
    assert_success

    local phase
    phase=$(echo "$output" | jq -r '.[0].phase')
    [[ "$phase" == "planned" ]]
}

@test "discovery: score reflects phase advancement" {
    local recent_iso
    recent_iso=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)

    mock_bd "[
        {\"id\":\"Test-exec\",\"title\":\"Executing\",\"status\":\"in_progress\",\"priority\":2,\"updated_at\":\"${recent_iso}\"},
        {\"id\":\"Test-brain\",\"title\":\"Brainstorm\",\"status\":\"open\",\"priority\":2,\"updated_at\":\"${recent_iso}\"}
    ]"

    # Mock phase_get to return different phases
    phase_get() {
        case "$1" in
            Test-exec) echo "executing" ;;
            Test-brain) echo "brainstorm" ;;
            *) echo "" ;;
        esac
    }
    export -f phase_get

    run discovery_scan_beads
    assert_success

    # Executing bead should rank first (higher phase score)
    local first_id
    first_id=$(echo "$output" | jq -r '.[0].id')
    [[ "$first_id" == "Test-exec" ]]
}
