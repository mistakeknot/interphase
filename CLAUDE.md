# interphase

Companion plugin for Clavain that provides lifecycle phase tracking, gate validation, and work discovery for the Beads issue tracker.

## Overview

- `hooks/lib-phase.sh` — Phase state tracking (set/get/infer bead phases)
- `hooks/lib-gates.sh` — Gate validation, dual persistence (beads + artifact headers), statusline updates
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

## Interline Integration

`_gate_update_statusline()` in `hooks/lib-gates.sh` writes `/tmp/clavain-bead-${session_id}.json` state files. These are read by the **interline** companion plugin's statusline renderer to display bead context (ID + phase) in the Claude Code status bar. No direct dependency — communication is via file-based sideband.

## Design Decisions

- Libraries are sourced by consuming plugins (e.g., Clavain) via shim delegation
- All functions are fail-safe: return 0 on error, never block workflow
- Phase tracking is observability only — functions never enforce or block
- Discovery scanner outputs structured JSON for programmatic consumption
