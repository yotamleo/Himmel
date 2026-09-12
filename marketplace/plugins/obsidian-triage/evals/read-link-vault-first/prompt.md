---
max_turns: 10
allowed_tools: [Bash, Glob, Grep, Read, WebFetch, Skill]
tags: [smoke, red-control]
---

/obsidian-triage:read-link https://example.com/deep-dive-article

Note: the vault for this session is not at the default location — it lives
at `./vault-fixture` (relative to your working directory). Pass
`--vault ./vault-fixture` to the lookup CLI in step 1.
