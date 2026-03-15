#!/usr/bin/env bash
# Shared gate library for Clavain lifecycle phase transitions.
# Provides validation, dual persistence (beads + artifact headers), fallback reading,
# tiered enforcement (F7), and stale review detection.
#
# Sources lib-phase.sh internally (reuses phase_set, phase_get, CLAVAIN_PHASES).
# Public functions are fail-safe by default (legacy mode). In strict mode
# (CLAVAIN_GATE_FAIL_CLOSED=true), hard-tier transitions (P0/P1) fail closed on
# dependency and malformed-input errors.
# Set CLAVAIN_DISABLE_GATES=true to bypass all enforcement (emergency escape hatch).

# Guard against double-sourcing
[[ -n "${_GATES_LOADED:-}" ]] && return 0
_GATES_LOADED=1

GATES_PROJECT_DIR="${GATES_PROJECT_DIR:-.}"

# Source lib-phase.sh for phase_set, phase_get, phase_infer_bead, CLAVAIN_PHASES
_GATES_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_PROJECT_DIR="$GATES_PROJECT_DIR"; source "${_GATES_SCRIPT_DIR}/lib-phase.sh"

# Optional shared sideband protocol library.
# Legacy mode is fail-open when interband is unavailable.
_gate_load_interband() {
    [[ "${_GATE_INTERBAND_LOADED:-0}" -eq 1 ]] && return 0

    local repo_root=""
    repo_root="$(git -C "$_GATES_SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"

    local candidate
    for candidate in \
        "${INTERBAND_LIB:-}" \
        "${_GATES_SCRIPT_DIR}/../../../infra/interband/lib/interband.sh" \
        "${_GATES_SCRIPT_DIR}/../../../interband/lib/interband.sh" \
        "${repo_root}/../interband/lib/interband.sh" \
        "${HOME}/.local/share/interband/lib/interband.sh"
    do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            # shellcheck source=/dev/null
            source "$candidate" && _GATE_INTERBAND_LOADED=1 && return 0
        fi
    done

    _GATE_INTERBAND_LOADED=0
    return 1
}

# ─── Phase Graph ─────────────────────────────────────────────────────

# Valid transitions as "from:to" strings. Empty from = first touch.
VALID_TRANSITIONS=(
    ":brainstorm"
    "brainstorm:brainstorm-reviewed"
    "brainstorm-reviewed:strategized"
    "strategized:planned"
    "planned:plan-reviewed"
    "plan-reviewed:executing"
    "executing:shipping"
    "shipping:done"
    # Skip paths (common in practice)
    ":brainstorm-reviewed"
    ":strategized"
    ":planned"
    ":plan-reviewed"
    ":executing"
    "brainstorm:strategized"
    "brainstorm-reviewed:planned"
    "strategized:plan-reviewed"
    "planned:executing"
    "plan-reviewed:shipping"
    "executing:done"
    # Phase cycling (re-entry for new milestones)
    "shipping:brainstorm"
    "shipping:planned"
    "done:brainstorm"
    "done:planned"
)

# Directories whose artifacts get **Phase:** headers.
# PRDs excluded — they are shared across beads.
ARTIFACT_PHASE_DIRS=("docs/brainstorms" "docs/plans")

# ─── Public Functions ────────────────────────────────────────────────

# Check if a transition from one phase to another is valid.
# Args: $1 = from (empty string for first touch), $2 = to
# Returns: 0 if valid, 1 if invalid
is_valid_transition() {
    local from="${1:-}"
    local to="${2:-}"

    if [[ -z "$to" ]]; then
        return 1
    fi

    local entry
    for entry in "${VALID_TRANSITIONS[@]}"; do
        if [[ "$entry" == "${from}:${to}" ]]; then
            return 0
        fi
    done
    return 1
}

# Check whether a phase gate allows transition to the target phase.
# Reads current phase via phase_get_with_fallback, checks is_valid_transition.
# Returns 0 on valid (or on error — fail-safe). Returns 1 on invalid, with stderr warning.
#
# Args: $1 = bead_id, $2 = target phase, $3 = artifact_path (optional)
check_phase_gate() {
    local bead_id="${1:-}"
    local target="${2:-}"
    local artifact_path="${3:-}"

    # Fail-safe: if inputs are missing, allow
    if [[ -z "$bead_id" || -z "$target" ]]; then
        return 0
    fi

    local current
    current=$(phase_get_with_fallback "$bead_id" "$artifact_path" 2>/dev/null) || true

    if is_valid_transition "$current" "$target"; then
        _gate_log_check "$bead_id" "$current" "$target" "pass"
        return 0
    else
        echo "WARNING: phase gate blocked $current → $target for $bead_id" >&2
        _gate_log_check "$bead_id" "$current" "$target" "blocked"
        return 1
    fi
}

# ─── Enforcement (F7) ──────────────────────────────────────────────

# Strict mode toggle.
_gate_strict_enabled() {
    [[ "${CLAVAIN_GATE_FAIL_CLOSED:-false}" == "true" ]]
}

# Resolve tier with structured errors.
# Output format: "<tier>|<error_class>|<error_reason>"
# error_class values: transient|permanent|"".
_gate_resolve_enforcement_tier() {
    local bead_id="${1:-}"
    if [[ -z "$bead_id" ]]; then
        echo "none||missing_bead_id"
        return 0
    fi

    local bead_json
    bead_json=$(bd show "$bead_id" --json 2>/dev/null) || {
        echo "none|transient|bd_show_failed"
        return 1
    }

    local priority
    priority=$(echo "$bead_json" | jq -er '.priority // 4' 2>/dev/null) || {
        echo "none|permanent|priority_json_parse_error"
        return 1
    }
    if [[ ! "$priority" =~ ^[0-9]+$ ]]; then
        echo "none|permanent|priority_not_integer"
        return 1
    fi

    case "$priority" in
        0|1) echo "hard||" ;;
        2|3) echo "soft||" ;;
        *)   echo "none||" ;;
    esac
}

# Get the enforcement tier for a bead based on its priority.
# Returns: hard (P0/P1), soft (P2/P3), or none (P4+)
#
# Args: $1 = bead_id
# Output: tier string to stdout
get_enforcement_tier() {
    local bead_id="${1:-}"
    local resolved tier
    resolved=$(_gate_resolve_enforcement_tier "$bead_id" 2>/dev/null) || true
    IFS='|' read -r tier _ _ <<< "$resolved"
    [[ -z "$tier" ]] && tier="none"
    echo "$tier"
}

# Check if a flux-drive review for an artifact is stale.
# Uses bead-ID matching to find review (survives file renames).
#
# Args: $1 = bead_id, $2 = artifact_path
# Output: "fresh", "stale", "none" (no review), or "unknown" (indeterminate)
check_review_staleness() {
    local bead_id="${1:-}"
    local artifact_path="${2:-}"
    _GATES_LAST_REVIEW_ERROR_CLASS=""
    _GATES_LAST_REVIEW_ERROR_REASON=""
    _GATES_LAST_REVIEW_STALENESS="none"

    if [[ -z "$artifact_path" ]]; then
        _GATES_LAST_REVIEW_STALENESS="none"
        echo "none"
        return 0
    fi

    local project_dir="${GATES_PROJECT_DIR:-.}"
    local research_dir="${project_dir}/docs/research/flux-drive"

    if [[ ! -d "$research_dir" ]]; then
        _GATES_LAST_REVIEW_STALENESS="none"
        echo "none"
        return 0
    fi

    # Strategy 1: Find review by bead-ID in findings.json
    local findings_file="" reviewed_date=""
    local candidate
    while IFS= read -r -d '' candidate; do
        # Check if this review references our bead or our artifact
        if [[ -n "$bead_id" ]] && jq -e --arg bid "$bead_id" '.bead_id == $bid or (.input // "" | contains($bid))' "$candidate" &>/dev/null; then
            findings_file="$candidate"
            break
        fi
        # Fallback: check if artifact path matches
        if [[ -n "$artifact_path" ]]; then
            local input_path
            input_path=$(jq -r '.input // ""' "$candidate" 2>/dev/null) || continue
            if [[ "$input_path" == *"$(basename "$artifact_path")"* ]]; then
                findings_file="$candidate"
                break
            fi
        fi
    done < <(find "$research_dir" -name 'findings.json' -print0 2>/dev/null)

    if [[ -z "$findings_file" ]]; then
        _GATES_LAST_REVIEW_STALENESS="none"
        echo "none"
        return 0
    fi

    # Read reviewed timestamp
    reviewed_date=$(jq -r '.reviewed // ""' "$findings_file" 2>/dev/null) || {
        _GATES_LAST_REVIEW_ERROR_CLASS="permanent"
        _GATES_LAST_REVIEW_ERROR_REASON="review_metadata_malformed"
        _GATES_LAST_REVIEW_STALENESS="unknown"
        echo "unknown"
        return 0
    }

    if [[ -z "$reviewed_date" || "$reviewed_date" == "null" ]]; then
        _GATES_LAST_REVIEW_ERROR_CLASS="permanent"
        _GATES_LAST_REVIEW_ERROR_REASON="review_timestamp_missing"
        _GATES_LAST_REVIEW_STALENESS="unknown"
        echo "unknown"
        return 0
    fi

    # Check if artifact has been modified since the review
    if [[ -n "$artifact_path" && -f "${project_dir}/${artifact_path}" ]]; then
        local commits_after
        commits_after=$(cd "$project_dir" && git log --oneline --since="$reviewed_date" -- "$artifact_path" 2>/dev/null | head -1) || {
            _GATES_LAST_REVIEW_ERROR_CLASS="transient"
            _GATES_LAST_REVIEW_ERROR_REASON="git_log_failed"
            _GATES_LAST_REVIEW_STALENESS="unknown"
            echo "unknown"
            return 0
        }
        if [[ -n "$commits_after" ]]; then
            _GATES_LAST_REVIEW_STALENESS="stale"
            echo "stale"
            return 0
        fi
    fi

    _GATES_LAST_REVIEW_STALENESS="fresh"
    echo "fresh"
}

_gate_check_interband_dependency() {
    _GATE_DEP_ERROR_CLASS=""
    _GATE_DEP_ERROR_REASON=""

    # No session means no sideband target requirement.
    if [[ -z "${CLAUDE_SESSION_ID:-}" ]]; then
        return 0
    fi

    if _gate_load_interband && type interband_path >/dev/null 2>&1 && type interband_write >/dev/null 2>&1; then
        return 0
    fi

    _GATE_DEP_ERROR_CLASS="transient"
    _GATE_DEP_ERROR_REASON="interband_unavailable"
    return 1
}

_gate_retry_transient_dependency() {
    local check_fn="${1:-}"
    local attempts=3
    local attempt=1
    [[ -z "$check_fn" ]] && return 1

    while [[ $attempt -le $attempts ]]; do
        if "$check_fn"; then
            return 0
        fi
        if [[ "${_GATE_DEP_ERROR_CLASS:-}" != "transient" ]]; then
            return 1
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

_gate_strict_fail_or_skip() {
    local bead_id="${1:-}"
    local target="${2:-}"
    local tier="${3:-hard}"
    local error_class="${4:-permanent}"
    local error_reason="${5:-strict_dependency_failed}"
    local skip_reason="${6:-}"

    if [[ -n "$skip_reason" ]]; then
        local audit_entry="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Strict gate skipped: $target (class=$error_class, reason: $error_reason, override: $skip_reason)"
        bd update "$bead_id" --append-notes "$audit_entry" 2>/dev/null || {
            echo "WARNING: failed to write strict skip-gate audit entry for $bead_id" >&2
        }
        _gate_log_enforcement "$bead_id" "?" "$tier" "skip-strict-override" "class=$error_class reason=$error_reason override=$skip_reason"
        return 0
    fi

    echo "ERROR: strict gate blocked $target for $bead_id (tier=$tier, class=$error_class, reason=$error_reason)" >&2
    echo "  Set CLAVAIN_SKIP_GATE=\"reason\" to override strict block." >&2
    _gate_log_enforcement "$bead_id" "?" "$tier" "block-strict-$error_class" "$error_reason"
    return 1
}

# Enforce a phase gate with priority-based tiering.
# Wraps check_phase_gate() with tier logic and audit trail.
#
# Tiers: hard (P0/P1) = block, soft (P2/P3) = warn, none (P4) = skip
# Override: set CLAVAIN_SKIP_GATE="reason" to bypass hard blocks.
# Emergency: set CLAVAIN_DISABLE_GATES=true to skip all enforcement.
#
# Args: $1 = bead_id, $2 = target_phase, $3 = artifact_path (optional)
# Returns: 0 = proceed, 1 = hard block
enforce_gate() {
    local bead_id="${1:-}"
    local target="${2:-}"
    local artifact_path="${3:-}"
    local skip_reason="${CLAVAIN_SKIP_GATE:-}"

    # Emergency bypass
    if [[ "${CLAVAIN_DISABLE_GATES:-}" == "true" ]]; then
        echo "WARNING: gate enforcement DISABLED by CLAVAIN_DISABLE_GATES" >&2
        _gate_log_enforcement "$bead_id" "?" "none" "bypass" "CLAVAIN_DISABLE_GATES"
        return 0
    fi

    # Fail-safe: if inputs are missing, allow
    if [[ -z "$bead_id" || -z "$target" ]]; then
        return 0
    fi

    # Resolve enforcement tier with detailed error classification.
    local resolved tier tier_error_class tier_error_reason
    resolved=$(_gate_resolve_enforcement_tier "$bead_id" 2>/dev/null) || true
    IFS='|' read -r tier tier_error_class tier_error_reason <<< "$resolved"
    [[ -z "$tier" ]] && tier="none"

    local strict_mode="false"
    if _gate_strict_enabled && [[ "$tier" == "hard" || -n "$tier_error_class" ]]; then
        strict_mode="true"
    fi

    # Fail closed on tier resolution errors in strict mode.
    if [[ -n "$tier_error_class" ]]; then
        if [[ "$strict_mode" == "true" ]]; then
            _gate_strict_fail_or_skip "$bead_id" "$target" "hard" "$tier_error_class" "$tier_error_reason" "$skip_reason"
            return $?
        fi
        tier="none"
    fi

    # No-gate tier: skip entirely
    if [[ "$tier" == "none" ]]; then
        _gate_log_enforcement "$bead_id" "?" "$tier" "pass-no-gate" ""
        return 0
    fi

    # Strict mode: ensure interband dependency is available for hard-tier transitions.
    if [[ "$strict_mode" == "true" ]]; then
        if ! _gate_retry_transient_dependency _gate_check_interband_dependency; then
            _gate_strict_fail_or_skip \
                "$bead_id" "$target" "$tier" \
                "${_GATE_DEP_ERROR_CLASS:-transient}" "${_GATE_DEP_ERROR_REASON:-dependency_check_failed}" \
                "$skip_reason"
            return $?
        fi
    fi

    # Check phase gate
    if check_phase_gate "$bead_id" "$target" "$artifact_path" 2>/dev/null; then
        # Valid transition — proceed regardless of tier
        _gate_log_enforcement "$bead_id" "?" "$tier" "pass" ""
        return 0
    fi

    # Invalid transition — check staleness
    local staleness="unknown"
    if [[ -n "$artifact_path" ]]; then
        check_review_staleness "$bead_id" "$artifact_path" >/dev/null 2>/dev/null || true
        staleness="${_GATES_LAST_REVIEW_STALENESS:-unknown}"
    fi
    if [[ "$strict_mode" == "true" && "$staleness" == "unknown" && -n "${_GATES_LAST_REVIEW_ERROR_CLASS:-}" ]]; then
        _gate_strict_fail_or_skip \
            "$bead_id" "$target" "$tier" \
            "$_GATES_LAST_REVIEW_ERROR_CLASS" "$_GATES_LAST_REVIEW_ERROR_REASON" \
            "$skip_reason"
        return $?
    fi

    # Handle by tier
    case "$tier" in
        hard)
            # Check for skip override
            if [[ -n "$skip_reason" ]]; then
                # Record skip in bead notes (fail-safe: continue even if write fails)
                local audit_entry="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Gate skipped: $target (tier=hard, reason: $skip_reason)"
                bd update "$bead_id" --append-notes "$audit_entry" 2>/dev/null || {
                    echo "WARNING: failed to write skip-gate audit entry for $bead_id" >&2
                }
                _gate_log_enforcement "$bead_id" "?" "$tier" "skip" "$skip_reason"
                return 0
            fi

            # Stale review = soft warning (not hard block) even for P0/P1
            if [[ "$staleness" == "stale" ]]; then
                echo "WARNING: review is stale for $bead_id — run /clavain:flux-drive to refresh" >&2
                _gate_log_enforcement "$bead_id" "?" "$tier" "warn-stale" ""
                return 0
            fi

            # Hard block
            echo "ERROR: phase gate blocked $target for $bead_id (tier=hard)" >&2
            echo "  Set CLAVAIN_SKIP_GATE=\"reason\" to override, or run /clavain:flux-drive first" >&2
            _gate_log_enforcement "$bead_id" "?" "$tier" "block" ""
            return 1
            ;;
        soft)
            # Soft gates always proceed with warning
            echo "WARNING: phase gate would block $target for $bead_id (tier=soft, proceeding)" >&2
            if [[ "$staleness" == "stale" ]]; then
                echo "  Review is stale — consider running /clavain:flux-drive" >&2
            fi
            _gate_log_enforcement "$bead_id" "?" "$tier" "warn" ""
            return 0
            ;;
    esac

    # Shouldn't reach here, but fail-safe
    return 0
}

# ─── Phase Management ──────────────────────────────────────────────

# Advance the phase: set on bead (via phase_set) and write to artifact header.
# Fail-safe: never blocks workflow.
#
# Args: $1 = bead_id, $2 = target phase, $3 = reason, $4 = artifact_path (optional)
advance_phase() {
    local bead_id="${1:-}"
    local target="${2:-}"
    local reason="${3:-}"
    local artifact_path="${4:-}"

    # Guard: need bead_id and target
    if [[ -z "$bead_id" || -z "$target" ]]; then
        return 0
    fi

    # Write to beads (primary persistence)
    phase_set "$bead_id" "$target" "$reason"

    # Write to artifact header (secondary persistence)
    if [[ -n "$artifact_path" ]]; then
        _gate_write_artifact_phase "$artifact_path" "$target"
    fi

    _gate_log_advance "$bead_id" "$target" "$reason" "$artifact_path"

    # Update statusline state file (read by ~/.claude/statusline.sh)
    _gate_update_statusline "$bead_id" "$target" "$reason"
}

# Get the current phase with fallback: beads first, then artifact header.
# Warns on desync (beads != artifact).
#
# Args: $1 = bead_id, $2 = artifact_path (optional)
# Output: phase value to stdout, or empty string
phase_get_with_fallback() {
    local bead_id="${1:-}"
    local artifact_path="${2:-}"

    local bead_phase=""
    local artifact_phase=""

    # Read from beads (primary)
    if [[ -n "$bead_id" ]]; then
        bead_phase=$(phase_get "$bead_id" 2>/dev/null) || true
    fi

    # Read from artifact header (secondary)
    if [[ -n "$artifact_path" ]]; then
        artifact_phase=$(_gate_read_artifact_phase "$artifact_path" 2>/dev/null) || true
    fi

    # Return beads phase if available
    if [[ -n "$bead_phase" ]]; then
        # Warn on desync
        if [[ -n "$artifact_phase" && "$bead_phase" != "$artifact_phase" ]]; then
            _gate_log_desync "$bead_id" "$bead_phase" "$artifact_phase" "$artifact_path"
            echo "WARNING: phase desync for $bead_id — beads=$bead_phase, artifact=$artifact_phase" >&2
        fi
        echo "$bead_phase"
        return 0
    fi

    # Fallback to artifact
    if [[ -n "$artifact_phase" ]]; then
        echo "$artifact_phase"
        return 0
    fi

    echo ""
}

# ─── Internal Functions ──────────────────────────────────────────────

# Write or update **Phase:** header in an artifact file.
# Only writes to files in ARTIFACT_PHASE_DIRS. Skips silently otherwise.
#
# Args: $1 = file path, $2 = phase
_gate_write_artifact_phase() {
    local filepath="${1:-}"
    local phase="${2:-}"

    if [[ -z "$filepath" || -z "$phase" || ! -f "$filepath" ]]; then
        return 0
    fi

    # Check if file is in an allowed directory
    local allowed=false
    local dir
    for dir in "${ARTIFACT_PHASE_DIRS[@]}"; do
        if [[ "$filepath" == *"$dir"* ]]; then
            allowed=true
            break
        fi
    done
    if [[ "$allowed" != "true" ]]; then
        return 0
    fi

    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
    local phase_line="**Phase:** ${phase} (as of ${timestamp})"
    local escaped_phase_line
    escaped_phase_line=$(_gate_sed_escape "$phase_line")

    # Strategy 1: Update existing **Phase:** line
    if grep -q '^\*\*Phase:\*\*' "$filepath" 2>/dev/null; then
        sed -i "s|^\*\*Phase:\*\*.*|${escaped_phase_line}|" "$filepath" 2>/dev/null || true
        return 0
    fi

    # Strategy 2: Insert after **Bead:** line
    if grep -q '^\*\*Bead:\*\*' "$filepath" 2>/dev/null; then
        sed -i "/^\*\*Bead:\*\*/a\\${escaped_phase_line}" "$filepath" 2>/dev/null || true
        return 0
    fi

    # Strategy 3: Insert after first # heading
    if grep -q '^# ' "$filepath" 2>/dev/null; then
        sed -i "0,/^# /{/^# /a\\${escaped_phase_line}
}" "$filepath" 2>/dev/null || true
        return 0
    fi
}

# Read phase value from **Phase:** line in an artifact file.
# Args: $1 = file path
# Output: phase value to stdout, or empty string
_gate_read_artifact_phase() {
    local filepath="${1:-}"

    if [[ -z "$filepath" || ! -f "$filepath" ]]; then
        echo ""
        return 0
    fi

    local line
    line=$(grep '^\*\*Phase:\*\*' "$filepath" 2>/dev/null | head -1) || true

    if [[ -z "$line" ]]; then
        echo ""
        return 0
    fi

    # Extract: **Phase:** <value> (as of <timestamp>)
    # Strip "**Phase:** " prefix and optional " (as of ...)" suffix
    local phase
    phase=$(echo "$line" | sed 's/^\*\*Phase:\*\*\s*//' | sed 's/\s*(as of .*)$//')
    echo "$phase"
}

# Escape a string for safe use in sed replacement.
# Handles backslash, forward slash, and ampersand.
_gate_sed_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\//\\/}"
    str="${str//&/\\&}"
    echo "$str"
}

# Write bead context to a session-keyed state file for the statusline.
# The statusline script runs as a subprocess and can't see in-conversation
# state, so we use /tmp/clavain-bead-<session_id>.json as a sideband channel.
#
# Args: $1 = bead_id, $2 = phase, $3 = reason (optional)
_gate_update_statusline() {
    local bead_id="$1" phase="$2" reason="${3:-}"
    local session_id="${CLAUDE_SESSION_ID:-}"
    [ -z "$session_id" ] && return 0
    local state_file="/tmp/clavain-bead-${session_id}.json"
    local payload_json
    payload_json=$(jq -n -c \
        --arg id "$bead_id" --arg phase "$phase" \
        --arg reason "$reason" --arg ts "$(date +%s)" \
        '{id:$id, phase:$phase, reason:$reason, ts:($ts|tonumber)}' \
    ) || payload_json=""
    [[ -z "$payload_json" ]] && return 0

    # Preferred path: structured sideband envelope under ~/.interband.
    if _gate_load_interband && type interband_path >/dev/null 2>&1 && type interband_write >/dev/null 2>&1; then
        local interband_file
        interband_file=$(interband_path "interphase" "bead" "$session_id" 2>/dev/null) || interband_file=""
        if [[ -n "$interband_file" ]]; then
            interband_write "$interband_file" "interphase" "bead_phase" "$session_id" "$payload_json" \
                2>/dev/null || true
            if type interband_prune_channel >/dev/null 2>&1; then
                interband_prune_channel "interphase" "bead" 2>/dev/null || true
            fi
        fi
    fi

    # Backward-compatible legacy path for existing consumers.
    local tmp_file="${state_file}.tmp.$$"
    printf '%s\n' "$payload_json" > "$tmp_file" 2>/dev/null && mv -f "$tmp_file" "$state_file" 2>/dev/null || true
}

# ─── Telemetry ───────────────────────────────────────────────────────

_gate_log_check() {
    local bead_id="$1"
    local from="${2:-}"
    local to="$3"
    local result="$4"
    local telemetry_file="${HOME}/.clavain/telemetry.jsonl"

    mkdir -p "$(dirname "$telemetry_file")" 2>/dev/null || return 0

    jq -n -c \
        --arg event "gate_check" \
        --arg bead "$bead_id" \
        --arg from "$from" \
        --arg to "$to" \
        --arg result "$result" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{event: $event, bead: $bead, from: $from, to: $to, result: $result, timestamp: $ts}' \
        >> "$telemetry_file" 2>/dev/null || true
}

_gate_log_advance() {
    local bead_id="$1"
    local phase="$2"
    local reason="${3:-}"
    local artifact="${4:-}"
    local telemetry_file="${HOME}/.clavain/telemetry.jsonl"

    mkdir -p "$(dirname "$telemetry_file")" 2>/dev/null || return 0

    jq -n -c \
        --arg event "phase_advance" \
        --arg bead "$bead_id" \
        --arg phase "$phase" \
        --arg reason "$reason" \
        --arg artifact "$artifact" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{event: $event, bead: $bead, phase: $phase, reason: $reason, artifact: $artifact, timestamp: $ts}' \
        >> "$telemetry_file" 2>/dev/null || true
}

_gate_log_enforcement() {
    local bead_id="$1"
    local priority="${2:-?}"
    local tier="$3"
    local decision="$4"
    local reason="${5:-}"
    local telemetry_file="${HOME}/.clavain/telemetry.jsonl"

    mkdir -p "$(dirname "$telemetry_file")" 2>/dev/null || return 0

    jq -n -c \
        --arg event "gate_enforce" \
        --arg bead "$bead_id" \
        --arg priority "$priority" \
        --arg tier "$tier" \
        --arg decision "$decision" \
        --arg reason "$reason" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{event: $event, bead: $bead, priority: $priority, tier: $tier, decision: $decision, reason: $reason, timestamp: $ts}' \
        >> "$telemetry_file" 2>/dev/null || true
}

_gate_log_desync() {
    local bead_id="$1"
    local bead_phase="$2"
    local artifact_phase="$3"
    local artifact_path="${4:-}"
    local telemetry_file="${HOME}/.clavain/telemetry.jsonl"

    mkdir -p "$(dirname "$telemetry_file")" 2>/dev/null || return 0

    jq -n -c \
        --arg event "phase_desync" \
        --arg bead "$bead_id" \
        --arg bead_phase "$bead_phase" \
        --arg artifact_phase "$artifact_phase" \
        --arg artifact "$artifact_path" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{event: $event, bead: $bead, bead_phase: $bead_phase, artifact_phase: $artifact_phase, artifact: $artifact, timestamp: $ts}' \
        >> "$telemetry_file" 2>/dev/null || true
}
