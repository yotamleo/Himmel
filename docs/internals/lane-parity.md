# Lane-parity index (WS5, HIMMEL-654)

> **Status:** WS5 Task 0 skeleton (HIMMEL-654). The living successor to the 562
> compatibility audit and the per-lane extension of
> [`harness-compat.md`](harness-compat.md). The invariant guard set is sourced
> from root `CLAUDE.md` ENFORCEMENT (per-hook detail in
> [`enforcement.md`](enforcement.md)). WS5 design decisions D1-D9 are the
> binding contract; this doc implements D1 (a living index, doc + tested
> subset), D6 (doctrine lives here, not root `CLAUDE.md`), D7 (merge-trust is a
> WS7-owned column the index consumes, not the trust gate), and D9 (no
> `claude-codex` row).

## Doctrine

**Compatibility doctrine.** Every worker lane runs under the FULL himmel setup
-- the same deny-guard guardrails, the same vault/memory substrate, the same
ship-flow -- so workers are interchangeable and their outputs land in
compatible shapes. "Workers run the full setup" is asserted in prose today;
this index makes it drift loudly instead of silently.

**One ruleset, N adapted projections.** Root `CLAUDE.md` is the single source.
Each runtime reads an ADAPTED projection: Claude Code reads `CLAUDE.md` native;
the `glm-spawn` fleet reads live `~/.claude`; the `claude-glm` launcher reads a
seeded `~/.claude-glm` copy; Codex / Cursor / Copilot read the generated
`AGENTS.md` (freshness-gated by `agents-md-fresh`); hermes reads `SOUL.md`
(identity) plus a per-context `AGENTS.md` / `CLAUDE.md`. The projections are
not all kept in lockstep today; the two tested columns (rule-projection
freshness, guard-firing pointers) are where the drift becomes visible.

**The index AGGREGATES WS7's merge-trust cell; it is NOT the trust gate.** The
merge-trust column is a VIEW that consumes WS7's verdict. WS5 wires the column
and asserts it exists per non-native lane; WS7 fills the verdict and owns the
trust decision. "Row green" is a composite, not a WS5 trust ruling (D7).

**GLM is reachable by THREE paths, with THREE different guard mechanisms -- so
"GLM is guarded" is proven per-path, not asserted once:**

1. `glm-spawn` -- Claude Code with the backend swapped, reads live `~/.claude`;
   the native PreToolUse hooks fire unchanged, plus
   `block-glm-external-writes.sh` (the classifier substitute for the
   write-authority dimension).
2. `glm-launcher` -- Claude Code with the backend swapped, reads a seeded
   `~/.claude-glm` copy; same guards as (1), plus a config-seed drift dimension
   (owned by Task 1).
3. GLM-via-hermes -- the hermes runtime drives GLM; himmel's Claude Code
   PreToolUse hooks do NOT load here, so the write-fence is `parity_guard.py`,
   not the CC hook. The GLM-engine write-fence reaching parity with the CC hook
   is `pending:Task3` (enumeration) and `GAP` until Task 6 ports it.

Same model, three runtimes, three guard mechanisms. A single "GLM is guarded"
claim collapses three distinct proofs; this index keeps them separate.

## Invariant guard set

The load-bearing distinction (design sec. a). Of the 9 PreToolUse hooks + 1
PostToolUse hook named in root `CLAUDE.md` ENFORCEMENT, only the DENY-guards
are parity-relevant: they are the hard blocks a non-native lane must replicate.
The non-deny hooks are EXCLUDED from the per-lane map, because enumerating them
per lane produces spurious `GAP`s (e.g. "codex lacks `auto-arm-on-cap`") that
swamp the real gaps.

**Deny-guards a non-native lane must replicate** (6 PreToolUse hooks + the
git-hook gates):

- `block-edit-on-main`
- `block-read-secrets`
- `block-backend-tier`
- `block-docker-privesc`
- `block-rogue-claude-schedule`
- `block-merged-pr-commit`
- the pre-commit / pre-push git gates (harness-independent -- git runs them on
  every lane that commits): `agents-md-fresh`, `check-platforms-tested`,
  `check-security-reviewed`, `doc-guard`, `gitleaks`, and the rest of the
  `.pre-commit-config.yaml` gate set.

**Non-deny hooks -- NOT mapped per-lane** (3 PreToolUse + 1 PostToolUse):

- `auto-approve-safe-bash` -- an auto-APPROVER (a fail-open permission helper),
  not a deny-guard.
- `auto-arm-on-cap` -- a fail-open cap watchdog; no non-native analog.
- `check-cr-marker-on-pr-create` -- a PR-time marker check, not a runtime deny.
- `auto-arm-on-subagent-cap` (PostToolUse) -- a cap detector, not a deny-guard.

### Write-authority / external-write fence (a cross-lane dimension -- NOT one of the 9 hooks)

Write-authority is the load-bearing parity dimension, but
`block-glm-external-writes.sh` is a lane-specific classifier SUBSTITUTE, not one
of the 9 ENFORCEMENT PreToolUse hooks -- so it has no home among the six
deny-guards above. It is recorded here as its own dimension row so every
write-fence cell sits in a real row (no home-less cell). The hermes
GLM-engine write-fence cell flipped `pending:Task3` -> `tested` when Task 3
confirmed HIMMEL-695 landed it (see the conformance notes below).

| Lane | Write-authority / external-write fence |
|---|---|
| main-claude | auto-mode classifier |
| glm-spawn | `tested:scripts/hooks/test-block-glm-external-writes.sh` |
| glm-launcher | `tested:scripts/hooks/test-block-glm-external-writes.sh` |
| codex-direct | adapter path -- `.codex/hooks.json` reaches the native block-* hooks |
| hermes-main (DEFAULT; engines codex-5.5 + GLM) | `parity_guard` push/PR fence -- `tested:scripts/hermes/test-parity-guard.sh` (HIMMEL-695 write-fence; the CC hook does NOT fire under hermes, parity_guard is the sole fence). Four OTHER deny-guards stay `GAP` until Task 6 / HIMMEL-731 ports them. |
| hermes-junior | n/a -- read-only tier (`luna_vault_guard`) |
| gemini / copilot / cursor | `deferred` |

## Token vocabulary (machine-readable; defined once)

Every index cell carries a token from this FIXED vocabulary. Task 2's
guard-conformance test parses these literals -- do not introduce synonyms.

- `tested:<relative/path>` -- a real proving test/script path (the two tested
  columns: rule projection, guardrail firing).
- `GAP` -- no proving test exists for this cell.
- `pending:<TaskN>` -- the verdict is owned by a later WS5 task and is not yet
  resolved.
- `asserted-only` -- a doc-asserted column (skills/cmds, vault/memory), not
  tested.
- `WS7-owned` -- the merge-trust column WS7 fills (wired by WS5, unfilled by
  WS5).
- `native` -- the lane runs the native Claude Code ruleset/hooks directly (the
  baseline).
- `native,no-seed` -- the native ruleset is read from LIVE config (no seeded
  copy, no drift dimension).
- `deferred` -- the lane is soft-deferred (no free usage tier); the row is
  present, not active.

Column status: **rule projection** + **guardrail firing** are the two TESTED
columns (cells carry `tested:<path>` / `GAP` / `pending:`); **skills/cmds** +
**vault/memory** = `asserted-only`; **merge-trust** = `WS7-owned`. A row is
`tested`-green only when every deny-guard cell in its guard x lane sub-table
row (Task 2) is `tested:<path>` -- no `GAP`, no `pending:`.

## Lane-parity index

| Lane | Rule projection | Guardrail firing | Skills/cmds | Vault/memory | Merge-trust (WS7) |
|---|---|---|---|---|---|
| main-claude | `native` (CLAUDE.md) | `native` (hooks + classifier) | `native` | `native` | `native` (baseline) |
| glm-spawn | `native,no-seed` (live `~/.claude`) | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `asserted-only` | `asserted-only` | `WS7-owned` |
| glm-launcher | `tested:scripts/hooks/test-claude-glm-seed-check.sh` (seeded `~/.claude-glm`, drift-checked) | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `asserted-only` | `asserted-only` | `WS7-owned` |
| codex-direct | `tested:scripts/agents-md/generate.mjs` (AGENTS.md gen + gated) | `tested:scripts/hooks/test-codex-run-hook.sh` | `asserted-only` | `asserted-only` | `WS7-owned` |
| hermes-main (DEFAULT; engines codex-5.5 + GLM) | `AGENTS.md (loaded)` (`tested:scripts/hermes/test-agents-reach.sh`) | `tested:scripts/hermes/test-parity-guard.sh` | `asserted-only` | `asserted-only` | `WS7-owned` |
| hermes-junior | `AGENTS.md (loaded)` (`tested:scripts/hermes/test-agents-reach.sh`) | `GAP` (`luna_vault_guard`, no in-repo test) | `asserted-only` | `asserted-only` | `WS7-owned` (read-only tier) |
| gemini / copilot / cursor | `deferred` | `deferred` | `deferred` | `deferred` | `deferred` |

Notes on the guardrail-firing cells. GLM IS Claude Code, so on the two CC GLM
lanes the native block-* hooks fire unchanged; the proving pointer is
`test-block-glm-external-writes.sh`, which covers the lane-specific write-fence
(push / git-remote-URL / network / `mcp__*` deny, with the Jira-CLI + gh-read
carveout). codex-direct reaches the native block-* hooks THROUGH the
`.codex/hooks.json` adapter (the exit-2 to deny translation proved by
`test-codex-run-hook.sh`); the per-guard codex resolution is enumerated in the
Task 2 guard x lane sub-table. hermes-main's `parity_guard` fences both
engines; the GLM-engine write-fence LANDED (HIMMEL-695) and is resolved in the
write-authority row above (`tested:scripts/hermes/test-parity-guard.sh`); the
residual non-write-fence GAPs are enumerated in the guard-parity table below.

**No `claude-codex` row (D9, locked).** Codex reaches real work ONLY via
`codex-direct` (Codex CLI as its own harness) or `hermes` (engine = Codex) --
never a `claude` backend swap. The index deliberately has no `claude-codex`
row; its absence asserts the lock structurally.

## Guard-firing conformance sub-table (deny-guard x lane)

The load-bearing WS5 delta over 562. The top-level index carries ONE
guardrail-firing cell per lane; this sub-table expands each non-native lane's
proof per invariant deny-guard (the Task-0 set of six PreToolUse deny-hooks
plus the cross-lane write-authority dimension) into a real proving test or
`GAP`. `scripts/parity/test-guard-conformance.sh` parses this table by its
anchor -- Task 3 and Task 6 both rewrite this file, so the HTML-comment anchor
(not heading text) is the stable parse key.

Cells use the Task-0 token vocabulary (`tested:<path>` / `GAP` /
`pending:<TaskN>`). A lane column is **`tested`-green** iff EVERY cell in it --
across all six deny-guards AND the write-authority / external-write-fence
dimension row -- is `tested:<path>` (no `GAP`, no `pending:`). The write-fence
row counts toward `tested`-green because write-authority is the load-bearing
parity dimension (Task 0): a lane is fully guard-tested only once its
write-fence is also tested. Task 3 confirmed the hermes-main GLM-engine
write-fence LANDED (HIMMEL-695: `parity_guard.py` fences plain push /
remote-URL rewrite / gh PR-mutation / network CLIs, fail-closed on an
untrusted or unknown engine, proved by `test-parity-guard.sh`), so the
write-authority cell flips from `pending:Task3` to
`tested:scripts/hermes/test-parity-guard.sh`. `hermes-main` is still NOT
`tested`-green: Task 3's enumeration found four deny-guards `parity_guard.py`
does NOT enforce (`block-edit-on-main`, `block-backend-tier` / MCP-fence,
`block-docker-privesc`, `block-merged-pr-commit`), so those four hermes-main
cells are `GAP` — the row goes `tested`-green only once Task 6 ports them.
The write-fence and `block-read-secrets` / `block-rogue-claude-schedule` are
the three PRESENT deny-guards; the four GAPs are enumerated in the guard-parity
table below and filed under HIMMEL-563.

<!-- BEGIN guard-lane-conformance -->

| deny-guard | glm-spawn | glm-launcher | codex-direct | hermes-main (codex-5.5 + GLM) | hermes-junior |
|---|---|---|---|---|---|
| block-edit-on-main | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-edit-on-main.sh` | `GAP` | `GAP` |
| block-read-secrets | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-read-secrets.sh` `GAP` | `tested:scripts/hermes/test-parity-guard.sh` | `GAP` |
| block-backend-tier | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-backend-tier.sh` | `GAP` | `GAP` |
| block-docker-privesc | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-docker-privesc.sh` | `GAP` | `GAP` |
| block-rogue-claude-schedule | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-rogue-claude-schedule.sh` | `tested:scripts/hermes/test-parity-guard.sh` | `GAP` |
| block-merged-pr-commit | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-merged-pr-commit.sh` | `GAP` | `GAP` |
| write-authority / external-write-fence (cross-lane dimension, NOT a CC PreToolUse hook) | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `GAP` | `tested:scripts/hermes/test-parity-guard.sh` | `GAP` |

<!-- END guard-lane-conformance -->

Notes on the cells:

- **glm-spawn + glm-launcher.** GLM IS Claude Code, so on these two CC GLM
  lanes the native block-* deny-guard hooks fire unchanged; the single
  lane-specific proving pointer is
  `tested:scripts/hooks/test-block-glm-external-writes.sh` (covers push /
  git-remote-URL / network / `mcp__*` deny, with the Jira-CLI + `gh`-read
  carveout). The native `test-block-<guard>.sh` fixtures fire unchanged for
  both lanes because the ruleset is live `~/.claude` (glm-spawn) or the seeded
  `~/.claude-glm` copy (glm-launcher).
- **codex-direct.** Each deny-guard is proved by the codex proving PAIR --
  `tested:scripts/hooks/test-codex-run-hook.sh` (the `.codex/hooks.json`
  adapter's exit-2 to `deny` translation, HIMMEL-427) PLUS the NATIVE
  `tested:scripts/hooks/test-block-<guard>.sh` the adapter reaches (all six
  native fixtures exist). The `block-read-secrets` cell additionally carries
  `GAP`: a true codex through-adapter END-TO-END secret-read fixture is wanted
  and does not exist, so T6 is proven by the PAIR, not by a (non-existent)
  codex-specific fixture. The write-authority cell is `GAP` for the same
  reason -- there is no codex through-adapter external-write e2e proof.
- **hermes-main (DEFAULT; both engines codex-5.5 + GLM).** himmel's CC
  PreToolUse hooks do NOT load under hermes, so `parity_guard.py` is the sole
  fence; both engines are exercised by
  `tested:scripts/hermes/test-parity-guard.sh`. The GLM-engine write-fence cell
  in the write-authority row is RESOLVED by Task 3 to
  `tested:scripts/hermes/test-parity-guard.sh`: HIMMEL-695 landed the
  write-fence in `parity_guard.py` (plain push / remote-URL rewrite / gh
  PR-mutation / network CLIs, fail-closed on an untrusted or unknown engine),
  so it is PRESENT and tested -- the earlier "only `git push --force`" reading
  is superseded. The residual non-write-fence GAPs (edit-on-main,
  docker-privesc, merged-PR-commit, MCP-fence) are enumerated in the
  guard-parity table below and filed under HIMMEL-563; porting is Task 6.
- **hermes-junior.** `GAP` -- its `luna_vault_guard` is a hermes-side artifact
  with no in-repo test.
- Any deny-guard with no lane proving test is `GAP` by construction.

## hermes guard-parity gap (Task 3 enumeration, both engines)

The contract side of the index: for each invariant DENY-guard (the Task-0 set
of six PreToolUse deny-hooks PLUS the cross-lane write-authority dimension),
what does `scripts/hermes/assets/parity_guard.py` -- the SOLE fence under
hermes, since himmel's Claude Code PreToolUse hooks do NOT load there -- actually
enforce, for BOTH engines (codex-5.5 + GLM) the `himmel_agent` profile is
pointed at? Tags: `present` (parity_guard enforces it), `n/a-for-runtime`
(Claude-Code-specific mechanics with no hermes analog), `GAP` (not enforced --
filed under HIMMEL-563, porting is Task 6).

| Invariant deny-guard | parity_guard.py status (both engines) | Verdict |
|---|---|---|
| `block-read-secrets` | `SECRET_READ` regex on `read_file` / `search_files` (any arg key): `.env` / `.envrc` / `.ssh` / `id_rsa` / `.pem` / `.key` / `secrets.yaml` / channel tokens / `.git-credentials` / `hosts.yml` / `credentials.json`. PHI egress fence (HIMMEL-695) refuses reads under a `.salus` / `phi-roots` / `egress-denylist` root. | `present` |
| `block-rogue-claude-schedule` | `TERMINAL_DESTRUCTIVE` blocks `schtasks` (and `taskkill`/`shutdown`/`reg`/`shutdown`), the scheduler-mutation class that arms a rogue `claude` schedule. The claude-CLI-specific System32-cwd anti-trap (HIMMEL-647) is a launch-path check with no hermes analog -- hermes does not arm the `claude` CLI. | `present` (scheduler vector fenced; the System32-cwd trap is `n/a-for-runtime`) |
| write-authority / external-write-fence (cross-lane dimension) | HIMMEL-695 landed the engine-gated write-fence: `terminal_external_write_reason` refuses `git push` (plain, not just `--force`), git remote-URL / `config ...url` rewrite, `gh` PR-mutations (carve-out: `gh issue *` + `gh pr view/diff/checks/status/list` + `gh run view/list/watch`), and network CLIs (`curl`/`wget`/`iwr`/`irm`). `_external_writes_allowed()` is fail-closed: refused unless `HERMES_EXTERNAL_WRITES_OK=1` AND no `api.z.ai` / `HERMES_ENGINE=glm*` untrusted signal. Proved by `test-parity-guard.sh` (push / remote-url / `gh pr create` / `curl` refused; carve-outs + trust opt-in allowed; z.ai + `HERMES_ENGINE=glm` override the opt-in). | `present` |
| `block-edit-on-main` | `check_write_path` blocks writes to the guard / a profile `config.yaml` / `SOUL.md` / Claude's home, but has NO branch awareness -- nothing refuses an edit or `git commit` because the repo is on `main`. Routine `git commit` is explicitly allowed. | `GAP` (no main-branch edit/commit lock) -- HIMMEL-563 sub-task |
| `block-merged-pr-commit` | No branch / PR-state awareness at all -- nothing detects a merged-PR branch. | `GAP` (no merged-PR-branch detection) -- HIMMEL-563 sub-task |
| `block-docker-privesc` | `TERMINAL_DESTRUCTIVE` covers recursive delete / disk / scheduler / process / registry / force-push / `curl|sh`, but has NO `docker` / `podman` mount + privilege detection. | `GAP` (no container privesc block) -- HIMMEL-563 sub-task |
| `block-backend-tier` | `parity_guard`'s hook matcher (`wire_parity_guard.py MATCHER`) is `write_file|patch|read_file|search_files|terminal|delete_file|...` -- it does NOT match `mcp__*` tools, so MCP tool calls do not invoke the guard at all. There is no MCP-tier / registry routing under hermes. | `GAP` (MCP unfenced) -- HIMMEL-563 sub-task |

**GLM-engine write-fence vs `scripts/hooks/block-glm-external-writes.sh`.** The
hermes runtime does not load that CC hook, so `parity_guard` is the sole
external-write fence for every engine on the `himmel_agent` profile. Compared
shape-by-shape against the hook (the behavior spec): `git push` (plain),
`git remote set-url` / `config ...url`, the `gh` carve-out (`issue *` + PR/run
reads only), and the network-CLI set (`curl`/`wget`/`iwr`/`irm`) all match --
the terminal / file external-write shapes are at PARITY (present, HIMMEL-695).
The ONE residual gap is **MCP**: `block-glm-external-writes.sh` blankets every
`mcp__*` tool (except the `qmd` KB carve-out), but `parity_guard`'s matcher
excludes `mcp__*`, so an MCP tool call reaches the engine unfenced under hermes.
If the `himmel_agent` profile is configured with MCP tools, that is a real
external-write exposure on the default lane -- filed as the `block-backend-tier`
GAP above.

**Bonus (not in the deny-guard set, recorded for completeness):** the
unconditional PHI / data-egress fence (HIMMEL-695, F-B5) fires on EVERY engine
on this cloud profile -- a `.salus`-marked path or a configured `phi-roots` /
`egress-denylist` root is refused for read / search / write / delete
(symlink/junction-safe via `realpath`, fail-closed on an unreadable list). It is
`present` and proved by `test-parity-guard.sh`; it is not one of the six
deny-guards, so it is not a parity GAP, just an additional fence hermes carries.

**Filed under HIMMEL-563 (proposed sub-tasks; the validating session files
these -- this enumeration does NOT create Jira issues):**

- port a branch-aware main-branch edit/commit lock into `parity_guard` (or a
  hermes-side commit hook) -- `block-edit-on-main` parity.
- add merged-PR-branch detection -- `block-merged-pr-commit` parity.
- add `docker` / `podman` mount + privilege detection to `TERMINAL_DESTRUCTIVE`
  -- `block-docker-privesc` parity.
- extend `parity_guard`'s matcher to cover `mcp__*` tools (mirror
  `block-glm-external-writes.sh`'s blanket MCP deny + `qmd` carve-out) --
  `block-backend-tier` / MCP-external-write parity (the load-bearing one).

Porting all four closes the hermes guard gap; the write-fence itself is already
PRESENT (HIMMEL-695), so Task 6's write-fence sub-task is satisfied -- only the
four GAPs above remain.
