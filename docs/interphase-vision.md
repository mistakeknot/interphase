# interphase — Vision and Philosophy

**Version:** 0.1.0
**Last updated:** 2026-02-28

## What interphase Is

interphase adds lifecycle phase tracking, gate validation, and work discovery on top of the
Beads issue tracker. It defines an 8-step bead lifecycle — brainstorm, brainstorm-reviewed,
strategized, planned, plan-reviewed, executing, shipping, done — and provides three sourced
libraries (`lib-phase.sh`, `lib-gates.sh`, `lib-discovery.sh`) that Clavain and other plugins
use to record transitions, enforce gate preconditions, and scan for actionable work.

Phase transitions are durable: each transition writes to Beads state and appends a JSONL event
to `~/.clavain/telemetry.jsonl`. Gate state is written as structured sideband to
`~/.interband/interphase/bead/${session_id}.json`, where interline reads it to render the
current bead context in the statusline — with no direct coupling between the two plugins.

## Why This Exists

Workflow phases are only meaningful if they leave evidence. Without interphase, Clavain knows
which commands to run but not whether the bead was reviewed before execution, or how long it
spent in each phase. interphase closes that loop: every transition is a receipt, every gate
check is an auditable precondition, and the telemetry log gives the session a durable record
of what happened and in what order.

## Design Principles

1. **Transitions are receipts, not cursor state.** Phase changes write to Beads and emit JSONL
   telemetry. The record is the proof. If it didn't produce a receipt, it didn't happen.

2. **Fail-open by default, fail-closed by choice.** All library functions return 0 on error and
   never block workflow unless strict mode is explicitly opted into. Hard-tier beads (P0/P1)
   can enable `CLAVAIN_GATE_FAIL_CLOSED=true` to get enforcement instead of observation.

3. **Gates enforce the review ladder.** brainstorm-reviewed and plan-reviewed phases exist to
   ensure a human approved each thinking phase before the agent advances to execution. Skipping
   a gate requires `CLAVAIN_SKIP_GATE="reason"` — the reason is audited, not silently dropped.

4. **Libraries, not hooks.** interphase is sourced by consumers rather than running as
   standalone hooks. This keeps the hook budget lean while making phase awareness available
   everywhere it is needed.

5. **Sideband over coupling.** interphase communicates with interline via files, not imports.
   Each plugin can evolve independently; the contract is the payload schema, not a shared API.

## Scope

**Does:**
- Track and record phase transitions on beads via the `bd` CLI
- Validate gate preconditions before high-risk phase advances
- Write structured sideband state for interline to render
- Scan open beads and infer next recommended actions (discovery)
- Emit append-only JSONL telemetry for every transition

**Does not:**
- Own the bead data model (that is Beads/`bd`)
- Render the statusline (that is interline)
- Run Clavain workflow commands or make autonomous phase decisions
- Require any plugin to be installed — all functions fail safely if `bd` is absent

## Direction

- Expand gate rules to cover more transition pairs as the phase model stabilizes
- Add structured discovery output consumed by `/lfg` routing in Clavain for automatic bead
  selection at session start
- Provide a gate audit report command so agents and humans can review skip history per bead
