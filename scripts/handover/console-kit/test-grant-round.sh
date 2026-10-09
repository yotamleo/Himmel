#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check(), as in test-write-verdict.sh
# shellcheck disable=SC2012  # ls over fixture dirs whose names the suite chose
# shellcheck disable=SC2031  # root is set once in the main shell; the scope subshell only reads
# scripts/handover/console-kit/test-grant-round.sh - suite for grant-round.sh
# (HIMMEL-5058), the console's own one-round grant on a persisted judge record:
#   1. no record for the qid refuses; a record for another head refuses; a
#      hand-written (unsigned) record refuses; a record naming another PR or
#      branch refuses - each leaves the counter and the consumption file alone
#   2. a leg caller (HIMMEL_CONSOLE_LEG) and a relay caller refuse, even with a
#      valid record
#   3. a PR whose live head is not NEW_HEAD, a fork PR and a closed PR refuse
#   4. a branch that has not reached the cap (round < 3) or has no .head
#      refuses, and does not consume the qid
#   5. a valid record grants exactly one round: .round drops to 2, the qid is
#      recorded in <branch>.verdicts (the file review-round.sh scans), the old
#      counter is backed up, and one audit line is written
#   6. the same qid a second time refuses and changes nothing
#
# Hermetic: a temp git repo holds the review-round state, a stub gh answers the
# PR lookup, a scratch HANDOVER_DIR and HOME hold the verdict records and key.
# Platform guard: POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/grant-round.sh"
WRITER="$HERE/write-verdict.sh"
REPO="$(cd "$HERE/../../.." && pwd)"
SHA_A=0123456789abcdef0123456789abcdef01234567
SHA_B=89abcdef0123456789abcdef0123456789abcdef
BRANCH=feat/x-grant

tmp="$(mktemp -d "${TMPDIR:-/tmp}/grant-round-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
scratch="/tmp/claude-$(id -u)"
[ -d "$scratch" ] || mkdir -m 700 "$scratch" || { echo "FAIL: cannot create $scratch" >&2; exit 1; }
evd="$(mktemp -d "$scratch/grant-round-test.XXXXXX")" || { echo "FAIL: mktemp -d in $scratch failed" >&2; rm -rf "$tmp"; exit 1; }
trap 'rm -rf "$tmp" "$evd"' EXIT
tmp="$(cd "$tmp" && pwd -P)"
root="$tmp/root"
mkdir -p "$root" "$tmp/home/.config/himmel" || exit 1
printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$tmp/home/.config/himmel/go-hmac.key"
export HOME="$tmp/home" USER_SLUG=tuser
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)) ;; esac; }

# The repo whose common dir holds the review-round state.
prim="$tmp/prim"
git init -q "$prim" || exit 1
state="$(git -C "$prim" rev-parse --path-format=absolute --git-common-dir)/cr-review-rounds"
mkdir -p "$state" || exit 1

# gh stub: prints the JSON in $GH_JSON.
cat > "$tmp/gh" <<'EOF'
#!/usr/bin/env bash
cat "$GH_JSON"
EOF
chmod +x "$tmp/gh"
gh_json() { # <head> [cross] [state]
    printf '{"headRefName":"%s","headRefOid":"%s","isCrossRepository":%s,"state":"%s"}\n' \
        "$BRANCH" "$1" "${2:-false}" "${3:-OPEN}" > "$tmp/pr.json"
}
export GH_JSON="$tmp/pr.json"

# Run the grant with the given extra env words, args in GR_ARGS.
run() { env -u HIMMEL_CONSOLE_LEG -u HIMMEL_CONSOLE_JUDGE -u HIMMEL_CONSOLE_RELAY \
    HANDOVER_DIR="$root" CLAUDE_CODE_SESSION_ID=sess-5058 \
    GRANT_ROUND_GH="$tmp/gh" GRANT_ROUND_PRIMARY="$prim" "$@" bash "$SCRIPT" "${GR_ARGS[@]}"; }

printf 'class: other\n\n## Evidence checked\n\n- read the diff\n' > "$evd/ev.md"
wv() {
    env -u HIMMEL_CONSOLE_LEG -u HIMMEL_CONSOLE_JUDGE -u HIMMEL_CONSOLE_RELAY \
        HANDOVER_DIR="$root" CLAUDE_CODE_SESSION_ID=sess-judge \
        bash "$WRITER" "$@"
}
scope=$(
    # shellcheck source=scripts/lib/go-gate.sh
    # shellcheck disable=SC1091
    . "$REPO/scripts/lib/go-gate.sh" && go_verdict_scope "$REPO"
) || { echo "FAIL: cannot resolve the verdict scope"; exit 1; }
vdir="$root/$scope/verdicts"

reset_state() { # <round>
    mkdir -p "$state/feat"
    rm -f "$state"/feat/* "$state/grant-round.audit"
    printf '%s\n' "$1" > "$state/$BRANCH.round"
    printf '%s\n' "$SHA_B" > "$state/$BRANCH.head"
}
snap_state() {
    local f
    for f in "$state"/feat/*; do
        case "$f" in *.bak-*) continue ;; esac
        printf '%s=%s\n' "${f##*/}" "$(cat "$f")"
    done
}

gh_json "$SHA_A"
reset_state 3
# state files live at $state/feat/x-grant.* (branch has a slash)
before="$(snap_state)"

# --- 1. refusals on the record ---------------------------------------------
GR_ARGS=(501 "$SHA_A" qnone)
rc=0; out=$(run 2>&1) || rc=$?
check "no record refuses" "$rc" 4
check "no record changes nothing" "$(snap_state)" "$before"

wv qother GO "$SHA_B" --pr 501 --branch "$BRANCH" --evidence-file "$evd/ev.md" >/dev/null 2>&1 || { echo "FAIL: cannot write qother"; fails=$((fails+1)); }
GR_ARGS=(501 "$SHA_A" qother)
rc=0; out=$(run 2>&1) || rc=$?
check "record for another head refuses" "$rc" 4
check "another head changes nothing" "$(snap_state)" "$before"

mkdir -p "$vdir/qhand"
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
printf '# VERDICT qhand - judge\n\nwriter-session: x\nwritten-at: 2026-10-09T00:00:00Z\n\n## Verdict\n\n**GO** for head `%s`.\n\npr: 501\n' "$SHA_A" > "$vdir/qhand/judge.md"
GR_ARGS=(501 "$SHA_A" qhand)
rc=0; out=$(run 2>&1) || rc=$?
check "unsigned record refuses" "$rc" 4

wv qpr GO "$SHA_A" --pr 777 --evidence-file "$evd/ev.md" >/dev/null 2>&1 || { echo "FAIL: cannot write qpr"; fails=$((fails+1)); }
GR_ARGS=(501 "$SHA_A" qpr)
rc=0; out=$(run 2>&1) || rc=$?
check "record naming another PR refuses" "$rc" 4

wv qbr GO "$SHA_A" --pr 501 --branch other/branch --evidence-file "$evd/ev.md" >/dev/null 2>&1 || { echo "FAIL: cannot write qbr"; fails=$((fails+1)); }
GR_ARGS=(501 "$SHA_A" qbr)
rc=0; out=$(run 2>&1) || rc=$?
check "record naming another branch refuses" "$rc" 4
check "bad records change nothing" "$(snap_state)" "$before"

# --- valid records for the rest ---------------------------------------------
wv qgood GO "$SHA_A" --pr 501 --branch "$BRANCH" --evidence-file "$evd/ev.md" >/dev/null 2>&1 || { echo "FAIL: cannot write qgood"; fails=$((fails+1)); }
GR_ARGS=(501 "$SHA_A" qgood)

# --- 2. leg / relay callers --------------------------------------------------
rc=0; out=$(run HIMMEL_CONSOLE_LEG=1 2>&1) || rc=$?
check "leg caller refuses" "$rc" 3
contains "leg refusal says why" "$out" "leg"
rc=0; out=$(run HIMMEL_CONSOLE_RELAY=1 2>&1) || rc=$?
check "relay caller refuses" "$rc" 3
check "leg/relay change nothing" "$(snap_state)" "$before"

# --- 3. PR shape --------------------------------------------------------------
gh_json "$SHA_B"
rc=0; out=$(run 2>&1) || rc=$?
check "PR head not NEW_HEAD refuses" "$rc" 15
gh_json "$SHA_A" true
rc=0; out=$(run 2>&1) || rc=$?
check "fork PR refuses" "$rc" 12
gh_json "$SHA_A" false CLOSED
rc=0; out=$(run 2>&1) || rc=$?
check "closed PR refuses" "$rc" 12
check "PR-shape refusals change nothing" "$(snap_state)" "$before"
gh_json "$SHA_A"

# --- 4. counter state ---------------------------------------------------------
reset_state 2
b2="$(snap_state)"
rc=0; out=$(run 2>&1) || rc=$?
check "round below the cap refuses" "$rc" 12
check "below-cap refusal changes nothing" "$(snap_state)" "$b2"
reset_state 3
rm -f "$state/$BRANCH.head"
rc=0; out=$(run 2>&1) || rc=$?
check "missing .head refuses" "$rc" 12
reset_state 3

# --- 5. a valid record grants exactly one round ------------------------------
rc=0; out=$(run 2>&1) || rc=$?
check "valid record grants rc 0" "$rc" 0
check "round drops to 2 (one round left before the cap)" "$(cat "$state/$BRANCH.round")" 2
contains "qid recorded where review-round scans" "$(cat "$state/$BRANCH.verdicts")" " qgood/judge"
check "the .head seed is untouched" "$(cat "$state/$BRANCH.head")" "$SHA_B"
check "old counter backed up" "$(ls "$state"/feat/x-grant.round.bak-* 2>/dev/null | wc -l | tr -d ' ')" 1
check "one audit line" "$(wc -l < "$state/grant-round.audit" | tr -d ' ')" 1
contains "audit names pr, head and record" "$(cat "$state/grant-round.audit")" "pr=501"
contains "audit names the record" "$(cat "$state/grant-round.audit")" "qgood/judge"

# --- 6. one record buys one round --------------------------------------------
after="$(snap_state)"
printf '3\n' > "$state/$BRANCH.round"
rc=0; out=$(run 2>&1) || rc=$?
check "second call with the same qid refuses" "$rc" 14
check "consumed qid leaves the counter alone" "$(cat "$state/$BRANCH.round")" 3
check "consumed qid adds no consumption line" "$(wc -l < "$state/$BRANCH.verdicts" | tr -d ' ')" 1
: "$after"

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASS"; exit 0; fi
echo "FAILED: $fails"
exit 1
