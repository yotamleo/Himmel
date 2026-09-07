# claude-p P0 probe results (HIMMEL-2179)

Epic: HIMMEL-2178 (claude-p dispatch-substrate migration plan).
CLI version under test: 2.1.250 (Claude Code), Windows / Git Bash.
Run with `bash run-all.sh`; per-probe raw envelopes/JSONL/logs land in `tmp/`
(gitignored, not committed). Several probes got one additional diagnostic
follow-up call beyond `run-all.sh` itself, noted inline — still within the
"repeat ≤2 attempts, then record" budget.

Every row is a measured result read from an artifact (session JSONL, JSON
envelope, file presence/absence, `permission_denials`), never inferred from
an exit code alone — this repo's own measured fact is that headless
permission denials are often silent at the rc level (`is_error`/rc here
reflects `--max-turns` exhaustion, not the denial itself).

## ⚠ Methodology correction (found while running probes 1/1b/3b)

**Git Bash on Windows silently rewrites a bare leading-slash CLI argument
into a Windows path before it ever reaches `claude.exe`.** Confirmed
directly: `node -e 'console.log(process.argv)' "/compact"` prints
`"C:/Program Files/Git/compact"`, not `/compact` — MSYS's argv-to-path
auto-conversion applies to any leading-slash arg passed to a non-MSYS
(native Windows) executable, `claude.exe` included. This produced **false
negatives** in the first pass of probes 1, 1b, and 3b: the model wasn't
failing to expand a slash command, it was correctly describing the garbled
Windows path it actually received. Mitigation: `MSYS_NO_PATHCONV=1` (or
`MSYS2_ARG_CONV_EXCL='*'`, or a `//` prefix) before the invocation — all
three verified to restore the literal `/compact` / `/probe-skill` argv.
Every affected probe below was re-run with `MSYS_NO_PATHCONV=1` and both
the original (confounded) and corrected results are recorded. **Any
migration-plan tooling that shells out `-p` invocations from Git Bash on
Windows with a slash-command prompt needs this env var or its prompts will
silently misfire.**

| probe | expectation | measured outcome | artifact evidence | verdict |
|---|---|---|---|---|
| 1 compact-via-resume | `claude` in `-p` mode with `--resume <id> "/compact"` triggers a real compaction event, visible as a `compact_boundary` system message in the session JSONL. | **Unmitigated run**: 3-call session ran cleanly, but `grep -c compact_boundary` = 0; the model replied confused about "that path" (see methodology note — this was Git-Bash argv mangling, not a real negative). **Corrected retest** (fresh session, `MSYS_NO_PATHCONV=1`): `compact_boundary_count=1`; the JSONL entry reads `{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual","preTokens":36059,...}}` — a genuine manual compaction, `.result` empty, `is_error:false`. | Unmitigated: `tmp/01-c.json`, session JSONL (0 matches). Corrected: `tmp/01-nomangle-c.json`, session JSONL (`compact_boundary`, `trigger:"manual"`). | **PASS** (corrected) — `/compact` via `-p --resume` DOES work. The original apparent FAIL was purely the Git-Bash argv-mangling artifact above, not a limitation of `claude` in `-p` mode. |
| 1b compact-via-continue | SDK docs show `/compact` dispatched via `--continue` (same cwd, no `--resume`) — does `--continue` expand slash commands the same way? | **Unmitigated run**: same false-negative shape as probe 1 (`compact_boundary_count=0`, "I see a path" reply). **Corrected retest** with `MSYS_NO_PATHCONV=1`: `compact_boundary_count=1`, `is_error:false`. | Unmitigated: `tmp/01b-c.json`. Corrected: `tmp/01b-nomangle-c.json` + session JSONL. | **PASS** (corrected) — `--continue "/compact"` also works once argv-mangling is neutralized; no observed difference from `--resume` for this purpose. |
| 2 dontask-allowlist | `--permission-mode dontAsk` + an allowlist that covers `Write` lets the file get written; an allowlist that omits `Write` blocks it, with the denial visible in `permission_denials`. | Run A (`allowedTools "Bash(echo *),Write"`): `tmp-artifact.txt` created, contents `OK`, rc=0. Run B (`allowedTools "Bash(echo *)"`, no Write): `tmp-artifact-noaccess.txt` absent (as expected), rc=1 (hit max-turns after the denial, not a distinct "denied" exit code). `permission_denials` held **two** entries: a denied `Write` call, then the model's fallback — a denied `Bash` call running `printf "OK" > file` (not covered by the narrow `Bash(echo *)` shape since it used `printf`, not `echo`). | `tmp/02-a.json`, `tmp/02-b.json` (`permission_denials` array), file presence via `ls`. | **PASS** as expected (allow→write, deny→no write). Also shows the model retries with a shell workaround on denial, and that workaround can itself be silently denied by an allowlist shape mismatch — `permission_denials` is the only structural signal; rc is not. |
| 3 bare-add-dir-skills | `--bare --add-dir <packdir>` discovers *and executes* a skill living under `<packdir>/.claude/skills/`. | **Bare run**: skill WAS discovered — `probe-skill` appears in both `slash_commands` and `skills` arrays of the `stream-json` init event — but invocation failed immediately: `"error":"authentication_failed"`, result `"Not logged in · Please run /login"`, and the init event shows `"apiKeySource":"none"`. No artifact file. **Control run** (same command, `--bare` removed): `/probe-skill` was not treated as a skill invocation at all — generic chat reply, no artifact, no error. The auth failure fires before any argv/slash-command handling (`duration_api_ms:0`), so it is NOT a mangling artifact — genuine. Whether the mangled argv also would have blocked local skill-matching in the bare run is unverified (moot given the auth failure fires first); see probe 3b for the clean comparison. | `tmp/03-stream.jsonl` (init event: `apiKeySource:"none"`, `error:"authentication_failed"`); `tmp/03-work-nobare/out.json` (generic chat reply, no skill trace). | **FAIL** (both shapes tested) — `--bare` surfaces the `--add-dir` skill in discovery but strips ambient auth entirely; dropping `--bare` restores auth but the added-dir skill is no longer recognized as invocable. Neither shape end-to-ends a `--add-dir` skill on this CLI/build. |
| 3b configdir-pack | A seeded `CLAUDE_CONFIG_DIR` (copy of `.credentials.json` only, plus a `skills/probe-skill/` dir — no `--bare`, no `--add-dir`) gives bare-equivalent skill isolation WITH working auth. | **Unmitigated run**: argv-mangled (`/probe-skill` → `C:/Program Files/Git/probe-skill`), model treated it as an ambiguous path — a mangling artifact, not a real result. **Corrected retest** with `MSYS_NO_PATHCONV=1`: auth worked cleanly (no "Not logged in" — confirms `CLAUDE_CONFIG_DIR` preserves auth, unlike `--bare`), but the CLI replied `"Unknown command: /probe-skill"` — the skill was NOT registered as an invocable slash command from `$CLAUDE_CONFIG_DIR/skills/`. No artifact either run. | Unmitigated: `tmp/03b-work/out.json`. Corrected: `tmp/03b-work-nomangle/out.json` (`{"is_error":false,"result":"Unknown command: /probe-skill"}`). | **FAIL** (corrected, clean result — mangling ruled out) — `CLAUDE_CONFIG_DIR` alone does NOT discover an ad-hoc `skills/` dir the way `--add-dir` does; it fixes probe 3's auth problem but doesn't replace `--add-dir` for discovery. Neither tested mechanism (probe 3's `--bare --add-dir`, or this probe's seeded `CLAUDE_CONFIG_DIR`) delivers "auth + discovery + execution" together on this CLI. |
| 3c cwd-pack | A plain project-tier pack — cwd's own `./.claude/skills/probe-skill/`, NO `--bare`, NO `--add-dir`, NO `CLAUDE_CONFIG_DIR` — gets discovered and executed by default project-tier skill loading. | Ran `claude` in `-p` mode (`MSYS_NO_PATHCONV=1 ... "/probe-skill"`) from inside the pack dir. Clean success first try: `is_error:false`, `result:"Done. SKILLOK written to skill-artifact.txt."`, `permission_denials:[]`, artifact present with `SKILLOK`. Auth intact throughout (no "Not logged in"). | `tmp/pack3c/out.json`, `tmp/pack3c/skill-artifact.txt`. | **PASS** — plain project-tier discovery (just `cwd/.claude/skills/`) is the one tested mechanism that delivers auth + discovery + execution together, with zero extra flags. |
| 3d plugin-dir-pack | A minimal plugin (`.claude-plugin/plugin.json` = `{"name":"probe-plugin","version":"0.0.1"}` + `skills/probe-skill/`) loaded via `--plugin-dir` from a scratch cwd, invoked as `/probe-plugin:probe-skill` (namespaced) or `/probe-skill` (bare fallback). | Namespaced form: `"result":"Unknown command: /probe-plugin:probe-skill"`, no artifact. Bare fallback: `"result":"Unknown command: /probe-skill"`, no artifact either. No schema-rejection error surfaced anywhere (`out.err`/`out2.err` both empty) — so this is a **silent** non-load, not a validation error. Confirmed via a `stream-json` diagnostic call: the init event's `plugins` array lists only the operator's real `~/.claude` plugin cache + this repo's marketplace plugins — `probe-plugin` never appears in `plugins` or `skills` at all. | `tmp/03d-work/out.json`, `tmp/03d-work/out2.json` (both `Unknown command`); `tmp/03d-work/diag-stream.jsonl` init event (`plugins` array has no `probe-plugin` entry). | **FAIL** (clean, unconfounded — no argv mangling involved once `MSYS_NO_PATHCONV=1` was applied throughout) — the minimal 2-field `plugin.json` is silently never loaded via `--plugin-dir`; whether a richer manifest (description, commands/skills declared explicitly, etc.) would load is untested — out of scope for this probe's budget. |
| 4 wrapper-shape | stdin prompt + `--append-system-prompt-file` + `--output-format json --json-schema '{...}'` produces a schema-conformant `structured_output` field. | First attempt (`--max-turns 1`, per brief's "cheapest possible") hit `terminal_reason:"max_turns"` before finishing — `structured_output:null`, `result:null`, `is_error:true`, `errors:["Reached maximum number of turns (1)"]`. Retried with `--max-turns 2`: completed cleanly — `terminal_reason:"completed"`, `is_error:false`, `structured_output:{"answer":"Hi"}` (schema-conformant), envelope reports `num_turns:3` internally. | `tmp/04.json` (max_turns failure), `tmp/04-retry.json` (success, `structured_output.answer="Hi"`). | **PASS**, but only with `--max-turns >= 2` — the `--json-schema` + `--append-system-prompt-file` combo needs headroom beyond 1 turn even for a trivial one-word answer; `--max-turns 1` silently produces a `null` structured_output instead of a schema error. |
| 5 cross-cwd-resume | `--resume` works from a cwd different than the one the session started in (docs claim support since CLI 2.1.223; under test: 2.1.250). | Session started in the worktree (`tmp/05-a.json`, rc=0). Resumed from `$TEMP` (git-bash `/tmp`) — rc=0, `is_error:false`, `result:"B"`, same `session_id`. Clean success, no special handling needed. | `tmp/05-a.json`, `tmp/05-b.json` (`{"is_error":false,"result":"B","session_id":"ddc98595-..."}`). | **PASS** — matches documented cross-directory resume behavior on this CLI version. |
| 6 bank-delta | Snapshot `five_hour`/`seven_day` utilization before and after the batch; abort everything if `bank-preflight.sh` prints `SKIPPED-BANK`. | Before batch: `five_hour=19.0`, `seven_day=65.0` (verdict `PROCEED`; already up from a 17.0/64.0 baseline taken before scaffolding). After batch (7 probe scripts × ~16 headless `claude` calls total): `five_hour=22.0`, `seven_day=65.0` (verdict `PROCEED`). Delta: **+3.0** points `five_hour`, **+0.0** points `seven_day`. The follow-up round (probes 1b/3b + mangling-diagnosis + corrected retests, ~8 more calls) was not re-snapshotted separately but never approached `SKIPPED-BANK` (verified via `bank-preflight.sh` PROCEED on every gated run). Never neared the 85% threshold at any point. | `tmp/06-before.json`, `tmp/06-after.json`, `tmp/06-delta.json` (`{"five_hour_delta":3,"seven_day_delta":0}`). | **PASS** (measured, not assumed) — the whole harness cost ~3 percentage points of the 5-hour bank; never at risk of the skip threshold. |
| 7 dual-shell-allowlist | Run the same "create a file" prompt twice under `dontAsk` with an allowlist phrased only for Bash shapes (`Bash(echo *),Write`); record per-run which tool the model reaches for (Bash / PowerShell / Write) — evidence of run-to-run shell nondeterminism. | Both runs: exactly one `tool_use`, `name:"Write"`; `permission_denials:[]`; artifact `probe7-output.txt` present with `OK` both times. Neither run touched Bash or PowerShell — the model consistently reached for the directly-allowed `Write` tool over any shell workaround. | `tmp/07-run1.jsonl`, `tmp/07-run2.jsonl` (`tool_use` names + final `permission_denials`), file presence in `tmp/07-run1/` and `tmp/07-run2/`. | **PASS** (measured) — no shell nondeterminism observed in this run (n=2): Write was chosen deterministically both times when it was directly allowlisted. A larger sample would be needed to rule out a low-probability divergence; this harness does not claim that. |

## Headline facts for the migration plan

- **Git Bash on Windows mangles leading-slash `-p` prompt args into Windows
  paths before `claude.exe` sees them** — set `MSYS_NO_PATHCONV=1` (or
  `MSYS2_ARG_CONV_EXCL='*'`, or a `//` prefix) around any headless
  invocation whose prompt is a slash command. This produced false negatives
  in this harness's own first pass; corrected retests are what the table
  above reports. **This is the single most important finding for any
  Windows/Git-Bash `-p` tooling in the migration plan.**
- **`/compact` DOES expand and compact via both `-p --resume` and
  `-p --continue`**, once the argv-mangling above is neutralized — a real
  `compact_boundary` event with `trigger:"manual"` lands in the session
  JSONL. (Probes 1, 1b)
- **`permission_denials` is the only reliable signal of a dontAsk denial** —
  process rc reflects `--max-turns` exhaustion, not the denial itself; a
  denied call can still exit 0 if the model gives up gracefully within its
  turn budget. (Probe 2, matches the brief's stated measured fact.)
- **Pack mechanism settled: plain project-tier `cwd/.claude/skills/` is the
  one mechanism (of four tested) that gives auth + discovery + execution
  together, with zero extra flags.** `--bare --add-dir` discovers the skill
  but strips auth (`apiKeySource:"none"`, probe 3); a seeded
  `CLAUDE_CONFIG_DIR` (creds only, no `--bare`/`--add-dir`) keeps auth but
  never registers the ad-hoc `skills/` dir (`"Unknown command"`, probe 3b);
  `--plugin-dir` with a minimal 2-field `plugin.json` is silently never
  loaded at all — doesn't even appear in the init event's `plugins` list,
  no error surfaced (probe 3d). Only running from a cwd whose own
  `./.claude/skills/probe-skill/` holds the skill — no flags at all — just
  worked on the first try (probe 3c). **If the migration plan needs a
  packaged/portable skill (not project-local), none of `--bare --add-dir`,
  `CLAUDE_CONFIG_DIR`, or a minimal `--plugin-dir` manifest currently
  deliver it end-to-end on this CLI — that gap needs a richer plugin
  manifest test or an upstream ask, out of this probe's scope.** (Probes 3,
  3b, 3c, 3d)
- **`--json-schema` needs `--max-turns >= 2`**, even for trivial output — 1
  turn silently yields `structured_output:null` instead of an error worth
  noticing. (Probe 4)
- **Cross-cwd `--resume` works cleanly** on CLI 2.1.250. (Probe 5)
- **Bank cost of this whole P0 probe batch: ~3 points of `five_hour`, ~0
  points of `seven_day`.** (Probe 6)
- **No shell-choice nondeterminism observed** in a small (n=2) sample when
  `Write` is directly allowlisted. (Probe 7)
