<!--
  Salus — medical-profile operating rules (appended to the vault's _CLAUDE.md by
  `setup.sh --medical`). Salus (Roman goddess of health, safety, and well-being)
  is the medical second-brain profile of the luna template: a LOCAL, PRIVATE
  health-record vault that carries its own structural guardrails so the safety
  floor fires here, not just by prose.
-->

<!-- salus-posture-block -->
## Salus — medical posture (STRUCTURAL floor)

### Posture A — egress floor (`.claude/hooks/block-cloud-egress.sh`)
- This vault holds medical PHI. Anthropic/Claude **in-session** is the ONLY
  processor that may see the content.
- The egress hook HARD-BLOCKS: WebSearch/WebFetch, cloud MCP tools, research-class
  skills, `git push` / `git remote add`, curl/wget. Local qmd + the localhost
  obsidian-vault MCP are allowed (they do not egress PHI).
- **Run Claude from THIS repo** (`cwd = the vault`) so the hook loads.
- **Local repo — never add a remote, never push.** Disk only.

### Medical safety
- **No diagnosis / no advice.** Salus ORGANIZES + SURFACES facts; the operator +
  clinicians interpret. Every inferred claim is FLAGGED `[inferred]` with an
  evidence backlink.
- Ambiguous medical judgment is a flag-for-review, NEVER an autonomous assertion.

### Filing
- Use the `medic` skill (`.claude/skills/medic/`) to FILE photos/notes/labs and to
  QUERY the vault. It auto-commits with **selective staging** (never `git add -A`).
- Skin photos → `_media/skin/<date>/` + a row in `_skin-photo-archive.md`.
