# himmel/docs/luna/

Reference docs for himmel features that touch the Luna Obsidian vault.

Per the luna-area docs convention locked 2026-05-25 (HIMMEL-138 +
`CLAUDE.md` "Luna-area docs convention" section): operator-facing
reference docs (guides, runbooks, architecture) for luna-touching
features in this repo live here. Personal-state work artifacts
(handovers, decision logs, journal entries) live in `yotam_docs`.

## Contents

- [`end-session-wiki.md`](end-session-wiki.md) — User guide for the
  `SessionEnd` hook that auto-captures every Claude Code session as
  a structured note in the Luna vault. Opt-out, dry-run, repo-config.
- [`end-session-wiki-schema.md`](end-session-wiki-schema.md) —
  On-disk schema for session notes the hook writes.

## Where things go

| Artifact | Lives in |
|---|---|
| Luna-touching reference docs for himmel | `himmel/docs/luna/` (here) |
| Luna repo's own reference docs | `luna/docs/` |
| luna_brain reference docs (OSS-bootstrap-ready) | `luna_brain/docs/` |
| Plugin specs | `plugins/<plugin>/README.md` |
| Handovers / work logs / decision journals | `yotam_docs/handovers/<USER_SLUG>/<repo-bucket>/` |
| Luna vault content (clips, human notes) | luna vault itself (unchanged) |
