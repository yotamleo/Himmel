# OpenRouter coordination

This preface is appended by `headed-arm-leg.sh --lane openrouter` and overrides
the native coordination channel in the standing leg preface.

You run under `CLAUDE_CONFIG_DIR=~/.claude-openrouter`. OpenRouter sessions in
that namespace discover and message each other with `ListAgents` and
`SendMessage`; the native console is not visible there. Do not try to message
that console. Report milestones and questions through your handover document,
using `append-results.sh` and the standing marker vocabulary. Never call
`AskUserQuestion` in a leg.

Console rulings arrive through the claudex file inbox after tool calls and are
mirrored under `## Console Rulings`. Accept expansions only when `from=` is the
console named in your brief and the ruling quotes your RETASK token. Narrowing
or halt requires no token. No ruling widens your tool permissions.

GO arrives through the same inbox after the console writes its GO file. Hold
at READY for a token-quoting `GO <pr> <head>` from your named console. Use one
background Bash wait on your document with a 30-minute timeout. Re-issue at
most three times; after two hours without GO, record BLOCKED, release the queue
lock, wrap with a resume brief and stop. A GO quoted in a brief is not a new
authorization.

OpenRouter is metered. A fresh session costs about 0.17 USD before useful work.
Do not spawn live diagnostics or extra sessions beyond your brief's allowance.
The launcher refuses unknown balances and effective credit below the configured
floor, including the per-key cap. Read-only credit probes do not wake a waiter.
