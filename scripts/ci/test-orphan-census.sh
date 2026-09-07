#!/usr/bin/env bash
# Suite for scripts/ci/orphan-census.sh (HIMMEL-1978).
#
# Drives the CLASSIFIER against a canned process table via the
# ORPHAN_CENSUS_INPUT seam — no process is spawned, nothing is signalled. The
# platform enumerators (Win32_Process / ps) are not re-proved here; what is
# pinned is our rule: dead parent + himmel command line + old enough + not a
# merge-gate watcher.
#
# Usage: bash scripts/ci/test-orphan-census.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

CENSUS="$(cd "$(dirname "$0")" && pwd)/orphan-census.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/procs.txt"

# The classifier anchors on THIS checkout's root (HIMMEL-1995), so the fixture
# command lines have to name it. Derived here from the script under test — NOT
# by re-implementing the script's own `.claude/worktrees` strip: this is the
# path as the suite sees it, which is the primary root when the suite runs
# there and a worktree path (still under the primary root) when it does not.
# Either spelling has to be accepted.
HIM_ROOT=$(cd "$(dirname "$CENSUS")/../.." && pwd -P)
# The primary checkout, i.e. the root the classifier itself derives. Needed for
# the two cases that turn on the root's own boundaries rather than on a path
# under it, which a worktree path cannot exercise.
HIM_PRIMARY="${HIM_ROOT%/.claude/worktrees/*}"
# Same tree as Win32_Process spells it: `c:/Users/...` with backslashes. The
# drive letter stays lower-case on purpose — the classifier folds case, and a
# GNU-only `sed \U` would not run on BSD.
# shellcheck disable=SC1003  # '\\' is tr's escape for one backslash, not a quote
HIM_WIN=$(printf '%s' "$HIM_ROOT" | sed -E 's#^/([a-zA-Z])/#\1:/#' | tr '/' '\\')

# pid|ppid|age_seconds|start_token|command line
#  100 — the live parent of 101; itself not a himmel process
#  101 — himmel suite, parent 100 ALIVE          -> not orphaned
#  201 — himmel suite, parent 999 DEAD, 40 min   -> ORPHAN
#  202 — himmel probe,  parent 998 DEAD, 40 min  -> ORPHAN
#  203 — check-ci watcher, parent dead, 40 min   -> WATCHER, never reaped
#  204 — himmel suite, parent dead, 2 min        -> too young, skipped
#  205 — unrelated program, parent dead, 40 min  -> not ours, not listed
#  206 — himmel suite reparented to init (POSIX orphan), 40 min -> ORPHAN
#  207 — himmel suite spelled with BACKSLASHES (Windows shape), 40 min -> ORPHAN
#  208 — a FOREIGN repo with the same scripts/**/test-*.sh layout -> not ours
#  209 — a FOREIGN suite that merely NAMES this checkout in an argument -> not ours
#  210 — this checkout's path in the wrong CASE (fixture/POSIX shape) -> not ours
#  211 — a FOREIGN absolute script AFTER this checkout's path -> not ours
#  212 — `cd <root> && bash scripts/...`, the live shape, 40 min -> ORPHAN
#  213 — a foreign tool PASSING this root plus a relative scripts/... -> not ours
#  214 — a WATCHER spelled in another case -> never ORPHAN
#  215 — this root appearing MID-PATH inside a foreign one -> not ours
#  216 — `cd <PRIMARY root> && bash scripts/...` (no trailing slash) -> ORPHAN
#  217 — a sibling checkout `<root>-old/...` -> not ours
#  218 — cd here, then cd elsewhere, then a relative script -> not ours
#  219 — an EDITOR holding one of our suite files open -> not ours
#  220 — `bash -x <root>/scripts/ci/test-y.sh` -> ORPHAN
#  221 — a supervisor whose ARGUMENT reads like the invocation -> not ours
#  222 — the quoted Windows shape (space in the interpreter path) -> ORPHAN
#  223 — cd here, then ECHO the invocation instead of running it -> not ours
#  224 — `bash --noprofile -o pipefail <root>/scripts/...` -> ORPHAN
#  225 — a suite whose ARGUMENTS name a watcher script -> ORPHAN, not WATCHER
#  226 — `cd <root>/../foreign && bash scripts/...` -> not ours
#  227 — `<root>/scripts/../../foreign/test-x.sh` -> not ours
#  228 — a shell PRINTING a rooted invocation -> not ours
#  229 — the interpreter reached after a command separator -> ORPHAN
#  230 — `bash -c read <root>/scripts/...` (the path is only $0) -> not ours
#  231 — `<root>/scripts/ci/test-worker.sh.bak` -> not ours
cat > "$WORK/procs.tmpl" <<'EOF'
1|0|360000|20260101000000|/sbin/init
100|1|3600|20260821030000|C:\Windows\System32\cmd.exe /c something
101|100|2400|20260821031000|/usr/bin/bash @ROOT@/scripts/handover/test-arm-resume.sh
201|999|2400|20260821031500|/usr/bin/bash @ROOT@/scripts/cr/test-critic-panel.sh
202|998|2400|20260821031600|/usr/bin/bash @ROOT@/scripts/probe-check-ci-escalate.sh
203|997|2400|20260821031700|/usr/bin/bash @ROOT@/scripts/check-ci.sh --watch 1779
204|996|120|20260821035800|/usr/bin/bash @ROOT@/scripts/ci/test-run-shell-tests.sh
205|995|2400|20260821031800|C:\Program Files\Some\updater.exe --quiet
206|1|2400|20260821031900|/usr/bin/bash @ROOT@/scripts/ci/test-suite-concurrency.sh
EOF
# Substituted with bash parameter expansion, not sed: a checkout path may
# legitimately contain `&`, `#` or `\`, every one of which means something in a
# sed replacement (panel r2 codex-3). The backslash-bearing lines below are
# appended with printf, where a %s argument is never re-escaped either.
while IFS= read -r line; do
    printf '%s\n' "${line//@ROOT@/$HIM_ROOT}"
done < "$WORK/procs.tmpl" > "$FIX"
HIM_UPPER=$(printf '%s' "$HIM_ROOT" | tr '[:lower:]' '[:upper:]')
{
    printf '207|994|2400|20260821032000|C:\\Windows\\bash.exe %s\\scripts\\cr\\test-cr-scores.sh\n' "$HIM_WIN"
    printf '208|993|2400|20260821032100|/usr/bin/bash /c/elsewhere/not-himmel/scripts/cr/test-critic-panel.sh\n'
    # 209: root and script pattern both present, but the script is NOT under the
    # root — anchoring them independently would have claimed this one.
    printf '209|992|2400|20260821032200|/usr/bin/bash /c/elsewhere/not-himmel/scripts/ci/test-x.sh --repo %s\n' "$HIM_ROOT"
    # 210: this checkout, upper-cased. The fixture seam never sets PS_BIN, so
    # the classifier is in its case-SENSITIVE (POSIX) mode and must not fold
    # these into the same checkout.
    printf '210|991|2400|20260821032300|/usr/bin/bash %s/scripts/cr/test-critic-panel.sh\n' "$HIM_UPPER"
    # 211: the foreign absolute script comes AFTER this checkout's path, so mere
    # ordering is not the guard — the script has to be root-prefixed or relative.
    printf '211|990|2400|20260821032400|/usr/bin/bash --config %s/x.json /c/elsewhere/not-himmel/scripts/ci/test-x.sh\n' "$HIM_ROOT"
    # 212: `cd <root> && bash scripts/…` — how nearly every live suite on the
    # box actually spells itself. Must still be claimed.
    printf '212|989|2400|20260821032500|/usr/bin/bash -c cd %s && bash scripts/ci/test-suite-box.sh\n' "$HIM_ROOT"
    # 213: a foreign tool that PASSES this root as an argument and separately
    # names a relative scripts/... path. Both halves of the relative branch are
    # present; the `cd` that would mean "running here" is not.
    printf '213|988|2400|20260821032600|/usr/bin/foreign-tool --repo %s --script scripts/ci/test-x.sh\n' "$HIM_ROOT"
    # 214: a watcher script spelled in a different CASE. Off Windows the
    # classifier is case-sensitive, so it is not claimed at all and cannot be
    # reaped — which is all this seam can prove. The Windows pairing (claim
    # folds case, so the watcher test must read the same folded string, panel r2
    # codex-2) is NOT reachable here: the fixture never sets PS_BIN. Reviewed by
    # reading, not pinned.
    printf '214|987|2400|20260821032700|/usr/bin/bash %s/scripts/Check-CI.sh --watch 1779\n' "$HIM_ROOT"
    # 215: the root appears MID-PATH inside a foreign one. index() alone
    # accepted that; the root has to start a path token.
    printf '215|986|2400|20260821032800|/usr/bin/bash /jail%s/scripts/ci/test-x.sh\n' "$HIM_ROOT"
    # 216: the same `cd … && bash scripts/…` shape, but entering the PRIMARY
    # checkout, where the root is followed by whitespace rather than by `/`.
    # A slash-terminated root could never match this (panel r4 codex-1), and
    # when the suite runs from the primary checkout case 212 IS this case — so
    # it is spelled out here to be pinned from a worktree run too.
    printf '216|985|2400|20260821032900|/usr/bin/bash -c cd %s && bash scripts/ci/test-primary-shape.sh\n' "$HIM_PRIMARY"
    # 217: a SIBLING checkout whose path merely starts with the root.
    printf '217|984|2400|20260821033000|/usr/bin/bash %s-old/scripts/ci/test-x.sh\n' "$HIM_PRIMARY"
    # 218: cd here, then cd somewhere else, THEN run a relative script. The cwd
    # at the point the script runs is not this checkout.
    printf '218|983|2400|20260821033100|/usr/bin/bash -c cd %s && cd /foreign && bash scripts/ci/test-x.sh\n' "$HIM_PRIMARY"
    # 219: an editor holding one of our suite files open. It is not running the
    # suite, and --reap must not take it.
    printf '219|982|2400|20260821033200|/usr/bin/vim %s/scripts/ci/test-x.sh\n' "$HIM_PRIMARY"
    # 220: the same file, but actually being run by an interpreter with a flag.
    printf '220|981|2400|20260821033300|/usr/bin/bash -x %s/scripts/ci/test-y.sh\n' "$HIM_PRIMARY"
    # 221: a supervisor whose ARGUMENT string reads like the invocation. Its
    # argv[0] is not an interpreter, so it is a description, not an execution.
    printf '221|980|2400|20260821033400|/usr/bin/supervisor --cmd bash %s/scripts/ci/test-x.sh\n' "$HIM_PRIMARY"
    # 222: the real Windows shape — a quoted interpreter whose own path
    # contains a space, and a quoted script argument.
    printf '222|979|2400|20260821033500|"C:/Program Files/Git/bin/bash.exe" "%s/scripts/ci/test-q.sh"\n' "$HIM_PRIMARY"
    # 223: cd here, then PRINT the invocation instead of running it. Only shell
    # glue may sit between the cd target and the interpreter.
    printf '223|978|2400|20260821033600|/usr/bin/bash -c cd %s && echo bash scripts/ci/test-x.sh\n' "$HIM_PRIMARY"
    # 224: a long option and a flag that carries a value.
    printf '224|977|2400|20260821033700|/usr/bin/bash --noprofile -o pipefail %s/scripts/ci/test-n.sh\n' "$HIM_PRIMARY"
    # 225: an ordinary suite whose ARGUMENTS mention a watcher script. The
    # watcher label must follow the script that was matched, not the whole line.
    printf '225|976|2400|20260821033800|/usr/bin/bash %s/scripts/ci/test-w.sh --after /c/x/scripts/check-ci.sh\n' "$HIM_PRIMARY"
    # 226/227: a path that STARTS at the root but walks back out of it, once
    # through the cd target and once through the script path itself.
    printf '226|975|2400|20260821033900|/usr/bin/bash -c cd %s/../foreign && bash scripts/ci/test-x.sh\n' "$HIM_PRIMARY"
    printf '227|974|2400|20260821034000|/usr/bin/bash %s/scripts/../../foreign/test-x.sh\n' "$HIM_PRIMARY"
    # 228: the root-prefixed twin of 223 — a shell PRINTING the invocation.
    printf '228|973|2400|20260821034100|/usr/bin/bash -c echo bash %s/scripts/ci/test-x.sh; sleep 1000\n' "$HIM_PRIMARY"
    # 229: the same shape actually running it, the interpreter reached after a
    # command separator rather than as argv[0].
    printf '229|972|2400|20260821034200|/usr/bin/bash -c cd /tmp && bash %s/scripts/ci/test-abs.sh\n' "$HIM_PRIMARY"
    # 230: with `-c`, the word after it is the command string and the path is
    # only $0 — the shell never runs it.
    printf '230|971|2400|20260821034300|/usr/bin/bash -c read %s/scripts/ci/test-x.sh\n' "$HIM_PRIMARY"
    # 231: a backup file that only CONTAINS `.sh`. The script name has to end
    # at the token boundary.
    printf '231|970|2400|20260821034400|/usr/bin/bash %s/scripts/ci/test-worker.sh.bak\n' "$HIM_PRIMARY"
} >> "$FIX"

echo "test-orphan-census.sh"

echo "== Case A: classification =="
out=$(ORPHAN_CENSUS_INPUT="$FIX" bash "$CENSUS" --min-age 10 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "rc=0"; else fail "rc=$rc"; fi
if grepq "$out" -E '^ +201 +999 +2400s +ORPHAN'; then pass "201 classified ORPHAN"; else fail "201 not ORPHAN: $out"; fi
if grepq "$out" -E '^ +202 +998 +2400s +ORPHAN'; then pass "202 (probe) classified ORPHAN"; else fail "202 not ORPHAN: $out"; fi
if grepq "$out" -E '^ +203 +997 +2400s +WATCHER'; then pass "203 classified WATCHER, not ORPHAN"; else fail "203 not WATCHER: $out"; fi
if grepq "$out" -E '^ +101 '; then fail "101 listed though its parent is alive"; else pass "101 excluded — parent alive"; fi
if grepq "$out" -E '^ +204 '; then fail "204 listed though it is younger than --min-age"; else pass "204 excluded — too young"; fi
if grepq "$out" -E '^ +205 '; then fail "205 listed though it is not a himmel process"; else pass "205 excluded — not a himmel command line"; fi
if grepq "$out" -E '^ +206 +1 +2400s +ORPHAN'; then
    pass "206 reparented to a LIVE init is still an ORPHAN (POSIX shape)"
else
    fail "206 not ORPHAN — the live-ppid check swallowed the POSIX orphan: $out"
fi
if grepq "$out" -E '^ +207 +994 +2400s +ORPHAN'; then
    pass "207 with a backslash script path is classified (Windows shape)"
else
    fail "207 not ORPHAN — backslash paths are not normalised: $out"
fi
if grepq "$out" -E '^ +208 '; then
    fail "208 listed — a same-layout FOREIGN repo was claimed as ours: $out"
else
    pass "208 excluded — outside this himmel checkout (HIMMEL-1995 root anchor)"
fi
if grepq "$out" -E '^ +209 '; then
    fail "209 listed — a foreign suite that only NAMES this checkout was claimed: $out"
else
    pass "209 excluded — the root must PREFIX the script path, not just appear on the line"
fi
if grepq "$out" -E '^ +210 '; then
    fail "210 listed — the checkout path was case-folded outside Windows: $out"
else
    pass "210 excluded — case-sensitive root match off Windows"
fi
if grepq "$out" -E '^ +211 '; then
    fail "211 listed — a foreign absolute script after the root was claimed: $out"
else
    pass "211 excluded — order alone does not claim a foreign absolute script"
fi
if grepq "$out" -E '^ +212 +989 +2400s +ORPHAN'; then
    pass "212 claimed — cd <root> && bash scripts/... is the live shape"
else
    fail "212 not ORPHAN — the relative-to-cwd shape is not claimed: $out"
fi
if grepq "$out" -E '^ +213 '; then
    fail "213 listed — a foreign tool that only PASSES this root was claimed: $out"
else
    pass "213 excluded — the relative branch needs a cd INTO the root"
fi
if grepq "$out" -E '^ +214 +[0-9]+ +[0-9]+s +ORPHAN'; then
    fail "214 is a watcher spelled in another case and landed in the reap list: $out"
else
    pass "214 never classified ORPHAN off Windows (case-sensitive claim)"
fi
if grepq "$out" -E '^ +215 '; then
    fail "215 listed — the root matched MID-PATH inside a foreign one: $out"
else
    pass "215 excluded — the root must start a path token"
fi
if grepq "$out" -E '^ +216 +985 +2400s +ORPHAN'; then
    pass "216 claimed — cd into the PRIMARY root, no trailing slash on the line"
else
    fail "216 not ORPHAN — a root followed by whitespace is not matched: $out"
fi
if grepq "$out" -E '^ +217 '; then
    fail "217 listed — a sibling checkout sharing the root prefix was claimed: $out"
else
    pass "217 excluded — the root must end at a path boundary"
fi
if grepq "$out" -E '^ +218 '; then
    fail "218 listed — an intervening cd to a foreign dir still claimed the script: $out"
else
    pass "218 excluded — the relative search stops at the next cd"
fi
if grepq "$out" -E '^ +219 '; then
    fail "219 listed — an editor holding a suite file open was claimed: $out"
else
    pass "219 excluded — an interpreter must precede the script"
fi
if grepq "$out" -E '^ +220 +981 +2400s +ORPHAN'; then
    pass "220 claimed — bash -x <script> is still a suite process"
else
    fail "220 not ORPHAN — an interpreter flag broke the match: $out"
fi
if grepq "$out" -E '^ +221 '; then
    fail "221 listed — a supervisor DESCRIBING the invocation was claimed: $out"
else
    pass "221 excluded — argv[0] must be an interpreter (or the script itself)"
fi
if grepq "$out" -E '^ +222 +979 +2400s +ORPHAN'; then
    pass "222 claimed — quoted interpreter with a space in its path, quoted script"
else
    fail "222 not ORPHAN — the real Windows quoted shape is missed: $out"
fi
if grepq "$out" -E '^ +223 '; then
    fail "223 listed — an ECHOED invocation was taken for a real one: $out"
else
    pass "223 excluded — only shell glue may precede the interpreter"
fi
if grepq "$out" -E '^ +224 +977 +2400s +ORPHAN'; then
    pass "224 claimed — long options and value-carrying flags"
else
    fail "224 not ORPHAN — bash --noprofile / -o pipefail is dropped: $out"
fi
if grepq "$out" -E '^ +225 +976 +2400s +ORPHAN'; then
    pass "225 ORPHAN — a watcher named in the ARGUMENTS does not relabel the suite"
else
    fail "225 not ORPHAN — mislabelled from the whole command line: $out"
fi
for p in 226 227; do
    if grepq "$out" -E "^ +$p "; then
        fail "$p listed — a .. component walked out of the checkout: $out"
    else
        pass "$p excluded — .. in the path after the root disqualifies it"
    fi
done
if grepq "$out" -E '^ +228 '; then
    fail "228 listed — a shell PRINTING the invocation was claimed: $out"
else
    pass "228 excluded — an interpreter preceded by a bare word is not running it"
fi
if grepq "$out" -E '^ +229 +972 +2400s +ORPHAN'; then
    pass "229 claimed — interpreter reached after a command separator"
else
    fail "229 not ORPHAN — a non-argv[0] interpreter is rejected outright: $out"
fi
if grepq "$out" -E '^ +230 '; then
    fail "230 listed — a path that is only \$0 to bash -c was claimed: $out"
else
    pass "230 excluded — -c makes the following words a command string, not a script"
fi
if grepq "$out" -E '^ +231 '; then
    fail "231 listed — a .sh.bak file matched the script pattern: $out"
else
    pass "231 excluded — the script name must end at a token boundary"
fi
if grepq "$out" -F 'SUMMARY orphans=11 watchers=1 young-skipped=1 scanned=34'; then
    pass "summary counts match"
else
    fail "summary wrong: $out"
fi
if grepq "$out" -F 'read-only'; then pass "default run advertises itself as read-only"; else fail "missing the read-only notice"; fi
if grepq "$out" -F 'source=fixture'; then pass "reports the fixture source"; else fail "did not report source=fixture"; fi

echo "== Case B: --min-age moves the young cut =="
out=$(ORPHAN_CENSUS_INPUT="$FIX" bash "$CENSUS" --min-age 1 2>&1)
if grepq "$out" -E '^ +204 +996 +120s +ORPHAN'; then
    pass "204 becomes an ORPHAN at --min-age 1"
else
    fail "204 still excluded at --min-age 1: $out"
fi

echo "== Case C: usage =="
ORPHAN_CENSUS_INPUT="$FIX" bash "$CENSUS" --min-age nope >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "non-numeric --min-age rc=2"; else fail "non-numeric --min-age rc=$rc"; fi
bash "$CENSUS" --nope >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "unknown flag rc=2"; else fail "unknown flag rc=$rc"; fi
ORPHAN_CENSUS_INPUT="$WORK/does-not-exist" bash "$CENSUS" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "unreadable fixture rc=2"; else fail "unreadable fixture rc=$rc"; fi
bash "$CENSUS" --help >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then pass "--help rc=0"; else fail "--help rc=$rc (help is not a usage error)"; fi

# The seam and the kill switch must never combine: a fixture's PIDs are
# literals, and by reap time they belong to whatever the OS reassigned them to.
echo "== Case D: --reap refuses the fixture seam =="
out=$(ORPHAN_CENSUS_INPUT="$FIX" bash "$CENSUS" --reap 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "--reap with ORPHAN_CENSUS_INPUT rc=2"; else fail "--reap with fixture rc=$rc (expected 2)"; fi
if grepq "$out" -F 'refusing --reap with ORPHAN_CENSUS_INPUT'; then pass "refusal names the reason"; else fail "refusal message wrong: $out"; fi
if grepq "$out" -F 'signalled'; then fail "--reap signalled a fixture PID"; else pass "nothing was signalled"; fi

echo
if [ "$failures" -eq 0 ]; then
    echo "test-orphan-census.sh: ALL PASS"
    exit 0
fi
echo "test-orphan-census.sh: $failures FAILED"
exit 1
