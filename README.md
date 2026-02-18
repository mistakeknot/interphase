# interphase

Phase tracking and gate validation for the Beads issue tracker.

## What This Does

interphase adds lifecycle state management on top of beads — discovery, planning, building, review, shipping. Each phase has gates that should be satisfied before moving to the next one. The key word is "should" — interphase tracks and reports but never blocks. It's observability, not enforcement.

The libraries (`lib-phase.sh`, `lib-gates.sh`, `lib-discovery.sh`) are sourced by consuming plugins like Clavain rather than running as standalone hooks. This keeps the hook budget lean while still making phase awareness available everywhere it's needed.

Phase state is communicated to interline via sideband files at `~/.interband/interphase/bead/${session_id}.json`, so the statusline can show your current workflow phase without any direct coupling between the plugins.

## Installation

```bash
/plugin install interphase
```

Companion plugin for Clavain — most useful when installed alongside the core engineering plugin.

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

All functions are fail-safe: return 0 on error, never block the workflow. A stuck interphase should be invisible, not catastrophic.
