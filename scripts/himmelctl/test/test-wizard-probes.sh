#!/usr/bin/env bash
# test-wizard-probes.sh — hermetic tests for scripts/himmelctl/lib/probes.js
# (HIMMEL-756 T1.4, extended HIMMEL-1093): the probe-type engine, run against
# the REAL scripts/install/manifest.json descriptors (so a manifest authoring
# drift breaks THIS suite, not silently). Mirrors sibling test-wizard-*.sh
# conventions: scripts/lib/hermetic-path.sh's link_hermetic_tool/scrub_path
# for curated stub PATHs, node launched by absolute path, winpath for
# node.exe's MSYS-path blindness.
#
# Covers, present AND absent (plus degraded where the probe type supports a
# tri-state result):
#   file-exists    targetPath-relative (guardrail-scope), the repoRoot-
#                  relative exception (jira-cli-dist-build — proves it
#                  ignores a targetPath that DOES carry the file), and the
#                  {vaultPath} placeholder (luna-vault-scaffold).
#   settings-key   dot-path single key (wiring-statusline), simple
#                  non-dotted key (claude-plugins-pluginSet), and the .env
#                  ALL-keys-required union resolving against repoRoot for
#                  BOTH scopes (jira-env-keys).
#   settings-hooks present (all 3 himmel PreToolUse markers) / degraded
#                  (1 of 3) / absent (none) (wiring-pretooluse).
#   cmd:has_qmd    qmd-binary, via a stubbed `qmd` on PATH.
#   qmd-index      present (all 4 collections) / degraded (2 of 4) / absent
#                  (no qmd on PATH).
#   mcp-registered tokensave-mcp present / server missing / file missing
#                  (ENOENT, clean) / malformed JSON / unexpected shape
#                  (the latter two carry configError:true), resolving
#                  .claude.json from ctx.env.HOME; graphify-mcp
#                  scope-awareness — project scope resolves <targetPath>/
#                  .mcp.json, user scope resolves ~/.claude.json, no
#                  cross-scope bleed (HIMMEL-1017 CR round); (HIMMEL-1093)
#                  the bin/initMarker deepening against the REAL tokensave-mcp
#                  descriptor — registered-but-broken (unresolved binary /
#                  uninitialized project) reads degraded, not present;
#                  (HIMMEL-1093 round 2, codex-2) the bin check resolves via
#                  ctx.env.PATH, proven DIVERGING from process.env.PATH (the
#                  outer shell's PATH is scrubbed of the stub, ctx.env's
#                  carries an extra dir process.env.PATH lacks); every fixture
#                  above pins a REGISTERED `command` that resolves (round 3,
#                  codex-adv-1's registered-command check is now
#                  unconditional — see the dedicated block further down for
#                  the wrong/missing/nonexistent-command coverage itself,
#                  including round 5's POSIX executability distinction —
#                  win32-reachable paths only; see that block's skip note).
#   which()        (helpers.js, round 5, codex-1) key-PRESENCE beats
#                  truthiness — a deliberately scrubbed PATH:'' must not fall
#                  through to a present Path, and Path alone (PATH key
#                  genuinely absent) still resolves.
#   handover-dir   handover-wiring — HANDOVER_DIR set (ctx.env pass-through,
#                  not process.env mutation) / unset with a non-repo cwd.
#   dep            single-cmd (rtk), the win32/posix platform union
#                  (scheduler-backend), and (HIMMEL-1093) graphify — each
#                  present/absent via stub PATH.
#   cmd:has_hermes (HIMMEL-1093) hermes-lanes, sourcing (via a resolver path
#                  passed through the spawned env, not string-interpolated
#                  into the command — round 6, codex-1) a stub resolve-
#                  hermes-py.sh — present/absent; resolver missing (rc 3,
#                  probe wiring broken) and a spawn error (bash unresolvable)
#                  both reading degraded (round 4, mirroring cmd:is_himmel_
#                  dev's round-2 fix); plus (round 6, codex-2) an UNEXPECTED
#                  rc (127 — resolver sourced but the function was never
#                  defined) also reading degraded, not the same absent as
#                  resolve_hermes_py's own clean "not installed" (rc 1).
#   cmd:is_himmel_dev (HIMMEL-1093) doc-guard-map, sourcing (same env-passed-
#                  path shape as cmd:has_hermes — round 6, codex-1) a stub
#                  guardrails/lib.sh — present (rc 0) / absent (rc 1, the
#                  ordinary non-contributor case) / degraded (rc 2, repo root
#                  unresolvable); plus (round 2, codex-1) rc 3 (resolver
#                  itself fails to source — probe wiring broken, must NOT
#                  read the same 'absent' as a clean marker-not-present), a
#                  spawn error (bash itself unresolvable via ctx.env.PATH),
#                  and (round 6, codex-2) an UNEXPECTED rc (127 — resolver
#                  sourced but the function was never defined) also reading
#                  degraded, never the same absent as is_himmel_dev_repo's
#                  own clean "not a dev checkout" (rc 1).
#   telegram-access (HIMMEL-1093 round 3, codex-adv-3) telegram-bridge — no
#                  token (absent); token + access.json missing/unparseable/
#                  no usable allow rule (degraded, would gate out every DM/
#                  group); token + a real allowFrom or a groups-only
#                  access.json (present).
#   file-exists {homePath} (HIMMEL-1100) obsidian-second-brain — present/
#                  absent, mirroring {vaultPath}'s existing pattern.
#   cmd:codex_provisioned (HIMMEL-1100) codex-cli — pure JS, no spawn: CODEX_BIN
#                  override semantics (unusable override = absent, no PATH
#                  fallback) / plain PATH resolution / binary-resolves-but-
#                  never-provisioned (no plugin cache dir) reads degraded, not
#                  present — the same false-green class HIMMEL-1093 killed for
#                  tokensave-mcp, applied here proactively; plus (round 3,
#                  codex-adv-2) a cache dir with OTHER marketplaces cached
#                  but no himmel/ subdir also reads degraded — ANY cache dir
#                  is not himmel-specific evidence, only a cache entry for
#                  the himmel marketplace itself is.
#   cmd:cadence_armed (HIMMEL-1100) pipeline-cadence (full matrix: armed /
#                  not-armed / resolver-missing / spawn-error / unexpected-rc,
#                  the round-6 discipline applied from the start) plus
#                  codex-sweep-cadence/graphmap-cadence envVar-wiring sanity.
#   cmd:guardrail_block_status (HIMMEL-1100) guardrail-block-global —
#                  project-mode (absent) / rotted node path, unparseable
#                  output, nonzero exit (all degraded); plus (round 3,
#                  codex-adv-1) a 1-of-3-hooks partial install (mode=global,
#                  node-resolves=yes for the ONE wired hook) reads degraded,
#                  NEVER present — status output cannot attest all 3
#                  guardrail hooks, only that at least one is wired, so
#                  'present' is bounded to unreachable via this data source.
#   dep            (HIMMEL-1100) gemini-cli — present/absent via stub PATH.
#   cmd:hermes_checkout (HIMMEL-1100 round 3, codex-adv-3) hermes-checkout —
#                  pure fs, no git spawn: resolves update_hermes()'s OWN
#                  root/src, reads .git/config directly for the origin
#                  remote — present (genuine NousResearch/hermes-agent
#                  checkout, exact ssh AND https origin forms) / absent (no
#                  .git at all) / degraded (checkout present but wrong/
#                  missing/unreadable origin); distinct from cmd:has_hermes
#                  (a usable venv python), kept unchanged on hermes-lanes for
#                  runtime health. Round 4: (codex-1) an EXACT owner/repo
#                  path match, not a substring — a spoofed origin that merely
#                  CONTAINS "NousResearch/hermes-agent" (e.g. evil/
#                  NousResearch-hermes-agent-mirror) reads degraded, never a
#                  false present; (codex-2) .git as a gitlink FILE (worktree/
#                  submodule "gitdir: <path>") is honored too, following the
#                  pointer one level — a broken pointer reads degraded
#                  (a checkout genuinely exists, just unverifiable), never a
#                  crash or a silent absent. Round 5: (codex-1) a NORMAL
#                  linked worktree (gitdir -> .git/worktrees/<name>, which
#                  carries no remotes of its own) resolves via that dir's
#                  `commondir` file, followed ONE level to the common config
#                  with the origin — reads present, not falsely degraded.
#   purity         a full sweep over every manifest.json item leaves the
#                  fixture repo + vault trees byte-identical (sha256
#                  snapshot before/after).

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
probes_lib="$repo_root/scripts/himmelctl/lib/probes.js"
helpers_lib="$repo_root/scripts/himmelctl/lib/helpers.js"
manifest_path="$repo_root/scripts/install/manifest.json"
[ -f "$probes_lib" ] || { echo "FAIL: $probes_lib not found" >&2; exit 1; }
[ -f "$helpers_lib" ] || { echo "FAIL: $helpers_lib not found" >&2; exit 1; }
[ -f "$manifest_path" ] || { echo "FAIL: $manifest_path not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "FAIL: sha256sum required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# winpath <path> — echo <path> unchanged on posix, or its Windows form on
# git-bash/MSYS/Cygwin (node.exe misresolves MSYS /tmp-style paths).
winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

is_win32() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# build_path <stub_dir> <present_tools...> -- <absent_tools...> (copied from
# the sibling suites: link the named present tools off the CURRENT PATH into
# <stub_dir>, then echo a PATH with the stub prepended and the named absent
# tools scrubbed).
build_path() {
  local _stub="$1"; shift
  local _present=() _absent=() _stage=0 _t
  for _t in "$@"; do
    if [ "$_t" = "--" ]; then _stage=1; continue; fi
    if [ "$_stage" -eq 0 ]; then _present+=("$_t"); else _absent+=("$_t"); fi
  done
  for _t in "${_present[@]}"; do
    link_hermetic_tool "$_t" "$_stub"
  done
  local _scrubbed="$PATH"
  if [ "${#_absent[@]}" -gt 0 ]; then
    _scrubbed=$(scrub_path "$PATH" "${_absent[@]}")
  fi
  printf '%s:%s' "$_stub" "$_scrubbed"
}

# snapshot_dir <dir> — sorted "relpath sha256" pairs, for a before/after
# byte-identity check that doesn't depend on tar's metadata quirks. Portable
# across bash 3.2 + BSD sort (no -z/-print0/xargs -0 on macOS's base sort).
snapshot_dir() {
  ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done )
}

probes_lib_w="$(winpath "$probes_lib")"
helpers_lib_w="$(winpath "$helpers_lib")"
manifest_w="$(winpath "$manifest_path")"
repo_root_w="$(winpath "$repo_root")"

# ── which() (helpers.js): key-PRESENCE, not truthiness — HIMMEL-1093 round 5
# CR fix (codex-1): `e.PATH || e.Path || ''` treated a DELIBERATELY scrubbed
# `PATH: ''` as falsy and fell through to `e.Path` — so a hermetic caller
# that explicitly empties PATH (to prove "nothing on it resolves") silently
# resolved from an inherited Windows `Path` instead, defeating the scrub.
# Proven directly against helpers.js (not through a probe), with a
# real-looking `Path` value present alongside the empty `PATH` — the exact
# shape that used to slip through.
whichEnvTest="$work/which-env-test-bin"; mkdir -p "$whichEnvTest"
: > "$whichEnvTest/probe-tool"
outWhichScrubbed=$("$node_bin" -e "
const { which } = require('$helpers_lib_w');
// PATH explicitly empty (the scrub); Path carries a REAL, resolvable dir —
// the pre-fix code would fall through to it and find 'probe-tool'.
const env = { PATH: '', Path: '$(winpath "$whichEnvTest")' };
console.log(JSON.stringify(which('probe-tool', env)));
")
echo "$outWhichScrubbed" | jq -e '. == null' >/dev/null \
  || fail "which(): an explicitly-empty PATH must NOT fall through to a present Path (got: $outWhichScrubbed)"
echo "ok: which() honors key-presence — a deliberately scrubbed PATH:'' is NOT treated as absent-so-fall-through-to-Path"

# ── which() positive control: Path alone (PATH key genuinely ABSENT) still
# resolves — proves the fix didn't just make which() always fail. ─────────
outWhichPathFallback=$("$node_bin" -e "
const { which } = require('$helpers_lib_w');
const env = { Path: '$(winpath "$whichEnvTest")' };
console.log(JSON.stringify(which('probe-tool', env)));
")
echo "$outWhichPathFallback" | jq -e '. != null' >/dev/null \
  || fail "which(): PATH key genuinely absent should still fall back to Path (got: $outWhichPathFallback)"
echo "ok: which() — PATH key genuinely absent still falls back to Path (the fallback itself still works)"

# ── file-exists: targetPath-relative (guardrail-scope) ──────────────────────
feA_present="$work/feA-present"; mkdir -p "$feA_present/scripts/guardrails"
: > "$feA_present/scripts/guardrails/lib.sh"
feA_absent="$work/feA-absent"; mkdir -p "$feA_absent"

outA1=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-scope');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$feA_present")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outA1" | jq -e '.actual == "present"' >/dev/null || fail "file-exists targetPath-relative present: (got: $outA1)"
outA2=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-scope');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$feA_absent")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outA2" | jq -e '.actual == "absent"' >/dev/null || fail "file-exists targetPath-relative absent: (got: $outA2)"
echo "ok: file-exists targetPath-relative (guardrail-scope) present/absent"

# ── file-exists: repoRoot-relative exception (jira-cli-dist-build) ─────────
# The target ALSO carries the file, at the identical relative path — proves
# the probe resolves against repoRoot, not targetPath, for this item.
feB_repo_absent="$work/feB-repo-absent"; mkdir -p "$feB_repo_absent"
feB_repo_present="$work/feB-repo-present"; mkdir -p "$feB_repo_present/scripts/jira/dist"
: > "$feB_repo_present/scripts/jira/dist/index.js"
feB_target_with_file="$work/feB-target"; mkdir -p "$feB_target_with_file/scripts/jira/dist"
: > "$feB_target_with_file/scripts/jira/dist/index.js"

outB1=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'jira-cli-dist-build');
const ctx = { repoRoot: '$(winpath "$feB_repo_absent")', targetPath: '$(winpath "$feB_target_with_file")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outB1" | jq -e '.actual == "absent"' >/dev/null \
  || fail "file-exists repoRoot-relative exception: expected absent (repoRoot lacks the file even though targetPath has it) (got: $outB1)"
outB2=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'jira-cli-dist-build');
const ctx = { repoRoot: '$(winpath "$feB_repo_present")', targetPath: '$(winpath "$work/feB-nonexistent-target")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outB2" | jq -e '.actual == "present"' >/dev/null \
  || fail "file-exists repoRoot-relative exception: expected present (repoRoot has the file; targetPath doesn't exist at all) (got: $outB2)"
echo "ok: file-exists repoRoot-relative exception (jira-cli-dist-build) ignores targetPath"

# ── file-exists: {vaultPath} placeholder (luna-vault-scaffold) ─────────────
feC_present="$work/feC-vault-present"; mkdir -p "$feC_present"
: > "$feC_present/.vault-template.json"
feC_absent="$work/feC-vault-absent"; mkdir -p "$feC_absent"

outC1=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'luna-vault-scaffold');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$feC_present")', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outC1" | jq -e '.actual == "present"' >/dev/null || fail "file-exists {vaultPath} present: (got: $outC1)"
outC2=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'luna-vault-scaffold');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$feC_absent")', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outC2" | jq -e '.actual == "absent"' >/dev/null || fail "file-exists {vaultPath} absent: (got: $outC2)"
echo "ok: file-exists {vaultPath} placeholder (luna-vault-scaffold) present/absent"

# ── settings-key: dot-path single key (wiring-statusline) ─────────────────
sk1_present="$work/sk1-present"; mkdir -p "$sk1_present/.claude"
printf '{"statusLine":{"command":"bash foo.sh"}}' > "$sk1_present/.claude/settings.json"
sk1_absent="$work/sk1-absent"; mkdir -p "$sk1_absent/.claude"
printf '{"statusLine":{}}' > "$sk1_absent/.claude/settings.json"

outSK1p=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'wiring-statusline');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$sk1_present")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSK1p" | jq -e '.actual == "present"' >/dev/null || fail "settings-key dot-path present: (got: $outSK1p)"
outSK1a=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'wiring-statusline');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$sk1_absent")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSK1a" | jq -e '.actual == "absent"' >/dev/null || fail "settings-key dot-path absent: (got: $outSK1a)"
echo "ok: settings-key dot-path single key (wiring-statusline) present/absent"

# ── settings-key: simple non-dotted key (claude-plugins-pluginSet) ─────────
sk2_present="$work/sk2-present"; mkdir -p "$sk2_present/.claude"
printf '{"enabledPlugins":{"foo@bar":true}}' > "$sk2_present/.claude/settings.json"
sk2_absent="$work/sk2-absent"; mkdir -p "$sk2_absent/.claude"
printf '{"enabledPlugins":{}}' > "$sk2_absent/.claude/settings.json"

outSK2p=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'claude-plugins-pluginSet');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$sk2_present")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSK2p" | jq -e '.actual == "present"' >/dev/null || fail "settings-key simple key present: (got: $outSK2p)"
outSK2a=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'claude-plugins-pluginSet');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$sk2_absent")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSK2a" | jq -e '.actual == "absent"' >/dev/null || fail "settings-key simple key absent (empty object): (got: $outSK2a)"
echo "ok: settings-key simple non-dotted key (claude-plugins-pluginSet) present/absent"

# ── settings-key: .env ALL-keys-required union (jira-env-keys) ────────────
# Resolves against repoRoot for BOTH scopes (CLAUDE.md / adopt.sh
# fill_env_core convention) — proven by using scope 'user' here too.
sk3_repo_present="$work/sk3-repo-present"; mkdir -p "$sk3_repo_present"
cat > "$sk3_repo_present/.env" <<'ENV'
JIRA_BASE_URL=https://example.atlassian.net
JIRA_EMAIL=me@example.com
JIRA_API_TOKEN=tok123
JIRA_PROJECT_KEY=HIMMEL
ENV
sk3_repo_missing="$work/sk3-repo-missing"; mkdir -p "$sk3_repo_missing"
cat > "$sk3_repo_missing/.env" <<'ENV'
JIRA_BASE_URL=https://example.atlassian.net
JIRA_EMAIL=me@example.com
JIRA_PROJECT_KEY=HIMMEL
ENV

outSK3p=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'jira-env-keys');
const ctx = { repoRoot: '$(winpath "$sk3_repo_present")', targetPath: '$repo_root_w', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSK3p" | jq -e '.actual == "present"' >/dev/null || fail "settings-key .env all-keys present: (got: $outSK3p)"
outSK3a=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'jira-env-keys');
const ctx = { repoRoot: '$(winpath "$sk3_repo_missing")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSK3a" | jq -e '.actual == "absent"' >/dev/null || fail "settings-key .env missing-one-key absent: (got: $outSK3a)"
echo "$outSK3a" | jq -e '.detail | contains("JIRA_API_TOKEN")' >/dev/null \
  || fail "settings-key .env absent detail should name the missing key JIRA_API_TOKEN (got: $outSK3a)"
echo "ok: settings-key .env ALL-keys-required (jira-env-keys), resolves against repoRoot for both scopes"

# ── settings-hooks: present (3/3) / degraded (1/3) / absent (0) ────────────
sh_present="$work/sh-present"; mkdir -p "$sh_present/.claude"
cat > "$sh_present/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/auto-approve-safe-bash.sh\""}]},
  {"matcher":"Edit","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/block-edit-on-main.sh\""}]},
  {"matcher":"Read","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/block-read-secrets.sh\""}]}
]}}
JSON
sh_degraded="$work/sh-degraded"; mkdir -p "$sh_degraded/.claude"
cat > "$sh_degraded/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/auto-approve-safe-bash.sh\""}]}
]}}
JSON
sh_absent="$work/sh-absent"; mkdir -p "$sh_absent/.claude"
printf '{"hooks":{"PreToolUse":[]}}' > "$sh_absent/.claude/settings.json"

outSHp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'wiring-pretooluse');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$sh_present")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSHp" | jq -e '.actual == "present"' >/dev/null || fail "settings-hooks present (3/3): (got: $outSHp)"
outSHd=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'wiring-pretooluse');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$sh_degraded")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSHd" | jq -e '.actual == "degraded"' >/dev/null || fail "settings-hooks degraded (1/3): (got: $outSHd)"
echo "$outSHd" | jq -e '.detail | contains("block-edit-on-main")' >/dev/null \
  || fail "settings-hooks degraded detail should name a missing marker (got: $outSHd)"
outSHa=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'wiring-pretooluse');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$sh_absent")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSHa" | jq -e '.actual == "absent"' >/dev/null || fail "settings-hooks absent (0/3): (got: $outSHa)"
echo "ok: settings-hooks (wiring-pretooluse) present/degraded/absent"

# ── cmd:has_qmd (qmd-binary) ────────────────────────────────────────────────
hq_present_stub="$work/hq-present-bin"; mkdir -p "$hq_present_stub"
pathHQpresent=$(build_path "$hq_present_stub" bash git jq -- bun)
cat > "$hq_present_stub/qmd" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$hq_present_stub/qmd"

outHQp=$(PATH="$pathHQpresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'qmd-binary');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHQp" | jq -e '.actual == "present"' >/dev/null || fail "cmd:has_qmd present: (got: $outHQp)"

hq_absent_stub="$work/hq-absent-bin"; mkdir -p "$hq_absent_stub"
pathHQabsent=$(build_path "$hq_absent_stub" bash git jq -- bun qmd)
outHQa=$(PATH="$pathHQabsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'qmd-binary');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHQa" | jq -e '.actual == "absent"' >/dev/null || fail "cmd:has_qmd absent: (got: $outHQa)"
echo "ok: cmd:has_qmd (qmd-binary) present/absent"

# ── qmd-index: present (4/4) / degraded (2/4) / absent (no qmd) ───────────
qi_present_stub="$work/qi-present-bin"; mkdir -p "$qi_present_stub"
pathQIpresent=$(build_path "$qi_present_stub" bash git jq -- bun)
cat > "$qi_present_stub/qmd" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "collection" ] && [ "$2" = "list" ]; then
  printf 'himmel\nluna\n'
  exit 0
fi
exit 0
STUB
chmod +x "$qi_present_stub/qmd"
outQIp=$(PATH="$pathQIpresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'qmd-index');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outQIp" | jq -e '.actual == "present"' >/dev/null || fail "qmd-index present (4/4): (got: $outQIp)"

qi_degraded_stub="$work/qi-degraded-bin"; mkdir -p "$qi_degraded_stub"
pathQIdegraded=$(build_path "$qi_degraded_stub" bash git jq -- bun)
cat > "$qi_degraded_stub/qmd" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "collection" ] && [ "$2" = "list" ]; then
  printf 'himmel\n'
  exit 0
fi
exit 0
STUB
chmod +x "$qi_degraded_stub/qmd"
outQId=$(PATH="$pathQIdegraded" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'qmd-index');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outQId" | jq -e '.actual == "degraded"' >/dev/null || fail "qmd-index degraded (2/4): (got: $outQId)"
echo "$outQId" | jq -e '.detail | contains("luna")' >/dev/null \
  || fail "qmd-index degraded detail should name a missing collection (got: $outQId)"

qi_absent_stub="$work/qi-absent-bin"; mkdir -p "$qi_absent_stub"
pathQIabsent=$(build_path "$qi_absent_stub" bash git jq -- bun qmd)
outQIa=$(PATH="$pathQIabsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'qmd-index');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outQIa" | jq -e '.actual == "absent"' >/dev/null || fail "qmd-index absent (no qmd on PATH): (got: $outQIa)"
echo "ok: qmd-index present/degraded/absent"

# ── mcp-registered: present / server missing / file missing / malformed ────
# HIMMEL-1093 round 3: the registered entry's OWN `command` is now ALWAYS
# validated (codex-adv-1) — the fixture's registered command must actually
# resolve for the 'present' case, so it points at a real stub FILE by
# absolute path (fs.existsSync, not PATH-dependent).
mcp_present_home="$work/mcp-present-home"; mkdir -p "$mcp_present_home"
: > "$mcp_present_home/tokensave-mcp-stub"
chmod +x "$mcp_present_home/tokensave-mcp-stub"
printf '{"mcpServers":{"tokensave":{"command":"%s"}}}' "$(winpath "$mcp_present_home/tokensave-mcp-stub")" > "$mcp_present_home/.claude.json"
mcp_server_missing_home="$work/mcp-server-missing-home"; mkdir -p "$mcp_server_missing_home"
printf '{"mcpServers":{"graphify":{"command":"graphify-mcp"}}}' > "$mcp_server_missing_home/.claude.json"
mcp_file_missing_home="$work/mcp-file-missing-home"; mkdir -p "$mcp_file_missing_home"
mcp_null_root_home="$work/mcp-null-root-home"; mkdir -p "$mcp_null_root_home"
printf 'null' > "$mcp_null_root_home/.claude.json"
# CR fix (HIMMEL-1017 CR round): a present-but-UNPARSEABLE config is a
# genuinely different case from a MISSING one — both used to read identically
# (actual:absent, generic "cannot read/parse" detail); configError now
# distinguishes them (see probes.js's probeMcpRegistered).
mcp_malformed_json_home="$work/mcp-malformed-json-home"; mkdir -p "$mcp_malformed_json_home"
printf '{not valid json' > "$mcp_malformed_json_home/.claude.json"

outMCP=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
// A SYNTHETIC descriptor (registration only, no bin/initMarker) — this block
// pins the pre-HIMMEL-1093 registration matrix (present/server-missing/
// file-missing/malformed/configError) in isolation from the HIMMEL-1093
// bin/initMarker deepening, which gets its own dedicated block below against
// the REAL tokensave-mcp descriptor.
const item = { id: 'tokensave-mcp', probe: { type: 'mcp-registered', server: 'tokensave' } };
const probeHome = (home) => runProbe(item, {
  repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: home }),
});
console.log(JSON.stringify([
  probeHome('$(winpath "$mcp_present_home")'),
  probeHome('$(winpath "$mcp_server_missing_home")'),
  probeHome('$(winpath "$mcp_file_missing_home")'),
  probeHome('$(winpath "$mcp_null_root_home")'),
  probeHome('$(winpath "$mcp_malformed_json_home")'),
]));
")
echo "$outMCP" | jq -e '.[0].actual == "present" and .[1].actual == "absent" and .[2].actual == "absent" and .[3].actual == "absent" and .[4].actual == "absent"' >/dev/null \
  || fail "mcp-registered present/server-missing/file-missing/null-root/malformed: (got: $outMCP)"
echo "$outMCP" | jq -e '.[2].detail | contains("does not exist")' >/dev/null \
  || fail "mcp-registered file-missing (ENOENT) detail should report 'does not exist' (got: $outMCP)"
echo "$outMCP" | jq -e '.[3].detail | contains("unexpected JSON shape")' >/dev/null \
  || fail "mcp-registered null-root detail should report unexpected JSON shape (got: $outMCP)"
echo "$outMCP" | jq -e '.[4].detail | contains("cannot read/parse")' >/dev/null \
  || fail "mcp-registered malformed-JSON detail should report cannot read/parse (got: $outMCP)"
# CR fix (HIMMEL-1017 CR round): configError distinguishes a genuinely BROKEN
# config (malformed JSON, unexpected shape) from a clean absence (present-
# but-server-missing, OR the file simply doesn't exist yet — ENOENT is the
# ORDINARY case for project-scope .mcp.json, never an error by itself).
echo "$outMCP" | jq -e '(.[0].configError // false) == false and (.[1].configError // false) == false and (.[2].configError // false) == false' >/dev/null \
  || fail "mcp-registered present/server-missing/file-missing (ENOENT) should carry NO configError (got: $outMCP)"
echo "$outMCP" | jq -e '.[3].configError == true and .[4].configError == true' >/dev/null \
  || fail "mcp-registered null-root/malformed-JSON should carry configError:true (got: $outMCP)"
echo "ok: mcp-registered (tokensave-mcp) present/server-missing/file-missing/null-root/malformed via ctx.env.HOME, configError distinguishes broken config from clean absence"

# ── mcp-registered: scope-aware file resolution (CR fix, HIMMEL-1017 round) ─
# project scope reads <targetPath>/.mcp.json, NOT ~/.claude.json — proven in
# both directions: a project-scope registration in .mcp.json reads present
# even with a DIFFERENT server registered in ~/.claude.json (never bleeds
# across scopes), and a user-scope-only registration is correctly invisible
# to a project-scope probe.
mcp_project_target="$work/mcp-project-target"; mkdir -p "$mcp_project_target"
: > "$mcp_project_target/graphify-mcp-stub"
chmod +x "$mcp_project_target/graphify-mcp-stub"
printf '{"mcpServers":{"graphify":{"command":"%s"}}}' "$(winpath "$mcp_project_target/graphify-mcp-stub")" > "$mcp_project_target/.mcp.json"
mcp_scope_home="$work/mcp-scope-home"; mkdir -p "$mcp_scope_home"
printf '{"mcpServers":{"tokensave":{"command":"tokensave-mcp"}}}' > "$mcp_scope_home/.claude.json"

outScope=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
// Synthetic descriptor again (see the outMCP comment above) — isolates the
// scope-resolution behavior from the HIMMEL-1093 bin deepening on the REAL
// graphify-mcp item.
const graphifyItem = { id: 'graphify-mcp', probe: { type: 'mcp-registered', server: 'graphify' } };
const env = Object.assign({}, process.env, { HOME: '$(winpath "$mcp_scope_home")' });
const projectHit = runProbe(graphifyItem, { repoRoot: '$repo_root_w', targetPath: '$(winpath "$mcp_project_target")', scope: 'project', env });
const userMiss = runProbe(graphifyItem, { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env });
console.log(JSON.stringify({ projectHit, userMiss }));
")
echo "$outScope" | jq -e '.projectHit.actual == "present"' >/dev/null \
  || fail "mcp-registered project-scope should read <targetPath>/.mcp.json, not ~/.claude.json (got: $outScope)"
echo "$outScope" | jq -e '.userMiss.actual == "absent"' >/dev/null \
  || fail "mcp-registered user-scope probe for graphify should NOT see the project-scope .mcp.json registration (got: $outScope)"
echo "ok: mcp-registered is scope-aware — project scope resolves .mcp.json, user scope resolves ~/.claude.json, never cross-bleeding"

# ── mcp-registered: HIMMEL-1093 deepening (bin + initMarker) ───────────────
# Registration alone used to read 'present' even when the wrapped binary is
# gone or the consuming project was never initialized — a registered-but-
# broken server looked identical to a working one. Proven against the REAL
# tokensave-mcp descriptor (bin:"tokensave" + initMarker:".tokensave"), so a
# manifest authoring drift on these fields breaks this suite too. The
# registered command itself is pinned to an absolute-path stub that always
# resolves (round 3's unconditional registered-command check — see below —
# is not what this block is isolating; it only wants bin/initMarker to be
# the thing that varies across the three sub-cases).
mcp_deep_home="$work/mcp-deep-home"; mkdir -p "$mcp_deep_home"
: > "$mcp_deep_home/tokensave-mcp-stub"
chmod +x "$mcp_deep_home/tokensave-mcp-stub"
printf '{"mcpServers":{"tokensave":{"command":"%s"}}}' "$(winpath "$mcp_deep_home/tokensave-mcp-stub")" > "$mcp_deep_home/.claude.json"
mcp_deep_target_init="$work/mcp-deep-target-init"; mkdir -p "$mcp_deep_target_init/.tokensave"
mcp_deep_target_noinit="$work/mcp-deep-target-noinit"; mkdir -p "$mcp_deep_target_noinit"

deep_bin_present="$work/deep-bin-present"; mkdir -p "$deep_bin_present"
pathDeepPresent=$(build_path "$deep_bin_present" bash git jq -- tokensave)
cat > "$deep_bin_present/tokensave" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$deep_bin_present/tokensave"

deep_bin_absent="$work/deep-bin-absent"; mkdir -p "$deep_bin_absent"
pathDeepAbsent=$(build_path "$deep_bin_absent" bash git jq -- tokensave)

outDeepP=$(PATH="$pathDeepPresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'tokensave-mcp');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$mcp_deep_target_init")', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcp_deep_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDeepP" | jq -e '.actual == "present"' >/dev/null \
  || fail "mcp-registered deepened (tokensave-mcp) fully satisfied (bin resolvable + .tokensave present) should read present: (got: $outDeepP)"

outDeepBinMissing=$(PATH="$pathDeepAbsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'tokensave-mcp');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$mcp_deep_target_init")', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcp_deep_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDeepBinMissing" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "mcp-registered deepened (tokensave-mcp) missing binary should read degraded, not present: (got: $outDeepBinMissing)"
echo "$outDeepBinMissing" | jq -e '.detail | contains("not resolvable on PATH")' >/dev/null \
  || fail "mcp-registered deepened missing-bin detail should name the unresolved binary (got: $outDeepBinMissing)"

outDeepNoInit=$(PATH="$pathDeepPresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'tokensave-mcp');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$mcp_deep_target_noinit")', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcp_deep_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDeepNoInit" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "mcp-registered deepened (tokensave-mcp) missing initMarker (no .tokensave/ in target) should read degraded: (got: $outDeepNoInit)"
echo "$outDeepNoInit" | jq -e '.detail | contains("project not initialized")' >/dev/null \
  || fail "mcp-registered deepened missing-initMarker detail should name it (got: $outDeepNoInit)"
echo "ok: mcp-registered deepening (HIMMEL-1093) — registered-but-broken (unresolved bin / uninitialized project) reads degraded, never silently present"

# ── mcp-registered: bin check honors ctx.env, not just process.env ─────────
# CR fix (HIMMEL-1093 round 2, codex-2): which(item.probe.bin) used to read
# process.env.PATH directly, ignoring ctx.env entirely — a hermetic caller
# that already threads a fully-controlled ctx.env (this probe reads
# ctx.env.HOME for its own file resolution) got a WRONG answer if ctx.env's
# PATH differed from the real process env. Proven by DIVERGING the two: the
# OUTER shell's PATH is scrubbed of any real `tokensave` (so node's own
# process.env.PATH, inherited unmodified, cannot resolve it), while ctx.env
# is built with an EXTRA stub dir prepended that process.env.PATH lacks —
# only a fix that actually reads ctx.env.PATH (not process.env.PATH) resolves
# it as present.
deep_bin_ctxonly="$work/deep-bin-ctxonly"; mkdir -p "$deep_bin_ctxonly"
cat > "$deep_bin_ctxonly/tokensave" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$deep_bin_ctxonly/tokensave"
scrub_stub="$work/scrub-stub-bin"; mkdir -p "$scrub_stub"
pathScrubbedOfTokensave=$(build_path "$scrub_stub" bash git jq -- tokensave)
outDeepCtxEnvPath=$(PATH="$pathScrubbedOfTokensave" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'tokensave-mcp');
// ctx.env.PATH carries an EXTRA stub dir process.env.PATH does not.
const ctxOnlyPath = '$(winpath "$deep_bin_ctxonly")' + require('path').delimiter + process.env.PATH;
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$mcp_deep_target_init")', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcp_deep_home")', PATH: ctxOnlyPath }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDeepCtxEnvPath" | jq -e '.actual == "present"' >/dev/null \
  || fail "mcp-registered bin check should resolve via ctx.env.PATH (not just process.env.PATH, which lacks the stub here): (got: $outDeepCtxEnvPath)"
echo "ok: mcp-registered bin check honors ctx.env.PATH for a hermetic caller with a fully-controlled env, diverging from process.env.PATH"

# ── mcp-registered: the REGISTERED command itself must resolve ─────────────
# CR fix (HIMMEL-1093 round 3, codex-adv-1, high): a descriptor-named `bin`
# is a GUESS at what the MCP server wraps — it can name the WRONG binary
# entirely (found live: graphify's real registered command is the MCP
# entrypoint graphify-mcp[.exe], not the bare `graphify` CLI the old
# descriptor checked). The registered entry's OWN `command` is now ALWAYS
# validated, unconditionally, with no descriptor opt-in — using a SYNTHETIC
# descriptor (server only, no bin/initMarker) to isolate this from the
# bin/initMarker deepening tested above.
mcpCmdItem() {
  cat <<'JS'
const item = { id: 'cmd-check', probe: { type: 'mcp-registered', server: 'srv' } };
JS
}

# absolute path, resolves (fs.existsSync) -> present.
mcpcmd_abs_home="$work/mcpcmd-abs-home"; mkdir -p "$mcpcmd_abs_home"
: > "$mcpcmd_abs_home/entrypoint-stub"
chmod +x "$mcpcmd_abs_home/entrypoint-stub"
printf '{"mcpServers":{"srv":{"command":"%s"}}}' "$(winpath "$mcpcmd_abs_home/entrypoint-stub")" > "$mcpcmd_abs_home/.claude.json"
outCmdAbs=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
$(mcpCmdItem)
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcpcmd_abs_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCmdAbs" | jq -e '.actual == "present"' >/dev/null \
  || fail "mcp-registered: an absolute registered command that exists should read present: (got: $outCmdAbs)"

# absolute path, does NOT exist -> degraded, naming the configured command.
mcpcmd_abs_missing_home="$work/mcpcmd-abs-missing-home"; mkdir -p "$mcpcmd_abs_missing_home"
missingAbsCmd="$(winpath "$mcpcmd_abs_missing_home")/does-not-exist-entrypoint"
printf '{"mcpServers":{"srv":{"command":"%s"}}}' "$missingAbsCmd" > "$mcpcmd_abs_missing_home/.claude.json"
outCmdAbsMissing=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
$(mcpCmdItem)
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcpcmd_abs_missing_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCmdAbsMissing" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "mcp-registered: an absolute registered command that does NOT exist should read degraded (got: $outCmdAbsMissing)"
echo "$outCmdAbsMissing" | jq -e '.detail | contains("does not resolve")' >/dev/null \
  || fail "mcp-registered: nonexistent-command detail should say it does not resolve (got: $outCmdAbsMissing)"

# bare name, resolves via PATH (which()) -> present. Reuses the deep-bin
# stub dir from the bin/initMarker block above (already has 'tokensave').
mcpcmd_bare_home="$work/mcpcmd-bare-home"; mkdir -p "$mcpcmd_bare_home"
printf '{"mcpServers":{"srv":{"command":"tokensave"}}}' > "$mcpcmd_bare_home/.claude.json"
outCmdBare=$(PATH="$pathDeepPresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
$(mcpCmdItem)
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcpcmd_bare_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCmdBare" | jq -e '.actual == "present"' >/dev/null \
  || fail "mcp-registered: a bare registered command resolvable via PATH should read present: (got: $outCmdBare)"

# bare name, NOT on PATH -> degraded.
outCmdBareMissing=$(PATH="$pathDeepAbsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
$(mcpCmdItem)
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcpcmd_bare_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCmdBareMissing" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "mcp-registered: a bare registered command NOT on PATH should read degraded: (got: $outCmdBareMissing)"

# null/missing command -> degraded, naming the gap (not a crash).
mcpcmd_null_home="$work/mcpcmd-null-home"; mkdir -p "$mcpcmd_null_home"
printf '{"mcpServers":{"srv":{"command":null}}}' > "$mcpcmd_null_home/.claude.json"
outCmdNull=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
$(mcpCmdItem)
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcpcmd_null_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCmdNull" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "mcp-registered: a null registered command should read degraded, not crash: (got: $outCmdNull)"
echo "$outCmdNull" | jq -e '.detail | contains("no usable command")' >/dev/null \
  || fail "mcp-registered: null-command detail should say no usable command (got: $outCmdNull)"

mcpcmd_no_command_home="$work/mcpcmd-no-command-home"; mkdir -p "$mcpcmd_no_command_home"
printf '{"mcpServers":{"srv":{}}}' > "$mcpcmd_no_command_home/.claude.json"
outCmdNone=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
$(mcpCmdItem)
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcpcmd_no_command_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCmdNone" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "mcp-registered: a registered entry with NO command field should read degraded: (got: $outCmdNone)"
echo "ok: mcp-registered — the registered entry's OWN command is validated (absolute-path resolution / bare-name PATH lookup), unconditionally; a wrong, missing, or nonexistent command reads degraded, never silently present"

# SKIP NOTE (HIMMEL-1093 round 5, codex-2): registeredCommandCheck()'s POSIX
# branch (fs.accessSync(cmd, X_OK) distinguishing "exists but not executable"
# from "does not exist") is gated behind `process.platform === 'win32'` and
# so is STRUCTURALLY UNREACHABLE on this dev/CI machine (win32) — the outCmdAbs/
# outCmdAbsMissing cases above already exercise the win32 existsSync branch
# (unchanged from round 3) for both the resolve/does-not-resolve outcomes,
# but the executability distinction itself has no path to run here. Per the
# CR's own guidance, this is a comment+skip note rather than a fake test:
# stubbing process.platform to force the POSIX branch on a win32 CI runner
# would test a code path that can never actually execute on this box (a
# platform hack producing a false sense of coverage, not a real one). The
# logic itself is a 6-line try/catch around a single documented Node API
# (fs.accessSync + fs.constants.X_OK) with no himmel-specific branching to
# get wrong; real coverage should come from a POSIX runner in CI/a Linux dev
# box, not a Windows-side simulation.

# ── graphify-mcp: bin field DROPPED, relying on the registered-command
# check alone (least-redundant design — see manifest.json's comment on this
# item). Proven live: the REAL server registered under a bare "graphify-mcp"
# name (the actual entrypoint) reads present without any bin field at all.
gmcp_home="$work/gmcp-home"; mkdir -p "$gmcp_home"
printf '{"mcpServers":{"graphify":{"command":"graphify-mcp-entry"}}}' > "$gmcp_home/.claude.json"
gmcp_bin_dir="$work/gmcp-bin"; mkdir -p "$gmcp_bin_dir"
pathGmcp=$(build_path "$gmcp_bin_dir" bash git jq -- graphify-mcp-entry)
cat > "$gmcp_bin_dir/graphify-mcp-entry" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$gmcp_bin_dir/graphify-mcp-entry"
outGmcp=$(PATH="$pathGmcp" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'graphify-mcp');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$gmcp_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGmcp" | jq -e '.actual == "present"' >/dev/null \
  || fail "graphify-mcp (no bin field): registered command resolvable via PATH should read present on the registered-command check alone: (got: $outGmcp)"
echo "ok: graphify-mcp's dropped bin field is redundant — the registered-command check alone correctly validates its REAL entrypoint"

# ── handover-dir (handover-wiring) ──────────────────────────────────────────
hd_present_dir="$work/hd-present-handoverdir"; mkdir -p "$hd_present_dir"
outHDp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'handover-wiring');
const env = Object.assign({}, process.env, { HANDOVER_DIR: '$(winpath "$hd_present_dir")' });
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'project', env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHDp" | jq -e '.actual == "present"' >/dev/null || fail "handover-dir present (HANDOVER_DIR set via ctx.env): (got: $outHDp)"

hd_absent_cwd="$work/hd-absent-not-a-repo"; mkdir -p "$hd_absent_cwd"
outHDa=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'handover-wiring');
const env = Object.assign({}, process.env);
delete env.HANDOVER_DIR;
const ctx = { repoRoot: '$(winpath "$hd_absent_cwd")', targetPath: '$(winpath "$hd_absent_cwd")', scope: 'project', env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHDa" | jq -e '.actual == "absent"' >/dev/null \
  || fail "handover-dir absent (HANDOVER_DIR unset, cwd not a git repo, no inline handovers/): (got: $outHDa)"
echo "ok: handover-dir (handover-wiring) present/absent, exercising ctx.env pass-through"

# ── dep: single-cmd (rtk) ────────────────────────────────────────────────────
dep_present_stub="$work/dep-present-bin"; mkdir -p "$dep_present_stub"
pathDeppresent=$(build_path "$dep_present_stub" bash git jq -- rtk)
cat > "$dep_present_stub/rtk" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$dep_present_stub/rtk"
outDepP=$(PATH="$pathDeppresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'rtk');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDepP" | jq -e '.actual == "present"' >/dev/null || fail "dep single-cmd (rtk) present: (got: $outDepP)"

dep_absent_stub="$work/dep-absent-bin"; mkdir -p "$dep_absent_stub"
pathDepabsent=$(build_path "$dep_absent_stub" bash git jq -- rtk)
outDepA=$(PATH="$pathDepabsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'rtk');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDepA" | jq -e '.actual == "absent"' >/dev/null || fail "dep single-cmd (rtk) absent: (got: $outDepA)"
echo "ok: dep single-cmd (rtk) present/absent"

# ── dep: win32/posix platform union (scheduler-backend) ────────────────────
if is_win32; then sched_name="schtasks"; else sched_name="at"; fi

dep_sched_present="$work/dep-sched-present-bin"; mkdir -p "$dep_sched_present"
pathSchedPresent=$(build_path "$dep_sched_present" bash git jq -- "$sched_name")
cat > "$dep_sched_present/$sched_name" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$dep_sched_present/$sched_name"
outSchedP=$(PATH="$pathSchedPresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'scheduler-backend');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSchedP" | jq -e '.actual == "present"' >/dev/null \
  || fail "dep platform-branch (scheduler-backend, $sched_name) present: (got: $outSchedP)"

dep_sched_absent="$work/dep-sched-absent-bin"; mkdir -p "$dep_sched_absent"
pathSchedAbsent=$(build_path "$dep_sched_absent" bash git jq -- "$sched_name")
outSchedA=$(PATH="$pathSchedAbsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'scheduler-backend');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSchedA" | jq -e '.actual == "absent"' >/dev/null \
  || fail "dep platform-branch (scheduler-backend, $sched_name) absent: (got: $outSchedA)"
echo "ok: dep platform-branch (scheduler-backend) picks '$sched_name' on this platform, present/absent"

# ── dep (graphify) — HIMMEL-1093 ─────────────────────────────────────────────
# Used to be file-exists on scripts/graphify/check-graph-freshness.sh, a
# git-TRACKED script — always 'present' on any himmel checkout regardless of
# whether graphify is actually installed. Now a plain PATH lookup, like
# tokensave-binary/rtk/every other real dep item.
gp_present_stub="$work/gp-present-bin"; mkdir -p "$gp_present_stub"
pathGPpresent=$(build_path "$gp_present_stub" bash git jq -- graphify)
cat > "$gp_present_stub/graphify" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$gp_present_stub/graphify"
outGPp=$(PATH="$pathGPpresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'graphify');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGPp" | jq -e '.actual == "present"' >/dev/null || fail "dep (graphify) present: (got: $outGPp)"

gp_absent_stub="$work/gp-absent-bin"; mkdir -p "$gp_absent_stub"
pathGPabsent=$(build_path "$gp_absent_stub" bash git jq -- graphify)
outGPa=$(PATH="$pathGPabsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'graphify');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGPa" | jq -e '.actual == "absent"' >/dev/null || fail "dep (graphify) absent: (got: $outGPa)"
echo "ok: dep (graphify) present/absent — no longer a tautological file-exists on a tracked script"

# ── cmd:has_hermes (hermes-lanes) — HIMMEL-1093 ──────────────────────────────
# Used to be file-exists on scripts/lanes/lanes.json (also git-TRACKED,
# always present). Now runs `. resolver || exit 3; resolve_hermes_py`,
# mirroring cmd:is_himmel_dev's shape exactly (round 4 CR fix: this branch
# INTRODUCED cmd:has_hermes with the same absent-vs-degraded conflation
# cmd:is_himmel_dev already got fixed in round 2 — ships consistent instead
# of repeating the bug): rc 0 present, rc 3 degraded (resolver itself failed
# to source — probe wiring broken), resolve_hermes_py's own nonzero ->
# absent (sourced fine, hermes genuinely not installed — the ordinary case).
hh_repo_present="$work/hh-repo-present"; mkdir -p "$hh_repo_present/scripts/lib"
cat > "$hh_repo_present/scripts/lib/resolve-hermes-py.sh" <<'SH'
resolve_hermes_py() { printf '%s\n' "/fake/venv/python"; return 0; }
SH
outHHp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-lanes');
const ctx = { repoRoot: '$(winpath "$hh_repo_present")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHHp" | jq -e '.actual == "present"' >/dev/null || fail "cmd:has_hermes present: (got: $outHHp)"

hh_repo_absent="$work/hh-repo-absent"; mkdir -p "$hh_repo_absent/scripts/lib"
cat > "$hh_repo_absent/scripts/lib/resolve-hermes-py.sh" <<'SH'
resolve_hermes_py() { return 1; }
SH
outHHa=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-lanes');
const ctx = { repoRoot: '$(winpath "$hh_repo_absent")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHHa" | jq -e '.actual == "absent"' >/dev/null || fail "cmd:has_hermes absent: (got: $outHHa)"
echo "ok: cmd:has_hermes (hermes-lanes) present/absent — no longer a tautological file-exists on a tracked registry file"

# ── cmd:has_hermes: resolver missing -> degraded, NOT absent (CR fix, ──────
# HIMMEL-1093 round 4). No scripts/lib/resolve-hermes-py.sh at all — `.`
# fails to source it, hitting the `|| exit 3` guard. Must not read the same
# 'absent' as hermes genuinely-not-installed.
hh_no_resolver="$work/hh-no-resolver"; mkdir -p "$hh_no_resolver/scripts/lib"
outHHnr=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-lanes');
const ctx = { repoRoot: '$(winpath "$hh_no_resolver")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHHnr" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:has_hermes degraded (resolver missing — probe wiring broken, not a clean absence): (got: $outHHnr)"
echo "$outHHnr" | jq -e '.detail | contains("cannot source resolver")' >/dev/null \
  || fail "cmd:has_hermes missing-resolver detail should name the sourcing failure (got: $outHHnr)"
echo "ok: cmd:has_hermes — a missing/unreadable resolver reads degraded, distinguished from hermes genuinely not installed"

# ── cmd:has_hermes: spawn error -> degraded, NOT absent (CR fix, ───────────
# HIMMEL-1093 round 4). ctx.env with an empty PATH makes 'bash' itself
# unresolvable to spawnSync, exercising the r.error branch.
outHHse=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-lanes');
const ctx = { repoRoot: '$(winpath "$hh_repo_present")', targetPath: '$repo_root_w', scope: 'user', env: { PATH: '' } };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHHse" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:has_hermes degraded (spawn error, bash unresolvable): (got: $outHHse)"
echo "$outHHse" | jq -e '.detail | contains("spawn error")' >/dev/null \
  || fail "cmd:has_hermes spawn-error detail should name it (got: $outHHse)"
echo "ok: cmd:has_hermes — a spawn error (bash unresolvable) reads degraded, not absent"

# ── cmd:has_hermes: unexpected rc (127 — resolver sourced fine but never ───
# defined resolve_hermes_py) -> degraded, NOT absent (CR fix, HIMMEL-1093
# round 6, codex-2). A stale/mismatched resolver is a WIRING problem, never
# a clean "hermes not installed" (resolve_hermes_py's own rc 1) — the old
# fallback-to-absent conflated ANY nonzero rc, including this one.
hh_no_fn="$work/hh-no-fn"; mkdir -p "$hh_no_fn/scripts/lib"
cat > "$hh_no_fn/scripts/lib/resolve-hermes-py.sh" <<'SH'
# sources cleanly but deliberately does NOT define resolve_hermes_py
SH
outHHnf=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-lanes');
const ctx = { repoRoot: '$(winpath "$hh_no_fn")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHHnf" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:has_hermes degraded (unexpected rc — resolver sourced but resolve_hermes_py undefined, rc 127): (got: $outHHnf)"
echo "$outHHnf" | jq -e '.detail | contains("unexpected rc")' >/dev/null \
  || fail "cmd:has_hermes unexpected-rc detail should name it (got: $outHHnf)"
echo "ok: cmd:has_hermes — an unexpected rc (127, resolver sourced but the function was never defined) reads degraded, never a clean absent"

# ── cmd:is_himmel_dev (doc-guard-map) — HIMMEL-1093 ──────────────────────────
# Used to be file-exists on scripts/lib/doc-guard-map.sh (repoRoot-forced,
# also git-TRACKED — always present). Now runs `. resolver || exit 3;
# is_himmel_dev_repo`: rc 0 present, rc 1 absent (sourced fine, not a dev
# checkout — the ordinary case), rc 2 degraded (repo root unresolvable),
# rc 3 degraded (resolver itself failed to source — CR fix, HIMMEL-1093
# round 2: this used to be indistinguishable from rc 1's clean absence, so a
# genuinely broken probe wiring read as "gate off by choice").
idh_present="$work/idh-present"; mkdir -p "$idh_present/scripts/guardrails"
cat > "$idh_present/scripts/guardrails/lib.sh" <<'SH'
is_himmel_dev_repo() { return 0; }
SH
outIDHp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'doc-guard-map');
const ctx = { repoRoot: '$(winpath "$idh_present")', targetPath: '$(winpath "$idh_present")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outIDHp" | jq -e '.actual == "present"' >/dev/null || fail "cmd:is_himmel_dev present (marker present): (got: $outIDHp)"

idh_absent="$work/idh-absent"; mkdir -p "$idh_absent/scripts/guardrails"
cat > "$idh_absent/scripts/guardrails/lib.sh" <<'SH'
is_himmel_dev_repo() { return 1; }
SH
outIDHa=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'doc-guard-map');
const ctx = { repoRoot: '$(winpath "$idh_absent")', targetPath: '$(winpath "$idh_absent")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outIDHa" | jq -e '.actual == "absent"' >/dev/null || fail "cmd:is_himmel_dev absent (marker absent, the common case): (got: $outIDHa)"

idh_error="$work/idh-error"; mkdir -p "$idh_error/scripts/guardrails"
cat > "$idh_error/scripts/guardrails/lib.sh" <<'SH'
is_himmel_dev_repo() { return 2; }
SH
outIDHe=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'doc-guard-map');
const ctx = { repoRoot: '$(winpath "$idh_error")', targetPath: '$(winpath "$idh_error")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outIDHe" | jq -e '.actual == "degraded"' >/dev/null || fail "cmd:is_himmel_dev degraded (rc=2, cannot resolve repo root): (got: $outIDHe)"
echo "ok: cmd:is_himmel_dev (doc-guard-map) present/absent/degraded — no longer a tautological file-exists on a tracked script"

# ── cmd:is_himmel_dev: resolver missing -> degraded, NOT absent (CR fix, ────
# HIMMEL-1093 round 2, codex-1). No scripts/guardrails/lib.sh at all — `.`
# fails to source it, hitting the `|| exit 3` guard. Must not read the same
# 'absent' as a genuinely-not-a-dev-checkout marker, or status-report.js's
# opt-in downgrade would swallow a broken probe into a friendly "gate off".
idh_no_resolver="$work/idh-no-resolver"; mkdir -p "$idh_no_resolver/scripts/guardrails"
outIDHnr=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'doc-guard-map');
const ctx = { repoRoot: '$(winpath "$idh_no_resolver")', targetPath: '$(winpath "$idh_no_resolver")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outIDHnr" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:is_himmel_dev degraded (resolver missing — probe wiring broken, not a clean absence): (got: $outIDHnr)"
echo "$outIDHnr" | jq -e '.detail | contains("cannot source resolver")' >/dev/null \
  || fail "cmd:is_himmel_dev missing-resolver detail should name the sourcing failure (got: $outIDHnr)"
echo "ok: cmd:is_himmel_dev — a missing/unreadable resolver reads degraded, distinguished from a genuinely absent marker"

# ── cmd:is_himmel_dev: spawn error -> degraded, NOT absent (CR fix, ─────────
# HIMMEL-1093 round 2, codex-1). ctx.env with an empty PATH makes 'bash'
# itself unresolvable to spawnSync, exercising the r.error branch.
outIDHse=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'doc-guard-map');
const ctx = { repoRoot: '$(winpath "$idh_present")', targetPath: '$(winpath "$idh_present")', scope: 'project', env: { PATH: '' } };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outIDHse" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:is_himmel_dev degraded (spawn error, bash unresolvable): (got: $outIDHse)"
echo "$outIDHse" | jq -e '.detail | contains("spawn error")' >/dev/null \
  || fail "cmd:is_himmel_dev spawn-error detail should name it (got: $outIDHse)"

# ── cmd:is_himmel_dev: unexpected rc (127 — resolver sourced fine but ──────
# never defined is_himmel_dev_repo) -> degraded, NOT absent (CR fix,
# HIMMEL-1093 round 6, codex-2). A stale/mismatched resolver is a WIRING
# problem, never a clean "not a dev checkout" (is_himmel_dev_repo's own
# rc 1) — the old fallback-to-absent conflated ANY nonzero rc, including
# this one, which status-report.js's opt-in handler would then have
# silently downgraded to a friendly "gate off" n/a.
idh_no_fn="$work/idh-no-fn"; mkdir -p "$idh_no_fn/scripts/guardrails"
cat > "$idh_no_fn/scripts/guardrails/lib.sh" <<'SH'
# sources cleanly but deliberately does NOT define is_himmel_dev_repo
SH
outIDHnf=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'doc-guard-map');
const ctx = { repoRoot: '$(winpath "$idh_no_fn")', targetPath: '$(winpath "$idh_no_fn")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outIDHnf" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:is_himmel_dev degraded (unexpected rc — resolver sourced but is_himmel_dev_repo undefined, rc 127): (got: $outIDHnf)"
echo "$outIDHnf" | jq -e '.detail | contains("unexpected rc")' >/dev/null \
  || fail "cmd:is_himmel_dev unexpected-rc detail should name it (got: $outIDHnf)"
echo "ok: cmd:is_himmel_dev — an unexpected rc (127, resolver sourced but the function was never defined) reads degraded, never a clean absent"
echo "ok: cmd:is_himmel_dev — a spawn error (bash unresolvable) reads degraded, not absent"

# ── telegram-access (telegram-bridge) — HIMMEL-1093 round 3 (codex-adv-3) ──
# Used to be a plain settings-key check on TELEGRAM_BOT_TOKEN — green for a
# bridge that would reject every DM/group (gate.ts's isAllowed()/
# isAllowedGroup() fail CLOSED on a missing/empty allowFrom with no groups).
# Now checks both the token AND access.json's usable-allow-rule shape: token
# absent -> absent; token present but access.json missing / unparseable /
# no usable allow rule -> degraded; both -> present.
telegramHome() {
  local name="$1"; mkdir -p "$work/$name/.claude/channels/telegram"; printf '%s' "$work/$name"
}

# no token at all -> absent, regardless of access.json.
tb_no_token=$(telegramHome "tb-no-token")
cat > "$tb_no_token/.claude/channels/telegram/access.json" <<'JSON'
{"allowFrom":["12345"]}
JSON
outTBnoToken=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$tb_no_token")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outTBnoToken" | jq -e '.actual == "absent"' >/dev/null \
  || fail "telegram-access: no TELEGRAM_BOT_TOKEN should read absent regardless of access.json: (got: $outTBnoToken)"
echo "ok: telegram-access — no token reads absent"

# token present, access.json MISSING entirely -> degraded.
tb_token_only=$(telegramHome "tb-token-only")
cat > "$tb_token_only/.claude/channels/telegram/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=123:abc
ENV
outTBtokenOnly=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$tb_token_only")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outTBtokenOnly" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "telegram-access: token present but access.json missing should read degraded (would gate out everything): (got: $outTBtokenOnly)"
echo "$outTBtokenOnly" | jq -e '.detail | test("gated out"; "i")' >/dev/null \
  || fail "telegram-access: missing-access.json detail should warn everything gets gated out (got: $outTBtokenOnly)"
echo "ok: telegram-access — token present, access.json missing reads degraded"

# token present, access.json MALFORMED (unparseable) -> degraded.
tb_malformed=$(telegramHome "tb-malformed")
cat > "$tb_malformed/.claude/channels/telegram/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=123:abc
ENV
printf '{not valid json' > "$tb_malformed/.claude/channels/telegram/access.json"
outTBmalformed=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$tb_malformed")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outTBmalformed" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "telegram-access: token present but access.json unparseable should read degraded: (got: $outTBmalformed)"
echo "ok: telegram-access — token present, access.json malformed reads degraded"

# token present, access.json parses but carries NO usable allow rule (empty
# allowFrom, no groups) -> degraded.
tb_empty_rules=$(telegramHome "tb-empty-rules")
cat > "$tb_empty_rules/.claude/channels/telegram/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=123:abc
ENV
cat > "$tb_empty_rules/.claude/channels/telegram/access.json" <<'JSON'
{"dmPolicy":"allowlist","allowFrom":[],"groups":{}}
JSON
outTBemptyRules=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$tb_empty_rules")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outTBemptyRules" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "telegram-access: empty allowFrom and no groups should read degraded (nothing would ever be allowed): (got: $outTBemptyRules)"
echo "$outTBemptyRules" | jq -e '.detail | test("no usable allow rule"; "i")' >/dev/null \
  || fail "telegram-access: empty-rules detail should name the missing allow rule (got: $outTBemptyRules)"
echo "ok: telegram-access — token present, access.json with no usable allow rule reads degraded"

# token present, access.json carries a real allowFrom -> present.
tb_valid=$(telegramHome "tb-valid")
cat > "$tb_valid/.claude/channels/telegram/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=123:abc
ENV
cat > "$tb_valid/.claude/channels/telegram/access.json" <<'JSON'
{"dmPolicy":"allowlist","allowFrom":["12345"]}
JSON
outTBvalid=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$tb_valid")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outTBvalid" | jq -e '.actual == "present"' >/dev/null \
  || fail "telegram-access: token + a real allowFrom should read present: (got: $outTBvalid)"
echo "ok: telegram-access — token + valid access.json (non-empty allowFrom) reads present"

# token present, access.json has NO allowFrom but a real groups entry ->
# present too (gate.ts admits a present group key with no per-group
# allowFrom — see the module comment in probes.js).
tb_group_only=$(telegramHome "tb-group-only")
cat > "$tb_group_only/.claude/channels/telegram/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=123:abc
ENV
cat > "$tb_group_only/.claude/channels/telegram/access.json" <<'JSON'
{"groups":{"-100123":{}}}
JSON
outTBgroupOnly=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$tb_group_only")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outTBgroupOnly" | jq -e '.actual == "present"' >/dev/null \
  || fail "telegram-access: token + a groups-only access.json (no top-level allowFrom) should read present: (got: $outTBgroupOnly)"
echo "ok: telegram-access — token + a groups-only access.json reads present, no longer a tautological file-exists on a tracked script"

# ── file-exists: {homePath} placeholder (obsidian-second-brain) — HIMMEL-1100
osb_home_present="$work/osb-home-present"; mkdir -p "$osb_home_present/.claude/plugins/obsidian-second-brain/.git"
outOSBp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'obsidian-second-brain');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$osb_home_present")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outOSBp" | jq -e '.actual == "present"' >/dev/null || fail "file-exists {homePath} (obsidian-second-brain) present: (got: $outOSBp)"

osb_home_absent="$work/osb-home-absent"; mkdir -p "$osb_home_absent"
outOSBa=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'obsidian-second-brain');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$osb_home_absent")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outOSBa" | jq -e '.actual == "absent"' >/dev/null || fail "file-exists {homePath} (obsidian-second-brain) absent: (got: $outOSBa)"
echo "ok: file-exists {homePath} placeholder (obsidian-second-brain) present/absent"

# ── cmd:codex_provisioned (codex-cli) — HIMMEL-1100 ─────────────────────────
# CR fix (round 3, codex-adv-2): the fixture must plant a himmel-marketplace
# cache ENTRY (matching install-himmel-codex.sh's own MARKET="himmel"
# constant), not just an empty plugins/cache dir — see the probe's own
# comment for why a bare cache dir is not himmel-specific evidence.
codex_home_present="$work/codex-home-present"; mkdir -p "$codex_home_present/plugins/cache/himmel/himmel-ops/0.1.0"
codex_bin_stub="$work/codex-bin-stub"
: > "$codex_bin_stub"
chmod +x "$codex_bin_stub"

outCodexP=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CODEX_BIN: '$(winpath "$codex_bin_stub")', CODEX_HOME: '$(winpath "$codex_home_present")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCodexP" | jq -e '.actual == "present"' >/dev/null || fail "cmd:codex_provisioned present (bin resolves + himmel-marketplace plugin cache exists): (got: $outCodexP)"

# CR fix (round 3, codex-adv-2): a NON-empty cache dir with entries for OTHER
# marketplaces only (no himmel/ subdir at all) must NOT read present — codex
# itself is clearly in real use, but the himmel companion specifically was
# never provisioned.
codex_home_other_market="$work/codex-home-other-market"; mkdir -p "$codex_home_other_market/plugins/cache/openai-bundled/some-plugin/1.0.0"
outCodexOM=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CODEX_BIN: '$(winpath "$codex_bin_stub")', CODEX_HOME: '$(winpath "$codex_home_other_market")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCodexOM" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:codex_provisioned degraded (cache has OTHER marketplaces only, no himmel/ subdir): (got: $outCodexOM)"
echo "$outCodexOM" | jq -e '.detail | contains("himmel companion is not provisioned")' >/dev/null \
  || fail "cmd:codex_provisioned other-marketplace-only detail should name the himmel-specific gap (got: $outCodexOM)"

codex_home_no_cache="$work/codex-home-no-cache"; mkdir -p "$codex_home_no_cache"
outCodexD=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CODEX_BIN: '$(winpath "$codex_bin_stub")', CODEX_HOME: '$(winpath "$codex_home_no_cache")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCodexD" | jq -e '.actual == "degraded"' >/dev/null || fail "cmd:codex_provisioned degraded (bin resolves, no plugin cache — never provisioned): (got: $outCodexD)"
echo "$outCodexD" | jq -e '.detail | contains("never provisioned")' >/dev/null || fail "cmd:codex_provisioned degraded detail should say never provisioned (got: $outCodexD)"

codex_scrub_stub="$work/codex-scrub-bin"; mkdir -p "$codex_scrub_stub"
pathCodexScrubbed=$(build_path "$codex_scrub_stub" bash git jq -- codex)
outCodexA=$(PATH="$pathCodexScrubbed" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-cli');
const env = Object.assign({}, process.env);
delete env.CODEX_BIN;
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCodexA" | jq -e '.actual == "absent"' >/dev/null || fail "cmd:codex_provisioned absent (codex not on PATH, no CODEX_BIN): (got: $outCodexA)"

outCodexAoverride=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CODEX_BIN: '$(winpath "$work")/nonexistent-codex' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCodexAoverride" | jq -e '.actual == "absent"' >/dev/null || fail "cmd:codex_provisioned absent (CODEX_BIN set but unusable, no PATH fallback): (got: $outCodexAoverride)"
echo "$outCodexAoverride" | jq -e '.detail | contains("CODEX_BIN set but")' >/dev/null || fail "cmd:codex_provisioned CODEX_BIN-unusable detail should name it (got: $outCodexAoverride)"
echo "ok: cmd:codex_provisioned (codex-cli) present/degraded/absent, including CODEX_BIN override semantics"

# ── cmd:codex_provisioned: ctx.env HOME/CODEX_HOME divergence — HIMMEL-1100 ─
# CR fix (round 2, codex-1): the codexHome resolution used to read the REAL
# os.homedir() whenever CODEX_HOME was unset, ignoring ctx.env.HOME entirely
# — the same hermeticity class as which()'s HIMMEL-1093 round-5 fix. Proven
# with a MINIMAL ctx.env (no process.env spread at all) carrying only
# CODEX_BIN + a HOME that diverges from the real process env — only a fix
# that actually reads ctx.env.HOME can find the plugin cache planted there.
codex_ctxenv_home="$work/codex-ctxenv-home"; mkdir -p "$codex_ctxenv_home/.codex/plugins/cache/himmel/himmel-ops/0.1.0"
codex_ctxenv_bin="$work/codex-ctxenv-bin"; : > "$codex_ctxenv_bin"; chmod +x "$codex_ctxenv_bin"
outCodexCtxEnv=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: { CODEX_BIN: '$(winpath "$codex_ctxenv_bin")', HOME: '$(winpath "$codex_ctxenv_home")' } };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCodexCtxEnv" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:codex_provisioned should resolve the plugin cache via ctx.env.HOME (not process.env/os.homedir()): (got: $outCodexCtxEnv)"
echo "ok: cmd:codex_provisioned honors ctx.env.HOME for a hermetic caller with a fully-controlled env, diverging from process.env"

# An explicit ctx.env.CODEX_HOME wins over the HOME-derived default — the
# fixture HOME here deliberately carries NO .codex/plugins/cache, so a fix
# that fell back to the HOME-derived path instead of the explicit CODEX_HOME
# would misread this as degraded.
codex_ctxenv_home2="$work/codex-ctxenv-home2"; mkdir -p "$codex_ctxenv_home2"
codex_ctxenv_codexhome="$work/codex-ctxenv-codexhome"; mkdir -p "$codex_ctxenv_codexhome/plugins/cache/himmel/himmel-ops/0.1.0"
outCodexCtxEnv2=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: { CODEX_BIN: '$(winpath "$codex_ctxenv_bin")', HOME: '$(winpath "$codex_ctxenv_home2")', CODEX_HOME: '$(winpath "$codex_ctxenv_codexhome")' } };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCodexCtxEnv2" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:codex_provisioned: explicit ctx.env.CODEX_HOME should win over the HOME-derived default (got: $outCodexCtxEnv2)"
echo "ok: cmd:codex_provisioned honors an explicit ctx.env.CODEX_HOME over the HOME-derived default"

# CodeRabbit fix (HIMMEL-1100 round 6, coderabbit-1): CODEX_HOME PRESENT
# but set to an EMPTY STRING — path.join('', 'plugins', 'cache') produces a
# RELATIVE path, which existsSync would resolve against the wrong thing
# (the current process's cwd) if not guarded. Must read degraded, naming
# the bad value — never silently probe cwd.
outCodexEmptyHome=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: { CODEX_BIN: '$(winpath "$codex_ctxenv_bin")', HOME: '$(winpath "$codex_ctxenv_home2")', CODEX_HOME: '' } };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCodexEmptyHome" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:codex_provisioned degraded (CODEX_HOME present but empty-string -> relative path, must not probe cwd): (got: $outCodexEmptyHome)"
echo "$outCodexEmptyHome" | jq -e '.detail | contains("non-absolute")' >/dev/null \
  || fail "cmd:codex_provisioned empty-CODEX_HOME detail should name the non-absolute path (got: $outCodexEmptyHome)"
echo "ok: cmd:codex_provisioned degraded when CODEX_HOME is present but empty (relative-path guard)"

# ── cmd:cadence_armed (pipeline-cadence) — HIMMEL-1100 ──────────────────────
pc_armed_dir="$work/pc-armed-dir"; mkdir -p "$pc_armed_dir"
cat > "$pc_armed_dir/pipeline-harvest.sh" <<'SH'
# himmel-cadence-runner-format: 7
SH
outPCp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'pipeline-cadence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { PIPELINE_BAT_DIR: '$(winpath "$pc_armed_dir")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPCp" | jq -e '.actual == "present"' >/dev/null || fail "cmd:cadence_armed present (pipeline-cadence armed): (got: $outPCp)"

pc_unarmed_dir="$work/pc-unarmed-dir"; mkdir -p "$pc_unarmed_dir"
outPCa=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'pipeline-cadence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { PIPELINE_BAT_DIR: '$(winpath "$pc_unarmed_dir")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPCa" | jq -e '.actual == "absent"' >/dev/null || fail "cmd:cadence_armed absent (pipeline-cadence not armed): (got: $outPCa)"
echo "$outPCa" | jq -e '.detail | contains("not armed")' >/dev/null || fail "cmd:cadence_armed absent detail should say not armed (got: $outPCa)"

pc_no_resolver="$work/pc-no-resolver"; mkdir -p "$pc_no_resolver/scripts/lib"
outPCnr=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'pipeline-cadence');
const ctx = { repoRoot: '$(winpath "$pc_no_resolver")', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { PIPELINE_BAT_DIR: '$(winpath "$pc_unarmed_dir")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPCnr" | jq -e '.actual == "degraded"' >/dev/null || fail "cmd:cadence_armed degraded (resolver missing — probe wiring broken): (got: $outPCnr)"
echo "$outPCnr" | jq -e '.detail | contains("cannot source resolver")' >/dev/null || fail "cmd:cadence_armed missing-resolver detail should name the sourcing failure (got: $outPCnr)"

outPCse=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'pipeline-cadence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: { PATH: '', PIPELINE_BAT_DIR: '$(winpath "$pc_unarmed_dir")' } };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPCse" | jq -e '.actual == "degraded"' >/dev/null || fail "cmd:cadence_armed degraded (spawn error, bash unresolvable): (got: $outPCse)"
echo "$outPCse" | jq -e '.detail | contains("spawn error")' >/dev/null || fail "cmd:cadence_armed spawn-error detail should name it (got: $outPCse)"

pc_bad_fn="$work/pc-bad-fn"; mkdir -p "$pc_bad_fn/scripts/lib"
cat > "$pc_bad_fn/scripts/lib/cadence-format.sh" <<'SH'
cadence_runner_stamp() { return 5; }
SH
outPCnf=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'pipeline-cadence');
const ctx = { repoRoot: '$(winpath "$pc_bad_fn")', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { PIPELINE_BAT_DIR: '$(winpath "$pc_unarmed_dir")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPCnf" | jq -e '.actual == "degraded"' >/dev/null || fail "cmd:cadence_armed degraded (unexpected rc=5 from cadence_runner_stamp): (got: $outPCnf)"
echo "$outPCnf" | jq -e '.detail | contains("unexpected rc")' >/dev/null || fail "cmd:cadence_armed unexpected-rc detail should name it (got: $outPCnf)"
echo "ok: cmd:cadence_armed (pipeline-cadence) present/absent/degraded (resolver missing / spawn error / unexpected rc)"

# CodeRabbit fix (HIMMEL-1100 round 6, coderabbit-3): cadence_runner_stamp
# conflates "genuinely unarmed" and "dir exists but unreadable" into the
# SAME rc 1 — the absent-vs-degraded conflation this whole ticket exists to
# kill. Pre-checked in the probe script via a distinct exit code (4). On
# Windows/NTFS, chmod 000 does not reliably deny the OWNING user read
# access the way it does on POSIX — detected here (not assumed) via a real
# bash `[ -r ... ]` probe against the fixture BEFORE asserting anything, so
# this skips cleanly (with a note) instead of false-failing on a platform
# where the fixture itself can't be constructed; POSIX CI exercises it.
pc_unreadable_dir="$work/pc-unreadable-dir"; mkdir -p "$pc_unreadable_dir"
chmod 000 "$pc_unreadable_dir" 2>/dev/null || true
if bash -c "[ -r \"$(winpath "$pc_unreadable_dir")\" ]" 2>/dev/null; then
  chmod 755 "$pc_unreadable_dir" 2>/dev/null || true
  echo "ok: cmd:cadence_armed unreadable-dir case SKIPPED — chmod 000 is not enforced for the owning user on this platform (Windows/NTFS); POSIX CI exercises it"
else
  outPCur=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'pipeline-cadence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { PIPELINE_BAT_DIR: '$(winpath "$pc_unreadable_dir")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
  chmod 755 "$pc_unreadable_dir" 2>/dev/null || true
  echo "$outPCur" | jq -e '.actual == "degraded"' >/dev/null \
    || fail "cmd:cadence_armed degraded (dir exists but is not readable — distinct from genuinely unarmed): (got: $outPCur)"
  echo "$outPCur" | jq -e '.detail | contains("not readable")' >/dev/null \
    || fail "cmd:cadence_armed unreadable-dir detail should name it (got: $outPCur)"
  echo "ok: cmd:cadence_armed — an existing-but-unreadable dir reads degraded, distinguished from genuinely unarmed (absent)"
fi

# ── cmd:cadence_armed: envVar/defaultSubdir wiring sanity for the other two ──
# cadences (codex-sweep-cadence, graphmap-cadence) — the full present/absent/
# degraded matrix is pinned once above for the shared probe TYPE; this
# confirms each item's OWN envVar override actually routes to ITS OWN dir,
# not a shared/copy-pasted one.
csc_armed_dir="$work/csc-armed-dir"; mkdir -p "$csc_armed_dir"
cat > "$csc_armed_dir/codex-sweep.bat" <<'BAT'
rem himmel-cadence-runner-format: 7
BAT
outCSCp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-sweep-cadence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { SWEEP_BAT_DIR: '$(winpath "$csc_armed_dir")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCSCp" | jq -e '.actual == "present"' >/dev/null || fail "cmd:cadence_armed (codex-sweep-cadence) present via SWEEP_BAT_DIR: (got: $outCSCp)"

gc_armed_dir="$work/gc-armed-dir"; mkdir -p "$gc_armed_dir"
cat > "$gc_armed_dir/graphmap-luna.sh" <<'SH'
# himmel-cadence-runner-format: 7
SH
outGCp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'graphmap-cadence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { GRAPHMAP_BAT_DIR: '$(winpath "$gc_armed_dir")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGCp" | jq -e '.actual == "present"' >/dev/null || fail "cmd:cadence_armed (graphmap-cadence) present via GRAPHMAP_BAT_DIR: (got: $outGCp)"
echo "ok: cmd:cadence_armed envVar wiring — codex-sweep-cadence/graphmap-cadence each route to their OWN dir"

# ── cmd:guardrail_block_status (guardrail-block-global) — HIMMEL-1100 ───────
# CR fix (round 3, codex-adv-1): guardrail-block.mjs's status verb declares
# mode=global off ANY single owned hook (detectMode: `.some`) and derives
# node-resolves from only the FIRST owned hook it iterates to — it never
# enumerates all 3 expected guardrail hooks. This fixture is DELIBERATELY a
# 1-of-3 partial install (only auto-approve-safe-bash.sh wired) — exactly
# what used to false-green as 'present' before this round's fix. Bounded to
# what status output alone can attest: 'present' is unreachable through this
# data source (see the probe's own comment) until guardrail-block.mjs grows
# a richer verb — every mode=global reading is 'degraded'.
gb_node_stub="$work/gb-node-stub"; : > "$gb_node_stub"
gb_settings_present="$work/gb-settings-present/.claude"; mkdir -p "$gb_settings_present"
"$node_bin" -e "
const fs = require('fs');
const nodePath = '$(winpath "$gb_node_stub")';
const command = 'GUARDRAIL_BASH=\"/bin/bash\" ' + JSON.stringify(nodePath) + ' \"/x/scripts/hooks/guardrail-skip-in-himmel.js\" \"/x/scripts/hooks/auto-approve-safe-bash.sh\"';
const settings = { hooks: { PreToolUse: [ { matcher: 'Bash', hooks: [ { type: 'command', command } ] } ] } };
fs.writeFileSync('$(winpath "$gb_settings_present")/settings.json', JSON.stringify(settings, null, 2));
"
outGBp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CLAUDE_USER_SETTINGS: '$(winpath "$gb_settings_present")/settings.json' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBp" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status: a 1-of-3-hooks partial install (mode=global, node-resolves=yes for the one wired hook) must read degraded, NEVER present (status output cannot attest all 3 hooks): (got: $outGBp)"
echo "$outGBp" | jq -e '.detail | contains("cannot confirm all 3")' >/dev/null \
  || fail "cmd:guardrail_block_status partial-install detail should explain the status-verb limitation (got: $outGBp)"
echo "ok: cmd:guardrail_block_status — a partial (1-of-3) install reads degraded, never a false present"

gb_settings_absent="$work/gb-settings-absent"; mkdir -p "$gb_settings_absent"
outGBa=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CLAUDE_USER_SETTINGS: '$(winpath "$gb_settings_absent")/settings.json' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBa" | jq -e '.actual == "absent"' >/dev/null || fail "cmd:guardrail_block_status absent (no settings file -> project/default mode): (got: $outGBa)"

gb_settings_degraded="$work/gb-settings-degraded/.claude"; mkdir -p "$gb_settings_degraded"
"$node_bin" -e "
const fs = require('fs');
const nodePath = '$(winpath "$work")/nonexistent-node-path';
const command = 'GUARDRAIL_BASH=\"/bin/bash\" ' + JSON.stringify(nodePath) + ' \"/x/scripts/hooks/guardrail-skip-in-himmel.js\" \"/x/scripts/hooks/auto-approve-safe-bash.sh\"';
const settings = { hooks: { PreToolUse: [ { matcher: 'Bash', hooks: [ { type: 'command', command } ] } ] } };
fs.writeFileSync('$(winpath "$gb_settings_degraded")/settings.json', JSON.stringify(settings, null, 2));
"
outGBd=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CLAUDE_USER_SETTINGS: '$(winpath "$gb_settings_degraded")/settings.json' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBd" | jq -e '.actual == "degraded"' >/dev/null || fail "cmd:guardrail_block_status degraded (global mode, node path rotted): (got: $outGBd)"
echo "$outGBd" | jq -e '.detail | contains("no longer resolves")' >/dev/null || fail "cmd:guardrail_block_status degraded detail should say node no longer resolves (got: $outGBd)"

gb_bad_script_dir="$work/gb-bad-script"; mkdir -p "$gb_bad_script_dir/scripts/hooks"
cat > "$gb_bad_script_dir/scripts/hooks/guardrail-block.mjs" <<'JS'
process.stdout.write('not-the-expected-format\n');
JS
outGBu=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$(winpath "$gb_bad_script_dir")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBu" | jq -e '.actual == "degraded"' >/dev/null || fail "cmd:guardrail_block_status degraded (unparseable output): (got: $outGBu)"
echo "$outGBu" | jq -e '.detail | contains("unparseable")' >/dev/null || fail "cmd:guardrail_block_status unparseable-output detail should name it (got: $outGBu)"

# CR fix (HIMMEL-1100 round 2, glm-3): mode=global but node-resolves is
# MISSING entirely (distinct from the unparseable case above — mode itself
# IS present/parseable here) used to fall through to 'present', since
# `resolves === 'no'` is simply false for a missing field. A missing field is
# not proof of resolution.
gb_missing_field_dir="$work/gb-missing-field"; mkdir -p "$gb_missing_field_dir/scripts/hooks"
cat > "$gb_missing_field_dir/scripts/hooks/guardrail-block.mjs" <<'JS'
process.stdout.write('guardrail-mode=global\n');
JS
outGBmf=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$(winpath "$gb_missing_field_dir")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBmf" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status degraded (mode=global but node-resolves field missing — must NOT fall through to present): (got: $outGBmf)"
echo "$outGBmf" | jq -e '.detail | contains("missing")' >/dev/null \
  || fail "cmd:guardrail_block_status missing-field detail should name it (got: $outGBmf)"
echo "ok: cmd:guardrail_block_status degraded when mode=global but node-resolves is missing from the output"

gb_bad_exit_dir="$work/gb-bad-exit"; mkdir -p "$gb_bad_exit_dir/scripts/hooks"
cat > "$gb_bad_exit_dir/scripts/hooks/guardrail-block.mjs" <<'JS'
process.stderr.write('boom\n');
process.exit(2);
JS
outGBe=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$(winpath "$gb_bad_exit_dir")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBe" | jq -e '.actual == "degraded"' >/dev/null || fail "cmd:guardrail_block_status degraded (script exits nonzero): (got: $outGBe)"
echo "$outGBe" | jq -e '.detail | contains("rc=2")' >/dev/null || fail "cmd:guardrail_block_status nonzero-exit detail should name the rc (got: $outGBe)"
echo "ok: cmd:guardrail_block_status (guardrail-block-global) absent/degraded (rotted node path / unparseable output / nonzero exit) — 'present' is unreachable from status output alone, see the partial-install case above"
# SKIP NOTE: a spawn-error path (process.execPath itself unresolvable) is not
# exercised — this probe spawns by ABSOLUTE execPath, never a bash/PATH
# lookup for node, so the r.error branch has no realistic trigger here (unlike
# the bash-spawned probes above, where 'bash' itself can go missing from
# PATH). The branch stays defensive (matches every other probe's shape) but
# is not artificially forced — per the CR-established "comment + skip note,
# not a fake test" standard (HIMMEL-1093 round 5, codex-2).

# ── dep (gemini-cli) — HIMMEL-1100 ──────────────────────────────────────────
gem_present_stub="$work/gem-present-bin"; mkdir -p "$gem_present_stub"
pathGemPresent=$(build_path "$gem_present_stub" bash git jq -- gemini)
cat > "$gem_present_stub/gemini" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$gem_present_stub/gemini"
outGemP=$(PATH="$pathGemPresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'gemini-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGemP" | jq -e '.actual == "present"' >/dev/null || fail "dep (gemini-cli) present: (got: $outGemP)"

gem_absent_stub="$work/gem-absent-bin"; mkdir -p "$gem_absent_stub"
pathGemAbsent=$(build_path "$gem_absent_stub" bash git jq -- gemini)
outGemA=$(PATH="$pathGemAbsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'gemini-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGemA" | jq -e '.actual == "absent"' >/dev/null || fail "dep (gemini-cli) absent: (got: $outGemA)"
echo "ok: dep (gemini-cli) present/absent"

# ── cmd:hermes_checkout (hermes-checkout) — HIMMEL-1100 round 3, codex-adv-3
# hermes-checkout no longer reuses cmd:has_hermes (that proves a usable venv
# python, kept unchanged on hermes-lanes for runtime health) — it now checks
# the CHECKOUT itself: pure fs, no git spawn, resolving update_hermes()'s
# OWN root/src and reading .git/config directly for the origin remote.
hc_home_present="$work/hc-home-present"; mkdir -p "$hc_home_present/hermes-agent/.git"
cat > "$hc_home_present/hermes-agent/.git/config" <<'CFG'
[core]
	repositoryformatversion = 0
[remote "origin"]
	url = https://github.com/NousResearch/hermes-agent.git
	fetch = +refs/heads/*:refs/remotes/origin/*
[branch "main"]
	remote = origin
	merge = refs/heads/main
CFG
outHCp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_present")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCp" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:hermes_checkout present (genuine NousResearch/hermes-agent checkout): (got: $outHCp)"
echo "$outHCp" | jq -e '.detail | contains("NousResearch/hermes-agent")' >/dev/null \
  || fail "cmd:hermes_checkout present detail should name the verified origin (got: $outHCp)"

# absent: no .git at all under either root/hermes-agent or root — never
# installed as a checkout, the ordinary case for most operators.
hc_home_absent="$work/hc-home-absent"; mkdir -p "$hc_home_absent"
outHCa=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_absent")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCa" | jq -e '.actual == "absent"' >/dev/null \
  || fail "cmd:hermes_checkout absent (no .git checkout at all): (got: $outHCa)"
echo "$outHCa" | jq -e '.detail | contains("not installed as a git checkout")' >/dev/null \
  || fail "cmd:hermes_checkout absent detail should say not installed as a git checkout (got: $outHCa)"

# degraded: .git present but the origin points at a DIFFERENT repo entirely
# — update_hermes() would silently skip this checkout too (its own remote
# grep), so this is genuinely NOT a working hermes install.
hc_home_wrong_origin="$work/hc-home-wrong-origin"; mkdir -p "$hc_home_wrong_origin/hermes-agent/.git"
cat > "$hc_home_wrong_origin/hermes-agent/.git/config" <<'CFG'
[remote "origin"]
	url = https://github.com/someone-else/not-hermes.git
CFG
outHCw=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_wrong_origin")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCw" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:hermes_checkout degraded (checkout present but wrong origin): (got: $outHCw)"
echo "$outHCw" | jq -e '.detail | contains("not a NousResearch/hermes-agent checkout")' >/dev/null \
  || fail "cmd:hermes_checkout wrong-origin detail should name it (got: $outHCw)"

# degraded: a SPOOFED origin whose owner/repo merely CONTAINS
# "NousResearch/hermes-agent" as a substring — CR fix (HIMMEL-1100 round 4,
# codex-1): the previous bare substring match would have false-greened this.
hc_home_spoof="$work/hc-home-spoof"; mkdir -p "$hc_home_spoof/hermes-agent/.git"
cat > "$hc_home_spoof/hermes-agent/.git/config" <<'CFG'
[remote "origin"]
	url = git@github.com:evil/NousResearch-hermes-agent-mirror.git
CFG
outHCs=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_spoof")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCs" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:hermes_checkout degraded (spoofed origin owner/repo CONTAINS the real name as a substring but is not an exact match): (got: $outHCs)"
echo "$outHCs" | jq -e '.detail | contains("not a NousResearch/hermes-agent checkout")' >/dev/null \
  || fail "cmd:hermes_checkout spoof detail should name it (got: $outHCs)"
echo "ok: cmd:hermes_checkout — a substring-spoofed origin (evil/NousResearch-hermes-agent-mirror) reads degraded, never a false present"

# degraded: .git present but NO [remote "origin"] section at all.
hc_home_no_origin="$work/hc-home-no-origin"; mkdir -p "$hc_home_no_origin/hermes-agent/.git"
cat > "$hc_home_no_origin/hermes-agent/.git/config" <<'CFG'
[core]
	repositoryformatversion = 0
CFG
outHCn=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_no_origin")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCn" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:hermes_checkout degraded (checkout present but no origin remote configured): (got: $outHCn)"

# HERMES_HOME pointing straight AT the checkout (venv + .git at root, no
# hermes-agent/ subdir) — the tolerance fallback update_hermes() itself has.
hc_home_at_root="$work/hc-home-at-root"; mkdir -p "$hc_home_at_root/.git"
cat > "$hc_home_at_root/.git/config" <<'CFG'
[remote "origin"]
	url = git@github.com:NousResearch/hermes-agent.git
CFG
outHCr=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_at_root")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCr" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:hermes_checkout present (HERMES_HOME pointing straight at the checkout, root/.git tolerance, SSH-form origin url): (got: $outHCr)"

# CodeRabbit fix (HIMMEL-1100 round 6, coderabbit-2): an ssh:// origin with
# an EXPLICIT PORT (a normal, real-world form) used to false-degrade — the
# combined regex couldn't parse past the port segment.
hc_home_ssh_port="$work/hc-home-ssh-port"; mkdir -p "$hc_home_ssh_port/hermes-agent/.git"
cat > "$hc_home_ssh_port/hermes-agent/.git/config" <<'CFG'
[remote "origin"]
	url = ssh://git@github.com:22/NousResearch/hermes-agent.git
CFG
outHCp2=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_ssh_port")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCp2" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:hermes_checkout present (ssh:// origin with an explicit port — ssh://git@github.com:22/NousResearch/hermes-agent.git): (got: $outHCp2)"
echo "ok: cmd:hermes_checkout — an ssh:// origin with an explicit port resolves present, not falsely degraded"

# .git as a gitlink FILE (worktree/submodule shape: "gitdir: <path>") must
# still count as a valid checkout indicator — CR fix (HIMMEL-1100 round 4,
# codex-2). Follows the pointer ONE level to find the real config.
hc_home_gitdir_file="$work/hc-home-gitdir-file"; mkdir -p "$hc_home_gitdir_file/hermes-agent"
hc_real_gitdir="$work/hc-real-gitdir"; mkdir -p "$hc_real_gitdir"
cat > "$hc_real_gitdir/config" <<'CFG'
[remote "origin"]
	url = https://github.com/NousResearch/hermes-agent.git
CFG
printf 'gitdir: %s\n' "$(winpath "$hc_real_gitdir")" > "$hc_home_gitdir_file/hermes-agent/.git"
outHCg=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_gitdir_file")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCg" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:hermes_checkout present (.git is a gitlink FILE — worktree/submodule shape — following the gitdir: pointer): (got: $outHCg)"

# gitdir: pointer target missing -> degraded (a .git entry genuinely exists,
# just unverifiable) — never absent, never a crash.
hc_home_gitdir_broken="$work/hc-home-gitdir-broken"; mkdir -p "$hc_home_gitdir_broken/hermes-agent"
printf 'gitdir: %s\n' "$(winpath "$work")/does-not-exist" > "$hc_home_gitdir_broken/hermes-agent/.git"
outHCgb=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_gitdir_broken")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCgb" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:hermes_checkout degraded (gitdir: pointer target missing — genuinely a checkout, just unverifiable, not a crash): (got: $outHCgb)"
echo "$outHCgb" | jq -e '.detail | contains("gitdir:")' >/dev/null \
  || fail "cmd:hermes_checkout broken-gitdir detail should mention the gitdir pointer (got: $outHCgb)"
echo "ok: cmd:hermes_checkout — a .git gitlink FILE (worktree/submodule) is honored, following the pointer one level; a broken pointer reads degraded, never absent or a crash"

# Worktree-shaped fixture — CR fix (HIMMEL-1100 round 5, codex-1): a NORMAL
# linked worktree's gitdir (.git/worktrees/<name>/) carries no remotes of
# its own — they live in the COMMON dir, reached via that dir's own
# `commondir` file (relative paths resolve against the gitdir, per git's own
# contract). Without the fallback, this legitimate install shape read
# falsely degraded.
hc_home_worktree="$work/hc-home-worktree"
hc_wt_main_git="$hc_home_worktree/hermes-agent-main/.git"
mkdir -p "$hc_wt_main_git/worktrees/hermes-agent"
cat > "$hc_wt_main_git/config" <<'CFG'
[remote "origin"]
	url = https://github.com/NousResearch/hermes-agent.git
CFG
printf '../..\n' > "$hc_wt_main_git/worktrees/hermes-agent/commondir"
mkdir -p "$hc_home_worktree/hermes-agent"
printf 'gitdir: %s\n' "$(winpath "$hc_wt_main_git/worktrees/hermes-agent")" > "$hc_home_worktree/hermes-agent/.git"
outHCwt=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_worktree")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCwt" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:hermes_checkout present (NORMAL worktree shape: gitdir -> worktrees/<name> -> commondir -> common config with the origin): (got: $outHCwt)"
echo "$outHCwt" | jq -e '.detail | contains("NousResearch/hermes-agent")' >/dev/null \
  || fail "cmd:hermes_checkout worktree-shape detail should name the verified origin (got: $outHCwt)"
echo "ok: cmd:hermes_checkout — a NORMAL linked-worktree checkout (gitdir -> worktrees/<name>, no local remotes) resolves via the commondir fallback, reads present"

echo "ok: cmd:hermes_checkout (hermes-checkout) present/absent/degraded (wrong origin / no origin / spoofed origin), including the root/.git tolerance fallback and SSH-form origin urls"

depsCheck=$(jq -r '.items[] | select(.id=="hermes-lanes") | .deps | join(",")' "$manifest_path")
[ "$depsCheck" = "hermes-checkout" ] || fail "manifest: hermes-lanes.deps should be exactly [\"hermes-checkout\"] (got: $depsCheck)"
echo "ok: hermes-lanes correctly deps on hermes-checkout (distinct probes: checkout provenance vs runtime venv health)"

# ── purity: full sweep over every manifest item, fixture tree byte-identical ─
purity_root="$work/purity-repo"
mkdir -p "$purity_root/scripts/jira/dist" "$purity_root/scripts/bitbucket/dist" \
  "$purity_root/scripts/guardrails" "$purity_root/scripts/lanes" "$purity_root/scripts/telegram" \
  "$purity_root/scripts/graphify" "$purity_root/scripts/lib" "$purity_root/handovers" "$purity_root/.claude"
: > "$purity_root/scripts/jira/dist/index.js"
: > "$purity_root/scripts/bitbucket/dist/index.js"
: > "$purity_root/scripts/guardrails/lib.sh"
: > "$purity_root/scripts/lanes/lanes.json"
: > "$purity_root/scripts/telegram/telegram-api.ts"
: > "$purity_root/scripts/graphify/check-graph-freshness.sh"
: > "$purity_root/scripts/lib/doc-guard-map.sh"
: > "$purity_root/.pre-commit-config.yaml"
cat > "$purity_root/.env" <<'ENV'
JIRA_BASE_URL=https://example.atlassian.net
JIRA_EMAIL=me@example.com
JIRA_API_TOKEN=tok123
JIRA_PROJECT_KEY=HIMMEL
ENV
cat > "$purity_root/.claude/settings.json" <<'JSON'
{"statusLine":{"command":"bash foo.sh"},"enabledPlugins":{"foo@bar":true},
 "hooks":{"PreToolUse":[
   {"matcher":"Bash","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/auto-approve-safe-bash.sh\""}]},
   {"matcher":"Edit","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/block-edit-on-main.sh\""}]},
   {"matcher":"Read","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/block-read-secrets.sh\""}]}
 ]}}
JSON
purity_vault="$work/purity-vault"; mkdir -p "$purity_vault"
: > "$purity_vault/.vault-template.json"

purity_before=$(snapshot_dir "$purity_root")
purity_vault_before=$(snapshot_dir "$purity_vault")

sweepOut=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const repoRoot = '$(winpath "$purity_root")';
const targetPath = '$(winpath "$purity_root")';
const vaultPath = '$(winpath "$purity_vault")';
const results = [];
for (const item of manifest.items) {
  const scope = item.scopes.includes('project') ? 'project' : 'user';
  const tp = item.id === 'luna-vault-scaffold' ? vaultPath : targetPath;
  const ctx = { repoRoot, targetPath: tp, scope, env: process.env };
  results.push(Object.assign({ id: item.id }, runProbe(item, ctx)));
}
console.log(JSON.stringify(results));
")

purity_after=$(snapshot_dir "$purity_root")
purity_vault_after=$(snapshot_dir "$purity_vault")

[ "$purity_before" = "$purity_after" ] || fail "purity: fixture repo/target tree was mutated by the probe sweep"
[ "$purity_vault_before" = "$purity_vault_after" ] || fail "purity: fixture vault tree was mutated by the probe sweep"

sweepCount=$(echo "$sweepOut" | jq 'length')
manifestCount=$(jq '.items | length' "$manifest_path")
[ "$sweepCount" -eq "$manifestCount" ] || fail "purity: expected $manifestCount probe results (one per manifest item), got $sweepCount"
echo "ok: purity — full probe sweep over all $manifestCount manifest items left every fixture tree byte-identical"

echo "PASS"
