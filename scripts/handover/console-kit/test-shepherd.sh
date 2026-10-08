#!/usr/bin/env bash
# test-shepherd.sh — HIMMEL-4942. Drives shepherd.sh with a stub gh on PATH, stub
# ready-check / check-ci / impacted-suites, and a real scratch git repo (a bare
# origin carrying refs/pull/7/head), in a scratch HOME. bash 3.2-safe.
#
# Run: bash scripts/handover/console-kit/test-shepherd.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHEP="${SHEPHERD:-$HERE/shepherd.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi; }
has() { # <name> <needle> <haystack>
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$2' in: $3)" ;; esac
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/shepherd-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@t; git config --global user.name t
git config --global init.defaultBranch main

# Scratch repo: bare origin + clone; PR 7 head = one commit adding test-a.sh.
git init -q --bare "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/repo" 2>/dev/null
( cd "$WORK/repo" && echo base > f && git add f && git commit -qm base && git push -q origin main \
  && git checkout -q -b pr && printf '#!/bin/sh\nexit 0\n' > test-a.sh && git add test-a.sh && git commit -qm pr \
  && git push -q origin pr:refs/pull/7/head && git checkout -q main )
HEADSHA=$(git -C "$WORK/repo" rev-parse pr)

# Stubs. gh prints $WORK/pr.json; ready-check/check-ci exit with the code in a file.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/bin/sh
cat "$SHEP_PRJSON"
EOF
chmod +x "$WORK/bin/gh"
cat > "$WORK/rc-stub.sh" <<'EOF'
#!/bin/sh
# usage: rc-stub.sh <name> ...: exit with the code in $SHEP_STUBDIR/<name>.rc (default 0)
n="$1"; shift
[ "$n" = ready ] && case "$1" in --only) n=cov ;; esac
c=0; [ -f "$SHEP_STUBDIR/$n.rc" ] && c=$(cat "$SHEP_STUBDIR/$n.rc")
echo "stub $n rc=$c fail line" ; exit "$c"
EOF
# shellcheck disable=SC2016
printf '#!/bin/sh\nexec sh "$SHEP_STUBDIR/../rc-stub.sh" ready "$@"\n' > "$WORK/ready-stub"
# shellcheck disable=SC2016
printf '#!/bin/sh\nexec sh "$SHEP_STUBDIR/../rc-stub.sh" ci "$@"\n' > "$WORK/ci-stub"
printf '#!/bin/sh\necho test-a.sh\n' > "$WORK/impacted-stub"
export SHEP_STUBDIR="$WORK/stubs"; mkdir -p "$SHEP_STUBDIR"
export SHEP_PRJSON="$WORK/pr.json"
export PATH="$WORK/bin:$PATH"
export SHEPHERD_READY_CHECK="$WORK/ready-stub" SHEPHERD_CHECK_CI="$WORK/ci-stub" SHEPHERD_IMPACTED="$WORK/impacted-stub"
export SHEPHERD_LEDGER="$WORK/ledger.jsonl"

setup() { # <cloud-done yes|no> <ledger ok|none> <suite-exit>
    rm -rf "${SHEP_STUBDIR:?}"/* "$WORK/repo/.claude"
    git -C "$WORK/repo" worktree prune
    if [ "$1" = yes ]; then c='[{"body":"CLOUD-DONE https://x"}]'; else c='[{"body":"hello"}]'; fi
    printf '{"headRefOid":"%s","baseRefName":"main","comments":%s}\n' "$HEADSHA" "$c" > "$SHEP_PRJSON"
    if [ "$2" = ok ]; then printf '{"kind":"avail","head":"%s","status":"ok"}\n' "$HEADSHA" > "$SHEPHERD_LEDGER"; else : > "$SHEPHERD_LEDGER"; fi
    printf '#!/bin/sh\nexit %s\n' "$3" > "$WORK/suite-body"
}
# the worktree checks out test-a.sh from the PR head (exit 0); a failing suite
# is simulated by the impacted stub naming a suite that does not pass.
run() { ( cd "$WORK/repo" && bash "$SHEP" 7 2>&1 ); }

# (a) usage
out=$(bash "$SHEP" 2>&1); check "(a) no args exits 2" 2 $?
out=$(bash "$SHEP" 07 2>&1); check "(a) leading zero exits 2" 2 $?

# (b) clean path
setup yes ok 0
out=$(run); rc=$?
check "(b) clean path exits 0" 0 "$rc"
has "(b) block says READY-CANDIDATE" "SHEPHERD 7 $HEADSHA READY-CANDIDATE" "$out"
has "(b) steering skipped" "steering: skipped" "$out"
has "(b) suite verdict line" "suite test-a.sh: PASS" "$out"
check "(b) worktree exists" yes "$([ -d "$WORK/repo/.claude/worktrees/shepherd-7" ] && echo yes)"

# (c) failed suite -> needs leg
setup yes ok 0
printf '#!/bin/sh\necho test-fail.sh\n' > "$WORK/impacted-stub"
( cd "$WORK/repo" && git checkout -q pr && printf '#!/bin/sh\nexit 1\n' > test-fail.sh && git add test-fail.sh && git commit -qm f \
  && git push -q -f origin pr:refs/pull/7/head && git checkout -q main )
HEADSHA=$(git -C "$WORK/repo" rev-parse pr); setup yes ok 0
out=$(run); rc=$?
check "(c) failed suite exits 1" 1 "$rc"
has "(c) names suite-failed" "NEEDS-LEG" "$out"
has "(c) suite-failed reason" "suite-failed:1" "$out"
has "(c) suite verdict FAIL" "suite test-fail.sh: FAIL" "$out"
printf '#!/bin/sh\necho test-a.sh\n' > "$WORK/impacted-stub"

# (d) coverage gap
setup yes ok 0; echo 1 > "$SHEP_STUBDIR/cov.rc"
out=$(run); rc=$?
check "(d) coverage gap exits 1" 1 "$rc"
has "(d) coverage-gap reason" "coverage-gap" "$out"

# (e) CI pending
setup yes ok 0; echo 2 > "$SHEP_STUBDIR/ci.rc"
out=$(run); rc=$?
check "(e) CI pending exits 1" 1 "$rc"
has "(e) names ci-pending" "ci-pending" "$out"
has "(e) ci line says PENDING" "ci: PENDING" "$out"

# (f) CLOUD-DONE absent: steering is NOT skipped, nothing else runs
setup no ok 0
out=$(run); rc=$?
check "(f) no CLOUD-DONE exits 1" 1 "$rc"
has "(f) steering DUE" "steering: DUE" "$out"
has "(f) steering-required reason" "steering-required" "$out"
check "(f) no worktree made" "" "$([ -d "$WORK/repo/.claude/worktrees/shepherd-7" ] && echo yes)"

# (g) panel not run -> says so, needs leg
setup yes none 0
out=$(run); rc=$?
check "(g) no ledger row exits 1" 1 "$rc"
has "(g) panel NOT-RUN stated" "panel: NOT-RUN" "$out"
has "(g) panel-not-run reason" "panel-not-run" "$out"

# (h) gh failure -> infra error
setup yes ok 0; printf 'not json\n' > "$SHEP_PRJSON"
out=$(run); rc=$?
check "(h) unreadable PR exits 2" 2 "$rc"

printf '\n%s failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
