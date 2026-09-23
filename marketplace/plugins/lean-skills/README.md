# lean-skills — vendored subset of the skills himmel actually invokes

## Why this plugin exists

HIMMEL-3064 — measured over 1628 local Claude transcripts, three always-on
plugins carried ~2.2k tokens of skill/agent listing into EVERY session for
skills himmel barely invokes: `superpowers` (14 skills + a SessionStart
injection, 4 invocations ever), `plannotator-effective-html` (6 skills, 1
invocation), `mattpocock-skills` (11 skills, ZERO invocations). Per-skill
enable/disable does not exist in Claude Code settings — plugin membership is
the ONLY lever that scopes a skill to a profile. So the fix is: vendor the
skills we actually use into one himmel plugin, and stop enabling the fat
upstream plugins. `superpowers@claude-plugins-official` and
`mattpocock-skills@claude-plugins-official` are dropped from
`scripts/lanes/plugin-profiles.json`'s `catalog` entirely; `lean-skills@himmel`
is in `base`, so every non-`bare` lane/console profile gets it.
`plannotator-effective-html@himmel` is a separate case — see
[Not vendored: plannotator-effective-html](#not-vendored-plannotator-effective-html)
below.

## What is vendored, and from where

| Source | Skills vendored | Count |
|--------|-----------------|-------|
| [`obra/superpowers`](https://github.com/obra/superpowers) @ 6.4.1 | `brainstorming`, `writing-plans`, `systematic-debugging`, `verification-before-completion` (the 4 himmel invokes) plus `executing-plans`, `finishing-a-development-branch`, `requesting-code-review`, `subagent-driven-development`, `test-driven-development`, `using-git-worktrees`, `writing-skills` (the 7 they hand off to) | 11 of 14 |
| [`mattpocock/skills`](https://github.com/mattpocock/skills) @ 1.2.3 | `grilling` | 1 of 11 |
| himmel-authored, no upstream | `context7-mcp` (moved here from `~/.claude/skills` — always-on before per-skill toggling existed, so a plugin profile can scope it) | — |

13 skill directories total, replacing 25 (14 + 11) across the two upstream
plugins. Full per-source detail (including the upstream license each skill
inherits) lives in [`VENDORED.md`](VENDORED.md) — read that file before
touching anything under `skills/`.

## Why 11 of superpowers' 14, not the 4 himmel actually invokes

Vendoring only the 4 invoked skills would leave dangling
`superpowers:<name>` cross-references: `brainstorming` hands off to
`writing-plans`, which hands off to `subagent-driven-development` or
`executing-plans`, which hand off to `requesting-code-review` and
`finishing-a-development-branch`, and so on. The 11 vendored skills are the
**reference closure** of the 4 himmel invokes — every skill one of those 4
can hand off to, transitively. Vendoring fewer breaks the handoff chain
mid-flow; vendoring more (all 14) would re-import the cost this ticket exists
to cut.

**Deliberately NOT vendored (3 of 14):**

- `using-superpowers` — its SessionStart injection is the majority of the
  ~700 tok/session this change reclaims. It exists to bootstrap discovery of
  the other 13 skills at the start of every conversation; lean-skills doesn't
  need a bootstrap injection because its skills are discovered the normal
  Claude Code way (skill-name matching against the request).
- `receiving-code-review`, `dispatching-parallel-agents` — nothing vendored
  here references either one; neither is in the reference closure of the 4
  invoked skills.

### Not vendored: plannotator-effective-html

`plannotator-effective-html@himmel` (the HTML design/UI artifact kit: 6
skills) is **not** part of this plugin and is **not** vendored anywhere. It
stays its own plugin, gated behind the `design` profile in
`scripts/lanes/plugin-profiles.json` instead of riding the ALWAYS tier —
measured 1 invocation in 1628 transcripts against ~630 tok/session cost, so
design/UI work opts in per-dispatch (`--profile design` or the operator's own
`/profile enable`) rather than every session paying for it.

## Prose is copied VERBATIM — never edit it locally

Every file under `skills/` is copied byte-for-byte from its upstream release.
**Do not locally edit vendored prose** — not to fix a typo, not to adapt a
reference, not for any reason. A local edit turns the next re-vendor from a
straight copy into a manual merge, and the divergence is invisible until
someone diffs it by hand. himmel's own framing (why we vendor, what we
excluded, the duplicate-plugin rule) belongs in this README, in
`VENDORED.md`, and in himmel's `CLAUDE.md`/hooks — never inside a vendored
`SKILL.md`.

If a vendored skill needs to behave differently under himmel, the fix is a
hook or a CLAUDE.md rule that layers on top (see `inject-minerva-critic.sh`'s
namespace-agnostic `grilling` routing for a worked example), not an edit to
the copied file.

### Known limitation: vendored prose still cites `superpowers:<name>`

Several vendored `SKILL.md` files hand off to sibling skills using the
upstream plugin's own qualified name, e.g. `superpowers:test-driven-development`
(`executing-plans/SKILL.md`, `subagent-driven-development/SKILL.md`,
`systematic-debugging/SKILL.md`, `writing-skills/SKILL.md`). Those
`superpowers:` references cannot resolve in a `lean-skills`-only install —
`superpowers@claude-plugins-official` is exactly what this plugin replaces.

This is a **namespace-prefix mismatch, not a missing capability**: every
skill any of those references cites is vendored here, under the same
directory name, just as `lean-skills:<name>` instead of
`superpowers:<name>`; the bare `<name>` resolves too. Per the VERBATIM rule
above, the cited files are not locally edited to fix this, and an upstream
rename is not an option (obra/superpowers correctly names itself
`superpowers:`).

**Mitigation (HIMMEL-3100, himmel-owned, outside the vendored tree):**
`hooks/note-superpowers-prefix.sh`, a `PostToolUse(Skill)` hook wired by
`hooks/hooks.json`. When a lean-skills skill whose files cite `superpowers:`
loads, it adds one line of context — `superpowers:<x>` means
`lean-skills:<x>`. It reads the citing skills from the tree (no hard-coded
list, so a re-vendor cannot drift it) and is advisory and fail-open; set
`LEAN_SKILLS_PREFIX_HINT_DISABLE=1` in the launching shell to switch it off.

Why a hint on load and not a rewrite of the failing call: Claude Code rejects
`Unknown skill: superpowers:<x>` at validation time, before hooks run — neither
`PreToolUse` nor `PostToolUseFailure` fires for it (hooks docs), so the call
cannot be intercepted or remapped. Verified live (one headless haiku session
with temp settings and a stub logging hook): `PostToolUse` fires for
`lean-skills:systematic-debugging`.

`hooks/test-note-superpowers-prefix.sh` also asserts the closure — every
`superpowers:<name>` the vendored tree cites has a `skills/<name>/SKILL.md`
here — so a re-vendor that starts citing an unvendored skill fails the suite.

Not covered: `executing-plans/SKILL.md` also points at
`../using-superpowers/references/` (per-platform tool refs), which is not
vendored and has no lean-skills equivalent; that path just does not exist here.

### Known limitation: `brainstorming`'s server reports its own version as `unknown`

`brainstorming/scripts/server.cjs`'s `readSuperpowersVersion()` looks for a
manifest at `package.json` or `.codex-plugin/plugin.json` relative to the
skill root. Neither exists here — this plugin ships
`.claude-plugin/plugin.json` instead — so the function always returns
`'unknown'`, and a telemetry-enabled session shows "Superpowers vunknown".
Cosmetic only (no functional impact). Per the VERBATIM rule above, the
vendored script is not locally edited to fix this — tracked in HIMMEL-3106.

## Re-vendor procedure

1. Check upstream for a new release: `obra/superpowers` or `mattpocock/skills`
   (or `bash scripts/check-plugin-drift.sh` — see below).
2. Re-copy the relevant skill directories verbatim from the new release tag
   into `marketplace/plugins/lean-skills/skills/`, preserving the same
   subset rules above (the reference closure for superpowers; `grilling`
   only for mattpocock/skills — re-check whether a new release changed what
   the closure needs to include).
3. Update `VENDORED.md`'s `vendored_from=<repo>@<version>` lines to the new
   version.
4. Bump the matching `synced_base` in `scripts/upstreams.json` (rows
   `superpowers-skills` / `mattpocock-skills`) to the new version — **in the
   same commit as step 2**. Bumping `synced_base` without re-copying the
   trees launders the drift signal `check-plugin-drift.sh` exists to raise.
5. Skim the diff for anything that changes what himmel's own hooks reference
   by name (e.g. a skill rename) — `inject-minerva-critic.sh`'s `grilling`
   matcher and `himmel-ops:minerva`'s SKILL.md both name vendored skills.
6. Run `bash scripts/check-plugin-drift.sh` and confirm both rows report
   CURRENT.

## How drift is detected

**Release-level, not per-file.** This is a deliberate departure from the
class-2 `UPSTREAM_PIN` format `pr-review-toolkit-himmel` (above) uses — that
format parses exactly one `upstream_repo`/`upstream_path`/`upstream_sha256`
triple per plugin, and this plugin vendors 13 whole skill *directories*
(`SKILL.md` plus companion prompts/scripts), not one file. A per-file sha256
pin would need ~36 `gh api` calls per drift check and would still silently
miss a companion file nobody had enumerated. Instead, `scripts/upstreams.json`
carries two `tag_release`/`mode: base` rows:

```text
superpowers-skills   obra/superpowers      synced_base 6.4.1
mattpocock-skills     mattpocock/skills     synced_base 1.2.3
```

`bash scripts/check-plugin-drift.sh` reports BEHIND when the tracked repo's
latest release tag has moved past `synced_base`. Neither row carries a
`version_pin`, so `scripts/upstreams/apply-drift-bump.sh` reports them
**SKIP (manual)** and never touches them automatically — repair is always a
reviewed re-vendor (the procedure above), the same discipline the luna
bundled-asset rows use. Bumping `synced_base` by hand without re-copying the
trees would make the tracker lie about what's actually shipped.

## The duplicate rule: if an adopter re-enables the upstream plugin

lean-skills is only a win while `superpowers@claude-plugins-official` and
`mattpocock-skills@claude-plugins-official` stay disabled. If an adopter
enables one of them ALONGSIDE `lean-skills@himmel`, both copies of the
overlapping skills get listed every session — worse than either arrangement
alone, and the two same-named skills drift apart as upstream moves while
himmel's copy stays frozen at `synced_base`.

**Resolution rule: the upstream plugin wins.** It's the live source, kept
current by upstream; himmel's vendored copy is a frozen release snapshot.
Prefer disabling the vendored skills (or the whole upstream plugin) rather
than trying to reconcile two copies.

This is enforced by a detector, not just documented:
`scripts/lanes/vendored-skill-dupes.mjs` (`--json` for machine output; exit
0 no overlap, 10 overlap found, 2 an unreadable settings layer) walks the
effective-enabled plugin set across every `.claude/settings.json` /
`settings.local.json` layer and reports which vendored skills collide with
which enabled upstream plugin. `himmel-doctor`'s `C37-vendored-skill-dupes`
check runs it advisory-only (WARN on overlap, never FAIL) as part of a normal
`bash scripts/himmel-doctor.sh` pass.

## Files

- `.claude-plugin/plugin.json` — plugin manifest (name: `lean-skills`).
- `skills/` — the 13 vendored skill directories, copied verbatim (see table
  above). Never edit these by hand.
- `VENDORED.md` — the machine-readable-ish inventory: which skill came from
  which upstream release, and why the 3 superpowers skills and the 10
  mattpocock/skills skills were left out.
- `LICENSE.superpowers`, `LICENSE.mattpocock-skills` — upstream licenses,
  carried forward per source.
- `README.md` — this file.

## License

`LICENSE.superpowers` and `LICENSE.mattpocock-skills` carry the respective
upstream licenses forward for the skills sourced from each. `context7-mcp`
is himmel-authored (MIT, matching this plugin's own `plugin.json`). See
`VENDORED.md` for the per-skill upstream attribution.
