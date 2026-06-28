---
name: shell-lint
description: Pre-emptive advisory shell lint (shellcheck + BOM + errexit-leak) on staged shell before commit. Use when the user asks to lint shell or run /shell-lint.
---

# shell-lint

When the user asks to lint shell, run:

    bash scripts/lint/shell-lint.sh --staged

To lint specific files instead of the staged set, pass paths:
`bash scripts/lint/shell-lint.sh <file...>`. Report each finding with its
file:line and the fix; if clean, say so.
