#!/usr/bin/env bash
# PostToolUse:Bash hook — auto-claim beads when agents run bd update --status=in_progress
# or bd update --claim outside of /clavain:route.
#
# Sets claimed_by/claimed_at state and exports CLAVAIN_BEAD_ID to CLAUDE_ENV_FILE,
# which activates the heartbeat and session-end-release hooks.
#
# No set -euo pipefail — PostToolUse hooks must never block tool execution.

# Fast guard — if CLAVAIN_BEAD_ID is already set, the route skill handled claiming
command -v bd &>/dev/null || exit 0

# Read hook input
INPUT=$(cat)

# Extract the command that was run
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[[ -n "$COMMAND" ]] || exit 0

# Only act on bd update/claim commands that set in_progress or use --claim
case "$COMMAND" in
    *bd\ update*--status=in_progress*|*bd\ update*--claim*|*bd\ claim*)
        ;;
    *)
        exit 0
        ;;
esac

# Check if command succeeded
EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_result.exit_code // ""' 2>/dev/null) || exit 0
[[ "$EXIT_CODE" == "0" || -z "$EXIT_CODE" ]] || exit 0

# Extract issue ID from the command (first argument after bd update/claim)
# Note: separate lookbehinds required — PCRE rejects variable-length (?:update|claim)
ISSUE_ID=$(echo "$COMMAND" | grep -oP '(?<=bd update |bd claim )\S+' 2>/dev/null) || exit 0
[[ -n "$ISSUE_ID" ]] || exit 0

# If CLAVAIN_BEAD_ID already matches this bead, nothing to do (idempotent)
if [[ "${CLAVAIN_BEAD_ID:-}" == "$ISSUE_ID" ]]; then
    exit 0
fi

SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"

# Collision check — don't stomp another session's active claim
EXISTING_CLAIMER=$(bd state "$ISSUE_ID" claimed_by 2>/dev/null) || EXISTING_CLAIMER=""
if [[ -n "$EXISTING_CLAIMER" && "$EXISTING_CLAIMER" != "(no claimed_by state set)" && "$EXISTING_CLAIMER" != "$SESSION_ID" ]]; then
    # Check if the existing claim is still fresh (within 45 min)
    EXISTING_TS=$(bd state "$ISSUE_ID" claimed_at 2>/dev/null) || EXISTING_TS=""
    if [[ -n "$EXISTING_TS" && "$EXISTING_TS" != "(no claimed_at state set)" ]]; then
        NOW=$(date +%s)
        AGE=$(( NOW - EXISTING_TS ))
        if (( AGE < 2700 )); then
            # Fresh claim by another session — don't override
            cat <<ENDJSON
{"additionalContext": "INTERPHASE: Bead ${ISSUE_ID} is actively claimed by session ${EXISTING_CLAIMER:0:8}… (${AGE}s ago). Auto-claim skipped to avoid collision."}
ENDJSON
            exit 0
        fi
    fi
fi

# Write claiming state
bd set-state "$ISSUE_ID" "claimed_by=$SESSION_ID" >/dev/null 2>&1 || true
bd set-state "$ISSUE_ID" "claimed_at=$(date +%s)" >/dev/null 2>&1 || true

# Export CLAVAIN_BEAD_ID so heartbeat + session-end-release activate
if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
    echo "export CLAVAIN_BEAD_ID=${ISSUE_ID}" >> "$CLAUDE_ENV_FILE"
fi

exit 0
