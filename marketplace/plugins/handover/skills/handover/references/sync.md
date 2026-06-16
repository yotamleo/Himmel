# Jira Sync — Bidirectional, Last-Modified-Wins

## When sync runs

- `update-status` — full pass over every tracked item
- `new-epic`, `new-task`, `new-standalone` — sync the new item after creation
- `end-session` — sync the target item

Bucket transitions, slug renames, and migration script runs all also trigger a sync of the touched items.

## Direction of writes

The skill is the agent. Each sync pass:

1. **READ from Jira:** `jira get <key>` returns `{ priority, severity, status, updated }`.
2. **READ from filesystem:** the item's frontmatter + file mtime of `master-plan.md` or `brief.md`.
3. **Compare:** if `priority` or `severity` differs:
   - file `mtime > Jira.updated`  → WRITE to Jira via `jira edit <key> --priority P --severity S`
   - file `mtime < Jira.updated`  → WRITE to file (mirror)
   - file `mtime ≈ Jira.updated`  → file wins by convention (skill is authoritative for the active session)
4. **Append to sync.log** — every write, even mirrors:
   ```
   2026-05-19T22:55:00Z  HIMMEL-69  priority  H→M  trigger=update-status
   ```

## Skipped during offline

If `jira get` throws (network error / token expired), the item is skipped for this sync pass — never error out the parent command. The sync resumes on the next successful command.

## Pending-link items

Items with `pending_jira_link: true` are skipped entirely (no Jira key to sync). They appear in `tech-debt.md` until `/handover jira-link <id>` upgrades them.

## sync.log format

Append-only, UTC ISO-8601 timestamp + tab-separated columns:

```
<UTC-iso8601>\t<jira-key>\t<field>\t<old>→<new>\t<trigger>
```

Trigger values: `update-status` | `new-epic` | `new-task` | `new-standalone` | `end-session` | `bucket-move` | `migrate` | `jira-link`.

The log is not rotated automatically. `/handover hygiene analyse` includes a check for `sync.log` size and flags >1MB as worth archiving.
