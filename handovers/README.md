# himmel/handovers/

This directory hosts handover state belonging to **himmel** specifically
(HIMMEL-XX epics, tasks, and standalones). Per the v2 handover skill's
multi-repo model (`marketplace/plugins/handover/skills/handover/SKILL.md`),
per-repo state lives inside the repo it belongs to and is discovered via
the `~/.claude/handover/registry.json` registry.

## Layout

```
handovers/<USER_SLUG>/   # owner-scoped tree
  status.md              # auto-regenerated session status (do not hand-edit)
  counter.md             # next-id counter for new epics/tasks/standalones
  epics/<ID>-*/          # multi-session work items (<ID> = Jira key, e.g. HIMMEL-42, or #N when offline)
  standalones/<ID>-*/    # single-session items (same <ID> convention)
  _templates/            # files copied by `/handover new-*` commands
```

`<USER_SLUG>` is resolved by `scripts/lib/user-slug.sh` (the `USER_SLUG`
env var, falling back to a slugified `git config user.name`).

## Splitting cross-project state into an external repo (optional)

A common setup keeps **per-repo** handover state inline (here, under
`handovers/`) while moving **cross-project** content (templates,
cross-cutting notes, ad-hoc capture buckets) into a separate external
handover repo — e.g. a dedicated `<your-handover-repo>/handovers/` tree.

To point the resolver at an external repo, register it with the v2
handover skill (`/handover register <repo>`) or set Mode B
`HANDOVER_DIR=/path/to/<your-handover-repo>/handovers` in the shell that
launches Claude Code. The registry-based path is preferred (multi-repo,
no global env var).

## HANDOVER_DIR resolver (HIMMEL-118)

`scripts/lib/handover-path.sh` provides a single-root resolver:

- Mode A (default): `HANDOVER_DIR` unset → root is `<himmel-repo>/handovers/`.
- Mode B (external): `HANDOVER_DIR` set → root is that path (e.g. an
  external handover repo's `handovers/` tree).

The v2 handover skill's registry-based resolution is the **preferred**
path now (multi-repo, no global env var), but HANDOVER_DIR is kept
working for scripts (auto-commit, arm-resume, setup checks) that
still rely on it. See the "Handover System" section in CLAUDE.md for
the full picture.
