# v2 Frontmatter Schema

Every `master-plan.md` (epics), `brief.md` (tasks, standalones), and `context.md` (epics) carries v2 frontmatter. Other per-item files (`bugs.md`, `reviewer-notes.md`, `extra-rules.md`, `plan.md`, `next-session-*.md`) carry only `template_version`.

## v2 frontmatter block

```yaml
---
template_version: 2
jira: HIMMEL-69                    # Jira key; "—" when no Jira (offline / no-Jira repo)
bucket: now                        # one of: now, next, later, someday
                                   #   (or kanban synonyms: wip, next-up, backlog, icebox)
priority: Highest                  # mirrors Jira priority: Highest | High | Medium | Low | Lowest
severity: —                        # mirrors Jira severity; "—" when not applicable
created: 2026-05-19T22:55:00Z      # UTC ISO 8601
updated: 2026-05-19T22:55:00Z      # UTC ISO 8601
pending_jira_link: false           # true while offline-fallback queue is open
---
```

## Field rules

- `jira`: written by the skill when `new-*` succeeds in creating a Jira issue. Set to `—` (em dash) when no Jira project is configured or `jira create` failed (in which case `pending_jira_link: true`).
- `bucket`: never empty; defaults to the per-repo `defaults["new_*.bucket"]` or asks the user. Internal storage uses the bucket name from the active `bucket_vocab`; switching vocabs is purely cosmetic at display time.
- `priority` and `severity`: mirrored from Jira on `update-status`, `new-*`, `end-session`. User edits to the frontmatter are pushed back to Jira on the next mutation (last-modified-wins; compare file mtime vs Jira `updated`).
- `created` and `updated`: UTC ISO-8601 with seconds (`%Y-%m-%dT%H:%M:%SZ`). Use `date -u +"%Y-%m-%dT%H:%M:%SZ"`.
- `pending_jira_link`: cleared when `/handover jira-link` succeeds.

## Per-file frontmatter (other files)

```yaml
---
template_version: 2
---
```

That's the entire frontmatter — only the version. Bumped from 1 to 2.

## Migration / mismatch behaviour

Parsers read `template_version` first. On mismatch with the skill's current version (1 vs 2), emit a stderr warning of the form `WARN: handover/<path>: template_version=1 (skill expects 2). Run /handover migrate to upgrade.` and proceed. v1 items remain readable until the migration script runs.
