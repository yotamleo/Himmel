#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-append-results.sh
# shellcheck disable=SC2012  # ls over fixture dirs whose names the suite chose
# shellcheck disable=SC2030,SC2031  # verdict_rc's subshell is deliberate: its export must not leak
# scripts/handover/console-kit/test-write-verdict.sh - suite for
# write-verdict.sh (HIMMEL-4689), the sanctioned writer a console-judge call
# uses for its verdict file:
#   1. a GO verdict it writes is accepted by go-gate.sh's own go_trust_verdict
#      (the parser go.sh --trust-reviewed calls), read-only
#   2. a NO-GO verdict blocks that parser
#   3. bad qid / short or uppercase head / bad answer / missing evidence are
#      refused with nothing written
#   4. a conflicting re-write (same head, other answer) is refused, the file
#      unchanged; the same answer again, or another head, is accepted
#   5. a symlinked verdicts/<qid>/ or target file is refused
#   6. an unparsed verdict beside it is refused (go.sh would refuse anyway);
#      a held qid lock refuses, so two writers cannot both pass the scan
#   7. the writer's session is stamped in the file
#   8. a console leg (HIMMEL_CONSOLE_LEG, not a judge) is refused
#   9. the writer's command text passes the live Bash guards (each guard
#      script fed a PreToolUse payload, as their own suites do), and the
#      heredoc spelling it replaces is denied (the control)
#
# Hermetic: temp dir only; the guard scripts are run, never edited.
# Platform guard: POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/write-verdict.sh"
REPO="$(cd "$HERE/../../.." && pwd)"
SHA_A=0123456789abcdef0123456789abcdef01234567
SHA_B=89abcdef0123456789abcdef0123456789abcdef

tmp="$(mktemp -d "${TMPDIR:-/tmp}/write-verdict-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"
root="$tmp/root"
mkdir -p "$root" || exit 1
export USER_SLUG=tuser
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)) ;; esac; }

# The writer under a judge call's environment: not a leg, a fixed root/user.
wv() {
    env -u HIMMEL_CONSOLE_LEG -u HIMMEL_CONSOLE_JUDGE -u HIMMEL_CONSOLE_RELAY \
        HANDOVER_DIR="$root" USER_SLUG=tuser CLAUDE_CODE_SESSION_ID=sess-4689 \
        bash "$SCRIPT" "$@"
}
# go_trust_verdict, sourced from the real lib in a subshell, read-only.
verdict_rc() {
    (
        unset HIMMEL_CONSOLE_LEG
        export HANDOVER_DIR="$root"
        # shellcheck source=scripts/lib/handover-path.sh
        # shellcheck disable=SC1091
        . "$REPO/scripts/lib/handover-path.sh" || exit 9
        # shellcheck source=scripts/lib/go-gate.sh
        # shellcheck disable=SC1091
        . "$REPO/scripts/lib/go-gate.sh" || exit 9
        r=$(go_resolve_root "$REPO") || exit 8
        go_trust_verdict "$r" "$1" "$2" "$REPO" >/dev/null
    )
}

ev="$tmp/evidence.md"
printf '## Evidence checked\n\n- 1. read the parser\n- the hook never runs unset\n' > "$ev"
# The <user>/<bucket> go.sh reads for this checkout (the bucket follows the
# primary checkout's directory name, so it is derived, never hardcoded).
scope=$(
    # shellcheck source=scripts/lib/go-gate.sh
    # shellcheck disable=SC1091
    . "$REPO/scripts/lib/go-gate.sh" && go_verdict_scope "$REPO"
) || { echo "FAIL: cannot resolve the verdict scope"; exit 1; }
scope_dir="$root/$scope/verdicts"

# --- 1. GO accepted by go.sh's own parser ---------------------------------
rc=0; out=$(wv q1 GO "$SHA_A" --evidence-file "$ev" 2>&1) || rc=$?
check "1: GO write rc 0" "$rc" 0
f1="$scope_dir/q1/judge.md"
check "1: written at verdicts/<qid>/judge.md" "$([ -f "$f1" ] && echo yes)" yes
contains "1: prints the path written" "$out" "$f1"
rc=0; verdict_rc q1 "$SHA_A" || rc=$?
check "1: go_trust_verdict accepts the GO" "$rc" 0
rc=0; verdict_rc q1 "$SHA_B" || rc=$?
check "1: go_trust_verdict refuses another head" "$rc" 2
contains "1: evidence carried verbatim" "$(cat "$f1")" "- the hook never runs unset"

# --- 2. NO-GO blocks ------------------------------------------------------
rc=0; wv q2 NO-GO "$SHA_A" --evidence-file "$ev" >/dev/null 2>&1 || rc=$?
check "2: NO-GO write rc 0" "$rc" 0
rc=0; verdict_rc q2 "$SHA_A" || rc=$?
check "2: go_trust_verdict refuses on the NO-GO" "$rc" 2

# --- 3. validation refusals ----------------------------------------------
for bad in '../q' '.q' 'a/b' '' '-q' 'q q'; do
    rc=0; wv "$bad" GO "$SHA_A" --evidence-file "$ev" >/dev/null 2>&1 || rc=$?
    check "3: qid '$bad' refused rc 2" "$rc" 2
done
check "3: no escaped write beside the root" "$(ls "$root/$scope" 2>/dev/null | tr '\n' ' ')" "verdicts "
check "3: no stray verdict dirs" "$(ls "$scope_dir" | tr '\n' ' ')" "q1 q2 "
for bad in "${SHA_A%?}" "$(printf '%s' "$SHA_A" | tr a-f A-F)" "${SHA_A}0" "g${SHA_A#?}"; do
    rc=0; wv q3 GO "$bad" --evidence-file "$ev" >/dev/null 2>&1 || rc=$?
    check "3: head '$bad' refused rc 2" "$rc" 2
done
for bad in go Go NOGO 'GO.' ''; do
    rc=0; wv q3 "$bad" "$SHA_A" --evidence-file "$ev" >/dev/null 2>&1 || rc=$?
    check "3: answer '$bad' refused rc 2" "$rc" 2
done
rc=0; wv q3 GO "$SHA_A" --evidence-file "$tmp/missing.md" >/dev/null 2>&1 || rc=$?
check "3: missing evidence refused rc 2" "$rc" 2
: > "$tmp/empty.md"
rc=0; wv q3 GO "$SHA_A" --evidence-file "$tmp/empty.md" >/dev/null 2>&1 || rc=$?
check "3: empty evidence refused rc 2" "$rc" 2
rc=0; wv q3 GO "$SHA_A" >/dev/null 2>&1 || rc=$?
check "3: no --evidence-file refused rc 2" "$rc" 2
rc=0; wv q3 GO "$SHA_A" --evidence-file "$ev" --judge '../x' >/dev/null 2>&1 || rc=$?
check "3: judge name with a path refused rc 2" "$rc" 2
check "3: nothing written for q3" "$([ -e "$scope_dir/q3" ] && echo yes || echo no)" no

# --- 4. conflicting re-write ---------------------------------------------
before=$(cat "$f1")
rc=0; out=$(wv q1 NO-GO "$SHA_A" --evidence-file "$ev" 2>&1) || rc=$?
check "4: NO-GO over a GO for the same head refused rc 4" "$rc" 4
check "4: the GO file is unchanged" "$(cat "$f1")" "$before"
rc=0; wv q1 NO-GO "$SHA_A" --evidence-file "$ev" --judge other-judge >/dev/null 2>&1 || rc=$?
check "4: a second judge file contradicting it is refused rc 4" "$rc" 4
rc=0; wv q1 GO "$SHA_A" --evidence-file "$ev" >/dev/null 2>&1 || rc=$?
check "4: the same answer again is accepted" "$rc" 0
rc=0; wv q1 NO-GO "$SHA_B" --evidence-file "$ev" --judge round2 >/dev/null 2>&1 || rc=$?
check "4: another head is accepted" "$rc" 0
rc=0; verdict_rc q1 "$SHA_A" || rc=$?
check "4: the head-A GO still stands" "$rc" 0

# --- 5. symlinks ----------------------------------------------------------
mkdir -p "$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$scope_dir/q5"
rc=0; wv q5 GO "$SHA_A" --evidence-file "$ev" >/dev/null 2>&1 || rc=$?
check "5: symlinked verdicts/<qid>/ refused rc 4" "$rc" 4
check "5: nothing written through it" "$(ls "$tmp/elsewhere" | wc -l | tr -d ' ')" 0
mkdir -p "$scope_dir/q6"
ln -s "$tmp/elsewhere/target.md" "$scope_dir/q6/judge.md"
rc=0; wv q6 GO "$SHA_A" --evidence-file "$ev" >/dev/null 2>&1 || rc=$?
check "5: symlinked target file refused rc 4" "$rc" 4
check "5: symlink target not created" "$([ -e "$tmp/elsewhere/target.md" ] && echo yes || echo no)" no

# --- 6. unparsed verdict beside it ---------------------------------------
mkdir -p "$scope_dir/q7"
printf '## Verdict\n\nlooks fine\n' > "$scope_dir/q7/hand.md"
rc=0; wv q7 GO "$SHA_A" --evidence-file "$ev" >/dev/null 2>&1 || rc=$?
check "6: unparsed sibling refused rc 4" "$rc" 4

# --- 6b. the scan and the publish hold the qid's lock --------------------
check "6b: a finished write leaves no lock behind" "$([ -e "$scope_dir/q1/.write-verdict.lock" ] && echo yes || echo no)" no
mkdir -p "$scope_dir/q9/.write-verdict.lock"
rc=0; wv q9 NO-GO "$SHA_A" --evidence-file "$ev" >/dev/null 2>&1 || rc=$?
check "6b: a held lock refuses rc 5" "$rc" 5
check "6b: nothing written under a held lock" "$(ls "$scope_dir/q9" | wc -l | tr -d ' ')" 0
check "6b: the other writer's lock is left alone" "$([ -d "$scope_dir/q9/.write-verdict.lock" ] && echo yes || echo no)" yes

# --- 7. session stamp -----------------------------------------------------
contains "7: writer session stamped" "$(cat "$f1")" "writer-session: sess-4689"

# --- 8. a console leg is refused -----------------------------------------
rc=0; env HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$root" USER_SLUG=tuser bash "$SCRIPT" q8 GO "$SHA_A" --evidence-file "$ev" >/dev/null 2>&1 || rc=$?
check "8: a console leg is refused rc 3" "$rc" 3
rc=0; env -u HIMMEL_CONSOLE_JUDGE HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_JUDGE=1 HANDOVER_DIR="$root" USER_SLUG=tuser bash "$SCRIPT" q8 GO "$SHA_A" --evidence-file "$ev" >/dev/null 2>&1 || rc=$?
check "8: a judge session (leg + judge marker) may write" "$rc" 0

# --- 9. the live Bash guards ---------------------------------------------
guard_rc() {  # guard_rc <hook basename> <command text>
    # A file, not a pipe: a guard that exits without reading stdin would
    # SIGPIPE the producer and read as a refusal.
    jq -cn --arg c "$2" --arg d "$REPO" '{tool_name:"Bash",tool_input:{command:$c,cwd:$d},cwd:$d}' > "$tmp/payload.json"
    (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$REPO/scripts/hooks/$1.sh" < "$tmp/payload.json" >/dev/null 2>&1)
}
call="bash scripts/handover/console-kit/write-verdict.sh j1979-never-denies GO $SHA_A --evidence-file /tmp/claude-1000/j1979/evidence.md"
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
heredoc="cat > $scope_dir/j1979/verdict.md <<'EOF'
## Verdict

**GO** for head \`$SHA_A\`.
EOF"
abs_call="bash $REPO/scripts/handover/console-kit/write-verdict.sh j1979-never-denies NO-GO $SHA_A --evidence-file /tmp/claude-1000/j1979/evidence.md --judge HIMMEL-4689-judge-j1979"
for h in block-chokepoint-env-prefix guard-pr-check-literal block-edit-live-settings block-write-into-main-checkout guard-relay-writes; do
    rc=0; guard_rc "$h" "$call" || rc=$?
    check "9: $h passes the writer call" "$rc" 0
    rc=0; guard_rc "$h" "$abs_call" || rc=$?
    check "9: $h passes the absolute writer call" "$rc" 0
done
rc=0; guard_rc guard-pr-check-literal "$heredoc" || rc=$?
check "9: control - the heredoc GO line is denied" "$rc" 2

[ "$fails" -eq 0 ] && { echo "PASS: test-write-verdict.sh"; exit 0; }
echo "FAIL: $fails case(s)"
exit 1
