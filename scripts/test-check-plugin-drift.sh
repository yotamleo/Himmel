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

# 2. The marketplace.json parser yields the SHA-pinned remotes (>=1; expect
#    claude-obsidian + obsidian). Mirrors the script's own parser.
pins="$(python3 - "$MJSON" <<'PY' | tr -d '\r'
import json, sys
m = json.load(open(sys.argv[1]))
for p in m.get("plugins", []):
    s = p.get("source")
    if isinstance(s, dict) and s.get("source") == "github" and s.get("ref"):
        print(p["name"])
PY
)"
if echo "$pins" | grep -qx "claude-obsidian"; then ok "parser finds claude-obsidian pin"; else bad "parser missing claude-obsidian"; fi
if echo "$pins" | grep -qx "obsidian"; then ok "parser finds obsidian (kepano) pin"; else bad "parser missing obsidian"; fi

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
for p in m.get("plugins", []):
    s = p.get("source")
    if isinstance(s, dict) and s.get("source") == "github" and s.get("ref"):
        o = ups.get(p["name"]) or {}
        print("|".join([p["name"], s["repo"], s["ref"],
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
  fx_out="$(DRIFT_MJSON="$fix_m" DRIFT_UPSTREAMS="$fix_u" bash "$SCRIPT" 2>&1)"; fx_rc=$?
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

echo ""
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
