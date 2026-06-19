# RTK - Rust Token Killer

**Usage**: Token-optimized CLI proxy (60-90% savings on dev operations)

## Meta Commands (always use rtk directly)

```bash
rtk gain              # Show token savings analytics
rtk gain --history    # Show command usage history with savings
rtk discover          # Analyze Claude Code history for missed opportunities
rtk proxy <cmd>       # Execute raw command without filtering (for debugging)
```

## Installation Verification

```bash
rtk --version         # Should show: rtk X.Y.Z
rtk gain              # Should work (not "command not found")
which rtk             # Verify correct binary
```

⚠️ **Name collision**: If `rtk gain` fails, you may have reachingforthejack/rtk (Rust Type Kit) installed instead.

## Hook-Based Usage

All other commands are automatically rewritten by the Claude Code hook.
Example: `git status` → `rtk git status` (transparent, 0 tokens overhead)

Refer to CLAUDE.md for full command reference.

## "No hook installed" banner

`rtk init --show` reports `Hook: not found` and rewritten commands print
`[rtk] /!\ No hook installed` to stderr. This is **benign** — himmel uses
`scripts/hooks/rtk-hook-guard.sh` instead of a bare `rtk hook claude` entry,
so rtk's self-check can't find its own signature even though rewriting works.
Do NOT re-run `rtk init -g` to resolve it; that re-adds the bare entry himmel
already replaced. See `docs/setup/new-machine.md §3a` for the reconcile command
if bare entries accumulate.
