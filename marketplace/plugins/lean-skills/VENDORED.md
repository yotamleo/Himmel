# Vendored trees in lean-skills@himmel

Vendored-skill inventory for lean-skills@himmel (HIMMEL-3064).

NOT the check-plugin-drift.sh class-2 format (that parses ONE
upstream_repo/upstream_path/upstream_sha256 triple per plugin and would only
ever check one of the 13 files below). Upstream advance for this plugin is
detected at the RELEASE level instead, by two scripts/upstreams.json rows:

    superpowers-skills   obra/superpowers      synced_base 6.3.0
    mattpocock-skills    mattpocock/skills     synced_base 1.2.3

A release-level check is the right grain here because we vendor whole skill
DIRECTORIES (SKILL.md plus its companion prompts and scripts), not single
files: a per-file sha pin would need ~36 gh calls per run and would still
miss a companion file we had not enumerated. Neither row carries a
`version_pin`, so scripts/upstreams/apply-drift-bump.sh reports them SKIP
(manual) and never touches them — repair is a reviewed re-vendor, same
discipline as the luna-* bundled-asset rows. Bumping synced_base without
re-copying the trees would launder the signal this file exists to raise.

Everything below is copied VERBATIM. Do not edit vendored prose: a local
edit makes the next re-vendor a merge instead of a copy. himmel's own
framing lives in its CLAUDE.md and hooks, never inside a vendored SKILL.md.

vendored_from=obra/superpowers@6.3.0 path=skills/<name>

The 4 skills himmel actually invokes: brainstorming, writing-plans,
systematic-debugging, verification-before-completion — plus the 7 they hand
off to, pulled in to close the `superpowers:<name>` reference closure
(vendoring only the 4 leaves dangling cross-references): executing-plans,
finishing-a-development-branch, requesting-code-review,
subagent-driven-development, test-driven-development, using-git-worktrees,
writing-skills. DELIBERATELY NOT vendored (3 of 14): using-superpowers (its
SessionStart injection is the ~700 tok this change reclaims),
receiving-code-review, dispatching-parallel-agents — nothing vendored
references them.

vendored_from=mattpocock/skills@1.2.3 path=skills/productivity/grilling

grilling only. 0 of the plugin's 11 exposed skills were ever invoked in 1628
local transcripts; grilling reaches us through the minerva hook's
namespace-agnostic `*:grilling|grilling` matcher, which keeps routing the
bare vendored name. The upstream skill ships an agents/openai.yaml (Codex
interface metadata) that is dropped here as harness-specific.

local=skills/context7-mcp

himmel-authored, no upstream. Lived in ~/.claude/skills (always-on, and
per-skill enable/disable does not exist in Claude Code settings) — moved
here so a plugin profile can scope it.
