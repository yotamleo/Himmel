# AGENTS.md

This repository's rules, repo map, and workflows live in
**[CLAUDE.md](CLAUDE.md)** — the single source of truth for every coding
agent that works here (Claude Code, Codex, and any other tool that reads
`AGENTS.md`).

This file is intentionally a thin pointer, not a copy, so the two can never
drift. **Read [CLAUDE.md](CLAUDE.md) first.**

> Codex-specific compatibility — whether himmel's PreToolUse hooks and
> pre-commit/pre-push gates actually fire under Codex — is tracked in
> HIMMEL-427. Until that audit lands, treat himmel's structural guardrails as
> Claude-Code-validated only.
