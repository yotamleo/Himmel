#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-headed-arm-leg.sh
# scripts/handover/console-kit/test-go.sh - suite for go.sh (HIMMEL-2919), the
# console's GO-evidence writer that merge-on-green.sh's console-GO gate reads.
# test-merge-on-green.sh drives the reader end to end with GO files written by
# THIS script; this suite pins the writer's own contract:
#   1. usage: arg count, non-digit / leading-zero PR, sha not 40 lowercase hex -> exit 2.
#   2. write: path printed, file fields pr= / head= / by= / at= (ISO-8601 UTC).
#   3. by= falls back to <user>@<host> without CONSOLE_SESSION_NAME.
#   4. idempotent: a re-run overwrites in place, no temp file left behind.
#   5. HIMMEL_CONSOLE_LEG set -> exit 3, nothing written (a leg never writes its own GO;
#      this covers a --judge leg too - HIMMEL-3133, same marker, no separate one).
#   6. HIMMEL_CONSOLE_RELAY set -> exit 3, and its message names the console, never
#      a judge, as the writer (HIMMEL-3133 fixed pre-existing stale wording here).
#   7. unresolvable handover root -> exit 1.
#
# Platform guard (gitbash-only): POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/go.sh"
unset HIMMEL_CONSOLE_LEG CONSOLE_SESSION_NAME 2>/dev/null || true

tmp="$(mktemp -d "${TMPDIR:-/tmp}/go-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
# HIMMEL-3543: go.sh mints its GO key under $HOME/.config/himmel — keep it off
# the operator's real key.
export HOME="$tmp/home"; mkdir -p "$HOME"

# HIMMEL-3578: go.sh now resolves this repo's nwo via `gh repo view` to bind
# the GO mac. A gh stub on PATH keeps every call below hermetic (no real
# gh/network dependency); STUB_NWO controls what it returns.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
    "repo view")
        json=""
        while [ $# -gt 0 ]; do
            case "$1" in --json) json="$2" ;; esac
            shift
        done
        case "$json" in
            nameWithOwner)
                [ "${STUB_GH_REPO_VIEW_FAIL:-0}" = "1" ] && exit 1
                printf '%s' "${STUB_NWO:-o/r}" ;;
            *) exit 90 ;;
        esac ;;
    *) exit 91 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
export STUB_NWO="o/r"

fails=0
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { grepq "$2" -F -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }

SHA=0123456789abcdef0123456789abcdef01234567
ROOT="$tmp/root"; mkdir -p "$ROOT"
GO="$ROOT/.locks/go/77.$SHA"

# --- 1. usage --------------------------------------------------------------
for args in "" "77" "77 $SHA extra" "x1 $SHA" "077 $SHA" "77 ${SHA%?}" "77 ${SHA}0" \
            "77 0123456789ABCDEF0123456789abcdef01234567" "77 g123456789abcdef0123456789abcdef01234567"; do
  rc=0
  # shellcheck disable=SC2086  # word-splitting the args string IS the point
  HANDOVER_DIR="$ROOT" bash "$SCRIPT" $args >/dev/null 2>&1 || rc=$?
  check "usage: [$args] -> exit 2" "$rc" "2"
done
check "usage: nothing written" "$(ls -A "$ROOT")" ""

# --- 2. write ----------------------------------------------------------------
rc=0; out="$(HANDOVER_DIR="$ROOT" CONSOLE_SESSION_NAME=console-x bash "$SCRIPT" 77 "$SHA" 2>&1)" || rc=$?
check "write: exit 0" "$rc" "0"
check "write: prints the GO path" "$out" "$GO"
body="$(cat "$GO" 2>/dev/null || true)"
contains "write: pr= field" "$body" "pr=77"
contains "write: head= field" "$body" "head=$SHA"
contains "write: by= is the console session name" "$body" "by=console-x"
grepq "$body" -Ex 'at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' \
  && echo "ok - write: at= is ISO-8601 UTC" || { echo "FAIL - write: at= not ISO-8601 UTC: [$body]"; fails=$((fails+1)); }

# --- 3. by= fallback ---------------------------------------------------------
rc=0; HANDOVER_DIR="$ROOT" bash "$SCRIPT" 78 "$SHA" >/dev/null 2>&1 || rc=$?
check "fallback: exit 0" "$rc" "0"
grepq "$(cat "$ROOT/.locks/go/78.$SHA" 2>/dev/null)" -Ex 'by=[^@]+@.+' \
  && echo "ok - fallback: by=<user>@<host>" || { echo "FAIL - fallback: by= not <user>@<host>"; fails=$((fails+1)); }

# --- 4. idempotent rewrite ---------------------------------------------------
rc=0; HANDOVER_DIR="$ROOT" CONSOLE_SESSION_NAME=console-y bash "$SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$?
check "rewrite: exit 0" "$rc" "0"
contains "rewrite: overwritten in place" "$(cat "$GO" 2>/dev/null)" "by=console-y"
check "rewrite: one head= line, not appended" "$(grep -c '^head=' "$GO" 2>/dev/null)" "1"
leftover=0
for f in "$ROOT/.locks/go"/.go.*; do [ -e "$f" ] && leftover=$((leftover+1)); done
check "rewrite: no temp file left behind" "$leftover" "0"

# --- 5. a console-spawned leg cannot write its own GO ------------------------
LEGROOT="$tmp/legroot"; mkdir -p "$LEGROOT"
rc=0; out="$(HANDOVER_DIR="$LEGROOT" HIMMEL_CONSOLE_LEG=1 bash "$SCRIPT" 77 "$SHA" 2>&1)" || rc=$?
check "leg marker: exit 3" "$rc" "3"
contains "leg marker: names the reason" "$out" "console-spawned leg"
check "leg marker: nothing written" "$(ls -A "$LEGROOT")" ""
# HIMMEL-3543: a leg must not mint (or even create) the GO key either.
LEGHOME="$tmp/leghome"; mkdir -p "$LEGHOME"
rc=0; HOME="$LEGHOME" HANDOVER_DIR="$LEGROOT" HIMMEL_CONSOLE_LEG=1 bash "$SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$?
check "leg marker: exit 3 with a fresh HOME" "$rc" "3"
check "leg marker: no GO key minted" "$(find "$LEGHOME" -type f | wc -l | tr -d ' ')" "0"
rc=0; HANDOVER_DIR="$LEGROOT" HIMMEL_CONSOLE_LEG=0 bash "$SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$?
check "leg marker: a falsy marker is no marker" "$rc" "0"

# --- 6. HIMMEL_CONSOLE_RELAY refuses on its own (HIMMEL-2975), nothing written.
ROOT6="$(mktemp -d)" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
rc=0; out="$(env -u HIMMEL_CONSOLE_LEG HANDOVER_DIR="$ROOT6" HIMMEL_CONSOLE_RELAY=1 bash "$SCRIPT" 77 "$SHA" 2>&1)" || rc=$?
check    "relay: exit 3" "$rc" "3"
contains "relay: names the relay" "$out" "console relay"
check    "relay: no GO file written" "$(find "$ROOT6" -type f | wc -l | tr -d ' ')" "0"
rm -rf "$ROOT6"

# --- 7. HIMMEL-3133: "the judge is a leg" - no separate HIMMEL_CONSOLE_JUDGE
# marker exists, so nothing anywhere in go.sh's output should still claim
# "only the judge writes a GO" (stale pre-3133 wording: only the CONSOLE does,
# whether the caller is a plain leg, a --judge leg, or a relay).
if grepq "$out" -F -e "the judge writes"; then
  echo "FAIL - relay refusal still claims a judge writes the GO (pre-3133 wording)"
  fails=$((fails+1))
else
  echo "ok - relay refusal does not claim a judge writes the GO"
fi
contains "relay: correctly names the console as the GO writer" "$out" "only the console writes a GO"

# --- 8. unresolvable handover root -------------------------------------------
rc=0; HANDOVER_DIR="$tmp/absent" bash "$SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$?
check "no root: exit 1" "$rc" "1"

# --- 9. HIMMEL-3437: relative entry hands off to the $HIMMEL_REPO anchor -----
# The same mechanism scripts/cr/anchor-handoff.sh gives the scripts/cr/
# writers (HIMMEL-3395), generalized to reach this depth-3 entry too
# (HIMMEL-3437). Fixture trees carry the REAL generalized anchor-handoff.sh
# and must be real git repos (its root resolution is `git rev-parse
# --show-toplevel`). A marker go.sh keeps everything up to and including the
# real hand-off sourcing line verbatim, then `echo "RAN:<label>"` — a passing
# case proves the ACTUAL shipped sourcing line triggers the hand-off, not a
# hand-rolled substitute (all cases above invoke go.sh by ABSOLUTE path, so
# none of them exercises the relative door — this is the first).
# shellcheck disable=SC2016  # the literal line go.sh carries, not an expansion
GO_ENTRY_SOURCE_LINE='. "$(dirname "${BASH_SOURCE[0]}")/../../cr/anchor-handoff.sh" || exit 2'
mk_go_entry_tree() {  # <root> <label>
  mkdir -p "$1/scripts/handover/console-kit" "$1/scripts/cr"
  git init -q "$1"
  cp "$HERE/../../cr/anchor-handoff.sh" "$1/scripts/cr/anchor-handoff.sh"
  awk -v src="$GO_ENTRY_SOURCE_LINE" '{ print } $0 == src { exit }' "$SCRIPT" > "$1/head.tmp"
  if ! grep -qxF "$GO_ENTRY_SOURCE_LINE" "$1/head.tmp"; then
    echo "FAIL - 3437 setup: go.sh no longer carries the expected hand-off sourcing line verbatim, control proves nothing" >&2
    fails=$((fails+1))
  fi
  printf '%s\necho "RAN:%s"\n' "$(cat "$1/head.tmp")" "$2" > "$1/scripts/handover/console-kit/go.sh"
  rm -f "$1/head.tmp"
}
G3437_WT="$tmp/g3437-wt"; G3437_ANCHOR="$tmp/g3437-anchor"
mk_go_entry_tree "$G3437_WT" branch
mk_go_entry_tree "$G3437_ANCHOR" anchor

out=$(cd "$G3437_WT" && env -u CR_ANCHOR_HANDED_OFF HIMMEL_REPO="$G3437_ANCHOR" bash scripts/handover/console-kit/go.sh 2>/dev/null)
check "3437: relative entry hands off" "$out" "RAN:anchor"

out=$(cd "$G3437_WT" && env -u CR_ANCHOR_HANDED_OFF HIMMEL_REPO="$G3437_ANCHOR" bash "$G3437_WT/scripts/handover/console-kit/go.sh" 2>/dev/null)
check "3437: absolute entry runs local" "$out" "RAN:branch"

rc=0; (cd "$G3437_WT" && env -u CR_ANCHOR_HANDED_OFF -u HIMMEL_REPO bash scripts/handover/console-kit/go.sh >/dev/null 2>&1) || rc=$?
check "3437: unset HIMMEL_REPO exits 2" "$rc" "2"

# --- 10. HIMMEL-3572 row 1: go.sh writes where merge-on-green reads ---------
# A console whose env has no HANDOVER_DIR (or has the harness repo's own
# handovers/ stub) used to get rc=0 and a GO under <repo>/handovers, while the
# gate reads the root the repo's .env configures. Fixture: a git tree carrying
# go.sh + scripts/lib + anchor-handoff.sh, a handovers/ stub, and a .env
# naming a real root outside it. go.sh runs by ABSOLUTE path (no hand-off).
S10="$tmp/s10"; S10_REAL="$tmp/s10-real"
mkdir -p "$S10/scripts/handover/console-kit" "$S10/scripts/cr" "$S10/handovers" "$S10_REAL"
git init -q "$S10"
cp "$SCRIPT" "$S10/scripts/handover/console-kit/go.sh"
cp -R "$HERE/../../lib" "$S10/scripts/lib"
cp "$HERE/../../cr/anchor-handoff.sh" "$S10/scripts/cr/anchor-handoff.sh"
printf 'HANDOVER_DIR=%s\n' "$S10_REAL" > "$S10/.env"
S10_GO=".locks/go/77.$SHA"

# 10a. HANDOVER_DIR unset: the GO lands in the configured root, not the stub.
rc=0; out=$(cd "$S10" && env -u HANDOVER_DIR -u HIMMEL_REPO bash "$S10/scripts/handover/console-kit/go.sh" 77 "$SHA" 2>&1) || rc=$?
check "3572: unset HANDOVER_DIR -> exit 0" "$rc" "0"
check "3572: unset HANDOVER_DIR -> nothing under the repo stub" "$(find "$S10/handovers" -type f | wc -l | tr -d ' ')" "0"
check "3572: unset HANDOVER_DIR -> GO in the .env-configured root" "$([ -f "$S10_REAL/$S10_GO" ] && echo yes)" "yes"
rm -f "$S10_REAL/$S10_GO"

# 10b. HANDOVER_DIR = the repo stub itself: same answer, the stub is skipped.
rc=0; (cd "$S10" && env -u HIMMEL_REPO HANDOVER_DIR="$S10/handovers" bash "$S10/scripts/handover/console-kit/go.sh" 77 "$SHA" >/dev/null 2>&1) || rc=$?
check "3572: HANDOVER_DIR=stub -> exit 0" "$rc" "0"
check "3572: HANDOVER_DIR=stub -> nothing under the repo stub" "$(find "$S10/handovers" -type f | wc -l | tr -d ' ')" "0"
check "3572: HANDOVER_DIR=stub -> GO in the .env-configured root" "$([ -f "$S10_REAL/$S10_GO" ] && echo yes)" "yes"

# 10c. The configured root is gone: refuse non-zero rather than fall back to
# the stub the gate never reads.
printf 'HANDOVER_DIR=%s\n' "$tmp/s10-missing" > "$S10/.env"
rc=0; out=$(cd "$S10" && env -u HANDOVER_DIR -u HIMMEL_REPO bash "$S10/scripts/handover/console-kit/go.sh" 77 "$SHA" 2>&1) || rc=$?
[ "$rc" -ne 0 ] && echo "ok - 3572: configured root missing -> non-zero ($rc)" || { echo "FAIL - 3572: configured root missing -> rc=0 (GO written where the gate cannot see it)"; fails=$((fails+1)); }
check "3572: configured root missing -> nothing under the repo stub" "$(find "$S10/handovers" -type f | wc -l | tr -d ' ')" "0"

# --- 11. HIMMEL-3578: nwo unresolvable -> refuse, no GO written -------------
# The mac binds the repo; a `gh repo view` failure must never fall back to
# writing an unbound GO.
ROOT11="$tmp/root11"; mkdir -p "$ROOT11"
rc=0; out="$(STUB_GH_REPO_VIEW_FAIL=1 HANDOVER_DIR="$ROOT11" bash "$SCRIPT" 79 "$SHA" 2>&1)" || rc=$?
check "3578: gh repo view fails -> exit 1" "$rc" "1"
contains "3578: names the cause" "$out" "gh repo view"
check "3578: nothing written" "$(find "$ROOT11" -type f | wc -l | tr -d ' ')" "0"

# --- 12. HIMMEL-3578: the mac binds the resolved nwo ------------------------
ROOT12="$tmp/root12"; mkdir -p "$ROOT12"
rc=0; STUB_NWO="a/b" HANDOVER_DIR="$ROOT12" bash "$SCRIPT" 80 "$SHA" >/dev/null 2>&1 || rc=$?
check "3578: write with nwo=a/b -> exit 0" "$rc" "0"
GO12="$ROOT12/.locks/go/80.$SHA"
MAC_AB=$(sed -n 's/^mac=//p' "$GO12" 2>/dev/null)
ROOT12B="$tmp/root12b"; mkdir -p "$ROOT12B"
rc=0; STUB_NWO="c/d" HANDOVER_DIR="$ROOT12B" bash "$SCRIPT" 80 "$SHA" >/dev/null 2>&1 || rc=$?
check "3578: write with nwo=c/d -> exit 0" "$rc" "0"
MAC_CD=$(sed -n 's/^mac=//p' "$ROOT12B/.locks/go/80.$SHA" 2>/dev/null)
[ -n "$MAC_AB" ] && [ -n "$MAC_CD" ] && [ "$MAC_AB" != "$MAC_CD" ] \
  && echo "ok - 3578: different nwo -> different mac for the same pr/sha" \
  || { echo "FAIL - 3578: mac [$MAC_AB] does not vary with nwo (got [$MAC_CD] for c/d)"; fails=$((fails+1)); }

echo "---"
if [ "$fails" -eq 0 ]; then
  echo "PASS - test-go.sh"
  exit 0
else
  echo "FAIL - test-go.sh ($fails failure(s))"
  exit 1
fi
