# Buckets — Vocab, WIP, and Transitions

## Two axes both called "bucket"

The handover skill uses the word "bucket" for **two orthogonal axes** — keep
them distinct:

1. **Source-repo bucket** — *which directory* an item lives in under
   `<state-root>` (`himmel/`, `luna/`, `luna_brain/`, `cross/`, and any
   `source_buckets_extra` like `luna-medic/`). HIMMEL-129 layer; governed by
   SKILL.md "Bucket Resolution" + the `source_buckets_extra` field (HIMMEL-307).
   **This file does NOT govern that axis.**
2. **Time-horizon bucket** — the frontmatter `bucket:` value
   (`now/next/later/someday`, or the kanban/`buckets_custom` names) that drives
   roadmap grouping. **This file governs THIS axis** (the index + vocab + WIP
   rules below).

The two name-sets are disjoint, which is what lets `/handover bucket <id>
<bucket>` dispatch by name to the right axis (see SKILL.md). `buckets_custom`
renames axis 2 only; it cannot add a source bucket.

## Bucket index

| Index | Time-horizon (default) | Kanban (alt) | Meaning |
|---|---|---|---|
| 0 | now | wip | actively being worked |
| 1 | next | next-up | queued for next pickup |
| 2 | later | backlog | planned, not scheduled |
| 3 | someday | icebox | parking lot |

Per-repo `bucket_vocab` registry field picks display names. Storage in frontmatter uses the active vocab's name (e.g. `bucket: now` or `bucket: wip`). Vocab switch is cosmetic — when reading, accept either name and map to index.

## Custom vocab

`buckets_custom` in registry overrides the 4-element name list, e.g. `["doing", "queued", "soon", "parked"]`. Order must match the 0..3 index.

## WIP rule

WIP (bucket 0) is **never enforced as a hard limit**. The skill never refuses or blocks a bucket transition — that hangs sessions. On a new wip transition for item X:

```
1. Scan all items with bucket-index == 0 in target repo (the "current wip set").

2. Detect context:
   a. PR-merged on a current wip item?
      → silently bump that item to bucket 1 (next-up) or, if status is done,
        leave it but exclude from wip. Set X to wip. No prompt.
   b. X is a child task of a current-wip epic?
      → silently allow coexistence. No prompt.
   c. Parallel-dispatch context active (recent Task tool invocation
      within the same session)?
      → silently allow coexistence. No prompt.
   d. None of the above and current wip set is non-empty?
      → soft prompt via AskUserQuestion:
          "<current wip> already in wip. Move X to wip too?"
          [1] Bump <current> → next-up, set X = wip (Recommended)
          [2] Keep both in wip
          [3] Cancel
        Default if the user dismisses or AskUserQuestion is unavailable:
        option 1 (auto-bump).

3. Write the bucket change to X's frontmatter and update sync.log.
```

## Bucket transitions are surfaceable

Every bucket move (via `/handover bucket <id> <bucket>`, end-session auto-bump, or migration) appends to `sync.log` (UTC ts, item id, from-bucket → to-bucket, trigger).
