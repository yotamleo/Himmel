#!/usr/bin/env bash
# shellcheck disable=SC2015
# scripts/handover/console/test-console.sh — RED/GREEN suite for console.sh
# (HIMMEL-2873).
#
# Every case runs against a TEMP handover root AND a throwaway fixture
# "repo" (a fresh `git init` whose scripts/ and docs/ are symlinked back to
# this checkout's real ones): console.sh resolves its own "repo" from
# `git rev-parse --git-common-dir` of the process cwd, and this checkout is
# a linked worktree whose PRIMARY checkout lives under this operator's real
# home directory — using it as-is would embed that real path into every
# doc console.sh writes and trip the private-string-leak check (case 8)
# for no reason related to the code under test. cd'ing into the fixture
# before every invocation makes the resolved repo path a clean /tmp path
# while queue-lock.sh, the templates, and console-kit all still resolve
# to the real, working files via the symlinks.
#
# Platform guard (gitbash-only): POSIX bash 3.2+; exercises console.sh,
# which is konsole/Linux-only for --arm (see console.sh's own header) —
# same platform scope, no .ps1 twin.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
C="$HERE/console.sh"
REPO_REAL="$(cd "$HERE/../../.." && pwd)"
QL="$REPO_REAL/scripts/handover/queue-lock.sh"
# shellcheck source=../../lib/permission-test.sh
. "$HERE/../../lib/permission-test.sh"

# Templated (BSD/macOS mktemp requires one); refuse loudly on failure BEFORE
# the EXIT trap is registered — an empty $tmp would otherwise make the trap
# clean up the wrong thing.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/console-test.XXXXXX")" || { echo "test-console: mktemp -d failed" >&2; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

fixture_repo="$tmp/repo"
mkdir -p "$fixture_repo"
git init -q "$fixture_repo"
ln -s "$REPO_REAL/scripts" "$fixture_repo/scripts"
ln -s "$REPO_REAL/docs" "$fixture_repo/docs"

root="$tmp/handovers"
mkdir -p "$root"
today="$(date +%F)"

console_root() {  # console_root <root> <args...> -- invoke console.sh with
                  # cwd pinned to the fixture repo, against an ARBITRARY
                  # handover root (used by cases exercising a non-default
                  # root, e.g. one containing a space).
    local r="$1"; shift
    ( cd "$fixture_repo" && HANDOVER_DIR="$r" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO bash "$C" "$@" )
}

console() { console_root "$root" "$@"; }

token_of() { printf '%s\n' "$1" | sed -n 's/^release-token: //p'; }

# --- 1/2/3/4: new, placeholder cleanliness, lock lifecycle, idempotent bump
docA="$root/tester/demorepo/DEMO-nextleg-${today}A-console.md"
docB="$root/tester/demorepo/DEMO-nextleg-${today}B-console.md"

out1="$(console new --bucket demorepo)"
check "1 new writes the console doc" "$([ -f "$docA" ] && echo yes)" "yes"
check "2 doc has no surviving placeholder" "$(grep -c '{{' "$docA" 2>/dev/null)" "0"

check "3 new prints release-token" "$(printf '%s\n' "$out1" | grep -c '^release-token: ')" "1"
token1="$(token_of "$out1")"
rc_held=0
HANDOVER_DIR="$root" bash "$QL" status "$docA" >/dev/null 2>&1 || rc_held=$?
check "3 lock held after acquire" "$rc_held" "11"
HANDOVER_DIR="$root" bash "$QL" release "$docA" "$token1" >/dev/null 2>&1
rc_freed=0
HANDOVER_DIR="$root" bash "$QL" status "$docA" >/dev/null 2>&1 || rc_freed=$?
check "3 lock freed after release" "$rc_freed" "0"

sumA_before="$(cksum < "$docA")"
out4="$(console new --bucket demorepo)"
check "4 second new writes B" "$([ -f "$docB" ] && echo yes)" "yes"
sumA_after="$(cksum < "$docA")"
check "4 A byte-identical after second new" "$sumA_before" "$sumA_after"
token4="$(token_of "$out4")"
HANDOVER_DIR="$root" bash "$QL" release "$docB" "$token4" >/dev/null 2>&1

# --- 5: --dry-run writes nothing --------------------------------------
before5="$(find "$root" -type f | sort)"
out5="$(console new --bucket dryrepo --dry-run)"
after5="$(find "$root" -type f | sort)"
check "5 dry-run writes nothing" "$before5" "$after5"
check "5 dry-run prints would-doc" "$(printf '%s\n' "$out5" | grep -c '^would-doc: ')" "1"

# --- 6: next writes the successor stub + predecessor HANDOFF ----------
doc6A="$root/tester/nextrepo/DEMO-nextleg-${today}A-console.md"
doc6B="$root/tester/nextrepo/DEMO-nextleg-${today}B-console.md"
handoff6A="$root/tester/nextrepo/DEMO-nextleg-${today}A-console-HANDOFF.md"

out6a="$(console new --bucket nextrepo)"
token6a="$(token_of "$out6a")"
console next --bucket nextrepo >/dev/null
check "6 next writes successor stub" "$([ -f "$doc6B" ] && echo yes)" "yes"
check "6 next writes predecessor HANDOFF" "$([ -f "$handoff6A" ] && echo yes)" "yes"
check "6 successor stub names the predecessor" "$(grep -c "DEMO-nextleg-${today}A-console.md" "$doc6B")" "1"
check "6 successor has no surviving placeholder" "$(grep -c '{{' "$doc6B" 2>/dev/null)" "0"
check "6 handoff has no surviving placeholder" "$(grep -c '{{' "$handoff6A" 2>/dev/null)" "0"
HANDOVER_DIR="$root" bash "$QL" release "$doc6A" "$token6a" >/dev/null 2>&1

# --- 6b: --doc outside the successor's own state dir --------------------
# The predecessor lives under a DIFFERENT bucket than the one this `next`
# invocation targets; its HANDOFF must land beside the predecessor doc, not
# in the successor's state_dir.
out6ba="$(console new --bucket outsidesrc)"
token6ba="$(token_of "$out6ba")"
doc6bSrc="$root/tester/outsidesrc/DEMO-nextleg-${today}A-console.md"
handoff6bSrc="$root/tester/outsidesrc/DEMO-nextleg-${today}A-console-HANDOFF.md"
handoff6bWrong="$root/tester/outsidedst/DEMO-nextleg-${today}A-console-HANDOFF.md"
doc6bDst="$root/tester/outsidedst/DEMO-nextleg-${today}B-console.md"

console next --bucket outsidedst --doc "$doc6bSrc" >/dev/null
check "6b next --doc still writes the successor stub into its own state_dir" "$([ -f "$doc6bDst" ] && echo yes)" "yes"
check "6b next --doc writes the HANDOFF beside the predecessor" "$([ -f "$handoff6bSrc" ] && echo yes)" "yes"
check "6b next --doc does not write the HANDOFF into the successor's state_dir" "$([ -f "$handoff6bWrong" ] && echo yes || echo no)" "no"
check "6b successor stub names a resolvable (absolute) HANDOFF reference" "$(grep -cF "$handoff6bSrc" "$doc6bDst")" "1"
# shellcheck disable=SC2016 # Match literal Markdown backticks, not command substitution.
successor6b_ref="$(sed -n 's/^Run ACTION ZERO from `\([^`]*\)` unchanged.*/\1/p' "$handoff6bSrc")"
check "6b HANDOFF names the absolute cross-bucket successor" "$successor6b_ref" "$doc6bDst"
case "$successor6b_ref" in
    /*) successor6b_path="$successor6b_ref" ;;
    *) successor6b_path="$(dirname "$handoff6bSrc")/$successor6b_ref" ;;
esac
check "6b successor reference resolves from the HANDOFF directory" "$([ -f "$successor6b_path" ] && echo yes)" "yes"
HANDOVER_DIR="$root" bash "$QL" release "$doc6bSrc" "$token6ba" >/dev/null 2>&1

# --- 7: next --arm with a stub arm target ------------------------------
doc7A="$root/tester/armrepo/DEMO-nextleg-${today}A-console.md"
session7B="DEMO-nextleg-${today}B-console"
# Signal/log live under a chain-identity subdir ($slug-$bucket), not
# $workdir directly -- see codex-2 round-2 (bucket-only-differing chains
# must not collide on the same signal/log path).
log7B="$tmp/work/tester-armrepo/launch-${session7B}.log"

cat > "$tmp/stub-arm.sh" <<'STUB'
#!/usr/bin/env bash
echo "armed: name=$1 doc=$2 signal=$3 deadline=$4" >> "$5"
STUB
chmod +x "$tmp/stub-arm.sh"

out7a="$(console new --bucket armrepo)"
token7a="$(token_of "$out7a")"
out7b="$( ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CONSOLE_HEADED_ARM="$tmp/stub-arm.sh" CONSOLE_ARM_FOREGROUND=1 CONSOLE_WORK_DIR="$tmp/work" \
    bash "$C" next --bucket armrepo --arm --deadline-min 0 ) )"
check "7 next --arm reports armed" "$(printf '%s\n' "$out7b" | grep -c '^armed: ')" "1"
check "7 arm log written" "$([ -f "$log7B" ] && echo yes)" "yes"
check "7 arm log carries armed/signal/deadline/session" \
    "$(grep -cE "armed: name=${session7B} doc=.* signal=.*sig-${session7B} deadline=[0-9]+" "$log7B" 2>/dev/null)" "1"
HANDOVER_DIR="$root" bash "$QL" release "$doc7A" "$token7a" >/dev/null 2>&1

# --- 8: no private-string leak -----------------------------------------
# leak-pattern-allow: this line and the next NAME the banned words in order
# to detect them; excluded below (by the same marker) when scanning THIS
# file, so the detector's own pattern is never mistaken for a leak.
BANNED='overlord|yotamleo|luna|cachyos' # leak-pattern-allow
leak_free() {
    local matches
    matches="$(grep -niE "$BANNED" "$1" 2>/dev/null | grep -vc 'leak-pattern-allow')"
    [ "$matches" = "0" ] && echo yes || echo no
}
# The temp-root scan is narrowly exempted for the queue-lock RELEASE TOKEN
# this round's {{RELEASE_TOKEN}} fix deliberately writes into every console
# doc: its shape is "<hostname>-pid<N>" (queue-lock.sh's
# _ql_default_session), and on a station whose hostname itself happens to
# contain one of the banned words above, the token trips this scan on the
# very string it exists to embed. This is REQUIRED, not a leak: the
# launched console (on --arm, its ONLY channel) needs the token to release
# its own lock; these documents live only in the operator's private
# handover state repo, never in-tree (the checks below this one scan
# in-tree files and are untouched, exactly as strict as before); and the
# state repo's own gitleaks config already allowlists this exact token
# shape for this exact reason. The exemption is narrow and self-verifying,
# never a blanket allowlist of a banned word anywhere under the root: only
# a LINE shaped like a release token is filtered out of the leak scan, and
# every such line must carry a token this run actually saw `new` print — an
# unrelated
# leak, or a line that merely LOOKS token-shaped, still fails loudly.
known_tokens=("$token1" "$token4" "$token6a" "$token6ba" "$token7a")
token_residual() {
    local token
    for token in "$@"; do
        [ -n "$token" ] || { echo "empty release-token capture" >&2; return 2; }
    done
    # Match the entire indented token line in console-template.md, not a
    # substring. Scan raw content, without grep's filename/line prefixes.
    grep -vxFf <(printf '   %s\n' "$@") || [ "$?" -eq 1 ]
}
token_rc=0
token_residual "${known_tokens[@]}" </dev/null || token_rc=$?
check "8 every known release token was actually captured" "$token_rc" "0"
leak_lines="$(grep -rhEi "$BANNED" "$root" 2>/dev/null)"
leak_residual="$(printf '%s\n' "$leak_lines" | token_residual "${known_tokens[@]}")"
check "8 no leak under the temp handover root (excluding exact release-token lines)" \
    "$(printf '%s\n' "$leak_residual" | grep -c .)" "0"
check "8 exact known token line is exempt" \
    "$(printf '   %s\n' "$token1" | token_residual "${known_tokens[@]}")" ""
# A legitimate token must not hide an unrelated banned value on the same line.
mixed_line="   $token1 ${BANNED%%|*}"
check "8 negative control: a known token plus a banned value remains a leak" \
    "$(printf '%s\n' "$mixed_line" | token_residual "${known_tokens[@]}")" "$mixed_line"
empty_rc=0
printf '%s\n' "$mixed_line" | token_residual "$token1" "" >/dev/null 2>&1 || empty_rc=$?
check "8 negative control: an empty token capture is rejected" "$empty_rc" "2"
check "8 no leak in console.sh" "$(leak_free "$C")" "yes"
check "8 no leak in test-console.sh" "$(leak_free "$HERE/test-console.sh")" "yes"
check "8 no leak in console-template.md" "$(leak_free "$REPO_REAL/docs/handover/console-template.md")" "yes"
check "8 no leak in console-handoff-template.md" "$(leak_free "$REPO_REAL/docs/handover/console-handoff-template.md")" "yes"
check "8 no leak in leg-brief-template.md" "$(leak_free "$REPO_REAL/docs/handover/leg-brief-template.md")" "yes"
check "8 no leak in running-a-console.md" "$(leak_free "$REPO_REAL/docs/handover/running-a-console.md")" "yes"
check "8 no leak in .claude/commands/console.md" "$(leak_free "$REPO_REAL/.claude/commands/console.md")" "yes"

# --- 9: unresolvable handover root exits 2, writes nothing -------------
badroot="$tmp/does-not-exist"
rc9=0
console_badroot() { ( cd "$fixture_repo" && HANDOVER_DIR="$badroot" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO bash "$C" new --bucket demorepo9 ); }
console_badroot >/dev/null 2>&1 || rc9=$?
check "9 unresolvable root exits 2" "$rc9" "2"
check "9 unresolvable root writes nothing" "$([ -e "$badroot" ] && echo yes || echo no)" "no"

# --- 10: --name is slugified --------------------------------------------
# .locks/ is excluded from both snapshots: queue-lock.sh legitimately writes
# there (outside any bucket) on every `new`, unrelated to --name handling.
before10="$(find "$root" -type f -not -path "$root/.locks/*" | sort)"
out10="$(console new --bucket namebucket --name '../evil')"
docNameSlug="$root/tester/namebucket/DEMO-nextleg-${today}A-evil.md"
check "10 --name is slugified into the doc path" "$([ -f "$docNameSlug" ] && echo yes)" "yes"
token10="$(token_of "$out10")"
after10_outside="$(find "$root" -type f -not -path "$root/.locks/*" -not -path "$root/tester/namebucket/*" | sort)"
check "10 nothing written outside state_dir" "$before10" "$after10_outside"
HANDOVER_DIR="$root" bash "$QL" release "$docNameSlug" "$token10" >/dev/null 2>&1

# --- 11: next --doc <A> twice never re-renders an existing successor ----
out11a="$(console new --bucket dupenext)"
token11a="$(token_of "$out11a")"
doc11A="$root/tester/dupenext/DEMO-nextleg-${today}A-console.md"
doc11B="$root/tester/dupenext/DEMO-nextleg-${today}B-console.md"

console next --bucket dupenext --doc "$doc11A" >/dev/null
check "11 first next --doc writes B" "$([ -f "$doc11B" ] && echo yes)" "yes"
sum11B_before="$(cksum < "$doc11B")"
rc11=0
console next --bucket dupenext --doc "$doc11A" >/dev/null 2>&1 || rc11=$?
check "11 second next --doc <same A> exits non-zero" "$([ "$rc11" -ne 0 ] && echo yes)" "yes"
sum11B_after="$(cksum < "$doc11B")"
check "11 second next --doc <same A> leaves B byte-identical" "$sum11B_before" "$sum11B_after"
HANDOVER_DIR="$root" bash "$QL" release "$doc11A" "$token11a" >/dev/null 2>&1

# --- 12: named chains can hand over -------------------------------------
out12a="$(console new --bucket nightbucket --name night)"
token12a="$(token_of "$out12a")"
doc12A="$root/tester/nightbucket/DEMO-nextleg-${today}A-night.md"
check "12 new --name night writes A-night doc" "$([ -f "$doc12A" ] && echo yes)" "yes"

console next --bucket nightbucket --name night >/dev/null
doc12B="$root/tester/nightbucket/DEMO-nextleg-${today}B-night.md"
check "12 next --name night writes B-night doc" "$([ -f "$doc12B" ] && echo yes)" "yes"
HANDOVER_DIR="$root" bash "$QL" release "$doc12A" "$token12a" >/dev/null 2>&1

# --- 12b: next --doc alone derives a non-default name from the basename -
out12ba="$(console new --bucket nightsrc --name night)"
token12ba="$(token_of "$out12ba")"
doc12bA="$root/tester/nightsrc/DEMO-nextleg-${today}A-night.md"
console next --bucket nightdst --doc "$doc12bA" >/dev/null
doc12bB="$root/tester/nightdst/DEMO-nextleg-${today}B-night.md"
check "12b next --doc (no --name) derives the chain name from the doc basename" "$([ -f "$doc12bB" ] && echo yes)" "yes"
HANDOVER_DIR="$root" bash "$QL" release "$doc12bA" "$token12ba" >/dev/null 2>&1

# --- 13: a failed queue-lock acquire aborts before the launch line -------
lockfail_doc="$root/tester/lockfail/DEMO-nextleg-${today}A-console.md"
foreign_out="$(HANDOVER_DIR="$root" bash "$QL" acquire "$lockfail_doc" foreign-session)"
foreign_token="$(token_of "$foreign_out")"
rc13=0
out13="$(console new --bucket lockfail 2>&1)" || rc13=$?
check "13 queue-lock acquire failure prints no launch line" "$(printf '%s\n' "$out13" | grep -c '^launch: ')" "0"
check "13 queue-lock acquire failure exits non-zero" "$([ "$rc13" -ne 0 ] && echo yes)" "yes"
HANDOVER_DIR="$root" bash "$QL" release "$lockfail_doc" "$foreign_token" >/dev/null 2>&1

# --- 14: --deadline-min with a leading zero is not read as octal --------
# A prior version of this case never checked either invocation actually
# succeeded or that a deadline was parsed at all: two empty operands
# subtract to 0, "passing" the tolerance check vacuously. Assert rc=0 and a
# non-empty integer parse on BOTH sides before ever comparing them.
rc14a=0
out14a="$(console new --bucket deadlinetest --dry-run --arm --deadline-min 8)" || rc14a=$?
check "14 --deadline-min 8 succeeds" "$rc14a" "0"
rc14b=0
out14b="$(console new --bucket deadlinetest --dry-run --arm --deadline-min 08)" || rc14b=$?
check "14 --deadline-min 08 succeeds" "$rc14b" "0"
dl_a="$(printf '%s\n' "$out14a" | sed -n 's/.*deadline=\([0-9]*\).*/\1/p' | head -n 1)"
dl_b="$(printf '%s\n' "$out14b" | sed -n 's/.*deadline=\([0-9]*\).*/\1/p' | head -n 1)"
check "14 deadline for --deadline-min 8 parsed as a non-empty integer" "$(printf '%s' "$dl_a" | grep -Ec '^[0-9]+$')" "1"
check "14 deadline for --deadline-min 08 parsed as a non-empty integer" "$(printf '%s' "$dl_b" | grep -Ec '^[0-9]+$')" "1"
diff14=$(( dl_b - dl_a ))
[ "$diff14" -ge 0 ] || diff14=$(( -diff14 ))
check "14 --deadline-min 08 parses like 8 (no octal error)" "$([ "$diff14" -le 2 ] && echo yes)" "yes"

# --- 15: fallback discovery survives a space in the handover root -------
# Predecessor dated YESTERDAY (portable epoch-based computation: GNU `date
# -d @epoch`, falling back to BSD `date -r epoch`), so the today-letter loop
# in resolve_predecessor misses and the glob fallback is what actually runs.
root_sp="$tmp/adj sp"
mkdir -p "$root_sp/tester/spacerepo"
yesterday_epoch=$(( $(date +%s) - 86400 ))
yesterday="$(date -u -d "@$yesterday_epoch" +%F 2>/dev/null || date -u -r "$yesterday_epoch" +%F 2>/dev/null)"
predoc15="$root_sp/tester/spacerepo/DEMO-nextleg-${yesterday}A-console.md"
: > "$predoc15"
console_root "$root_sp" next --bucket spacerepo >/dev/null 2>&1
doc15B="$root_sp/tester/spacerepo/DEMO-nextleg-${today}B-console.md"
check "15 fallback discovery survives a space in the handover root" "$([ -f "$doc15B" ] && echo yes)" "yes"

# --- 16: new advances past an already-claimed letter --------------------
# Closes the check-then-write race: two concurrent `new` runs could
# otherwise both pick the same free letter, and the second would truncate
# the first's doc before either took its queue lock.
mkdir -p "$root/tester/racetest"
racetest_docA="$root/tester/racetest/DEMO-nextleg-${today}A-console.md"
printf 'pre-existing content that must survive\n' > "$racetest_docA"
sum_racetestA_before="$(cksum < "$racetest_docA")"
out16="$(console new --bucket racetest)"
token16="$(token_of "$out16")"
racetest_docB="$root/tester/racetest/DEMO-nextleg-${today}B-console.md"
check "16 new advances past an already-claimed letter" "$([ -f "$racetest_docB" ] && echo yes)" "yes"
sum_racetestA_after="$(cksum < "$racetest_docA")"
check "16 the already-claimed doc is left untouched" "$sum_racetestA_before" "$sum_racetestA_after"
HANDOVER_DIR="$root" bash "$QL" release "$racetest_docB" "$token16" >/dev/null 2>&1

# --- 16b: exhaustion requires 26 real collisions, not arbitrary I/O errors.
mkdir -p "$root/tester/exhausted"
for letter16 in {A..Z}; do
    printf 'claimed\n' > "$root/tester/exhausted/DEMO-nextleg-${today}${letter16}-console.md"
done
rc16b=0
out16b="$(console new --bucket exhausted 2>&1)" || rc16b=$?
check "16b all 26 claimed letters: exits 1" "$rc16b" "1"
check "16b all 26 claimed letters: reports exhaustion" "$(printf '%s\n' "$out16b" | grep -c 'all 26 letters')" "1"

# A directory at candidate A is EISDIR, not an existing console document.
blocked16A="$root/tester/createerror/DEMO-nextleg-${today}A-console.md"
mkdir -p "$blocked16A"
rc16c=0
out16c="$(LC_ALL=C console new --bucket createerror 2>&1)" || rc16c=$?
check "16c non-collision at A: exits 1" "$rc16c" "1"
check "16c non-collision at A: reports the underlying error" "$(printf '%s\n' "$out16c" | grep -ci 'is a directory')" "1"
check "16c non-collision at A: never tries B" "$([ -e "$root/tester/createerror/DEMO-nextleg-${today}B-console.md" ] && echo yes || echo no)" "no"
check "16c non-collision at A: does not report exhaustion" "$(printf '%s\n' "$out16c" | grep -c 'all 26 letters')" "0"

# ENAMETOOLONG cannot be confused with any pre-existing candidate (even as root).
long16_name="$(printf '%0260d' 0)"
rc16d=0
out16d="$(LC_ALL=C console new --bucket longname --name "$long16_name" 2>&1)" || rc16d=$?
check "16d non-collision with no candidate: exits 1" "$rc16d" "1"
check "16d non-collision with no candidate: reports the underlying error" "$(printf '%s\n' "$out16d" | grep -ci 'file name too long')" "1"
check "16d non-collision with no candidate: does not report exhaustion" "$(printf '%s\n' "$out16d" | grep -c 'all 26 letters')" "0"

# --- 17: chains differing only by --bucket get different signal/log paths
# The session-name shape (<PREFIX>-nextleg-<date><letter>-<name>) is
# unchanged and thus identical between these two calls; only the work-dir
# path is namespaced by chain identity (slug+bucket).
out17a="$(console new --bucket bucketa --dry-run --arm)"
out17b="$(console new --bucket bucketb --dry-run --arm)"
sig17a="$(printf '%s\n' "$out17a" | sed -n 's/.*signal=\([^ ]*\).*/\1/p' | head -n 1)"
sig17b="$(printf '%s\n' "$out17b" | sed -n 's/.*signal=\([^ ]*\).*/\1/p' | head -n 1)"
log17a="$(printf '%s\n' "$out17a" | sed -n 's/.*log=\([^ ]*\).*/\1/p' | head -n 1)"
log17b="$(printf '%s\n' "$out17b" | sed -n 's/.*log=\([^ ]*\).*/\1/p' | head -n 1)"
check "17 signal path differs when only --bucket differs" "$([ -n "$sig17a" ] && [ "$sig17a" != "$sig17b" ] && echo yes)" "yes"
check "17 log path differs when only --bucket differs" "$([ -n "$log17a" ] && [ "$log17a" != "$log17b" ] && echo yes)" "yes"

# --- 18: next --doc <missing predecessor> refuses rather than fabricate -
before18="$(find "$root" -type f -not -path "$root/.locks/*" | sort)"
missing_doc="$root/tester/missingrepo/DEMO-nextleg-${today}A-console.md"
rc18=0
console next --bucket missingrepo --doc "$missing_doc" >/dev/null 2>&1 || rc18=$?
check "18 next --doc <missing predecessor> exits non-zero" "$([ "$rc18" -ne 0 ] && echo yes)" "yes"
after18="$(find "$root" -type f -not -path "$root/.locks/*" | sort)"
check "18 next --doc <missing predecessor> writes nothing" "$before18" "$after18"

# --- 19: a RELATIVE --doc outside state_dir still yields an absolute
# HANDOFF reference (canonicalised, not left relative to whatever cwd the
# successor happens to launch from).
out19a="$(console new --bucket relsrc)"
token19a="$(token_of "$out19a")"
doc19A="$root/tester/relsrc/DEMO-nextleg-${today}A-console.md"
handoff19A="$root/tester/relsrc/DEMO-nextleg-${today}A-console-HANDOFF.md"
doc19B="$root/tester/reldst/DEMO-nextleg-${today}B-console.md"
# console() cd's into $fixture_repo before invoking console.sh, and
# fixture_repo/root are both direct children of $tmp -- so this relative
# path, taken from that cwd, resolves to the same file as doc19A.
rel19_doc="../handovers/tester/relsrc/DEMO-nextleg-${today}A-console.md"
console next --bucket reldst --doc "$rel19_doc" >/dev/null
check "19 next --doc (relative) still writes the successor stub" "$([ -f "$doc19B" ] && echo yes)" "yes"
check "19 next --doc (relative) writes the HANDOFF beside the predecessor" "$([ -f "$handoff19A" ] && echo yes)" "yes"
check "19 successor stub names an ABSOLUTE HANDOFF reference" "$(grep -cF "$handoff19A" "$doc19B")" "1"
check "19 successor stub does not embed the relative --doc literally" "$(grep -cF '../handovers' "$doc19B")" "0"
HANDOVER_DIR="$root" bash "$QL" release "$doc19A" "$token19a" >/dev/null 2>&1

# --- 20: --prefix is refused, not silently rewritten, on a path-escape --
before20="$(find "$root" -type f -not -path "$root/.locks/*" | sort)"
rc20=0
console new --bucket prefixtest --prefix '../OTHER' >/dev/null 2>&1 || rc20=$?
check "20 new --prefix '../OTHER' exits non-zero" "$([ "$rc20" -ne 0 ] && echo yes)" "yes"
after20="$(find "$root" -type f -not -path "$root/.locks/*" | sort)"
check "20 new --prefix '../OTHER' writes nothing" "$before20" "$after20"

# --- 21: a value containing '&' renders through the template intact ----
# (bash 5.2+'s patsub_replacement would otherwise treat an UNQUOTED '&' in
# the replacement as "insert the matched text").
root_amp="$tmp/hand&over"
mkdir -p "$root_amp"
out21="$(console_root "$root_amp" new --bucket ampbucket)"
doc21="$root_amp/tester/ampbucket/DEMO-nextleg-${today}A-console.md"
check "21 new with '&' in the handover root writes the doc" "$([ -f "$doc21" ] && echo yes)" "yes"
check "21 doc has no surviving placeholder" "$(grep -c '{{' "$doc21" 2>/dev/null)" "0"
check "21 doc contains the literal '&' path intact" "$([ "$(grep -cF "$root_amp" "$doc21")" -gt 0 ] && echo yes)" "yes"
token21="$(token_of "$out21")"
HANDOVER_DIR="$root_amp" bash "$QL" release "$doc21" "$token21" >/dev/null 2>&1

# --- 22: the resolved prefix is validated for EVERY source, not just the
# --prefix flag -- JIRA_PROJECT_KEY reaches the same path construction.
before22="$(find "$root" -type f -not -path "$root/.locks/*" | sort)"
rc22=0
( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY='../OTHER' \
    bash "$C" new --bucket envprefixtest ) >/dev/null 2>&1 || rc22=$?
check "22 JIRA_PROJECT_KEY='../OTHER' is refused" "$([ "$rc22" -ne 0 ] && echo yes)" "yes"
after22="$(find "$root" -type f -not -path "$root/.locks/*" | sort)"
check "22 JIRA_PROJECT_KEY='../OTHER' writes nothing" "$before22" "$after22"

# --- 23: HANDOFF creation is exclusive-create too, closing the same class
# of race the successor-doc claim closed: two `next` runs targeting
# DIFFERENT successor buckets but the SAME predecessor must not both
# render (and thereby clobber) the one shared HANDOFF.
out23a="$(console new --bucket handoffracesrc)"
token23a="$(token_of "$out23a")"
doc23A="$root/tester/handoffracesrc/DEMO-nextleg-${today}A-console.md"
handoff23A="$root/tester/handoffracesrc/DEMO-nextleg-${today}A-console-HANDOFF.md"

console next --bucket handoffracedst1 --doc "$doc23A" >/dev/null
doc23B1="$root/tester/handoffracedst1/DEMO-nextleg-${today}B-console.md"
check "23 first next writes its own successor" "$([ -f "$doc23B1" ] && echo yes)" "yes"
check "23 first next creates the HANDOFF" "$([ -f "$handoff23A" ] && echo yes)" "yes"
sum23_before="$(cksum < "$handoff23A")"

console next --bucket handoffracedst2 --doc "$doc23A" >/dev/null
doc23B2="$root/tester/handoffracedst2/DEMO-nextleg-${today}B-console.md"
check "23 second next (different bucket, same predecessor) still writes its own successor" "$([ -f "$doc23B2" ] && echo yes)" "yes"
sum23_after="$(cksum < "$handoff23A")"
check "23 the shared HANDOFF is left byte-identical, not re-rendered" "$sum23_before" "$sum23_after"
HANDOVER_DIR="$root" bash "$QL" release "$doc23A" "$token23a" >/dev/null 2>&1

# --- 24: a non-writable predecessor directory aborts, rather than being
# misread as "HANDOFF already exists" -- `: >` under noclobber fails for
# ANY reason, not just a genuine collision.
out24a="$(console new --bucket rodir)"
token24a="$(token_of "$out24a")"
doc24A="$root/tester/rodir/DEMO-nextleg-${today}A-console.md"
chmod 555 "$root/tester/rodir"
if test_dir_unwritable "$root/tester/rodir" "24 non-writable predecessor dir"; then
    rc24=0
    out24b="$(console next --bucket rodst --doc "$doc24A" 2>&1)" || rc24=$?
    check "24 non-writable predecessor dir: next --doc exits non-zero" "$([ "$rc24" -ne 0 ] && echo yes)" "yes"
    check "24 non-writable predecessor dir: no launch line printed" "$(printf '%s\n' "$out24b" | grep -c '^launch: ')" "0"
fi
chmod 755 "$root/tester/rodir"
HANDOVER_DIR="$root" bash "$QL" release "$doc24A" "$token24a" >/dev/null 2>&1

# --- 25: next is ATOMIC on the HANDOFF-create abort path -- it must not
# strand a successor stub the operator has to hand-delete before a retry.
# Three steps, the third being the actual control: abort, no stub left,
# THEN the identical retry with permissions restored must succeed -- proof
# recovery works, not just that something got deleted.
out25a="$(console new --bucket atomicsrc)"
token25a="$(token_of "$out25a")"
doc25A="$root/tester/atomicsrc/DEMO-nextleg-${today}A-console.md"
doc25B="$root/tester/atomicdst/DEMO-nextleg-${today}B-console.md"
handoff25A="$root/tester/atomicsrc/DEMO-nextleg-${today}A-console-HANDOFF.md"

chmod 555 "$root/tester/atomicsrc"
if test_dir_unwritable "$root/tester/atomicsrc" "25 HANDOFF-create abort / no stub / retry"; then
    rc25=0
    console next --bucket atomicdst --doc "$doc25A" >/dev/null 2>&1 || rc25=$?
    check "25 step1: aborts non-zero" "$([ "$rc25" -ne 0 ] && echo yes)" "yes"
    check "25 step2: leaves no successor stub" "$([ -f "$doc25B" ] && echo yes || echo no)" "no"

    chmod 755 "$root/tester/atomicsrc"
    rc25b=0
    console next --bucket atomicdst --doc "$doc25A" >/dev/null 2>&1 || rc25b=$?
    check "25 step3 (the control): the identical retry now succeeds" "$rc25b" "0"
    check "25 step3: the retry actually wrote the successor doc" "$([ -f "$doc25B" ] && echo yes)" "yes"
    check "25 step3: the retry actually wrote the HANDOFF" "$([ -f "$handoff25A" ] && echo yes)" "yes"
else
    chmod 755 "$root/tester/atomicsrc"
fi
HANDOVER_DIR="$root" bash "$QL" release "$doc25A" "$token25a" >/dev/null 2>&1

# --- 25b: the same abort / no stub / retry chain through HANDOFF rendering.
# An unresolved placeholder fails after the successor was already rendered.
render_tpl_dir="$tmp/render-failure-templates"
mkdir -p "$render_tpl_dir" "$root/tester/rendersrc"
cp "$REPO_REAL/docs/handover/console-template.md" "$render_tpl_dir/console-template.md"
printf '{{BROKEN_PLACEHOLDER}}\n' > "$render_tpl_dir/console-handoff-template.md"
doc25bA="$root/tester/rendersrc/DEMO-nextleg-${today}A-console.md"
doc25bB="$root/tester/renderdst/DEMO-nextleg-${today}B-console.md"
handoff25bA="$root/tester/rendersrc/DEMO-nextleg-${today}A-console-HANDOFF.md"
printf 'predecessor\n' > "$doc25bA"
rc25c=0
out25c="$(CONSOLE_TEMPLATE_DIR="$render_tpl_dir" console next --bucket renderdst --doc "$doc25bA" 2>&1)" || rc25c=$?
check "25b step1: render aborts with exit 1" "$rc25c" "1"
check "25b step1: failure names the unresolved placeholder" "$(printf '%s\n' "$out25c" | grep -c 'unresolved placeholder {{BROKEN_PLACEHOLDER}}')" "1"
check "25b step1: render failure prints no launch line" "$(printf '%s\n' "$out25c" | grep -c '^launch: ')" "0"
check "25b step2: leaves no successor stub" "$([ -e "$doc25bB" ] && echo yes || echo no)" "no"
check "25b step2: leaves no partial HANDOFF" "$([ -e "$handoff25bA" ] && echo yes || echo no)" "no"
cp "$REPO_REAL/docs/handover/console-handoff-template.md" "$render_tpl_dir/console-handoff-template.md"
rc25d=0
CONSOLE_TEMPLATE_DIR="$render_tpl_dir" console next --bucket renderdst --doc "$doc25bA" >/dev/null 2>&1 || rc25d=$?
check "25b step3 (the control): retry with repaired template succeeds" "$rc25d" "0"
check "25b step3: retry wrote the successor doc" "$([ -s "$doc25bB" ] && echo yes)" "yes"
check "25b step3: retry wrote the HANDOFF" "$([ -s "$handoff25bA" ] && echo yes)" "yes"

# --- 26: {{RELEASE_TOKEN}} carries the REAL acquired token into the doc on
# --arm -- the one path that had no other way to deliver it to the launched
# console. A minimal stub template (this test's own, not the real one under
# docs/) isolates console.sh's own contract: capture-and-embed, independent
# of when the template's own {{RELEASE_TOKEN}} lands. The control is the
# LAST check: releasing with the token READ OUT OF THE DOCUMENT must
# succeed -- asserting only that a token-shaped string is present would
# also pass on a wrong token.
stub_tpl_dir="$tmp/stub-templates"
mkdir -p "$stub_tpl_dir"
cat > "$stub_tpl_dir/console-template.md" <<'EOF'
# {{LETTER}} stub
predecessor: {{PREDECESSOR}}
predecessor_handoff: {{PREDECESSOR_HANDOFF}}
session: {{SESSION_NAME}}
handover_root: {{HANDOVER_ROOT}}
state_dir: {{STATE_DIR}}
repo: {{REPO}}
prefix: {{PREFIX}}
bucket: {{BUCKET}}
kit: {{KIT}}
fill_signal: {{FILL_SIGNAL}}
fill_percent: {{FILL_PERCENT}}
release_token: {{RELEASE_TOKEN}}
EOF

out26="$( ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CONSOLE_TEMPLATE_DIR="$stub_tpl_dir" CONSOLE_HEADED_ARM="$tmp/stub-arm.sh" \
    CONSOLE_ARM_FOREGROUND=1 CONSOLE_WORK_DIR="$tmp/work" \
    bash "$C" new --bucket tokenbucket --arm ) )"
doc26="$root/tester/tokenbucket/DEMO-nextleg-${today}A-console.md"
token26_printed="$(token_of "$out26")"
check "26 new --arm prints a release-token line" "$([ -n "$token26_printed" ] && echo yes)" "yes"
check "26 doc has no surviving placeholder" "$(grep -c '{{' "$doc26" 2>/dev/null)" "0"
token26_in_doc="$(sed -n 's/^release_token: //p' "$doc26" | head -n 1)"
check "26 the token embedded in the doc matches the printed token" "$token26_in_doc" "$token26_printed"
rc26=0
HANDOVER_DIR="$root" bash "$QL" release "$doc26" "$token26_in_doc" >/dev/null 2>&1 || rc26=$?
check "26 the control: release using the token read out of the document succeeds" "$rc26" "0"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
