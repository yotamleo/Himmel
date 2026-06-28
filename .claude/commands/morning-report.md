---
description: Generate the dated 🌅 Morning Report from live git/gh/jira/worktree state at ~zero Claude tokens (no-token default; opt-in --llm enriches TL;DR + Suggested order + theme-clustered Backlog). HIMMEL-574.
argument-hint: "[--llm] [--llm-model M] [--since SHA] [--since-date YYYY-MM-DD] [--out PATH] [--jira-limit N] [--backlog-limit N] [--dry-run]"
---

Generate the daily 🌅 Morning Report by templating live `git`/`gh`/`jira`/`worktree`
state into the curated schema and writing it to the handover bucket
(`morning-report-<local-date>.md`). The default run costs ~no Claude tokens — it
emits deterministic sections (✅ Completed PRs, 🔴 In-flight WIP, 🧹 Stale
worktrees, 📋 Backlog, Done cross-ref) plus heuristic TL;DR + Suggested order.

Pass `--llm` to enrich TL;DR, Suggested order, and Backlog theme-clustering via a
bounded interactive Sonnet turn (degrades to the deterministic heuristic if
`claude` is unavailable). It is a point-in-time snapshot — cross-day continuity
stays a session's job.

Run:

```bash
bash scripts/handover/generate-morning-briefing.sh $ARGUMENTS
```

Common: `/morning-report` · `/morning-report --llm` · `/morning-report --dry-run`
