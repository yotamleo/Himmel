#!/usr/bin/env bash
# Smoke test for scripts/check-plugin-drift.sh (HIMMEL-322).
# Structural checks (no network needed) + one end-to-end run (uses network iff
# gh is available; the script itself fail-opens when it isn't).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/check-plugin-drift.sh"
MJSON="$ROOT/marketplace/.claude-plugin/marketplace.json"
fails=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

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
    if isinstance(s, dict) and s.get("source") in ("github", "url") and s.get("ref"):
        print(p["name"])
PY
)"
if echo "$pins" | grep -qx "claude-obsidian"; then ok "parser finds claude-obsidian pin"; else bad "parser missing claude-obsidian"; fi
if echo "$pins" | grep -qx "obsidian"; then bad "obsidian pin still present — should have been dropped (HIMMEL-435)"; else ok "obsidian (kepano) pin absent — dropped as expected"; fi

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
    if isinstance(s, dict) and s.get("source") in ("github", "url") and s.get("ref"):
        o = ups.get(p["name"]) or {}
        print("|".join([p["name"], repo_of(s), s["ref"],
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
pick() { printf '%s\n' "$1" | grep -E "$TAG_RE" | sort -V | tail -1; }
if [ "$(pick "$(printf 'v1.9.1\nv1.9.2\nv1.9.2-alpha\nv1.8.1\n')")" = "v1.9.2" ]; then ok "stable-tag select: prerelease of current version ignored"; else bad "prerelease leaked into latest"; fi
if [ "$(pick "$(printf 'v1.9.2\nv1.9.3\n')")" = "v1.9.3" ]; then ok "stable-tag select: newer stable wins"; else bad "newer stable not selected"; fi
if [ -z "$(pick "$(printf 'v1.9.2-alpha\nv1.9.3-rc1\n')")" ]; then ok "stable-tag select: all-prerelease -> empty (drives the UNCHECKED path)"; else bad "all-prerelease should select nothing, got '$(pick "$(printf 'v1.9.2-alpha\nv1.9.3-rc1\n')")'"; fi

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
if ! printf '%s' "$out" | grep -q "fail-open"; then
  if printf '%s' "$out" | grep -q "pinned remotes"; then ok "output has pinned-remotes section"; else bad "no pinned-remotes section"; fi
  if printf '%s' "$out" | grep -q "vendored forks"; then ok "output has vendored-forks section"; else bad "no vendored-forks section"; fi
  if printf '%s' "$out" | grep "claude-obsidian" | grep -q "AgriciDaniel/claude-obsidian"; then
    ok "claude-obsidian drift tracks true upstream (AgriciDaniel), not the fork"
  else
    bad "claude-obsidian line does not reference true upstream AgriciDaniel; output: $(printf '%s' "$out" | grep claude-obsidian)"
  fi
else
  ok "gh unavailable — fail-open path taken (sections skipped, expected)"
fi

# 5. Fail-open path, deterministically (hide gh from PATH). The script's headline
#    safety property: gh absent -> exit 0 + skip, so CI / fresh clones never break.
fo_out="$(PATH=/usr/bin:/bin bash "$SCRIPT" 2>&1)"; fo_rc=$?
if [ "$fo_rc" -eq 0 ] && printf '%s' "$fo_out" | grep -q "fail-open"; then
  ok "fail-open: gh absent -> exit 0 + skip message"
else
  bad "fail-open broken: rc=$fo_rc out=$fo_out"
fi

# 6. Override-branch UNCHECKED paths via fixtures (DRIFT_MJSON/DRIFT_UPSTREAMS).
#    Both checks fire BEFORE any gh call, but the script's top-level fail-open gate
#    means the pin loop only runs when gh is present — so gate this on the real run
#    not having taken the fail-open path.
if ! printf '%s' "$out" | grep -q "fail-open"; then
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
  if printf '%s' "$fx_out" | grep "fix-missing-base" | grep -q "missing synced_base"; then ok "missing synced_base -> UNCHECKED (not a phantom BEHIND)"; else bad "missing synced_base not UNCHECKED; out: $(printf '%s' "$fx_out" | grep fix-missing-base)"; fi
  if printf '%s' "$fx_out" | grep "fix-bad-track" | grep -q "unknown track"; then ok "unknown track -> UNCHECKED"; else bad "bad track not UNCHECKED; out: $(printf '%s' "$fx_out" | grep fix-bad-track)"; fi
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
cat >"$W7/state/heads" <<HEADS
owner/pin-full=aaaabbbbccccdddd000011112222333344445555
owner/pin-short=1111222233334444555566667777888899990000
owner/checkout-repo=${CK1_HEAD}
owner/mkt-fixt=${CK2_HEAD}
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
TAGS
MISSING="$W7/does_not_exist_dir"
cat >"$W7/upstreams.json" <<JSON
{"entries":[
 {"name":"pin-full","kind":"commit_head","mode":"pin","tracked_repo":"owner/pin-full","pinned_commit":"aaaabbbbccccdddd000011112222333344445555","tier":"A"},
 {"name":"pin-short","kind":"commit_head","mode":"pin","tracked_repo":"owner/pin-short","pinned_commit":"Short0a","tier":"A"},
 {"name":"checkout-ok","kind":"commit_head","mode":"checkout","tracked_repo":"owner/checkout-repo","checkout_path":"$CK1","tier":"B"},
 {"name":"checkout-missing","kind":"commit_head","mode":"checkout","tracked_repo":"owner/x","checkout_path":"$MISSING","tier":"B"},
 {"name":"base-cur","kind":"tag_release","mode":"base","tracked_repo":"owner/base-cur","synced_base":"v1.2.3","tier":"A"},
 {"name":"base-behind","kind":"tag_release","mode":"base","tracked_repo":"owner/base-behind","synced_base":"v1.0.0","tier":"A"},
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
GHSTATE="$W7/state" PATH="$W7/bin:$PATH" \
  DRIFT_REGISTRY="$W7/upstreams.json" DRIFT_KNOWN_MARKETPLACES="$W7/km.json" \
  DRIFT_MJSON="$empty_mjson" DRIFT_UPSTREAMS="$W7/empty_ups.json" \
  bash "$SCRIPT" >"$W7/out.txt" 2>&1; rc7=$?
sec7="$(sed -n '/carried upstreams/,$p' "$W7/out.txt")"
# 7a. commit_head paths.
if printf '%s' "$sec7" | grep -q '^  pin-full: CURRENT'; then ok "commit_head pin full-SHA -> CURRENT"; else bad "commit_head pin-full not CURRENT; $(printf '%s' "$sec7" | grep pin-full)"; fi
if printf '%s' "$sec7" | grep -q '^  pin-short: BEHIND'; then ok "commit_head pin short-SHA resolved -> BEHIND"; else bad "commit_head pin-short not BEHIND; $(printf '%s' "$sec7" | grep pin-short)"; fi
if printf '%s' "$sec7" | grep -q '^  checkout-ok: CURRENT'; then ok "commit_head checkout present -> CURRENT"; else bad "checkout-ok not CURRENT; $(printf '%s' "$sec7" | grep checkout-ok)"; fi
if printf '%s' "$sec7" | grep 'checkout-missing' | grep -q 'UNCHECKED'; then ok "commit_head checkout absent -> UNCHECKED"; else bad "checkout-missing not UNCHECKED"; fi
if printf '%s' "$sec7" | grep 'weird-mode' | grep -q "mode 'bogus' unknown"; then ok "commit_head unknown mode -> UNCHECKED"; else bad "weird-mode not flagged"; fi
# 7b. tag_release paths.
if printf '%s' "$sec7" | grep -q '^  base-cur: CURRENT'; then ok "tag_release base synced -> CURRENT"; else bad "base-cur not CURRENT"; fi
if printf '%s' "$sec7" | grep -q '^  base-behind: BEHIND'; then ok "tag_release base stale -> BEHIND"; else bad "base-behind not BEHIND"; fi
if printf '%s' "$sec7" | grep -q '^  probe-cur: CURRENT'; then ok "tag_release probe synced -> CURRENT"; else bad "probe-cur not CURRENT"; fi
if printf '%s' "$sec7" | grep -q '^  probe-behind: BEHIND'; then ok "tag_release probe stale -> BEHIND"; else bad "probe-behind not BEHIND"; fi
if printf '%s' "$sec7" | grep 'probe-ahead' | grep -q 'CURRENT'; then ok "tag_release probe installed-ahead -> CURRENT (not a phantom BEHIND)"; else bad "probe-ahead not CURRENT; $(printf '%s' "$sec7" | grep probe-ahead)"; fi
# 7b-extra (HIMMEL-869 CR fix): a version_regex containing a literal '|'
# (regex alternation) must round-trip through the emitter/consumer protocol
# intact. Under a pipe-delimited protocol this record's own fields would
# misalign (v2/version_regex truncates at the first '|', the remainder spills
# into tier) — assert the verdict line is well-formed: CURRENT, with tier
# exactly "[A]" and no leaked regex remainder.
if printf '%s' "$sec7" | grep '^  probe-pipe-regex: CURRENT' | grep -q '\[A\]$'; then
  ok "tag_release probe: version_regex containing '|' parses into correct fields (well-formed CURRENT line, tier intact)"
else
  bad "probe-pipe-regex line malformed (delimiter/field misalignment?); $(printf '%s' "$sec7" | grep probe-pipe-regex)"
fi
if printf '%s' "$sec7" | grep 'probe-pipe-regex' | grep -q 'nomatchxyz'; then
  bad "probe-pipe-regex line leaked regex remainder into tier/verdict — field misalignment"
else
  ok "probe-pipe-regex line does not leak regex remainder (fields correctly delimited)"
fi
# 7c. marketplace discovery.
if printf '%s' "$sec7" | grep -q '^  mkt:fixt-mkt: CURRENT'; then ok "marketplace github-sourced checkout -> CURRENT"; else bad "mkt:fixt-mkt not CURRENT; $(printf '%s' "$sec7" | grep 'mkt:')"; fi
if printf '%s' "$sec7" | grep -q 'mkt:dir-src'; then bad "directory-sourced marketplace should be skipped (not checked)"; else ok "directory-sourced marketplace correctly skipped"; fi
# 7d. unknown kind + exit code (drift from pin-short/base-behind/probe-behind => 2).
if printf '%s' "$sec7" | grep 'weird-kind' | grep -q "unknown kind 'bogus'"; then ok "unknown kind -> UNCHECKED"; else bad "weird-kind not flagged"; fi
if [ "$rc7" -eq 2 ]; then ok "carried-upstreams drift run exits 2 (drift, precedence over incomplete)"; else bad "carried-upstreams drift run rc=$rc7; expected 2"; fi
# 7e. malformed registry -> class UNCHECKED (never a false all-clear).
printf '{not valid json' >"$W7/bad.json"
bad_out="$(GHSTATE="$W7/state" PATH="$W7/bin:$PATH" DRIFT_REGISTRY="$W7/bad.json" DRIFT_KNOWN_MARKETPLACES=/dev/null DRIFT_MJSON="$empty_mjson" DRIFT_UPSTREAMS="$W7/empty_ups.json" bash "$SCRIPT" 2>&1)"; bad_rc=$?
if printf '%s' "$bad_out" | grep -q 'carried-upstreams class UNCHECKED'; then ok "malformed registry -> class UNCHECKED"; else bad "malformed registry not UNCHECKED; $bad_out"; fi
if [ "$bad_rc" -eq 3 ]; then ok "malformed registry run exits 3 (incomplete, not a false 0)"; else bad "malformed registry rc=$bad_rc; expected 3"; fi
# 7f. empty/missing registry -> no entries (clean, not UNCHECKED). (Overall exit
#     code is not asserted: the vendored-forks section still globs the REAL
#     UPSTREAM_PINs and reads UNCHECKED under the stub, which is orthogonal to
#     the empty-registry property under test — that the carried-upstreams section
#     emits no spurious entries.)
empty_out="$(GHSTATE="$W7/state" PATH="$W7/bin:$PATH" DRIFT_REGISTRY=/dev/null DRIFT_KNOWN_MARKETPLACES=/dev/null DRIFT_MJSON="$empty_mjson" DRIFT_UPSTREAMS="$W7/empty_ups.json" bash "$SCRIPT" 2>&1)"
if printf '%s' "$empty_out" | grep -q 'carried upstreams' && ! printf '%s' "$empty_out" | sed -n '/carried upstreams/,$p' | grep -Eq '^  [a-z].*: (CURRENT|BEHIND|UNCHECKED|unknown)'; then
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
  ln -s "$f" "$W8/notimeout/$b" 2>/dev/null
done
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
if printf '%s' "$w8_out" | grep -q "watchdog fallback"; then ok "hanging probe: fallback-watchdog note emitted"; else bad "hanging probe: no fallback-watchdog note; out: $w8_out"; fi
if printf '%s' "$w8_out" | grep 'hang-tool' | grep -q 'probe timed out'; then ok "hanging probe: entry reads 'probe timed out' UNCHECKED"; else bad "hanging probe: no timeout note; $(printf '%s' "$w8_out" | grep hang-tool)"; fi
if printf '%s' "$w8_out" | grep -qE '^  hang-tool: (CURRENT|BEHIND)'; then bad "hanging probe: entry read CURRENT/BEHIND instead of UNCHECKED"; else ok "hanging probe: entry never read CURRENT/BEHIND"; fi
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
if printf '%s' "$w9_out" | grep 'mkt:no-install-loc-marketplace' | grep -q 'lacks installLocation'; then
  ok "marketplace entry without installLocation -> named per-entry UNCHECKED skip"
else
  bad "missing-installLocation marketplace entry not flagged; $(printf '%s' "$w9_out" | grep 'no-install-loc-marketplace')"
fi
if printf '%s' "$w9_out" | grep 'mkt:no-install-loc-marketplace' | grep -q 'checkout not present'; then
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
if printf '%s' "$w10_out" | grep 'timedprobe-tool' | grep -q 'probe timed out (10s)'; then ok "timeout-path hanging probe: entry reads 'probe timed out (10s)' UNCHECKED"; else bad "timeout-path hanging probe: no timeout note; $(printf '%s' "$w10_out" | grep timedprobe-tool)"; fi
if printf '%s' "$w10_out" | grep -qE '^  timedprobe-tool: (CURRENT|BEHIND)'; then bad "timeout-path hanging probe: entry read CURRENT/BEHIND instead of UNCHECKED (partial pre-hang output was parsed)"; else ok "timeout-path hanging probe: entry never read CURRENT/BEHIND"; fi
if [ "$w10_rc" -eq 3 ]; then ok "timeout-path hanging probe run exits 3 (incomplete)"; else bad "timeout-path hanging probe run rc=$w10_rc; expected 3"; fi
rm -rf "$W10"

echo ""
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
