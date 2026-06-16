---
description: Dispatch gemini-cli on a prompt in a background Warp tab (fire-and-forget). Returns the log path immediately.
argument-hint: "<prompt>"
---

Spawn a fresh local Warp terminal tab and run gemini-cli (via
`scripts/gemini/invoke.sh`) on the user's prompt. This Claude session returns
immediately — fire-and-forget. The new tab is visible in your Warp window;
output streams to a log file under `<repo-top>/logs/gemini/`.

**Steps:**

1. Use the **Write** tool to save the literal prompt text below into this
   exact path (overwrite is fine — the dispatcher reads and deletes the file):

   `${CLAUDE_PROJECT_DIR}/.claude/cache/gemini-bg-input.txt`

   File content = the user's prompt, verbatim:

   ```
   $ARGUMENTS
   ```

   (Use the Write tool — not Bash heredoc — so quotes / newlines / backticks
   in the prompt are preserved exactly without shell parsing.)

2. Dispatch via the Bash tool:

   ```bash
   powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PROJECT_DIR}/scripts/gemini/offload-bg.ps1" -PromptFile "${CLAUDE_PROJECT_DIR}/.claude/cache/gemini-bg-input.txt" -Cwd "${CLAUDE_PROJECT_DIR}"
   ```

3. The dispatcher prints a `LogPath` line. Return that log path to the user so
   they can tail it. No status tracking — fire-and-forget.

**When to use:**
- Long-running gemini task (large-context read, full-task run) where you don't
  need the result inline in this session.
- You want to free this Claude session's token budget.

**When NOT to use:**
- You need gemini's output inline now — use `/gemini` (synchronous) instead.
- Task is interactive / needs operator decisions mid-run.

**Local-only.** Same machine only. No return channel — operator tails the log.
