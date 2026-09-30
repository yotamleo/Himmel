#!/usr/bin/env bash
# Tests for scripts/lib/chokepoint-seam-guard.sh (HIMMEL-3914).
# Usage: bash scripts/lib/test-chokepoint-seam-guard.sh
# Hermetic: the verdict, overlay and registry rows run on fixture files, the
# ancestry rows on a fake /proc tree. The gate itself only enforces on the
# anchor copy under a live claude ancestor, which a suite never is - that
# end-to-end path is covered by the static wiring rows plus the fail-closed
# source rows (each chokepoint copied WITHOUT the lib must exit 96).
# Platform guard (gitbash-only): POSIX bash 3.2+; a test fixture needs no .ps1
# twin (WS5 T15 convention).
set -uo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$LIB_DIR/../.." && pwd)"
LIB="$LIB_DIR/chokepoint-seam-guard.sh"
REGISTRY="$REPO/scripts/chokepoints.json"
# shellcheck source=chokepoint-seam-guard.sh
# shellcheck disable=SC1091
if ! { [ -r "$LIB" ] && . "$LIB"; }; then
    echo "FAIL cannot load $LIB"
    exit 1
fi

FAILED=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label — expected '$expected', got '$actual'"
        FAILED=$((FAILED + 1))
    fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/csg-test.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)
A="$TMP/anchor"; mkdir -p "$A/.claude" "$TMP/other" "$TMP/home/.claude"
ln -s "$A" "$TMP/anchor-link"

# mkenv <file> <k=v>... - a NUL-separated environ file.
mkenv() {
    local f="$1" kv
    shift
    : > "$f"
    for kv in "$@"; do printf '%s\0' "$kv" >> "$f"; done
}
# v <verdict args...> - "rc|mismatched,names" from _csg_verdict.
v() {
    local out rc
    out=$(_csg_verdict "$@")
    rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ',')"
}
unset CSGT_A CSGT_B CSGT_C CSGT_N

E="$TMP/env"
mkenv "$E" PATH=/bin HOME=/h CSGT_A=1 "CSGT_N=x"$'\n'

# --- Verdict --------------------------------------------------------------
assert_eq "V1 set in the call, unset at launch -> DENY" "1|CSGT_B" "$(CSGT_B=1 v "$E" "$A" "$A" "CSGT_B")"
assert_eq "V2 set at launch, unset in the call (a per-call clear) -> DENY" "1|CSGT_A" "$(v "$E" "$A" "$A" "CSGT_A")"
assert_eq "V3 value differs -> DENY" "1|CSGT_A" "$(CSGT_A=2 v "$E" "$A" "$A" "CSGT_A")"
assert_eq "V4 empty in the call, unset at launch -> DENY" "1|CSGT_B" "$(CSGT_B='' v "$E" "$A" "$A" "CSGT_B")"
assert_eq "V5 equal -> ALLOW" "0|" "$(CSGT_A=1 v "$E" "$A" "$A" "CSGT_A")"
assert_eq "V6a trailing newline kept on both sides -> ALLOW" "0|" "$(CSGT_A=1 CSGT_N=x$'\n' v "$E" "$A" "$A" "CSGT_A CSGT_N")"
assert_eq "V6b trailing newline dropped in the call -> DENY" "1|CSGT_N" "$(CSGT_A=1 CSGT_N=x v "$E" "$A" "$A" "CSGT_A CSGT_N")"
assert_eq "V7 a var outside this chokepoint's seams differs -> ALLOW" "0|" "$(CSGT_A=1 CSGT_C=9 v "$E" "$A" "$A" "CSGT_A")"
assert_eq "V8 both unset -> ALLOW" "0|" "$(v "$E" "$A" "$A" "CSGT_B")"
assert_eq "V9 an invalid seam name in the registry -> DENY" "1|BAD-NAME" "$(CSGT_A=1 v "$E" "$A" "$A" "CSGT_A BAD-NAME")"
assert_eq "V10 every mismatch named" "1|CSGT_A,CSGT_B" "$(CSGT_B=1 v "$E" "$A" "$A" "CSGT_A CSGT_B")"
: > "$TMP/empty-env"
assert_eq "V11 empty launch environ -> rc 2" "2|" "$(CSGT_A=1 v "$TMP/empty-env" "$A" "$A" "CSGT_A")"
assert_eq "V12 unreadable launch environ -> rc 2" "2|" "$(CSGT_A=1 v "$TMP/no-such-env" "$A" "$A" "CSGT_A")"

# --- Anchor scope ----------------------------------------------------------
assert_eq "A1 non-anchor copy with a mismatch -> ALLOW" "0|" "$(CSGT_B=1 v "$E" "$A" "$TMP/other" "CSGT_B")"
assert_eq "A2 no anchor -> ALLOW" "0|" "$(CSGT_B=1 v "$E" "" "$A" "CSGT_B")"
assert_eq "A3 anchor reached through a symlink is still the anchor -> DENY" "1|CSGT_B" "$(CSGT_B=1 v "$E" "$TMP/anchor-link" "$A" "CSGT_B")"

# --- Settings overlay ------------------------------------------------------
U="$TMP/home/.claude/settings.json"
printf '%s\n' '{"env":{"CSGT_B":"from-user","CSGT_A":"user-loses","CSGT_C":5}}' > "$U"
P="$A/.claude/settings.json"; L="$A/.claude/settings.local.json"
printf '%s\n' '{"env":{"CSGT_B":"from-project"}}' > "$P"
printf '%s\n' '{"env":{"CSGT_B":"from-local"}}' > "$L"
assert_eq "S1a user settings env, absent from environ, equal in the call -> ALLOW" "0|" "$(CSGT_A=1 CSGT_B=from-user v "$E" "$A" "$A" "CSGT_A CSGT_B" "$U")"
assert_eq "S1b user settings env, absent from environ, cleared in the call -> DENY" "1|CSGT_B" "$(CSGT_A=1 v "$E" "$A" "$A" "CSGT_A CSGT_B" "$U")"
assert_eq "S2 environ wins over a settings env block" "0|" "$(CSGT_A=1 v "$E" "$A" "$A" "CSGT_A" "$U")"
assert_eq "S2b the losing settings value is refused" "1|CSGT_A" "$(CSGT_A=user-loses v "$E" "$A" "$A" "CSGT_A" "$U")"
assert_eq "S3a local precedes project precedes user" "0|" "$(CSGT_B=from-local v "$E" "$A" "$A" "CSGT_B" "$L" "$P" "$U")"
assert_eq "S3b a lower level's value is refused" "1|CSGT_B" "$(CSGT_B=from-project v "$E" "$A" "$A" "CSGT_B" "$L" "$P" "$U")"
assert_eq "S4 a non-string settings value compares as its JSON text" "0|" "$(CSGT_C=5 v "$E" "$A" "$A" "CSGT_C" "$U")"
printf '%s\n' '{not json' > "$TMP/bad.json"
assert_eq "S5 a missing or malformed settings file reads as unset" "1|CSGT_B" "$(CSGT_B=x v "$E" "$A" "$A" "CSGT_B" "$TMP/nope.json" "$TMP/bad.json")"

# Overlay file list: which levels are read at all.
EH="$TMP/env-home"; mkenv "$EH" PATH=/bin "HOME=$TMP/home"
EC="$TMP/env-cfg"; mkenv "$EC" PATH=/bin "HOME=$TMP/home" "CLAUDE_CONFIG_DIR=$TMP/cfg"
assert_eq "O1 cwd is the anchor -> local, project, user" \
    "$A/.claude/settings.local.json,$A/.claude/settings.json,$TMP/home/.claude/settings.json," \
    "$(_csg_overlay_files "$A" "$A" "$EH" | tr '\n' ',')"
assert_eq "O2 cwd is not the anchor -> user only" "$TMP/home/.claude/settings.json," \
    "$(_csg_overlay_files "$TMP/other" "$A" "$EH" | tr '\n' ',')"
assert_eq "O3 CLAUDE_CONFIG_DIR at launch -> the user file is not read" "$A/.claude/settings.local.json,$A/.claude/settings.json," \
    "$(_csg_overlay_files "$A" "$A" "$EC" | tr '\n' ',')"
# The per-leg --settings file is session-writable: a seam only it sets DENIES.
LEG="$TMP/leg-settings.json"
printf '%s\n' '{"env":{"CSGT_B":"from-leg"}}' > "$LEG"
got=$(_csg_overlay_files "$A" "$A" "$EH")
case "$got" in *"$LEG"*) leg=listed ;; *) leg=absent ;; esac
assert_eq "O4a the --settings file is never in the overlay" "absent" "$leg"
set -f
# shellcheck disable=SC2086 # the list is newline-separated fixture paths with no spaces
set -- $got
set +f
assert_eq "O4b a seam matching only the --settings file -> DENY" "1|CSGT_B" "$(CSGT_B=from-leg v "$E" "$A" "$A" "CSGT_B" "$@")"
set --

# --- Registry --------------------------------------------------------------
assert_eq "R1 quiet-run enforces every seam but the internal HELD" \
    "HIMMEL_SUITE_SLOTS HIMMEL_SUITE_SEMAPHORE_DIR HIMMEL_SUITE_SLOT_TTL" \
    "$(_csg_registry_seams "$REGISTRY" scripts/quiet-run.sh)"
assert_eq "R2 run-shell-tests enforces every seam but the internal HELD" \
    "HIMMEL_SUITE_SLOTS HIMMEL_SUITE_SEMAPHORE_DIR HIMMEL_SUITE_SLOT_TTL" \
    "$(_csg_registry_seams "$REGISTRY" scripts/ci/run-shell-tests.sh)"
assert_eq "R3 merge-on-green enforces its full list" \
    "ARMAUTOMERGE MERGE_ON_GREEN_LOG HIMMEL_CONSOLE_LEG HANDOVER_DIR HIMMEL_REPO" \
    "$(_csg_registry_seams "$REGISTRY" scripts/handover/merge-on-green.sh)"
_csg_registry_seams "$REGISTRY" scripts/not-a-chokepoint.sh >/dev/null; rc=$?
assert_eq "R4 an unregistered key fails (the gate then refuses)" "fail" "$([ "$rc" -ne 0 ] && echo fail || echo ok)"
_csg_registry_seams "$TMP/no-registry.json" scripts/quiet-run.sh >/dev/null; rc=$?
assert_eq "R5 an unreadable registry fails (the gate then refuses)" "fail" "$([ "$rc" -ne 0 ] && echo fail || echo ok)"

# --- Ancestry on a fake /proc ----------------------------------------------
# mkproc <root> <pid> <ppid> <comm> <exe|-> <argv...>
mkproc() {
    local root="$1" pid="$2" ppid="$3" comm="$4" exe="$5" a
    shift 5
    mkdir -p "$root/$pid"
    printf '%s (%s) S %s 1 1 0\n' "$pid" "$comm" "$ppid" > "$root/$pid/stat"
    : > "$root/$pid/cmdline"
    for a in "$@"; do printf '%s\0' "$a" >> "$root/$pid/cmdline"; done
    [ "$exe" = - ] || ln -s "$exe" "$root/$pid/exe"
}
walk() {
    local out rc
    out=$(_csg_find_outermost "$@")
    rc=$?
    printf '%s|%s' "$rc" "$out"
}
F1="$TMP/proc1"
mkproc "$F1" 1 0 systemd /usr/lib/systemd/systemd /sbin/init
mkproc "$F1" 10 1 bash /usr/bin/bash bash
mkproc "$F1" 20 10 bash /usr/bin/bash bash
assert_eq "P1 no claude ancestor -> empty, rc 0" "0|" "$(walk "$F1" 20)"
F2="$TMP/proc2"
mkproc "$F2" 1 0 systemd - /sbin/init
mkproc "$F2" 5 1 konsole /usr/bin/konsole konsole -e claude
mkproc "$F2" 10 5 claude /opt/claude/versions/2.1.285 claude --settings x
mkproc "$F2" 20 10 zsh /usr/bin/zsh zsh
mkproc "$F2" 30 20 claude "$TMP/fake/claude" "$TMP/fake/claude"
mkproc "$F2" 40 30 bash /usr/bin/bash bash
assert_eq "P2 the outermost claude wins over a nested fake" "0|10" "$(walk "$F2" 40)"
assert_eq "P3 konsole carrying claude in its argv is not claude" "0|" "$(walk "$F2" 5)"
F3="$TMP/proc3"
mkproc "$F3" 1 0 systemd - /sbin/init
mkproc "$F3" 10 1 node /x/bin/claude node /x/cli.js
mkproc "$F3" 20 10 "a) b" /usr/bin/bash bash
assert_eq "P4 exe basename claude matches; a comm holding ') ' parses" "0|10" "$(walk "$F3" 20)"
F4="$TMP/proc4"
mkproc "$F4" 1 0 systemd - /sbin/init
mkproc "$F4" 20 10 bash /usr/bin/bash bash
assert_eq "P5 a missing intermediate stat -> rc 2" "2|" "$(walk "$F4" 20)"
F5="$TMP/proc5"
mkproc "$F5" 20 10 claude - claude
mkproc "$F5" 30 20 bash - bash
assert_eq "P6 a missing stat after a claude match -> rc 2" "2|" "$(walk "$F5" 30)"
F6="$TMP/proc6"
mkproc "$F6" 20 20 bash - bash
assert_eq "P7 a self-parented pid -> rc 2" "2|" "$(walk "$F6" 20)"
assert_eq "P8 a non-numeric start pid -> rc 2" "2|" "$(walk "$F1" abc)"
F7="$TMP/proc7"; mkdir -p "$F7/20"; printf '%s\n' '20 bash S 1' > "$F7/20/stat"
assert_eq "P9 a stat without the comm close -> rc 2" "2|" "$(walk "$F7" 20)"
F8="$TMP/proc8"
mkproc "$F8" 1 0 systemd - /sbin/init
mkproc "$F8" 10 1 node /usr/bin/node node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js
mkproc "$F8" 15 10 node /usr/bin/node node /srv/app/cli.js
mkproc "$F8" 20 15 bash /usr/bin/bash bash
assert_eq "P11 an npm claude (node running claude-code/cli.js) matches; other node does not" "0|10" "$(walk "$F8" 20)"
if [ -r /proc/self/stat ]; then
    live=$(walk /proc "$$")
    assert_eq "P10 the real /proc walks cleanly from this shell" "0" "${live%%|*}"
else
    echo "SKIP P10 no /proc on this host"
fi

# --- The gate on a non-anchor copy -----------------------------------------
# This file's tree is never the anchor under a suite (a worktree, a CI checkout
# or a fixture), so a mismatching seam is allowed here whatever the ancestry.
out=$(HIMMEL_SUITE_SLOTS=csgt-mismatch chokepoint_seam_guard scripts/quiet-run.sh 2>&1); rc=$?
assert_eq "G1 the gate allows a non-anchor copy" "0|" "$rc|$out"

# --- The whole gate on a fake /proc with a fixture anchor --------------------
# The anchor is a fixture tree holding a copy of the lib and the registry, so
# BASH_SOURCE puts the gate's root there; the fake claude's environ names it.
GA="$TMP/ganchor"; GH="$TMP/ghome"
mkdir -p "$GA/scripts/lib" "$GH/.claude"
cp "$LIB" "$GA/scripts/lib/chokepoint-seam-guard.sh"
cp "$REGISTRY" "$GA/scripts/chokepoints.json"
git -c init.defaultBranch=main init -q "$GA"
printf '%s\n' '{"env":{"ARMAUTOMERGE":"1"}}' > "$GH/.claude/settings.json"
# mkclaude <proc-root> <cwd|-> <environ k=v...> - pid 1 <- 10 claude <- 20 bash.
mkclaude() {
    local root="$1" cwd="$2"
    shift 2
    mkdir -p "$root/self"; : > "$root/self/stat"
    mkproc "$root" 1 0 systemd - /sbin/init
    mkproc "$root" 10 1 claude /opt/claude/versions/2.1.285 claude
    mkproc "$root" 20 10 bash /usr/bin/bash bash
    [ "$cwd" = - ] || ln -s "$cwd" "$root/10/cwd"
    mkenv "$root/10/environ" "$@"
}
# gate <proc-root> <key> [VAR=val...] - "rc" of the fixture gate, run with
# every go.sh / merge-on-green seam cleared first, then the given ones set.
gate() {
    local proc="$1" key="$2"
    shift 2
    # shellcheck disable=SC2016 # $1..$3 expand in the child bash, by design
    env -u ARMAUTOMERGE -u MERGE_ON_GREEN_LOG -u HIMMEL_CONSOLE_LEG -u HANDOVER_DIR -u HIMMEL_REPO "$@" \
        bash -c '. "$1" && _csg_gate "$2" 20 "$3"' _ "$GA/scripts/lib/chokepoint-seam-guard.sh" "$proc" "$key" 2>"$TMP/gate.err"
    printf '%s' "$?"
}
GO=scripts/handover/console-kit/go.sh
MOG=scripts/handover/merge-on-green.sh
Q1="$TMP/gproc1"; mkclaude "$Q1" "$GA" PATH=/bin "HOME=$GH" "HIMMEL_REPO=$GA" HIMMEL_CONSOLE_LEG=1
assert_eq "G2 anchor copy, seams equal to launch -> ALLOW" "0" "$(gate "$Q1" "$GO" "HIMMEL_REPO=$GA" HIMMEL_CONSOLE_LEG=1)"
assert_eq "G3 anchor copy, a per-call clear of a launch seam -> 96" "96" "$(gate "$Q1" "$GO" "HIMMEL_REPO=$GA")"
case "$(cat "$TMP/gate.err")" in
    *HIMMEL_CONSOLE_LEG*"set it in the launching shell"*) said=named ;;
    *) said=silent ;;
esac
assert_eq "G3b the refusal names the seam and the remedy" "named" "$said"
rc=$(gate "$Q1" "$GO" "HIMMEL_REPO=$GA" HIMMEL_CONSOLE_LEG=csgt-call-value)
case "$(cat "$TMP/gate.err")" in *csgt-call-value*) leak=value ;; *) leak=none ;; esac
assert_eq "G3c a differing value is refused and never printed" "96|none" "$rc|$leak"
assert_eq "G4 anchor copy, a per-call set of an absent seam -> 96" "96" "$(gate "$Q1" "$MOG" "HIMMEL_REPO=$GA" HIMMEL_CONSOLE_LEG=1 MERGE_ON_GREEN_LOG=/tmp/x)"
assert_eq "G5 a seam from the user settings env, absent from environ -> ALLOW" "0" "$(gate "$Q1" "$MOG" "HIMMEL_REPO=$GA" HIMMEL_CONSOLE_LEG=1 ARMAUTOMERGE=1)"
assert_eq "G6 an unregistered key on the anchor -> 96" "96" "$(gate "$Q1" scripts/not-a-chokepoint.sh "HIMMEL_REPO=$GA" HIMMEL_CONSOLE_LEG=1)"
Q2="$TMP/gproc2"; mkclaude "$Q2" "$GA" PATH=/bin "HOME=$GH" "HIMMEL_REPO=$TMP/other"
assert_eq "G7 launch anchor is another tree -> ALLOW despite a mismatch" "0" "$(gate "$Q2" "$GO" HIMMEL_CONSOLE_LEG=1)"
Q3="$TMP/gproc3"; mkclaude "$Q3" "$GA" PATH=/bin "HOME=$GH" HIMMEL_CONSOLE_LEG=1
assert_eq "G8a no HIMMEL_REPO: the claude cwd's primary checkout is the anchor -> ALLOW when equal" "0" "$(gate "$Q3" "$GO" HIMMEL_CONSOLE_LEG=1)"
assert_eq "G8b no HIMMEL_REPO: the cwd fallback still enforces -> 96" "96" "$(gate "$Q3" "$GO" HIMMEL_CONSOLE_LEG=0)"
assert_eq "G8c a caller's git config env cannot blank the cwd fallback -> 96" "96" "$(gate "$Q3" "$GO" HIMMEL_CONSOLE_LEG=0 "GIT_CONFIG_PARAMETERS='bad" "GIT_CEILING_DIRECTORIES=$TMP")"
Q4="$TMP/gproc4"; mkclaude "$Q4" - PATH=/bin "HOME=$GH" "HIMMEL_REPO=$GA"
assert_eq "G9 the claude cwd is unreadable -> 96" "96" "$(gate "$Q4" "$GO" "HIMMEL_REPO=$GA")"
Q5="$TMP/gproc5"; mkclaude "$Q5" "$GA" PATH=/bin; rm -f "$Q5/10/environ"
assert_eq "G10 the claude environ is unreadable -> 96" "96" "$(gate "$Q5" "$GO")"
Q6="$TMP/gproc6"; mkclaude "$Q6" "$GA" PATH=/bin "HIMMEL_REPO=$GA"; rm -rf "$Q6/1"
assert_eq "G11 a walk error past the claude match -> 96" "96" "$(gate "$Q6" "$GO" "HIMMEL_REPO=$GA")"
Q7="$TMP/gproc7"; mkclaude "$Q7" "$GA" PATH=/bin "HIMMEL_REPO=$GA"; rm -rf "$Q7/self"
assert_eq "G12 no /proc (non-Linux) -> ALLOW despite a mismatch" "0" "$(gate "$Q7" "$GO" HIMMEL_CONSOLE_LEG=1)"
Q8="$TMP/gproc8"; mkdir -p "$Q8/self"; : > "$Q8/self/stat"
mkproc "$Q8" 1 0 systemd - /sbin/init
mkproc "$Q8" 20 1 bash /usr/bin/bash bash
assert_eq "G13 no claude ancestor (CI, a plain terminal) -> ALLOW" "0" "$(gate "$Q8" "$GO" HIMMEL_CONSOLE_LEG=1)"
# A PATH-shadowed jq/readlink/git would forge an empty seam list or a foreign
# anchor; the gate resolves its tools from fixed system dirs instead.
EVIL="$TMP/evil-bin"; mkdir -p "$EVIL"
for t in jq readlink git env; do
    printf '#!/bin/sh\nexit 0\n' > "$EVIL/$t"; chmod +x "$EVIL/$t"
done
assert_eq "G14 a PATH-shadowed jq/readlink/git cannot forge an allow -> 96" "96" "$(gate "$Q1" "$GO" "HIMMEL_REPO=$GA" "PATH=$EVIL:$PATH")"
# A curated PATH holding only bash (test-bank-preflight's no-timeout case)
# must not break the gate: equal seams still ALLOW.
BARE="$TMP/bare-bin"; mkdir -p "$BARE"; ln -s "$(command -v bash)" "$BARE/bash"
assert_eq "G15 a curated PATH without jq/readlink/git still resolves -> ALLOW" "0" "$(gate "$Q1" "$GO" "HIMMEL_REPO=$GA" HIMMEL_CONSOLE_LEG=1 "PATH=$BARE")"

# --- Wiring: every chokepoint sources the lib and calls the gate first -------
KEYS=$(jq -r 'keys[]' "$REGISTRY")
for key in $KEYS; do
    f="$REPO/$key"
    gl=$(grep -n -x "chokepoint_seam_guard $key" "$f" | head -n 1 | cut -d: -f1)
    assert_eq "W1 $key calls the gate with its own registry key" "yes" "$([ -n "$gl" ] && echo yes || echo no)"
    [ -n "$gl" ] || continue
    alt=$(jq -r --arg k "$key" '.[$k].seam_env_vars | join("|")' "$REGISTRY")
    sl=$(grep -n -E "(^|[^A-Za-z0-9_])($alt)([^A-Za-z0-9_]|$)" "$f" | grep -v -E '^[0-9]+:[[:space:]]*#' | head -n 1 | cut -d: -f1)
    assert_eq "W2 $key: the gate precedes the first seam reference" "yes" "$([ -z "$sl" ] || [ "$gl" -lt "$sl" ] && echo yes || echo no)"
    hl=$(grep -n -E '^\. .*anchor-handoff\.sh' "$f" | head -n 1 | cut -d: -f1)
    assert_eq "W3 $key: the gate runs after any anchor hand-off" "yes" "$([ -z "$hl" ] || [ "$hl" -lt "$gl" ] && echo yes || echo no)"
    rel=$(grep -E '^_csg_lib=' "$f" | head -n 1 | sed -E 's#^_csg_lib="\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/(.*)"$#\1#')
    assert_eq "W4 $key: the sourced path resolves to this lib" "yes" "$([ -n "$rel" ] && [ "$(dirname "$f")/$rel" -ef "$LIB" ] && echo yes || echo no)"
done

# --- Fail closed: a chokepoint whose lib is missing refuses with 96 ---------
# Each copy runs by absolute path (anchor-handoff is then a no-op) in a scrubbed
# env with a fixture HOME and cwd, so nothing past the source step can reach a
# real repo, forge or ledger.
FC="$TMP/failclosed"
mkdir -p "$FC/home" "$FC/scripts/cr"
cp "$REPO/scripts/cr/anchor-handoff.sh" "$FC/scripts/cr/anchor-handoff.sh"
for key in $KEYS; do
    mkdir -p "$FC/$(dirname "$key")"
    cp "$REPO/$key" "$FC/$key"
    out=$(cd "$FC/home" && env -i PATH="/usr/bin:/bin" HOME="$FC/home" bash "$FC/$key" --help </dev/null 2>&1); rc=$?
    case "$out" in *"cannot load"*"HIMMEL-3914"*) said=named ;; *) said=silent ;; esac
    assert_eq "F1 $key without its lib -> rc 96, names the lib" "96|named" "$rc|$said"
done

if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED FAILED"
exit 1
