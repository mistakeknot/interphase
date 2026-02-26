# interphase

Phase tracking and gate validation for the Beads issue tracker.

## What this does

interphase adds lifecycle state management on top of beads: discovery, planning, building, review, shipping. Each phase has gates that should be satisfied before moving to the next one. By default, interphase tracks and reports without blocking (observability-first). An opt-in strict mode can fail closed for high-risk transitions.

The libraries (`lib-phase.sh`, `lib-gates.sh`, `lib-discovery.sh`) are sourced by consuming plugins like Clavain rather than running as standalone hooks. This keeps the hook budget lean while still making phase awareness available everywhere it's needed.

Phase state is communicated to interline via sideband files at `~/.interband/interphase/bead/${session_id}.json`, so the statusline can show your current workflow phase without any direct coupling between the plugins.

## Installation

First, add the [interagency marketplace](https://github.com/mistakeknot/interagency-marketplace) (one-time setup):

```bash
/plugin marketplace add mistakeknot/interagency-marketplace
```

Then install the plugin:

```bash
/plugin install interphase
```

Companion plugin for Clavain: most useful when installed alongside the core engineering plugin.

## Usage

The `beads-workflow` skill provides guidance for the full beads lifecycle:

```
"what phase am I in?"
"check gate requirements for review"
"discover open work"
```

## Architecture

```
lib/
  lib-phase.sh       Phase state tracking (set/get/infer)
  lib-gates.sh       Gate validation with dual persistence
  lib-discovery.sh   Work discovery scanner
skills/
  beads-workflow/     Lifecycle guidance skill
tests/               Bats shell tests
```

By default, functions are fail-safe: return 0 on dependency/error paths and avoid blocking workflow. In strict mode, hard-tier transitions can intentionally fail closed.

## Strict Mode (Opt-In)

interphase supports an opt-in strict gate mode for high-risk transitions:

- Set `CLAVAIN_GATE_FAIL_CLOSED=true` to enable strict behavior.
- Strict mode applies to hard-tier beads only (`P0`/`P1`).
- In strict mode, dependency or malformed-input errors fail closed instead of failing open.
- `CLAVAIN_SKIP_GATE="reason"` remains available as an emergency override and is explicitly audited.
- `CLAVAIN_DISABLE_GATES=true` still bypasses all gate enforcement.
