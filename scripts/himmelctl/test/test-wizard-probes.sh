#!/usr/bin/env bash
# test-wizard-probes.sh — hermetic tests for scripts/himmelctl/lib/probes.js
# (HIMMEL-756 T1.4): the seven-probe-type engine, run against the REAL
# scripts/install/manifest.json descriptors (so a manifest authoring drift
# breaks THIS suite, not silently). Mirrors sibling test-wizard-*.sh
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
#   handover-dir   handover-wiring — HANDOVER_DIR set (ctx.env pass-through,
#                  not process.env mutation) / unset with a non-repo cwd.
#   dep            single-cmd (rtk) and the win32/posix platform union
#                  (scheduler-backend), each present/absent via stub PATH.
#   purity         a full sweep over every manifest.json item leaves the
#                  fixture repo + vault trees byte-identical (sha256
#                  snapshot before/after).

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
probes_lib="$repo_root/scripts/himmelctl/lib/probes.js"
manifest_path="$repo_root/scripts/install/manifest.json"
[ -f "$probes_lib" ] || { echo "FAIL: $probes_lib not found" >&2; exit 1; }
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
manifest_w="$(winpath "$manifest_path")"
repo_root_w="$(winpath "$repo_root")"

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
