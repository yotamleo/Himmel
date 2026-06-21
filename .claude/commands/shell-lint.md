---
description: Pre-emptive advisory shell lint — run shellcheck + UTF-8 BOM + errexit-leak checks on staged shell (or named files) BEFORE the commit attempt, so the loop fixes issues instead of bouncing off the pre-commit gate (HIMMEL-478).
---

Pre-emptive shell lint (HIMMEL-478, C4 of the autonomy-resilience epic). Run it
on a worktree branch **before `git commit`** whenever the branch changes shell
scripts, so issues are fixed up front instead of bouncing off the real
pre-commit gate mid-run. The authoritative gate (`.pre-commit-config.yaml`)
stays the source of truth and is unchanged — this is additive and runs earlier.

Lean-invoke by design (HIMMEL-177): a fast advisory step the autonomous loop (or
the operator) runs on demand, not an always-on hook. It only reports — it never
modifies files.

What it checks per shell file:
- **[BOM]** — a UTF-8 byte-order mark at the file start (breaks the shebang; the
  gate's shellcheck flags it as SC1082).
- **[errexit]** — `set -e` / `-eu` / `-euo` / `-o errexit` in the prologue;
  errexit leaks into a sourcing shell, so himmel uses `set -uo pipefail`.
- **[shellcheck]** — the same linter the pre-commit gate runs (when installed).
  Caveat: it uses the **locally-installed** shellcheck; if that version differs
  from the gate's pinned `shellcheck-py` (`.pre-commit-config.yaml`), a minor-
  version heuristic (e.g. SC2015) can differ. The gate stays authoritative.

Steps:

1. Lint the staged shell files (the common case before a commit):

   ```bash
   bash scripts/lint/shell-lint.sh --staged
   ```

   Or lint explicit files:

   ```bash
   bash scripts/lint/shell-lint.sh path/to/script.sh another.sh
   ```

2. Exit code: `0` = clean, `1` = findings (each reported with file + line), `2` =
   usage error. On findings, fix them in the worktree and re-run until clean,
   then proceed to `git commit` (the pre-commit gate will pass first-try).
