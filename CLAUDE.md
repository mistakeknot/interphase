# interline

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

## Design Decisions

- Libraries are sourced by consuming plugins (e.g., Clavain) via shim delegation
- All functions are fail-safe: return 0 on error, never block workflow
- Phase tracking is observability only — functions never enforce or block
- Discovery scanner outputs structured JSON for programmatic consumption
