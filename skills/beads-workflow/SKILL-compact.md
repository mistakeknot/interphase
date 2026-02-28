# Beads Workflow (compact)

Git-native issue tracker (`bd`) for persistent task tracking across sessions with dependencies.

## When to Invoke

Use when work spans multiple sessions, has dependencies, or needs persistent cross-agent tracking. For single-session tasks, use in-memory TaskCreate instead.

## Essential Commands

```bash
bd ready                          # Find work with no blockers
bd list --status=open             # All open issues
bd show <id>                      # Detail view with deps
bd create --title="..." --type=task|bug|feature --priority=2
bd update <id> --claim            # Atomically claim (preferred)
bd close <id> --reason="..."      # Mark complete
bd dep add <issue> <depends-on>   # Add dependency
bd sync                           # Compatibility sync (0.50.x syncs, 0.51+ no-op)
bd doctor --fix --yes             # Health check and auto-fix
```

**Priority:** 0-4 numeric (0=critical, 4=backlog). NOT "high"/"medium"/"low".

**Hierarchy:** `bd create --parent=bd-a3f8` creates bd-a3f8.1 (dot notation).

## Session Close Protocol (CRITICAL)

```bash
git add <files> && git commit -m "..." && bd sync && git push
```

Never skip. Work is not done until pushed.

## Batch Consolidation

After creating 5+ beads, review for: same-file merges, parent-child absorption, duplicates, missing deps, missing descriptions. Typically reduces backlog 30-40%.

## Workflow Modes

- **Stealth** (`bd init --stealth`): local-only, nothing committed
- **Contributor** (`bd init --contributor`): planning in `~/.beads-planning`
- **Maintainer**: full read-write, auto-detected via SSH/HTTPS

## Key Facts

- Database lives at monorepo root `.beads/`, not in submodules
- Backend: Dolt (cell-level merge). Rebuild from JSONL: `bd doctor --fix --source=jsonl`
- `bv` command: AI-friendly analytics (PageRank, critical path, parallel tracks)

---
*For full command reference, daily maintenance, and integration details, read SKILL.md.*
