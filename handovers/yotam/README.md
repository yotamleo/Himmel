# himmel/handovers/`<USER_SLUG>`/ — example owner-scoped stub

This is the owner-scoped handover tree for a single user. The directory
name is the operator's `<USER_SLUG>` (resolved by
`scripts/lib/user-slug.sh` — the `USER_SLUG` env var, falling back to a
slugified `git config user.name`). The concrete directory name you see in
this checkout is just the example slug it resolved to; in your setup it
will be your own `<USER_SLUG>`.

A common setup keeps only **generic, per-repo** content inline here and
moves active personal state (ticket queues, standalones, epics, status,
backlog, roadmap, tech-debt) into a separate external handover repo. In
that case this directory stays near-empty and exists only as a backstop
for scripts that hardcode `handovers/<USER_SLUG>/` resolution.

## Where handover state lives

When state is split into an external handover repo, the structure
mirrors this layout:

| Need | Location (external handover repo) |
|---|---|
| Active next-session resume | `handovers/<USER_SLUG>/next-session-resume.md` |
| Standalone tickets (HIMMEL-N) | `handovers/<USER_SLUG>/himmel/standalones/HIMMEL-N-<slug>/` |
| Standalone tickets (per-repo, e.g. LUNA-N) | `handovers/<USER_SLUG>/<repo>/standalones/<KEY>-N-<slug>/` |
| Epics (HIMMEL-N) | `handovers/<USER_SLUG>/himmel/epics/HIMMEL-N-<slug>/` |
| Templates | `handovers/<USER_SLUG>/_templates/` |
| Backlog / roadmap / status | `handovers/<USER_SLUG>/{backlog,roadmap,status,tech-debt}.md` |
| Daily / overnight summaries | `handovers/<USER_SLUG>/overnight-summary-*.md` |
| Counter (offline-fallback) | `handovers/<USER_SLUG>/counter.md` |

A per-repo bucket layer (`<USER_SLUG>/<repo>/{epics,standalones}/`) routes
items by ticket prefix and is opt-in — active whenever any bucket dir
exists. The v2 handover skill
(`marketplace/plugins/handover/skills/handover/SKILL.md`) walks
`<state-root>/<repo>/{epics,standalones}/` when buckets are present.

## Backstop note

Script call sites that hardcode `<repo>/handovers/<USER_SLUG>/` —
`scripts/lib/handover-path.sh` (single-root resolver), the v2 handover
skill, and `~/.claude/handover/registry.json` — each resolve through the
`<USER_SLUG>` layer. Keep this directory in place so those consumers have
a valid path even when active state lives in an external repo.
