#!/usr/bin/env bash
# Smoke test for scripts/check-plugin-drift.sh (HIMMEL-322).
# Structural checks (no network needed) + one end-to-end run (uses network iff
# gh is available; the script itself fail-opens when it isn't).
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/check-plugin-drift.sh"
MJSON="$ROOT/marketplace/.claude-plugin/marketplace.json"
fails=0
# The pin scan (section 12) hits the npm registry per package; every OTHER case
# below runs against an empty scan root so its exit-code assertions stay about
# the section under test.
PIN_EMPTY="$(mktemp -d "${TMPDIR:-/tmp}/pdrift-pinempty.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }; export DRIFT_PIN_ROOT="$PIN_EMPTY"
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

# tool_link <src> <dst> -- put a tool on a masked PATH dir. Where `ln -s` makes a
# real link that is the link; where it COPIES (Git Bash without the symlink
# privilege) a copied bash.exe/dirname.exe cannot load its DLLs and answers rc=127
# (HIMMEL-3182), so a one-line exec wrapper stands in for it instead.
# shellcheck source=lib/host-caps.sh
. "$ROOT/scripts/lib/host-caps.sh"
if host_symlinks_real; then
  tool_link() { ln -s "$1" "$2" 2>/dev/null; }
else
  tool_link() { printf '#!/bin/sh\nexec "%s" "$@"\n' "$1" > "$2" && chmod +x "$2"; }
fi

# 1. Syntax.
if bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "syntax"; fi

# 2. The marketplace.json parser yields the git-remote pinned remotes (>=1; expect
#    claude-obsidian — sourced via an explicit HTTPS url since HIMMEL-549, so the
#    parser must accept both the {github,repo} and {url,url} shapes; obsidian/kepano
#    was dropped, it installs from its own marketplace, HIMMEL-435). Mirrors the
#    script's own parser.
pins="$(python3 - "$MJSON" <<'PY' | tr -d '\r'
import json, sys
m = json.load(open(sys.argv[1]))
for p in m.get("plugins", []):
    s = p.get("source")
    if isinstance(s, dict) and s.get("source") in ("github", "url") and (s.get("ref") or s.get("sha")):
        print(p["name"])
PY
)"
if grepq "$pins" -x "claude-obsidian"; then ok "parser finds claude-obsidian pin"; else bad "parser missing claude-obsidian"; fi
if grepq "$pins" -x "obsidian"; then bad "obsidian pin still present — should have been dropped (HIMMEL-435)"; else ok "obsidian (kepano) pin absent — dropped as expected"; fi
# HIMMEL-2854: plannotator-effective-html is pinned by `sha`, not `ref`
# (marketplace/.claude-plugin/marketplace.json) — a predicate that only
# checks `ref` silently drops it from the pinned-remotes inventory this
# mirror feeds, even though the production parser (check-plugin-drift.sh)
# already accepts `ref or sha`.
if grepq "$pins" -x "plannotator-effective-html"; then ok "parser finds plannotator-effective-html SHA-only pin"; else bad "parser missing plannotator-effective-html (SHA-only pin)"; fi

# 3. Every fork UPSTREAM_PIN carries the generic fields the checker reads.
for pin in "$ROOT"/marketplace/plugins/*/UPSTREAM_PIN; do
  [ -f "$pin" ] || continue
  plug="$(basename "$(dirname "$pin")")"
  for field in upstream_repo upstream_path upstream_sha256; do
    if grep -q "^${field}=" "$pin"; then ok "$plug UPSTREAM_PIN has $field"; else bad "$plug UPSTREAM_PIN missing $field"; fi
  done
done

# 3b. The true-upstream override sidecar is well-formed and routes through the
#     parser deterministically (no network). claude-obsidian is a fork whose
#     marketplace `repo` is OURS, so it MUST carry an override or the guard would
#     only ever check fork-vs-pin.
UPS="$ROOT/scripts/plugin-upstreams.json"
if [ -f "$UPS" ]; then
  ok "plugin-upstreams.json present"
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$UPS" >/dev/null 2>&1; then
    ok "plugin-upstreams.json is valid JSON"
  else
    bad "plugin-upstreams.json is not valid JSON"
  fi
  # The augmented parser (same shape the script uses) must emit a 6-field line for
  # claude-obsidian with field 4 = the TRUE upstream.
  line="$(python3 - "$MJSON" "$UPS" <<'PY' 2>/dev/null | tr -d '\r' | grep '^claude-obsidian|'
import json, os, sys
m = json.load(open(sys.argv[1]))
ups = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else {}
def repo_of(s):
    if s.get("source") == "github":
        return s.get("repo", "")
    u = s.get("url", "")
    if "github.com/" in u:
        r = u.split("github.com/", 1)[1].rstrip("/")
        return r[:-4] if r.endswith(".git") else r
    return ""
for p in m.get("plugins", []):
    s = p.get("source")
    if isinstance(s, dict) and s.get("source") in ("github", "url") and (s.get("ref") or s.get("sha")):
        o = ups.get(p["name"]) or {}
        print("|".join([p["name"], repo_of(s), s.get("ref") or s.get("sha"),
                        o.get("upstream_repo", ""), o.get("track", ""), o.get("synced_base", "")]))
PY
)"
  up_repo_field="$(printf '%s' "$line" | cut -d'|' -f4)"
  up_track_field="$(printf '%s' "$line" | cut -d'|' -f5)"
  up_base_field="$(printf '%s' "$line" | cut -d'|' -f6)"
  if [ "$up_repo_field" = "AgriciDaniel/claude-obsidian" ]; then ok "override routes claude-obsidian to true upstream"; else bad "claude-obsidian override upstream_repo wrong: '$up_repo_field'"; fi
  if [ "$up_track_field" = "release" ]; then ok "claude-obsidian override track=release"; else bad "claude-obsidian track wrong: '$up_track_field'"; fi
  if [ -n "$up_base_field" ]; then ok "claude-obsidian override has synced_base ($up_base_field)"; else bad "claude-obsidian override missing synced_base"; fi
else
  bad "plugin-upstreams.json missing — claude-obsidian (a fork) would be checked against itself"
fi

# 3c. Stable-tag selection (mirrors the script's `latest` computation): a stale
#     same-version prerelease must NOT be picked as latest over the stable tag
#     (would be a phantom BEHIND), and a genuinely-newer stable IS picked.
TAG_RE='^v?[0-9]+\.[0-9]+(\.[0-9]+)?$'
# Run the PRODUCTION highest_version helper, not a mirror (HIMMEL-1054 CR
# round): the function body is extracted verbatim from the script under test,
# so a divergence in the real selector cannot pass silently here. (The script
# executes on source, so a plain `source` is not an option.)
eval "$(sed -n '/^highest_version() {/,/^}/p' "$SCRIPT")"
pick() { printf '%s\n' "$1" | grep -E "$TAG_RE" | highest_version; }
if [ "$(pick "$(printf 'v1.9.1\nv1.9.2\nv1.9.2-alpha\nv1.8.1\n')")" = "v1.9.2" ]; then ok "stable-tag select: prerelease of current version ignored"; else bad "prerelease leaked into latest"; fi
if [ "$(pick "$(printf 'v1.9.2\nv1.9.3\n')")" = "v1.9.3" ]; then ok "stable-tag select: newer stable wins"; else bad "newer stable not selected"; fi
if [ -z "$(pick "$(printf 'v1.9.2-alpha\nv1.9.3-rc1\n')")" ]; then ok "stable-tag select: all-prerelease -> empty (drives the UNCHECKED path)"; else bad "all-prerelease should select nothing, got '$(pick "$(printf 'v1.9.2-alpha\nv1.9.3-rc1\n')")'"; fi

# 3d. The real upstreams.json registers the two SHA-pinned lib forks (HIMMEL-1046)
#     against their TRUE upstreams — graphify via latest_source=release (its tags
#     are non-monotonic: a stale v1.0.0 predates the current v0.9.x line), qmd via
#     the default highest-tag path.
REG="$ROOT/scripts/upstreams.json"
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$REG" >/dev/null 2>&1; then ok "upstreams.json is valid JSON"; else bad "upstreams.json is not valid JSON"; fi
reg_probe="$(python3 - "$REG" <<'PY' 2>/dev/null | tr -d '\r'
import json,sys
d=json.load(open(sys.argv[1]))
for e in d.get("entries",[]):
    if e.get("name") in ("graphify","qmd"):
        print("|".join([e.get("name",""), e.get("tracked_repo",""), e.get("kind",""), e.get("mode",""), e.get("latest_source","")]))
PY
)"
if grepq "$reg_probe" 'graphify|Graphify-Labs/graphify|tag_release|base|release'; then ok "graphify entry -> true upstream Graphify-Labs, tag_release/base, latest_source=release"; else bad "graphify registry entry wrong/missing: $(printf '%s' "$reg_probe" | grep graphify)"; fi
if grepq "$reg_probe" 'qmd|tobi/qmd|tag_release|base'; then ok "qmd entry -> true upstream tobi/qmd, tag_release/base"; else bad "qmd registry entry wrong/missing: $(printf '%s' "$reg_probe" | grep '^qmd')"; fi

# 3e. HIMMEL-1435 zero-gap inventory: claude-obsidian must be a plain tag-pinned
#     resync target (no fork block — the fork was retired at v2.2.0, HIMMEL-2925)
#     whose duplicated synced_base matches plugin-upstreams.json; qmd is likewise
#     a plain SHA-pinned entry with no fork block since HIMMEL-3045 de-forked it
#     (it was the last remaining fork-block entry until then); every third-party
#     plugin actually bundled in the luna template must have a registry row
#     whose base matches its manifest; deliberate omissions stay explicit in
#     coverage_audit rather than disappearing silently.
audit_out="$(python3 - "$ROOT" "$REG" "$UPS" <<'PY' 2>&1
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
reg = json.load(open(sys.argv[2], encoding='utf-8'))
ups = json.load(open(sys.argv[3], encoding='utf-8'))
entries = {e['name']: e for e in reg.get('entries', [])}

co = entries['claude-obsidian']
assert co['tracked_repo'] == 'AgriciDaniel/claude-obsidian'
assert co['synced_base'] == ups['claude-obsidian']['synced_base']
assert 'fork' not in co

qmd = entries['qmd']
assert qmd['tracked_repo'] == 'tobi/qmd'
# HIMMEL-3956 re-carried the fork (launcher signal forwarding) until
# tobi/qmd#1030 lands; HIMMEL-3982 drops this block again.
assert qmd['fork']['fork_repo'] == 'https://github.com/yotamleo/qmd.git'
assert qmd['fork']['upstream_repo'] == 'https://github.com/tobi/qmd.git'
assert qmd['fork']['pin_file'] == 'scripts/lib/qmd-bin.sh'
assert 'version_pin' not in qmd

plugin_root = root / 'templates/luna-second-brain/.obsidian/plugins'
community = json.load(open(root / 'templates/luna-second-brain/.obsidian/community-plugins.json', encoding='utf-8'))
expected = {
    'calendar': ('luna-calendar', 'liamcain/obsidian-calendar-plugin'),
    'dataview': ('luna-dataview', 'blacksmithgu/obsidian-dataview'),
    'obsidian-banners': ('luna-obsidian-banners', 'noatpad/obsidian-banners'),
    'obsidian-local-rest-api': ('luna-obsidian-local-rest-api', 'coddingtonbear/obsidian-local-rest-api'),
    'qmd-as-md-obsidian': ('luna-qmd-as-md-obsidian', 'danieltomasz/qmd-as-md-obsidian'),
}
assert set(community) == set(expected), (community, sorted(expected))
for plugin_id, (entry_name, repo) in expected.items():
    manifest = json.load(open(plugin_root / plugin_id / 'manifest.json', encoding='utf-8'))
    entry = entries[entry_name]
    assert entry['tracked_repo'] == repo, (entry_name, entry['tracked_repo'], repo)
    assert entry['kind'] == 'tag_release' and entry['mode'] == 'base'
    assert entry['synced_base'].lstrip('v') == manifest['version'].lstrip('v'), (entry_name, entry['synced_base'], manifest['version'])
    assert 'version_pin' not in entry

# github-sync (HIMMEL-3066): opt-in, out of community-plugins.json, vendored
# under optional/plugins/ instead of .obsidian/plugins/ — checked separately
# since it is no longer one of the always-installed community entries above.
assert 'github-sync' not in community
gs_manifest = json.load(open(root / 'templates/luna-second-brain/optional/plugins/github-sync/manifest.json', encoding='utf-8'))
gs_entry = entries['luna-github-sync']
assert gs_entry['tracked_repo'] == 'kevinmkchin/Obsidian-GitHub-Sync'
assert gs_entry['kind'] == 'tag_release' and gs_entry['mode'] == 'base'
assert gs_entry['synced_base'].lstrip('v') == gs_manifest['version'].lstrip('v'), (gs_entry['synced_base'], gs_manifest['version'])
assert 'version_pin' not in gs_entry

audit = reg['coverage_audit']
covered = {row['name'] for row in audit['covered_elsewhere']}
skips = {row['name'] for row in audit['skips']}
assert 'scripts/lib pinned binaries' in covered
assert 'codex companion and installed marketplaces' in covered
assert 'claude-statusline' in skips
assert 'luna optional plugin pointers' in skips
print('ok')
PY
)"
audit_rc=$?
if [ "$audit_rc" -eq 0 ]; then
  ok "zero-gap inventory covers claude-obsidian (plain pin), qmd (carried fork, HIMMEL-3956), the five default-installed luna plugins + the opt-in github-sync (HIMMEL-3066), scripts/lib pins, codex dynamic discovery, and explicit skips"
else
  bad "zero-gap inventory invalid: $audit_out"
fi

# 3e. --manifest-only (HIMMEL-3464): local, no-network check that every
#     marketplace plugin manifest carries a "version" field. RED against a
#     scratch fixture with one manifest missing the field (never against the
#     real tree), then GREEN once every fixture manifest has one.
W_MAN="$(mktemp -d "${TMPDIR:-/tmp}/pdrift-manifest.XXXXXX")" || { bad "--manifest-only fixture: mktemp -d failed"; exit 1; }
mkdir -p "$W_MAN/plugin-a/.claude-plugin" "$W_MAN/plugin-b/.claude-plugin"
printf '{"name": "plugin-a", "description": "no version here"}\n' > "$W_MAN/plugin-a/.claude-plugin/plugin.json"
printf '{"name": "plugin-b", "version": "1.0.0"}\n' > "$W_MAN/plugin-b/.claude-plugin/plugin.json"
red_out="$(DRIFT_PLUGINS_DIR="$W_MAN" bash "$SCRIPT" --manifest-only 2>&1)"; red_rc=$?
if [ "$red_rc" -ne 0 ]; then ok "--manifest-only: RED — missing version exits non-zero"; else bad "--manifest-only: missing version did not fail (rc=0)"; fi
if grepq "$red_out" "plugin-a/.claude-plugin/plugin.json"; then ok "--manifest-only: RED names the offending manifest"; else bad "--manifest-only: RED output did not name plugin-a's manifest: $red_out"; fi
printf '{"name": "plugin-a", "version": "0.1.0"}\n' > "$W_MAN/plugin-a/.claude-plugin/plugin.json"
green_out="$(DRIFT_PLUGINS_DIR="$W_MAN" bash "$SCRIPT" --manifest-only 2>&1)"; green_rc=$?
if [ "$green_rc" -eq 0 ]; then ok "--manifest-only: GREEN — every manifest carries a version"; else bad "--manifest-only: GREEN fixture failed (rc=$green_rc): $green_out"; fi
rm -rf -- "$W_MAN"
real_out="$(bash "$SCRIPT" --manifest-only 2>&1)"; real_rc=$?
if [ "$real_rc" -eq 0 ]; then ok "--manifest-only: real tree — every marketplace plugin manifest carries a version"; else bad "--manifest-only: real tree failed (rc=$real_rc): $real_out"; fi

# 3f. --manifest-only: an empty/absent plugins dir must not silently pass
#     (codex-1, HIMMEL-3464 CR round 2).
W_EMPTY="$(mktemp -d "${TMPDIR:-/tmp}/pdrift-empty.XXXXXX")" || { bad "--manifest-only empty-dir fixture: mktemp -d failed"; exit 1; }
empty_out="$(DRIFT_PLUGINS_DIR="$W_EMPTY/no-such-dir" bash "$SCRIPT" --manifest-only 2>&1)"; empty_rc=$?
if [ "$empty_rc" -ne 0 ]; then ok "--manifest-only: RED — empty plugins dir exits non-zero"; else bad "--manifest-only: empty plugins dir did not fail (rc=0)"; fi
rm -rf -- "$W_EMPTY"

# 3g. --manifest-only: a truthy non-string version (bool/number) must not pass
#     (codex-2, HIMMEL-3464 CR round 2).
W_TYPE="$(mktemp -d "${TMPDIR:-/tmp}/pdrift-type.XXXXXX")" || { bad "--manifest-only version-type fixture: mktemp -d failed"; exit 1; }
mkdir -p "$W_TYPE/plugin-c/.claude-plugin"
printf '{"name": "plugin-c", "version": true}\n' > "$W_TYPE/plugin-c/.claude-plugin/plugin.json"
DRIFT_PLUGINS_DIR="$W_TYPE" bash "$SCRIPT" --manifest-only >/dev/null 2>&1; type_rc=$?
if [ "$type_rc" -ne 0 ]; then ok "--manifest-only: RED — non-string version (bool) exits non-zero"; else bad "--manifest-only: non-string version did not fail (rc=0)"; fi
rm -rf -- "$W_TYPE"

# 3h. --manifest-only: a manifest that decodes to non-object JSON (null, list)
#     must not crash on .get() (codex-1, HIMMEL-3464 CR round 3).
W_NULL="$(mktemp -d "${TMPDIR:-/tmp}/pdrift-null.XXXXXX")" || { bad "--manifest-only null-manifest fixture: mktemp -d failed"; exit 1; }
mkdir -p "$W_NULL/plugin-d/.claude-plugin"
printf 'null\n' > "$W_NULL/plugin-d/.claude-plugin/plugin.json"
null_out="$(DRIFT_PLUGINS_DIR="$W_NULL" bash "$SCRIPT" --manifest-only 2>&1)"; null_rc=$?
if [ "$null_rc" -ne 0 ]; then ok "--manifest-only: RED — non-object manifest (null) exits non-zero"; else bad "--manifest-only: non-object manifest did not fail (rc=0)"; fi
if grepq "$null_out" "Traceback"; then bad "--manifest-only: non-object manifest crashed instead of failing cleanly: $null_out"; else ok "--manifest-only: non-object manifest fails cleanly, no traceback"; fi
rm -rf -- "$W_NULL"

# 3i. --bump-required (HIMMEL-3551): a commit that changes a plugin file
#     without bumping that plugin's plugin.json "version" must fail, both in
#     staged mode (pre-commit shape) and range mode (CI shape). Throwaway git
#     repo fixtures — this check is inherently diff-based, unlike the
#     directory-only --manifest-only checks above.
W_BUMP="$(mktemp -d "${TMPDIR:-/tmp}/pdrift-bump.XXXXXX")" || { bad "--bump-required fixture: mktemp -d failed"; exit 1; }
(
  set -e
  cd "$W_BUMP"
  git init -q
  git config user.email test@example.com
  git config user.name test
  mkdir -p marketplace/plugins/plugin-a/.claude-plugin marketplace/plugins/plugin-a/skills
  printf '{"name": "plugin-a", "version": "0.1.0"}\n' > marketplace/plugins/plugin-a/.claude-plugin/plugin.json
  printf '# skill\n' > marketplace/plugins/plugin-a/skills/one.md
  git add -A
  git commit -q -m 'chore: seed plugin-a'
)
# RED (staged): edit a plugin file, stage it, don't touch the manifest.
(cd "$W_BUMP" && printf '# skill v2\n' > marketplace/plugins/plugin-a/skills/one.md && git add -A)
staged_red_out="$(cd "$W_BUMP" && bash "$SCRIPT" --bump-required 2>&1)"; staged_red_rc=$?
if [ "$staged_red_rc" -ne 0 ]; then ok "--bump-required (staged): RED — plugin changed without a version bump exits non-zero"; else bad "--bump-required (staged): RED did not fail (rc=0): $staged_red_out"; fi
if grepq "$staged_red_out" "plugin-a"; then ok "--bump-required (staged): RED names the offending plugin"; else bad "--bump-required (staged): RED output did not name plugin-a: $staged_red_out"; fi
# GREEN (staged): also bump the version.
(cd "$W_BUMP" && printf '{"name": "plugin-a", "version": "0.1.1"}\n' > marketplace/plugins/plugin-a/.claude-plugin/plugin.json && git add -A)
staged_green_out="$(cd "$W_BUMP" && bash "$SCRIPT" --bump-required 2>&1)"; staged_green_rc=$?
if [ "$staged_green_rc" -eq 0 ]; then ok "--bump-required (staged): GREEN — version bumped alongside the change"; else bad "--bump-required (staged): GREEN fixture failed (rc=$staged_green_rc): $staged_green_out"; fi
(cd "$W_BUMP" && git commit -q -m 'chore: bump plugin-a')

# RED (range): a second commit changes a plugin file, no manifest bump; gate
# against the range base..HEAD instead of the index.
base_sha="$(cd "$W_BUMP" && git rev-parse HEAD)"
(cd "$W_BUMP" && printf '# skill v3\n' > marketplace/plugins/plugin-a/skills/one.md && git add -A && git commit -q -m 'fix: tweak plugin-a skill, no bump')
range_red_out="$(cd "$W_BUMP" && bash "$SCRIPT" --bump-required "$base_sha" 2>&1)"; range_red_rc=$?
if [ "$range_red_rc" -ne 0 ]; then ok "--bump-required (range): RED — unbumped range change exits non-zero"; else bad "--bump-required (range): RED did not fail (rc=0): $range_red_out"; fi
# GREEN (range): a bump commit on top closes the range's own gap.
(cd "$W_BUMP" && printf '{"name": "plugin-a", "version": "0.1.2"}\n' > marketplace/plugins/plugin-a/.claude-plugin/plugin.json && git add -A && git commit -q -m 'chore: bump plugin-a again')
range_green_out="$(cd "$W_BUMP" && bash "$SCRIPT" --bump-required "$base_sha" 2>&1)"; range_green_rc=$?
if [ "$range_green_rc" -eq 0 ]; then ok "--bump-required (range): GREEN — version bumped within the range"; else bad "--bump-required (range): GREEN fixture failed (rc=$range_green_rc): $range_green_out"; fi
# A new plugin's first commit needs no bump — there's nothing to bump FROM.
(cd "$W_BUMP" && mkdir -p marketplace/plugins/plugin-b/.claude-plugin && printf '{"name": "plugin-b", "version": "0.1.0"}\n' > marketplace/plugins/plugin-b/.claude-plugin/plugin.json && git add -A)
new_plugin_out="$(cd "$W_BUMP" && bash "$SCRIPT" --bump-required 2>&1)"; new_plugin_rc=$?
if [ "$new_plugin_rc" -eq 0 ]; then ok "--bump-required (staged): a brand-new plugin needs no bump"; else bad "--bump-required (staged): new plugin wrongly required a bump (rc=$new_plugin_rc): $new_plugin_out"; fi
(cd "$W_BUMP" && git commit -q -m 'feat: add plugin-b')
# Nothing staged/changed under marketplace/plugins/ at all -> pass trivially.
noop_out="$(cd "$W_BUMP" && bash "$SCRIPT" --bump-required 2>&1)"; noop_rc=$?
if [ "$noop_rc" -eq 0 ]; then ok "--bump-required (staged): no plugin changes -> pass"; else bad "--bump-required (staged): no-op case failed (rc=$noop_rc): $noop_out"; fi
rm -rf -- "$W_BUMP"

# 4. End-to-end: the script runs to completion with a sane exit code —
#    0 (all current / fail-open), 2 (drift), or 3 (incomplete). Anything else
#    (1, 127, crash) fails.
out="$(bash "$SCRIPT" 2>&1)"; rc=$?
case "$rc" in
  0|2|3) ok "end-to-end run exits $rc (expected 0, 2, or 3)" ;;
  *)     bad "end-to-end run exited $rc; output: $out" ;;
esac
# When gh ran (not the fail-open path), both section headers must appear, and the
# claude-obsidian line must reference its TRUE upstream (AgriciDaniel), proving the
# override routed the check away from our fork repo.
if ! grepq "$out" "fail-open"; then
  if grepq "$out" "pinned remotes"; then ok "output has pinned-remotes section"; else bad "no pinned-remotes section"; fi
  if grepq "$out" "vendored forks"; then ok "output has vendored-forks section"; else bad "no vendored-forks section"; fi
  if grepq "$(printf '%s' "$out" | grep "claude-obsidian")" "AgriciDaniel/claude-obsidian"; then
    ok "claude-obsidian drift tracks true upstream (AgriciDaniel), not the fork"
  else
    bad "claude-obsidian line does not reference true upstream AgriciDaniel; output: $(printf '%s' "$out" | grep claude-obsidian)"
  fi
else
  ok "gh unavailable — fail-open path taken (sections skipped, expected)"
fi

# 5. Fail-open path, deterministically (hide gh from PATH). The script's headline
#    safety property: gh absent -> exit 0 + skip, so CI / fresh clones never break.
#    A system-directory PATH (e.g. /usr/bin:/bin) does NOT hide gh — gh, jq, git,
#    sha256sum etc. all live in /usr/bin on this station (HIMMEL-2524's inverse
#    mistake: hiding by directory re-admits the very tool named). Build a minimal
#    stub dir instead, naming only what this fail-open path itself needs (bash to
#    run the script, dirname for its `$(dirname "$0")` ROOT resolution) and
#    deliberately excluding gh, then assert the precondition that gh really is
#    unreachable under that PATH before trusting the run.
if NOGH_BIN="$(mktemp -d "${TMPDIR:-/tmp}/nogh-bin.XXXXXX")"; then
  tool_link "$(command -v bash)" "$NOGH_BIN/bash"
  tool_link "$(command -v dirname)" "$NOGH_BIN/dirname"
  if PATH="$NOGH_BIN" command -v gh >/dev/null 2>&1; then
    bad "fail-open fixture precondition failed: gh still reachable under stub PATH"
  else
    fo_out="$(PATH="$NOGH_BIN" bash "$SCRIPT" 2>&1)"; fo_rc=$?
    if [ "$fo_rc" -eq 0 ] && grepq "$fo_out" "fail-open"; then
      ok "fail-open: gh absent -> exit 0 + skip message"
    else
      bad "fail-open broken: rc=$fo_rc out=$fo_out"
    fi
  fi
  rm -rf "$NOGH_BIN"
else
  bad "fail-open fixture: mktemp -d failed"
fi

# 5b. Malformed vendored-fork UPSTREAM_PIN: a fork pin missing the generic
#     fields must mark the run incomplete, never skip into a false all-current.
W5B="$(mktemp -d)"; mkdir -p "$W5B/bin" "$W5B/scripts" "$W5B/marketplace/plugins/bad-pin"
cp "$SCRIPT" "$W5B/scripts/check-plugin-drift.sh"
mkdir -p "$W5B/scripts/upstreams"; cp "$ROOT/scripts/upstreams/pin-scan.py" "$W5B/scripts/upstreams/pin-scan.py"
cat >"$W5B/marketplace/plugins/bad-pin/UPSTREAM_PIN" <<'PIN'
upstream_repo=
PIN
cat >"$W5B/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = auth ] && [ "$2" = status ] && exit 0
exit 0
GH
chmod +x "$W5B/bin/gh"
printf '{"plugins":[]}' >"$W5B/empty_mjson.json"
printf '{}' >"$W5B/empty_ups.json"
badpin_out="$(PATH="$W5B/bin:$PATH" DRIFT_MJSON="$W5B/empty_mjson.json" DRIFT_UPSTREAMS="$W5B/empty_ups.json" DRIFT_REGISTRY=/dev/null DRIFT_KNOWN_MARKETPLACES=/dev/null bash "$W5B/scripts/check-plugin-drift.sh" 2>&1)"; badpin_rc=$?
rm -rf "$W5B"
if grepq "$(printf '%s' "$badpin_out" | grep 'bad-pin')" 'UNCHECKED'; then ok "malformed UPSTREAM_PIN -> named UNCHECKED"; else bad "malformed UPSTREAM_PIN not UNCHECKED; $(printf '%s' "$badpin_out" | grep bad-pin)"; fi
if [ "$badpin_rc" -eq 3 ]; then ok "malformed UPSTREAM_PIN run exits 3 (incomplete, not false all-current)"; else bad "malformed UPSTREAM_PIN rc=$badpin_rc; expected 3"; fi

# 5c. Vendored-fork hashing on systems without sha256sum (stock macOS):
#     fall back to shasum -a 256. Hash-tool failure must not read as DRIFT.
W5C="$(mktemp -d)"; mkdir -p "$W5C/bin" "$W5C/nosha" "$W5C/scripts" "$W5C/marketplace/plugins/hash-pin"
cp "$SCRIPT" "$W5C/scripts/check-plugin-drift.sh"
mkdir -p "$W5C/scripts/upstreams"; cp "$ROOT/scripts/upstreams/pin-scan.py" "$W5C/scripts/upstreams/pin-scan.py"
for f in /usr/bin/*; do
  b="$(basename "$f")"
  case "$b" in
    sha256sum|sha256sum.exe|shasum|shasum.exe) continue ;;
  esac
  tool_link "$f" "$W5C/nosha/$b"
done
for tool in awk base64 basename bash dirname grep head mktemp python3 rm sed tr; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  if [ -n "$tool_path" ]; then tool_link "$tool_path" "$W5C/nosha/$tool"; fi
done
# Fixture content is base64('hello\n') (the gh stub below); the pin carries the
# REAL sha256 of those bytes so the decode->tmpfile->hash->parse data path is
# genuinely exercised (a canned stub hash would pass without hashing anything).
HELLO_SHA=5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
cat >"$W5C/marketplace/plugins/hash-pin/UPSTREAM_PIN" <<PIN
upstream_repo=owner/hash-pin
upstream_path=file.txt
upstream_sha256=$HELLO_SHA
PIN
cat >"$W5C/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = auth ] && [ "$2" = status ] && exit 0
case "$*" in
  *"repos/owner/hash-pin/contents/file.txt"*) printf '%s\n' 'aGVsbG8K'; exit 0 ;;
esac
exit 0
GH
# Real-computing shasum stub: hashes its FILE argument (same output shape as
# `shasum -a 256`), so a wrong tmpfile/decode would fail the CURRENT assertion.
# The real sha256sum is resolved HERE (the mask below hides it from the script
# under test, not from this stub); python3 is the fallback where it is absent
# (macOS), and the runner's Git Bash has no python3 (HIMMEL-3182).
REAL_SHA256SUM="$(command -v sha256sum 2>/dev/null || true)"; export REAL_SHA256SUM
cat >"$W5C/bin/shasum" <<'SHASUM'
#!/usr/bin/env bash
if [ "$1" = "-a" ] && [ "$2" = "256" ]; then
  [ -n "${REAL_SHA256SUM:-}" ] && exec "$REAL_SHA256SUM" "$3"
  exec python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest() + "  " + sys.argv[1])' "$3"
fi
exit 1
SHASUM
chmod +x "$W5C/bin/gh" "$W5C/bin/shasum"
printf '{"plugins":[]}' >"$W5C/empty_mjson.json"
printf '{}' >"$W5C/empty_ups.json"
if PATH="$W5C/bin:$W5C/nosha" command -v sha256sum >/dev/null 2>&1; then
  bad "sha256sum-mask setup failed - sha256sum still resolvable"
else
  ok "sha256sum-mask: sha256sum unresolvable"
fi
hash_out="$(PATH="$W5C/bin:$W5C/nosha" DRIFT_MJSON="$W5C/empty_mjson.json" DRIFT_UPSTREAMS="$W5C/empty_ups.json" DRIFT_REGISTRY=/dev/null DRIFT_KNOWN_MARKETPLACES=/dev/null bash "$W5C/scripts/check-plugin-drift.sh" 2>&1)"; hash_rc=$?
if grepq "$hash_out" '^  hash-pin: CURRENT'; then ok "sha256sum absent -> shasum fallback verifies vendored fork CURRENT"; else bad "sha256sum fallback did not verify CURRENT; $(printf '%s' "$hash_out" | grep hash-pin)"; fi
if grepq "$(printf '%s' "$hash_out" | grep 'hash-pin')" 'DRIFT'; then bad "sha256sum absent was reported as DRIFT"; else ok "sha256sum absent never reported as DRIFT"; fi
if [ "$hash_rc" -eq 0 ]; then ok "sha256sum fallback-only run exits 0"; else bad "sha256sum fallback run rc=$hash_rc; expected 0"; fi

# 5c-neg. Same sandbox, mismatched pin sha -> the shasum fallback path must
#         report DRIFT (rc=2). Covers the vendored-fork DRIFT verdict, and the
#         'now <computed>' prefix proves the stub hashed the real bytes.
cat >"$W5C/marketplace/plugins/hash-pin/UPSTREAM_PIN" <<'PIN'
upstream_repo=owner/hash-pin
upstream_path=file.txt
upstream_sha256=0000000000000000000000000000000000000000000000000000000000000000
PIN
drift_out="$(PATH="$W5C/bin:$W5C/nosha" DRIFT_MJSON="$W5C/empty_mjson.json" DRIFT_UPSTREAMS="$W5C/empty_ups.json" DRIFT_REGISTRY=/dev/null DRIFT_KNOWN_MARKETPLACES=/dev/null bash "$W5C/scripts/check-plugin-drift.sh" 2>&1)"; drift_rc=$?
if grepq "$(printf '%s' "$drift_out" | grep '^  hash-pin: DRIFT')" "now ${HELLO_SHA:0:12}"; then ok "mismatched pin sha -> DRIFT via shasum fallback (computed hash in message)"; else bad "mismatched pin sha not reported as DRIFT with computed hash; $(printf '%s' "$drift_out" | grep hash-pin)"; fi
if [ "$drift_rc" -eq 2 ]; then ok "shasum-fallback DRIFT run exits 2"; else bad "shasum-fallback DRIFT run rc=$drift_rc; expected 2"; fi

# 5d. BOTH hash tools absent -> the tool-failure branch: named UNCHECKED
#     (never DRIFT), run incomplete (rc=3). Reuses the W5C sandbox with a bin
#     dir that has the gh stub but NO shasum.
mkdir -p "$W5C/nohash"
ln -s "$W5C/bin/gh" "$W5C/nohash/gh" 2>/dev/null || cp "$W5C/bin/gh" "$W5C/nohash/gh"
cat >"$W5C/marketplace/plugins/hash-pin/UPSTREAM_PIN" <<PIN
upstream_repo=owner/hash-pin
upstream_path=file.txt
upstream_sha256=$HELLO_SHA
PIN
if PATH="$W5C/nohash:$W5C/nosha" command -v shasum >/dev/null 2>&1; then
  bad "both-tools-mask setup failed - shasum still resolvable"
else
  ok "both-tools-mask: shasum unresolvable"
fi
notool_out="$(PATH="$W5C/nohash:$W5C/nosha" DRIFT_MJSON="$W5C/empty_mjson.json" DRIFT_UPSTREAMS="$W5C/empty_ups.json" DRIFT_REGISTRY=/dev/null DRIFT_KNOWN_MARKETPLACES=/dev/null bash "$W5C/scripts/check-plugin-drift.sh" 2>&1)"; notool_rc=$?
rm -rf "$W5C"
if grepq "$(printf '%s' "$notool_out" | grep 'hash-pin' | grep 'could not compute sha256')" 'UNCHECKED'; then ok "both hash tools absent -> named UNCHECKED (could not compute sha256)"; else bad "both-tools-absent not UNCHECKED; $(printf '%s' "$notool_out" | grep hash-pin)"; fi
if grepq "$(printf '%s' "$notool_out" | grep 'hash-pin')" 'DRIFT'; then bad "both hash tools absent was reported as DRIFT"; else ok "both hash tools absent never reported as DRIFT"; fi
if [ "$notool_rc" -eq 3 ]; then ok "both-tools-absent run exits 3 (incomplete, not false all-current)"; else bad "both-tools-absent run rc=$notool_rc; expected 3"; fi
# 6. Override-branch UNCHECKED paths via fixtures (DRIFT_MJSON/DRIFT_UPSTREAMS).
#    Both checks fire BEFORE any gh call, but the script's top-level fail-open gate
#    means the pin loop only runs when gh is present — so gate this on the real run
#    not having taken the fail-open path.
if ! grepq "$out" "fail-open"; then
  fix_m="$(mktemp)"; fix_u="$(mktemp)"
  cat >"$fix_m" <<'JSON'
{"plugins":[
 {"name":"fix-missing-base","source":{"source":"github","repo":"yotamleo/x","ref":"v1"}},
 {"name":"fix-bad-track","source":{"source":"github","repo":"yotamleo/y","ref":"v1"}}
]}
JSON
  cat >"$fix_u" <<'JSON'
{
 "fix-missing-base":{"upstream_repo":"AgriciDaniel/claude-obsidian","track":"release"},
 "fix-bad-track":{"upstream_repo":"AgriciDaniel/claude-obsidian","track":"bogus"}
}
JSON
  # Stub the carried-upstreams registry + marketplaces (HIMMEL-869) to /dev/null so
  # this override-branch fixture run stays hermetic + deterministic (no real
  # carried-upstream checks firing alongside the fixture under test).
  fx_out="$(DRIFT_MJSON="$fix_m" DRIFT_UPSTREAMS="$fix_u" DRIFT_REGISTRY=/dev/null DRIFT_KNOWN_MARKETPLACES=/dev/null bash "$SCRIPT" 2>&1)"; fx_rc=$?
  rm -f "$fix_m" "$fix_u"
  if grepq "$(printf '%s' "$fx_out" | grep "fix-missing-base")" "missing synced_base"; then ok "missing synced_base -> UNCHECKED (not a phantom BEHIND)"; else bad "missing synced_base not UNCHECKED; out: $(printf '%s' "$fx_out" | grep fix-missing-base)"; fi
  if grepq "$(printf '%s' "$fx_out" | grep "fix-bad-track")" "unknown track"; then ok "unknown track -> UNCHECKED"; else bad "bad track not UNCHECKED; out: $(printf '%s' "$fx_out" | grep fix-bad-track)"; fi
  if [ "$fx_rc" -eq 3 ] || [ "$fx_rc" -eq 2 ]; then ok "fixture run signals incomplete/drift (rc=$fx_rc, never a false all-clear)"; else bad "fixture run rc=$fx_rc; expected 3 (incomplete) — UNCHECKED must not read as exit 0"; fi
else
  ok "gh unavailable — override-branch fixture checks skipped (consistent with fail-open)"
fi

# Note (deliberately NOT covered by this smoke layer): the exit-2 DRIFT verdict on
# a REAL upstream advance is non-deterministic (depends on upstream releasing); the
# fixture above covers the UNCHECKED override paths deterministically. The CRLF-strip
# is exercised implicitly on this Windows checkout (python3 emits CRLF; check #2 +
# the real run both depend on it).

# 7. Carried-upstreams registry (HIMMEL-869): fully hermetic — a stubbed `gh` on
#    PATH serves canned SHAs/tags from a state dir, a fixture upstreams.json +
#    fixture known_marketplaces.json cover every kind/mode + the UNCHECKED shapes,
#    and a throwaway git checkout backs the commit_head/checkout + marketplace
#    paths. NO network. Exercises: commit_head pin (full SHA CURRENT / short-SHA
#    resolve BEHIND / checkout CURRENT / checkout-missing UNCHECKED / unknown-mode
#    UNCHECKED), tag_release base (CURRENT / BEHIND) + probe (CURRENT / BEHIND /
#    installed-ahead CURRENT), marketplace discovery from known_marketplaces.json
#    (github-sourced checked, directory-sourced skipped), unknown-kind UNCHECKED,
#    malformed-registry UNCHECKED, empty-registry clean.
W7="$(mktemp -d)"; mkdir -p "$W7/bin"
# Stub gh: dispatches on the api path, serves per-repo heads/tags/resolves from
# $GHSTATE so one stub covers every repo in the fixture.
cat > "$W7/bin/gh" <<'GH'
#!/usr/bin/env bash
a="$*"
[ "$1" = auth ] && [ "$2" = status ] && exit 0
repo=$(printf '%s\n' "$a" | sed -n 's|.*repos/\([^/ ]*/[^/ ]*\)/.*|\1|p')
case "$a" in
  *"/compare/"*) printf '%s\n' "${FAKE_AHEAD:-5}"; exit 0 ;;
  *"/tags"*)
    grep -E "^${repo}=" "$GHSTATE/tags" 2>/dev/null | head -1 | cut -d= -f2- | tr ',' '\n'
    exit 0 ;;
  *"commits/HEAD"*)
    grep -E "^${repo}=" "$GHSTATE/heads" 2>/dev/null | head -1 | cut -d= -f2
    exit 0 ;;
  *commits/*)
    ref=$(printf '%s\n' "$a" | sed -n 's|.*/commits/\([^ ]*\).*|\1|p')
    hit=$(grep -E "^${repo}:${ref}=" "$GHSTATE/resolves" 2>/dev/null | head -1 | cut -d= -f2)
    if [ -n "$hit" ]; then printf '%s\n' "$hit"; else
      grep -E "^${repo}=" "$GHSTATE/heads" 2>/dev/null | head -1 | cut -d= -f2
    fi
    exit 0 ;;
esac
exit 0
GH
chmod +x "$W7/bin/gh"
mk_repo() {  # mk_repo <name> -> echoes the new git checkout dir (1 commit)
  d="$W7/ck_$1"; mkdir -p "$d"; git -C "$d" init -q
  printf 'x\n' >"$d/f"
  git -C "$d" -c user.email=t@t -c user.name=t add f
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm "init $1"
  printf '%s' "$d"
}
CK1="$(mk_repo ok)"; CK1_HEAD="$(git -C "$CK1" rev-parse HEAD)"
CK2="$(mk_repo mkt)"; CK2_HEAD="$(git -C "$CK2" rev-parse HEAD)"
mkdir -p "$W7/state"
: >"$W7/state/resolves"
GCS_SHA=cccc111122223333444455556666777788889999
GCSDIR="$W7/gcs_owner"; mkdir -p "$GCSDIR"
printf ' %s \n' "$GCS_SHA" >"$GCSDIR/.gcs-sha"
cat >"$W7/state/heads" <<HEADS
owner/pin-full=aaaabbbbccccdddd000011112222333344445555
owner/pin-short=1111222233334444555566667777888899990000
owner/checkout-repo=${CK1_HEAD}
owner/mkt-fixt=${CK2_HEAD}
owner/gcs-repo=${GCS_SHA}
HEADS
cat >"$W7/state/resolves" <<RESOLVES
owner/pin-short:Short0a=9999888877776666555544443333222211110000
RESOLVES
cat >"$W7/state/tags" <<TAGS
owner/ver-current=v1.0.0,v1.2.3,v1.2.3-rc1
owner/ver-behind=v0.9.0,v2.0.0,v2.0.0-beta
owner/ver-ahead=v0.1.0,v0.2.0
owner/base-cur=v1.0.0,v1.2.3,v1.2.3-rc1
owner/base-behind=v1.0.0,v2.0.0
owner/base-held=v1.0.0,v2.0.0
owner/base-held-expired=v1.0.0,v3.0.0
TAGS
MISSING="$W7/does_not_exist_dir"
cat >"$W7/upstreams.json" <<JSON
{"entries":[
 {"name":"pin-full","kind":"commit_head","mode":"pin","tracked_repo":"owner/pin-full","pinned_commit":"aaaabbbbccccdddd000011112222333344445555","tier":"A"},
 {"name":"pin-short","kind":"commit_head","mode":"pin","tracked_repo":"owner/pin-short","pinned_commit":"Short0a","tier":"A"},
 {"name":"checkout-ok","kind":"commit_head","mode":"checkout","tracked_repo":"owner/checkout-repo","checkout_path":"$CK1","tier":"B"},
 {"name":"checkout-missing","kind":"commit_head","mode":"checkout","tracked_repo":"owner/x","checkout_path":"$MISSING","tier":"B"},
 {"name":"checkout-expand","kind":"commit_head","mode":"checkout","tracked_repo":"owner/checkout-repo","checkout_path":"\${DRIFT_TEST_UNSET_VAR:-\$DRIFT_TEST_DEFAULT_DIR}","tier":"B"},
 {"name":"checkout-gcs","kind":"commit_head","mode":"checkout","tracked_repo":"owner/gcs-repo","checkout_path":"$GCSDIR","tier":"B"},
 {"name":"base-cur","kind":"tag_release","mode":"base","tracked_repo":"owner/base-cur","synced_base":"v1.2.3","tier":"A"},
 {"name":"base-behind","kind":"tag_release","mode":"base","tracked_repo":"owner/base-behind","synced_base":"v1.0.0","tier":"A"},
 {"name":"base-held","kind":"tag_release","mode":"base","tracked_repo":"owner/base-held","synced_base":"1.0.0","tier":"A"},
 {"name":"base-held-expired","kind":"tag_release","mode":"base","tracked_repo":"owner/base-held-expired","synced_base":"1.0.0","tier":"A"},
 {"name":"probe-cur","kind":"tag_release","mode":"probe","tracked_repo":"owner/ver-current","version_command":"printf 1.2.3","version_regex":"[0-9]+[.][0-9]+[.][0-9]+[0-9A-Za-z.-]*","tier":"A"},
 {"name":"probe-behind","kind":"tag_release","mode":"probe","tracked_repo":"owner/ver-behind","version_command":"printf 1.2.3","version_regex":"[0-9]+[.][0-9]+[.][0-9]+[0-9A-Za-z.-]*","tier":"A"},
 {"name":"probe-ahead","kind":"tag_release","mode":"probe","tracked_repo":"owner/ver-ahead","version_command":"printf 1.5.0","version_regex":"[0-9]+[.][0-9]+[.][0-9]+[0-9A-Za-z.-]*","tier":"A"},
 {"name":"probe-pipe-regex","kind":"tag_release","mode":"probe","tracked_repo":"owner/ver-current","version_command":"printf 1.2.3","version_regex":"[0-9]+[.][0-9]+[.][0-9]+|nomatchxyz","tier":"A"},
 {"name":"weird-kind","kind":"bogus","mode":"x","tracked_repo":"owner/x"},
 {"name":"weird-mode","kind":"commit_head","mode":"bogus","tracked_repo":"owner/x"}
]}
JSON
cat >"$W7/km.json" <<KJSON
{
 "fixt-mkt":{"source":{"source":"github","repo":"owner/mkt-fixt"},"installLocation":"$CK2","autoUpdate":true},
 "dir-src":{"source":{"source":"directory","path":"/whatever"},"installLocation":"/whatever"}
}
KJSON
empty_mjson="$W7/empty_mjson.json"
printf '{"plugins":[]}' >"$empty_mjson"
printf '{}' >"$W7/empty_ups.json"
# pin-holds rows for carried upstreams (HIMMEL-3952): eco "upstream", key = the
# registry name. Both holds reviewed 2.0.0, but base-held-expired's upstream
# has since shipped v3.0.0, so its hold no longer applies.
cat >"$W7/holds.json" <<'JSON'
{"holds":[
 {"eco":"upstream","key":"base-held","current":"1.0.0","latest_reviewed":"2.0.0","reason":"fixture upstream hold"},
 {"eco":"upstream","key":"base-held-expired","current":"1.0.0","latest_reviewed":"2.0.0","reason":"fixture upstream hold"}
]}
JSON
GHSTATE="$W7/state" PATH="$W7/bin:$PATH" DRIFT_PIN_HOLDS="$W7/holds.json" \
  DRIFT_REGISTRY="$W7/upstreams.json" DRIFT_KNOWN_MARKETPLACES="$W7/km.json" \
  DRIFT_MJSON="$empty_mjson" DRIFT_UPSTREAMS="$W7/empty_ups.json" \
  DRIFT_TEST_DEFAULT_DIR="$CK1" \
  bash "$SCRIPT" >"$W7/out.txt" 2>&1; rc7=$?
sec7="$(sed -n '/carried upstreams/,$p' "$W7/out.txt")"
# 7a. commit_head paths.
if grepq "$sec7" '^  pin-full: CURRENT'; then ok "commit_head pin full-SHA -> CURRENT"; else bad "commit_head pin-full not CURRENT; $(printf '%s' "$sec7" | grep pin-full)"; fi
if grepq "$sec7" '^  pin-short: BEHIND'; then ok "commit_head pin short-SHA resolved -> BEHIND"; else bad "commit_head pin-short not BEHIND; $(printf '%s' "$sec7" | grep pin-short)"; fi
if grepq "$sec7" '^  checkout-ok: CURRENT'; then ok "commit_head checkout present -> CURRENT"; else bad "checkout-ok not CURRENT; $(printf '%s' "$sec7" | grep checkout-ok)"; fi
if grepq "$(printf '%s' "$sec7" | grep 'checkout-missing')" 'UNCHECKED'; then ok "commit_head checkout absent -> UNCHECKED"; else bad "checkout-missing not UNCHECKED"; fi
# 7a-expand (HIMMEL-3537): checkout_path is ${UNSET:-default}, default text
# itself carries a bare $VAR (DRIFT_TEST_DEFAULT_DIR=$CK1) — proves both the
# ${VAR:-default} fallback AND the second substitution pass that expands a
# $VAR embedded in the default's own text. A failed expand would leave the
# literal '${...}' string as checkout_path, which is not a directory ->
# "checkout not present", never CURRENT.
if grepq "$sec7" '^  checkout-expand: CURRENT'; then ok "expand(): \${VAR:-default} with \$VAR inside the default resolves to a real checkout -> CURRENT"; else bad "checkout-expand not CURRENT; $(printf '%s' "$sec7" | grep checkout-expand)"; fi
# 7a-gcs (HIMMEL-3537): no .git dir, but a .gcs-sha file (Claude Code's own
# GCS-tarball marketplace install shape) -> read that as the local commit
# instead of failing UNCHECKED. The fixture .gcs-sha carries leading/trailing
# whitespace and a newline to prove the tr -d '[:space:]' strip.
if grepq "$sec7" '^  checkout-gcs: CURRENT'; then ok ".gcs-sha (non-git checkout) read as local commit -> CURRENT"; else bad "checkout-gcs not CURRENT; $(printf '%s' "$sec7" | grep checkout-gcs)"; fi
if grepq "$(printf '%s' "$sec7" | grep 'weird-mode')" "mode 'bogus' unknown"; then ok "commit_head unknown mode -> UNCHECKED"; else bad "weird-mode not flagged"; fi
# 7b. tag_release paths.
if grepq "$sec7" '^  base-cur: CURRENT'; then ok "tag_release base synced -> CURRENT"; else bad "base-cur not CURRENT"; fi
if grepq "$sec7" '^  base-behind: BEHIND'; then ok "tag_release base stale -> BEHIND"; else bad "base-behind not BEHIND"; fi
if grepq "$sec7" '^  base-held: HELD '; then ok "tag_release base with a matching pin-holds row -> HELD, not BEHIND"; else bad "base-held not HELD; $(printf '%s' "$sec7" | grep base-held)"; fi
if grepq "$sec7" '^  base-held-expired: BEHIND'; then ok "tag_release hold expires once upstream moves past the reviewed release -> BEHIND"; else bad "base-held-expired not BEHIND; $(printf '%s' "$sec7" | grep base-held-expired)"; fi
# 7b-vm (HIMMEL-4583): a hold whose release is "vm-proof" names the proof route
# that vm.mode resolves (scripts/lib/vm-mode.sh), never a hardcoded local VM, and
# under vm.mode=none it stays HELD and says no VM can release it.
cat >"$W7/holds-vm.json" <<'JSON'
{"holds":[
 {"eco":"upstream","key":"base-held","current":"1.0.0","latest_reviewed":"2.0.0","release":"vm-proof","reason":"fixture vm hold"}
]}
JSON
run7vm() { # <vm.mode config json> -> the base-held line
  printf '%s\n' "$1" >"$W7/vmcfg.json"
  HIMMEL_VM_MODE_CONFIG="$W7/vmcfg.json" GHSTATE="$W7/state" PATH="$W7/bin:$PATH" DRIFT_PIN_HOLDS="$W7/holds-vm.json" \
    DRIFT_REGISTRY="$W7/upstreams.json" DRIFT_KNOWN_MARKETPLACES="$W7/km.json" \
    DRIFT_MJSON="$empty_mjson" DRIFT_UPSTREAMS="$W7/empty_ups.json" \
    DRIFT_TEST_DEFAULT_DIR="$CK1" \
    bash "$SCRIPT" 2>&1 | grep '^  base-held:'
}
l7="$(run7vm '{}')"
if grepq "$l7" -F 'HELD' && grepq "$l7" -F 'release: vm-proof via local-vm localhost:2222'; then ok "vm-proof hold, vm.mode unset -> local VM route"; else bad "vm-proof local route missing; $l7"; fi
l7="$(run7vm '{"vm":{"mode":"remote","remote":{"ssh":"ops@vm.example","port":2201}}}')"
if grepq "$l7" -F 'HELD' && grepq "$l7" -F 'release: vm-proof via remote-vm ops@vm.example:2201'; then ok "vm-proof hold, vm.mode=remote -> remote VM route"; else bad "vm-proof remote route missing; $l7"; fi
l7="$(run7vm '{"vm":{"mode":"none"}}')"
if grepq "$l7" -F 'HELD' && grepq "$l7" -F 'vm.mode=none' && grepq "$l7" -F 'operator ack' && grepq "$l7" -F 'never auto-released'; then ok "vm-proof hold, vm.mode=none -> stays HELD, operator ack + rollback point"; else bad "vm-proof none not HELD-with-ack; $l7"; fi
# HIMMEL-4597 (J1932 T1): a resolver error stays HELD but offers only "fix the config", never the ack route.
l7="$(run7vm '{"vm":{"mode":"Local"}}')"
if grepq "$l7" -F 'HELD' && grepq "$l7" -F 'vm.mode config error' && grepq "$l7" -F 'fix ~/.himmel/config.json' && ! grepq "$l7" -F 'operator ack'; then ok "vm-proof hold, vm.mode config error -> HELD, fix config, no ack route"; else bad "vm-proof error offers the ack route or no fix-config; $l7"; fi
if grepq "$sec7" '^  probe-cur: CURRENT'; then ok "tag_release probe synced -> CURRENT"; else bad "probe-cur not CURRENT"; fi
if grepq "$sec7" '^  probe-behind: BEHIND'; then ok "tag_release probe stale -> BEHIND"; else bad "probe-behind not BEHIND"; fi
if grepq "$(printf '%s' "$sec7" | grep 'probe-ahead')" 'CURRENT'; then ok "tag_release probe installed-ahead -> CURRENT (not a phantom BEHIND)"; else bad "probe-ahead not CURRENT; $(printf '%s' "$sec7" | grep probe-ahead)"; fi
# 7b-extra (HIMMEL-869 CR fix): a version_regex containing a literal '|'
# (regex alternation) must round-trip through the emitter/consumer protocol
# intact. Under a pipe-delimited protocol this record's own fields would
# misalign (v2/version_regex truncates at the first '|', the remainder spills
# into tier) — assert the verdict line is well-formed: CURRENT, with tier
# exactly "[A]" and no leaked regex remainder.
if grepq "$(printf '%s' "$sec7" | grep '^  probe-pipe-regex: CURRENT')" '\[A\]$'; then
  ok "tag_release probe: version_regex containing '|' parses into correct fields (well-formed CURRENT line, tier intact)"
else
  bad "probe-pipe-regex line malformed (delimiter/field misalignment?); $(printf '%s' "$sec7" | grep probe-pipe-regex)"
fi
if grepq "$(printf '%s' "$sec7" | grep 'probe-pipe-regex')" 'nomatchxyz'; then
  bad "probe-pipe-regex line leaked regex remainder into tier/verdict — field misalignment"
else
  ok "probe-pipe-regex line does not leak regex remainder (fields correctly delimited)"
fi
# 7c. marketplace discovery.
if grepq "$sec7" '^  mkt:fixt-mkt: CURRENT'; then ok "marketplace github-sourced checkout -> CURRENT"; else bad "mkt:fixt-mkt not CURRENT; $(printf '%s' "$sec7" | grep 'mkt:')"; fi
if grepq "$sec7" 'mkt:dir-src'; then bad "directory-sourced marketplace should be skipped (not checked)"; else ok "directory-sourced marketplace correctly skipped"; fi
# 7d. unknown kind + exit code (drift from pin-short/base-behind/probe-behind => 2).
if grepq "$(printf '%s' "$sec7" | grep 'weird-kind')" "unknown kind 'bogus'"; then ok "unknown kind -> UNCHECKED"; else bad "weird-kind not flagged"; fi
if [ "$rc7" -eq 2 ]; then ok "carried-upstreams drift run exits 2 (drift, precedence over incomplete)"; else bad "carried-upstreams drift run rc=$rc7; expected 2"; fi
# 7e. malformed registry -> class UNCHECKED (never a false all-clear).
printf '{not valid json' >"$W7/bad.json"
bad_out="$(GHSTATE="$W7/state" PATH="$W7/bin:$PATH" DRIFT_REGISTRY="$W7/bad.json" DRIFT_KNOWN_MARKETPLACES=/dev/null DRIFT_MJSON="$empty_mjson" DRIFT_UPSTREAMS="$W7/empty_ups.json" bash "$SCRIPT" 2>&1)"; bad_rc=$?
if grepq "$bad_out" 'carried-upstreams class UNCHECKED'; then ok "malformed registry -> class UNCHECKED"; else bad "malformed registry not UNCHECKED; $bad_out"; fi
if [ "$bad_rc" -eq 3 ]; then ok "malformed registry run exits 3 (incomplete, not a false 0)"; else bad "malformed registry rc=$bad_rc; expected 3"; fi
# 7f. empty/missing registry -> no entries (clean, not UNCHECKED). (Overall exit
#     code is not asserted: the vendored-forks section still globs the REAL
#     UPSTREAM_PINs and reads UNCHECKED under the stub, which is orthogonal to
#     the empty-registry property under test — that the carried-upstreams section
#     emits no spurious entries.)
empty_out="$(GHSTATE="$W7/state" PATH="$W7/bin:$PATH" DRIFT_REGISTRY=/dev/null DRIFT_KNOWN_MARKETPLACES=/dev/null DRIFT_MJSON="$empty_mjson" DRIFT_UPSTREAMS="$W7/empty_ups.json" bash "$SCRIPT" 2>&1)"
if grepq "$empty_out" 'carried upstreams' && ! printf '%s' "$empty_out" | sed -n '/carried upstreams/,$p' | grep -Eq '^  [a-z].*: (CURRENT|BEHIND|UNCHECKED|unknown)'; then
  ok "empty registry -> carried-upstreams section header only (no spurious entries/UNCHECKED)"
else
  bad "empty registry emitted entries or parse error; $(printf '%s' "$empty_out" | sed -n '/carried upstreams/,$p')"
fi
rm -rf "$W7"

# 8. Probe watchdog fallback (HIMMEL-869 CR fix 1): when `timeout` is absent
#    from PATH, a hanging version_command must not wedge the run — the
#    bash-native watchdog fallback bounds it to the same 10s budget, and a
#    killed probe reads UNCHECKED (never CURRENT/BEHIND). PATH is rebuilt from
#    symlinks to every /usr/bin entry EXCEPT timeout (Windows also ships
#    system32/timeout.exe, so merely reordering PATH can't hide it — the
#    masked dir must be the only source of these tools) plus /mingw64/bin
#    (git) and the python3 dir, so the fallback branch is the one genuinely
#    exercised, not the `timeout`-present branch.
W8="$(mktemp -d)"; mkdir -p "$W8/notimeout" "$W8/bin"
for f in /usr/bin/*; do
  b="$(basename "$f")"
  case "$b" in
    timeout|timeout.exe) continue ;;
  esac
  tool_link "$f" "$W8/notimeout/$b"
done
# macOS ships bash only at /bin/bash, never under /usr/bin -- name it
# explicitly (same convention as the NOGH_BIN block above) so the rebuilt
# PATH can still run "$SCRIPT" regardless of which directory holds it.
tool_link "$(command -v bash)" "$W8/notimeout/bash"
cat > "$W8/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = auth ] && [ "$2" = status ] && exit 0
exit 0
GH
chmod +x "$W8/bin/gh"
cat > "$W8/bin/hangprobe" <<'HANG'
#!/usr/bin/env bash
sleep 60
HANG
chmod +x "$W8/bin/hangprobe"
cat > "$W8/upstreams.json" <<'JSON'
{"entries":[
 {"name":"hang-tool","kind":"tag_release","mode":"probe","tracked_repo":"owner/hang","version_command":"hangprobe","version_regex":"[0-9]+","tier":"A"}
]}
JSON
printf '{"plugins":[]}' >"$W8/empty_mjson.json"
printf '{}' >"$W8/empty_ups.json"
NOTIMEOUT_PATH="$W8/bin:$W8/notimeout:/mingw64/bin:$HOME/.local/bin"
if PATH="$NOTIMEOUT_PATH" command -v timeout >/dev/null 2>&1; then
  bad "PATH-mask setup failed — 'timeout' still resolvable, fallback branch not actually exercised"
else
  ok "PATH-mask: 'timeout' unresolvable in the rebuilt PATH"
fi
w8_start=$(date +%s)
w8_out="$(PATH="$NOTIMEOUT_PATH" DRIFT_REGISTRY="$W8/upstreams.json" DRIFT_KNOWN_MARKETPLACES=/dev/null DRIFT_MJSON="$W8/empty_mjson.json" DRIFT_UPSTREAMS="$W8/empty_ups.json" bash "$SCRIPT" 2>&1)"; w8_rc=$?
w8_elapsed=$(( $(date +%s) - w8_start ))
if [ "$w8_elapsed" -lt 20 ]; then ok "hanging probe watchdog: run completed in ${w8_elapsed}s (<20s)"; else bad "hanging probe watchdog: run took ${w8_elapsed}s (>=20s) — watchdog did not bound it"; fi
if grepq "$w8_out" "watchdog fallback"; then ok "hanging probe: fallback-watchdog note emitted"; else bad "hanging probe: no fallback-watchdog note; out: $w8_out"; fi
if grepq "$(printf '%s' "$w8_out" | grep 'hang-tool')" 'probe timed out'; then ok "hanging probe: entry reads 'probe timed out' UNCHECKED"; else bad "hanging probe: no timeout note; $(printf '%s' "$w8_out" | grep hang-tool)"; fi
if grepq "$w8_out" -E '^  hang-tool: (CURRENT|BEHIND)'; then bad "hanging probe: entry read CURRENT/BEHIND instead of UNCHECKED"; else ok "hanging probe: entry never read CURRENT/BEHIND"; fi
if [ "$w8_rc" -eq 3 ]; then ok "hanging probe run exits 3 (incomplete)"; else bad "hanging probe run rc=$w8_rc; expected 3"; fi
rm -rf "$W8"

# 9. Marketplace entry lacking installLocation (HIMMEL-869 CR fix 3): older/
#    foreign known_marketplaces.json shapes must skip with a named per-entry
#    UNCHECKED note, never fall through to the checkout-missing branch with an
#    empty path (which would read as "checkout not present on this machine ()"
#    — indistinguishable from a real absent checkout).
W9="$(mktemp -d)"; mkdir -p "$W9/bin"
cat > "$W9/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = auth ] && [ "$2" = status ] && exit 0
exit 0
GH
chmod +x "$W9/bin/gh"
cat > "$W9/km.json" <<'KJSON'
{"no-install-loc-marketplace":{"source":{"source":"github","repo":"owner/no-loc"}}}
KJSON
printf '{"plugins":[]}' >"$W9/empty_mjson.json"
printf '{}' >"$W9/empty_ups.json"
w9_out="$(PATH="$W9/bin:$PATH" DRIFT_REGISTRY=/dev/null DRIFT_KNOWN_MARKETPLACES="$W9/km.json" DRIFT_MJSON="$W9/empty_mjson.json" DRIFT_UPSTREAMS="$W9/empty_ups.json" bash "$SCRIPT" 2>&1)"; w9_rc=$?
if grepq "$(printf '%s' "$w9_out" | grep 'mkt:no-install-loc-marketplace')" 'lacks installLocation'; then
  ok "marketplace entry without installLocation -> named per-entry UNCHECKED skip"
else
  bad "missing-installLocation marketplace entry not flagged; $(printf '%s' "$w9_out" | grep 'no-install-loc-marketplace')"
fi
if grepq "$(printf '%s' "$w9_out" | grep 'mkt:no-install-loc-marketplace')" 'checkout not present'; then
  bad "missing-installLocation entry fell through to the empty-path checkout-missing branch"
else
  ok "missing-installLocation entry did not fall through to checkout-missing"
fi
if [ "$w9_rc" -eq 3 ]; then ok "missing-installLocation-only run exits 3 (incomplete)"; else bad "missing-installLocation run rc=$w9_rc; expected 3"; fi
rm -rf "$W9"

# 10. Probe timeout path (HIMMEL-869 CR round-3): with `timeout` AVAILABLE on
#     PATH (the normal/common case — no PATH masking here, unlike test 8's
#     fallback exercise), a probe that prints a version line and THEN hangs
#     must be killed by `timeout` (rc=124) and read UNCHECKED, never parsed
#     from its partial (pre-hang) output as CURRENT/BEHIND.
W10="$(mktemp -d)"; mkdir -p "$W10/bin"
cat > "$W10/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = auth ] && [ "$2" = status ] && exit 0
exit 0
GH
chmod +x "$W10/bin/gh"
cat > "$W10/bin/timedprobe" <<'HANG'
#!/usr/bin/env bash
echo "v1.2.3"
sleep 60
HANG
chmod +x "$W10/bin/timedprobe"
cat > "$W10/upstreams.json" <<'JSON'
{"entries":[
 {"name":"timedprobe-tool","kind":"tag_release","mode":"probe","tracked_repo":"owner/timed","version_command":"timedprobe","version_regex":"[0-9]+\\.[0-9]+\\.[0-9]+","tier":"A"}
]}
JSON
printf '{"plugins":[]}' >"$W10/empty_mjson.json"
printf '{}' >"$W10/empty_ups.json"
# Stock macOS ships neither `timeout` nor `gtimeout` (HIMMEL-2589) -- the
# ambient PATH cannot be trusted to have one, so resolve it explicitly via
# scripts/lib/timeout-bin.sh and put it on this test's own PATH, same as
# `tool_link` does for bash/dirname above, rather than assuming the host has
# GNU coreutils.
# shellcheck source=lib/timeout-bin.sh
. "$ROOT/scripts/lib/timeout-bin.sh"
if [ -n "$_TIMEOUT_BIN" ]; then
  tool_link "$_TIMEOUT_BIN" "$W10/bin/timeout"
  TIMEOUT_PATH="$W10/bin:$PATH"
  if PATH="$TIMEOUT_PATH" command -v timeout >/dev/null 2>&1; then
    ok "timeout-available setup: 'timeout' resolvable on PATH"
  else
    bad "timeout-available setup failed — 'timeout' not resolvable, timeout branch not actually exercised"
  fi
  w10_start=$(date +%s)
  w10_out="$(PATH="$TIMEOUT_PATH" DRIFT_REGISTRY="$W10/upstreams.json" DRIFT_KNOWN_MARKETPLACES=/dev/null DRIFT_MJSON="$W10/empty_mjson.json" DRIFT_UPSTREAMS="$W10/empty_ups.json" bash "$SCRIPT" 2>&1)"; w10_rc=$?
  w10_elapsed=$(( $(date +%s) - w10_start ))
  if [ "$w10_elapsed" -lt 20 ]; then ok "timeout-path hanging probe: run completed in ${w10_elapsed}s (<20s)"; else bad "timeout-path hanging probe: run took ${w10_elapsed}s (>=20s) — 'timeout' did not bound it"; fi
  if grepq "$(printf '%s' "$w10_out" | grep 'timedprobe-tool')" 'probe timed out (10s)'; then ok "timeout-path hanging probe: entry reads 'probe timed out (10s)' UNCHECKED"; else bad "timeout-path hanging probe: no timeout note; $(printf '%s' "$w10_out" | grep timedprobe-tool)"; fi
  if grepq "$w10_out" -E '^  timedprobe-tool: (CURRENT|BEHIND)'; then bad "timeout-path hanging probe: entry read CURRENT/BEHIND instead of UNCHECKED (partial pre-hang output was parsed)"; else ok "timeout-path hanging probe: entry never read CURRENT/BEHIND"; fi
  if [ "$w10_rc" -eq 3 ]; then ok "timeout-path hanging probe run exits 3 (incomplete)"; else bad "timeout-path hanging probe run rc=$w10_rc; expected 3"; fi
else
  ok "timeout-available path: skipped — no GNU timeout/gtimeout resolvable on this host (consistent with the documented degrade in timeout-bin.sh)"
fi
rm -rf "$W10"

# 11. latest_source=release (HIMMEL-1046): for a NON-MONOTONIC-tag upstream, the
#     guard must read the maintainer's latest NON-prerelease via the Releases API,
#     NOT the highest semver tag (a stale higher tag would be a phantom latest).
#     The stub serves BOTH a stale-higher tag (v1.0.0) and the real release
#     (v0.9.16); the release-mode entry compares against v0.9.16, while the default
#     tag-mode control against the SAME repo picks the stale v1.0.0 — proving the
#     opt-in changes the source.
W11="$(mktemp -d)"; mkdir -p "$W11/bin"
cat > "$W11/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = auth ] && [ "$2" = status ] && exit 0
case "$*" in
  *"/releases/latest"*) printf 'v0.9.16\n'; exit 0 ;;
  *"/tags"*) printf 'v1.0.0\nv0.9.16\nv0.9.13\n'; exit 0 ;;
esac
exit 0
GH
chmod +x "$W11/bin/gh"
cat > "$W11/reg-release.json" <<'JSON'
{"entries":[
 {"name":"nonmono-rel","kind":"tag_release","mode":"base","tracked_repo":"owner/nonmono","synced_base":"0.9.13","latest_source":"release","tier":"A"}
]}
JSON
cat > "$W11/reg-tag.json" <<'JSON'
{"entries":[
 {"name":"nonmono-tag","kind":"tag_release","mode":"base","tracked_repo":"owner/nonmono","synced_base":"0.9.13","tier":"A"}
]}
JSON
printf '{"plugins":[]}' >"$W11/empty_mjson.json"; printf '{}' >"$W11/empty_ups.json"
rel_out="$(PATH="$W11/bin:$PATH" DRIFT_REGISTRY="$W11/reg-release.json" DRIFT_KNOWN_MARKETPLACES=/dev/null DRIFT_MJSON="$W11/empty_mjson.json" DRIFT_UPSTREAMS="$W11/empty_ups.json" bash "$SCRIPT" 2>&1)"
tag_out="$(PATH="$W11/bin:$PATH" DRIFT_REGISTRY="$W11/reg-tag.json" DRIFT_KNOWN_MARKETPLACES=/dev/null DRIFT_MJSON="$W11/empty_mjson.json" DRIFT_UPSTREAMS="$W11/empty_ups.json" bash "$SCRIPT" 2>&1)"
if grepq "$(printf '%s' "$rel_out" | grep 'nonmono-rel')" 'v0.9.16'; then ok "latest_source=release compares against Releases API (v0.9.16)"; else bad "release-mode did not use releases/latest; $(printf '%s' "$rel_out" | grep nonmono-rel)"; fi
if grepq "$(printf '%s' "$rel_out" | grep 'nonmono-rel')" 'v1.0.0'; then bad "release-mode leaked the stale v1.0.0 tag"; else ok "latest_source=release ignores the stale v1.0.0 highest tag"; fi
if grepq "$(printf '%s' "$tag_out" | grep 'nonmono-tag')" 'v1.0.0'; then ok "default tag-mode control picks the highest tag v1.0.0 — confirms the opt-in changes the source"; else bad "tag-mode control did not pick v1.0.0; $(printf '%s' "$tag_out" | grep nonmono-tag)"; fi
# releases/latest unreachable -> UNCHECKED (never a phantom compare).
cat > "$W11/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = auth ] && [ "$2" = status ] && exit 0
case "$*" in
  *"/releases/latest"*) exit 1 ;;
esac
exit 0
GH
chmod +x "$W11/bin/gh"
unreach_out="$(PATH="$W11/bin:$PATH" DRIFT_REGISTRY="$W11/reg-release.json" DRIFT_KNOWN_MARKETPLACES=/dev/null DRIFT_MJSON="$W11/empty_mjson.json" DRIFT_UPSTREAMS="$W11/empty_ups.json" bash "$SCRIPT" 2>&1)"; unreach_rc=$?
if grepq "$(printf '%s' "$unreach_out" | grep 'nonmono-rel')" 'UNCHECKED'; then ok "latest_source=release: no latest release -> UNCHECKED"; else bad "release-mode unreachable not UNCHECKED; $(printf '%s' "$unreach_out" | grep nonmono-rel)"; fi
if [ "$unreach_rc" -eq 3 ]; then ok "release-mode unreachable run exits 3 (incomplete)"; else bad "release-mode unreachable rc=$unreach_rc; expected 3"; fi
# An UNKNOWN latest_source (typo like "releases") must be UNCHECKED, never a
# silent fall-through to tag mode (which would re-introduce the phantom drift).
cat > "$W11/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = auth ] && [ "$2" = status ] && exit 0
case "$*" in
  *"/tags"*) printf 'v1.0.0\nv0.9.16\n'; exit 0 ;;
esac
exit 0
GH
chmod +x "$W11/bin/gh"
cat > "$W11/reg-bad.json" <<'JSON'
{"entries":[
 {"name":"bad-src","kind":"tag_release","mode":"base","tracked_repo":"owner/nonmono","synced_base":"0.9.13","latest_source":"releases","tier":"A"}
]}
JSON
bad_out="$(PATH="$W11/bin:$PATH" DRIFT_REGISTRY="$W11/reg-bad.json" DRIFT_KNOWN_MARKETPLACES=/dev/null DRIFT_MJSON="$W11/empty_mjson.json" DRIFT_UPSTREAMS="$W11/empty_ups.json" bash "$SCRIPT" 2>&1)"; bad_rc=$?
if grepq "$(printf '%s' "$bad_out" | grep 'bad-src')" "unknown latest_source"; then ok "unknown latest_source -> UNCHECKED (not silent tag-mode)"; else bad "unknown latest_source not UNCHECKED; $(printf '%s' "$bad_out" | grep bad-src)"; fi
if grepq "$bad_out" -E '^  bad-src: (CURRENT|BEHIND)'; then bad "unknown latest_source fell through to a tag-mode verdict"; else ok "unknown latest_source never produced a CURRENT/BEHIND verdict"; fi
rm -rf "$W11"

# 12. Pin scan (HIMMEL-3807): every npm/bun dep, pre-commit rev, workflow
#     `uses:`, gitleaks `ver=` and OXLINT_VERSION= literal is discovered by
#     scanning the repo and compared to its latest stable — hermetic, `curl`
#     (npm registry) and `gh` (releases) stubbed from a state dir. A
#     deliberately stale pin for a newly watched package MUST read BEHIND.
W12="$(mktemp -d "${TMPDIR:-/tmp}/pdrift-w12.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }; mkdir -p "$W12/bin" "$W12/state" "$W12/root/pkgA" "$W12/root/.github/workflows" "$W12/root/scripts/hooks"
cat > "$W12/bin/curl" <<'CURL'
#!/usr/bin/env bash
for last; do :; done
pkg="${last#https://registry.npmjs.org/}"; pkg="${pkg%/latest}"
case "$last" in https://pypi.org/pypi/*) pkg="${last#https://pypi.org/pypi/}"; pkg="${pkg%/json}"
  ver=$(grep -E "^${pkg}=" "$PINSTATE/pypi" 2>/dev/null | head -1 | cut -d= -f2); [ -n "$ver" ] || exit 22
  printf '{"info":{"version":"%s"}}\n' "$ver"; exit 0 ;; esac
ver=$(grep -E "^${pkg}=" "$PINSTATE/npm" 2>/dev/null | head -1 | cut -d= -f2)
[ -n "$ver" ] || ver="${PINSTATE_DEFAULT:-}"
[ -n "$ver" ] || exit 22
printf '{"name":"%s","version":"%s"}\n' "$pkg" "$ver"
CURL
cat > "$W12/bin/gh" <<'GH'
#!/usr/bin/env bash
a="$*"
[ "$1" = auth ] && [ "$2" = status ] && exit 0
repo=$(printf '%s\n' "$a" | sed -n 's|.*repos/\([^/ ]*/[^/ ]*\)/.*|\1|p')
case "$a" in
  *"/releases/latest"*)
    hit=$(grep -E "^${repo}=" "$PINSTATE/rel" 2>/dev/null | head -1 | cut -d= -f2)
    if [ -n "$hit" ]; then printf '%s\n' "$hit"; exit 0; fi
    [ -n "${PINSTATE_DEFAULT:-}" ] && { printf 'v%s\n' "$PINSTATE_DEFAULT"; exit 0; }
    exit 1 ;;
esac
exit 1
GH
chmod +x "$W12/bin/curl" "$W12/bin/gh"
cat > "$W12/state/npm" <<'NPM'
stale-pkg=1.4.0
fresh-pkg=2.0.0
oxlint=2.0.0
NPM
cat > "$W12/state/rel" <<'REL'
owner/hookrepo=v1.3.0
owner/heldrepo=v2.0.0
owner/act=v3.4.1
owner/act2=v2.0.0
REL
cat > "$W12/root/pkgA/package.json" <<'JSON'
{"name":"a","devDependencies":{"stale-pkg":"^1.0.0","fresh-pkg":"^2.0.0","unreach-pkg":"^1.0.0"}}
JSON
cat > "$W12/root/pkgA/package-lock.json" <<'JSON'
{"lockfileVersion":3,"packages":{"":{},"node_modules/stale-pkg":{"version":"1.0.0"},"node_modules/fresh-pkg":{"version":"2.0.0"},"node_modules/unreach-pkg":{"version":"1.0.0"}}}
JSON
cat > "$W12/root/.pre-commit-config.yaml" <<'YML'
repos:
  - repo: https://github.com/owner/hookrepo
    rev: v1.0.0
    hooks:
      - id: x
  - repo: https://github.com/owner/heldrepo
    rev: v1.0.0
    hooks:
      - id: y
YML
cat > "$W12/root/.github/workflows/w.yml" <<'YML'
jobs:
  a:
    steps:
      - uses: owner/act@v3
      - uses: owner/act2@v1
      - run: python -m pip install --disable-pip-version-check pypi-stale==1.0.0 pypi-second==3.0.0 pypi-dev==1.2.3.dev1
      - run: python -m pip install pypi-fresh==2.0.0
YML
printf 'pypi-stale=1.2.0\npypi-fresh=2.0.0\npypi-second=3.0.0\n' > "$W12/state/pypi"
printf '#!/usr/bin/env bash\nOXLINT_VERSION=1.0.0\n' > "$W12/root/scripts/hooks/h.sh"
# A vendored upstream tree (VENDORED.md marker): its pins follow upstream, not npm-latest.
mkdir -p "$W12/root/vend"; printf 'vend-pkg=9.0.0\n' >> "$W12/state/npm"
printf '{"name":"v","devDependencies":{"vend-pkg":"^1.0.0"}}\n' > "$W12/root/vend/package.json"
printf '{"lockfileVersion":3,"packages":{"":{},"node_modules/vend-pkg":{"version":"1.0.0"}}}\n' > "$W12/root/vend/package-lock.json"
printf 'vendored from upstream\n' > "$W12/root/vend/VENDORED.md"
cat > "$W12/holds.json" <<'JSON'
{"holds":[{"eco":"gh","key":"owner/heldrepo","current":"v1.0.0","latest_reviewed":"v2.0.0","reason":"fixture hold"}]}
JSON
printf '{"plugins":[]}' > "$W12/empty_mjson.json"; printf '{}' > "$W12/empty_ups.json"
pin_run() {  # pin_run <holds-file> -> output in $pin_out, rc in $pin_rc
  pin_out="$(PINSTATE="$W12/state" PATH="$W12/bin:$PATH" DRIFT_PIN_ROOT="$W12/root" DRIFT_PIN_HOLDS="$1" \
    DRIFT_REGISTRY=/dev/null DRIFT_KNOWN_MARKETPLACES=/dev/null DRIFT_MJSON="$W12/empty_mjson.json" DRIFT_UPSTREAMS="$W12/empty_ups.json" \
    bash "$SCRIPT" 2>&1)"; pin_rc=$?
  pin_sec="$(printf '%s\n' "$pin_out" | sed -n '/pinned tools and packages/,$p')"
}
pin_run "$W12/holds.json"
if grepq "$pin_sec" 'pinned tools and packages'; then ok "pin-scan section present"; else bad "pin-scan section missing; $pin_out"; fi
if grepq "$pin_sec" '^  npm:stale-pkg 1\.0\.0 (pkgA): BEHIND'; then ok "pin-scan: stale npm pin -> BEHIND (lockfile version, not the range)"; else bad "stale-pkg not BEHIND; $(printf '%s' "$pin_sec" | grep stale-pkg)"; fi
if grepq "$pin_sec" '^  npm:fresh-pkg 2\.0\.0 (pkgA): CURRENT'; then ok "pin-scan: current npm pin -> CURRENT"; else bad "fresh-pkg not CURRENT"; fi
if grepq "$pin_sec" '^  npm:unreach-pkg .*UNCHECKED'; then ok "pin-scan: unreachable registry -> UNCHECKED (never CURRENT)"; else bad "unreach-pkg not UNCHECKED"; fi
if grepq "$pin_sec" '^  npm:oxlint 1\.0\.0 (scripts/hooks/h\.sh): BEHIND'; then ok "pin-scan: OXLINT_VERSION= literal watched -> BEHIND"; else bad "oxlint literal not BEHIND; $(printf '%s' "$pin_sec" | grep oxlint)"; fi
if grepq "$pin_sec" '^  gh:owner/hookrepo v1\.0\.0 (\.pre-commit-config\.yaml): BEHIND'; then ok "pin-scan: stale pre-commit rev -> BEHIND"; else bad "hookrepo not BEHIND"; fi
if grepq "$pin_sec" '^  gh:owner/heldrepo v1\.0\.0 .*: HELD'; then ok "pin-scan: recorded hold -> HELD, not drift"; else bad "heldrepo not HELD"; fi
if grepq "$pin_sec" 'owner/act'; then bad "pin-scan reported a workflow uses: pin; Dependabot owns those; $(printf '%s' "$pin_sec" | grep owner/act)"; else ok "pin-scan skips workflow uses: pins (Dependabot github-actions owns them)"; fi
if grepq "$pin_sec" '^  pypi:pypi-stale 1\.0\.0 (\.github/workflows/w\.yml): BEHIND'; then ok "pin-scan: stale workflow pip == pin -> BEHIND"; else bad "pypi-stale not BEHIND; $(printf '%s' "$pin_sec" | grep pypi-stale)"; fi
if grepq "$pin_sec" '^  pypi:pypi-fresh 2\.0\.0 .*: CURRENT'; then ok "pin-scan: current workflow pip == pin -> CURRENT"; else bad "pypi-fresh not CURRENT"; fi
if grepq "$pin_sec" '^  pypi:pypi-second 3\.0\.0 .*: CURRENT'; then ok "pin-scan: second == pin on one pip install line is also scanned"; else bad "pypi-second not discovered"; fi
if grepq "$pin_sec" 'pypi:pypi-dev'; then bad "a .dev version suffix was truncated and reported"; else ok "pin-scan: a pip pin with a version suffix is not misreported"; fi
if grepq "$pin_sec" '^  npm:vend-pkg 1\.0\.0 (vend): VENDORED'; then ok "pin-scan: pin inside a VENDORED.md tree -> VENDORED, not BEHIND npm-latest"; else bad "vend-pkg not VENDORED; $(printf '%s' "$pin_sec" | grep vend-pkg)"; fi
if [ "$pin_rc" -eq 2 ]; then ok "pin-scan drift run exits 2"; else bad "pin-scan drift run rc=$pin_rc; expected 2"; fi
# A vm-proof hold on a pin (HIMMEL-4583) names the route vm.mode resolves; none keeps it HELD.
printf '{"holds":[{"eco":"gh","key":"owner/heldrepo","current":"v1.0.0","latest_reviewed":"v2.0.0","release":"vm-proof","reason":"fixture vm hold"}]}\n' > "$W12/holds-vm.json"
printf '{"vm":{"mode":"none"}}\n' > "$W12/vm-none.json"
HIMMEL_VM_MODE_CONFIG="$W12/vm-none.json" pin_run "$W12/holds-vm.json"
l12="$(printf '%s\n' "$pin_sec" | grep 'owner/heldrepo')"
if grepq "$l12" -F ': HELD' && grepq "$l12" -F 'vm.mode=none' && grepq "$l12" -F 'never auto-released'; then ok "pin-scan: vm-proof hold under vm.mode=none stays HELD with the ack route"; else bad "pin-scan vm-proof none; $l12"; fi
printf '{"vm":\n' > "$W12/vm-err.json"
HIMMEL_VM_MODE_CONFIG="$W12/vm-err.json" pin_run "$W12/holds-vm.json"
l12="$(printf '%s\n' "$pin_sec" | grep 'owner/heldrepo')"
if grepq "$l12" -F ': HELD' && grepq "$l12" -F 'vm.mode config error' && ! grepq "$l12" -F 'operator ack'; then ok "pin-scan: vm-proof hold under a vm.mode config error stays HELD, fix config only"; else bad "pin-scan vm-proof error; $l12"; fi
printf '{"vm":{"mode":"remote","remote":{"ssh":"ops@vm.example"}}}\n' > "$W12/vm-remote.json"
HIMMEL_VM_MODE_CONFIG="$W12/vm-remote.json" pin_run "$W12/holds-vm.json"
l12="$(printf '%s\n' "$pin_sec" | grep 'owner/heldrepo')"
if grepq "$l12" -F ': HELD' && grepq "$l12" -F 'release: vm-proof via remote-vm ops@vm.example:22'; then ok "pin-scan: vm-proof hold under vm.mode=remote names the remote VM"; else bad "pin-scan vm-proof remote; $l12"; fi
# A hold expires when upstream ships something newer than the one reviewed.
printf 'owner/hookrepo=v1.3.0\nowner/heldrepo=v3.0.0\nowner/act=v3.4.1\nowner/act2=v2.0.0\n' > "$W12/state/rel"
pin_run "$W12/holds.json"
if grepq "$pin_sec" '^  gh:owner/heldrepo v1\.0\.0 .*: BEHIND'; then ok "pin-scan: hold expires once upstream moves past the reviewed release"; else bad "expired hold still HELD; $(printf '%s' "$pin_sec" | grep heldrepo)"; fi
# Coverage: every tracked package.json with dependency pins is discovered.
# Dependency-free packages have no pins and intentionally emit no scanner row.
cov_out="$(PINSTATE="$W12/state" PINSTATE_DEFAULT=0.0.0 PATH="$W12/bin:$PATH" python3 "$ROOT/scripts/upstreams/pin-scan.py" "$ROOT" "" 2>&1)"
cov_missing=""
while IFS= read -r pj; do
  has_pins="$(python3 -I -c 'import json,sys; p=json.load(open(sys.argv[1])); print("yes" if p.get("dependencies") or p.get("devDependencies") else "no")' "$ROOT/$pj")" || { bad "cannot read dependency pins: $pj"; continue; }
  [ "$has_pins" = no ] && continue
  d="$(dirname "$pj")"
  grepq "$cov_out" -F "$d" || cov_missing="$cov_missing $d"
done < <(git -C "$ROOT" ls-files '*package.json' | grep -v -e '^node_modules/' -e '/fixtures/')
if [ -z "$cov_missing" ]; then ok "pin-scan discovers every tracked package.json directory with dependency pins"; else bad "pin-scan missed:$cov_missing"; fi
if grepq "$cov_out" -F 'scripts/hooks/check-oxlint-complexity.sh' && grepq "$cov_out" -F 'scripts/hooks/check-oxlint-hardening.sh'; then ok "pin-scan discovers both oxlint hook pins"; else bad "oxlint hook pins not discovered"; fi
if grepq "$cov_out" -E '^  gh:gitleaks/gitleaks v[0-9.]+ \([^)]*\.github/workflows/ci\.yml[^)]*\.pre-commit-config\.yaml'; then ok "pin-scan reads the ci.yml gitleaks literal into the same row as the hook rev"; else bad "ci.yml gitleaks pin not discovered with the hook rev; $(printf '%s' "$cov_out" | grep gitleaks)"; fi
rm -rf "$W12" "$PIN_EMPTY"

# 13. Non-semver tag streams + git-subdir sources (HIMMEL-4012). Hermetic: a
#     stubbed gh serves tags/heads from a state dir; a fixture marketplace.json
#     and plugin-upstreams.json carry the shapes under test.
#     (a) an override with `tag_prefix` ("skill-v") compares only that stream's
#         tags — the engine-v* stream and bare semver tags must not win;
#     (b) a `git-subdir` source with a sha is read like a url source (HEAD
#         compare) instead of silently vanishing from the inventory.
W13="$(mktemp -d "${TMPDIR:-/tmp}/pdrift-stream.XXXXXX")" || { bad "tag_prefix/git-subdir fixture: mktemp -d failed"; exit 1; }; mkdir -p "$W13/bin" "$W13/state"
cat >"$W13/bin/gh" <<'GH'
#!/usr/bin/env bash
a="$*"
[ "$1" = auth ] && [ "$2" = status ] && exit 0
repo=$(printf '%s\n' "$a" | sed -n 's|.*repos/\([^/ ]*/[^/ ]*\)/.*|\1|p')
case "$a" in
  *"/compare/"*) printf '3\n'; exit 0 ;;
  *"/tags"*) grep -E "^${repo}=" "$GHSTATE/tags" 2>/dev/null | head -1 | cut -d= -f2- | tr ',' '\n'; exit 0 ;;
  *"commits/HEAD"*) grep -E "^${repo}=" "$GHSTATE/heads" 2>/dev/null | head -1 | cut -d= -f2; exit 0 ;;
esac
exit 0
GH
chmod +x "$W13/bin/gh"
SUB_SHA=aaaabbbbccccdddd000011112222333344445555
SUB_HEAD=ffffeeeeddddcccc999988887777666655554444
printf 'o/stream-cur=engine-v0.1.9,skill-v4.3.1,skill-v4.3.0,v9.9.9\no/stream-behind=engine-v0.1.9,skill-v4.4.0,skill-v4.3.1\no/stream-none=v1.0.0\n' >"$W13/state/tags"
printf 'o/sub-ok=%s\no/sub-behind=%s\n' "$SUB_SHA" "$SUB_HEAD" >"$W13/state/heads"
cat >"$W13/m.json" <<JSON
{"plugins":[
 {"name":"stream-cur","source":{"source":"url","url":"https://github.com/o/stream-cur.git","ref":"skill-v4.3.1"}},
 {"name":"stream-behind","source":{"source":"url","url":"https://github.com/o/stream-behind.git","ref":"skill-v4.3.1"}},
 {"name":"stream-none","source":{"source":"url","url":"https://github.com/o/stream-none.git","ref":"skill-v4.3.1"}},
 {"name":"sub-ok","source":{"source":"git-subdir","url":"https://github.com/o/sub-ok.git","path":"plugin","sha":"$SUB_SHA"}},
 {"name":"sub-behind","source":{"source":"git-subdir","url":"https://github.com/o/sub-behind.git","path":"plugin","sha":"$SUB_SHA"}}
]}
JSON
cat >"$W13/u.json" <<JSON
{
 "stream-cur":{"upstream_repo":"o/stream-cur","track":"release","synced_base":"skill-v4.3.1","tag_prefix":"skill-v"},
 "stream-behind":{"upstream_repo":"o/stream-behind","track":"release","synced_base":"skill-v4.3.1","tag_prefix":"skill-v"},
 "stream-none":{"upstream_repo":"o/stream-none","track":"release","synced_base":"skill-v4.3.1","tag_prefix":"skill-v"}
}
JSON
printf '{}' >"$W13/empty.json"
GHSTATE="$W13/state" PATH="$W13/bin:$PATH" DRIFT_MJSON="$W13/m.json" DRIFT_UPSTREAMS="$W13/u.json" \
  DRIFT_REGISTRY="$W13/empty.json" DRIFT_KNOWN_MARKETPLACES=/dev/null \
  bash "$SCRIPT" >"$W13/out.txt" 2>&1
out13="$(cat "$W13/out.txt")"
if grepq "$out13" '^  stream-cur: CURRENT'; then ok "tag_prefix: synced to the highest skill-v tag -> CURRENT (engine-v/bare v9.9.9 ignored)"; else bad "stream-cur not CURRENT; $(grep stream-cur "$W13/out.txt")"; fi
if grepq "$out13" '^  stream-behind: BEHIND'; then ok "tag_prefix: newer skill-v tag -> BEHIND"; else bad "stream-behind not BEHIND; $(grep stream-behind "$W13/out.txt")"; fi
if grepq "$out13" '^  stream-none: ? no stable version tags'; then ok "tag_prefix: no tag in the stream -> UNCHECKED, never a false CURRENT"; else bad "stream-none not UNCHECKED; $(grep stream-none "$W13/out.txt")"; fi
if grepq "$out13" '^  sub-ok: CURRENT'; then ok "git-subdir sha pin at HEAD -> CURRENT"; else bad "git-subdir sub-ok not CURRENT; $(grep sub-ok "$W13/out.txt")"; fi
if grepq "$out13" '^  sub-behind: BEHIND'; then ok "git-subdir sha pin behind HEAD -> BEHIND"; else bad "git-subdir source missing from the pinned-remote class; $(grep sub-behind "$W13/out.txt")"; fi
# HIMMEL-4019: standalone adoption targets must be checked even when absent
# from our marketplace. Reuse the same gh boundary and state fixture.
printf '{"plugins":[]}' >"$W13/m.json"
cat >"$W13/u.json" <<JSON
{
 "candidate-release-current":{"standalone":true,"upstream_repo":"o/stream-cur","track":"release","synced_base":"skill-v4.3.1","tag_prefix":"skill-v","ref":"$SUB_SHA"},
 "candidate-release-behind":{"standalone":true,"upstream_repo":"o/stream-behind","track":"release","synced_base":"skill-v4.3.1","tag_prefix":"skill-v","ref":"$SUB_SHA"},
 "candidate-head-current":{"standalone":true,"upstream_repo":"o/sub-ok","track":"head","ref":"$SUB_SHA"},
 "candidate-head-behind":{"standalone":true,"upstream_repo":"o/sub-behind","track":"head","ref":"$SUB_SHA"}
}
JSON
out14="$(GHSTATE="$W13/state" PATH="$W13/bin:$PATH" DRIFT_MJSON="$W13/m.json" DRIFT_UPSTREAMS="$W13/u.json" DRIFT_REGISTRY="$W13/empty.json" DRIFT_KNOWN_MARKETPLACES=/dev/null bash "$SCRIPT" 2>&1)"; rc14=$?
for verdict in 'candidate-release-current: CURRENT' 'candidate-release-behind: BEHIND' 'candidate-head-current: CURRENT' 'candidate-head-behind: BEHIND'; do
  if grepq "$out14" -F "$verdict"; then ok "standalone target: $verdict"; else bad "standalone target missing verdict: $verdict; $out14"; fi
done
if [ "$rc14" -eq 2 ]; then ok "standalone drift exits 2"; else bad "standalone drift rc=$rc14; expected 2"; fi
printf '{"bad":{"standalone":true,"upstream_repo":"o/sub-ok","track":"typo","ref":"%s"}}' "$SUB_SHA" >"$W13/u.json"
out14="$(GHSTATE="$W13/state" PATH="$W13/bin:$PATH" DRIFT_MJSON="$W13/m.json" DRIFT_UPSTREAMS="$W13/u.json" DRIFT_REGISTRY="$W13/empty.json" DRIFT_KNOWN_MARKETPLACES=/dev/null bash "$SCRIPT" 2>&1)"; rc14=$?
if [ "$rc14" -eq 3 ] && grepq "$out14" 'parse failed'; then ok "invalid standalone track is INCOMPLETE, never current"; else bad "invalid standalone target rc=$rc14; $out14"; fi
rm -rf "$W13"

# 15. Registry tag_prefix on a latest_source=release entry (HIMMEL-4258): bun
#     publishes `bun-v1.4.3`, which the bare-version release match rejected as
#     UNCHECKED. tag_prefix strips the stream prefix so synced_base stays a bare
#     version (what .bun-version holds) and the BEHIND line names a bare version
#     apply-drift-bump.sh can take as-is.
W15="$(mktemp -d "${TMPDIR:-/tmp}/pdrift-w15.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }; mkdir -p "$W15/bin"
cat > "$W15/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = auth ] && [ "$2" = status ] && exit 0
case "$*" in
  *"/releases/latest"*) printf 'bun-v1.4.3\n'; exit 0 ;;
esac
exit 0
GH
chmod +x "$W15/bin/gh"
printf '{"plugins":[]}' >"$W15/m.json"; printf '{}' >"$W15/u.json"
for base in 1.4.2 1.4.3; do
  cat > "$W15/reg.json" <<JSON
{"entries":[{"name":"bun-pin","kind":"tag_release","mode":"base","tracked_repo":"oven-sh/bun","synced_base":"$base","latest_source":"release","tag_prefix":"bun-v","tier":"A"}]}
JSON
  out15="$(PATH="$W15/bin:$PATH" DRIFT_REGISTRY="$W15/reg.json" DRIFT_KNOWN_MARKETPLACES=/dev/null DRIFT_MJSON="$W15/m.json" DRIFT_UPSTREAMS="$W15/u.json" bash "$SCRIPT" 2>&1)"
  line15="$(printf '%s' "$out15" | grep 'bun-pin')"
  if [ "$base" = 1.4.2 ]; then
    if grepq "$line15" 'BEHIND.*1\.4\.3'; then ok "release tag_prefix: bun-v1.4.3 vs 1.4.2 -> BEHIND naming the bare 1.4.3"; else bad "bun-pin not BEHIND; $line15"; fi
  else
    if grepq "$line15" 'CURRENT'; then ok "release tag_prefix: bun-v1.4.3 vs 1.4.3 -> CURRENT"; else bad "bun-pin not CURRENT; $line15"; fi
  fi
done
rm -rf "$W15"

echo ""
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
