#!/usr/bin/env bash
# Work discovery scanner library for Clavain.
# Sourced by commands/lfg.md (on-demand discovery) and hooks/session-start.sh (future F4).
# All functions emit structured JSON to stdout. Errors emit sentinel strings.
# Multi-factor scoring (F8): priority + phase + recency - staleness.

# Guard against double-sourcing
[[ -n "${_DISCOVERY_LOADED:-}" ]] && return 0
_DISCOVERY_LOADED=1

DISCOVERY_PROJECT_DIR="${DISCOVERY_PROJECT_DIR:-.}"

# Source lib-phase.sh for phase_get (needed for phase-aware scoring)
_DISCOVERY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_DISCOVERY_SCRIPT_DIR}/lib-phase.sh" ]]; then
    export PHASE_PROJECT_DIR="$DISCOVERY_PROJECT_DIR"; source "${_DISCOVERY_SCRIPT_DIR}/lib-phase.sh" 2>/dev/null || true
fi

# ─── Multi-Factor Scoring (F8) ────────────────────────────────────────

# Score a bead for discovery ranking.
# Formula: priority_score + phase_score + recency_score + staleness_penalty
# Higher score = more important / more actionable.
#
# Args: $1 = priority (0-4), $2 = phase, $3 = updated_at (ISO 8601), $4 = stale (true/false)
# Output: integer score to stdout
score_bead() {
    local priority="${1:-4}"
    local phase="${2:-}"
    local updated_at="${3:-}"
    local stale="${4:-false}"

    local score=0

    # Priority score (0-60): strategic importance dominates
    # Gap between tiers is large enough that phase+recency can't invert 2-tier difference
    case "$priority" in
        0) score=$((score + 60)) ;;
        1) score=$((score + 48)) ;;
        2) score=$((score + 36)) ;;
        3) score=$((score + 24)) ;;
        *) score=$((score + 12)) ;;
    esac

    # Phase score (0-30): work in progress > ready to start > early stages
    case "$phase" in
        shipping)            score=$((score + 30)) ;;
        executing)           score=$((score + 28)) ;;
        plan-reviewed)       score=$((score + 24)) ;;
        planned)             score=$((score + 18)) ;;
        strategized)         score=$((score + 12)) ;;
        brainstorm-reviewed) score=$((score + 8)) ;;
        brainstorm)          score=$((score + 4)) ;;
        *)                   score=$((score + 0)) ;;
    esac

    # Recency score (0-20): recently touched beads are more relevant
    if [[ -n "$updated_at" && "$updated_at" != "null" ]]; then
        local updated_epoch now_epoch age_hours
        updated_epoch=$(date -d "$updated_at" +%s 2>/dev/null || echo "")
        now_epoch=$(date +%s)
        if [[ -n "$updated_epoch" && "$updated_epoch" -gt 0 ]]; then
            age_hours=$(( (now_epoch - updated_epoch) / 3600 ))
            if [[ $age_hours -lt 24 ]]; then
                score=$((score + 20))
            elif [[ $age_hours -lt 48 ]]; then
                score=$((score + 15))
            elif [[ $age_hours -lt 168 ]]; then  # 7 days
                score=$((score + 10))
            else
                score=$((score + 5))
            fi
        else
            score=$((score + 5))  # Can't parse date, default low
        fi
    else
        score=$((score + 5))
    fi

    # Staleness penalty
    if [[ "$stale" == "true" ]]; then
        score=$((score - 10))
    fi

    echo "$score"
}

# ─── Action Inference ─────────────────────────────────────────────────

# Determine the recommended next action for a bead based on filesystem artifacts.
# Single source of truth: grep docs/ directories for bead ID references.
# Uses word-boundary anchors to prevent substring false positives.
#
# Args: $1 = bead_id, $2 = status (already validated by caller)
# Output: "action|artifact_path" to stdout
infer_bead_action() {
    local bead_id="$1"
    local status="$2"

    local plan_path="" prd_path="" brainstorm_path=""

    # Filesystem scan for artifacts referencing this bead.
    # Pattern: "Bead" (possibly markdown-bold) followed by the bead ID.
    # Word-boundary: bead IDs are alphanumeric+hyphen, so we match the ID
    # followed by a non-word char (space, paren, comma, colon, EOL).
    # Uses -P (Perl regex) for \b support; falls back to basic match if unavailable.
    local grep_flags="-rl"
    local pattern
    if grep -P "" /dev/null 2>/dev/null; then
        grep_flags="-rlP"
        pattern="Bead.*${bead_id}\b"
    else
        # Portable fallback: match ID followed by non-alnum or end of line
        pattern="Bead.*${bead_id}[^a-zA-Z0-9_-]"
    fi
    if [[ -d "${DISCOVERY_PROJECT_DIR}/docs/plans" ]]; then
        plan_path=$(grep $grep_flags "$pattern" "${DISCOVERY_PROJECT_DIR}/docs/plans/" 2>/dev/null | head -1 || true)
        # Fallback: pattern may not match if ID is at EOL (portable mode)
        if [[ -z "$plan_path" && "$grep_flags" == "-rl" ]]; then
            plan_path=$(grep -rl "Bead.*${bead_id}$" "${DISCOVERY_PROJECT_DIR}/docs/plans/" 2>/dev/null | head -1 || true)
        fi
    fi
    if [[ -d "${DISCOVERY_PROJECT_DIR}/docs/prds" ]]; then
        prd_path=$(grep $grep_flags "$pattern" "${DISCOVERY_PROJECT_DIR}/docs/prds/" 2>/dev/null | head -1 || true)
        if [[ -z "$prd_path" && "$grep_flags" == "-rl" ]]; then
            prd_path=$(grep -rl "Bead.*${bead_id}$" "${DISCOVERY_PROJECT_DIR}/docs/prds/" 2>/dev/null | head -1 || true)
        fi
    fi
    if [[ -d "${DISCOVERY_PROJECT_DIR}/docs/brainstorms" ]]; then
        brainstorm_path=$(grep $grep_flags "$pattern" "${DISCOVERY_PROJECT_DIR}/docs/brainstorms/" 2>/dev/null | head -1 || true)
        if [[ -z "$brainstorm_path" && "$grep_flags" == "-rl" ]]; then
            brainstorm_path=$(grep -rl "Bead.*${bead_id}$" "${DISCOVERY_PROJECT_DIR}/docs/brainstorms/" 2>/dev/null | head -1 || true)
        fi
    fi

    # Phase-aware action inference (overrides filesystem-based logic when phase is available)
    local phase=""
    if command -v phase_get &>/dev/null && [[ -n "$bead_id" ]]; then
        phase=$(phase_get "$bead_id" 2>/dev/null) || phase=""
    fi

    if [[ -n "$phase" ]]; then
        case "$phase" in
            brainstorm)          echo "strategize|${brainstorm_path}"; return 0 ;;
            brainstorm-reviewed) echo "strategize|${brainstorm_path}"; return 0 ;;
            strategized)         echo "plan|${prd_path}"; return 0 ;;
            planned)             echo "execute|${plan_path}"; return 0 ;;
            plan-reviewed)       echo "execute|${plan_path}"; return 0 ;;
            executing)           echo "continue|${plan_path}"; return 0 ;;
            shipping)            echo "ship|${plan_path}"; return 0 ;;
            done)                echo "closed|"; return 0 ;;
        esac
    fi

    # Fallback: filesystem-based inference (no phase set)
    if [[ "$status" == "in_progress" ]]; then
        echo "continue|${plan_path}"
    elif [[ -n "$plan_path" ]]; then
        echo "execute|${plan_path}"
    elif [[ -n "$prd_path" ]]; then
        echo "plan|${prd_path}"
    elif [[ -n "$brainstorm_path" ]]; then
        echo "strategize|${brainstorm_path}"
    else
        echo "brainstorm|"
    fi
}

# ─── Scanner ──────────────────────────────────────────────────────────

# Scan open beads and rank by priority then recency.
# Output:
#   - "DISCOVERY_UNAVAILABLE" if bd not installed
#   - "DISCOVERY_ERROR" if bd fails or returns invalid JSON
#   - "[]" if no open beads
#   - JSON array: [{id, title, priority, status, action, plan_path, stale}, ...]
discovery_scan_beads() {
    # Re-apply default in case caller used prefix assignment (VAR=x source ...) which
    # rolls back after source completes, leaving the variable unset.
    DISCOVERY_PROJECT_DIR="${DISCOVERY_PROJECT_DIR:-.}"

    # Guard: bd must be installed
    if ! command -v bd &>/dev/null; then
        echo "DISCOVERY_UNAVAILABLE"
        return 0
    fi

    # Guard: .beads directory must exist
    if [[ ! -d "${DISCOVERY_PROJECT_DIR}/.beads" ]]; then
        echo "DISCOVERY_UNAVAILABLE"
        return 0
    fi

    # Query open + in_progress beads (bd only supports single status filter)
    local open_list ip_list
    open_list=$(bd list --status=open --json 2>/dev/null) || {
        echo "DISCOVERY_ERROR"
        return 0
    }
    ip_list=$(bd list --status=in_progress --json 2>/dev/null) || ip_list="[]"

    # Validate JSON
    if ! echo "$open_list" | jq empty 2>/dev/null; then
        echo "DISCOVERY_ERROR"
        return 0
    fi
    if ! echo "$ip_list" | jq empty 2>/dev/null; then
        ip_list="[]"
    fi

    # Merge both lists
    local merged
    merged=$(jq -n --argjson a "$open_list" --argjson b "$ip_list" '$a + $b')

    local count
    count=$(echo "$merged" | jq 'length' 2>/dev/null) || count=0
    [[ "$count" == "null" ]] && count=0

    # Build result array with multi-factor scoring (F8)
    local results="[]"
    local two_days_ago
    two_days_ago=$(date -d '2 days ago' +%s 2>/dev/null || date -v-2d +%s 2>/dev/null || echo 0)

    local i=0
    while [[ $i -lt $count ]]; do
        local bead_json
        bead_json=$(echo "$merged" | jq ".[$i]")

        # Extract fields with validation
        local id status priority title updated
        id=$(echo "$bead_json" | jq -r '.id // empty')
        status=$(echo "$bead_json" | jq -r '.status // empty')
        priority=$(echo "$bead_json" | jq -r '.priority // 4')
        title=$(echo "$bead_json" | jq -r '.title // "Untitled"')
        updated=$(echo "$bead_json" | jq -r '.updated_at // ""')

        # Skip if essential fields missing
        if [[ -z "$id" || -z "$status" ]]; then
            i=$((i + 1))
            continue
        fi

        # Read phase for this bead (F8: phase-aware scoring)
        # TODO(performance): phase_get is O(n) subprocess calls. For >50 beads,
        # consider caching phase state in /tmp/clavain-phase-cache-${session_id}.json
        local phase=""
        if command -v phase_get &>/dev/null; then
            phase=$(phase_get "$id" 2>/dev/null) || phase=""
        fi

        # Infer action via filesystem scan (now phase-aware)
        local action_result action plan_path
        action_result=$(infer_bead_action "$id" "$status")
        action="${action_result%%|*}"
        plan_path="${action_result#*|}"

        # Staleness check: plan mtime if available, else bead updated_at
        # Default to not-stale on any error (stat failure, date parse failure)
        # to avoid false "stale" signals from transient filesystem issues.
        local stale=false
        if [[ -n "$plan_path" && -f "$plan_path" ]]; then
            local plan_mtime
            plan_mtime=$(stat -c %Y "$plan_path" 2>/dev/null || stat -f %m "$plan_path" 2>/dev/null || echo "")
            if [[ -n "$plan_mtime" && "$plan_mtime" -lt "$two_days_ago" ]]; then
                stale=true
            fi
        elif [[ -n "$updated" && "$updated" != "null" && "$updated" != "" ]]; then
            local updated_epoch
            updated_epoch=$(date -d "$updated" +%s 2>/dev/null || echo "")
            if [[ -n "$updated_epoch" && "$updated_epoch" -lt "$two_days_ago" ]]; then
                stale=true
            fi
        fi

        # Multi-factor score (F8)
        local score
        score=$(score_bead "$priority" "$phase" "$updated" "$stale")

        # Append to results with phase and score fields
        results=$(echo "$results" | jq \
            --arg id "$id" \
            --arg title "$title" \
            --argjson priority "${priority:-4}" \
            --arg status "$status" \
            --arg action "$action" \
            --arg plan_path "$plan_path" \
            --argjson stale "$stale" \
            --arg phase "$phase" \
            --argjson score "${score:-0}" \
            '. + [{id: $id, title: $title, priority: $priority, status: $status, action: $action, plan_path: $plan_path, stale: $stale, phase: $phase, score: $score}]')

        i=$((i + 1))
    done

    # Append orphaned artifacts (unlinked docs without beads)
    local orphans
    orphans=$(discovery_scan_orphans 2>/dev/null) || orphans="[]"
    if [[ "$orphans" != "[]" ]]; then
        local orphan_count
        orphan_count=$(echo "$orphans" | jq 'length' 2>/dev/null) || orphan_count=0
        local j=0
        while [[ $j -lt $orphan_count ]]; do
            local orphan_json o_title o_path o_type
            orphan_json=$(echo "$orphans" | jq ".[$j]")
            o_title=$(echo "$orphan_json" | jq -r '.title // "Untitled"')
            o_path=$(echo "$orphan_json" | jq -r '.path // ""')
            o_type=$(echo "$orphan_json" | jq -r '.type // ""')

            results=$(echo "$results" | jq \
                --arg title "$o_title" \
                --arg plan_path "$o_path" \
                --arg type "$o_type" \
                '. + [{id: null, title: $title, priority: 3, status: "orphan", action: "create_bead", plan_path: $plan_path, stale: false, phase: "", score: 0}]')

            j=$((j + 1))
        done
    fi

    # Sort by score DESC, then id ASC (deterministic tiebreaker)
    results=$(echo "$results" | jq 'sort_by(-.score, .id)')

    echo "$results"
}

# ─── Orphan Detection ─────────────────────────────────────────────────

# Scan docs/{brainstorms,prds,plans} for markdown artifacts not linked to any
# active bead. Returns JSON array of orphaned artifacts.
#
# An artifact is orphaned if:
#   1. No bead ID found in file (unlinked artifact)
#   2. Bead ID found but bead doesn't exist (deleted bead)
# An artifact is NOT orphaned if:
#   - Bead ID found and bead exists (active work, any status including closed)
#
# Output: JSON array [{path, type, title, bead_id}] or "[]" if no orphans.
discovery_scan_orphans() {
    local project_dir="${DISCOVERY_PROJECT_DIR:-.}"
    local orphans="[]"

    # Regex to extract bead IDs from markdown headers.
    # Matches patterns like: **Bead:** Foo-abc123, Bead: Foo-xyz, <!-- Bead: Foo-123 -->
    local bead_id_regex='[Bb]ead[*]*[[:space:]:]*([A-Za-z]+-[a-z0-9]+)'

    local dir type
    for dir in docs/brainstorms docs/prds docs/plans; do
        [[ -d "${project_dir}/${dir}" ]] || continue

        case "$dir" in
            docs/brainstorms) type="brainstorm" ;;
            docs/prds)        type="prd" ;;
            docs/plans)       type="plan" ;;
        esac

        local file
        while IFS= read -r -d '' file; do
            # Extract title from first heading
            local title=""
            title=$(grep -m1 '^# ' "$file" 2>/dev/null | sed 's/^# //' || true)
            [[ -z "$title" ]] && title="$(basename "$file" .md)"

            # Extract bead ID(s) from file content
            local bead_id=""
            if grep -P "" /dev/null 2>/dev/null; then
                bead_id=$(grep -oP "$bead_id_regex" "$file" 2>/dev/null | head -1 | grep -oP '[A-Za-z]+-[a-z0-9]+$' || true)
            else
                # Portable fallback: use grep -E
                bead_id=$(grep -oE '[A-Za-z]+-[a-z0-9]+' <(grep -i 'bead' "$file" 2>/dev/null | head -1) 2>/dev/null | head -1 || true)
            fi

            if [[ -z "$bead_id" ]]; then
                # No bead reference at all → unlinked orphan
                local rel_path="${file#"${project_dir}/"}"
                orphans=$(echo "$orphans" | jq \
                    --arg path "$rel_path" \
                    --arg type "$type" \
                    --arg title "$title" \
                    --arg bead_id "" \
                    '. + [{path: $path, type: $type, title: $title, bead_id: $bead_id}]')
            else
                # Bead ID found — verify it still exists
                if ! bd show "$bead_id" &>/dev/null; then
                    # Bead was deleted → stale orphan
                    local rel_path="${file#"${project_dir}/"}"
                    orphans=$(echo "$orphans" | jq \
                        --arg path "$rel_path" \
                        --arg type "$type" \
                        --arg title "$title" \
                        --arg bead_id "$bead_id" \
                        '. + [{path: $path, type: $type, title: $title, bead_id: $bead_id}]')
                fi
                # Bead exists (open, in_progress, or closed) → not orphan
            fi
        done < <(find "${project_dir}/${dir}" -name '*.md' -print0 2>/dev/null)
    done

    echo "$orphans"
}

# ─── Brief Scan ──────────────────────────────────────────────────────

# Lightweight work state summary for session-start injection.
# Uses a 60-second TTL cache to avoid repeated bd queries.
# Output: 1-2 line plain text summary, or empty string if unavailable.
discovery_brief_scan() {
    # Guard: bd must be installed
    if ! command -v bd &>/dev/null; then
        return 0
    fi

    # Guard: .beads directory must exist
    local project_dir="${DISCOVERY_PROJECT_DIR:-.}"
    if [[ ! -d "${project_dir}/.beads" ]]; then
        return 0
    fi

    # Cache path — unique per project directory
    local cache_key="${project_dir//\//_}"
    local cache_file="/tmp/clavain-discovery-brief-${cache_key}.cache"

    # Check TTL (60 seconds)
    if [[ -f "$cache_file" ]]; then
        local cache_mtime now cache_age
        cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
        now=$(date +%s)
        cache_age=$(( now - cache_mtime ))
        if [[ $cache_age -lt 60 && $cache_age -ge 0 ]]; then
            # Cache is fresh — validate then return
            local cached
            cached=$(cat "$cache_file" 2>/dev/null) || cached=""
            if [[ "$cached" == "NO_WORK" ]]; then
                return 0  # Valid "no open beads" state
            elif [[ -n "$cached" ]]; then
                echo "$cached"
                return 0
            fi
        fi
    fi

    # Cache stale or missing — query bd
    local open_json
    open_json=$(bd list --status=open --json 2>/dev/null) || return 0
    local ip_json
    ip_json=$(bd list --status=in_progress --json 2>/dev/null) || ip_json="[]"

    # Validate JSON before processing
    echo "$open_json" | jq empty 2>/dev/null || return 0
    echo "$ip_json" | jq empty 2>/dev/null || ip_json="[]"

    # Count beads
    local open_count ip_count
    open_count=$(echo "$open_json" | jq 'length' 2>/dev/null) || open_count=0
    ip_count=$(echo "$ip_json" | jq 'length' 2>/dev/null) || ip_count=0
    local total_count=$(( open_count + ip_count ))

    if [[ "$total_count" -eq 0 ]]; then
        # No open work — cache with sentinel so next call uses cache
        local temp_cache="${cache_file}.$$"
        echo "NO_WORK" > "$temp_cache" 2>/dev/null && mv -f "$temp_cache" "$cache_file" 2>/dev/null || true
        return 0
    fi

    # Find highest-priority item across both lists
    local merged top_id top_title top_priority top_action
    merged=$(jq -n --argjson a "$open_json" --argjson b "$ip_json" '$a + $b | sort_by(.priority) | .[0]')
    top_id=$(echo "$merged" | jq -r '.id // empty')
    top_title=$(echo "$merged" | jq -r '.title // "Untitled"')
    top_priority=$(echo "$merged" | jq -r '.priority // 4')

    # Infer action for the top item (if function available)
    top_action="Review"
    if [[ -n "$top_id" ]]; then
        local top_status
        top_status=$(echo "$merged" | jq -r '.status // "open"')
        local action_result
        action_result=$(infer_bead_action "$top_id" "$top_status" 2>/dev/null) || action_result="brainstorm|"
        local action_verb="${action_result%%|*}"
        case "$action_verb" in
            continue)   top_action="Continue" ;;
            execute)    top_action="Execute plan for" ;;
            plan)       top_action="Plan" ;;
            strategize) top_action="Strategize" ;;
            brainstorm) top_action="Brainstorm" ;;
            ship)       top_action="Ship" ;;
            closed)     top_action="Review (closed)" ;;
            *)          top_action="Review" ;;
        esac
    fi

    # Build summary
    local summary
    if [[ "$ip_count" -gt 0 ]]; then
        summary="${total_count} open beads (${ip_count} in-progress). Top: ${top_action} ${top_id} — ${top_title} (P${top_priority})"
    else
        summary="${total_count} open beads. Top: ${top_action} ${top_id} — ${top_title} (P${top_priority})"
    fi

    # Write to cache (atomic: temp file + rename prevents partial reads)
    local temp_cache="${cache_file}.$$"
    echo "$summary" > "$temp_cache" 2>/dev/null && mv -f "$temp_cache" "$cache_file" 2>/dev/null || true

    echo "$summary"
}

# ─── Telemetry ────────────────────────────────────────────────────────

# Log which discovery option was selected. Append-only JSONL.
# Uses jq for safe JSON construction — no printf injection from user data.
# Fails silently — telemetry must never block workflow.
#
# Args: $1 = bead_id, $2 = action, $3 = was_recommended (true/false)
discovery_log_selection() {
    local bead_id="$1"
    local action="$2"
    local was_recommended="${3:-false}"
    local telemetry_file="${HOME}/.clavain/telemetry.jsonl"

    mkdir -p "$(dirname "$telemetry_file")" 2>/dev/null || return 0

    jq -n -c \
        --arg event "discovery_select" \
        --arg bead "$bead_id" \
        --arg action "$action" \
        --argjson recommended "$was_recommended" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{event: $event, bead: $bead, action: $action, recommended: $recommended, timestamp: $ts}' \
        >> "$telemetry_file" 2>/dev/null || true
}
