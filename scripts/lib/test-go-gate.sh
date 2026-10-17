#!/usr/bin/env bash
# scripts/lib/test-go-gate.sh -- fixture test for scripts/lib/go-gate.sh's
# console_leg() predicate.
#
# Before go-gate.sh the HIMMEL_CONSOLE_LEG truthiness test was hand-copied at
# three sites (merge-on-green.sh's _truthy(), block-unresolved-cr-merge.sh's
# gate 3, console-kit/go.sh's inline check) with no shared source of truth --
# nothing stopped one copy drifting from the other two. This suite is a single
# table-driven test: one spellings list, checked directly against console_leg()
# and, for the cheapest call site (go.sh, which only needs a HANDOVER_DIR
# fixture and no gh/network calls), against the live end-to-end behaviour too.
# It also asserts structurally that none of the three sites still hand-rolls
# its own case statement -- each must call console_leg instead.
#
# RED-control instructions for reviewers:
#   BEFORE the fix: `git stash` the go-gate.sh/merge-on-green.sh/
#   block-unresolved-cr-merge.sh/go.sh changes (keep this test file) and rerun
#   -- FAIL, because scripts/lib/go-gate.sh has no console_leg() to source.
#   AFTER the fix, to prove the table itself can fail: temporarily add a
#   spelling (e.g. 'disabled') to ONE call site's own copy in a scratch file,
#   point this suite's *_SRC override at it, rerun -- FAIL naming the site;
#   then `bash scripts/git/restore-to-head.sh <path>` to restore.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, no .ps1 twin needed (no hook
# dispatch here).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_GATE_SRC="${GO_GATE_SRC:-$HERE/go-gate.sh}"
GO_SCRIPT="${GO_SCRIPT:-$HERE/../handover/console-kit/go.sh}"
MERGE_ON_GREEN_SRC="${MERGE_ON_GREEN_SRC:-$HERE/../handover/merge-on-green.sh}"
BLOCK_CR_MERGE_SRC="${BLOCK_CR_MERGE_SRC:-$HERE/../hooks/block-unresolved-cr-merge.sh}"

FAIL=0
fail() { echo "FAIL: $1" >&2; FAIL=1; }

# --- 1. Table-driven: console_leg() directly ------------------------------
# One spellings list, each row (value, expected rc). Falsy: empty, 0, false,
# off, no -- case-insensitive, whitespace-stripped, same five every call site
# used before go-gate.sh. Everything else is truthy.
SPELLINGS='
""|0
"0"|0
"false"|0
"off"|0
"no"|0
"FALSE"|0
"Off"|0
"NO"|0
" 0 "|0
"  "|0
"1"|1
"true"|1
"yes"|1
"TRUE"|1
" 1 "|1
"2"|1
"anything"|1
'

unset -f console_leg go_gate 2>/dev/null || true
# shellcheck source=/dev/null
if ! . "$GO_GATE_SRC" 2>/dev/null || ! declare -F console_leg >/dev/null 2>&1; then
    fail "cannot source $GO_GATE_SRC or it does not define console_leg -- this is the RED-before-fix case"
else
    old_ifs="$IFS"
    IFS='
'
    for row in $SPELLINGS; do
        IFS="$old_ifs"
        [ -n "$row" ] || continue
        val="${row%%|*}"
        exp_truthy="${row##*|}"
        val="${val#\"}"; val="${val%\"}"
        rc=0
        HIMMEL_CONSOLE_LEG="$val" bash -c '
            unset -f console_leg 2>/dev/null || true
            . "$1"
            console_leg
        ' _ "$GO_GATE_SRC" || rc=$?
        if [ "$exp_truthy" -eq 1 ] && [ "$rc" -ne 0 ]; then
            fail "console_leg HIMMEL_CONSOLE_LEG='$val' expected truthy (rc 0), got rc=$rc"
        elif [ "$exp_truthy" -eq 0 ] && [ "$rc" -eq 0 ]; then
            fail "console_leg HIMMEL_CONSOLE_LEG='$val' expected falsy (rc!=0), got rc=0"
        fi
        IFS='
'
    done
    IFS="$old_ifs"
fi

# --- 1b. Structural: the shared predicate must match exactly the five
# documented falsy spellings, no more, no fewer -- guards against a NEW
# spelling being added to the one shared site (forbidden, see the ticket's
# do-not list), which the plain value table above would otherwise miss if the
# new spelling isn't also added there.
CASE_LINE=$(grep -E "return 1 ;;" "$GO_GATE_SRC" 2>/dev/null | head -1)
CASE_PATTERN=$(printf '%s' "$CASE_LINE" | sed -E 's/^[[:space:]]*//; s/\).*$//')
if [ "$CASE_PATTERN" != "''|0|false|off|no" ]; then
    fail "$GO_GATE_SRC's console_leg falsy branch no longer matches exactly the five spellings (empty/0/false/off/no) -- got: $CASE_LINE"
fi

# --- 2. Structural: no call site still hand-rolls the case statement -----
for site in "$MERGE_ON_GREEN_SRC" "$BLOCK_CR_MERGE_SRC" "$GO_SCRIPT"; do
    if grep -qE "HIMMEL_CONSOLE_LEG.*tr -d '\[:space:\]'.*\bin\$|case .*HIMMEL_CONSOLE_LEG" "$site"; then
        fail "$site still hand-rolls a HIMMEL_CONSOLE_LEG case statement instead of calling console_leg"
    fi
    # Executable call only: strip full-line comments and the two references
    # to the name that are not invocations (declare -F probe, unset -f drop).
    if ! grep -vE '^[[:space:]]*#' "$site" | grep -vE 'declare -F console_leg|unset -f' | grep -q 'console_leg'; then
        fail "$site never calls console_leg -- HIMMEL-3149 predicate not wired in"
    fi
done

# --- 3. Live end-to-end: full table against go.sh (cheapest call site) ---
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-go-gate.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$ROOT"' EXIT
ROOT="$(cd "$ROOT" && pwd)"
# go.sh mints its GO key under $HOME/.config/himmel — a scratch
# HOME keeps every run below off the operator's real key.
export HOME="$ROOT/home"
mkdir -p "$HOME"
SHA="$(printf '%040d' 7)"

# go.sh now resolves this repo's nwo via `gh repo view` to bind
# the GO mac. A gh stub on PATH keeps every go.sh call below hermetic (no
# real gh/network dependency) and lets tests fix the nwo it returns via
# STUB_NWO.
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'STUB'
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
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
export STUB_NWO="o/r"
# go.sh refuses unless ready-check.sh passes, so it runs from a
# repo whose CR ledger has an ok row for $SHA, under a gh answering ready-check
# green (every other call falls through to the stub above).
# shellcheck source=../handover/console-kit/testlib-ready-pass.sh
. "$HERE/../handover/console-kit/testlib-ready-pass.sh"
ready_pass_bin "$ROOT/ready-bin"
export PATH="$ROOT/ready-bin:$PATH" READY_STUB_HEAD="$SHA"
git init -q "$ROOT/ready-repo"
ready_pass_ledger "$ROOT/ready-repo" "$SHA"
cd "$ROOT/ready-repo" || { echo "FAIL: cd into the ready repo" >&2; exit 1; }

# HIMMEL_CONSOLE_LEG is a Claude Code marker (any value): run from an anchor
# checkout with no claude ancestor (CI) and HANDOVER_DIR set, go.sh refuses 96
# A console always runs under its claude session, so run
# under a fake one.
_as_claude() { (exec -a claude bash -c '"$@"; exit $?' _ "$@"); }

old_ifs="$IFS"
IFS='
'
for row in $SPELLINGS; do
    IFS="$old_ifs"
    [ -n "$row" ] || continue
    val="${row%%|*}"
    exp_truthy="${row##*|}"
    val="${val#\"}"; val="${val%\"}"
    rc=0
    HANDOVER_DIR="$ROOT" HIMMEL_CONSOLE_LEG="$val" _as_claude bash "$GO_SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$?
    if [ "$exp_truthy" -eq 1 ]; then
        if [ "$rc" -ne 3 ]; then
            fail "go.sh HIMMEL_CONSOLE_LEG='$val' expected refusal (rc 3), got rc=$rc"
        fi
    else
        if [ "$rc" -ne 0 ]; then
            fail "go.sh HIMMEL_CONSOLE_LEG='$val' expected a written GO (rc 0), got rc=$rc"
        fi
    fi
    IFS='
'
done
IFS="$old_ifs"

# --- 4. a GO is authenticated, not merely present -----------
# A leg that can write the handover root must not be able to forge its own
# GO. go.sh signs pr|sha with a key only it mints; go_gate verifies the mac.
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_RELAY 2>/dev/null || true
GROOT="$ROOT/g4"
mkdir -p "$GROOT/.locks/go"
gate() {  # <pr> <sha> [nwo] -> rc of go_gate in a clean shell, reason on stdout
    bash -c 'unset -f go_gate 2>/dev/null || true; . "$1"; go_gate "$2" "$3" "$4" "$5"' _ "$GO_GATE_SRC" "$1" "$2" "$GROOT" "${3:-o/r}"
}

# 4a. A leg-planted GO — the plain lines go.sh used to write — is refused.
printf 'pr=%s\nhead=%s\nby=leg\nat=2026-09-24T00:00:00Z\n' 91 "$SHA" > "$GROOT/.locks/go/91.$SHA"
rc=0; out=$(gate 91 "$SHA") || rc=$?
[ "$rc" -eq 2 ] || fail "4a: a leg-planted GO (no mac) was accepted by go_gate (rc=$rc) -- HIMMEL-3543"
case "$out" in *mac*) ;; *) fail "4a: refusal does not name the mac as the cause: $out" ;; esac

# 4b. A real console GO written by go.sh passes.
rc=0; HANDOVER_DIR="$GROOT" bash "$GO_SCRIPT" 92 "$SHA" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "4b: go.sh could not write a GO (rc=$rc)"
rc=0; out=$(gate 92 "$SHA") || rc=$?
[ "$rc" -eq 0 ] || fail "4b: a real console GO was refused (rc=$rc): $out"

# 4c. The key go.sh minted is 0600 and 64 hex chars.
KEY="$HOME/.config/himmel/go-hmac.key"
if [ ! -f "$KEY" ]; then
    fail "4c: go.sh minted no key at $KEY"
else
    mode=$(stat -c %a "$KEY" 2>/dev/null || stat -f %Lp "$KEY" 2>/dev/null)
    [ "$mode" = "600" ] || fail "4c: key mode is $mode, want 600"
    grep -qxE '[0-9a-f]{64}' "$KEY" || fail "4c: key is not 64 lowercase hex chars"
fi

# 4d. A real GO copied onto another PR's path, pr= line rewritten, is refused:
# the mac binds pr as well as sha.
sed 's/^pr=92$/pr=93/' "$GROOT/.locks/go/92.$SHA" > "$GROOT/.locks/go/93.$SHA"
rc=0; gate 93 "$SHA" >/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "4d: a GO re-bound to another PR was accepted (rc=$rc)"

# 4e. The mac is a real HMAC-SHA256 over himmel-go-v2|<nwo>|<pr>|<sha>
# (bound to the repo, resolved above via the gh stub as o/r).
if [ -f "$KEY" ]; then
    want=$(printf 'himmel-go-v2|o/r|92|%s' "$SHA" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(cat "$KEY")" | awk '{print $NF}')
    got=$(sed -n 's/^mac=//p' "$GROOT/.locks/go/92.$SHA")
    if [ -z "$want" ] || [ "$got" != "$want" ]; then
        fail "4e: mac [$got] is not HMAC-SHA256 [$want]"
    fi
fi

# 4f. No key at the verifier (a different HOME) fails closed.
rc=0; HOME="$ROOT/nokey" gate 92 "$SHA" >/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "4f: go_gate accepted a GO with no key to verify against (rc=$rc)"
[ ! -e "$ROOT/nokey/.config/himmel/go-hmac.key" ] || fail "4f: the verifier minted a key (only go.sh may)"

# --- 5. _go_in_harness must not trust an inherited GIT_* env ---
# An exported GIT_DIR pointing at a DIFFERENT repo would, without a scrub,
# override `-C` and steer `git rev-parse` to answer about that other repo
# instead of the path _go_in_harness was actually asked about.
REAL_A="$ROOT/harness-a"; mkdir -p "$REAL_A" && git -C "$REAL_A" init -q
REAL_B="$ROOT/harness-b"; mkdir -p "$REAL_B" && git -C "$REAL_B" init -q
DECOY="$ROOT/decoy"; mkdir -p "$DECOY" && git -C "$DECOY" init -q
DECOY_GIT_DIR="$(git -C "$DECOY" rev-parse --path-format=absolute --git-dir)"

# Baseline (no env poisoning): A is not B.
rc=0; bash -c 'unset -f _go_in_harness 2>/dev/null || true; . "$1"; _go_in_harness "$2" "$3"' \
    _ "$GO_GATE_SRC" "$REAL_A" "$REAL_B" || rc=$?
[ "$rc" -ne 0 ] || fail "5a: baseline expected _go_in_harness(A, B) to be false (rc!=0), got rc=0"

# Poisoned: an exported GIT_DIR naming the decoy repo must not change the
# answer -- the scrub inside _go_in_harness's own subshells must win.
rc=0; GIT_DIR="$DECOY_GIT_DIR" bash -c 'unset -f _go_in_harness 2>/dev/null || true; . "$1"; _go_in_harness "$2" "$3"' \
    _ "$GO_GATE_SRC" "$REAL_A" "$REAL_B" || rc=$?
[ "$rc" -ne 0 ] || fail "5b: an exported GIT_DIR (decoy repo) flipped _go_in_harness(A, B) to true (rc=0) -- HIMMEL-3570"

# 5c. GIT_CEILING_DIRECTORIES joins the scrub too. A
# nested "split-root" shape (e.g. a handovers/ dir under the anchor, no .git
# of its own) resolves via upward .git discovery from the nested path -- an
# exported GIT_CEILING_DIRECTORIES naming the anchor's own top blocks that
# discovery, flipping the same-repo answer from true (rc=0) to false (rc!=0),
# unless the scrub wins.
REAL_A_SUB="$REAL_A/handovers"; mkdir -p "$REAL_A_SUB"

# Baseline (no env poisoning): the nested path is inside REAL_A.
rc=0; bash -c 'unset -f _go_in_harness 2>/dev/null || true; . "$1"; _go_in_harness "$2" "$3"' \
    _ "$GO_GATE_SRC" "$REAL_A_SUB" "$REAL_A" || rc=$?
[ "$rc" -eq 0 ] || fail "5c-baseline: expected _go_in_harness(REAL_A/handovers, REAL_A) to be true (rc=0), got rc=$rc"

# Poisoned: an exported GIT_CEILING_DIRECTORIES naming REAL_A must not change
# the answer -- the scrub inside _go_in_harness's own subshells must win.
rc=0; GIT_CEILING_DIRECTORIES="$REAL_A" bash -c 'unset -f _go_in_harness 2>/dev/null || true; . "$1"; _go_in_harness "$2" "$3"' \
    _ "$GO_GATE_SRC" "$REAL_A_SUB" "$REAL_A" || rc=$?
[ "$rc" -eq 0 ] || fail "5c: an exported GIT_CEILING_DIRECTORIES (anchor top) flipped _go_in_harness(REAL_A/handovers, REAL_A) to false (rc=$rc) -- HIMMEL-3572 round 2"

# --- 6. go_msg_mac signs verdict records; go_mac is unchanged ---
PINHOME="$ROOT/pinhome"; mkdir -p "$PINHOME/.config/himmel"
printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$PINHOME/.config/himmel/go-hmac.key"
PINSHA=$(printf '1%.0s' $(seq 1 40))
pin_mac() { HOME="$PINHOME" bash -c 'unset -f go_mac go_msg_mac 2>/dev/null || true; . "$1"; shift; "$@"' _ "$GO_GATE_SRC" "$@"; }
# 6a. Pin: go_mac output is byte-identical to the pre-refactor values.
[ "$(pin_mac go_mac 92 "$PINSHA" o/r)" = b00594fd457b1bbf8c73c1a82079acc0fb894ae7d6d756833912b89961184a07 ] \
    || fail "6a: go_mac (plain) no longer matches its pinned value"
[ "$(pin_mac go_mac 92 "$PINSHA" o/r rev-1)" = 08e2b5dd55947a3a812d5dd7c624cac40cab1d881daf4c8fdf9cd55e63a83833 ] \
    || fail "6a: go_mac (trust-reviewed) no longer matches its pinned value"
# 6b. go_msg_mac is a real HMAC-SHA256 over "<domain>|<msg>" with the GO key.
want=$(printf 'himmel-verdict-v1|a|b' | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(cat "$PINHOME/.config/himmel/go-hmac.key")" | awk '{print $NF}')
[ "$(pin_mac go_msg_mac himmel-verdict-v1 'a|b')" = "$want" ] || fail "6b: go_msg_mac is not HMAC-SHA256 over <domain>|<msg>"
# 6c. Domains are separate: a verdict mac never equals a GO mac, whatever the message.
v=$(pin_mac go_msg_mac himmel-verdict-v1 "o/r|92|$PINSHA")
if ! { [ -n "$v" ] && [ "$v" != "$(pin_mac go_mac 92 "$PINSHA" o/r)" ]; }; then fail "6c: a verdict mac equals a GO mac"; fi
g=$(pin_mac go_msg_mac himmel-go-v2 "o/r|92|$PINSHA")
if ! { [ "$g" = "$(pin_mac go_mac 92 "$PINSHA" o/r)" ] && [ "$g" != "$v" ]; }; then fail "6c: the GO domain via go_msg_mac does not stay distinct from the verdict domain"; fi
# 6d. Only the verdict domain is accepted for a verdict mac; empty domain or msg refuses; no key fails closed.
rc=0; pin_mac go_msg_mac '' x >/dev/null 2>&1 || rc=$?; [ "$rc" -ne 0 ] || fail "6d: an empty domain was signed"
rc=0; pin_mac go_msg_mac himmel-verdict-v1 '' >/dev/null 2>&1 || rc=$?; [ "$rc" -ne 0 ] || fail "6d: an empty message was signed"
rc=0; HOME="$ROOT/nokey" bash -c '. "$1"; go_msg_mac himmel-verdict-v1 x' _ "$GO_GATE_SRC" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "6d: go_msg_mac signed with no key"
# 6e. One snapshot of the bytes: the file check and the snapshot check agree, and
# an edited byte in the snapshot fails the mac.
SREC="$ROOT/snap-record.md"
printf '# VERDICT q - n\n\nbody line\n' > "$SREC"
printf 'mac: %s\n' "$(HOME="$PINHOME" bash -c '. "$1"; go_verdict_mac s q n < "$2"' _ "$GO_GATE_SRC" "$SREC")" >> "$SREC"
snap_ok() { HOME="$PINHOME" bash -c '. "$1"; go_verdict_snapshot "$2" || exit 3; case "$4" in edit) GO_VERDICT_SNAP=${GO_VERDICT_SNAP/body/BODY} ;; esac; go_verdict_mac_ok_text "$GO_VERDICT_SNAP" s q n' _ "$GO_GATE_SRC" "$SREC" x "${1:-}"; }
rc=0; snap_ok >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 0 ] || fail "6e: a signed record's snapshot did not verify (rc=$rc)"
rc=0; snap_ok edit >/dev/null 2>&1 || rc=$?; [ "$rc" -ne 0 ] || fail "6e: an edited snapshot verified"
# 6f. A NUL byte would drop out of the shell variable and leave the mac valid over
# different bytes, so a signed record with one inserted is refused.
NREC="$ROOT/snap-record-nul.md"
{ head -n 2 "$SREC"; printf 'body\0 line\n'; tail -n +4 "$SREC"; } > "$NREC"
rc=0; HOME="$PINHOME" bash -c '. "$1"; go_verdict_mac_ok "$2" s q n' _ "$GO_GATE_SRC" "$NREC" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "6f: a record with an inserted NUL byte verified"
rc=0; HOME="$PINHOME" bash -c '. "$1"; go_verdict_mac_ok "$2" s q n' _ "$GO_GATE_SRC" "$SREC" >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 0 ] || fail "6f: the clean record stopped verifying"
rc=0; HOME="$PINHOME" bash -c '. "$1"; go_verdict_mac_ok "$2" s q n' _ "$GO_GATE_SRC" "$SREC" >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 0 ] || fail "6e: go_verdict_mac_ok disagrees with the snapshot check"

# --- 7. go_fixred_gate - the console-written fix-GO for the red-main gate
# A fix-GO names ONE red run: file fix-main-red.<pr>.<sha>.<run>, signed over
# himmel-go-fixred-v1|<nwo>|<pr>|<sha>|<run>, so it never verifies as an ordinary
# GO, a trust GO or a verdict, and binds the repo, PR, head and run id.
FXROOT="$ROOT/fx"; mkdir -p "$FXROOT/.locks/go"
FXRUN=37964772913
fx_write() {  # <pr> <sha> <run> <nwo> [<mac-run>] - write a fix-GO as go.sh would
    local pr=$1 sha=$2 run=$3 nwo=$4 mrun=${5:-$3} mac
    mac=$(HOME="$PINHOME" bash -c '. "$1"; go_msg_mac himmel-go-fixred-v1 "$2"' _ "$GO_GATE_SRC" "$nwo|$pr|$sha|$mrun")
    printf 'pr=%s\nhead=%s\nfix-main-red-run=%s\nby=t\nat=x\nmac=%s\n' "$pr" "$sha" "$run" "$mac" \
        > "$FXROOT/.locks/go/fix-main-red.$pr.$sha.$run"
}
fx_gate() {  # <pr> <sha> <nwo> <run> -> go_fixred_gate's rc
    HOME="$PINHOME" bash -c '. "$1"; go_fixred_gate "$2" "$3" "$4" "$5" "$6"' _ "$GO_GATE_SRC" "$1" "$2" "$FXROOT" "$3" "$4"
}
fx_write 92 "$PINSHA" "$FXRUN" o/r
rc=0; fx_gate 92 "$PINSHA" o/r "$FXRUN" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "7a: a valid fix-GO for the red run was refused (rc=$rc)"
rc=0; fx_gate 92 "$PINSHA" o/r 111 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "7b: a fix-GO for run $FXRUN passed for a different (newer) red run"
rc=0; fx_gate 93 "$PINSHA" o/r "$FXRUN" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "7c: a fix-GO for PR 92 passed for PR 93"
rc=0; fx_gate 92 "$PINSHA" other/repo "$FXRUN" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "7d: a fix-GO signed for o/r passed for other/repo"
fx_write 94 "$PINSHA" "$FXRUN" o/r 999
rc=0; fx_gate 94 "$PINSHA" o/r "$FXRUN" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "7e: a fix-GO whose mac signs another run id passed"
printf 'pr=95\nhead=%s\nfix-main-red-run=%s\nby=t\nat=x\n' "$PINSHA" "$FXRUN" > "$FXROOT/.locks/go/fix-main-red.95.$PINSHA.$FXRUN"
rc=0; fx_gate 95 "$PINSHA" o/r "$FXRUN" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "7f: an unsigned fix-GO passed"
# an ordinary GO mac copied into a fix-GO file must not verify (domain separation)
gmac=$(pin_mac go_mac 96 "$PINSHA" o/r)
printf 'pr=96\nhead=%s\nfix-main-red-run=%s\nmac=%s\n' "$PINSHA" "$FXRUN" "$gmac" > "$FXROOT/.locks/go/fix-main-red.96.$PINSHA.$FXRUN"
rc=0; fx_gate 96 "$PINSHA" o/r "$FXRUN" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "7g: an ordinary GO mac verified as a fix-GO"
rc=0; fx_gate 92 "$PINSHA" o/r 'x;1' >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "7h: a non-numeric run id was accepted"
# 7i. a fix-GO body sitting at the ordinary GO path never passes go_gate
fx_write 97 "$PINSHA" "$FXRUN" o/r
cp "$FXROOT/.locks/go/fix-main-red.97.$PINSHA.$FXRUN" "$FXROOT/.locks/go/97.$PINSHA"
rc=0; HOME="$PINHOME" bash -c '. "$1"; go_gate "$2" "$3" "$4" "$5"' _ "$GO_GATE_SRC" 97 "$PINSHA" "$FXROOT" o/r >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "7i: a fix-GO body at the ordinary GO path passed go_gate (rc=$rc)"
# 7j. head moved: a fix-GO for one head does not pass for another head
OTHERSHA=$(printf '%s' "$PINSHA" | tr '0-9a-f' '1-9a-f0')
rc=0; fx_gate 92 "$OTHERSHA" o/r "$FXRUN" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "7j: a fix-GO for head $PINSHA passed for a moved head (rc=$rc)"

# --- 8. go_verdict_scope user slug sources --------------------
# USER_SLUG absent from env: the slug comes from the PRIMARY's .env when the
# anchor is a linked worktree (which has no .env), and the forge/git fallback
# runs with the ANCHOR as cwd, never the caller's.
SCHOME="$ROOT/scopehome"; mkdir -p "$SCHOME"
sc_git() { HOME="$SCHOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
# shellcheck disable=SC2016  # $1/$2 expand in the inner bash, not here
sc_scope() {  # <anchor> <caller-cwd> -> go_verdict_scope's stdout
    ( cd "$2" && env -i HOME="$SCHOME" PATH="$PATH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        bash -c '. "$1"; go_verdict_scope "$2"' _ "$GO_GATE_SRC" "$1" 2>/dev/null )
}
SCP="$ROOT/scoperepo"; SCW="$ROOT/scopewt"; SCC="$ROOT/scopecaller"; SCN="$ROOT/scopenoenv"
for d in "$SCP" "$SCC" "$SCN"; do mkdir -p "$d"; sc_git -C "$d" init -q; done
sc_git -C "$SCC" config user.name "Caller Name"
sc_git -C "$SCN" config user.name "Anchor Name"
sc_git -C "$SCP" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
printf 'USER_SLUG=envuser\n' > "$SCP/.env"
sc_git -C "$SCP" worktree add -q "$SCW" -b scopewt
got=$(sc_scope "$SCW" "$SCC")
[ "$got" = "envuser/scoperepo" ] || fail "8a: linked-worktree anchor did not take USER_SLUG from the primary's .env (got '$got')"
got=$(sc_scope "$SCN" "$SCC")
[ "$got" = "anchor-name/scopenoenv" ] || fail "8b: the user-slug fallback ran in the caller's cwd, not the anchor's (got '$got')"

# --- 9. change ids, the br-* mac domain, local-git trust paths --
G9="$ROOT/g9"; mkdir -p "$G9/.locks/go"
g9_gate() {  # <fn> <id> <sha> <nwo> -> rc of go_gate/go_trust_gate under PINHOME, reason on stdout
    HOME="$PINHOME" bash -c 'unset -f go_gate go_trust_gate _go_gate_verify go_mac 2>/dev/null || true; . "$1"; "$2" "$3" "$4" "$5" "$6"' _ "$GO_GATE_SRC" "$1" "$2" "$3" "$G9" "$4"
}
g9_go() {  # <id> <sha> <nwo> [<mac-id>] - write a GO file for <id>, signed for <mac-id>
    printf 'head=%s\nmac=%s\n' "$2" "$(pin_mac go_mac "${4:-$1}" "$2" "$3")" > "$G9/.locks/go/$1.$2"
}
# 9a. A br-* id signs under its own domain: HMAC over himmel-go-br-v1|<nwo>|<id>|<sha>.
want=$(printf 'himmel-go-br-v1|local:/r/.git|br-x|%s' "$PINSHA" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(cat "$PINHOME/.config/himmel/go-hmac.key")" | awk '{print $NF}')
[ "$(pin_mac go_mac br-x "$PINSHA" local:/r/.git)" = "$want" ] || fail "9a: go_mac br-x is not HMAC over himmel-go-br-v1|<nwo>|<id>|<sha>"
want=$(printf 'himmel-go-br-trust-v1|o/r|br-x|%s|rev-1' "$PINSHA" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(cat "$PINHOME/.config/himmel/go-hmac.key")" | awk '{print $NF}')
[ "$(pin_mac go_mac br-x "$PINSHA" o/r rev-1)" = "$want" ] || fail "9a: trust go_mac br-x is not HMAC over himmel-go-br-trust-v1|..."
# 9b. A GO for br-x does not satisfy PR 7, nor the reverse; each passes for itself.
g9_go 7 "$PINSHA" o/r br-x
rc=0; g9_gate go_gate 7 "$PINSHA" o/r >/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "9b: a GO signed for br-x satisfied PR 7 (rc=$rc)"
g9_go br-x "$PINSHA" o/r 7
rc=0; g9_gate go_gate br-x "$PINSHA" o/r >/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "9b: a GO signed for PR 7 satisfied br-x (rc=$rc)"
g9_go 7 "$PINSHA" o/r; g9_go br-x "$PINSHA" local:/r/.git
rc=0; g9_gate go_gate 7 "$PINSHA" o/r >/dev/null || rc=$?
[ "$rc" -eq 0 ] || fail "9b: PR 7's own GO was refused (rc=$rc)"
rc=0; out=$(g9_gate go_gate br-x "$PINSHA" local:/r/.git) || rc=$?
[ "$rc" -eq 0 ] || fail "9b: br-x's own GO was refused (rc=$rc): $out"
# 9c. Ids outside ^([0-9]+|br-[a-z0-9._-]+)$ refuse before any file is read.
for bad in "" "br-" "br-X" "../7" "7x" "br-a/b" "-7"; do
    rc=0; out=$(g9_gate go_gate "$bad" "$PINSHA" o/r) || rc=$?
    case "$rc:$out" in "2:change id '$bad' is neither"*) ;; *) fail "9c: id '$bad' was not refused as an id (rc=$rc): $out" ;; esac
done
# 9d. A numeric refusal is byte-identical to the pre-forge-mode behaviour.
rc=0; out=$(g9_gate go_gate 8 "$PINSHA" o/r) || rc=$?
[ "$rc:$out" = "2:PR #8 at $PINSHA has no console GO ($G9/.locks/go/8.$PINSHA) — this is a console-spawned leg; send READY to your console and wait for GO; a GO for an older head is stale, never reuse it." ] \
    || fail "9d: the numeric no-GO refusal changed: $out"
rc=0; out=$(g9_gate go_gate br-y "$PINSHA" o/r) || rc=$?
case "$rc:$out" in "2:change br-y at $PINSHA has no console GO"*) ;; *) fail "9d: br-y's refusal does not name the change (rc=$rc): $out" ;; esac

# 9e. trust_path_check for a local-git change reads the list and files from git.
lg() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=t -c user.email=t@t "$@"; }
tpc() {  # <repo-id> <id> <sha> <anchor> -> trust_path_check's rc:stdout
    local o r=0
    o=$(bash -c '. "$1"; shift; trust_path_check "$@"' _ "$GO_GATE_SRC" "$1" "$2" "$3" main "$4") || r=$?
    printf '%s:%s' "$r" "$o"
}
LR="$ROOT/lgrepo"; mkdir -p "$LR/scripts/ci"
lg -C "$LR" init -q -b main
printf '# trust\n^scripts/ci/\n' > "$LR/scripts/ci/ci-trust-paths.txt"
lg -C "$LR" add -A && lg -C "$LR" commit -q -m list
LRID="local:$(cd "$LR/.git" && pwd -P)"
lg -C "$LR" checkout -q -b feat/hit
printf 'x\n' > "$LR/scripts/ci/new.sh"; printf '^nothing$\n' > "$LR/scripts/ci/ci-trust-paths.txt"
lg -C "$LR" add -A && lg -C "$LR" commit -q -m hit
HIT=$(lg -C "$LR" rev-parse HEAD)
lg -C "$LR" checkout -q -b feat/clean main
printf 'y\n' > "$LR/README"; lg -C "$LR" add -A && lg -C "$LR" commit -q -m clean
CLEAN=$(lg -C "$LR" rev-parse HEAD)
lg -C "$LR" checkout -q -b feat/uni main
printf 'u\n' > "$LR/scripts/ci/$(printf 'caf\303\251').sh"; lg -C "$LR" add -A && lg -C "$LR" commit -q -m uni
UNI=$(lg -C "$LR" rev-parse HEAD)
lg -C "$LR" checkout -q main
got=$(tpc "$LRID" br-feat-hit "$HIT" "$LR")
[ "$got" = "0:hit scripts/ci/ci-trust-paths.txt" ] || fail "9e: a local-git change touching a trust path (the branch's own list edit ignored) is not a hit: $got"
got=$(tpc "$LRID" br-feat-clean "$CLEAN" "$LR")
[ "$got" = "0:none" ] || fail "9e: a local-git change touching no trust path is not none: $got"
got=$(tpc "$LRID" br-feat-uni "$UNI" "$LR")
[ "$got" = "0:hit scripts/ci/$(printf 'caf\303\251').sh" ] || fail "9e: a non-ASCII trust-path file (git's quoted path) is not a hit: $got"
got=$(tpc o/r br-feat-hit "$HIT" "$LR")
case "$got" in "2:list "*) ;; *) fail "9e: a br id with a non-local repo id was not refused: $got" ;; esac
got=$(tpc "$LRID" br-feat-hit "$(printf '%040d' 9)" "$LR")
case "$got" in "2:files "*) ;; *) fail "9e: a head that is not a commit in the repo was not refused: $got" ;; esac
# A path with a newline in it must not split into lines that each miss an
# end-anchored pattern: it refuses instead.
LN="$ROOT/lgnl"; mkdir -p "$LN/scripts/ci"
lg -C "$LN" init -q -b main
printf '^scripts/ci/.*[.]sh$\n' > "$LN/scripts/ci/ci-trust-paths.txt"
lg -C "$LN" add -A && lg -C "$LN" commit -q -m list
LNID="local:$(cd "$LN/.git" && pwd -P)"
lg -C "$LN" checkout -q -b feat/nl
printf 'n\n' > "$LN/scripts/ci/evil
.sh"; lg -C "$LN" add -A && lg -C "$LN" commit -q -m nl
NL=$(lg -C "$LN" rev-parse HEAD)
lg -C "$LN" checkout -q main
got=$(tpc "$LNID" br-feat-nl "$NL" "$LN")
case "$got" in "2:files "*) ;; *) fail "9e: a changed path holding a newline was not refused: $got" ;; esac
# 9f. A hit needs the anchor to hold main's tip: an older anchor refuses.
lg -C "$LR" worktree add -q --detach "$ROOT/lgold" "$(lg -C "$LR" rev-parse main)"
printf 'z\n' > "$LR/z"; lg -C "$LR" add -A && lg -C "$LR" commit -q -m moved
got=$(tpc "$LRID" br-feat-hit "$HIT" "$ROOT/lgold")
case "$got" in "2:anchor "*) ;; *) fail "9f: a hit with an anchor behind main was not refused: $got" ;; esac
# 9g. A hit refuses without a judge GO: go_trust_gate wants a trust-reviewed br GO.
g9_go br-feat-hit "$HIT" "$LRID"
rc=0; out=$(g9_gate go_trust_gate br-feat-hit "$HIT" "$LRID") || rc=$?
case "$rc:$out" in "2:change br-feat-hit at $HIT touches a CI trust path"*) ;; *) fail "9g: an ordinary GO passed the trust gate for br-feat-hit (rc=$rc): $out" ;; esac
printf 'head=%s\ntrust-reviewed=judge-1\nmac=%s\n' "$HIT" "$(pin_mac go_mac br-feat-hit "$HIT" "$LRID" judge-1)" > "$G9/.locks/go/br-feat-hit.$HIT"
rc=0; out=$(g9_gate go_trust_gate br-feat-hit "$HIT" "$LRID") || rc=$?
[ "$rc:$out" = "0:judge-1" ] || fail "9g: a trust-reviewed br GO was refused (rc=$rc): $out"
# 9h. A missing list: not-adopted in a repo other than the anchor's, refused in the anchor's own.
LM="$ROOT/lgmissing"; mkdir -p "$LM"; lg -C "$LM" init -q -b main
printf 'a\n' > "$LM/a"; lg -C "$LM" add -A && lg -C "$LM" commit -q -m a
lg -C "$LM" checkout -q -b feat/m; printf 'b\n' > "$LM/b"; lg -C "$LM" add -A && lg -C "$LM" commit -q -m b
MH=$(lg -C "$LM" rev-parse HEAD); LMID="local:$(cd "$LM/.git" && pwd -P)"
got=$(tpc "$LMID" br-feat-m "$MH" "$LR")
[ "$got" = "0:not-adopted" ] || fail "9h: a missing list in another repo is not not-adopted: $got"
got=$(tpc "$LMID" br-feat-m "$MH" "$LM")
case "$got" in "2:list "*) ;; *) fail "9h: a missing list in the anchor's own repo was not refused: $got" ;; esac
# 9i. github, unchanged: a 404 list is not-adopted only when the anchor's origin names another repo.
printf '#!/usr/bin/env bash\necho "gh: Not Found (HTTP 404)" >&2\nexit 1\n' > "$ROOT/gh404"; chmod +x "$ROOT/gh404"
GA="$ROOT/ghanchor"; mkdir -p "$GA"; lg -C "$GA" init -q
lg -C "$GA" remote add origin https://github.com/other/repo.git
got=$(GH="$ROOT/gh404" tpc o/r 7 "$PINSHA" "$GA")
[ "$got" = "0:not-adopted" ] || fail "9i: github 404 with another repo's anchor is not not-adopted: $got"
lg -C "$GA" remote set-url origin https://github.com/o/r.git
got=$(GH="$ROOT/gh404" tpc o/r 7 "$PINSHA" "$GA")
[ "$got" = "2:list scripts/ci/ci-trust-paths.txt is missing on o/r@main, and the harness anchor's origin does not prove it is another repo" ] \
    || fail "9i: github 404 with this repo's anchor was not refused as before: $got"

# 9j. scripts/lib/fixtures/ready-lines.tsv: parse_ready_line and fleet.mjs agree with the fixture.
TSV="$HERE/fixtures/ready-lines.tsv"
want=$(grep -v '^#' "$TSV" | grep -v '^$' | cut -f2-4)
shell_out=$(grep -v '^#' "$TSV" | grep -v '^$' | cut -f1 | while IFS= read -r l; do
    bash -c '. "$1"; parse_ready_line "$2"' _ "$GO_GATE_SRC" "$l" || printf -- '-\t\t\n'
done | sed "s/$(printf '\t')*\$//")
[ "$shell_out" = "$want" ] || fail "9j: parse_ready_line disagrees with ready-lines.tsv: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$shell_out") | tr '\n' ' ')"
if command -v node >/dev/null 2>&1; then
    node_out=$(node "$HERE/../handover/console-kit/fleet.mjs" --ready-lines "$TSV" | sed "s/$(printf '\t')*\$//")
    [ "$node_out" = "$want" ] || fail "9j: fleet.mjs disagrees with ready-lines.tsv: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$node_out") | tr '\n' ' ')"
else
    fail "9j: node is missing, so fleet.mjs's parser cannot be checked"
fi

# 10. The fork gate: go_adapter_entry reads the harness repo from the
# anchor's origin remote (never gh's default-repo answer), go_fork_ready needs a
# registered, settled check, and the case mapping is pinned to the C locale.
FG="$ROOT/fg"; mkdir -p "$FG/bin"
cat > "$FG/bin/gh" <<'STUB'
#!/usr/bin/env bash
# default repo = the fork (what gh's default-repo setting could resolve to)
case "$1 $2" in
    "repo view") case "$*" in *defaultBranchRef*) printf 'main' ;; *) printf 'yotamleo/qmd' ;; esac ;;
    "api repos/"*) case "$2" in "repos/$FG_ORIGIN/contents/"*) printf '%s' '[{"nwo":"yotamleo/qmd","himmel_branch":"himmel/pin","merge_allowed":true}]' ;; *) exit 1 ;; esac ;;
    "pr view") cat "$FG_PRVIEW" ;;
    "api graphql") printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}\n' ;;
    *) exit 91 ;;
esac
STUB
chmod +x "$FG/bin/gh"
export FG_ORIGIN="owner/Himmel" FG_PRVIEW="$FG/prview.json"
fg_anchor() {  # <name> <origin url or ''> -> a git checkout whose origin is that url
    git init -q "$FG/$1" && { [ -z "$2" ] || git -C "$FG/$1" remote add origin "$2"; }
}
fg_anchor https  https://github.com/owner/Himmel.git
fg_anchor ssh    git@github.com:owner/Himmel.git
fg_anchor sshurl ssh://git@github.com/owner/Himmel
fg_anchor junk   'not a url'
fg_anchor none   ''
for a in https ssh sshurl; do
    got=$(GH="$FG/bin/gh" bash -c '. "$1"; go_adapter_entry "$2" yotamleo/qmd' _ "$GO_GATE_SRC" "$FG/$a") || got="rc"
    [ "$got" = himmel/pin ] || fail "10a: origin form [$a] with gh defaulting to the fork: expected the fork's branch, got [$got]"
done
for tgt in owner/Himmel owner/himmel OWNER/HIMMEL; do
    rc=0; got=$(GH="$FG/bin/gh" bash -c '. "$1"; go_adapter_entry "$2" "$3"' _ "$GO_GATE_SRC" "$FG/https" "$tgt") || rc=$?
    { [ "$rc" = 2 ] && printf '%s' "$got" | grep -q 'harness repo itself'; } || fail "10b: the harness repo [$tgt] must refuse as itself (rc=$rc, out=[$got])"
done
for a in junk none; do
    rc=0; got=$(GH="$FG/bin/gh" bash -c '. "$1"; go_adapter_entry "$2" yotamleo/qmd' _ "$GO_GATE_SRC" "$FG/$a") || rc=$?
    { [ "$rc" = 2 ] && printf '%s' "$got" | grep -q 'origin remote'; } || fail "10c: anchor origin [$a] must refuse fail-closed (rc=$rc, out=[$got])"
done
# 10d. the case mapping holds under a non-C locale (the Turkish dotless-i trap needs tr_TR, which is
# not installed here; the structural row below pins every call site, this one proves a real
# non-C locale still compares equal).
if locale -a 2>/dev/null | grep -qi '^de_DE\.utf-\?8$'; then
    rc=0; LC_ALL=de_DE.utf8 GH="$FG/bin/gh" bash -c '. "$1"; go_adapter_entry "$2" OWNER/HIMMEL' _ "$GO_GATE_SRC" "$FG/https" >/dev/null || rc=$?
    [ "$rc" = 2 ] || fail "10d: an uppercase nwo must compare equal to the lowercase origin under de_DE (rc=$rc)"
fi
# 10e. structural: no tr case mapping or lowercase-bucket sed in go-gate.sh runs without the C-locale prefix.
unpinned=$(grep -nE "(^|[^_A-Za-z=])tr '\[:(upper|lower):\]'" "$GO_GATE_SRC" | grep -v 'LC_ALL=C tr' || true)
[ -z "$unpinned" ] || fail "10e: tr case mapping without LC_ALL=C: $unpinned"
# 10f. go_fork_ready: a registered, settled check is required on top of CLEAN.
fr() { printf '{"mergeStateStatus":"CLEAN","statusCheckRollup":%s}\n' "$1" > "$FG_PRVIEW"; GH="$FG/bin/gh" bash -c '. "$1"; go_fork_ready o/r 5' _ "$GO_GATE_SRC"; }
rc=0; out=$(fr '[{"status":"COMPLETED","conclusion":"SUCCESS"}]') || rc=$?
[ "$rc" = 0 ] || fail "10f: a completed passing check must be ready (rc=$rc, out=[$out])"
rc=0; out=$(fr '[{"state":"SUCCESS"}]') || rc=$?
[ "$rc" = 0 ] || fail "10f: a SUCCESS status context must be ready (rc=$rc, out=[$out])"
for chk in '[]' 'null' '[{"status":"IN_PROGRESS"}]' '[{"status":"QUEUED"}]' '[{"state":"PENDING"}]' '[{"state":"EXPECTED"}]' '[{}]' '[{"status":null}]' '{"a":1}' '["SUCCESS"]' '[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"IN_PROGRESS"}]'; do
    rc=0; out=$(fr "$chk") || rc=$?
    { [ "$rc" = 2 ] && printf '%s' "$out" | grep -qi 'check'; } || fail "10f: checks [$chk] must refuse naming the checks (rc=$rc, out=[$out])"
done
printf '{"mergeStateStatus":"CLEAN"}\n' > "$FG_PRVIEW"
rc=0; out=$(GH="$FG/bin/gh" bash -c '. "$1"; go_fork_ready o/r 5' _ "$GO_GATE_SRC") || rc=$?
[ "$rc" = 2 ] || fail "10f: an answer with no statusCheckRollup field must refuse (rc=$rc)"

# 11. The real scripts/ci/ci-trust-paths.txt flags a path under each audited guard line and the two hooks.json files, and passes an unlisted file.
TL="$ROOT/tprepo"; mkdir -p "$TL/scripts/ci"
lg -C "$TL" init -q -b main
cp "$HERE/../ci/ci-trust-paths.txt" "$TL/scripts/ci/ci-trust-paths.txt"
lg -C "$TL" add -A && lg -C "$TL" commit -q -m list
TLID="local:$(cd "$TL/.git" && pwd -P)"
n=0
for tp in scripts/hooks/block-x.sh scripts/hooks/read-clamp.sh scripts/hooks/check-cr-x.sh \
    scripts/handover/console-kit/verdict-go.sh scripts/cr/write-verdicts.sh \
    .codex/hooks.json marketplace/plugins/p/hooks/hooks.json; do
    n=$((n + 1))
    lg -C "$TL" checkout -q -b "feat/tp$n" main
    mkdir -p "$TL/$(dirname "$tp")"; printf 'x\n' > "$TL/$tp"
    lg -C "$TL" add -A && lg -C "$TL" commit -q -m "tp$n"
    got=$(tpc "$TLID" "br-feat-tp$n" "$(lg -C "$TL" rev-parse HEAD)" "$TL")
    [ "$got" = "0:hit $tp" ] || fail "11: $tp is not a trust-path hit: $got"
done
lg -C "$TL" checkout -q -b feat/tpmiss main
printf 'x\n' > "$TL/docs-unlisted.md"; mkdir -p "$TL/scripts/hooks"; printf 'x\n' > "$TL/scripts/hooks/test-block-x.sh"
lg -C "$TL" add -A && lg -C "$TL" commit -q -m miss
got=$(tpc "$TLID" br-feat-tpmiss "$(lg -C "$TL" rev-parse HEAD)" "$TL")
[ "$got" = "0:none" ] || fail "11: unlisted files are not none: $got"

if [ "$FAIL" -eq 0 ]; then
    echo "PASS: test-go-gate.sh"
    exit 0
fi
exit 1
