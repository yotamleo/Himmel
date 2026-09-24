# Third-Party License Audit (HIMMEL-2185)

Pre-tag blocker for `v1.0.0-pre` (HIMMEL-297 sequence: himmel targets MIT).
Covers every tracked `package.json` in the repo (`git ls-files "*package.json"
| grep -v node_modules`, `node_modules` excluded) — 16 manifests, 19 unique
npm deps including devDependencies. **Scope: direct dependencies only**
(the ticket's own measured surface) — the transitive tree (e.g. everything
`@modelcontextprotocol/sdk` or `playwright` pulls in) was NOT walked or
audited; a permissive direct dependency can still depend on a copyleft
transitive, so this scope limitation is a real gap, not a cleared risk, and a
future pass should run `license-checker` (or equivalent) over the full
resolved tree if that risk needs closing before release.
"Compatible" = a permissive, no-copyleft-obligation license: MIT/BSD-2/BSD-3/
Apache-2.0/ISC/0BSD/Unlicense, or another license that is verified
case-by-case to be equally or more permissive (the one instance — `left-pad`'s
WTFPL — is called out explicitly below rather than silently folded in).

## Verdict

**All 19 npm deps are MIT-compatible. Zero FLAGs.** One informational note
(left-pad/WTFPL, test-fixture-only, never installed or shipped — see below).

## SBOM

| Dep | Version declared → **locked** | License | Manifest(s) | Runtime/Dev | Verdict |
|---|---|---|---|---|---|
| `@modelcontextprotocol/sdk` | `^1.0.0` → **1.29.0**; `^1.29.0` → **1.30.0** | MIT | marketplace/plugins/luna-correlate, marketplace/plugins/telegram-himmel, scripts/jira | runtime | COMPATIBLE |
| `commander` | `^15.0.0` → **15.0.0**; `9.4.1` (T6 fixture, exact, no lockfile) | MIT | scripts/bitbucket, scripts/himmel-run, scripts/jira, scripts/lanes/bench/fixtures/T6/.../tools/codegen/scripts | runtime | COMPATIBLE |
| `@coderabbitai/bitbucket` | `^1.1.4` → **1.1.4** | Apache-2.0 | scripts/bitbucket | runtime | COMPATIBLE |
| `env-paths` | `^4.0.0` → **4.0.0** | MIT | scripts/himmel-run | runtime | COMPATIBLE |
| `proper-lockfile` | `^4.1.2` → **4.1.2** | MIT | scripts/himmel-run | runtime | COMPATIBLE |
| `grammy` | `^1.21.0` → **1.44.0** | MIT | marketplace/plugins/telegram-himmel | runtime | COMPATIBLE |
| `js-yaml` | `5.3.0` → **5.3.0** | MIT | marketplace/plugins/obsidian-triage/tools | runtime | COMPATIBLE |
| `playwright` | `1.62.1` → **1.62.1** | Apache-2.0 | marketplace/plugins/obsidian-triage/tools | runtime | COMPATIBLE |
| `left-pad` | `1.1.0` (exact, T6 fixture only, no lockfile) | WTFPL | scripts/lanes/bench/fixtures/T6/input (+3 workspace packages) | runtime (fixture) | COMPATIBLE — see note |
| `chalk` | `4.1.2` (exact, T6 fixture only, no lockfile) | MIT | scripts/lanes/bench/fixtures/T6/input | runtime (fixture) | COMPATIBLE |
| `react` | `18.2.0` (exact, T6 fixture only, no lockfile) | MIT | scripts/lanes/bench/fixtures/T6/.../examples/demo-app | runtime (fixture) | COMPATIBLE |
| `lodash` | `4.18.1` (exact, T6 fixture only, no lockfile) | MIT | scripts/lanes/bench/fixtures/T6/.../packages/core | runtime (fixture) | COMPATIBLE |
| `@types/node` | `^26.2.0` → **26.2.0**; `^26.1.0` → **26.1.0** | MIT | scripts/bitbucket, scripts/ci-orchestrator, scripts/himmel-run, scripts/jira | dev | COMPATIBLE |
| `typescript` | `^7.0.2` → **7.0.2**; `^6.0.3` → **6.0.3** | Apache-2.0 | marketplace/plugins/claude-hud, marketplace/plugins/luna-correlate, scripts/bitbucket, scripts/ci-orchestrator, scripts/himmel-run, scripts/jira | dev | COMPATIBLE |
| `vitest` | `^4.1.11` → **4.1.11**; `^4.1.9` → **4.1.9** | MIT | plugins/himmel-gh, plugins/himmel-jira, scripts/bitbucket, scripts/ci-orchestrator, scripts/himmel-run, scripts/jira | dev | COMPATIBLE |
| `c8` | `^11.0.0` → **11.0.0** | ISC | marketplace/plugins/claude-hud | dev | COMPATIBLE |
| `bun-types` | `^1.3.14` → **1.3.14** | MIT | marketplace/plugins/luna-correlate | dev | COMPATIBLE |
| `@types/bun` | `latest` → **1.3.14** | MIT | scripts/luna-vitals | dev | COMPATIBLE |
| `@types/proper-lockfile` | `^4.1.4` → **4.1.4** | MIT | scripts/himmel-run | dev | COMPATIBLE |

**Methodology:** every manifest here has a committed lockfile
(`package-lock.json` or `bun.lock`) — the **locked** column is the exact
version pinned in that manifest's own lockfile (read directly from it, e.g.
`.packages['node_modules/<dep>'].version` in `package-lock.json`), which is
what a clean `npm ci` / `bun install` actually installs — the deterministic,
release-accurate answer, not a registry snapshot or local `node_modules`
state (both of which were independently found stale or drifted from the
lockfile in several spots during this audit, e.g. `js-yaml`'s locally
installed `5.0.0` vs. the lockfile's `5.3.0`). The four T6 benchmark-fixture
packages have no lockfile (they are synthetic prompt data, never installed —
see the fixture note below) and keep their exact declared pin. Every locked
version's license was independently confirmed via `npm view
<dep>@<locked-version> license` and matches what's shown — no dependency's
license differs across the version deltas observed in this audit.

### Note on `left-pad` / WTFPL

`left-pad@1.1.0` only appears in `scripts/lanes/bench/fixtures/T6/` — a
synthetic benchmark fixture (`prompt.md` in that dir: "bump left-pad from
1.1.0 to 1.3.0") used to test the lanes tooling's ability to edit a monorepo.
It is never installed (no `node_modules/left-pad` anywhere in the repo) and
never shipped. WTFPL is a public-domain-equivalent license (no attribution,
no copyleft, more permissive than MIT) but isn't one of the named compatible
license classes, so it's called out here rather than silently folded into
COMPATIBLE. No action needed — it's fixture data, not a real dependency.

## Bundled-artifact exposure

`scripts/jira/dist/` (the Jira/Confluence CLI build output) is **untracked**
today — `npm run build` (`tsc`) output, not committed, not distributed. `tsc`
transpiles only `jira-cli`'s own TypeScript; it does not bundle or inline
`node_modules`, so `dist/` itself contains no third-party dependency code and
triggers no attribution obligation as-is (it still requires `node_modules` at
runtime to actually run). Attribution only becomes a live question if a
FUTURE change bundles the CLI (e.g. an esbuild/pkg step that inlines
`node_modules` into a standalone distributable) — at that point the audit
would need to cover the **full resolved transitive tree** of whatever gets
inlined, not just the two direct runtime deps. Today those direct runtime
deps are `@modelcontextprotocol/sdk` (MIT) and `commander` (MIT) — both
permissive, no NOTICE obligation — but that list is a starting point for a
future bundling audit, not a substitute for one; see the transitive-tree gap
noted above. `@types/node`, `typescript`, `vitest` are devDependencies used
only for type-checking, compiling, and testing — the CLI's runtime source
never `import`s them — so a bundler that follows actual reachable imports
from the entry point (rather than being told to include them explicitly)
would not pull them in; being a devDependency doesn't by itself guarantee
exclusion from a bundle, correct usage does.

## Vendored skill: `unslop` (MIT, Lauren Tan)

Added HIMMEL-3115 (2026-09-17), the first single-file skill vendored outside
`marketplace/plugins/*`. Lives at `.claude/skills/unslop/SKILL.md`, sourced
from `cursor/plugins` (pstack) at pinned commit
`e8d856f0273b42ebafe0ec3546bd645709e7c1b0`, path
`pstack/skills/unslop/SKILL.md`. No `node_modules`/npm involvement — a
single vendored markdown file, MIT-licensed. Decision record:
[`tool-adoption/adr-unslop-skill.md`](tool-adoption/adr-unslop-skill.md).

MIT License text as it appeared at that commit
(`pstack/LICENSE`), reproduced here per the license's own attribution
requirement:

```
MIT License

Copyright (c) 2026 Lauren Tan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Vendored skill: `test-audit` (MIT, OpenClaw Foundation)

Added HIMMEL-3580 (2026-09-24). Lives at `.claude/skills/test-audit/`
(`SKILL.md` adapted, with its deviations listed in its own header;
`CAMPAIGN.md` verbatim), sourced from `openclaw/openclaw` at pinned commit
`1370643e394f956dfae2e42f43ee030b0072434b`, path
`.agents/skills/test-audit/`. The GitHub API reports the repo licence as
`NOASSERTION` because the `LICENSE` file carries a trailing third-party-notices
line; the file itself is the MIT text. No `node_modules`/npm involvement.

MIT License text as it appeared at that commit (`LICENSE`), reproduced here
per the license's own attribution requirement:

```
MIT License

Copyright (c) 2026 OpenClaw Foundation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Non-npm sweep (marketplace/plugins + scripts)

- Every `marketplace/plugins/*` plugin with a `LICENSE` file declares MIT
  (`claude-hud` — fork, upstream copyright by Jarrod Watts, preserved per
  convention; `handover`, `himmel-ops`, `obsidian-triage`, `qmd` — MIT) or
  Apache-2.0 (`pr-review-toolkit-himmel`, `telegram-himmel` — both also carry
  a `NOTICE` file). All compatible with an MIT-top-level project.
  `luna-correlate` has no separate `LICENSE` (first-party, no fork lineage;
  inherits the repo root license).
- `rg`-style sweep for `copyright` / `SPDX-License` headers and
  vendored/copied-snippet markers across `marketplace/plugins/` and
  `scripts/` (excluding `node_modules`, `dist/`) found no third-party
  license headers outside the plugin `LICENSE`/`NOTICE` files above. The
  "vendored" hits that turned up (e.g. `scripts/hooks/wire-plugin-hook-bash.mjs`,
  `scripts/lib/wire-statusline.sh`) are internal cross-copies of himmel's own
  files (byte-identical duplicates shipped inside a plugin so it's
  self-contained) — not third-party code, no separate attribution needed.
