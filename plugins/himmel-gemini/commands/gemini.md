---
allowed-tools: Bash(bash:*)
description: Run gemini-cli synchronously via the invoke.sh chokepoint and return its stdout. Forwards --model / --json / --yolo.
argument-hint: "<prompt> [--model <name>] [--json] [--yolo]"
---

> **Note (Windows):** the body shells out via Git Bash. Claude Code's `Bash`
> tool invokes Git Bash on Windows — works as long as Git Bash is on PATH
> (it is when this repo's `setup/win11.ps1` ran successfully).

## Your task

Run gemini-cli on the user's prompt through the shared chokepoint and return
its stdout to the user. Auth, model defaults, and flags are resolved inside
`invoke.sh` — do not call `gemini` directly.

Pass the user's prompt as the positional argument. Forward `--model <name>`,
`--json`, and `--yolo` through to `invoke.sh` only if the user asked for them.

```
bash $CLAUDE_PROJECT_DIR/scripts/gemini/invoke.sh "$ARGUMENTS"
```

Return the full stdout from `invoke.sh` verbatim. It exits with gemini-cli's
return code; if it is non-zero, surface the error output to the user.
