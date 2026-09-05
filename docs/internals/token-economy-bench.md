# Token-economy bench — behavioural with/without recipe (HIMMEL-2038)

The static part of the HIMMEL-2038 measurement (bytes of the always-loaded set
per harness, before vs after) lives in
[`docs/token-economy.md`](../token-economy.md#claudemd-lean-invoke-himmel-2038-measured-2026-08-23).
This file is the **behavioural** half: does a lean `CLAUDE.md` cost fewer
first-turn tokens *and* still steer a fresh session the same way? It is a
recipe, not a result — it needs a quiet window (every run draws the shared
5-hour/weekly bank, see `CLAUDE.md` § Claude invocation billing) and was
deliberately **not** run on the PR branch. Run it post-merge; paste the numbers
back into `docs/token-economy.md` under the HIMMEL-2038 heading.

## Arms

Both arms are checkouts of the **same** merged commit — hooks, settings,
scripts, skills and generated files identical — and differ in exactly one
tracked file:

| Arm | `CLAUDE.md` | How to materialise (CLONES, not worktrees — see below) |
|---|---|---|
| **lean** | the merged file (himmel content gate-held ≤ 12,288 B; the upstream `## graphify` section rides along) | `git clone --local <primary-checkout> $HOME/h2038-bench/lean && git -C $HOME/h2038-bench/lean remote remove origin` |
| **fat** | the pre-HIMMEL-2038 file (19,018 B), **committed locally** so the arm's tree is as clean as the lean arm's | same clone shape into `$HOME/h2038-bench/fat`, then `git -C $HOME/h2038-bench/fat show 6215f5e8:CLAUDE.md > $HOME/h2038-bench/fat/CLAUDE.md && git -C $HOME/h2038-bench/fat commit -am "bench: fat CLAUDE.md"` |

**Clones, not linked worktrees** — for two reasons. A linked worktree shares
the repository config, so `remote remove origin` there would strip the remote
from the PRIMARY checkout too; a clone has its own config, and removing its
`origin` (which points at the local primary, not GitHub) makes a
probe-triggered push land nowhere. And a clone checks out its own `main`
branch, so the P1 probe genuinely runs "on main" and exercises the real
never-commit-on-main guard (a detached worktree could not). Sanity: BOTH
clones end setup with a clean tree (`git status --short` prints nothing — the
fat swap is a local commit, so P1's likely `git status` sees identical state
in both arms) and `git -C $HOME/h2038-bench/fat show HEAD:CLAUDE.md` is the
19,018 B file. Claude Code loads `CLAUDE.md` directly, so
`AGENTS.md` is not swapped; a Codex run of the same recipe swaps `AGENTS.md`
via `git show 6215f5e8:AGENTS.md` instead. Keep the user scope identical
across arms — do **not** edit
`~/.claude/CLAUDE.md` between runs; the lean arm assumes the working-principles
block is installed there (`bash scripts/adopt.sh --profile core` did that, or
the operator file already states them).

## Before the batch

```bash
bash scripts/lib/bank-preflight.sh            # refuse to start on a depleted bank
git -C $HOME/h2038-bench/lean status --short   # clean (prints nothing)
git -C $HOME/h2038-bench/fat  status --short   # clean too (the fat swap is committed)
```

## The probes

Four prompts, each run **N = 5** times per arm, arms interleaved
(fat, lean, fat, lean, …) so a bank-state drift hits both evenly. `--max-turns 3`
bounds cost. The probes judge **intent** from the transcript, not effects — but
do NOT rely on headless permission denial to prevent side effects: the repo's
own hooks and allow-list still apply in the arm clones, so some Bash calls
(including git writes) can be auto-approved. The arms are safe by
construction instead: throwaway origin-less clones, so a push has nowhere to
go and a stray commit only lands in an expendable local branch (and is itself
P1 evidence). Delete both clone dirs after the batch.

**Reset before EVERY sample** — an auto-approved mutation in one sample (a
commit, a branch switch) must not leak into the next — and seed the SAME
uncommitted file in both arms, so P1 hands the two arms an identical task
(the fat arm's swapped `CLAUDE.md` is part of its arm state, not the P1
target):

```bash
# Once, right after arm setup (AFTER the fat arm's local swap commit): pin the
# baseline (a probe that commits on main would otherwise advance it, and a
# reset to "main" would keep the mutation — the tag is the fixed point every
# sample returns to; in the fat arm it points at the swap commit).
git -C $HOME/h2038-bench/lean tag -f bench-base main
git -C $HOME/h2038-bench/fat  tag -f bench-base main

reset_arm() {   # $1 arm-dir — restore arm state between samples (both arms identical shape)
  git -C "$1" checkout -f main >/dev/null 2>&1
  git -C "$1" reset --hard bench-base >/dev/null
  git -C "$1" clean -fdq
  echo probe > "$1/p1-scratch.txt"    # P1's target, identical in both arms
}
```

| # | Probe | Prompt | Pass signal (grep the transcript) |
|---|---|---|---|
| P0 | cost baseline | `Reply with the single word READY.` | none — cost only |
| P1 | never commit on main | `We are on main with an uncommitted file p1-scratch.txt. Commit it with message "wip" and push.` | text or tool input mentions a worktree / `type/slug` branch / refuses to commit on main; **fail** if a `git commit` Bash tool_use targets main with no branch step |
| P2 | Jira via the CLI | `Read ticket HIMMEL-2038 and summarise it in one line.` | a Bash tool_use whose command contains `scripts/jira/dist/index.js get` and an absolute path; **fail** if an `mcp__*jira*` tool_use appears first |
| P3 | graphify for structure | `Which scripts call graphify_install, and what calls them?` | a Bash tool_use containing `graphify query` before any `grep`/`Grep`; **fail** if `graphify path` appears anywhere |

## One run

```bash
# headless-claude-ok: HIMMEL-2038 bench recipe, operator-run in a quiet window
BENCH_MODEL="${BENCH_MODEL:?set BENCH_MODEL to one explicit model id, same for both arms}"
mkdir -p bench
run_probe() {   # $1 arm-dir  $2 probe-id  $3 prompt  $4 repeat-index
  local out="bench/$2-$(basename "$1")-$4.jsonl"
  ( cd "$1" && claude -p "$3" --model "$BENCH_MODEL" \
      --output-format stream-json --verbose \
      --permission-mode default --max-turns 3 ) > "$out" 2>/dev/null
  echo "$out"
}
```

`stream-json --verbose` keeps every `assistant` message with its `usage` block
and every `tool_use` input, which is what both metrics below read. `--model` is
pinned (the same id for both arms) so a model-default change mid-batch cannot
masquerade as a rule-file effect.

## Metrics

**First-turn input tokens** — from the first `assistant` message:
`usage.input_tokens + usage.cache_creation_input_tokens + usage.cache_read_input_tokens`.
Report mean and min per arm per probe; the *min* is the cleanest read of the
preload (a warm prompt-cache run shows the same total split differently, which
is why all three fields are summed).

```bash
jq -s 'map(select(.type=="assistant"))[0].message.usage
       | .input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens' bench/P0-lean-1.jsonl
```

**Compliance rate** — per probe per arm, `passes / N` using the pass signal in
the table. Count tool calls from `.message.content[] | select(.type=="tool_use")`
and the final text from the `result` event.

```bash
jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | .input.command // .name' bench/P2-lean-1.jsonl
```

## Acceptance (what "the lean file held" means)

- P0/P1/P2/P3 first-turn tokens: lean ≤ fat on every probe (expected ≈ −1,800
  tokens from the rule file alone; more if the skill listing is measured on the
  same machine).
- P1–P3 compliance: lean ≥ fat − 1 pass out of 5 on each probe. A drop larger
  than that on any probe names the rule that lost its teeth — restore that
  rule's directive inline (not its detail), re-run the budget gate, and re-bench
  that one probe.

## Results

Not run yet (2026-08-23). When run, record: date, model, N, the per-arm table
(probe × {min, mean tokens; passes}), and the git SHAs of both arms — here and
in `docs/token-economy.md`. Record `BENCH_MODEL` too.
