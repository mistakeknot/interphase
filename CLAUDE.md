# interphase

Companion plugin for Clavain that provides lifecycle phase tracking, gate validation, and work discovery for the Beads issue tracker.

## Overview

- `hooks/lib-phase.sh` — Phase state tracking (set/get/infer bead phases)
- `hooks/lib-gates.sh` — Gate validation, dual persistence (beads + artifact headers)
- `hooks/lib-discovery.sh` — Work discovery scanner (scan open beads, infer next actions)
- `skills/beads-workflow/` — Beads workflow skill with CLI reference and troubleshooting

## Quick Commands

```bash
# Syntax check
bash -n hooks/lib-phase.sh
bash -n hooks/lib-gates.sh
bash -n hooks/lib-discovery.sh

# Run tests
bats tests/shell/

# Manifest check
python3 -c "import json; json.load(open('.claude-plugin/plugin.json'))"
```

## interline Integration

The statusline sideband is **kernel-authored** (Sylveste-rfs, 2026-07-20): `clavain-cli sprint-advance` (`writeBeadSideband` in os/Clavain) writes the interband envelope to `~/.interband/interphase/bead/${session_id}.json` plus the legacy `/tmp/clavain-bead-${session_id}.json`. interphase no longer writes the sideband — its `_gate_update_statusline` writer was retired per the f-005 consumer-migration rule. The **interline** statusline renderer reads the envelope (legacy path as fallback) to display bead context (ID + phase). No direct dependency — communication is via file-based sideband.

## Configuration

interphase uses env-based gate controls:

- `CLAVAIN_GATE_FAIL_CLOSED=true` enables strict fail-closed behavior for hard-tier (`P0`/`P1`) transitions.
- `CLAVAIN_SKIP_GATE="reason"` bypasses hard/strict blocks with explicit audit trail.
- `CLAVAIN_DISABLE_GATES=true` bypasses all gate enforcement.

Visible output (statusline colors, labels, layers) is configured via the **interline** companion plugin (`~/.claude/interline.json`). The integration contract between interphase and interline is the sideband bead payload (`id`, `phase`, `reason`, `ts`) carried in `~/.interband/interphase/bead/${session_id}.json` (with legacy `/tmp/clavain-bead-${session_id}.json` fallback).

## Design Decisions

- Libraries are sourced by consuming plugins (e.g., Clavain) via shim delegation
- Legacy mode is fail-safe/fail-open for dependency errors
- Strict mode is opt-in and fail-closed for hard-tier dependency/malformed-input errors
- Discovery scanner outputs structured JSON for programmatic consumption
