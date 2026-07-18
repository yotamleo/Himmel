#!/usr/bin/env bash
# test-wizard-scope-switch.sh — hermetic tests for the himmelctl `scope`
# subcommand (HIMMEL-757 C — scope-switch MVP): `scope get` / `scope status`
# read the current scope; `scope set <project|user>` re-projects the install
# to the target scope (wires the target scope, UNWIRES the old scope, refuses
# to leave any item wired in BOTH scopes). Drives bin.js end-to-end via a
# HIMMELCTL_REPO_ROOT fixture carrying a small manifest + STUB wire/unwire
# primitives (never the real wire-*.sh) that set/del a statusLine.command key
# the settings-key probe reads — so a single wire item genuinely RELOCATES
# its settings.json by scope (project: target/.claude, user: $HOME/.claude).
# Mirrors sibling test-wizard-*.sh conventions (fake HOME +
# HIMMELCTL_CACHE_DIR/HIMMELCTL_REPO_ROOT, node by absolute path, winpath for
# node.exe's MSYS-path blindness).
#
# Covers:
#   a. project->user switch: the OLD (project) scope's wiring is GONE and the
#      NEW (user) scope's is PRESENT.
#   b. state.json is re-keyed to the target scope (the old project key is
#      DELETED, the user key is present — so no item is enabled in both
#      scopes); the recorded scope (install-profile cache) is flipped to
#      'user' and `scope get` returns 'user'.
#   c. FAIL-CLOSED: a full-offboard-only item that exists in BOTH scopes with
#      NO runnable unwire descriptor, present in the old scope, REFUSES the
#      whole switch (exit 1, zero mutation) and is named; the UNWIREABLE wire
#      item is NOT named (correctly excluded).
#   d. `--dry-run` prints the plan (unwire old, wire new, re-key) and changes
#      nothing.
#   e. non-interactive without `--yes` refuses (exit 2, zero mutation).
#   f. `scope get` / `scope status` print the current scope (the read path).

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

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

# snapshot_dir <dir> — sorted sha256 lines, one per file under <dir>. The
# zero-mutation assertions (cases c/d/e) run BEFORE any primitive dispatch,
# so no .tmp residue is left behind — a file-only snapshot is sufficient.
# sha256 of a file, portably: sha256sum (Linux/Git-Bash) or `shasum -a 256`
# (macOS, where sha256sum is not installed by default).
_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}
snapshot_dir() {
  # Include DIRECTORY entries too (as bare `dir <path>` lines), not just file
  # hashes — otherwise creating an empty dir (e.g. $HOME/.claude before a
  # refusal) would slip past the zero-mutation assertions (CR).
  ( cd "$1" && find . | LC_ALL=C sort | while IFS= read -r p; do
      if [ -d "$p" ]; then printf 'dir %s\n' "$p"; else _sha256 "$p"; fi
    done )
}

# write_cache <path> <role> <scope> <vault-mode> <vault-path> <handover-mode>
#             <handover-path> <plugin-set> — same minimal valid Draft-A
#             profile shape every sibling suite's write_cache writes.
write_cache() {
  cat > "$1" <<JSON
{"role":"$2","tier":"standard","scope":"$3","vault":{"mode":"$4","path":"$5"},"handover":{"mode":"$6","path":"$7"},"pluginSet":"$8","lanes":[],"alwaysOn":false}
JSON
}

# ── shared clean-switch fixture: ONE unwireable wire item (statusline) that
# relocates its settings.json by scope. The stub wire/unwire primitives
# set/del the statusLine.command key the settings-key probe reads (mirrors
# the real wire-statusline.sh / unwire-statusline.sh jq+dirname+mv shape —
# Git Bash dirname handles the Windows backslash settings path node passes). ─
repo="$work/repo"; mkdir -p "$repo/scripts/install" "$repo/scripts/lib"
cat > "$repo/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "wire-item",
      "kind": "wiring",
      "scopes": ["project", "user"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "settings-key", "file": ".claude/settings.json", "key": "statusLine.command" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    }
  ]
}
JSON
cat > "$repo/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
settings="$1"
mkdir -p "$(dirname "$settings")"
tmp="${settings}.wire.tmp"
if [ -s "$settings" ]; then
  jq '.statusLine.command = "himmel"' "$settings" > "$tmp"
else
  printf '{}' | jq '.statusLine.command = "himmel"' > "$tmp"
fi
mv "$tmp" "$settings"
SH
cat > "$repo/scripts/lib/unwire-statusline.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
settings="$1"
[ -f "$settings" ] || exit 0
tmp="${settings}.unwire.tmp"
jq 'del(.statusLine)' "$settings" > "$tmp"
mv "$tmp" "$settings"
SH
chmod +x "$repo/scripts/lib/wire-statusline.sh" "$repo/scripts/lib/unwire-statusline.sh"

# ── case f: scope get / scope status read the current scope ─────────────────
targetF="$work/targetF"; mkdir -p "$targetF"
cacheF="$work/cacheF"; mkdir -p "$cacheF"
homeF="$work/homeF"; mkdir -p "$homeF"
write_cache "$cacheF/install-profile.json" adopter project none "" inline "" lean
getOut=$( cd "$targetF" && HIMMELCTL_REPO_ROOT="$(winpath "$repo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheF")" HOME="$homeF" \
  "$node_bin" "$wizard" scope get </dev/null )
[ "$getOut" = "project" ] || fail "case f: scope get should print 'project' (got: $getOut)"
statusOut=$( cd "$targetF" && HIMMELCTL_REPO_ROOT="$(winpath "$repo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheF")" HOME="$homeF" \
  "$node_bin" "$wizard" scope status </dev/null )
[ "$statusOut" = "project" ] || fail "case f: scope status should print 'project' (got: $statusOut)"
echo "ok: case f — scope get / scope status print the current scope"

# ── seed a project-scope install for cases a/b/d/e: ensure wires wire-item
# into the project settings.json and persists the project target in state. ───
target="$work/target"; mkdir -p "$target"
cache="$work/cache"; mkdir -p "$cache"
home="$work/home"; mkdir -p "$home"
write_cache "$cache/install-profile.json" adopter project none "" inline "" lean
# Seed the project scope (ensure wires wire-item + persists the project
# target). Output is discarded; set -e aborts on a non-zero seed, and the
# settings/state assertions below prove it took.
( cd "$target" && HIMMELCTL_REPO_ROOT="$(winpath "$repo")" HIMMELCTL_CACHE_DIR="$(winpath "$cache")" HOME="$home" \
  "$node_bin" "$wizard" ensure --yes </dev/null ) >/dev/null
jq -e '.statusLine.command' "$target/.claude/settings.json" >/dev/null \
  || fail "seed: ensure should have wired wire-item into the project settings (got: $(cat "$target/.claude/settings.json" 2>/dev/null))"
[ "$(jq '.targets | length' "$cache/state.json")" = "1" ] \
  || fail "seed: state.json should carry exactly one target (the project cwd) (got: $(jq -c '.targets|keys' "$cache/state.json"))"
echo "ok: seed — project-scope install wired (wire-item green, project target persisted)"

# ── case a + b: project -> user switch ──────────────────────────────────────
switchOut=$( cd "$target" && HIMMELCTL_REPO_ROOT="$(winpath "$repo")" HIMMELCTL_CACHE_DIR="$(winpath "$cache")" HOME="$home" \
  "$node_bin" "$wizard" scope set user --yes </dev/null )
echo "$switchOut" | grep -qF "scope switched 'project' -> 'user'" \
  || fail "case a: expected the switch success line (got: $switchOut)"
# (a) the OLD (project) scope's wiring is GONE:
[ "$(jq '.statusLine' "$target/.claude/settings.json")" = "null" ] \
  || fail "case a: project settings statusLine should be null (unwired) after the switch (got: $(jq -c '.statusLine' "$target/.claude/settings.json"))"
# (a) the NEW (user) scope's wiring is PRESENT:
[ -f "$home/.claude/settings.json" ] || fail "case a: user settings.json should exist after the switch"
[ "$(jq -r '.statusLine.command' "$home/.claude/settings.json")" = "himmel" ] \
  || fail "case a: user settings statusLine.command should be 'himmel' (wired) after the switch (got: $(cat "$home/.claude/settings.json"))"
echo "ok: case a — project->user switch unwires the old scope and wires the new"
# (b) state.json re-keyed: the project (cwd) key is DELETED, the 'user' key is
# present — so no item is enabled in both scopes (only one target exists).
[ "$(jq '.targets | has("user")' "$cache/state.json")" = "true" ] \
  || fail "case b: state.json should have the 'user' target after the switch (got: $(jq -c '.targets|keys' "$cache/state.json"))"
[ "$(jq '.targets | length' "$cache/state.json")" = "1" ] \
  || fail "case b: state.json should have EXACTLY one target (user) — the project key must be deleted (got keys: $(jq -c '.targets|keys' "$cache/state.json"))"
[ "$(jq -r '.targets["user"].items["wire-item"].enabled' "$cache/state.json")" = "true" ] \
  || fail "case b: the user target should have wire-item enabled (got: $(jq -c '.targets["user"].items["wire-item"]' "$cache/state.json"))"
# (b) the recorded scope (install-profile cache) flipped to 'user', and the
# user target carries NO project-scope-only item enabled (none in this tiny
# manifest, but the assertion documents the both-scopes invariant).
[ "$(jq -r '.scope' "$cache/install-profile.json")" = "user" ] \
  || fail "case b: install-profile scope should be 'user' after the switch (got: $(jq -r '.scope' "$cache/install-profile.json"))"
getAfter=$( cd "$target" && HIMMELCTL_REPO_ROOT="$(winpath "$repo")" HIMMELCTL_CACHE_DIR="$(winpath "$cache")" HOME="$home" \
  "$node_bin" "$wizard" scope get </dev/null )
[ "$getAfter" = "user" ] || fail "case b: scope get should return 'user' after the switch (got: $getAfter)"
echo "ok: case b — state re-keyed to the user scope (project key deleted); recorded scope flipped; scope get returns 'user'"

# ── case c: FAIL-CLOSED when a full-offboard-only both-scopes item (no
# unwire descriptor) is present in the old scope ─────────────────────────────
repoC="$work/repoC"; mkdir -p "$repoC/scripts/install" "$repoC/scripts/lib"
cat > "$repoC/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "wire-item",
      "kind": "wiring",
      "scopes": ["project", "user"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "settings-key", "file": ".claude/settings.json", "key": "statusLine.command" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    },
    {
      "id": "stuck-item",
      "kind": "plugin",
      "scopes": ["project", "user"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "settings-key", "file": ".claude/settings.json", "key": "enabledPlugins" },
      "install": { "type": "plugins" },
      "removable": "full-offboard-only"
    }
  ]
}
JSON
cp "$repo/scripts/lib/wire-statusline.sh" "$repoC/scripts/lib/"
cp "$repo/scripts/lib/unwire-statusline.sh" "$repoC/scripts/lib/"

targetC="$work/targetC"; mkdir -p "$targetC/.claude"
cacheC="$work/cacheC"; mkdir -p "$cacheC"
homeC="$work/homeC"; mkdir -p "$homeC"
write_cache "$cacheC/install-profile.json" adopter project none "" inline "" lean
# Seed BOTH wire-item (statusLine.command) AND stuck-item (enabledPlugins) as
# present in the PROJECT scope directly (no ensure run — keeps the zero-
# mutation snapshot tight). stuck-item is the unhandleable blocker (full-
# offboard-only, no unwire); wire-item is the unwireable pair that must be
# EXCLUDED from the fail-closed list.
printf '{"statusLine":{"command":"himmel"},"enabledPlugins":{"foo":"true"}}' > "$targetC/.claude/settings.json"
# A real project install records BOTH settings.json wiring AND a state.json
# target entry keyed by the project path. The CWD guard (CR bin.js:59) requires
# that entry — without it `scope set` fail-closes on the directory check before
# it can reach the item-level fail-closed this case exercises. Seed it keyed by
# the resolved cwd exactly as bin.js computes it (path.resolve(process.cwd())).
( cd "$targetC" && HIMMELCTL_CACHE_DIR="$(winpath "$cacheC")" "$node_bin" -e '
  const fs = require("fs"), path = require("path");
  const key = path.resolve(process.cwd());
  const state = { schemaVersion: 1, harness: "claude", targets: { [key]: { profile: "core", scope: "project", items: { "wire-item": { enabled: true }, "stuck-item": { enabled: true } }, lastEnsured: null } } };
  fs.writeFileSync(path.join(process.env.HIMMELCTL_CACHE_DIR, "state.json"), JSON.stringify(state));
' )

snapCBefore=$(snapshot_dir "$work")
set +e
outC=$( cd "$targetC" && HIMMELCTL_REPO_ROOT="$(winpath "$repoC")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheC")" HOME="$homeC" \
  "$node_bin" "$wizard" scope set user --yes 2>&1 </dev/null ); rcC=$?
set -e
[ "$rcC" -eq 1 ] || fail "case c: fail-closed should exit 1 (got rc=$rcC): $outC"
echo "$outC" | grep -qF 'stuck-item' || fail "case c: the refusal should name stuck-item (got: $outC)"
if echo "$outC" | grep -qF 'wire-item'; then
  fail "case c: the unwireable wire-item must NOT be listed as a fail-closed blocker (got: $outC)"
fi
echo "$outC" | grep -qF 'HIMMEL-1172' || fail "case c: the refusal should mention HIMMEL-1172 (got: $outC)"
echo "$outC" | grep -qi 'both scopes' || fail "case c: the refusal should explain the both-scopes risk (got: $outC)"
# zero mutation: fail-closed returns BEFORE any state save or dispatch — the
# seeded project state entry must survive UN-re-keyed (no 'user' target added).
[ "$(jq '.targets | has("user")' "$cacheC/state.json")" = "false" ] \
  || fail "case c: state.json must NOT be re-keyed to user on a fail-closed refusal (got: $(jq -c '.targets|keys' "$cacheC/state.json"))"
[ "$(jq -r '.scope' "$cacheC/install-profile.json")" = "project" ] \
  || fail "case c: install-profile scope must stay 'project' (got: $(jq -r '.scope' "$cacheC/install-profile.json"))"
[ "$(jq -r '.statusLine.command' "$targetC/.claude/settings.json")" = "himmel" ] \
  || fail "case c: project settings must be UNCHANGED (wire-item still present)"
[ "$(jq -r '.enabledPlugins.foo' "$targetC/.claude/settings.json")" = "true" ] \
  || fail "case c: project settings must be UNCHANGED (stuck-item still present)"
[ ! -f "$homeC/.claude/settings.json" ] || fail "case c: user settings must NOT be created on a refusal"
snapCAfter=$(snapshot_dir "$work")
[ "$snapCBefore" = "$snapCAfter" ] || fail "case c: fail-closed refusal should make ZERO mutations"
echo "ok: case c — fail-closed names the unhandleable item, excludes the unwireable one, zero mutation"

# ── case d: --dry-run prints the plan, changes nothing ──────────────────────
targetD="$work/targetD"; mkdir -p "$targetD"
cacheD="$work/cacheD"; mkdir -p "$cacheD"
homeD="$work/homeD"; mkdir -p "$homeD"
write_cache "$cacheD/install-profile.json" adopter project none "" inline "" lean
( cd "$targetD" && HIMMELCTL_REPO_ROOT="$(winpath "$repo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheD")" HOME="$homeD" \
  "$node_bin" "$wizard" ensure --yes </dev/null ) >/dev/null
jq -e '.statusLine.command' "$targetD/.claude/settings.json" >/dev/null \
  || fail "case d seed: ensure should wire wire-item (got: $(cat "$targetD/.claude/settings.json" 2>/dev/null))"

snapDBefore=$(snapshot_dir "$work")
set +e
outD=$( cd "$targetD" && HIMMELCTL_REPO_ROOT="$(winpath "$repo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheD")" HOME="$homeD" \
  "$node_bin" "$wizard" scope set user --dry-run </dev/null ); rcD=$?
set -e
[ "$rcD" -eq 0 ] || fail "case d: --dry-run should exit 0 (got rc=$rcD): $outD"
echo "$outD" | grep -qF 'DRY: unwire wire-item (from project)' \
  || fail "case d: dry-run should preview the unwire of the old scope (got: $outD)"
echo "$outD" | grep -q 'DRY:.*wire-statusline' \
  || fail "case d: dry-run should preview the wire of the new scope (got: $outD)"
echo "$outD" | grep -qF 'DRY: re-key state' || fail "case d: dry-run should preview the re-key (got: $outD)"
snapDAfter=$(snapshot_dir "$work")
[ "$snapDBefore" = "$snapDAfter" ] || fail "case d: --dry-run should make ZERO mutations"
[ "$(jq -r '.scope' "$cacheD/install-profile.json")" = "project" ] \
  || fail "case d: install-profile scope must stay 'project' under dry-run"
[ "$(jq '.targets | length' "$cacheD/state.json")" = "1" ] \
  || fail "case d: state.json must stay re-keyed to the project target under dry-run (got: $(jq -c '.targets|keys' "$cacheD/state.json"))"
[ ! -f "$homeD/.claude/settings.json" ] || fail "case d: user settings must NOT be created under dry-run"
[ "$(jq -r '.statusLine.command' "$targetD/.claude/settings.json")" = "himmel" ] \
  || fail "case d: project settings must stay wired under dry-run"
echo "ok: case d — --dry-run previews the switch (unwire old, wire new, re-key) and changes nothing"

# ── case e: non-interactive without --yes refuses (exit 2, zero mutation) ───
targetE="$work/targetE"; mkdir -p "$targetE"
cacheE="$work/cacheE"; mkdir -p "$cacheE"
homeE="$work/homeE"; mkdir -p "$homeE"
write_cache "$cacheE/install-profile.json" adopter project none "" inline "" lean
( cd "$targetE" && HIMMELCTL_REPO_ROOT="$(winpath "$repo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheE")" HOME="$homeE" \
  "$node_bin" "$wizard" ensure --yes </dev/null ) >/dev/null
jq -e '.statusLine.command' "$targetE/.claude/settings.json" >/dev/null \
  || fail "case e seed: ensure should wire wire-item (got: $(cat "$targetE/.claude/settings.json" 2>/dev/null))"

snapEBefore=$(snapshot_dir "$work")
set +e
outE=$( cd "$targetE" && HIMMELCTL_REPO_ROOT="$(winpath "$repo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheE")" HOME="$homeE" \
  "$node_bin" "$wizard" scope set user 2>&1 </dev/null ); rcE=$?
set -e
[ "$rcE" -eq 2 ] || fail "case e: non-interactive scope switch without --yes should exit 2 (got rc=$rcE): $outE"
echo "$outE" | grep -qF 'non-interactive scope switch requires --yes' \
  || fail "case e: expected the requires---yes message (got: $outE)"
snapEAfter=$(snapshot_dir "$work")
[ "$snapEBefore" = "$snapEAfter" ] || fail "case e: a refused non-interactive switch should make ZERO mutations"
echo "ok: case e — non-interactive scope switch without --yes refuses (exit 2), zero mutation"

# ── case g: CWD guard — `scope set` from the WRONG directory fails closed ────
# (CR bin.js:59) A project install is recorded at its project path. Running
# `scope set` from any OTHER directory must refuse (exit 2) rather than treat
# the wrong cwd as the old install — which would delete the wrong state key and
# never unwire the real project, leaving BOTH scopes wired.
targetG="$work/targetG"; mkdir -p "$targetG"
wrongG="$work/wrongG";  mkdir -p "$wrongG"
cacheG="$work/cacheG";  mkdir -p "$cacheG"
homeG="$work/homeG";    mkdir -p "$homeG"
write_cache "$cacheG/install-profile.json" adopter project none "" inline "" lean
( cd "$targetG" && HIMMELCTL_REPO_ROOT="$(winpath "$repo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheG")" HOME="$homeG" \
  "$node_bin" "$wizard" ensure --yes </dev/null ) >/dev/null
jq -e '.statusLine.command' "$targetG/.claude/settings.json" >/dev/null \
  || fail "case g seed: ensure should wire the project (got: $(cat "$targetG/.claude/settings.json" 2>/dev/null))"

snapGBefore=$(snapshot_dir "$work")
set +e
outG=$( cd "$wrongG" && HIMMELCTL_REPO_ROOT="$(winpath "$repo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheG")" HOME="$homeG" \
  "$node_bin" "$wizard" scope set user --yes 2>&1 </dev/null ); rcG=$?
set -e
[ "$rcG" -eq 2 ] || fail "case g: scope set from the wrong dir should exit 2 (got rc=$rcG): $outG"
echo "$outG" | grep -qF 'not the recorded project install' \
  || fail "case g: expected the wrong-directory refusal (got: $outG)"
snapGAfter=$(snapshot_dir "$work")
[ "$snapGBefore" = "$snapGAfter" ] || fail "case g: a wrong-directory refusal should make ZERO mutations"
echo "ok: case g — scope set from the wrong directory fails closed (CWD guard), zero mutation"

echo "PASS"
