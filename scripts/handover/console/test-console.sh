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

# Templated (BSD/macOS mktemp requires one); refuse loudly on failure BEFORE
# the EXIT trap is registered — an empty $tmp would otherwise make the trap
# clean up the wrong thing.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/console-test.XXXXXX")" || { echo "test-console: mktemp -d failed" >&2; exit 1; }
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

console() {  # console <args...> -- invoke console.sh with cwd pinned to the
             # fixture repo and a fixed temp handover identity.
    ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO bash "$C" "$@" )
}

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
HANDOVER_DIR="$root" bash "$QL" release "$doc6bSrc" "$token6ba" >/dev/null 2>&1

# --- 7: next --arm with a stub arm target ------------------------------
doc7A="$root/tester/armrepo/DEMO-nextleg-${today}A-console.md"
session7B="DEMO-nextleg-${today}B-console"
log7B="$tmp/work/launch-${session7B}.log"

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
check "8 no leak under the temp handover root" "$(grep -rniE "$BANNED" "$root" 2>/dev/null | wc -l | tr -d ' ')" "0"
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

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
