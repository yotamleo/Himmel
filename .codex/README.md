# `.codex/` — himmel guardrails under Codex (HIMMEL-427)

Wires himmel's PreToolUse / PostToolUse / SessionStart / UserPromptSubmit
guardrails so they fire when himmel runs under **Codex** (which implements a
Claude-compatible hook engine). See `docs/internals/harness-compat.md` for the
full compat matrix.

## Files
- **`hooks.json`** — the project hook config (Codex recognises a project
  `.codex/hooks.json` layer). Every command invokes `run-hook.cmd <script.sh>`.
  Kept to the strict schema (only a top-level `hooks` key — Codex's parser uses
  `deny_unknown_fields`, so an extra key like `description`/`_comment` would make
  it skip the hooks).
  Includes `block-docker-privesc.sh` + `block-merged-pr-commit.sh` (HIMMEL-589):
  these two SECURITY guards ship via the `himmel-ops` plugin `hooks.json` using
  `$CLAUDE_PROJECT_DIR`, which Codex leaves unset for plugin hooks — so they
  silently no-op under Codex unless mirrored here, where `run-hook.cmd` derives
  the repo root from its own location.
- **`run-hook.cmd`** — a **polyglot** wrapper (cmd.exe batch on Windows, bash on
  Unix) that fixes the three reasons the old hand-ported `.codex/hooks.json` did
  **not** block on Windows under Codex:
  1. **No `CLAUDE_PROJECT_DIR`.** Codex injects no `CLAUDE_PROJECT_DIR` for
     project hooks (plugin hooks get `CLAUDE_PLUGIN_ROOT`, not
     `CLAUDE_PROJECT_DIR`). The wrapper derives the repo root from its **own**
     location (`.codex/..`) and exports `CLAUDE_PROJECT_DIR` for the guardrail
     scripts.
  2. **Bare `bash` → WSL stub.** Via `cmd.exe`, bare `bash` resolves to
     `C:\Windows\System32\bash.exe` (the WSL stub — can't read `C:\`, exit 127).
     The wrapper finds **Git Bash** explicitly (`Program Files\Git`), and the
     PATH fallback skips any `\System32\` bash.
  3. **Exit 2 ≠ block under Codex.** himmel guardrails block by exiting 2 (Claude
     convention), but Codex blocks a tool call only on a JSON
     `permissionDecision:"deny"` on stdout — it ignores exit 2 (the tool would
     proceed). The wrapper delegates to `codex-hook-adapter.sh` (below) to bridge
     this.
  After finding Git Bash, the wrapper execs the adapter and propagates its exit
  code (`exit /b %ERRORLEVEL%` at top level — a bare `exit /b` inside a cmd
  `if (...)` block returns 0, not the child's code). If **no Git Bash** is found
  the wrapper **fails CLOSED** by emitting a JSON `deny` on stdout (an `exit 2`
  would fail *open* under Codex) with a loud reason — Git Bash is a hard
  dependency, so a missing-bash env is surfaced, never silently run unprotected.
- **`codex-hook-adapter.sh`** — the exit-code→JSON-decision bridge. Runs the
  named guardrail with the hook JSON on **stdin** (inherited untouched) and, when
  it exits 2 (block), re-emits the block as Codex's JSON
  `permissionDecision:"deny"` with the guardrail's stderr as the reason, exiting
  0. All other outcomes pass through (stdout decisions forwarded, exit code
  propagated). This keeps the guardrails single-sourced: they run verbatim under
  Claude Code, which never invokes the adapter.

## Tests
- `scripts/hooks/test-codex-run-hook.sh` — the Unix (bash) branch.
- `scripts/hooks/test-codex-run-hook.ps1` — the Windows (cmd.exe) branch.
Both assert: `CLAUDE_PROJECT_DIR` derived+exported, stdin forwarded, a non-block
exit code propagated, an **exit-2 block translated to a JSON `deny`** (stderr →
reason), missing-name → rc 2.

## Live-verified (codex-cli 0.141.0, Windows, HIMMEL-427)
Confirmed against a real `codex exec` run: `.codex/hooks.json` parses (no
`deny_unknown_fields` rejection), the guardrails **fire and block** —
`block-read-secrets` denies a secret read (`PreToolUse Blocked`), and a benign
command is allowed. The exit-2→`deny` translation in `codex-hook-adapter.sh` is
what makes the block land (Codex ignores exit 2). Caveats observed live:
- Codex runs hooks **inside the tool sandbox**; a `read-only` sandbox suppresses
  their side effects, so the interactive default (`workspace-write`) or wider is
  needed for them to act.
- Run from a git **worktree**, Codex loads project hooks from the **main
  checkout** (the worktree's `.git` is a file) — trust/edit hooks there.
- New project hooks are trust-hashed on first use; interactive Codex prompts to
  trust them once (non-interactive `codex exec` needs
  `--dangerously-bypass-hook-trust`).
See `docs/internals/harness-compat.md` §"Codex deep-dive → Hooks" for detail.

## codex-cli 0.142.0 note (HIMMEL-533)
Once the project hooks are **already trusted** (persisted from a prior
interactive trust, or this checkout's hooks already hashed), plain
`codex exec "<prompt>"` runs **without** `--dangerously-bypass-hook-trust` — the
flag is only the first-run / still-untrusted non-interactive path. (The flag
still exists in 0.142.0; this README's live-verified block above is 0.141.0.)
Skill discovery: Codex reads **project-local `.agents/skills/<name>/SKILL.md`**
from the run cwd — live-verified under 0.142.0 (HIMMEL-533 ships the himmel
driver skills there).
