---
description: Diagnose common himmel-harness health problems (node/caveman SessionStart wiring, shadowed claude-obsidian, dirty single-writer luna vault, bitbucket-vs-gh, handover-registry gaps, PATH-fragile bare-interpreter MCP servers), print a severity-grouped report, optionally heal the node wiring (--fix) and file ONE consolidated GitHub issue.
---

Run `himmel-doctor` to surface the field problems that bite himmel installs —
chiefly the macOS/Linux **`node: command not found` at SessionStart** (a caveman
hook wired at a node path that a PATH-less GUI launch / a node upgrade made
unresolvable), a **shadowed claude-obsidian** (prompt-type-hook error after
autoUpdate shadows the himmel pin), a **dirty single-writer luna vault** (e.g.
after `/luna-upgrade`, which writes but never commits), a **Bitbucket repo** where
`/commit-push-pr`'s hardcoded `gh` can't open a PR, and a **repo not in the
handover registry** (so `handover-resume` finds nothing).

It also flags **PATH-fragile MCP servers** (C6) — servers wired as a bare
interpreter (`uvx mcp-obsidian`, `bun …`) that a PATH-less macOS GUI launch can't
find, so the server and all its tools silently fail to start (same root cause as
the node hook).

It is read-only EXCEPT `--fix`, which heals the C1 node wiring by rewriting the
caveman hooks in the **user-scope** `~/.claude/settings.json` (outside any repo —
the on-main / repo-settings self-mod guards do not apply) to route through the
runtime node wrapper `scripts/lib/run-node.sh`. On Windows `--fix` is a no-op (the
`C:\Program Files\nodejs` path is stable; win11.ps1 owns it).

This command runs from **any directory** — resolve the himmel checkout the same
way `/himmel-update` does, then run the doctor:

```bash
# Resolve the himmel checkout: $HIMMEL_REPO -> git toplevel -> canonical -> error.
REPO="${HIMMEL_REPO:-}"
[ -n "$REPO" ] && [ -f "$REPO/scripts/himmel-doctor.sh" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO" ] || [ ! -f "$REPO/scripts/himmel-doctor.sh" ]; then
  for c in "$HOME/Documents/github/himmel" "$HOME/Documents/github/Himmel" "$HOME/github/himmel" "$HOME/github/Himmel"; do
    [ -f "$c/scripts/himmel-doctor.sh" ] && { REPO="$c"; break; }
  done
fi
[ -f "$REPO/scripts/himmel-doctor.sh" ] || { echo "ERR: cannot locate himmel checkout — set HIMMEL_REPO" >&2; exit 1; }

bash "$REPO/scripts/himmel-doctor.sh"                       # report only
bash "$REPO/scripts/himmel-doctor.sh" --fix                 # also heal the node (C1) wiring
bash "$REPO/scripts/himmel-doctor.sh" --file-issue --repo owner/name   # file ONE consolidated public GitHub issue
```

Drive the operator interaction yourself: run the report; if there are FAIL/WARN
findings, summarize them, then ASK the operator whether to (a) heal the node
wiring (`--fix`) and/or (b) file a consolidated GitHub issue. Only on a yes re-run
with `--fix` / `--file-issue --repo <public-repo>`. The issue repo resolves from
`--repo` → `$HIMMEL_DOCTOR_ISSUE_REPO` → the github `origin` slug; for the
operator's himmel, that public mirror is `yotamleo/Himmel`. Exit code is 1 if any
FAIL finding is present (0 otherwise), so a `--fix` re-run that clears C1 returns 0.
