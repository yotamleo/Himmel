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
#   13. --trust-reviewed <id> (HIMMEL-3895): id validated, signed into the mac.
#
# Platform guard (gitbash-only): POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/go.sh"
unset HIMMEL_CONSOLE_LEG CONSOLE_SESSION_NAME 2>/dev/null || true

tmp="$(mktemp -d "${TMPDIR:-/tmp}/go-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
# Sections 14-15 run after section 13 sources go-gate.sh, which assigns its
# own `tmp`; name their dirs here so nothing below reads `$tmp` past that point.
ROOT14="$tmp/root14"; ROOT15="$tmp/root15"; ROOT16="$tmp/root16"; ROOT18="$tmp/root18"
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

# HIMMEL-4565: go.sh runs ready-check.sh itself, so every write below runs from
# a repo whose CR ledger has an ok row for the head, with a gh that answers
# ready-check's queries green (testlib-ready-pass.sh). Section 14 breaks each.
# shellcheck source=scripts/handover/console-kit/testlib-ready-pass.sh
# shellcheck disable=SC1091
. "$HERE/testlib-ready-pass.sh"
ready_pass_bin "$tmp/ready-bin"
export PATH="$tmp/ready-bin:$PATH"
READY_REPO="$tmp/ready-repo"
git init -q "$READY_REPO"
cd "$READY_REPO" || { echo "FAIL: cd $READY_REPO" >&2; exit 1; }

fails=0
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { grepq "$2" -F -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }

# verdict <root> <qid> <verdict line> [<file name>] - a judge's verdict file,
# as docs/handover/verdict-template.md lays it out.
verdict() {
  local vf="$1/$VSCOPE/verdicts/$2/${4:-HIMMEL-1-judge-$2}.md" vmac
  mkdir -p "$1/$VSCOPE/verdicts/$2"
  printf '# VERDICT %s - judge\n\n## Reason (scope asked)\n\nq\n\n## Verdict\n\n%s\n\npr: %s\n\nreason\n\n## Evidence checked\n\ne\n%s' \
    "$2" "$3" "${VPR:-83}" "${VEXTRA:-}" > "$vf"
  # HIMMEL-4984: a record counts only with write-verdict.sh's mac (VSIGN=0 models a hand-written one).
  [ "${VSIGN:-1}" = 1 ] || return 0
  vsign "$2" "$vf"
}
# vsign <qid> <file> - append write-verdict.sh's mac line to a hand-built record.
vsign() {
  local vmac
  mkdir -p "$HOME/.config/himmel"
  [ -s "$HOME/.config/himmel/go-hmac.key" ] || printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$HOME/.config/himmel/go-hmac.key"
  vmac="$(cat "$2" | bash -c '. "$1"; go_verdict_mac "$2" "$3" "$4"' _ "$HERE/../../lib/go-gate.sh" "$VSCOPE" "$1" "$(basename "$2" .md)")" || { echo "FAIL: cannot sign $2" >&2; return 1; }
  printf 'mac: %s\n' "$vmac" >> "$2"
}

# HIMMEL-4589: a trust verdict counts only under <user>/<bucket>, the user slug
# and the primary checkout's slugified basename (never a hardcoded bucket).
export USER_SLUG=u
VBUCKET="$(basename "$(dirname "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)")" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
VSCOPE="u/$VBUCKET"

SHA=0123456789abcdef0123456789abcdef01234567
export READY_STUB_HEAD="$SHA"
ready_pass_ledger "$READY_REPO" "$SHA"
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
# HIMMEL_CONSOLE_LEG is a Claude Code marker (any value): from an anchor checkout
# with no claude ancestor (CI) and HANDOVER_DIR set, go.sh refuses 96
# (HIMMEL-3914 I3). A leg always runs under its claude session, so these rows
# run under a fake one.
_as_claude() { (exec -a claude bash -c '"$@"; exit $?' _ "$@"); }
rc=0; out="$(HANDOVER_DIR="$LEGROOT" HIMMEL_CONSOLE_LEG=1 _as_claude bash "$SCRIPT" 77 "$SHA" 2>&1)" || rc=$?
check "leg marker: exit 3" "$rc" "3"
contains "leg marker: names the reason" "$out" "console-spawned leg"
check "leg marker: nothing written" "$(ls -A "$LEGROOT")" ""
# HIMMEL-3543: a leg must not mint (or even create) the GO key either.
LEGHOME="$tmp/leghome"; mkdir -p "$LEGHOME"
rc=0; HOME="$LEGHOME" HANDOVER_DIR="$LEGROOT" HIMMEL_CONSOLE_LEG=1 _as_claude bash "$SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$?
check "leg marker: exit 3 with a fresh HOME" "$rc" "3"
check "leg marker: no GO key minted" "$(find "$LEGHOME" -type f | wc -l | tr -d ' ')" "0"
rc=0; HANDOVER_DIR="$LEGROOT" HIMMEL_CONSOLE_LEG=0 _as_claude bash "$SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$?
check "leg marker: a falsy marker is no marker" "$rc" "0"

# --- 6. HIMMEL_CONSOLE_RELAY refuses on its own (HIMMEL-2975), nothing written.
ROOT6="$(mktemp -d)" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
rc=0; out="$(env -u HIMMEL_CONSOLE_LEG HANDOVER_DIR="$ROOT6" HIMMEL_CONSOLE_RELAY=1 bash "$SCRIPT" 77 "$SHA" 2>&1)" || rc=$?
check    "relay: exit 3" "$rc" "3"
contains "relay: names the relay" "$out" "console relay"
check    "relay: no GO file written" "$(find "$ROOT6" -type f | wc -l | tr -d ' ')" "0"
rm -rf "$ROOT6"

# --- 7. HIMMEL-3133: "the judge is a leg" - go.sh's own gate is the leg
# marker (HIMMEL_CONSOLE_JUDGE, HIMMEL-4564, only feeds guard-judge-writes.sh),
# so nothing anywhere in go.sh's output should still claim
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
GO_ENTRY_SOURCE_LINE='. "$_ah_d/../../cr/anchor-handoff.sh" || exit 2'
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
cp "$HERE/ready-check.sh" "$S10/scripts/handover/console-kit/ready-check.sh"
ready_pass_ledger "$S10" "$SHA"
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

# --- 13. HIMMEL-3895: --trust-reviewed signs the reviewer id -----------------
ROOT13="$tmp/root13"; mkdir -p "$ROOT13"
GO13="$ROOT13/.locks/go/81.$SHA"
for bad in "" "a b" "x;y" "id|z" "$(printf '%0129d' 0)"; do
  rc=0; HANDOVER_DIR="$ROOT13" bash "$SCRIPT" --trust-reviewed "$bad" 81 "$SHA" >/dev/null 2>&1 || rc=$?
  check "3895: --trust-reviewed [$bad] -> exit 2" "$rc" "2"
done
rc=0; HANDOVER_DIR="$ROOT13" bash "$SCRIPT" --trust-reviewed judge-N9 >/dev/null 2>&1 || rc=$?
check "3895: --trust-reviewed with no pr/sha -> exit 2" "$rc" "2"
check "3895: nothing written on usage errors" "$(find "$ROOT13" -type f | wc -l | tr -d ' ')" "0"
rc=0; HANDOVER_DIR="$ROOT13" bash "$SCRIPT" 81 "$SHA" >/dev/null 2>&1 || rc=$?
MAC_PLAIN=$(sed -n 's/^mac=//p' "$GO13" 2>/dev/null)
check "3895: an ordinary GO has no trust line" "$(grep -c '^trust-reviewed=' "$GO13" 2>/dev/null)" "0"
# HIMMEL-3832: a trust-reviewed GO needs the judge's GO verdict for this head.
VPR=81
verdict "$ROOT13" judge-N9 "**GO** for head \`$SHA\`."
verdict "$ROOT13" judge-N8 "**GO** for head \`$SHA\`."
rc=0; HANDOVER_DIR="$ROOT13" bash "$SCRIPT" --trust-reviewed judge-N9 81 "$SHA" >/dev/null 2>&1 || rc=$?
check "3895: --trust-reviewed judge-N9 -> exit 0" "$rc" "0"
contains "3895: trust-reviewed= line written" "$(cat "$GO13" 2>/dev/null)" "trust-reviewed=judge-N9"
MAC_T9=$(sed -n 's/^mac=//p' "$GO13" 2>/dev/null)
HANDOVER_DIR="$ROOT13" bash "$SCRIPT" --trust-reviewed judge-N8 81 "$SHA" >/dev/null 2>&1
MAC_T8=$(sed -n 's/^mac=//p' "$GO13" 2>/dev/null)
[ -n "$MAC_T9" ] && [ "$MAC_T9" != "$MAC_PLAIN" ] && [ "$MAC_T9" != "$MAC_T8" ] \
  && echo "ok - 3895: the mac covers the trust id (differs from the ordinary mac and per id)" \
  || { echo "FAIL - 3895: trust mac [$MAC_T9] vs plain [$MAC_PLAIN] vs N8 [$MAC_T8]"; fails=$((fails+1)); }
# The shared verifier accepts what the writer signed, and refuses an edited id.
# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/go-gate.sh"
rc=0; out=$(go_trust_gate 81 "$SHA" "$ROOT13" o/r) || rc=$?
check "3895: go_trust_gate accepts go.sh's trust GO" "$rc:$out" "0:judge-N8"
VPR=
# shellcheck disable=SC2218  # the read-race test below defines a sed() hook; this is the binary
sed -i.bak 's/^trust-reviewed=.*/trust-reviewed=judge-N7/' "$GO13"
rc=0; go_trust_gate 81 "$SHA" "$ROOT13" o/r >/dev/null || rc=$?
check "3895: go_trust_gate refuses an edited trust id" "$rc" "2"
HANDOVER_DIR="$ROOT13" bash "$SCRIPT" 81 "$SHA" >/dev/null 2>&1
rc=0; out=$(go_trust_gate 81 "$SHA" "$ROOT13" o/r) || rc=$?
check "3895: go_trust_gate refuses an ordinary GO" "$rc" "2"
contains "3895: and says how to grant one" "$out" "--trust-reviewed"
rc=0; go_gate 81 "$SHA" "$ROOT13" o/r >/dev/null || rc=$?
check "3895: go_gate still accepts the ordinary GO" "$rc" "0"
# Read race (judge NO-GO on PR 1479): a copy of the ordinary GO with a forged
# trust line keeps the ordinary mac. Swapped in after the verifier's first read
# of the file, a verifier that re-reads it checks the mac against the genuine
# copy and takes the trust id from the forged one. The sed hook swaps on its
# first call, deterministically; the verifier must read the file once.
cp "$GO13" "$GO13.forged"
printf 'trust-reviewed=forged\n' >> "$GO13.forged"
# shellcheck disable=SC2317  # invoked indirectly, by the verifier under test
sed() { command sed "$@"; local r=$?; [ -f "$GO13.forged" ] && mv -f "$GO13.forged" "$GO13"; return "$r"; }
rc=0; out=$(go_trust_gate 81 "$SHA" "$ROOT13" o/r) || rc=$?
unset -f sed
check "3895: a GO swapped between reads never yields a trust id" "$rc" "2"
rm -f "$GO13.forged"

# --- 14. HIMMEL-4565: no GO for a head ready-check does not pass ------------
# The console ran ready-check by convention only; go.sh signed any head. It
# now runs ready-check itself (check 4 is the CR-ledger ok row at the head)
# and refuses, exit 4 and nothing written, on anything but PASS.
mkdir -p "$ROOT14"
SHA14=1111111111111111111111111111111111111111
rc=0; out="$(READY_STUB_HEAD="$SHA14" HANDOVER_DIR="$ROOT14" bash "$SCRIPT" 82 "$SHA14" 2>&1)" || rc=$?
check    "4565: unreviewed head (no ledger ok row) -> exit 4" "$rc" "4"
contains "4565: names the failed check" "$out" "4. CR ledger"
check    "4565: unreviewed head -> nothing written" "$(find "$ROOT14" -type f | wc -l | tr -d ' ')" "0"
ready_pass_ledger "$READY_REPO" "$SHA14"
rc=0; out="$(READY_STUB_HEAD="$SHA" HANDOVER_DIR="$ROOT14" bash "$SCRIPT" 82 "$SHA14" 2>&1)" || rc=$?
check    "4565: PR head moved past the sha -> exit 4" "$rc" "4"
check    "4565: moved head -> nothing written" "$(find "$ROOT14" -type f | wc -l | tr -d ' ')" "0"
rc=0; out="$(cd "$ROOT14" && READY_STUB_HEAD="$SHA14" HANDOVER_DIR="$ROOT14" bash "$SCRIPT" 82 "$SHA14" 2>&1)" || rc=$?
check    "4565: run outside any repo (no ledger to read) -> exit 4" "$rc" "4"
rc=0; out="$(READY_STUB_HEAD="$SHA14" HANDOVER_DIR="$ROOT14" bash "$SCRIPT" 82 "$SHA14" 2>/dev/null)" || rc=$?
check    "4565: reviewed head -> exit 0" "$rc" "0"
check    "4565: reviewed head -> the GO path" "$out" "$ROOT14/.locks/go/82.$SHA14"

# --- 15. HIMMEL-3832: --trust-reviewed <qid> needs that judge's GO verdict ---
# The verdict file is <root>/<user>/<bucket>/verdicts/<qid>/*.md; the first
# non-blank line under `## Verdict` parses only as **GO**/**NO-GO** for head
# `<sha>` (a trailing full stop allowed). An unparsed file, a NO-GO on this head,
# or no GO on this head refuses, exit 5, nothing written; another head's verdict
# (an earlier round) is ignored.
mkdir -p "$ROOT15"
t15() {  # <label> <qid> - expect a refusal, nothing written
  local rc=0
  out="$(HANDOVER_DIR="$ROOT15" bash "$SCRIPT" --trust-reviewed "$2" 83 "$SHA" 2>&1)" || rc=$?
  check "3832: $1 -> exit 5" "$rc" "5"
  check "3832: $1 -> nothing written" "$(find "$ROOT15/.locks" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
}
t15 "no verdict dir" J1
verdict "$ROOT15" J2 "**NO-GO** for head \`$SHA\`."
t15 "NO-GO verdict" J2
verdict "$ROOT15" J3 "**GO** for head \`$SHA14\`."
t15 "GO for another head" J3
verdict "$ROOT15" J4 "**GO.**"
t15 "GO bound to no head (unparsed)" J4
verdict "$ROOT15" J5 "**GO** for head \`$SHA\`. Ship it."
t15 "trailing text after the head (unparsed)" J5
verdict "$ROOT15" J6 "**GO** for head \`$SHA\`."
verdict "$ROOT15" J6 "**NO-GO** for head \`$SHA\`." second
t15 "a second judge file says NO-GO" J6
verdict "$ROOT15" J7 "**GO** for head \`$SHA\`."
verdict "$ROOT15" J7 "**GO.**" second
t15 "a second judge file is unparsed" J7
mkdir -p "$ROOT15/$VSCOPE/verdicts/J8"
t15 "an empty verdict dir" J8
verdict "$ROOT15" "judge:J9" "**GO** for head \`$SHA\`."
t15 "an id that is not a qid path segment" "judge:J9"
verdict "$ROOT15" J10 "**GO** for head \`$SHA\`."
rc=0; out="$(HANDOVER_DIR="$ROOT15" bash "$SCRIPT" --trust-reviewed J10 83 "$SHA" 2>/dev/null)" || rc=$?
check    "3832: GO verdict for this head -> exit 0" "$rc" "0"
contains "3832: trust id signed in" "$(cat "$ROOT15/.locks/go/83.$SHA" 2>/dev/null)" "trust-reviewed=J10"
verdict "$ROOT15" J11 "**GO** for head \`$SHA\`"
rc=0; HANDOVER_DIR="$ROOT15" bash "$SCRIPT" --trust-reviewed J11 83 "$SHA" >/dev/null 2>&1 || rc=$?
check    "3832: no trailing full stop -> exit 0" "$rc" "0"
verdict "$ROOT15" J12 "**NO-GO** for head \`$SHA14\`." round1
verdict "$ROOT15" J12 "**GO** for head \`$SHA\`." round2
rc=0; HANDOVER_DIR="$ROOT15" bash "$SCRIPT" --trust-reviewed J12 83 "$SHA" >/dev/null 2>&1 || rc=$?
check    "3832: an earlier round's NO-GO on another head is ignored -> exit 0" "$rc" "0"
mkdir -p "$ROOT15/$VSCOPE/verdicts/J13"
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
printf '# VERDICT J13 - judge\r\n\r\n## Verdict\r\n\r\n**GO** for head `%s`.\r\n\r\npr: 83\r\n\r\nreason\r\n' "$SHA" \
  > "$ROOT15/$VSCOPE/verdicts/J13/HIMMEL-1-judge-J13.md"
vsign J13 "$ROOT15/$VSCOPE/verdicts/J13/HIMMEL-1-judge-J13.md"
rc=0; HANDOVER_DIR="$ROOT15" bash "$SCRIPT" --trust-reviewed J13 83 "$SHA" >/dev/null 2>&1 || rc=$?
check    "3832: a CRLF verdict file -> exit 0" "$rc" "0"

# --- 16. HIMMEL-4589: only this repo's own <user>/<bucket> verdicts count -----
# A judge can write verdicts/<qid>/ in any bucket; the lookup must not read them.
t16() {  # <label> <qid> - expect a refusal, nothing written
  local rc=0
  out="$(HANDOVER_DIR="$ROOT16" bash "$SCRIPT" --trust-reviewed "$2" 84 "$SHA" 2>&1)" || rc=$?
  check "4589: $1 -> exit 5" "$rc" "5"
  check "4589: $1 -> nothing written" "$(find "$ROOT16/.locks" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
}
mkdir -p "$ROOT16"
VPR=84
other_verdict() {  # <scope> <qid> - a GO for $SHA written under another scope
  mkdir -p "$ROOT16/$1/verdicts/$2"
  # shellcheck disable=SC2016  # the backticks are the verdict line's literal text
  printf '# VERDICT %s - judge\n\n## Verdict\n\n**GO** for head `%s`.\n\npr: 84\n' "$2" "$SHA" > "$ROOT16/$1/verdicts/$2/HIMMEL-1-judge-$2.md"
}
other_verdict "u/not-this-repo" K1
t16 "a GO in another repo bucket" K1
other_verdict "someone-else/$VBUCKET" K2
t16 "a GO under another user" K2
other_verdict "u/not-this-repo" K3
verdict "$ROOT16" K3 "**NO-GO** for head \`$SHA\`."
t16 "own-bucket NO-GO beats another bucket's GO" K3
verdict "$ROOT16" K4 "**GO** for head \`$SHA\`."
other_verdict "u/not-this-repo" K4
rc=0; HANDOVER_DIR="$ROOT16" bash "$SCRIPT" --trust-reviewed K4 84 "$SHA" >/dev/null 2>&1 || rc=$?
check "4589: own-bucket GO still satisfies it -> exit 0" "$rc" "0"
rm -rf "$ROOT16/.locks"
other_verdict "u/$VBUCKET" K5
rc=0; out="$(USER_SLUG='../x' HANDOVER_DIR="$ROOT16" bash "$SCRIPT" --trust-reviewed K5 84 "$SHA" 2>&1)" || rc=$?
check "4589: an unresolvable user slug fails closed -> exit 5" "$rc" "5"
contains "4589: and says the scope cannot resolve" "$out" "cannot resolve this repo's <user>/<bucket> verdict scope"

# --- 17. HIMMEL-4928: a trust verdict counts only for the PR it names -------
# Two PRs can point at one head; the verdict's pr: line (two lines after the
# verdict line) must equal go.sh's PR. A verdict with no pr: line fails closed:
# it was written before the field existed and the judge rewrites it with
# write-verdict.sh --pr.
# shellcheck disable=SC2031  # tmp is assigned at the top; the subshell reads are not writes
ROOT17="$tmp/root17"; mkdir -p "$ROOT17"
t17() {  # <label> <qid> <pr> <stable text> - expect a refusal, nothing written
  local rc=0
  out="$(HANDOVER_DIR="$ROOT17" bash "$SCRIPT" --trust-reviewed "$2" "$3" "$SHA" 2>&1)" || rc=$?
  check "4928: $1 -> exit 5" "$rc" "5"
  contains "4928: $1 -> says why" "$out" "$4"
  check "4928: $1 -> nothing written" "$(find "$ROOT17/.locks" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
}
VPR=90; verdict "$ROOT17" L1 "**GO** for head \`$SHA\`."
t17 "a GO naming another PR on the same head" L1 91 "names PR #90, not PR #91"
rc=0; HANDOVER_DIR="$ROOT17" bash "$SCRIPT" --trust-reviewed L1 90 "$SHA" >/dev/null 2>&1 || rc=$?
check "4928: the same verdict satisfies its own PR -> exit 0" "$rc" "0"
rm -rf "$ROOT17/.locks"
mkdir -p "$ROOT17/$VSCOPE/verdicts/L2"
# shellcheck disable=SC2016  # the backticks are the verdict line literal text
printf '# VERDICT L2 - judge\n\n## Verdict\n\n**GO** for head `%s`.\n\nreason\n' "$SHA" > "$ROOT17/$VSCOPE/verdicts/L2/HIMMEL-1-judge-L2.md"
vsign L2 "$ROOT17/$VSCOPE/verdicts/L2/HIMMEL-1-judge-L2.md"
t17 "a legacy GO with no pr: line" L2 90 "names no PR"
mkdir -p "$ROOT17/$VSCOPE/verdicts/L3"
# shellcheck disable=SC2016  # the backticks are the verdict line literal text
printf '# VERDICT L3 - judge\n\n## Verdict\n\n**GO** for head `%s`.\n\nreason\npr: 90\n' "$SHA" > "$ROOT17/$VSCOPE/verdicts/L3/HIMMEL-1-judge-L3.md"
vsign L3 "$ROOT17/$VSCOPE/verdicts/L3/HIMMEL-1-judge-L3.md"
t17 "a pr: line in the body is not the field" L3 90 "names no PR"
VPR=90; verdict "$ROOT17" L4 "**NO-GO** for head \`$SHA\`."
t17 "a NO-GO naming another PR still vetoes" L4 91 "NO-GO for head"
VPR=

# --- 18. HIMMEL-4984: a record counts as merge trust only with its mac --------
mkdir -p "$ROOT18"
t18() {  # <label> <qid> - expect a refusal, nothing written
  local rc=0
  out="$(HANDOVER_DIR="$ROOT18" bash "$SCRIPT" --trust-reviewed "$2" 95 "$SHA" 2>&1)" || rc=$?
  check "4984: $1 -> exit 5" "$rc" "5"
  check "4984: $1 -> nothing written" "$(find "$ROOT18/.locks" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
}
VPR=95
VSIGN=0 verdict "$ROOT18" M1 "**GO** for head \`$SHA\`."
t18 "a hand-written exact-format GO (no mac)" M1
verdict "$ROOT18" M2 "**GO** for head \`$SHA\`."
sed -i.bak 's/^reason$/reasoN/' "$ROOT18/$VSCOPE/verdicts/M2/HIMMEL-1-judge-M2.md"
rm -f "$ROOT18/$VSCOPE/verdicts/M2/"*.bak
t18 "an edited evidence byte invalidates the mac" M2
VEXTRA=$'\ndelta-scope: test-only\ndelta-from: 0123456789abcdef0123456789abcdef01234566\n' verdict "$ROOT18" M3 "**GO** for head \`$SHA\`."
t18 "a signed scope-round record is not merge trust" M3
verdict "$ROOT18" M4 "**GO** for head \`$SHA\`."
rc=0; HANDOVER_DIR="$ROOT18" bash "$SCRIPT" --trust-reviewed M4 95 "$SHA" >/dev/null 2>&1 || rc=$?
check "4984: a signed GO still satisfies --trust-reviewed -> exit 0" "$rc" "0"
VPR=

echo "---"
if [ "$fails" -eq 0 ]; then
  echo "PASS - test-go.sh"
  exit 0
else
  echo "FAIL - test-go.sh ($fails failure(s))"
  exit 1
fi
