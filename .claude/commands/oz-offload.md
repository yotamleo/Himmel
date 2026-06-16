---
description: Offload a long-running independent task to a separate local Warp tab running `warp agent run` (fire-and-forget; same-machine only)
argument-hint: <task description>
---

Spawn a fresh local Warp terminal tab and have Warp's native agent (`warp agent run`) work on the user's task. This Claude session returns immediately — fire-and-forget. The new tab is visible in your Warp window; inspect it there for progress and results. With "Close tab on shell exit" enabled in Warp settings, the tab closes automatically when the agent finishes.

**Steps:**

1. Use the **Write** tool to save the literal task text below into this exact path (overwrite is fine — the dispatcher reads and deletes the file):

   `${CLAUDE_PROJECT_DIR}/.claude/cache/oz-offload-input.txt`

   File content = the user's task, verbatim:

   ```
   $ARGUMENTS
   ```

   (Use the Write tool — not Bash heredoc — so quotes / newlines / backticks in the prompt are preserved exactly without shell parsing.)

2. Dispatch via the Bash tool:

   ```bash
   powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PROJECT_DIR}/scripts/oz/offload.ps1" -PromptFile "${CLAUDE_PROJECT_DIR}/.claude/cache/oz-offload-input.txt" -Cwd "${CLAUDE_PROJECT_DIR}"
   ```

**When to use:**
- The task is long-running and independent (no shared session context needed).
- You want to free this Claude session's token budget for other work.
- The task is something Warp's agent can do standalone (codebase analysis, single-PR-scope refactor, doc generation).

**When NOT to use:**
- Task needs context from this conversation that the offloaded agent can't see.
- Task is interactive / needs operator decisions mid-run.
- Task finishes in seconds — overhead exceeds value.
- You need the result inline in this session — offload is fire-and-forget; there is no return channel in v1.

**Local-only.** Same machine only. No CI, no SSH, no remote operator. Cloud Oz agents (`oz agent run-cloud`) are explicitly out of scope per the project's no-API-key, no-cloud constraint.

**Offload target is `warp agent run`, never a headless/print-mode claude invocation.** Headless Claude Code bills to a separate bucket and is banned from normal workflow — see root `CLAUDE.md` § Claude invocation billing (HIMMEL-128) if maintaining this command.
