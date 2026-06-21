# AGENTS.md

This repository's rules, repo map, and workflows live in
**[CLAUDE.md](CLAUDE.md)** — the single source of truth for every coding
agent that works here (Claude Code, Codex, and any other tool that reads
`AGENTS.md`).

This file is intentionally a thin pointer, not a copy, so the two can never
drift. **Read [CLAUDE.md](CLAUDE.md) first.**

> Codex compatibility — what fires under Codex, and what's ported vs accepted
> — is documented in
> [`docs/internals/harness-compat.md`](docs/internals/harness-compat.md)
> (HIMMEL-427). In short: the git-level gates (pre-commit/pre-push) fire under
> any harness, but the in-session PreToolUse guardrails and the rule file itself
> need ports (tracked under epic HIMMEL-470) — Codex reads this `AGENTS.md`, not
> `CLAUDE.md`, so until HIMMEL-471 generates a real rule file here, treat
> himmel's structural guardrails as Claude-Code-validated only.
