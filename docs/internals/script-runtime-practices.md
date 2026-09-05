# Script runtime practices — invocation, spawn economics, guardrail shape

How, at what cost, and why himmel scripts run the way they do. Platform
*traps* (WSL stub resolution, MSYS path mangling, PowerShell footguns) live in
[`environment-gotchas.md`](environment-gotchas.md) — this doc does not repeat
them, only cross-links. Guardrail fail-direction and the hook-chain mechanism
are owned by [`enforcement.md`](enforcement.md) and
[`scripts/hooks/CLAUDE.md`](../../scripts/hooks/CLAUDE.md); this doc adds the
measured economics behind those rules. Nothing here is prose to remember —
every rule traces to a ticket with a measurement or an incident behind it.

## 1. How to invoke

| Target | Rule | Why |
|---|---|---|
| `.ps1` | Always `pwsh` (PowerShell 7+). `powershell.exe` 5.1 only with a **named reason per use**. | Operator ruling 2026-08-26 (HIMMEL-2126): 5.1 reads a BOM-less UTF-8 file as cp1252 — an em dash becomes a string terminator, and the parser error points at the WRONG line. Bit twice: ggs-local `run-bridges.ps1` (2026-08-05), station-ops `sweep-contention.ps1` (2026-08-26). |
| `pwsh -File` list args | Pass ONE quoted comma string; split it inside the script. Never `-Levels 1,2,4,8` bare. | `pwsh -File` converts a bare comma list to a single int — `1,2,4,8` becomes `1248`. This is the HIMMEL-2119 fan-out bomb: 1248 workers spawned, host RAM to 96%. |
| Shell scripts | bash 3.2-safe (macOS floor). `scripts/hooks/CLAUDE.md` is normative for this repo's hooks. | Same rule as the hooks subtree; a bash-4-only construct (`mapfile`, associative arrays) silently breaks on macOS. |
| Repo shell script invoked FROM PowerShell | Pin `& "C:\Program Files\Git\bin\bash.exe"`. Never bare `bash`. | Bare `bash` from PowerShell resolves the WSL stub (`C:\WINDOWS\system32\bash.exe`), which cannot read `C:\…` paths. Full trap + `resolveBash()`/`BASH_BIN` reference: [`environment-gotchas.md` § Windows: bare `bash`…](environment-gotchas.md#windows-bare-bash-resolves-to-the-system32-wsl-stub). |
| `schtasks` create vs query | Pair them: **query → PowerShell, create → Git Bash.** | `schtasks /create` is AV-denied from both PowerShell generations on OVERLORD8 but works from Git Bash; `/query` is the reverse (MSYS mangles it). |
| Here-strings / growing content in MSYS bash | Temp file or case-membership once content can exceed ~64 KiB, never a herestring. | A herestring ≥ 64 KiB wedges MSYS bash forever (HIMMEL-2027). |

## 2. What it costs — MSYS spawn economics

External-process spawn from a bash script is not free, and the cost is not
flat — it rises under contention. Measured on the PreToolUse Bash hook chain
(HIMMEL-2119 / HIMMEL-2123):

- One external grandchild (grep/jq/git spawned from a bash script): **~34 ms
  idle, ~106 ms at 16-way load** — the marginal cost roughly **triples** under
  contention. The spawn path saturates around **2.4–3 chains/s**.
- The 10-member PreToolUse Bash chain runs on **every** Bash tool call, so a
  hot-path spawn multiplies by call volume, not by how often you personally
  notice it.

### Defork round 2 results (HIMMEL-2123, PR #1912)

Per-member spawn count and ms/call, before → after:

| Chain member | Spawns (old → new) | ms/call (old → new) |
|---|---|---|
| check-cr-marker | 1 → 0 | 55 → 36 |
| tail-pipe | 5 → 1 | 181 → 87 |
| destructive | 10 → 3 | 284 → 152 |
| git-stash | 10 → 3 | 257 → 131 |
| auto-approve | 7 → 2 | 272 → 160 |
| read-secrets | 8 → 3 | 234 → 136 |
| quiet-run | 5 → 2 | 213 → 167 |
| jira-compound | 5 → 1 | 243 → 115 |
| rogue-schedule | 8 → 3 | 224 → 135 |
| chokepoint | 9 → 4 | 340 → 301 |

Chain-wide: **~2.30s → ~1.42s idle**. Post-defork sweep (station-ops
`sweep-contention.ps1`):
N=1 mean 1.65s, N=16 P95 7.4s, 0 skips, ~3.2 chains/s.

### Defork patterns

Each cuts a spawn but carries its own trap — read the trap before copying the
pattern:

- **`input=$(cat)` → `IFS= read -r -d '' input || true`.** A fail-closed fence
  built on this then needs an **explicit blank-input guard**: `jq <<<""` emits
  0 values with 0 errors, silently flipping the fence fail-open (caught twice
  in the HIMMEL-2123 CR round).
- **N × `printf|jq` → one `jq` call emitting delimited multi-field rows.** The
  multi-line-capable field (`command`) goes **last** and is extracted as
  rest-of-string. A delimiter a JSON string could legally contain needs an
  in-jq collision guard on fail-closed hooks (the SOH-injection finding).
- **jq `// empty` inside a `+` concatenation is a zero-output GENERATOR** — one
  missing field collapses the whole extraction. Use `// ""`, never `// empty`,
  inside a concatenation.
- **Non-string `command` (array/object) must error fail-closed** —
  `error("non-string-command")` — in a fence. `|tostring` is not equivalent:
  it changes match semantics versus jq `-r` pretty-printing.
- **`tr a | tr b` → one `tr 'SET1' 'SET2'` call — only when the translations are
  independent.** Chained `tr` is not generally composable: if the second call acts
  on characters the first PRODUCED, a single merged call changes the result.
  Verify byte-identical output on the real inputs per site (the HIMMEL-2123
  merges were). sed/cut/head one-liners on small strings → parameter expansion.
  `printf | jq -Rs` → `jq -n --arg`.
- **Herestring `<<<` appends a trailing newline** — keep `printf` where a
  `$`-anchored regex depends on the exact trailing bytes.

### Beyond the hook chain

- **`py_armor_capture` costs 7 spawns per call** — mktemp ×2 + interpreter +
  cat ×2 (stderr replay + stdout capture) + rm ×2 (`scripts/lib/py-armor.sh:101-135`).
  This is the dominant shape: 10 of arm-resume's 11 py-armor call sites use it.
  The plain `py_armor` path (minority, 1 site) is a single interpreter spawn.
  Batch capture calls or replace the trivial ones — this is arm-resume's
  remaining ~30s (HIMMEL-2125).
- **Leading-zero env values through `$(( ))` parse as octal and abort under
  `set -e`.** A digit-only check does not catch this (`0180` is all digits and
  still invalid octal). Normalize with `10#$value` before arithmetic.

## 3. Why the guardrails hold shape

### Fail-direction

Full policy and the accepted exception are owned by
[`enforcement.md`](enforcement.md) and
[`scripts/hooks/CLAUDE.md` § Fail-open vs fail-closed](../../scripts/hooks/CLAUDE.md#fail-open-vs-fail-closed--decide-by-failure-direction).
Restated as a lookup table because a defork touches exactly this boundary:

| Hook shape | Fails | Why |
|---|---|---|
| Security fence (secrets, destructive commands, egress) | **Closed** — including on blank stdin, non-string fields, delimiter collisions, unparseable input | A false negative here is a security incident |
| Watchdog | **Open** | Must never block a tool call on its own bug |
| Workflow nudge | **Open** on its own infra errors (missing `jq`, unparseable JSON) | Failing closed denies every call the hook can't parse — the nudge becomes the next thing everyone bypasses |
| Auto-approve gateway | Only ever grants | One documented deny carve-out (HIMMEL-2121) |

### Chain budgets (`scripts/hooks/run-hook-with-bash.js`)

Nesting, largest to smallest: **entry 60s > chain 50s > member 15s > floor
500ms.** Must-run members fail **closed** on starvation rather than being
silently skipped (HIMMEL-2060). These are static numbers again post-defork —
HIMMEL-2091's load-aware sizing was closed as superseded, since the
post-defork sweep's N=16 P95 (7.4s) is >6× inside the 50s chain budget.
Reopen trigger: any entry appearing in `hook-chain-skips.jsonl`.

## 4. Measurement discipline

- **Benchmark before/after around every perf change**, conditions recorded
  HIMMEL-1564-style: box, load level, date, SHA. Land the numbers on the
  ticket before the next phase starts.
- **Verify the ARTIFACT, not the rc.** A vacuous `exit 0` passes trivially;
  pin that the guarded path actually ran (the 2113c anti-vacuous pattern) —
  same discipline as
  [`environment-gotchas.md` § A real `sleep`…](environment-gotchas.md#a-real-sleep-reachable-from-test-config-is-a-hang-waiting-to-happen)
  for injected-sleep tests.
- **A skip needs its own tally — never the pass counter.** A case that never
  ran must not be credited as a pass — not via the PASS counter or a `pass()`
  helper, and not via a token that reads as one (`PASS (skipped)`, a real
  pass's `ok - ` prefix). HIMMEL-2258's fleet audit found 13 such sites across
  8 suites, 2 firing every run (HIMMEL-2254 / #2029: a `.env` shield skipped 7
  cases on every primary checkout). Give a legitimate capability skip its own
  counter in the summary line instead (`test-check-hud-drift.sh`'s `_skips`,
  exit 77) — and don't let a setup shield "skip if it already exists": prefer
  `mktemp -d` per-run fixtures, and assert the shield engaged, not just that
  the suite passed.
- **Build a probe harness, don't re-run the full suite per iteration.** Splice
  a suite's own setup plus 1–2 representative cases into a standalone script
  under `scripts/` (not `/tmp` — see
  [`environment-gotchas.md` § MSYS `/tmp`…](environment-gotchas.md#msys-tmp-is-the-windows-user-temp-dir--temp-cleaners-delete-it-under-you)),
  and never edit a script while it's running.
- **Load experiments respect the safety envelope** built into station-ops
  `sweep-contention.ps1`: avail ≥ 12 GiB, commit ≤ 80%, ≤ 250 bash processes,
  N ≤ 64.
- **Size a `run-shell-tests.sh` per-suite cap from the LOADED case, not an
  idle box** (HIMMEL-2401): a cap set from an idle benchmark's headroom gets
  consumed as a suite grows, so re-benchmark under the load the box actually
  carries and set the cap to `measured_loaded × 2`, dating the comment —
  never nudge a stale cap by a few seconds, that reproduces the ticket at the
  next added case. In the runner's own `== Summary ==`, a
  `CAP EXCEEDED (assertions passing): N` line means the watchdog killed a
  suite at its cap while every observed "ok"/"not ok" TAP-style line was
  still passing. Treat it as a strong disposition HINT — re-size the
  suite's `_suite_timeout_for` entry first, not re-run — but it is a
  heuristic over one line convention, not proof of health: a suite can emit
  an "ok" token as plain narration and still fail through a different,
  non-TAP mechanism, so a suite that keeps failing after its cap is raised
  still needs a look.
