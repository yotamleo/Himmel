# claude-hud — vendored fork (himmel)

This directory is a **vendored copy** of a fork of
[`jarrodwatts/claude-hud`](https://github.com/jarrodwatts/claude-hud) (MIT),
used by himmel as the statusline **renderer** (HIMMEL-718). himmel wires it as a
single `node` process — `node <this-dir>/dist/index.js` — replacing the legacy
vendored bash statusline (supersedes HIMMEL-331 + the 2026-05-16 cache patch).

Upstream `LICENSE` is retained verbatim. This is **not** a source of upstream
contributions; it exists so himmel controls the pin and can carry a small delta.

## Pin record (machine-readable — do not hand-edit the hash)

```
fork_repo:            https://github.com/yotamleo/claude-hud   # public fork (HIMMEL-718)
upstream_repo:        https://github.com/jarrodwatts/claude-hud
pinned_commit:        939eb66485832dead1b0a28a954f76f7aa2bdb06  # main HEAD (HIMMEL-2274, issue #518)
pinned_upstream_tree: a9f550fa2eee50682133bc654caaa8a951cf3483  # git tree of pinned_commit (provenance)
vendored_tree_hash:   5cfecacb09d70aae86c682f380f1271398ee41e08cabdcd4cc503783fe16d4eb  # sha256 over VENDORED.manifest
vendored_at:          2026-08-30
```

`pinned_commit` points at the **upstream** base `939eb66` (main
HEAD, 2 commits past v0.8.0's release tag); the vendored tree is that base **plus** himmel's `customLineCommand` delta
**plus** the trimmed `CLAUDE.md` **plus** any dependabot lockfile bumps landed
since the vendor (see **Fork delta**
below), so `vendored_tree_hash` reflects those deltas — it is a
self-consistency hash over the CURRENT tree, not a claim that the tree equals
`pinned_upstream_tree`. `fork_repo`
(`yotamleo/claude-hud`) is a public provenance mirror himmel does NOT install
from (himmel vendors the tree directly), so keeping it in sync is optional — the
drift guard gates on `vendored_tree_hash`, and the nightly upstream-drift guard
(`scripts/upstreams.json` → `claude-hud`) gates on `pinned_commit` vs upstream
HEAD. Re-run `scripts/statusline/check-hud-drift.sh --write` after any re-vendor,
and bump the `claude-hud` `pinned_commit` in `scripts/upstreams.json` to the same
SHA so the nightly guard reads CURRENT.

## Drift guard

`scripts/statusline/check-hud-drift.sh` (pre-commit, himmel-dev-only via
`.himmel-dev` — a no-op in non-contributor checkouts) recomputes a hash over
the **upstream-derived** files in this directory and fails if it diverges
from `vendored_tree_hash` without a pin bump.

**himmel-owned files (excluded from the drift hash — keep in sync with
`OWNED_RE` in both check-hud-drift twins):**
- `VENDORED.md` (this file — edit freely)
- `VENDORED.manifest` (machine-written by `--write`: the per-file hash list
  the aggregate is computed over; excluded because it cannot hash itself —
  never hand-edit)
- `.gitignore` (upstream's file + an appended himmel block re-including
  `dist/`; upstream's own `dist/` ignore would make `git add` silently skip
  the committed runtime we wire)
- `config/**` (himmel's `himmel-config.json`, added in Phase 3)

Everything else here (incl. upstream `README.md`) is **upstream-derived** and
protected: editing it without bumping the pin trips the guard.

> **Deviation from plan (2026-07-06, documented):** the plan listed `README.md`
> as himmel-owned. We instead keep upstream `README.md` faithful (it carries the
> hud config-options docs Phase 3.1 references) and put the himmel fork-delta
> here in `VENDORED.md`. This keeps the vendored tree an exact upstream copy and
> makes the drift guard protect *more* upstream files, not fewer.

## Fork delta

- **Test-only station isolation fixes (HIMMEL-2944, 2026-09-12):** two bugs in
  `tests/core.test.js` / `tests/index.test.js` made `bun test` fail on any
  station with a populated `~/.claude.json` (19 cases), even though the
  suite is green in CI (it never runs there — network-bound, excluded by
  `scripts/ci/run-shell-tests.sh`). (1) 18 `countConfigs` fixtures mutated
  `process.env.HOME` to redirect the counter at a fixture temp dir, but
  bun's `os.homedir()` reads `HOME` once at process startup and never
  re-reads it (Node's does) — fixed with a shared `withHome(homeDir)`
  helper that `spyOn(os, 'homedir')` (`bun:test`) instead, which works
  because `config-reader.ts` already does a namespace import
  (`import * as os from 'node:os'`) that `spyOn` can intercept. (2) the
  entrypoint test relied on re-importing `dist/index.js` with a
  cache-busting query string to force a second module evaluation, but
  bun's dynamic `import()` resolves distinct query strings to the same
  cached module and evaluates it only once per process (Node's ESM loader
  treats each query as a distinct module) — fixed by spawning a real
  `node dist/index.js` child process, matching the plugin's other CLI
  tests. No `src/`/`dist/` change; pin bump is test-file-only.
  **CR round 1 follow-up:** the `spyOn` fix's static `import { spyOn } from
  'bun:test'` broke `npm test` (`node --test`) with
  `ERR_UNSUPPORTED_ESM_URL_SCHEME`, since `bun:test` isn't resolvable under
  plain Node — fixed by loading it dynamically and only when
  `typeof Bun !== 'undefined'`, falling back to plain `process.env.HOME`
  mutation under Node (safe there, since Node's `os.homedir()` re-reads
  `HOME` on every call). Also added the missing `result.status === 0`
  assertion to the spawned-child test, matching every other `spawnSync`
  test in `tests/integration.test.js`. Verified green under both
  `node --test` and `bun test`.

- **Prompt-cache economics line (HIMMEL-2878, 2026-09-12, opt-in, off by
  default):** a new statusline row — `session r:<reads> w:<writes> hit:<pct>%
  net <±$net> cost <$total>` plus an `all` row aggregating every historical
  session transcript — ported from the legacy bash statusline's
  `build_cache_lines`/`read_session_cache_stats`/
  `read_all_sessions_cache_stats`/`format_tokens`/`get_model_savings_rate`
  (`scripts/statusline/bin/statusline.sh`, untouched by this change). Gated
  behind a new `display.showPromptCacheEconomics` config key (default
  `false`); rendered only when set. v1 scope: the unbounded "all" window
  only, no week/month periods; existing lines are unchanged. New files
  `src/cache-economics.ts` (all-sessions aggregator, 30s file-cached like the
  bash original, reusing `parseTranscript`'s per-file accumulation rather
  than reimplementing the bash's jq dedup) and
  `src/render/lines/prompt-cache-economics.ts`; wiring in `src/config.ts`,
  `src/types.ts`, `src/index.ts`, `src/render/index.ts`,
  `src/render/lines/index.ts`, `src/i18n/*`. Pricing deliberately reuses
  `src/cost.ts`'s existing `MODEL_PRICING` table and cache-rate defaulting
  (now exported as `resolveEffectiveCachePricing`) instead of duplicating the
  bash's own hardcoded (and differently-priced) cache-rate table; an unknown
  model renders `net —` / `cost —` rather than the bash's `?`-suffix
  convention. Tests: `tests/prompt-cache-economics.test.js`.

- **Landed (Phase 3.3, HIMMEL-718, `extra-cmd`=B — see the plan §Decisions):** a
  generic `customLineCommand` capability. When `display.customLineCommand` is set
  AND the ACE gate `CLAUDE_HUD_ALLOW_EXTRA_CMD` is enabled, the renderer runs that
  command once per render: it pipes the session stdin JSON to the command's stdin,
  runs it in the session CWD, bounds it by a timeout (3s) + output cap (10KB / 10
  lines), sanitizes each line, and appends the command's **multiline** stdout as
  additional HUD lines. Files: new `src/custom-line-cmd.ts` (+ built `dist/`);
  wiring in `src/config.ts`, `src/index.ts`, `src/types.ts`,
  `src/render/index.ts`; tests in `tests/custom-line-cmd.test.js`. himmel's own
  render logic (the where-are-we composer) stays in himmel `scripts/`, **not** in
  this fork — this fork carries only the generic capability. **This is now the
  ONLY himmel `src/` delta** (see the re-vendor notes below) — `CLAUDE.md` is
  additionally trimmed (next bullet) and the lockfile carries automated
  dependency bumps; see the dependabot bullet.

- **Claudex-lane labels (HIMMEL-2900, 2026-09-12):** under `CLAUDEX_LANE_OK=1`
  (a Claude Code harness driving Codex, not Claude) the renderer no longer
  shows Claude-specific stdin fields that don't apply: `resolveModelName`
  (`src/stdin.ts`) reads `CODEX_MODEL`/`ANTHROPIC_MODEL` instead of the stdin
  model label; cost estimation/native-cost lookup (`src/cost.ts`) is gated off
  the same way as the existing Bedrock/Vertex gates, and the cost slot
  (`src/render/lines/cost.ts`) renders the literal `status.unmeasured` instead
  of disappearing; the context bar (`src/render/lines/identity.ts`) gains a
  `format.configured` suffix since the denominator is a config value, not a
  measured window. Two new i18n keys across all locales. `dist/` rebuilt from
  source.

  > **Coexists with upstream's own `extra-cmd` (since v0.6.0):** upstream grew
  > `src/extra-cmd.ts`, gated by the SAME env `CLAUDE_HUD_ALLOW_EXTRA_CMD` but a
  > DIFFERENT contract — a `--extra-cmd` **CLI arg** whose command emits JSON
  > `{label}` for ONE labelled line. himmel's `customLineCommand` is a **config
  > field** appending **raw multiline** stdout. The two are independent and both
  > wired; himmel uses `customLineCommand` (via `scripts/statusline/hud-custom-lines.sh`),
  > upstream's `extra-cmd` stays dormant (himmel sets no `--extra-cmd`).

- **Trimmed `CLAUDE.md` (HIMMEL-1848, PR #1849):** upstream's `CLAUDE.md`
  auto-loads into every himmel session that touches this subtree, so the
  derivable parts (the `src/` file-tree listing, the stdin/transcript field
  inventory, the dependency stanza) were cut and replaced with a pointer to
  `src/types.ts`. No effect on the renderer — context hygiene only. It must be
  **re-applied on every re-vendor**: the file stays upstream-derived (inside the
  drift hash), it is deliberately NOT in `OWNED_RE`.

- **Re-vendored to upstream v0.6.0 (HIMMEL-1238, 2026-07-21, issue #469):** the
  two previously-carried deltas were **dropped as upstream-absorbed**:
  - The HIMMEL-865 carried PRs jarrodwatts/claude-hud#650 + #646 are now **merged
    upstream** — the re-vendor takes upstream's versions (which evolved beyond the
    carried hunks: transcript dedup now uses `normalizeMessageId` + a capped set +
    an id-OR-usage-fingerprint fallback).
  - The HIMMEL-865 CR-salvage hardening (a `transcript.ts` id-less-fallback
    comment + no-id/opt-in-default tests) is **superseded**: upstream now
    implements the id-less fallback explicitly with its own comment + coverage,
    and the old "id-less ⇒ accumulate as-is" test asserts behaviour upstream
    changed (id-less entries now dedup by usage fingerprint). Kept only where
    still additive; the obsolete no-id test was dropped.

- **Re-vendored to upstream `e39bafc` (HIMMEL-1254, 2026-07-21, fork-drift issue
  #491):** +2 commits past v0.6.0 — upstream `adec51e` "add safe Jujutsu status
  indicators (#685)" + its `dist/` compile. New upstream files (`src/jj.ts`,
  `src/render/vcs-status.ts`, `tests/jj.test.js`) plus a refactor routing git
  status through the new `vcs-status` abstraction (`src/git.ts`, `src/config.ts`,
  `src/index.ts`, `src/render/lines/project.ts`, `src/render/session-line.ts`).
  **Inert for himmel:** himmel repos are git, not Jujutsu — `src/jj.ts` detection
  returns false and the renderer falls back to git, so behaviour is unchanged on
  every himmel machine. Adopted per the Tier-A "always sync + additive" policy
  (HIMMEL-869) to keep the carried delta small. himmel's `customLineCommand` delta
  is preserved — the `src/config.ts` + `src/index.ts` 3-way merges were clean
  (both upstream's jj wiring and himmel's customLineCommand wiring coexist);
  `tests/custom-line-cmd.test.js` stays 6/6. The jj tests are inert where the `jj`
  binary is absent (skip); the only new Windows failures are EPERM on symlink
  fixtures in `tests/jj.test.js` (platform, not code).

- **Re-vendored to upstream `ef5f1c8` (HIMMEL-2138, 2026-08-26, fork-drift issue
  #518):** +49 commits past `e39bafc`, upstream release **v0.8.0**. Notable
  upstream work: a `git-runner.ts` / `windows-git-worker.ts` pair that bounds git
  invocations and kills orphaned Windows git processes; per-`CLAUDE_CONFIG_DIR`
  config overrides (`~/.claude/claude-hud.json`, layered over the shared
  `plugins/claude-hud/config.json` — bounded to 64KB, symlinks + `__proto__`-class
  keys rejected); prompt-cache TTL detection and expiry display; MCP-error
  surfacing on the environment line; Claude 5 / MiniMax pricing and endpoint
  labels; a configurable effort format, clock hour-cycle and `display.rightAlign`;
  and stale-completed-agent expiry. All three himmel deltas re-applied; the
  re-vendor was a `git rebase` of the carried delta onto `ef5f1c8` with **one**
  conflict, in `src/config.ts`: upstream replaced the inline
  `typeof … ? .slice(n)` display-field validation with a `validateDisplayText()`
  helper. Resolved by taking upstream's helper for its own fields and **keeping
  the inline slice for `customLineCommand`** — that string is EXECUTED, not
  displayed, and `validateDisplayText` runs `sanitizeDisplayText`, which strips C0
  (newline/tab included) and would silently rewrite a multi-line command. The
  reason is carried as a comment at the call site. `dist/` was rebuilt from source
  (`npm ci && npm run build`); `tests/custom-line-cmd.test.js` stays 6/6, and the
  upstream suite shows **no net-new failures** against a pristine `ef5f1c8`
  baseline on Windows (39 failures here vs 40 on pristine upstream — all
  pre-existing platform failures: symlink EPERM, `cmd.exe` shim resolution,
  CLAUDE_CONFIG_DIR cache paths).

- **Stale cost-estimate pricing + session token totals (HIMMEL-2161,
  2026-08-27):** two independent fixes to the `estimateSessionCost` fallback
  path (only exercised when stdin `cost.total_cost_usd` is absent — native
  cost still wins in `resolveSessionCost`), verified against the `claude-api`
  skill's pricing reference rather than memory:
  - Repriced the `opusplan`/`haikuplan` enterprise-alias rows in
    `src/cost.ts` from retired model-generation prices ($15/$75, $0.80/$4) to
    the current default model in each tier ($5/$25 Opus 5, $1/$5 Haiku 4.5).
    `sonnetplan` was already correct ($3/$15, matches Sonnet 4.6) — left
    unchanged. Upstream-worthy: file against upstream too (roster
    HIMMEL-2153).
  - Removed the Sonnet 5 date-keyed promo cutover (`SONNET_5_PROMO_END_MS`,
    flat $2/$10 before 2026-09-01 UTC then $3/$15 after) — the claude-api
    skill's current pricing reference lists Sonnet 5 at a flat $2/$10 with no
    scheduled increase corroborated anywhere; kept as a permanent
    `MODEL_PRICING` row instead of an unverified future price hike.
    Upstream-worthy alongside the alias fix.
  - Harness-local display preference, NOT upstream-worthy: split the
    session-tokens line's combined "cache" figure
    (`src/render/lines/session-tokens.ts`) into separate cache-write and
    cache-read totals (new `format.cacheWrite`/`format.cacheRead` i18n keys,
    all 3 locales), so the existing input/output/cache/sum display shows all
    four `SessionTokenUsage` buckets distinctly per HIMMEL-2161's ask, rather
    than lumping cache-creation and cache-read into one number.

  `dist/` rebuilt from source (`tsc` typecheck clean). Test suite: 1040
  pass / 39 fail / 7 skip on Windows, identical failure set to the pristine
  `ef5f1c8` baseline (symlink EPERM, `cmd.exe` shim resolution,
  `CLAUDE_CONFIG_DIR` cache-dir permission bits — all pre-existing platform
  failures, none touching `cost.ts`/`session-tokens.ts`/i18n).

- **Re-vendored to upstream `939eb66` (HIMMEL-2274, 2026-08-30, fork-drift issue
  #518):** +10 commits past `ef5f1c8` (v0.8.0), of which 3 are `build: compile
  dist/ [auto]` and 1 is docs-only. Upstream work absorbed:
  `feat(cost)` an opt-in `display.showDailyCost` daily cumulative-spend ledger
  (new `src/daily-cost.ts` + `tests/daily-cost.test.js`); `feat(usage)` a
  `display.showModelScopedUsage` toggle; `fix(config)` closing a TOCTOU between
  config validation and read (`src/config.ts`); `fix(cache)` anchoring the
  prompt-cache clock to request start and rendering it as `until <time>`;
  `--no-optional-locks` on `git diff --numstat` so a timed-out poll cannot leave
  `.git/index.lock` behind; async-agent (`isAsync` / `status: async_launched`)
  handling in `src/transcript.ts`; and zh-docs + CONTRIBUTING updates. All three
  himmel deltas re-applied by rebasing the carried delta onto `939eb66`: **no
  `src/` conflict this round** - the only content conflict was `CHANGELOG.md`
  (both sides appended under `## [Unreleased]`; resolved by merging both entry
  sets), plus generated `dist/` sourcemaps that `npm run build` rewrites anyway.
  The HIMMEL-2138 `src/config.ts` resolution still stands: `customLineCommand`
  keeps the inline `.slice(n)` validation rather than upstream's
  `validateDisplayText()` helper, and upstream's TOCTOU fix landed elsewhere in
  the file. `dist/` rebuilt from source (`npm ci && npm run build`);
  `tests/custom-line-cmd.test.js` stays 6/6, and the upstream suite shows **zero
  net-new failures** against a pristine `939eb66` baseline built and run in the
  same scratchpad on Windows (76 distinct failing test names on both sides,
  identical sets - symlink EPERM, `cmd.exe` shim resolution, `CLAUDE_CONFIG_DIR`
  cache paths).

  **`src/context-cache.ts` is byte-identical across `ef5f1c8..939eb66`** (source
  and the compiled `dist/`), so the snapshot schema (`used_percentage`,
  `context_window_size`, `saved_at`, `session_name`), the `sha256(transcript
  path)` key and the `context-cache/` directory name are all unchanged -
  himmel's `scripts/context-fill.sh` (HIMMEL-2212) needs no compat fix; its suite
  is green at this pin.

- **Dependabot SECURITY-update lockfile bumps (automated, on top of the pin):**
  `.github/dependabot.yml` deliberately does NOT list
  `/marketplace/plugins/claude-hud` — scheduled *version* updates are not wanted
  on a vendored tree (they would drift it away from `pinned_commit` every week
  and demand a re-record each time; the tree is meant to move on re-vendors).
  Dependabot **security** updates are repo-level and alert-driven, though: they
  fire on any lockfile GitHub detects, config directory or not. So a security
  bump can land here WITHOUT a re-vendor, and the vendored tree then legitimately
  differs from `pinned_upstream_tree` by those hunks. Landed so far:
  `brace-expansion` 5.0.6 → 5.0.7 (dev-only transitive, PR #1374 /
  `a386a624`, re-recorded in HIMMEL-1262); `brace-expansion` 5.0.7 → 5.0.9
  (dev-only transitive via minimatch `^5.0.2`, dependabot alert #26,
  HIMMEL-1408) — **still carried**: upstream `939eb66` still pins
  `brace-expansion` 5.0.6, so both the HIMMEL-2138 and HIMMEL-2274 re-vendors
  kept the 5.0.9 floor per the re-vendor rule below rather than taking upstream's
  lockfile. Dependabot does NOT run
  `check-hud-drift.sh --write`, so each such bump needs a follow-up pin re-record
  commit (`--write`, then commit `VENDORED.md` + `VENDORED.manifest`) or every
  contributor commit trips the pre-commit drift gate. `pinned_commit` /
  `pinned_upstream_tree` / `vendored_at` stay UNCHANGED for these — they record
  the upstream base, and a bump is not a re-vendor.

  **Re-vendor rule for these bumps — do NOT blindly take upstream's lockfile.**
  A re-vendor supersedes a bump listed here ONLY when the incoming upstream
  lockfile pins the same version or newer. If upstream is still behind (e.g.
  upstream at `brace-expansion` 5.0.6 while the entry below records 5.0.7),
  taking upstream's lockfile wholesale DOWNGRADES a patched dependency, and
  re-recording the pin afterwards would bless that regression — the drift guard
  hashes the tree for self-consistency and cannot tell a downgrade from any
  other change. Re-apply the bump on top of the re-vendored tree instead
  — lockfile-ONLY, so a dev-only transitive package does not become a direct
  dependency:

  ```sh
  # in marketplace/plugins/claude-hud/
  npm update <pkg> --package-lock-only --ignore-scripts
  git diff --exit-code package.json   # MUST be unchanged
  # then confirm the resolved version + integrity moved to the recorded floor
  ```

  (`npm install <pkg>@<ver>` is the WRONG tool here — it writes the package into
  `package.json` `dependencies`, and the follow-up `--write` would bless that as
  a vendored delta.) Then `--write`. Only strike an entry from the list once
  upstream has actually caught up.

  This rule is prose, not an enforced gate: `check-hud-drift.sh` hashes the tree
  for self-consistency and has no notion of a version floor, so a re-vendor that
  downgrades still passes if the reviewer misses it. Machine-enforcing the floor
  is tracked separately (HIMMEL-1264).
