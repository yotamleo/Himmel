#!/usr/bin/env bash
# shellcheck disable=SC2015
# scripts/handover/console/test-console.sh — RED/GREEN suite for console.sh
#
# Every case runs against a TEMP handover root AND a throwaway fixture
# "repo" (a fresh `git init` holding REAL copies of scripts/handover,
# scripts/lib and docs/handover, the rest of scripts/ and docs/ symlinked
# back to this checkout's real ones): console.sh resolves its own "repo"
# from its OWN location (`git -C $HERE rev-parse --git-common-dir`),
# never the cwd, and git resolves a symlinked dir
# physically -- so a symlinked scripts/ would resolve to this checkout's
# PRIMARY, whose path lives under this operator's real home directory, embed
# it into every doc console.sh writes and trip the private-string-leak check
# (case 8). The suite runs console.sh from the fixture's copy, so the
# resolved repo path is a clean /tmp path.
#
# Platform guard (gitbash-only): POSIX bash 3.2+; exercises console.sh,
# which is konsole/Linux-only for --arm (see console.sh's own header) —
# same platform scope, no .ps1 twin.
set -uo pipefail

# a bus-identified console's `next` leaves the relay-on-live marker unasked; only 6e sets it
unset HIMMEL_BUS_NAME
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_REAL="$(cd "$HERE/../../.." && pwd)"
QL="$REPO_REAL/scripts/handover/queue-lock.sh"
# shellcheck source=../../lib/permission-test.sh
. "$HERE/../../lib/permission-test.sh"
# shellcheck source=../../lib/host-caps.sh
. "$HERE/../../lib/host-caps.sh"
# shellcheck source=../../lib/timeout-bin.sh
. "$HERE/../../lib/timeout-bin.sh"
# Cases 27/29/30/40 need a real symlink, 31/32/33/36/39/41/42 a
# chmod / `mkdir -m` that sticks -- neither holds on Git Bash / NTFS, so those
# cases SKIP there (measured, not keyed off uname) rather than fail.
HOST_SYMLINKS_REAL=0; host_symlinks_real && HOST_SYMLINKS_REAL=1
HOST_MODES_STICK=0; host_modes_stick && HOST_MODES_STICK=1

# Templated (BSD/macOS mktemp requires one); refuse loudly on failure BEFORE
# the EXIT trap is registered — an empty $tmp would otherwise make the trap
# clean up the wrong thing.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/console-test.XXXXXX")" || { echo "test-console: mktemp -d failed" >&2; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# console.sh records the launch context of the console it prints a
# launch line for, under ${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}/launch-logs.
# Pin that dir under $tmp for the WHOLE suite so no case can leave a fixture row
# (session DEMO-nextleg-...) in the operator's real launch-record directory.
export HIMMELCTL_CACHE_DIR="$tmp/himmelctl-cache"

# registry_lookup_for_project() falls back
# to $HOME/.claude/handover/registry.json when HANDOVER_REGISTRY is unset. Pin
# it to a path that never exists for the WHOLE suite, so every --project case
# that doesn't set its own scratch registry stays hermetic -- never reads the
# operator's real registry (Do-Not: tests use scratch copies only).
export HANDOVER_REGISTRY="$tmp/no-registry-for-this-suite.json"

# console.sh renders the resolved inbox path into every doc. Pin
# BRIDGE_ROOT under $tmp for the WHOLE suite so no doc embeds the operator's
# real home directory (case 8 scans the temp root for private strings).
export BRIDGE_ROOT="$tmp/bridge"

# `next` pre-fills the HANDOFF through handoff-facts.sh, which reads
# the bank and open PRs. Stub both for the WHOLE suite so no case reads the real
# bank or calls gh.
printf '#!/usr/bin/env bash\necho "bank-preflight: leg=unknown five_hour=9.0 seven_day=91.0 extra_usage=n/a"\necho PROCEED\n' > "$tmp/facts-bank.sh"
printf '#!/usr/bin/env bash\necho "#5 [DEMO-1] stub pr (feat/x)"\n' > "$tmp/facts-prs.sh"
export HANDOFF_FACTS_BANK="$tmp/facts-bank.sh" HANDOFF_FACTS_PRS="$tmp/facts-prs.sh"
# `next` pre-computes ACTION ZERO through action-zero.sh. A stub keeps every case
# fast and keeps the lock sweep's host names out of case 8's leak scan; case 90
# runs the real script.
printf '#!/usr/bin/env bash\necho "== STUB action-zero"\n' > "$tmp/az-stub.sh"
export ACTION_ZERO_SCRIPT="$tmp/az-stub.sh"

fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

# A hand-made outgoing doc: `next` refuses one with no real `## Current direction` block.
stub_doc() { printf '%s\n' "$1" '' '## Current direction' '' 'In work: the fixture.'; }

fixture_repo="$tmp/repo"
mkdir -p "$fixture_repo"
git init -q "$fixture_repo"
mkdir -p "$fixture_repo/scripts" "$fixture_repo/docs"
for _e in "$REPO_REAL"/scripts/* "$REPO_REAL"/docs/*; do
    case "$_e" in
        "$REPO_REAL/scripts/handover"|"$REPO_REAL/scripts/lib") cp -R "$_e" "$fixture_repo/scripts/" ;;
        "$REPO_REAL/docs/handover") cp -R "$_e" "$fixture_repo/docs/" ;;
        "$REPO_REAL"/scripts/*) ln -s "$_e" "$fixture_repo/scripts/${_e##*/}" ;;
        *) ln -s "$_e" "$fixture_repo/docs/${_e##*/}" ;;
    esac
done
C="$fixture_repo/scripts/handover/console/chief.sh"

root="$tmp/handovers"
mkdir -p "$root"
today="$(date +%F)"

# root_digest_of <canonical-root> -- mirrors console.sh's _console_sha256_8:
# first 8 hex chars of the sha256 of the resolved, canonicalized handover
# root. $root is already canonical here (built via `pwd -P`
# above), so no realpath step is needed for fixture roots.
root_digest_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | cut -d' ' -f1 | cut -c1-8
    else
        printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1 | cut -c1-8
    fi
}
root_digest="$(root_digest_of "$root")"

console_root() {  # console_root <root> <args...> -- invoke console.sh with
                  # cwd pinned to the fixture repo, against an ARBITRARY
                  # handover root (used by cases exercising a non-default
                  # root, e.g. one containing a space). CHIEF_WORK_DIR is
                  # pinned to an isolated fixture dir so the eager work-dir
                  # hardening never touches, and every case
                  # here never collides on, the REAL live
                  # /tmp/himmel-console-<uid> tree other running consoles use.
    local r="$1"; shift
    ( cd "$fixture_repo" && HANDOVER_DIR="$r" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO CHIEF_WORK_DIR="$tmp/defaultwork" bash "$C" "$@" )
}

console() { console_root "$root" "$@"; }

# Acquire prints the token backticked
# ("release-token: `<token>`"); strip a matched pair so callers get the bare
# token either way -- a no-op on the pre-2910 bare form.
token_of() {
    local t
    t="$(printf '%s\n' "$1" | sed -n 's/^release-token: //p')"
    t="${t#\`}"
    t="${t%\`}"
    printf '%s' "$t"
}

# --- 1/2/3/4: new, placeholder cleanliness, lock lifecycle, idempotent bump
docA="$root/tester/demorepo/DEMO-nextleg-${today}A-console.md"
docB="$root/tester/demorepo/DEMO-nextleg-${today}B-console.md"

out1="$(console new --bucket demorepo)"
check "1 new writes the console doc" "$([ -f "$docA" ] && echo yes)" "yes"
check "1 Telegram metadata records the console bucket" "$(grep -c '"bucket":"demorepo"' "$BRIDGE_ROOT/consoles/DEMO-nextleg-${today}A-console.md.meta.json" 2>/dev/null || true)" "1"
check "2 doc has no surviving placeholder" "$(grep -c '{{' "$docA" 2>/dev/null)" "0"
# The step-10/11 commands carry the RESOLVED literal inbox path,
# never a ${BRIDGE_ROOT:-...} expansion guard-pr-check-literal denies.
check "2b doc has no BRIDGE_ROOT expansion" "$(grep -c 'BRIDGE_ROOT' "$docA" 2>/dev/null)" "0"
# shellcheck disable=SC2016  # literal, unexpanded on purpose
check "2b step-10/11 commands carry no \${ expansion" "$(grep -E 'console-wait.sh|`: >> ' "$docA" 2>/dev/null | grep -cF '${')" "0"
check "2b doc names the BRIDGE_ROOT override inbox literally" "$(grep -cF "$BRIDGE_ROOT/consoles/DEMO-nextleg-${today}A-console.md" "$docA" 2>/dev/null)" "3"
docInboxDefault="$root/tester/inboxdefault/DEMO-nextleg-${today}A-console.md"
outInbox="$( unset BRIDGE_ROOT; HOME="$tmp/inboxhome" console new --bucket inboxdefault 2>&1 )"
tokenInbox="$(token_of "$outInbox")"
# Release now: a held lock's owner files carry the host name (case 8 leak scan).
HANDOVER_DIR="$root" bash "$QL" release "$docInboxDefault" "$tokenInbox" >/dev/null 2>&1
check "2c unset BRIDGE_ROOT renders the HOME default inbox literally" "$(grep -cF "$tmp/inboxhome/.claude/handover/bridge/consoles/DEMO-nextleg-${today}A-console.md" "$docInboxDefault" 2>/dev/null)" "3"

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
t4_start=$SECONDS
out4="$(console new --bucket demorepo)"
# Bash 3.2's ${var//pat/rep} render burned ~60 s per call on macOS
# (Linux: <1 s). Generous bound; RED only reproduces on bash 3.2 / macOS.
check "4 new renders in bounded time" "$([ $((SECONDS - t4_start)) -lt 20 ] && echo yes)" "yes"
# render_template must splice values LITERALLY ('&', backslash,
# '/', '$', quotes, newline).
(
    # shellcheck disable=SC2317,SC2329  # called by the eval'd render_template
    err() { echo "$@" >&2; }
    eval "$(sed -n '/^render_template() {/,/^}/p' "$C")"
    tpl="$REPO_REAL/docs/handover/console-template.md"
    # shellcheck disable=SC2016  # literal, unexpanded on purpose
    rv='a&b\c/$d"q
line2'
    set --
    for _k in $(grep -o '{{[A-Z_]*}}' "$tpl" | sort -u | tr -d '{}'); do set -- "$@" "$_k" "$rv-$_k"; done
    render_template "$tpl" "$tmp/render-new.md" "$@"
) || echo "render row setup failed" >&2
# shellcheck disable=SC2016  # literal, unexpanded on purpose
check "4 render_template: every placeholder became the literal value" "$(grep -oF 'a&b\c/$d"q' "$tmp/render-new.md" | wc -l | tr -d ' ')" "$(grep -o '{{[A-Z_]*}}' "$REPO_REAL/docs/handover/console-template.md" | wc -l | tr -d ' ')"
check "4 render_template: multiline value tail preserved" "$(grep -oE 'line2-[A-Z_]+' "$tmp/render-new.md" | wc -l | tr -d ' ')" "$(grep -o '{{[A-Z_]*}}' "$REPO_REAL/docs/handover/console-template.md" | wc -l | tr -d ' ')"
check "4 render_template: no placeholder survives" "$(grep -c '{{[A-Z_]*}}' "$tmp/render-new.md")" "0"
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

# --- 5b: consoles default to 1m/auto, not standard.
out5b="$(unset CHIEF_CONTEXT CONSOLE_CONTEXT; console new --bucket dryrepo5b --dry-run)"
check "5b default launch line carries --autocompact auto" \
    "$(printf '%s\n' "$out5b" | grep -c -- '--autocompact auto')" "1"
check "5b default launch line carries no --autocompact 200000" \
    "$(printf '%s\n' "$out5b" | grep -c -- '--autocompact 200000')" "0"
# The console launch line applies the console plugin profile.
check "5b launch line carries --settings <console profile>" \
    "$(printf '%s\n' "$out5b" | grep -c -- 'claude --settings [^ ]*/console.json --model ')" "1"
# The console loads only its profile's MCP servers (no graphify).
check "5b launch line carries --mcp-config <console.mcp.json> --strict-mcp-config" \
    "$(printf '%s\n' "$out5b" | grep -c -- '--mcp-config [^ ]*/console.mcp.json --strict-mcp-config ')" "1"
# An allowlist that does not resolve (the settings still do) refuses
# the printed launch line: rc 2 and no launch line at all.
python3 - "$REPO_REAL/scripts/lanes/plugin-profiles.json" "$tmp/registry-5310.json" <<'PYE'
import json, sys
d = json.load(open(sys.argv[1]))
d["profiles"]["console"]["mcpServers"] = ["qmd", "no-such-server-5310"]
json.dump(d, open(sys.argv[2], "w"))
PYE
rc5d=0
out5d="$(PLUGIN_PROFILES_REGISTRY="$tmp/registry-5310.json" console new --bucket dryrepo5d --dry-run 2>&1)" || rc5d=$?
check "5d unresolvable MCP allowlist: console new --dry-run exits 2" "$rc5d" "2"
check "5d unresolvable MCP allowlist: no launch line printed" \
    "$(printf '%s\n' "$out5d" | grep -c -- 'launch:')" "0"
out5c="$(CHIEF_CONTEXT=1m console new --bucket dryrepo5c --dry-run)"
check "5c CHIEF_CONTEXT=1m launch line carries --autocompact auto" \
    "$(printf '%s\n' "$out5c" | grep -c -- '--autocompact auto')" "1"
check "5c CHIEF_CONTEXT=1m launch line carries no --autocompact 200000" \
    "$(printf '%s\n' "$out5c" | grep -c -- '--autocompact 200000')" "0"

# Catch console default regressions and ignored CLI overrides.
out3884="$(unset CHIEF_CONTEXT CONSOLE_CONTEXT; console next --bucket demorepo --doc "$docA" --dry-run)"
check "3884 next defaults to --autocompact auto" \
    "$(printf '%s\n' "$out3884" | grep -c -- '--autocompact auto')" "1"
check "3884 next records 1m default auto" \
    "$(printf '%s\n' "$out3884" | grep -c -- "record-launch.sh DEMO-nextleg-${today}B-console 1m default auto")" "1"
for command3884 in new next; do
    out3884="$(CHIEF_CONTEXT=1m console "$command3884" --bucket demorepo --context standard --dry-run)"
    check "3884 $command3884 --context standard overrides env" \
        "$(printf '%s\n' "$out3884" | grep -c -- '--autocompact 200000')" "1"
    check "3884 $command3884 standard source is explicit" \
        "$(printf '%s\n' "$out3884" | grep -c -- 'standard explicit 200000')" "1"
    out3884="$(CHIEF_CONTEXT=standard console "$command3884" --bucket demorepo --context=1m --dry-run)"
    check "3884 $command3884 --context=1m overrides env" \
        "$(printf '%s\n' "$out3884" | grep -c -- '1m explicit auto')" "1"
    rc3884=0
    out3884="$(console "$command3884" --bucket demorepo --context bogus --dry-run 2>&1)" || rc3884=$?
    check "3884 $command3884 bogus context refused" "$rc3884" "2"
    check "3884 $command3884 bogus diagnostic" \
        "$(printf '%s\n' "$out3884" | grep -c -- '--context must be 1m or standard')" "1"
done
out3884="$(CHIEF_CONTEXT=standard console new --bucket dry3884 --dry-run)"
check "3884 env opt-down is explicit" \
    "$(printf '%s\n' "$out3884" | grep -c -- 'standard explicit 200000')" "1"
resolved3884="$(. "$REPO_REAL/scripts/lib/chief-context.sh"; console_context_default 0 1m; printf '%s %s' "$CHIEF_CONTEXT_RESOLVED_MODE" "$CHIEF_CONTEXT_RESOLVED_SOURCE")"
check "3884 non-console ignores env and stays standard" "$resolved3884" "standard default"

# --- 5d: the printed launch line must clear the inherited
# child-session marker. An operator pastes this line into a terminal that was
# itself spawned from a claude session, so CLAUDE_CODE_CHILD_SESSION=1,
# CLAUDE_PID and CLAUDE_CODE_SESSION_ID are live in that shell's environment.
# Without an `env -u` prefix the new console adopts them, writes no transcript,
# and cannot read its own context fill -- which is the handover trigger its
# operating contract is built on. headed-arm.sh already does this for the leg
# path; the printed line was missed.
for v in CLAUDE_CODE_CHILD_SESSION CLAUDE_PID CLAUDE_CODE_SESSION_ID; do
    check "5d launch line unsets $v" \
        "$(printf '%s\n' "$out5b" | grep -c -- "-u $v")" "1"
done
check "5d launch line forces session persistence" \
    "$(printf '%s\n' "$out5b" | grep -c -- 'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1')" "1"
# The env prefix must precede the binary, not trail it -- `claude ... env -u X`
# would pass the flags to claude as arguments instead of scrubbing anything.
check "5d env prefix precedes the claude binary" \
    "$(printf '%s\n' "$out5b" | grep -c -E '^(would-)?launch: cd [^;]* && \{ bash [^;]*record-launch.sh [^;]*; (if \[ -f [^;]*console-bus-exec.sh \]; then bash [^;]*console-bus-exec.sh [^;]* -- )?env( -u [A-Z_]+)+ CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 claude ')" "1"

# --- 6: next writes the successor stub + predecessor HANDOFF ----------
doc6A="$root/tester/nextrepo/DEMO-nextleg-${today}A-console.md"
doc6B="$root/tester/nextrepo/DEMO-nextleg-${today}B-console.md"
handoff6A="$root/tester/nextrepo/DEMO-nextleg-${today}A-console-HANDOFF.md"

out6a="$(console new --bucket nextrepo)"
token6a="$(token_of "$out6a")"
# a WRAPPED leg whose doc names a PR that is still open is carried into the HANDOFF
# (the stub PR set above is just #5); a WRAPPED leg naming a closed PR is not.
printf '%s\n' '# leg' '## Results' '- 10:00 READY 5 aaaa GREEN' '- 10:05 WRAPPED — done' > "$root/tester/nextrepo/DEMO-1-N9-wrapped.md"
printf '%s\n' '# leg' '## Results' '- 10:00 READY 77 bbbb GREEN' '- 10:05 WRAPPED — done' > "$root/tester/nextrepo/DEMO-2-N8-closed.md"
printf '{"legs":[{"label":"N9","doc":"%s"},{"label":"N8","doc":"%s"}]}\n' "$root/tester/nextrepo/DEMO-1-N9-wrapped.md" "$root/tester/nextrepo/DEMO-2-N8-closed.md" > "$root/tester/nextrepo/DEMO-nextleg-${today}A-console.fleet.json"
console next --bucket nextrepo >/dev/null
check "6 next writes successor stub" "$([ -f "$doc6B" ] && echo yes)" "yes"
check "6 Telegram metadata records the successor bucket" "$(grep -c '"bucket":' "$BRIDGE_ROOT/consoles/DEMO-nextleg-${today}B-console.md.meta.json" 2>/dev/null || true)" "1"
check "6 next writes predecessor HANDOFF" "$([ -f "$handoff6A" ] && echo yes)" "yes"
check "6 successor stub names the predecessor" "$(grep -c "DEMO-nextleg-${today}A-console.md" "$doc6B")" "1"
check "6 successor has no surviving placeholder" "$(grep -c '{{' "$doc6B" 2>/dev/null)" "0"
check "6 successor has no BRIDGE_ROOT expansion" "$(grep -c 'BRIDGE_ROOT' "$doc6B" 2>/dev/null)" "0"
check "6 successor names its inbox literally" "$(grep -cF "$BRIDGE_ROOT/consoles/DEMO-nextleg-${today}B-console.md" "$doc6B" 2>/dev/null)" "3"
check "6 handoff has no surviving placeholder" "$(grep -c '{{' "$handoff6A" 2>/dev/null)" "0"
# The mechanical fields are pre-filled by handoff-facts.sh (the
# bank and PR commands are stubbed above), so the console writes only judgement
# notes; and `next` puts the predecessor's waiter in handover mode.
check "6 handoff pre-fills the bank line" "$(grep -c '^\*\*Bank at write:\*\* 5-hour 9.0 %, 7-day 91.0 %' "$handoff6A")" "1"
check "6 handoff pre-fills the open PRs" "$(grep -c '^#5 \[DEMO-1\] stub pr' "$handoff6A")" "1"
check "6 handoff keeps no sha/url placeholder" "$(grep -E '^\*\*(Head|Bank at write):\*\*' "$handoff6A" | grep -c '<sha>\|<origin url>\|<n> %')" "0"
check "6 handoff carries a WRAPPED leg whose PR is still open (HIMMEL-5542)" "$(grep -c '^- PR #5 (N9), orphan since .*DEMO-1-N9-wrapped.md' "$handoff6A")" "1"
check "6 handoff omits a WRAPPED leg whose PR is closed (HIMMEL-5542)" "$(grep -c '^- PR #77' "$handoff6A")" "0"
check "6 handoff section tells the successor to disposition before dispatch (HIMMEL-5542)" "$(grep -c '^## Wrapped with open PR' "$handoff6A")" "1"
check "6 handoff leaves one judgement-notes block" "$(grep -c '^## Rulings and judgement notes' "$handoff6A")" "1"
check "6 next puts the predecessor waiter in handover mode" "$(cat "$BRIDGE_ROOT/consoles/DEMO-nextleg-${today}A-console.md.handover" 2>/dev/null)" "DEMO-nextleg-${today}B-console"

# --- 6c: the GENERATED stub and HANDOFF must not tell the
# successor to mint and rotate a fresh nonce per leg -- leg-preface.md (the
# authority) says a relay MAY keep the leg's token. Asserted on the emitted
# files, not the templates: this is what every console hand-patched.
stale6c='mint a fresh|rotate nonces to|hands you a fresh token per leg'
check "6c control: the stale-rotation pattern matches the pre-#967 wording" \
    "$(printf '%s\n' 'So, per leg: mint a fresh B-<leg>-<hex> token, hand it to the predecessor' | grep -icE "$stale6c")" "1"
check "6c successor stub carries no mint-and-rotate instruction" \
    "$(tr '\n' ' ' < "$doc6B" | tr -s ' ' | grep -icE "$stale6c")" "0"
check "6c HANDOFF carries no mint-and-rotate instruction" \
    "$(tr '\n' ' ' < "$handoff6A" | tr -s ' ' | grep -icE "$stale6c")" "0"
check "6c successor stub says rotation is not a precondition of succession" \
    "$(tr '\n' ' ' < "$doc6B" | tr -s ' ' | grep -c 'rotation is not a precondition')" "1"
check "6c HANDOFF says a relay MAY keep the leg's token" \
    "$(tr '\n' ' ' < "$handoff6A" | tr -s ' ' | grep -c 'MAY keep')" "1"
HANDOVER_DIR="$root" bash "$QL" release "$doc6A" "$token6a" >/dev/null 2>&1

# --- 6d: --relay-on-live leaves a marker (line 1 successor, line 2 its doc) beside the
# predecessor's inbox; a plain `next` leaves none; the flag is next-only.
out6da="$(console new --bucket reldemo)"
token6da="$(token_of "$out6da")"
doc6dA="$root/tester/reldemo/DEMO-nextleg-${today}A-console.md"
doc6dB="$root/tester/reldemo/DEMO-nextleg-${today}B-console.md"
mark6d="$BRIDGE_ROOT/consoles/DEMO-nextleg-${today}A-console.md.relay-on-live"
console next --bucket reldemo >/dev/null
check "6d plain next leaves no relay-on-live marker" "$([ -f "$mark6d" ] && echo yes || echo no)" "no"
rm -f "$doc6dB" "$BRIDGE_ROOT/consoles/DEMO-nextleg-${today}A-console.md.handover"
console next --bucket reldemo --relay-on-live >/dev/null
check "6d next --relay-on-live writes the successor session on line 1" "$(sed -n 1p "$mark6d" 2>/dev/null)" "DEMO-nextleg-${today}B-console"
check "6d next --relay-on-live writes the successor doc on line 2" "$(sed -n 2p "$mark6d" 2>/dev/null)" "$doc6dB"
check "6d --relay-on-live is next-only" "$(console new --bucket reldemo2 --relay-on-live >/dev/null 2>&1; echo $?)" "1"
# 6e: a console with a bus identity gets the marker without the flag, so its waiter runs
# relay-batch.sh (bus record + SendMessage lines) instead of a hand relay that leaves the
# legs with no bus edge to the successor.
rm -f "$doc6dB" "$BRIDGE_ROOT/consoles/DEMO-nextleg-${today}A-console.md.handover" "$mark6d"
rc6e=0
HIMMEL_BUS_NAME="DEMO-nextleg-${today}A-console" console next --bucket reldemo >/dev/null || rc6e=$?
check "6e bus-identified next succeeds" "$rc6e" "0"
check "6e next from a bus-identified console writes the relay-on-live marker unasked" "$(sed -n 1p "$mark6d" 2>/dev/null)" "DEMO-nextleg-${today}B-console"
HANDOVER_DIR="$root" bash "$QL" release "$doc6dA" "$token6da" >/dev/null 2>&1

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
# Signal/log live under a chain-identity subdir ($slug-$bucket-$digest), not
# $workdir directly -- bucket-only-differing chains
# must not collide on the same signal/log path, and chains under
# DIFFERENT handover roots must not collide either, hence the root digest).
log7B="$tmp/work/tester-armrepo-${root_digest}/launch-${session7B}.log"

cat > "$tmp/stub-arm.sh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = --role ] && shift 2
echo "armed: name=$1 doc=$2 signal=$3 deadline=$4 context=${7:-${CHIEF_CONTEXT:-default}}" >> "$5"
STUB
chmod +x "$tmp/stub-arm.sh"

out7a="$(console new --bucket armrepo)"
token7a="$(token_of "$out7a")"
out7b="$( ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_HEADED_ARM="$tmp/stub-arm.sh" CHIEF_ARM_FOREGROUND=1 CHIEF_WORK_DIR="$tmp/work" CHIEF_CONTEXT=1m \
    bash "$C" next --bucket armrepo --arm --deadline-min 0 --context standard ) )"
check "7 next --arm reports armed" "$(printf '%s\n' "$out7b" | grep -c '^armed: ')" "1"
check "7 arm log written" "$([ -f "$log7B" ] && echo yes)" "yes"
check "3884 explicit context reaches actual arm input" "$(grep -c 'context=standard$' "$log7B")" "1"
check "3884 explicit context agrees with printed launch" "$(printf '%s\n' "$out7b" | grep -c -- 'standard explicit 200000')" "1"
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
# the {{RELEASE_TOKEN}} placeholder deliberately writes into every console
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
known_tokens=("$token1" "$token4" "$token6a" "$token6ba" "$token6da" "$token7a" "$tokenInbox")
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
check "8 no leak in .claude/commands/chief.md" "$(leak_free "$REPO_REAL/.claude/commands/chief.md")" "yes"

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
out10="$(console new --bucket namebucket --name '../evil-console')"
docNameSlug="$root/tester/namebucket/DEMO-nextleg-${today}A-evil-console.md"
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
out12a="$(console new --bucket nightbucket --name night-console)"
token12a="$(token_of "$out12a")"
doc12A="$root/tester/nightbucket/DEMO-nextleg-${today}A-night-console.md"
check "12 new --name night-console writes A-night doc" "$([ -f "$doc12A" ] && echo yes)" "yes"

console next --bucket nightbucket --name night-console >/dev/null
doc12B="$root/tester/nightbucket/DEMO-nextleg-${today}B-night-console.md"
check "12 next --name night-console writes B-night doc" "$([ -f "$doc12B" ] && echo yes)" "yes"
HANDOVER_DIR="$root" bash "$QL" release "$doc12A" "$token12a" >/dev/null 2>&1

# --- 12b: next --doc alone derives a non-default name from the basename -
out12ba="$(console new --bucket nightsrc --name night-console)"
token12ba="$(token_of "$out12ba")"
doc12bA="$root/tester/nightsrc/DEMO-nextleg-${today}A-night-console.md"
console next --bucket nightdst --doc "$doc12bA" >/dev/null
doc12bB="$root/tester/nightdst/DEMO-nextleg-${today}B-night-console.md"
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
stub_doc predecessor > "$predoc15"
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

# --- 16b: exhaustion requires ALL 702 letters (A-Z, AA-ZZ) as real
# collisions, not arbitrary I/O errors. The boundary is
# 26 (single letters) to 702 (single + bijective base-26 double letters), since
# `new` rolls past Z instead of refusing there.
mkdir -p "$root/tester/exhausted"
for letter16 in {A..Z}; do
    printf 'claimed\n' > "$root/tester/exhausted/DEMO-nextleg-${today}${letter16}-console.md"
done
for letter16a in {A..Z}; do
    for letter16b in {A..Z}; do
        printf 'claimed\n' > "$root/tester/exhausted/DEMO-nextleg-${today}${letter16a}${letter16b}-console.md"
    done
done
rc16b=0
out16b="$(console new --bucket exhausted 2>&1)" || rc16b=$?
check "16b all 702 letters (A-Z, AA-ZZ) claimed: exits 1" "$rc16b" "1"
check "16b all 702 letters claimed: reports past-ZZ exhaustion" "$(printf '%s\n' "$out16b" | grep -c 'past ZZ')" "1"

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
long16_name="$(printf '%0260d' 0)-console"
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

# --- 17b: case 17's sibling -- chains under DIFFERENT handover roots that
# otherwise agree on slug/bucket/prefix/date/letter/name must not collide
# on the same signal/log path either. Same $root twice would
# reuse letter A on the second call, so use two disjoint fixture roots.
root17b1="$tmp/handovers-17b1"
root17b2="$tmp/handovers-17b2"
mkdir -p "$root17b1" "$root17b2"
out17c="$(console_root "$root17b1" new --bucket samebucket --dry-run --arm)"
out17d="$(console_root "$root17b2" new --bucket samebucket --dry-run --arm)"
sig17c="$(printf '%s\n' "$out17c" | sed -n 's/.*signal=\([^ ]*\).*/\1/p' | head -n 1)"
sig17d="$(printf '%s\n' "$out17d" | sed -n 's/.*signal=\([^ ]*\).*/\1/p' | head -n 1)"
log17c="$(printf '%s\n' "$out17c" | sed -n 's/.*log=\([^ ]*\).*/\1/p' | head -n 1)"
log17d="$(printf '%s\n' "$out17d" | sed -n 's/.*log=\([^ ]*\).*/\1/p' | head -n 1)"
check "17b signal path differs when only HANDOVER_DIR differs" "$([ -n "$sig17c" ] && [ "$sig17c" != "$sig17d" ] && echo yes)" "yes"
check "17b log path differs when only HANDOVER_DIR differs" "$([ -n "$log17c" ] && [ "$log17c" != "$log17d" ] && echo yes)" "yes"

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
stub_doc predecessor > "$doc25bA"
rc25c=0
out25c="$(CHIEF_TEMPLATE_DIR="$render_tpl_dir" console next --bucket renderdst --doc "$doc25bA" 2>&1)" || rc25c=$?
check "25b step1: render aborts with exit 1" "$rc25c" "1"
check "25b step1: failure names the unresolved placeholder" "$(printf '%s\n' "$out25c" | grep -c 'unresolved placeholder {{BROKEN_PLACEHOLDER}}')" "1"
check "25b step1: render failure prints no launch line" "$(printf '%s\n' "$out25c" | grep -c '^launch: ')" "0"
check "25b step2: leaves no successor stub" "$([ -e "$doc25bB" ] && echo yes || echo no)" "no"
check "25b step2: leaves no partial HANDOFF" "$([ -e "$handoff25bA" ] && echo yes || echo no)" "no"
cp "$REPO_REAL/docs/handover/console-handoff-template.md" "$render_tpl_dir/console-handoff-template.md"
rc25d=0
CHIEF_TEMPLATE_DIR="$render_tpl_dir" console next --bucket renderdst --doc "$doc25bA" >/dev/null 2>&1 || rc25d=$?
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
    CHIEF_TEMPLATE_DIR="$stub_tpl_dir" CHIEF_HEADED_ARM="$tmp/stub-arm.sh" \
    CHIEF_ARM_FOREGROUND=1 CHIEF_WORK_DIR="$tmp/work" \
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

# --- 27: default work dir refuses a pre-created SYMLINK --
# Another local user could symlink the predictable default path elsewhere
# before this process's first run; the eager work-dir hardening must catch
# it regardless of --arm. TMPDIR is pointed at an isolated fixture dir (never
# real /tmp) and XDG_RUNTIME_DIR is unset so the TMPDIR-fallback branch of
# the resolution is the one under test.
if [ "$HOST_SYMLINKS_REAL" = 1 ]; then
tmp27="$tmp/c27"
mkdir -p "$tmp27/real-elsewhere"
ln -s "$tmp27/real-elsewhere" "$tmp27/himmel-console-$(id -u)"
rc27=0
out27="$( ( cd "$fixture_repo" && env -u XDG_RUNTIME_DIR -u CHIEF_WORK_DIR -u CONSOLE_WORK_DIR \
    HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO TMPDIR="$tmp27" \
    bash "$C" new --bucket wdlinktest --dry-run ) 2>&1 )" || rc27=$?
check "27 symlinked default work dir: refuses with a distinct exit code" "$rc27" "3"
check "27 symlinked default work dir: stderr names the cause" "$(printf '%s\n' "$out27" | grep -ci symlink)" "1"
check "27 symlinked default work dir: never followed into real-elsewhere" "$([ -n "$(find "$tmp27/real-elsewhere" -mindepth 1 2>/dev/null)" ] && echo yes || echo no)" "no"
else
    host_skip "27 symlinked default work dir: ln -s does not make a real link on this host"
fi

# --- 28: default work dir refuses a directory owned by a DIFFERENT uid;
# skipped cleanly (never faked) if this host offers no way
# to arrange one without privileges we do not have.
if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; then
    echo "ok - SKIPPED: default work dir owned by another uid (no passwordless privilege escalation on this host to arrange one - sudo -n true failed)"
else
    tmp28="$tmp/c28"
    mkdir -p "$tmp28/himmel-console-$(id -u)"
    if sudo -n chown nobody:nobody "$tmp28/himmel-console-$(id -u)" >/dev/null 2>&1; then
        rc28=0
        out28="$( ( cd "$fixture_repo" && env -u XDG_RUNTIME_DIR -u CHIEF_WORK_DIR -u CONSOLE_WORK_DIR \
            HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO TMPDIR="$tmp28" \
            bash "$C" new --bucket wdotheruid --dry-run ) 2>&1 )" || rc28=$?
        check "28 default work dir owned by another uid: refuses with a distinct exit code" "$rc28" "3"
        check "28 default work dir owned by another uid: stderr names the cause" "$(printf '%s\n' "$out28" | grep -ci owned)" "1"
        sudo -n chown "$(id -u):$(id -g)" "$tmp28/himmel-console-$(id -u)" >/dev/null 2>&1
    else
        echo "ok - SKIPPED: default work dir owned by another uid (sudo -n chown to nobody:nobody failed - no usable privilege on this host)"
    fi
fi

# --- 29: two spellings of the SAME handover root (a symlink alias) must
# digest to the SAME chain dir -- canonicalization has to
# happen before hashing, or a symlinked root would silently degrade back
# into the very collision the digest exists to prevent.
if [ "$HOST_SYMLINKS_REAL" = 1 ]; then
root29_link="$tmp/handovers-symlink"
ln -s "$root" "$root29_link"
out29a="$(console_root "$root" new --bucket digestsame --dry-run --arm)"
out29b="$(console_root "$root29_link" new --bucket digestsame --dry-run --arm)"
sig29a="$(printf '%s\n' "$out29a" | sed -n 's/.*signal=\([^ ]*\).*/\1/p' | head -n 1)"
sig29b="$(printf '%s\n' "$out29b" | sed -n 's/.*signal=\([^ ]*\).*/\1/p' | head -n 1)"
check "29 root spelled via a symlink alias yields the SAME signal path" "$([ -n "$sig29a" ] && [ "$sig29a" = "$sig29b" ] && echo yes)" "yes"
else
    host_skip "29 symlink-aliased handover root: ln -s does not make a real link on this host"
fi

# --- 30: work-dir creation TOCTOU -- if another local process wins the race between console.sh's
# `[ ! -e ]` absence check and its `mkdir -p` call, planting a directory or
# symlink first, `mkdir -p` treats the path as already-satisfied and returns
# 0 without creating anything; console_workdir_ensure must not trust that
# silent success and skip validation -- it must always re-check what is
# actually at the path afterward. A real race cannot be scheduled
# deterministically, so a PATH stub for `mkdir` simulates the race winner:
# it plants a symlink at the exact target path (mirroring what a hostile
# local user's pre-created symlink looks like once `mkdir -p` sees the path
# as already existing) and exits 0 -- exactly what the real `mkdir -p` does
# in that situation -- instead of ever actually creating the target
# directory.
if [ "$HOST_SYMLINKS_REAL" = 1 ]; then
tmp30="$tmp/c30"
mkdir -p "$tmp30/bin" "$tmp30/elsewhere-30"
target30="$tmp30/himmel-console-$(id -u)"
real_mkdir30="$(command -v mkdir)"
cat > "$tmp30/bin/mkdir" <<STUB_EOF
#!/usr/bin/env bash
for a in "\$@"; do
    if [ "\$a" = "$target30" ]; then
        ln -s "$tmp30/elsewhere-30" "$target30"
        exit 0
    fi
done
exec "$real_mkdir30" "\$@"
STUB_EOF
chmod +x "$tmp30/bin/mkdir"
rc30=0
out30="$( ( cd "$fixture_repo" && env -u XDG_RUNTIME_DIR -u CHIEF_WORK_DIR -u CONSOLE_WORK_DIR \
    HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO TMPDIR="$tmp30" \
    PATH="$tmp30/bin:$PATH" \
    bash "$C" new --bucket wdtoctou --dry-run ) 2>&1 )" || rc30=$?
check "30 work-dir creation TOCTOU: refuses with a distinct exit code" "$rc30" "3"
check "30 work-dir creation TOCTOU: stderr names the cause" "$(printf '%s\n' "$out30" | grep -ci symlink)" "1"
check "30 work-dir creation TOCTOU: never followed into elsewhere-30" "$([ -n "$(find "$tmp30/elsewhere-30" -mindepth 1 2>/dev/null)" ] && echo yes || echo no)" "no"
else
    host_skip "30 work-dir creation TOCTOU: ln -s does not make a real link on this host"
fi

# --- 31: XDG_RUNTIME_DIR itself group- or world-writable must NOT be
# trusted for the default work dir -- console_workdir_ensure only validates the CHILD
# ($XDG_RUNTIME_DIR/himmel-console) it creates; a local user with write
# access to the PARENT can still unlink/replace that child after
# validation completes (Unix permission semantics: write access to a
# directory controls its entries regardless of the entries' own
# permissions, absent a sticky bit like /tmp's). The selection must not
# prefer $XDG_RUNTIME_DIR when the directory itself is group- or
# world-writable; it must fall back to the uid-qualified TMPDIR path
# instead, exactly as it already does for a non-owned $XDG_RUNTIME_DIR.
if [ "$HOST_MODES_STICK" = 1 ]; then
tmp31="$tmp/c31"
mkdir -p "$tmp31/xdg" "$tmp31/tmp"
chmod 0777 "$tmp31/xdg"
out31="$( ( cd "$fixture_repo" && env -u CHIEF_WORK_DIR -u CONSOLE_WORK_DIR \
    HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    XDG_RUNTIME_DIR="$tmp31/xdg" TMPDIR="$tmp31/tmp" \
    bash "$C" new --bucket wdgwtest --dry-run --arm ) 2>&1 )"
sig31="$(printf '%s\n' "$out31" | sed -n 's/.*signal=\([^ ]*\).*/\1/p' | head -n 1)"
case "$sig31" in
    "$tmp31/xdg/himmel-console/"*) sig31_branch=rejected ;;
    "$tmp31/tmp/himmel-console-$(id -u)/"*) sig31_branch=fallback ;;
    *) sig31_branch="other:$sig31" ;;
esac
check "31 group/world-writable XDG_RUNTIME_DIR is not preferred" "$sig31_branch" "fallback"
else
    host_skip "31 group/world-writable XDG_RUNTIME_DIR: chmod does not stick on this host"
fi

# --- 32: a CHIEF_WORK_DIR override sitting under a group/world-writable,
# non-sticky PARENT must be refused -- console_workdir_ensure only ever validates the override path
# itself, never its parent; an override is exactly as reachable by another
# local user as the default path, so an insecure parent lets that user
# swap the (validated) override directory out from under this process the
# same way an insecure XDG_RUNTIME_DIR could. A sticky bit (as /tmp
# normally has) would neutralize this, which is why the fixture parent is
# deliberately NOT sticky (0777, not 1777).
if [ "$HOST_MODES_STICK" = 1 ]; then
tmp32="$tmp/c32"
mkdir -p "$tmp32/parent"
chmod 0777 "$tmp32/parent"
out32="$( ( cd "$fixture_repo" && env -u XDG_RUNTIME_DIR \
    HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_WORK_DIR="$tmp32/parent/work" \
    bash "$C" new --bucket wdparent32 --dry-run ) 2>&1 )"; rc32=$?
check "32 CHIEF_WORK_DIR under an insecure parent: refuses with a distinct exit code" "$rc32" "3"
check "32 CHIEF_WORK_DIR under an insecure parent: stderr names the cause" "$(printf '%s\n' "$out32" | grep -ci parent)" "1"
else
    host_skip "32 CHIEF_WORK_DIR under an insecure parent: chmod does not stick on this host"
fi

# --- 33: the TMPDIR-fallback work dir's parent (normally /tmp, sticky) must
# be checked the same way when TMPDIR itself is overridden to a
# group/world-writable, non-sticky directory (TMPDIR half). No XDG_RUNTIME_DIR and no CHIEF_WORK_DIR
# override, so the default TMPDIR-fallback path is exercised directly.
if [ "$HOST_MODES_STICK" = 1 ]; then
tmp33="$tmp/c33"
mkdir -p "$tmp33/insecure-tmp"
chmod 0777 "$tmp33/insecure-tmp"
out33="$( ( cd "$fixture_repo" && env -u XDG_RUNTIME_DIR -u CHIEF_WORK_DIR -u CONSOLE_WORK_DIR \
    HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    TMPDIR="$tmp33/insecure-tmp" \
    bash "$C" new --bucket wdparent33 --dry-run ) 2>&1 )"; rc33=$?
check "33 TMPDIR-fallback under an insecure TMPDIR: refuses with a distinct exit code" "$rc33" "3"
check "33 TMPDIR-fallback under an insecure TMPDIR: stderr names the cause" "$(printf '%s\n' "$out33" | grep -ci parent)" "1"
else
    host_skip "33 TMPDIR-fallback under an insecure TMPDIR: chmod does not stick on this host"
fi

# --- 34: a sticky PARENT owned by neither root nor us must still be refused
# -- a blanket sticky exemption would accept
# any sticky directory, but the sticky bit only protects entries from users
# who are NOT the directory's own owner; the owner can still rename/unlink
# entries inside their own directory regardless of the sticky bit, so a
# sticky directory owned by an attacker is not actually safe. A real
# attacker-owned fixture cannot be built without root, so a PATH stub for
# `stat` reports a foreign uid for this one fixture path while every other
# `stat` call (including console.sh's own real ones on other paths) passes
# through to the real binary unchanged.
tmp34="$tmp/c34"
mkdir -p "$tmp34/bin" "$tmp34/attacker-owned"
chmod 1777 "$tmp34/attacker-owned"
real_stat34="$(command -v stat)"
cat > "$tmp34/bin/stat" <<STUB_EOF
#!/usr/bin/env bash
if [ "\$1" = "-c" ] && [ "\$3" = "$tmp34/attacker-owned" ]; then
    case "\$2" in
        %a) echo 1777; exit 0 ;;
        %u) echo 31337; exit 0 ;;
    esac
fi
exec "$real_stat34" "\$@"
STUB_EOF
chmod +x "$tmp34/bin/stat"
out34="$( ( cd "$fixture_repo" && env -u XDG_RUNTIME_DIR -u CHIEF_WORK_DIR -u CONSOLE_WORK_DIR \
    HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    TMPDIR="$tmp34/attacker-owned" \
    PATH="$tmp34/bin:$PATH" \
    bash "$C" new --bucket wdparent34 --dry-run ) 2>&1 )"; rc34=$?
check "34 sticky but attacker-owned parent: refuses with a distinct exit code" "$rc34" "3"
check "34 sticky but attacker-owned parent: stderr names the cause" "$(printf '%s\n' "$out34" | grep -ci parent)" "1"

# --- 35 (control): a sticky parent owned by US (the real /tmp shape) must
# still be accepted -- proves the ownership check does not regress
# the plain /tmp case the sticky exemption exists for.
tmp35="$tmp/c35"
mkdir -p "$tmp35/self-owned"
chmod 1777 "$tmp35/self-owned"
rc35=0
( cd "$fixture_repo" && env -u XDG_RUNTIME_DIR -u CHIEF_WORK_DIR -u CONSOLE_WORK_DIR \
    HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    TMPDIR="$tmp35/self-owned" \
    bash "$C" new --bucket wdparent35 --dry-run ) >/dev/null 2>&1 || rc35=$?
check "35 sticky self-owned parent (real /tmp analogue): accepted" "$rc35" "0"

# --- 36: an insecure GRANDPARENT must be refused even when the immediate
# parent looks safe on its own:
# checking only the immediate parent leaves the rest of the ancestor
# chain unchecked; a local user with write access to a grandparent can
# rename/replace it, substituting the entire subtree including an
# otherwise-safe immediate parent.
if [ "$HOST_MODES_STICK" = 1 ]; then
tmp36="$tmp/c36"
mkdir -p "$tmp36/grandparent/parent"
chmod 0777 "$tmp36/grandparent"
chmod 0700 "$tmp36/grandparent/parent"
out36="$( ( cd "$fixture_repo" && env -u XDG_RUNTIME_DIR \
    HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_WORK_DIR="$tmp36/grandparent/parent/work" \
    bash "$C" new --bucket wdparent36 --dry-run ) 2>&1 )"; rc36=$?
check "36 insecure grandparent despite safe immediate parent: refuses with a distinct exit code" "$rc36" "3"
check "36 insecure grandparent despite safe immediate parent: stderr names the cause" "$(printf '%s\n' "$out36" | grep -ci parent)" "1"
else
    host_skip "36 insecure grandparent: chmod does not stick on this host"
fi

# --- 37: an attacker-owned parent that is NOT group/world-writable (e.g.
# mode 0755) must still be refused -- an ownership check on only the STICKY
# branch would leave this open; a non-writable-by-group/other directory was still accepted
# regardless of owner, but the owner of a directory can chmod it (or may
# already have owner-only write access at 0755) at any time after this
# check runs, so ownership by neither root nor us is disqualifying even
# when the current bits look tight. Same stat PATH-stub technique as case 34
# (no root available to build a real attacker-owned fixture).
tmp37="$tmp/c37"
mkdir -p "$tmp37/bin" "$tmp37/attacker-0755"
chmod 0755 "$tmp37/attacker-0755"
real_stat37="$(command -v stat)"
cat > "$tmp37/bin/stat" <<STUB_EOF
#!/usr/bin/env bash
if [ "\$1" = "-c" ] && [ "\$2" = "%u" ] && [ "\$3" = "$tmp37/attacker-0755" ]; then
    echo 31337; exit 0
fi
exec "$real_stat37" "\$@"
STUB_EOF
chmod +x "$tmp37/bin/stat"
out37="$( ( cd "$fixture_repo" && env -u XDG_RUNTIME_DIR -u CHIEF_WORK_DIR -u CONSOLE_WORK_DIR \
    HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    TMPDIR="$tmp37/attacker-0755" \
    PATH="$tmp37/bin:$PATH" \
    bash "$C" new --bucket wdparent37 --dry-run ) 2>&1 )"; rc37=$?
check "37 attacker-owned non-writable (0755) parent: refuses with a distinct exit code" "$rc37" "3"
check "37 attacker-owned non-writable (0755) parent: stderr names the cause" "$(printf '%s\n' "$out37" | grep -ci parent)" "1"

# --- 38 (control): a self-owned, non-writable (0755) parent must still be
# accepted -- proves the ownership-first ordering does not
# regress the ordinary, non-shared TMPDIR-fallback case.
tmp38="$tmp/c38"
mkdir -p "$tmp38/self-0755"
chmod 0755 "$tmp38/self-0755"
rc38=0
( cd "$fixture_repo" && env -u XDG_RUNTIME_DIR -u CHIEF_WORK_DIR -u CONSOLE_WORK_DIR \
    HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    TMPDIR="$tmp38/self-0755" \
    bash "$C" new --bucket wdparent38 --dry-run ) >/dev/null 2>&1 || rc38=$?
check "38 self-owned non-writable (0755) parent: accepted" "$rc38" "0"

# --- 39: a RELATIVE CHIEF_WORK_DIR must still walk the real ancestor
# chain above the current working directory -- a lexical `dirname` loop on a relative path like "work"
# stops at "." (dirname(".") is itself "."), so only the cwd is ever
# checked; canonicalizing to an absolute path first is required to reach an
# insecure ancestor sitting above cwd.
if [ "$HOST_MODES_STICK" = 1 ]; then
tmp39="$tmp/c39"
mkdir -p "$tmp39/insecure-ancestor/cwd-dir"
chmod 0777 "$tmp39/insecure-ancestor"
chmod 0700 "$tmp39/insecure-ancestor/cwd-dir"
out39="$( ( cd "$tmp39/insecure-ancestor/cwd-dir" && env -u XDG_RUNTIME_DIR \
    HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_WORK_DIR="work" \
    bash "$C" new --bucket wdparent39 --dry-run ) 2>&1 )"; rc39=$?
check "39 relative CHIEF_WORK_DIR under an insecure ancestor: refuses with a distinct exit code" "$rc39" "3"
check "39 relative CHIEF_WORK_DIR under an insecure ancestor: stderr names the cause" "$(printf '%s\n' "$out39" | grep -ci parent)" "1"
else
    host_skip "39 relative CHIEF_WORK_DIR under an insecure ancestor: chmod does not stick on this host"
fi

# --- 40: a symlink ANCESTOR of CHIEF_WORK_DIR must be resolved ONCE and
# the canonical form reused for every subsequent operation
# console_workdir_ensure already refuses
# $workdir itself being a symlink, but a symlink one level UP (workdir's
# own last component still a plain, not-yet-existing directory) isn't
# caught by that -- ancestor validation ran against the canonicalized path,
# while creation/chain_dir previously kept the ORIGINAL, still-symlinked
# spelling, so a swapped symlink between check and use could redirect
# actual filesystem access to an unvalidated location. Proven here by
# asserting the printed --dry-run --arm paths resolve through the REAL
# target, never through the symlink spelling.
if [ "$HOST_SYMLINKS_REAL" = 1 ]; then
tmp40="$tmp/c40"
mkdir -p "$tmp40/real-target"
chmod 0700 "$tmp40/real-target"
ln -s "$tmp40/real-target" "$tmp40/linky"
out40="$( ( cd "$fixture_repo" && env -u XDG_RUNTIME_DIR \
    HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_WORK_DIR="$tmp40/linky/subdir" \
    bash "$C" new --bucket wdparent40 --dry-run --arm ) 2>&1 )"; rc40=$?
check "40 symlink ancestor in CHIEF_WORK_DIR: dry-run succeeds" "$rc40" "0"
check "40 symlink ancestor in CHIEF_WORK_DIR: signal path resolves through the real target" "$(printf '%s\n' "$out40" | grep -c "signal=$tmp40/real-target/subdir/")" "1"
check "40 symlink ancestor in CHIEF_WORK_DIR: signal path never embeds the symlink spelling" "$(printf '%s\n' "$out40" | grep -c "signal=$tmp40/linky/")" "0"
else
    host_skip "40 symlink ancestor in CHIEF_WORK_DIR: ln -s does not make a real link on this host"
fi

# --- 41: a MISSING intermediate ancestor of CHIEF_WORK_DIR is skipped by
# the ancestor-walk above (nothing to validate yet) and then created by a
# single `mkdir -p` alongside the work dir itself, with no ownership check
# of its own. A local attacker
# who races to plant that ancestor between the walk and the create call gets
# it silently adopted, then owns a directory in this process's path that was
# never validated. A real race cannot be scheduled deterministically, so
# (mirroring case 30's technique) a PATH stub for `mkdir` simulates the race
# winner: the first time console.sh's own code tries to create anything
# under the test's tmp tree, the stub plants the intermediate ancestor
# itself at an insecure, self-owned mode (0777, no sticky bit) BEFORE
# forwarding the original call to the real `mkdir` -- exactly what a raced
# attacker directory would look like by the time this process next touches
# that path.
if [ "$HOST_MODES_STICK" = 1 ]; then
tmp41="$tmp/c41"
mkdir -p "$tmp41/bin"
chmod 0700 "$tmp41"
mid41="$tmp41/mid"
target41="$tmp41/mid/workdir"
real_mkdir41="$(command -v mkdir)"
cat > "$tmp41/bin/mkdir" <<STUB_EOF
#!/usr/bin/env bash
if [ ! -e "$tmp41/.raced41" ]; then
    for a in "\$@"; do
        case "\$a" in
            "$tmp41"/*)
                : > "$tmp41/.raced41"
                "$real_mkdir41" -m 0777 -p "$mid41" 2>/dev/null
                break
                ;;
        esac
    done
fi
exec "$real_mkdir41" "\$@"
STUB_EOF
chmod +x "$tmp41/bin/mkdir"
rc41=0
out41="$( ( cd "$fixture_repo" && env -u XDG_RUNTIME_DIR \
    HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_WORK_DIR="$target41" \
    PATH="$tmp41/bin:$PATH" \
    bash "$C" new --bucket wdancestor41 --dry-run ) 2>&1 )"; rc41=$?
check "41 raced intermediate ancestor of CHIEF_WORK_DIR: refuses with a distinct exit code" "$rc41" "3"
check "41 raced intermediate ancestor of CHIEF_WORK_DIR: stderr names the cause" "$([ "$(printf '%s\n' "$out41" | grep -ci ancestor)" -ge 1 ] && echo yes || echo no)" "yes"
check "41 raced intermediate ancestor of CHIEF_WORK_DIR: never created the work dir beneath the raced ancestor" "$([ -e "$target41" ] && echo yes || echo no)" "no"
else
    host_skip "41 raced intermediate ancestor: chmod/mkdir -m does not stick on this host"
fi

# --- 42: an ancestor an attacker races into existence AFTER the outer
# ancestor-unsafe walk concludes "safe" but BEFORE _console_mkdir_chain_safe's
# own missing-component scan runs is silently trusted as that scan's stopping
# point, with no validation of its own: the scan's `while [ ! -e "$prefix" ]` loop
# just stops at the first EXISTING directory it meets and hands it to the
# create loop as a trusted base -- but "existing" only means existing NOW,
# at scan time, not at the time the outer walk last looked. A real race
# cannot be scheduled deterministically, so (mirroring cases 30/34/37's
# technique) a PATH stub for `stat` simulates the race winner: the instant
# the outer ancestor-unsafe walk examines the LAST existing ancestor it will
# see before concluding "safe", the stub plants the next-level-down ancestor
# at an insecure, self-owned mode (0777, no sticky bit) as a side effect,
# then returns the real `stat` output for the path it was actually asked
# about -- exactly what a raced attacker directory materializing in that
# exact window would look like.
if [ "$HOST_MODES_STICK" = 1 ]; then
tmp42="$tmp/c42"
mkdir -p "$tmp42/bin"
chmod 0700 "$tmp42"
mid42="$tmp42/mid"
target42="$tmp42/mid/workdir"
real_stat42="$(command -v stat)"
cat > "$tmp42/bin/stat" <<STUB_EOF
#!/usr/bin/env bash
if [ ! -e "$tmp42/.raced42" ]; then
    for a in "\$@"; do
        if [ "\$a" = "$tmp42" ]; then
            : > "$tmp42/.raced42"
            mkdir -m 0777 "$mid42" 2>/dev/null
            break
        fi
    done
fi
exec "$real_stat42" "\$@"
STUB_EOF
chmod +x "$tmp42/bin/stat"
rc42=0
out42="$( ( cd "$fixture_repo" && env -u XDG_RUNTIME_DIR \
    HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_WORK_DIR="$target42" \
    PATH="$tmp42/bin:$PATH" \
    bash "$C" new --bucket wdancestor42 --dry-run ) 2>&1 )"; rc42=$?
check "42 ancestor raced in between the outer walk and the create scan: refuses with a distinct exit code" "$rc42" "3"
check "42 ancestor raced in between the outer walk and the create scan: stderr names the cause" "$([ "$(printf '%s\n' "$out42" | grep -ci ancestor)" -ge 1 ] && echo yes || echo no)" "yes"
check "42 ancestor raced in between the outer walk and the create scan: never created the work dir beneath the raced ancestor" "$([ -e "$target42" ] && echo yes || echo no)" "no"
else
    host_skip "42 ancestor raced between the outer walk and the create scan: chmod/mkdir -m does not stick on this host"
fi

# --- 43: the rendered "Handing over" line must carry --model <resolved> --
# same class as the --bucket and --prefix flags: the doc
# tells its own console what to literally run at handover, so any flag
# missing from that line is a flag the next `console next` invocation never
# receives, and re-resolves from CHIEF_MODEL / the built-in default
# instead of inheriting. CHIEF_MODEL is deliberately set to
# a DIFFERENT value than --model on every invocation below, so a fallback
# to the environment shows up as the wrong string landing in the doc.
doc43A="$root/tester/modelbucket/DEMO-nextleg-${today}A-console.md"
out43a="$( ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_MODEL=envdefault-model \
    bash "$C" new --bucket modelbucket --model custom-model-x ) )"
token43a="$(token_of "$out43a")"
# The value is single-quoted in the rendered line -- an unquoted
# claude-opus-5[1m] is a zsh glob and fails at the exact moment of handover.
check "43 new's own rendered handover line carries --model <given>" "$(grep -c -- "--model 'custom-model-x'" "$doc43A")" "1"
check "43 new's rendered handover line does not carry CHIEF_MODEL instead" "$(grep -c -e '--model envdefault-model' -e "--model 'envdefault-model'" "$doc43A")" "0"

# next, invoked the way the line above actually instructs (no --model of its
# own is available to a copy-pasting operator/console unless THIS fix put
# one there) but run here with an explicit --model so the successor's own
# resolved model is known -- under a CHIEF_MODEL that again differs, to
# prove the successor's rendered doc carries the given --model forward
# rather than re-deriving it from the environment.
doc43B="$root/tester/modelbucket/DEMO-nextleg-${today}B-console.md"
( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_MODEL=envdefault-model \
    bash "$C" next --bucket modelbucket --model custom-model-x ) >/dev/null
check "43 next's rendered successor doc carries --model <given>" "$(grep -c -- "--model 'custom-model-x'" "$doc43B")" "1"
check "43 next's rendered successor doc does not carry CHIEF_MODEL instead" "$(grep -c -e '--model envdefault-model' -e "--model 'envdefault-model'" "$doc43B")" "0"
HANDOVER_DIR="$root" bash "$QL" release "$doc43A" "$token43a" >/dev/null 2>&1

# --- 44: same-day rollover past Z --------------------------
# 26 consoles on 2026-09-12 hit a hard refusal at letter Z with a live leg
# in flight. Continuation with no --date flag at all must roll bijective
# base-26: Z -> AA (an explicit --date, even one matching the predecessor's
# own date, always resets the chain to A instead -- see case 48).
mkdir -p "$root/tester/rollz"
docZ44="$root/tester/rollz/DEMO-nextleg-${today}Z-console.md"
stub_doc stub > "$docZ44"
out44="$(console next --bucket rollz --dry-run --doc "$docZ44")"
check "44 next --dry-run rolls Z to AA" "$(printf '%s\n' "$out44" | grep -c "^would-doc: .*${today}AA-console.md$")" "1"

# --- 45: same-day rollover AZ -> BA ---------------------------------------
mkdir -p "$root/tester/rollaz"
docAZ45="$root/tester/rollaz/DEMO-nextleg-${today}AZ-console.md"
stub_doc stub > "$docAZ45"
out45="$(console next --bucket rollaz --dry-run --doc "$docAZ45")"
check "45 next --dry-run rolls AZ to BA" "$(printf '%s\n' "$out45" | grep -c "^would-doc: .*${today}BA-console.md$")" "1"

# --- 46: the recovery regex accepts a two-letter doc name -----------------
# --doc alone (no --name) must derive the chain name from a TWO-letter
# basename just as it already does for a one-letter one (line ~262's regex
# was [A-Z] only), and bump AA -> AB.
mkdir -p "$root/tester/rollname"
docAA46="$root/tester/rollname/DEMO-nextleg-${today}AA-mychain-console.md"
stub_doc stub > "$docAA46"
console next --bucket rollname --doc "$docAA46" >/dev/null
docAB46="$root/tester/rollname/DEMO-nextleg-${today}AB-mychain-console.md"
check "46 next --doc <two-letter> derives name and bumps to AB" "$([ -f "$docAB46" ] && echo yes)" "yes"

# --- 47: new with 26 docs present picks AA instead of refusing -----------
mkdir -p "$root/tester/rollnew"
for letter47 in {A..Z}; do
    printf 'claimed\n' > "$root/tester/rollnew/DEMO-nextleg-${today}${letter47}-console.md"
done
out47="$(console new --bucket rollnew)"
token47="$(token_of "$out47")"
docAA47="$root/tester/rollnew/DEMO-nextleg-${today}AA-console.md"
check "47 new with all 26 single letters claimed picks AA" "$([ -f "$docAA47" ] && echo yes)" "yes"
HANDOVER_DIR="$root" bash "$QL" release "$docAA47" "$token47" >/dev/null 2>&1

# --- 48: --date mints tomorrow's A, HANDOFF still pairs with the Z doc ---
# The whole point of --date: a 23:5x console at letter Z can pre-mint
# TOMORROW's first console (A) without waiting for midnight to roll the
# date over naturally. The predecessor pointer (HANDOFF location + the
# successor stub's own back-reference) still names the Z doc, even though
# the letter resets rather than continuing the bijective sequence.
mkdir -p "$root/tester/rolldate"
docZ48="$root/tester/rolldate/DEMO-nextleg-${today}Z-console.md"
stub_doc stub > "$docZ48"
tomorrow48="2026-09-14"
out48="$(console next --bucket rolldate --dry-run --date "$tomorrow48" --doc "$docZ48")"
check "48 --date mints tomorrow's A, not a same-day AA rollover" "$(printf '%s\n' "$out48" | grep -c "^would-doc: .*${tomorrow48}A-console.md$")" "1"
check "48 --date dry-run still names the Z predecessor's HANDOFF" "$(printf '%s\n' "$out48" | grep -c "would-handoff: .*${today}Z-console-HANDOFF.md")" "1"

# --- 49: --date malformed exits 2 with a usage line -----------------------
rc49=0
out49="$(console next --bucket rolldate --dry-run --date notadate --doc "$docZ48" 2>&1)" || rc49=$?
check "49 --date malformed exits 2" "$rc49" "2"
check "49 --date malformed prints a usage line" "$(printf '%s\n' "$out49" | grep -c '^usage: chief.sh')" "1"

# --- 50: highest-doc discovery compares letters NUMERICALLY, not lexically
# "AA" < "B" as strings even though AA (27) is the LATER letter. Auto
# discovery (no --doc) must pick AA over B as today's predecessor.
mkdir -p "$root/tester/rollorder"
printf 'stub\n' > "$root/tester/rollorder/DEMO-nextleg-${today}B-console.md"
stub_doc stub > "$root/tester/rollorder/DEMO-nextleg-${today}AA-console.md"
out50="$(console next --bucket rollorder --dry-run)"
check "50 auto-discovery treats AA as newer than B (numeric, not lexical)" "$(printf '%s\n' "$out50" | grep -c "^would-doc: .*${today}AB-console.md$")" "1"

# --- 51-55: --date validates a real calendar date, and an explicitly ------
# empty value is an ERROR, not a silent reset to today's own chain (a console
# ruling). An explicit --doc bypasses predecessor auto-
# discovery so these exercise the date-validation branch alone, not "no
# predecessor found".
mkdir -p "$root/tester/dateval"
docZval="$root/tester/dateval/DEMO-nextleg-${today}Z-console.md"
stub_doc stub > "$docZval"

rc51=0
out51="$(console next --bucket dateval --dry-run --date 2026-99-99 --doc "$docZval" 2>&1)" || rc51=$?
check "51 --date 2026-99-99 exits 2" "$rc51" "2"
check "51 --date 2026-99-99 prints no would-doc line" "$(printf '%s\n' "$out51" | grep -c '^would-doc:')" "0"

rc52=0
out52="$(console next --bucket dateval --dry-run --date 2026-02-30 --doc "$docZval" 2>&1)" || rc52=$?
check "52 --date 2026-02-30 exits 2" "$rc52" "2"
check "52 --date 2026-02-30 prints no would-doc line" "$(printf '%s\n' "$out52" | grep -c '^would-doc:')" "0"

rc53=0
out53="$(console next --bucket dateval --dry-run --date "" --doc "$docZval" 2>&1)" || rc53=$?
check "53 --date '' exits 2" "$rc53" "2"
check "53 --date '' prints a usage line" "$(printf '%s\n' "$out53" | grep -c '^usage: chief.sh')" "1"

rc54=0
out54="$(console next --bucket dateval --dry-run --date= --doc "$docZval" 2>&1)" || rc54=$?
check "54 --date= exits 2" "$rc54" "2"
check "54 --date= prints a usage line" "$(printf '%s\n' "$out54" | grep -c '^usage: chief.sh')" "1"

out55="$(console next --bucket dateval --dry-run --date "2026-09-14" --doc "$docZval")"
check "55 a real --date still mints the successor" "$(printf '%s\n' "$out55" | grep -c '^would-doc: .*2026-09-14A-console.md$')" "1"

# --- 56/57: CONSOLE_ROLE is
# retired -- console is implicit, so do_arm never hands headed-arm.sh a
# --role. Each stub records its FULL "$*" to a fixed path baked into the stub
# itself (never a positional like $5), so an unexpected leading --role shows
# up as a record line rather than a silently shifted field.
doc56A="$root/tester/rolerepo/DEMO-nextleg-${today}A-console.md"
record56="$tmp/role-record-56"
cat > "$tmp/stub-arm-role-56.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$record56"
STUB
chmod +x "$tmp/stub-arm-role-56.sh"

out56a="$(console new --bucket rolerepo)"
token56a="$(token_of "$out56a")"
out56b="$( ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_HEADED_ARM="$tmp/stub-arm-role-56.sh" CHIEF_ARM_FOREGROUND=1 CHIEF_WORK_DIR="$tmp/work" \
    CONSOLE_ROLE=console \
    bash "$C" next --bucket rolerepo --arm --deadline-min 0 ) )"
check "56 next --arm reports armed" "$(printf '%s\n' "$out56b" | grep -c '^armed: ')" "1"
check "56 CONSOLE_ROLE=console (retired): the stub was invoked" "$(grep -c '' "$record56" 2>/dev/null)" "1"
check "56 CONSOLE_ROLE=console (retired): the arm is launched --role console (HIMMEL-4052)" \
    "$(grep -c -- '--role console ' "$record56" 2>/dev/null)" "1"
HANDOVER_DIR="$root" bash "$QL" release "$doc56A" "$token56a" >/dev/null 2>&1

doc57A="$root/tester/rolerepo2/DEMO-nextleg-${today}A-console.md"
record57="$tmp/role-record-57"
cat > "$tmp/stub-arm-role-57.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$record57"
STUB
chmod +x "$tmp/stub-arm-role-57.sh"

out57a="$(console new --bucket rolerepo2)"
token57a="$(token_of "$out57a")"
out57b="$( ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_HEADED_ARM="$tmp/stub-arm-role-57.sh" CHIEF_ARM_FOREGROUND=1 CHIEF_WORK_DIR="$tmp/work" \
    bash "$C" next --bucket rolerepo2 --arm --deadline-min 0 ) )"
check "57 next --arm reports armed" "$(printf '%s\n' "$out57b" | grep -c '^armed: ')" "1"
check "57 no CONSOLE_ROLE: the arm is launched --role console (HIMMEL-4052)" \
    "$(grep -c -- '--role console ' "$record57" 2>/dev/null)" "1"
HANDOVER_DIR="$root" bash "$QL" release "$doc57A" "$token57a" >/dev/null 2>&1

# --- 58: a stale CONSOLE_ROLE=relay in the environment no
# longer refuses the arm -- the retired variable is ignored, the stub IS
# invoked and no --role reaches it. (Was 58/59: relay/bogus exited 2 before the
# detached launch.)
doc58A="$root/tester/rolerepo3/DEMO-nextleg-${today}A-console.md"
record58="$tmp/role-record-58"
cat > "$tmp/stub-arm-role-58.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$record58"
STUB
chmod +x "$tmp/stub-arm-role-58.sh"

out58a="$(console new --bucket rolerepo3)"
token58a="$(token_of "$out58a")"
rc58b=0
out58b="$( ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_HEADED_ARM="$tmp/stub-arm-role-58.sh" CHIEF_ARM_FOREGROUND=1 CHIEF_WORK_DIR="$tmp/work" \
    CONSOLE_ROLE=relay \
    bash "$C" next --bucket rolerepo3 --arm --deadline-min 0 ) 2>&1 )" || rc58b=$?
check "58 CONSOLE_ROLE=relay (retired): exits 0" "$rc58b" "0"
check "58 CONSOLE_ROLE=relay (retired): armed line printed" "$(printf '%s\n' "$out58b" | grep -c '^armed: ')" "1"
check "58 CONSOLE_ROLE=relay (retired): stub invoked" "$([ -e "$record58" ] && echo 1 || echo 0)" "1"
check "58 CONSOLE_ROLE=relay (retired): --role console, never relay (HIMMEL-4052)" \
    "$(grep -c -- '--role console ' "$record58" 2>/dev/null)$(grep -c -- '--role relay' "$record58" 2>/dev/null)" "10"
HANDOVER_DIR="$root" bash "$QL" release "$doc58A" "$token58a" >/dev/null 2>&1

# --- 58b: a console profile refusal (profile-settings.sh rc 2)
# inside launch_cmd must fail the whole command. It ran inside $(...) at the
# `launch:` / `would-launch:` echoes, so the exit 2 was lost and the arm went on
# (rc 0) with no profiled launch line. HIMMEL_PROFILE_SETTINGS_DIR under /dev/null
# makes the resolver's mkdir fail, which is its fail-closed rc 2.
record58b="$tmp/role-record-58b"
cat > "$tmp/stub-arm-role-58b.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$record58b"
STUB
chmod +x "$tmp/stub-arm-role-58b.sh"
rc58n=0
out58n="$( ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    HIMMEL_PROFILE_SETTINGS_DIR=/dev/null/no-such CHIEF_HEADED_ARM="$tmp/stub-arm-role-58b.sh" \
    CHIEF_ARM_FOREGROUND=1 CHIEF_WORK_DIR="$tmp/work" \
    bash "$C" new --bucket rolerepo4 --arm --deadline-min 0 ) 2>&1 )" || rc58n=$?
check "58b new --arm with an unresolvable console profile: exit 2" "$rc58n" "2"
# The profile is resolved BEFORE the lock, so the refusal leaves no
# doc and no held lock (the release token must not even have been printed).
doc58nA="$root/tester/rolerepo4/DEMO-nextleg-${today}A-console.md"
check "58b new refusal: no doc left behind (HIMMEL-4058)" "$([ -e "$doc58nA" ] && echo 1 || echo 0)" "0"
check "58b new refusal: no release-token printed (HIMMEL-4058)" "$(printf '%s\n' "$out58n" | grep -c 'release-token')" "0"
check "58b new refusal: no queue lock held (HIMMEL-4058)" \
    "$(HANDOVER_DIR="$root" bash "$QL" status "$doc58nA" 2>&1)" "free"
check "58b refusal: no launch line printed" "$(printf '%s\n' "$out58n" | grep -c '^launch: ')" "0"
check "58b refusal: the arm was never started" "$([ -e "$record58b" ] && echo 1 || echo 0)" "0"
rc58d=0
( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    HIMMEL_PROFILE_SETTINGS_DIR=/dev/null/no-such bash "$C" new --bucket rolerepo4 --dry-run ) >/dev/null 2>&1 || rc58d=$?
check "58b new --dry-run with an unresolvable console profile: exit 2" "$rc58d" "2"
# `next` refusal must also remove the claimed successor doc (else a retry dies
# on "successor doc already exists").
out58x="$(console new --bucket rolerepo5)"
token58x="$(token_of "$out58x")"
doc58xA="$root/tester/rolerepo5/DEMO-nextleg-${today}A-console.md"
doc58xB="$root/tester/rolerepo5/DEMO-nextleg-${today}B-console.md"
rc58x=0
( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    HIMMEL_PROFILE_SETTINGS_DIR=/dev/null/no-such bash "$C" next --bucket rolerepo5 ) >/dev/null 2>&1 || rc58x=$?
check "58b next with an unresolvable console profile: exit 2" "$rc58x" "2"
check "58b next refusal: successor doc removed" "$([ -e "$doc58xB" ] && echo 1 || echo 0)" "0"
HANDOVER_DIR="$root" bash "$QL" release "$doc58xA" "$token58x" >/dev/null 2>&1

# --- 60: `next` seeds the predecessor's `legs:`, `queue:`, `last GO:` and
# `acked:` verbatim into the successor's own `## Live state`, and ONLY those
# lines: a marker planted in the neighbouring `## Compact instructions` body
# must NOT leak. The HANDOFF points at the seeded doc and carries no nonce, so
# the successor's `action-zero.sh --render-legs` keeps the nonce from its own
# line (it refuses a listed leg with no nonce).
out60a="$(console new --bucket livestatesrc)"
token60a="$(token_of "$out60a")"
doc60A="$root/tester/livestatesrc/DEMO-nextleg-${today}A-console.md"
doc60B="$root/tester/livestatedst/DEMO-nextleg-${today}B-console.md"
handoff60A="$root/tester/livestatesrc/DEMO-nextleg-${today}A-console-HANDOFF.md"

# shellcheck disable=SC2016  # backtick leg span, literal fixture text
fixture60_legs='legs: `N9:nonce-fixture-60:lock-fixture-60:42424`'
marker60='MARKER-60-COMPACT-INSTRUCTIONS-MUST-NOT-LEAK'
awk -v legs_line="$fixture60_legs" -v marker="$marker60" '
    $0 == "## Live state" {
        print
        print ""
        print legs_line
        print "queue: N9"
        print "last GO: `#999:deadbeef00`"
        print "acked: none"
        skip = 1
        next
    }
    skip && /^## / { skip = 0 }
    skip { next }
    $0 == "## Compact instructions" {
        print
        print ""
        print marker
        skip2 = 1
        next
    }
    skip2 && /^## / { skip2 = 0 }
    skip2 { next }
    { print }
' "$doc60A" > "$doc60A.new" && mv "$doc60A.new" "$doc60A"

leg60="$root/tester/livestatesrc/DEMO-leg60-N9.md"
printf '%s\n' '# leg' '## Results' '- 10:00 LIVE — fixture' > "$leg60"
printf '{"legs":[{"label":"N9","doc":"%s"}]}\n' "$leg60" > "${doc60A%.md}.fleet.json"
leg60tok="$(token_of "$(HANDOVER_DIR="$root" bash "$QL" acquire "$leg60" 2>/dev/null)")"

rc60=0
console next --bucket livestatedst --doc "$doc60A" >/dev/null 2>&1 || rc60=$?
check "60 next succeeds against a doc with a real Live state section" "$rc60" "0"
live60B="$(awk '$0 == "## Live state" { f = 1; next } f && /^## / { exit } f' "$doc60B" 2>/dev/null)"
check "60 successor Live state seeds the predecessor's legs line verbatim" \
    "$(printf '%s\n' "$live60B" | grep -Fxc "$fixture60_legs")" "1"
# shellcheck disable=SC2016  # literal fixture text
check "60 successor Live state seeds queue, last GO and acked verbatim" \
    "$(printf '%s\n' "$live60B" | grep -Fxc -e 'queue: N9' -e 'last GO: `#999:deadbeef00`' -e 'acked: none')" "3"
check "60 successor Live state keeps no placeholder legs line" \
    "$(printf '%s\n' "$live60B" | grep -c '^legs: <')" "0"
check "60 HANDOFF carries no copy of the fixture nonce" \
    "$(grep -Fc 'nonce-fixture-60' "$handoff60A" 2>/dev/null)" "0"
check "60 HANDOFF points at the seeded successor doc" \
    "$(grep -Ec "Live state: seeded into \`([^\`]*/)?$(basename "$doc60B")\`" "$handoff60A" 2>/dev/null)" "1"
check "60 the control: Compact instructions marker does not leak into the successor or the HANDOFF" \
    "$(cat "$doc60B" "$handoff60A" 2>/dev/null | grep -Fc "$marker60")" "0"
check "60 successor doc itself was still written" "$([ -s "$doc60B" ] && echo yes)" "yes"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/az60-doctor.sh"
rc60z=0
ACTION_ZERO_BANK="$tmp/facts-bank.sh" ACTION_ZERO_DOCTOR="$tmp/az60-doctor.sh" \
    bash "$fixture_repo/scripts/handover/console-kit/action-zero.sh" --doc "$doc60B" --root "$root" --repo "$fixture_repo" --render-legs >"$tmp/az60.out" 2>&1 || rc60z=$?
check "60 action-zero.sh --render-legs on the seeded successor exits 0" "$rc60z" "0"
check "60 the re-rendered legs line keeps the seeded nonce with the held lock's token" \
    "$(grep -Fc "\`N9:nonce-fixture-60:$leg60tok:" "$doc60B" 2>/dev/null)" "1"
HANDOVER_DIR="$root" bash "$QL" release "$leg60" "$leg60tok" >/dev/null 2>&1
HANDOVER_DIR="$root" bash "$QL" release "$doc60A" "$token60a" >/dev/null 2>&1

# --- 60b: the console board's artifact URL rides on the
# `board:` line of `## Live state` and `next` seeds the successor's own line
# with it, so the successor updates the same artifact. Controls: a fresh
# console starts at "none yet" (the RED at the base: no `board:` line at all),
# and a predecessor with no URL yields "none yet", not an empty value.
out60b="$(console new --bucket boardsrc)"
token60b="$(token_of "$out60b")"
doc60bA="$root/tester/boardsrc/DEMO-nextleg-${today}A-console.md"
doc60bB="$root/tester/boarddst/DEMO-nextleg-${today}B-console.md"
doc60bC="$root/tester/boarddst2/DEMO-nextleg-${today}B-console.md"
url60b='https://claude.ai/artifact/fixture-3361-board'
check "60b a fresh console's Live state starts the board: line at none yet" \
    "$(grep -c '^board: none yet' "$doc60bA" 2>/dev/null)" "1"
rc60b=0
console next --bucket boarddst2 --doc "$doc60bA" >/dev/null 2>&1 || rc60b=$?
check "60b next from a doc with no URL succeeds" "$rc60b" "0"
check "60b no-URL predecessor yields none yet on the successor, never empty" \
    "$(grep -c '^board: none yet' "$doc60bC" 2>/dev/null)" "1"
awk -v url="$url60b" '/^board: none yet/ { print "board: " url; next } { print }' "$doc60bA" > "$doc60bA.new" && mv "$doc60bA.new" "$doc60bA"
rc60b=0
console next --bucket boarddst --doc "$doc60bA" >/dev/null 2>&1 || rc60b=$?
check "60b next succeeds against a doc with a published board URL" "$rc60b" "0"
check "60b successor doc's board: line carries the predecessor's artifact URL" \
    "$(grep -Fxc "board: $url60b" "$doc60bB" 2>/dev/null)" "1"
check "60b no unrendered {{BOARD_URL}} left in the successor doc" \
    "$(grep -Fc '{{BOARD_URL}}' "$doc60bB" 2>/dev/null)" "0"
check "60b a fresh console's Live state starts tracker: at none (tick tracker=skip)" \
    "$(grep -Fxc 'tracker: none' "$doc60bA" 2>/dev/null)" "1"
check "60b no-URL predecessor yields tracker: none on the successor, never empty" \
    "$(grep -Fxc 'tracker: none' "$doc60bC" 2>/dev/null)" "1"
# A published tracker URL is carried to the successor.
trackerurl60b='https://claude.ai/artifact/fixture-3933-tracker'
sed "s|^tracker: none|tracker: $trackerurl60b|" "$doc60bA" >"$doc60bA.new" && mv "$doc60bA.new" "$doc60bA"
rm -f "$doc60bB"
console next --bucket boarddst --doc "$doc60bA" >/dev/null 2>&1 || rc60b=$?
check "60b successor doc's tracker: line carries the predecessor's tracker URL" \
    "$(grep -Fxc "tracker: $trackerurl60b" "$doc60bB" 2>/dev/null)" "1"
check "60b no unrendered {{TRACKER_URL}} left in the successor doc" \
    "$(grep -Fc '{{TRACKER_URL}}' "$doc60bB" 2>/dev/null)" "0"
# focus-version: and focus-plan: opt the FOCUS refresh in; a succession must keep them.
focusplan60b='/fixture/plans/focus-plan-60b.md'
awk -v plan="$focusplan60b" '{ print } /^tracker: / { print "focus-version: v9.9.9"; print "focus-plan: " plan }' "$doc60bA" >"$doc60bA.new" && mv "$doc60bA.new" "$doc60bA"
rm -f "$doc60bB"
rc60bf=0
console next --bucket boarddst --doc "$doc60bA" >/dev/null 2>&1 || rc60bf=$?
check "60b next succeeds against a doc with focus-version: and focus-plan:" "$rc60bf" "0"
check "60b successor doc carries the predecessor's focus-version: line" \
    "$(grep -Fxc 'focus-version: v9.9.9' "$doc60bB" 2>/dev/null)" "1"
check "60b successor doc carries the predecessor's focus-plan: line" \
    "$(grep -Fxc "focus-plan: $focusplan60b" "$doc60bB" 2>/dev/null)" "1"
HANDOVER_DIR="$root" bash "$QL" release "$doc60bA" "$token60b" >/dev/null 2>&1

# --- 61: the console parent defaults to Opus, not Fable
# (Opus = default parent, Fable = the escalation target; operator halt
# 2026-09-14). The armed path has no terminal to notice a wrong default, so
# the check reads what the arm stub actually RECEIVED (its model positional,
# $6), not just the printed --dry-run line. CHIEF_MODEL is unset in every
# subshell so an ambient value cannot mask the built-in default. Fable stays
# reachable through an explicit --model / CHIEF_MODEL.
out61a="$( ( cd "$fixture_repo" && unset CHIEF_MODEL CONSOLE_MODEL && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_WORK_DIR="$tmp/work" bash "$C" new --bucket modeldefault --dry-run --arm ) )"
check "61 dry-run --arm launch line defaults to bare claude-opus-5-5 (native 1M, HIMMEL-5501)" \
    "$(printf '%s\n' "$out61a" | grep -cF -- '--model claude-opus-5-5 ')" "1"
check "61 dry-run --arm launch line carries no [1m] suffix on a native-1M model" \
    "$(printf '%s\n' "$out61a" | grep -cF -- 'claude-opus-5-5\[1m\]')" "0"
out61c="$( ( cd "$fixture_repo" && unset CHIEF_MODEL CONSOLE_MODEL && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_WORK_DIR="$tmp/work" bash "$C" new --bucket modeldefault --dry-run --arm --model claude-opus-4-6 ) )"
check "61 a 4.6-family model keeps the [1m] suffix (HIMMEL-5501)" \
    "$(printf '%s\n' "$out61c" | grep -cF -- '--model claude-opus-4-6\[1m\] ')" "1"
out61d="$( ( cd "$fixture_repo" && unset CHIEF_MODEL CONSOLE_MODEL && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_WORK_DIR="$tmp/work" bash "$C" new --bucket modeldefault --dry-run --arm --model gpt-5.6-sol ) )"
check "61 a non-Anthropic model never gets [1m] (HIMMEL-5501)" \
    "$(printf '%s\n' "$out61d" | grep -cF -- '--model gpt-5.6-sol ')" "1"

# --- 61f: a Claude Code below the version floor refuses an
# armed launch (rc=2, names the version and `claude update`); a dry run only
# warns. Version shapes copied from the real `claude --version` output.
cat > "$tmp/claude-old-61f" <<'OLD_STUB'
#!/usr/bin/env bash
echo "2.1.100 (Claude Code)"
OLD_STUB
chmod +x "$tmp/claude-old-61f"
out61f="$( ( cd "$fixture_repo" && HEADED_ARM_CLAUDE_CLI="$tmp/claude-old-61f" HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_WORK_DIR="$tmp/work" bash "$C" new --bucket floor61f --arm 2>&1 ) )"
rc61f=$?
check "61f armed launch below the floor refused (rc=2)" "$rc61f" "2"
check "61f message names the installed version and the fix" \
    "$(printf '%s\n' "$out61f" | grep -c '2\.1\.100.*claude update\|claude update.*2\.1\.100')" "1"
check "61f nothing was armed" "$(printf '%s\n' "$out61f" | grep -c '^armed: ')" "0"
out61g="$( ( cd "$fixture_repo" && HEADED_ARM_CLAUDE_CLI="$tmp/claude-old-61f" HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_WORK_DIR="$tmp/work" bash "$C" new --bucket floor61f --dry-run --arm 2>&1 ) )"
rc61g=$?
check "61f dry-run below the floor only warns (rc=0)" "$rc61g" "0"
check "61f dry-run warning names the fix" "$(printf '%s\n' "$out61g" | grep -c 'claude update')" "1"
check "61 dry-run --arm launch line carries no fable model" \
    "$(printf '%s\n' "$out61a" | grep -c 'claude-fable-5-1')" "0"
out61b="$( ( cd "$fixture_repo" && unset CHIEF_MODEL CONSOLE_MODEL && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_WORK_DIR="$tmp/work" bash "$C" new --bucket modeldefault --dry-run --arm --model claude-fable-5-1 ) )"
check "61 explicit --model claude-fable-5-1 still launches Fable" \
    "$(printf '%s\n' "$out61b" | grep -c '^would-launch: .* claude --settings [^ ]* --model claude-fable-5-1 ')" "1"
out61o="$( ( cd "$fixture_repo" && unset CHIEF_MODEL && CONSOLE_MODEL=claude-fable-5-1 HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_WORK_DIR="$tmp/work" bash "$C" new --bucket modeldefault --dry-run --arm ) )"
check "61 the old name CONSOLE_MODEL still sets the model" \
    "$(printf '%s\n' "$out61o" | grep -c '^would-launch: .* claude --settings [^ ]* --model claude-fable-5-1 ')" "1"
out61c="$( ( cd "$fixture_repo" && CHIEF_MODEL=claude-fable-5-1 HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_WORK_DIR="$tmp/work" bash "$C" new --bucket modeldefault --dry-run --arm ) )"
check "61 CHIEF_MODEL=claude-fable-5-1 still launches Fable" \
    "$(printf '%s\n' "$out61c" | grep -c '^would-launch: .* claude --settings [^ ]* --model claude-fable-5-1 ')" "1"

record61="$tmp/record-61"
cat > "$tmp/stub-arm-model-61.sh" <<STUB
#!/usr/bin/env bash
[ "\$1" = --role ] && shift 2
printf '%s\n' "\$6" >> "$record61"
STUB
chmod +x "$tmp/stub-arm-model-61.sh"
out61d="$( ( cd "$fixture_repo" && unset CHIEF_MODEL CONSOLE_MODEL && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_HEADED_ARM="$tmp/stub-arm-model-61.sh" CHIEF_ARM_FOREGROUND=1 CHIEF_WORK_DIR="$tmp/work" \
    bash "$C" new --bucket modeldefault --arm --deadline-min 0 ) )"
token61d="$(token_of "$out61d")"
check "61 armed console without --model: the arm target received claude-opus-5-5" "$(cat "$record61" 2>/dev/null)" "claude-opus-5-5"
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/modeldefault/DEMO-nextleg-${today}A-console.md" "$token61d" >/dev/null 2>&1

# --- 62: console.sh must not expand a possibly-EMPTY array bare.
# Under `set -u` bash < 4.4 (macOS /bin/bash 3.2) treats `"${arr[@]}"` of an
# empty array as an unbound variable and aborts -- the workdir ancestor scan's
# `missing` array is empty whenever the work dir already exists, so every
# `new`/`next` died at "missing[@]: unbound variable" on macOS. This host's
# bash is newer and cannot show the abort, so the assertion is static: every
# expansion of `missing` must use the `${arr[@]+"${arr[@]}"}` guard.
# ponytail: static proof only -- the real bash 3.2 run is the macOS nightly.
check "62 console.sh expands the possibly-empty 'missing' array only via the [@]+ guard" \
    "$(grep -v '^[[:space:]]*#' "$C" | grep -cE '[^+]"\$\{missing\[@\]\}"')" "0"

# --- 63: a console started from the printed launch line leaves a
# launch record. That line is PASTED by an operator, so no launcher runs and the
# writers in headed-arm.sh / arm-resume.sh never fire -- every
# real console read `context-unknown` while the only role=console rows in the
# durable dir were another suite's fixtures. The row must exist if and only if
# the console starts, so it is written by the pasted command, never at print
# time (a row for a line nobody pasted would be a fabricated console).
LL63="$HIMMELCTL_CACHE_DIR/launch-logs"
stub63="$tmp/stub63bin"
mkdir -p "$stub63"
cat > "$stub63/claude" <<STUB
#!/usr/bin/env bash
# Records its argv and whether the launch row already existed when it started.
printf '%s\n' "\$*" > "$tmp/claude-argv-63"
for f in "$LL63"/*.log; do [ -e "\$f" ] && printf 'row-existed\n' >> "$tmp/claude-argv-63"; done
exit 0
STUB
chmod +x "$stub63/claude"
# run_launch_line <output containing a `launch:` line> -- executes that line the
# way the operator's shell does (bash -c), with the stub claude first on PATH.
run_launch_line() {
    local line
    line="$(printf '%s\n' "$1" | sed -n 's/^launch: //p')"
    ( cd "$tmp" && PATH="$stub63:$PATH" bash -c "$line" )
}

S63="DEMO-nextleg-${today}A-rec63a-console"
out63a="$(console new --bucket rec63a --name rec63a-console)"
token63a="$(token_of "$out63a")"
check "63a printing the launch line writes no row (a line nobody pastes is no console)" "$([ -e "$LL63/$S63.log" ] && echo present || echo absent)" "absent"
rm -f "$tmp/claude-argv-63"
run_launch_line "$out63a"
row63a="$(cat "$LL63/$S63.log" 2>/dev/null || true)"
case "$row63a" in
    "headed-arm: role=console session=$S63 context=1m source=default autocompact=auto launched="[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) r63a=match ;;
    *) r63a="nomatch: [$row63a]" ;;
esac
check "63a running the pasted line writes one console row: context, source, autocompact, launched" "$r63a" "match"
argv63a="$(cat "$tmp/claude-argv-63" 2>/dev/null || true)"
contains() { case "$1" in *"$2"*) echo "ok - $3" ;; *) echo "FAIL - $3: [$1] lacks [$2]"; fails=$((fails+1)) ;; esac; }
contains "$argv63a" "--autocompact auto -n $S63" "63a the row's autocompact is the value claude was launched with"
contains "$argv63a" "row-existed" "63a the row was already there when claude started"
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/rec63a/$S63.md" "$token63a" >/dev/null 2>&1

# 63b. CHIEF_CONTEXT=1m is the one opt-in: the row says so, as the arm paths do.
S63b="DEMO-nextleg-${today}A-rec63b-console"
out63b="$( ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO CHIEF_WORK_DIR="$tmp/defaultwork" \
    CHIEF_CONTEXT=1m bash "$C" new --bucket rec63b --name rec63b-console ) )"
token63b="$(token_of "$out63b")"
run_launch_line "$out63b"
check "63b CHIEF_CONTEXT=1m: the row is context=1m source=explicit autocompact=auto" \
    "$(grep -c "^headed-arm: role=console session=$S63b context=1m source=explicit autocompact=auto launched=" "$LL63/$S63b.log" 2>/dev/null || true)" "1"
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/rec63b/$S63b.md" "$token63b" >/dev/null 2>&1

# 63c. next records the SUCCESSOR's session (the console its line launches).
out63c="$(console new --bucket rec63c --name rec63c-console)"
token63c="$(token_of "$out63c")"
out63c2="$(console next --bucket rec63c --name rec63c-console)"
run_launch_line "$out63c2"
check "63c next: the successor's line writes a row for the successor session" "$(grep -c "^headed-arm: role=console session=DEMO-nextleg-${today}B-rec63c-console " "$LL63/DEMO-nextleg-${today}B-rec63c-console.log" 2>/dev/null || true)" "1"
check "63c next: the predecessor's session got no row (its line was never run)" "$([ -e "$LL63/DEMO-nextleg-${today}A-rec63c-console.log" ] && echo present || echo absent)" "absent"
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/rec63c/DEMO-nextleg-${today}A-rec63c-console.md" "$token63c" >/dev/null 2>&1

# 63d. --dry-run shows the SAME command it would print, and running nothing
# writes nothing.
out63d="$(console new --bucket rec63d --name rec63d-console --dry-run)"
check "63d --dry-run: would-launch names the recorder" "$(printf '%s\n' "$out63d" | grep -c '^would-launch: .*record-launch.sh ')" "1"
check "63d --dry-run: writes no row" "$([ -e "$LL63/DEMO-nextleg-${today}A-rec63d-console.log" ] && echo present || echo absent)" "absent"

# 63e. a launch-record dir that cannot be written never stops the console: the
# recorder warns and claude still starts.
rm -f "$tmp/claude-argv-63"
( cd "$tmp" && HIMMELCTL_CACHE_DIR="$tmp/not-a-dir-63" PATH="$stub63:$PATH" bash -c "touch $tmp/not-a-dir-63; $(printf '%s\n' "$out63a" | sed -n 's/^launch: //p')" ) >/dev/null 2>&1
check "63e unwritable record dir: claude still started" "$([ -s "$tmp/claude-argv-63" ] && echo started || echo not-started)" "started"

# 64. `next` never acquires the successor doc's lock (the
# RELEASE_TOKEN placeholder above says "none yet"), so ACTION ZERO step 8 must
# present `free` as the expected state on that path, not as the exception. RED
# control (pre-fix template): step 8 read "`held` by that session is the
# expected, correct state" with no `/console next` branch -- 0 matches.
step8_64="$(sed -n '/^8\. \*\*/,/^9\. \*\*/p' "$REPO_REAL/docs/handover/console-template.md")"
# shellcheck disable=SC2016  # backticks are literal template text
check "64 step 8 says /console next never acquires, so free is expected there" \
    "$(printf '%s\n' "$step8_64" | tr '\n' ' ' | grep -c '`/console next` never acquires.*`none yet` and the lock is `free`')" "1"
check "64 step 8 no longer calls held the only expected state" \
    "$(printf '%s\n' "$step8_64" | grep -c 'is the expected, correct state')" "0"

# 65. HANDOVER_DIR / USER_SLUG / JIRA_PROJECT_KEY must resolve
# from console.sh's OWN checkout, never the caller's CWD repo. Fixture mirrors
# test-bank-preflight-dotenv-root.sh: a scratch "own checkout" (scripts/lib +
# scripts/handover copied verbatim, plus a fixture .env carrying the three
# keys) is run with CWD inside a SEPARATE, foreign `git init` repo that has no
# .env of its own and none of the three vars exported by the caller.
own65="$tmp/own-checkout-65"
mkdir -p "$own65/scripts"
cp -r "$REPO_REAL/scripts/lanes" "$own65/scripts/lanes"  # launch_cmd refusals propagate, so the fixture needs the profile resolver
cp -r "$REPO_REAL/scripts/lib" "$own65/scripts/lib"
cp -r "$REPO_REAL/scripts/handover" "$own65/scripts/handover"
ln -s "$REPO_REAL/docs" "$own65/docs"
ln -s "$REPO_REAL/marketplace" "$own65/marketplace"  # launch_cmd resolves the console MCP allowlist from the marketplace manifests
mkdir -p "$own65/state-fixture-65/ownslug"
printf 'HANDOVER_DIR=%s\nUSER_SLUG=ownslug\nJIRA_PROJECT_KEY=OWNKEY\n' "$own65/state-fixture-65" > "$own65/.env"
foreign65="$tmp/foreign-repo-65"
mkdir -p "$foreign65/nested"
( cd "$foreign65" && git init -q )
out65="$(cd "$foreign65/nested" && env -u HANDOVER_DIR -u USER_SLUG -u JIRA_PROJECT_KEY CHIEF_WORK_DIR="$tmp/defaultwork65" bash "$own65/scripts/handover/console/chief.sh" new --name rec65-console --dry-run 2>&1)"
rc65=$?
check "65 own-checkout .env resolves rc=0" "$rc65" "0"
case "$out65" in
    *"$own65/state-fixture-65"*) contains65=yes ;;
    *) contains65=no ;;
esac
check "65 own-checkout's HANDOVER_DIR used, not the foreign CWD repo" "$contains65" "yes"

# --- 66: next --arm run from inside a leg's own shell must
# arm a CLEAN console. A leg's env keeps every leg_propagate_env / plain
# `export` name from headed-arm-leg.sh live for its whole session (plain
# export crosses every descendant of that long-running process, not just its
# immediate child), so a later `console.sh next --arm` in that same shell
# used to inherit all of it unfiltered. Runs the REAL headed-arm.sh (not a
# stub) via --dry-run, reached through do_arm()'s own CHIEF_ARM_FOREGROUND
# path -- this exercises the actual strip, not a hand-written substitute.
# CHIEF_CONTEXT=1m is the operator's real opt-in mechanism (headed-arm.sh
# only ever appends [1m] to MODEL when CONTEXT resolves to 1m, regardless of
# what --model was given) -- a leaked HEADED_ARM_REQUIRED_AUTOCOMPACT=200000
# refuses that launch outright (see the RED excerpt in this ticket's PR).
out66a="$(console new --bucket cleanenv66)"
token66a="$(token_of "$out66a")"
doc66A="$root/tester/cleanenv66/DEMO-nextleg-${today}A-console.md"

cat > "$tmp/stub-arm-66.sh" <<STUB
#!/usr/bin/env bash
# Dump whether each scrubbed name is still SET in this child's
# own environment (not just absent from headed-arm.sh's printed output) --
# the console's ruling asked for direct evidence on the child process, since
# a text-scan of argv/output cannot tell "unset" from "set to a value that
# happens not to print".
{
    printf 'LEG_PROFILE_SETTINGS=%s\n' "\${LEG_PROFILE_SETTINGS+set}"
    printf 'HIMMEL_LEG_PROFILE=%s\n' "\${HIMMEL_LEG_PROFILE+set}"
    printf 'HIMMEL_CONSOLE_LEG=%s\n' "\${HIMMEL_CONSOLE_LEG+set}"
    printf 'LEG_LANE=%s\n' "\${LEG_LANE+set}"
    printf 'OPENROUTER_MODEL=%s\n' "\${OPENROUTER_MODEL+set}"
    printf 'HEADED_ARM_REQUIRED_AUTOCOMPACT=%s\n' "\${HEADED_ARM_REQUIRED_AUTOCOMPACT+set}"
} > "$tmp/child-env-66.txt"
exec "$REPO_REAL/scripts/handover/headed-arm.sh" --dry-run "\$@"
STUB
chmod +x "$tmp/stub-arm-66.sh"

# headed-arm.sh's own presence check for $KONSOLE runs even under --dry-run
# (only the actual launch is skipped) -- a CI runner has no real konsole, so
# this needs the same KONSOLE_CMD stub test-headed-arm.sh already uses,
# never invoked here (dry-run never reaches the launch), only present.
cat > "$tmp/konsole-66" <<'KONSOLE_STUB'
#!/usr/bin/env bash
exit 0
KONSOLE_STUB
chmod +x "$tmp/konsole-66"

out66b="$( ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    HIMMEL_LEG_PROFILE=leg-impl \
    LEG_PROFILE_SETTINGS=/leaked-66/settings.json LEG_PROFILE_PREFACE=/leaked-66/preface.md \
    LEG_PROFILE_MCP_CONFIG=/leaked-66/mcp.json LEG_CLAUDE_BIN=/leaked-66/claude \
    HIMMEL_LEAN_LEG=1 HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=leaked-console-66 \
    WORKER_SESSION_EFFORT=high CLAUDE_CODE_EFFORT_LEVEL=high CLAUDEX_LANE_OK=1 \
    LEG_LANE=openrouter OPENROUTER_MODEL=anthropic/claude-sonnet-5.5 \
    CR_TRIGGER_SUPPRESS=1 IMPL_GUARD_OK=1 INLINE_IMPL_OK=1 HIMMEL_READ_CLAMP_LINES=4000 \
    HIMMEL_CONSOLE_RELAY=1 \
    HEADED_ARM_LAUNCHER=/leaked-66/leg-claude-launcher.sh HEADED_ARM_RECORDER=1 \
    HEADED_ARM_REQUIRED_AUTOCOMPACT=200000 \
    HEADED_ARM_LAUNCHER_ENV="CLAUDEX_LANE_OK=1 LEG_PROFILE_SETTINGS=/leaked-66/settings.json" \
    HEADED_ARM_UNAME=Darwin \
    CHIEF_CONTEXT=1m \
    KONSOLE_CMD="$tmp/konsole-66" \
    CHIEF_HEADED_ARM="$tmp/stub-arm-66.sh" CHIEF_ARM_FOREGROUND=1 CHIEF_WORK_DIR="$tmp/work66" \
    bash "$C" next --bucket cleanenv66 --arm --deadline-min 0 ) 2>&1 )"
rc66b=$?
check "66 next --arm from a leaked leg env still succeeds (rc=0)" "$rc66b" "0"
check "66 CHIEF_CONTEXT=1m survives the leaked required-autocompact pin, model stays bare (native 1M)" \
    "$(printf '%s\n' "$out66b" | grep -c '^headed-arm: context=1m .*model=claude-opus-5-5 runs 1M without a suffix .*(autocompact=auto)$')" "1"
check "66 dry-run resolves the real launcher, not the leaked shim; recorder not inherited" \
    "$(printf '%s\n' "$out66b" | grep -c '^headed-arm: launcher=claude recorder=0 ')" "1"
check "66 no leaked leg-profile value reaches the armed console's argv/env" \
    "$(printf '%s\n' "$out66b" | grep -c 'leaked-66')" "0"
check "66 armed child's OWN environment still lacks LEG_PROFILE_SETTINGS (not just unprinted)" \
    "$(grep -c '^LEG_PROFILE_SETTINGS=set$' "$tmp/child-env-66.txt")" "0"
check "66 armed child's OWN environment still lacks HIMMEL_CONSOLE_LEG (not just unprinted)" \
    "$(grep -c '^HIMMEL_CONSOLE_LEG=set$' "$tmp/child-env-66.txt")" "0"
check "66 armed child's OWN environment still lacks HEADED_ARM_REQUIRED_AUTOCOMPACT (not just unprinted)" \
    "$(grep -c '^HEADED_ARM_REQUIRED_AUTOCOMPACT=set$' "$tmp/child-env-66.txt")" "0"
HANDOVER_DIR="$root" bash "$QL" release "$doc66A" "$token66a" >/dev/null 2>&1

# --- 67: console_context_leg_env_unset_names must name
# every var headed-arm-leg.sh propagates to a leg via leg_propagate_env, so a
# NEW leg_propagate_env call site there is a visible gap here, not a silent
# new leak (headed-arm-leg.sh is read-only here; this is the
# contract's "a test that fails when it gains a var the strip list does not
# name").
propagated67="$(grep -v -E '^[[:space:]]*#' "$REPO_REAL/scripts/handover/console-kit/headed-arm-leg.sh" | grep -oE 'leg_propagate_env [A-Z_][A-Z0-9_]*' | awk '{print $2}' | sort -u)"
strip_list67="$( ( . "$REPO_REAL/scripts/lib/chief-context.sh"; console_context_leg_env_unset_names ) | sort -u)"
missing67="$(comm -23 <(printf '%s\n' "$propagated67") <(printf '%s\n' "$strip_list67"))"
check "67 every leg_propagate_env name in headed-arm-leg.sh is in the strip list" "$missing67" ""
# leg_propagate_env also sets each name's worker-session twin, so every twin
# must be stripped too, and a launch-seam name's twin must be seam as well.
twins67="$(sed -n '/^leg_env_twin() {/,/^}/p' "$REPO_REAL/scripts/handover/console-kit/headed-arm-leg.sh" | sed -nE 's/^[[:space:]]*([A-Z_][A-Z0-9_]*)\) echo ([A-Z_][A-Z0-9_]*) ;;/\1 \2/p')"
check "67 headed-arm-leg.sh has a twin table" "$([ -n "$twins67" ] && echo found)" "found"
want67='HIMMEL_LEAN_LEG HIMMEL_LEAN_WORKER_SESSION
HIMMEL_LEG_AUTOCOMPACT HIMMEL_WORKER_SESSION_AUTOCOMPACT
HIMMEL_LEG_CONTEXT_MODE HIMMEL_WORKER_SESSION_CONTEXT_MODE
HIMMEL_LEG_PROFILE HIMMEL_WORKER_SESSION_PROFILE
LEG_CLAUDE_BIN WORKER_SESSION_CLAUDE_BIN
LEG_LANE WORKER_SESSION_LANE
LEG_PROFILE_MCP_CONFIG WORKER_SESSION_PROFILE_MCP_CONFIG
LEG_PROFILE_NO_SETTING_SOURCES WORKER_SESSION_PROFILE_NO_SETTING_SOURCES
LEG_PROFILE_PREFACE WORKER_SESSION_PROFILE_PREFACE
LEG_PROFILE_SETTINGS WORKER_SESSION_PROFILE_SETTINGS
LEG_SESSION_ID WORKER_SESSION_ID
'
check "67 the twin table maps every required leg name to its worker-session twin" "$(comm -13 <(printf '%s\n' "$twins67" | sort -u) <(printf '%s' "$want67" | sort -u))" ""
missing67t="$(comm -23 <(printf '%s\n' "$twins67" | awk '{print $2}' | sort -u) <(printf '%s\n' "$strip_list67"))"
check "67 every worker-session twin in headed-arm-leg.sh is in the strip list" "$missing67t" ""
seam67="$( ( . "$REPO_REAL/scripts/lib/chief-context.sh"; console_context_launch_seam_env_names ) | sort -u)"
seam_missing67=""
while read -r old67 new67; do
    grep -qx "$old67" <<< "$seam67" || continue
    grep -qx "$new67" <<< "$seam67" || seam_missing67="$seam_missing67 $new67"
done <<< "$twins67"
check "67 every launch-seam name's worker-session twin is launch seam too" "$seam_missing67" ""
check "67 armed child's own environment strips LEG_LANE" \
    "$(grep -c '^LEG_LANE=set$' "$tmp/child-env-66.txt")" "0"
check "67 armed child's own environment strips OPENROUTER_MODEL" \
    "$(grep -c '^OPENROUTER_MODEL=set$' "$tmp/child-env-66.txt")" "0"
check "67 armed child's own environment strips HIMMEL_LEG_PROFILE" \
    "$(grep -c '^HIMMEL_LEG_PROFILE=set$' "$tmp/child-env-66.txt")" "0"

# --- 68: --project <dir> -- a console for a repo that is NOT this himmel
# checkout (the himmel-ops plugin's /console, run from e.g. ~/Websites). The
# bucket and prefix come from the project, never from himmel's own
# JIRA_PROJECT_KEY, and the armed session opens in the project, not in himmel.
proj68="$tmp/Web Sites68"; mkdir -p "$proj68"
out68="$(console new --project "$proj68" --dry-run 2>&1)"
check "68 --project: bucket derived from the project dir" \
    "$(printf '%s\n' "$out68" | grep -c "^would-doc: $root/tester/web-sites68/WEBSITES68-nextleg-${today}A-console.md\$")" "1"
check "68 --project: himmel's JIRA_PROJECT_KEY is not the prefix" \
    "$(printf '%s\n' "$out68" | grep -c 'DEMO-nextleg')" "0"
check "68 --project: dry-run names the project the session opens in" \
    "$(printf '%s\n' "$out68" | grep -c "^would-project: $proj68\$")" "1"
out68b="$(console new --project "$proj68" --bucket other68 --prefix OTH --dry-run 2>&1)"
check "68 --project: explicit --bucket/--prefix still win" \
    "$(printf '%s\n' "$out68b" | grep -c "^would-doc: $root/tester/other68/OTH-nextleg-")" "1"
out68c="$(console new --project "$fixture_repo" --dry-run 2>&1)"
check "68 --project at the himmel checkout itself changes nothing (JIRA key kept)" \
    "$(printf '%s\n' "$out68c" | grep -c '^would-doc: .*/DEMO-nextleg-')" "1"
check "68 --project at the himmel checkout prints no would-project" \
    "$(printf '%s\n' "$out68c" | grep -c '^would-project:')" "0"
rc68=0; console new --project "$tmp/no-such-68" --dry-run >/dev/null 2>&1 || rc68=$?
check "68 --project on a missing dir is a usage error" "$rc68" "1"
cat > "$tmp/stub-arm-68.sh" <<'STUB'
#!/usr/bin/env bash
echo "stub-arm-68: HEADED_ARM_REPO=${HEADED_ARM_REPO:-<unset>}"
STUB
out68d="$( ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    HANDOVER_REGISTRY="$tmp/no-such-registry-68.json" \
    CHIEF_HEADED_ARM="$tmp/stub-arm-68.sh" CHIEF_ARM_FOREGROUND=1 CHIEF_WORK_DIR="$tmp/work68" \
    bash "$C" new --project "$proj68" --arm --deadline-min 0 ) 2>&1 )"
# 68d: the console session itself stays
# in the himmel checkout -- --project is data recorded in the doc, never an
# exported HEADED_ARM_REPO for the ARMED CONSOLE (a leg for the project is
# dispatched separately via WORKER_SESSION_REPO). RED against the imported commit (which
# exported HEADED_ARM_REPO=$proj68 here), GREEN after the fix.
check "68d --project --arm does NOT export HEADED_ARM_REPO for the console" \
    "$(printf '%s\n' "$out68d" | grep -c "^stub-arm-68: HEADED_ARM_REPO=<unset>\$")" "1"
doc68="$root/tester/web-sites68/WEBSITES68-nextleg-${today}A-console.md"
check "68d the doc records the project (not just the dry-run line)" \
    "$(grep -c "The project this console is FOR is \*\*\`$proj68\`\*\*" "$doc68" 2>/dev/null)" "1"
HANDOVER_DIR="$root" bash "$QL" release "$doc68" "$(token_of "$out68d")" >/dev/null 2>&1

# --- 68e/68f (change 4): project -> bucket/prefix through the handover
# registry, via a SCRATCH registry file only -- never ~/.claude/handover/registry.json.
reg68="$tmp/registry-68.json"
regproj68="$tmp/Widget Co 68"; mkdir -p "$regproj68"
regproj68_canon="$(cd "$regproj68" && pwd -P)"
cat > "$reg68" <<JSON
{"repos":{"widgets68":{"path":"$regproj68_canon","user":"tester","aliases":[],"keywords":[],"branch_prefix":"","jira_project":"WIDG68"}}}
JSON
out68e="$( HANDOVER_REGISTRY="$reg68" console new --project "$regproj68" --dry-run 2>&1 )"
check "68e a registered path resolves to its registry key + jira_project" \
    "$(printf '%s\n' "$out68e" | grep -c "^would-doc: $root/tester/widgets68/WIDG68-nextleg-${today}A-console.md\$")" "1"

collideproj68="$tmp/collideproj68"; mkdir -p "$collideproj68"
cat > "$reg68" <<JSON
{"repos":{"collideproj68":{"path":"$tmp/some-other-real-project","user":"tester","aliases":[],"keywords":[],"branch_prefix":"","jira_project":"COLL"}}}
JSON
rc68f=0
out68f="$( HANDOVER_REGISTRY="$reg68" console new --project "$collideproj68" --dry-run 2>&1 )" || rc68f=$?
check "68f a basename collision with an unrelated registered key is refused" "$rc68f" "1"
check "68f collision refusal names the conflicting registered path" \
    "$(printf '%s\n' "$out68f" | grep -c "collides with the registered project at '$tmp/some-other-real-project'")" "1"
check "68f no doc written on a collision refusal" \
    "$([ -e "$root/tester/collideproj68" ] && echo yes || echo no)" "no"

# --- 68g (change 7): a SYMLINK to the himmel checkout given as --project is
# canonicalized with pwd -P and recognized as himmel itself, not a foreign
# project (skips on hosts where a real symlink doesn't stick, e.g. Git Bash).
if [ "$HOST_SYMLINKS_REAL" = "1" ]; then
    himmel_link68="$tmp/himmel-link-68"
    ln -s "$fixture_repo" "$himmel_link68"
    out68g="$( HANDOVER_REGISTRY="$tmp/no-such-registry-68.json" console new --project "$himmel_link68" --dry-run 2>&1 )"
    check "68g a symlink to himmel is treated as himmel (no would-project)" \
        "$(printf '%s\n' "$out68g" | grep -c '^would-project:')" "0"
    check "68g a symlink to himmel keeps himmel's own JIRA key" \
        "$(printf '%s\n' "$out68g" | grep -c '^would-doc: .*/DEMO-nextleg-')" "1"
fi

# --- 68h: the 68f collision
# message itself says "pass --bucket to disambiguate", but the collision
# exit used to fire unconditionally -- an explicit --bucket could never
# reach the bucket-resolution code below it. RED against the pre-fix
# collision-exit (always refuses), GREEN after (only refuses when --bucket
# was not given).
collideproj68h="$tmp/collideproj68h"; mkdir -p "$collideproj68h"
cat > "$reg68" <<JSON
{"repos":{"collideproj68h":{"path":"$tmp/some-other-real-project","user":"tester","aliases":[],"keywords":[],"branch_prefix":"","jira_project":"COLL"}}}
JSON
rc68h=0
out68h="$( HANDOVER_REGISTRY="$reg68" console new --project "$collideproj68h" --bucket disambig68h --dry-run 2>&1 )" || rc68h=$?
check "68h an explicit --bucket disambiguates a registry collision (no refusal)" "$rc68h" "0"
check "68h the disambiguated doc uses the explicit --bucket" \
    "$(printf '%s\n' "$out68h" | grep -c "^would-doc: $root/tester/disambig68h/")" "1"

# --- 69a/69b/69c:
# `next` with no --project must not silently record the successor as "the
# himmel checkout itself" for a chain that is FOR a foreign project -- the
# plugin console.md no longer derives --project for `next` (only for `new`,
# see marketplace/plugins/himmel-ops/commands/chief.md), so without this a
# foreign-project chain's successor would fall back into himmel's own DEMO
# bucket. RED against a console.sh that never seeds PROJECT_ARG
# from the predecessor doc.
reg69="$tmp/registry-69.json"
foreignproj69="$tmp/Acme Co 69"; mkdir -p "$foreignproj69"
foreignproj69_canon="$(cd "$foreignproj69" && pwd -P)"
cat > "$reg69" <<JSON
{"repos":{"acme69":{"path":"$foreignproj69_canon","user":"tester","aliases":[],"keywords":[],"branch_prefix":"","jira_project":"ACME69"}}}
JSON
out69a_new="$( HANDOVER_REGISTRY="$reg69" console new --project "$foreignproj69" )"
token69a_new="$(token_of "$out69a_new")"
doc69A="$root/tester/acme69/ACME69-nextleg-${today}A-console.md"
check "69 setup: predecessor doc written under the foreign project's registry bucket" "$([ -f "$doc69A" ] && echo yes)" "yes"

out69a="$( HANDOVER_REGISTRY="$reg69" console next --doc "$doc69A" --dry-run )"
check "69a next --doc with no --project derives the foreign bucket/prefix from the predecessor's recorded project" \
    "$(printf '%s\n' "$out69a" | grep -c "^would-doc: $root/tester/acme69/ACME69-nextleg-${today}B-console.md\$")" "1"
check "69a next --doc with no --project inherits the predecessor's recorded project" \
    "$(printf '%s\n' "$out69a" | grep -c "^would-project: $foreignproj69\$")" "1"

# --- 69b: an explicit --project/--bucket/--prefix on next still overrides
# the inherited value (same predecessor doc as 69a -- --dry-run never claims
# the successor letter, so it stays reusable across these sub-cases).
otherproj69="$tmp/Other Co 69"; mkdir -p "$otherproj69"
out69b="$( HANDOVER_REGISTRY="$reg69" console next --doc "$doc69A" --project "$otherproj69" --bucket otherdst69 --prefix OTH69 --dry-run )"
check "69b an explicit --project/--bucket/--prefix on next overrides the inherited project" \
    "$(printf '%s\n' "$out69b" | grep -c "^would-doc: $root/tester/otherdst69/OTH69-nextleg-${today}B-console.md\$")" "1"
check "69b overridden would-project reflects the explicit --project, not the inherited one" \
    "$(printf '%s\n' "$out69b" | grep -c "^would-project: $otherproj69\$")" "1"
HANDOVER_DIR="$root" bash "$QL" release "$doc69A" "$token69a_new" >/dev/null 2>&1

# --- 69c: a predecessor doc with no recorded project (a native himmel-only
# chain, e.g. case 1's docA) keeps today's fallback -- no project inherited.
out69c="$( console next --bucket demorepo --doc "$docA" --dry-run )"
check "69c a predecessor doc with no recorded project prints no would-project (native fallback unchanged)" \
    "$(printf '%s\n' "$out69c" | grep -c '^would-project:')" "0"

# --- 70: the plugin runs console.sh with the
# cwd in a FOREIGN repo. `repo` (template, kit, queue-lock, the doc's REPO)
# must come from console.sh's OWN location, never the cwd: RED against the
# cwd-first resolve_repo (missing template rc=2 / the foreign queue-lock ran).
console_from() {  # console_from <cwd> <args...>
    local d="$1"; shift
    ( cd "$d" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO CHIEF_WORK_DIR="$tmp/defaultwork" bash "$C" "$@" )
}
foreign70="$tmp/foreign70"; mkdir -p "$foreign70"; git init -q "$foreign70"
rc70a=0; out70a="$(console_from "$foreign70" new --bucket c1plain --dry-run 2>&1)" || rc70a=$?
check "70a a plain foreign cwd still gets himmel's template (dry-run rc=0)" "$rc70a" "0"
check "70a the kit is himmel's, not the foreign cwd's" \
    "$(printf '%s\n' "$out70a" | grep -c "^would-kit: $fixture_repo/scripts/handover/console-kit\$")" "1"
# A foreign repo shipping its own template and a booby-trapped queue-lock: the
# trap writes a sentinel if it is ever executed.
evil70="$tmp/evil70"; mkdir -p "$evil70/docs/handover" "$evil70/scripts/handover"
git init -q "$evil70"
printf 'EVIL-TEMPLATE {{LETTER}} {{SESSION_NAME}} {{REPO}} {{PROJECT}} {{KIT}} {{RELEASE_TOKEN}}\n' > "$evil70/docs/handover/console-template.md"
cp "$fixture_repo/docs/handover/console-handoff-template.md" "$evil70/docs/handover/console-handoff-template.md"
printf '#!/usr/bin/env bash\necho ran > %q\nexit 0\n' "$tmp/evil70-sentinel" > "$evil70/scripts/handover/queue-lock.sh"
rc70b=0; out70b="$(console_from "$evil70" new --bucket c1evil 2>&1)" || rc70b=$?
check "70b a real new from a foreign cwd shipping its own template succeeds" "$rc70b" "0"
check "70b the foreign repo's queue-lock.sh is never executed" "$([ -e "$tmp/evil70-sentinel" ] && echo ran || echo clean)" "clean"
doc70b="$root/tester/c1evil/DEMO-nextleg-${today}A-console.md"
check "70b the doc is rendered from himmel's template, not the foreign one" "$(grep -c 'EVIL-TEMPLATE' "$doc70b" 2>/dev/null)" "0"
check "70b the doc points at the himmel checkout" \
    "$(grep -c "^> \*\*\`$fixture_repo\`\*\*\. The project this console is FOR" "$doc70b" 2>/dev/null)" "1"
check "70b the doc never names the foreign cwd" "$(grep -c "$evil70" "$doc70b" 2>/dev/null)" "0"
HANDOVER_DIR="$root" bash "$QL" release "$doc70b" "$(token_of "$out70b")" >/dev/null 2>&1

# --- 70c (I3): the printed launch line cds into the himmel checkout first, so a
# line pasted into the foreign terminal starts the console in himmel (its hooks,
# its GO gate), not in the foreign cwd.
launch70="$(printf '%s\n' "$out70a" | sed -n 's/^would-launch: //p')"
case "$launch70" in
    "cd $(printf '%q' "$fixture_repo") && { bash "*) l70=cd-himmel ;;
    *) l70="$launch70" ;;
esac
check "70c the printed launch line cds into the himmel checkout first" "$l70" "cd-himmel"
# ... and a cd that fails must not fall through to running claude elsewhere:
# the whole line is one `&&` group, so a failed cd skips the recorder AND claude.
case "$launch70" in
    *"; }") l70e=braced ;;
    *) l70e="$launch70" ;;
esac
check "70c the cd guards the whole line (one braced group)" "$l70e" "braced"

# --- 71 (I1): a same-NAME repo at a different path must not inherit himmel's or
# notes' bucket/prefix through a registry ALIAS.
reg71="$tmp/registry-71.json"
notes71="$tmp/notes71"; mkdir -p "$notes71"
cat > "$reg71" <<JSON
{"repos":{"himmel71":{"path":"$fixture_repo","user":"tester","aliases":["himmel71","internal71"],"keywords":[],"branch_prefix":"","jira_project":"HIM71"},"notes71":{"path":"$notes71","user":"tester","aliases":["docs71","vault71x"],"keywords":[],"branch_prefix":"","jira_project":"NOT71"}}}
JSON
for n71 in himmel71 internal71 docs71; do
    other71="$tmp/other71/$n71"; mkdir -p "$other71"
    rc71=0; out71="$( HANDOVER_REGISTRY="$reg71" console new --project "$other71" --dry-run 2>&1 )" || rc71=$?
    check "71 an unrelated repo named $n71 (a registered key or alias) is refused" "$rc71" "1"
    check "71 $n71 refusal names the collision" "$(printf '%s\n' "$out71" | grep -c 'collides with the registered project')" "1"
    rc71b=0; HANDOVER_REGISTRY="$reg71" console new --project "$other71" --bucket other71b --dry-run >/dev/null 2>&1 || rc71b=$?
    check "71 $n71 with an explicit --bucket disambiguates" "$rc71b" "0"
done
out71c="$( HANDOVER_REGISTRY="$reg71" console new --project "$notes71" --dry-run 2>&1 )"
check "71 the registered path itself still resolves to its key + jira_project" \
    "$(printf '%s\n' "$out71c" | grep -c "^would-doc: $root/tester/notes71/NOT71-nextleg-")" "1"

# --- 72 (I2): a predecessor doc's recorded PROJECT that is missing, relative or
# a file is REFUSED like --project would, never silently dropped so the
# successor falls back to himmel's own bucket.
reg72="$tmp/registry-72.json"
proj72="$tmp/Proj 72"; mkdir -p "$proj72"
printf '{"repos":{}}\n' > "$reg72"
out72="$( HANDOVER_REGISTRY="$reg72" console new --project "$proj72" 2>&1 )"
doc72="$root/tester/proj-72/PROJ72-nextleg-${today}A-console.md"
check "72 setup: a foreign chain doc records its project" "$(grep -c "The project this console is FOR is \*\*\`$proj72\`\*\*" "$doc72" 2>/dev/null)" "1"
touch "$tmp/a-file-72"
rc72p=0; HANDOVER_REGISTRY="$reg72" console new --project "$tmp/a-file-72" --dry-run >/dev/null 2>&1 || rc72p=$?
check "72 (control) --project on a file is refused" "$rc72p" "1"
cp "$doc72" "$doc72.orig"
for bad72 in "$tmp/no-such-dir-72" "." "$tmp/a-file-72"; do
    sed "s|The project this console is FOR is \*\*\`$proj72\`\*\*|The project this console is FOR is **\`$bad72\`**|" "$doc72.orig" > "$doc72"
    rc72=0; out72n="$( HANDOVER_REGISTRY="$reg72" console next --doc "$doc72" --dry-run 2>&1 )" || rc72=$?
    check "72 next refuses a recorded project of '$bad72' (rc=1, like --project)" "$rc72" "1"
    check "72 the refusal is --project's own message for '$bad72'" \
        "$(printf '%s\n' "$out72n" | grep -c "^console: --project must be an existing directory, got '$bad72'\$")" "1"
    check "72 nothing falls back to himmel's bucket for '$bad72'" "$(printf '%s\n' "$out72n" | grep -c '^would-doc:')" "0"
done
cp "$doc72.orig" "$doc72"
out72ok="$( HANDOVER_REGISTRY="$reg72" console next --doc "$doc72" --dry-run 2>&1 )"
check "72 (control) an intact recorded project still inherits" "$(printf '%s\n' "$out72ok" | grep -c "^would-project: $proj72\$")" "1"
HANDOVER_DIR="$root" bash "$QL" release "$doc72" "$(token_of "$out72")" >/dev/null 2>&1

# --- 73: a bare `next` with NOTHING pinning down where to
# search (no --doc, no CHIEF_DOC, no --bucket/--project/--prefix) must
# still find a foreign predecessor and inherit ITS bucket/prefix/project --
# not silently fall back to himmel's own DEMO bucket. RED against pre-fix
# console.sh (state_dir, needed to search, can only ever resolve to himmel's
# own bucket when nothing pins the project down), GREEN after. An isolated
# root avoids any letter/name collision with the rest of this suite.
root73="$tmp/root73"; mkdir -p "$root73"
reg73="$tmp/registry-73.json"
foreignproj73="$tmp/Acme Co 73"; mkdir -p "$foreignproj73"
cat > "$reg73" <<JSON
{"repos":{"acme73":{"path":"$foreignproj73","user":"tester","aliases":[],"keywords":[],"branch_prefix":"","jira_project":"ACME73"}}}
JSON
out73_new="$( HANDOVER_REGISTRY="$reg73" console_root "$root73" new --project "$foreignproj73" )"
token73_new="$(token_of "$out73_new")"
doc73A="$root73/tester/acme73/ACME73-nextleg-${today}A-console.md"
check "73 setup: predecessor doc written under the foreign project's registry bucket" "$([ -f "$doc73A" ] && echo yes)" "yes"
HANDOVER_DIR="$root73" bash "$QL" release "$doc73A" "$token73_new" >/dev/null 2>&1

out73="$( HANDOVER_REGISTRY="$reg73" console_root "$root73" next --dry-run )"
check "73 a bare next with nothing pinning the search finds the foreign predecessor's would-doc" \
    "$(printf '%s\n' "$out73" | grep -c "^would-doc: $root73/tester/acme73/ACME73-nextleg-${today}B-console.md\$")" "1"
check "73 a bare next inherits the foreign predecessor's recorded project" \
    "$(printf '%s\n' "$out73" | grep -c "^would-project: $foreignproj73\$")" "1"

# --- 74 (mirrors 72 for the auto-discovery path): a poisoned
# recorded PROJECT reached through auto-discovery (no --doc) is refused
# exactly like --project would refuse it -- never silently dropped so the
# successor falls back to himmel's own bucket.
root74="$tmp/root74"; mkdir -p "$root74"
reg74="$tmp/registry-74.json"
proj74="$tmp/Proj 74"; mkdir -p "$proj74"
printf '{"repos":{}}\n' > "$reg74"
out74_new="$( HANDOVER_REGISTRY="$reg74" console_root "$root74" new --project "$proj74" )"
token74_new="$(token_of "$out74_new")"
doc74A="$root74/tester/proj-74/PROJ74-nextleg-${today}A-console.md"
check "74 setup: a foreign chain doc records its project" \
    "$(grep -c "The project this console is FOR is \*\*\`$proj74\`\*\*" "$doc74A" 2>/dev/null)" "1"
HANDOVER_DIR="$root74" bash "$QL" release "$doc74A" "$token74_new" >/dev/null 2>&1
cp "$doc74A" "$doc74A.orig"
sed "s|The project this console is FOR is \*\*\`$proj74\`\*\*|The project this console is FOR is **\`$tmp/no-such-dir-74\`**|" "$doc74A.orig" > "$doc74A"
rc74=0; out74="$( HANDOVER_REGISTRY="$reg74" console_root "$root74" next --dry-run 2>&1 )" || rc74=$?
check "74 a bare next refuses a poisoned recorded project (rc=1, like --project)" "$rc74" "1"
check "74 the refusal is --project's own message" \
    "$(printf '%s\n' "$out74" | grep -c "^console: --project must be an existing directory, got '$tmp/no-such-dir-74'\$")" "1"
check "74 nothing falls back to himmel's bucket" "$(printf '%s\n' "$out74" | grep -c '^would-doc:')" "0"

# 75: the user slug resolves from console.sh's OWN checkout, never the
# caller's cwd -- the same pinning load_dotenv gets. The plugin
# /himmel-ops:supervisor-session runs console.sh from any directory; from a non-git one
# forge_detect found no origin, so the slug fell back to the cwd's slugified
# git user.name and the chain forked into a second user dir.
tmp75="$tmp/t75"
mkdir -p "$tmp75/bin" "$tmp75/foreign-cwd"
# shellcheck disable=SC2016  # $1/$2 are the stub gh's own args, not ours
printf '#!/usr/bin/env bash\n[ "$1 $2" = "api user" ] && { echo forge-login-75; exit 0; }\nexit 1\n' > "$tmp75/bin/gh"
chmod +x "$tmp75/bin/gh"
printf '[user]\n\tname = Cwd Fallback\n' > "$tmp75/gitconfig"
git -C "$fixture_repo" remote add origin https://github.com/example/himmel.git
out75="$( cd "$tmp75/foreign-cwd" && env -u USER_SLUG -u FORGE HANDOVER_DIR="$root" JIRA_PROJECT_KEY=DEMO \
    CHIEF_WORK_DIR="$tmp/defaultwork" GIT_CONFIG_GLOBAL="$tmp75/gitconfig" GH_CMD="$tmp75/bin/gh" \
    bash "$C" new --dry-run --bucket slug75 2>&1 )"
check "75 slug is console.sh's own checkout's forge login, not the cwd's git user.name" \
    "$(printf '%s\n' "$out75" | grep -c "^would-doc: $root/forge-login-75/slug75/")" "1"

# 76: an inherited GIT_DIR must not steer the slug either -- the cd
# into console.sh's checkout is void if git still answers about GIT_DIR's repo
# (no origin -> no forge login -> that repo's own user.name wins).
tmp76="$tmp/t76"
mkdir -p "$tmp76/foreign-cwd"
git init -q "$tmp76/poison"
git -C "$tmp76/poison" config user.name "Env Poison"
out76="$( cd "$tmp76/foreign-cwd" && env -u USER_SLUG -u FORGE HANDOVER_DIR="$root" JIRA_PROJECT_KEY=DEMO \
    CHIEF_WORK_DIR="$tmp/defaultwork" GIT_CONFIG_GLOBAL="$tmp75/gitconfig" GH_CMD="$tmp75/bin/gh" \
    GIT_DIR="$tmp76/poison/.git" bash "$C" new --dry-run --bucket slug76 2>&1 )"
check "76 slug ignores an inherited GIT_DIR (checkout's forge login, not GIT_DIR's user.name)" \
    "$(printf '%s\n' "$out76" | grep -c "^would-doc: $root/forge-login-75/slug76/")" "1"

# 77: `next` COPIES the predecessor's <stem>.fleet.json to the
# successor's stem (copy, not rename: the outgoing waiter still reads its own),
# and the successor stub's ACTION ZERO step 10 names the carried manifest path.
out77="$(console new --bucket fleet77src)"
token77="$(token_of "$out77")"
doc77A="$root/tester/fleet77src/DEMO-nextleg-${today}A-console.md"
doc77B="$root/tester/fleet77dst/DEMO-nextleg-${today}B-console.md"
doc77C="$root/tester/fleet77dst2/DEMO-nextleg-${today}B-console.md"
man77A="${doc77A%.md}.fleet.json"
man77B="${doc77B%.md}.fleet.json"
man77C="${doc77C%.md}.fleet.json"
console next --bucket fleet77dst2 --doc "$doc77A" >/dev/null 2>&1
check "77 no predecessor manifest: successor gets none (no-op)" "$([ -e "$man77C" ] && echo yes || echo no)" "no"
check "77 no predecessor manifest: step 10 names the successor's own manifest path" \
    "$(grep -Fc "$man77C" "$doc77C" 2>/dev/null)" "1"
printf '{"schema":1,"legs":["/x/leg.md"]}\n' > "$man77A"
console next --bucket fleet77dst --doc "$doc77A" >/dev/null 2>&1
check "77 manifest is copied to the successor's stem" "$(cat "$man77B" 2>/dev/null)" '{"schema":1,"legs":["/x/leg.md"]}'
check "77 the predecessor's manifest is left in place (copy, not rename)" "$([ -f "$man77A" ] && echo yes)" "yes"
check "77 successor step 10 names the carried manifest path" "$(grep -Fc "$man77B" "$doc77B" 2>/dev/null)" "1"
check "77 no unrendered {{FLEET_MANIFEST}} left in the successor doc" "$(grep -Fc '{{FLEET_MANIFEST' "$doc77B" 2>/dev/null)" "0"
HANDOVER_DIR="$root" bash "$QL" release "$doc77A" "$token77" >/dev/null 2>&1

# --- 78: a name without the -console suffix is refused, nothing armed
before78="$(find "$root" -type f -not -path "$root/.locks/*" | sort)"
rc78n=0; out78n="$(console new --bucket nosuffix78 --name roadmap 2>&1)" || rc78n=$?
check "78 new --name roadmap (no -console suffix) exits non-zero" "$([ "$rc78n" -ne 0 ] && echo yes)" "yes"
check "78 new refusal names the suffix" "$(printf '%s\n' "$out78n" | grep -c -- '-console')" "1"
rc78x=0; console next --bucket nosuffix78 --name roadmap >/dev/null 2>&1 || rc78x=$?
check "78 next --name roadmap (no -console suffix) exits non-zero" "$([ "$rc78x" -ne 0 ] && echo yes)" "yes"
check "78 refusal writes nothing" "$(find "$root" -type f -not -path "$root/.locks/*" | sort)" "$before78"
rc78ok=0; out78ok="$(console new --bucket nosuffix78 --name roadmap-console 2>&1)" || rc78ok=$?
check "78 new --name roadmap-console is accepted" "$rc78ok" "0"
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/nosuffix78/DEMO-nextleg-${today}A-roadmap-console.md" "$(token_of "$out78ok")" >/dev/null 2>&1

# --- 79: the console profile's himmel-bus opt-in registers the
# armed console (--predecessor on next), exports only HIMMEL_BUS_NAME plus the
# bind flag, and drops a predecessor's own HIMMEL_BUS_*; opted-out registers
# and exports nothing; a failed register warns and still arms.
bus79="$tmp/bus79"; mkdir -p "$bus79"
cat > "$bus79/arm.sh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = --role ] && shift 2
printf 'bus_name=%s extra=%s bind=%s\n' "${HIMMEL_BUS_NAME:-<unset>}" "${HIMMEL_BUS_EXTRA:-<unset>}" "${HEADED_ARM_BUS:-<unset>}" >> "$5"
STUB
cat > "$bus79/bus" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/calls"
if [ -n "${BUS79_FAIL:-}" ] && { [ -z "${BUS79_FAIL_VERB:-}" ] || [ "$1" = "$BUS79_FAIL_VERB" ]; }; then
  echo "stub bus: $1 refused" >&2
  exit 1
fi
exit 0
STUB
for v79 in in out; do
  if [ "$v79" = in ]; then n79='["qmd","himmel-bus"]'; else n79='["qmd"]'; fi
  printf "console.log('%s');\n" "$n79" > "$bus79/profiles-$v79.mjs"
done
printf "process.exit(3);\n" > "$bus79/profiles-broken.mjs"
chmod +x "$bus79/arm.sh" "$bus79/bus"
run79() { # <variant> <cmd> <bucket> [extra env...]
  local variant="$1" cmd="$2" bucket="$3"; shift 3
  ( cd "$fixture_repo" && env HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
      HIMMEL_BUS_NAME=old-console HIMMEL_BUS_EXTRA=1 "$@" \
      CHIEF_BUS_CLI="$bus79/bus" CHIEF_BUS_PROFILES_MJS="$bus79/profiles-$variant.mjs" \
      CHIEF_HEADED_ARM="$bus79/arm.sh" CHIEF_ARM_FOREGROUND=1 CHIEF_WORK_DIR="$tmp/work79" \
      bash "$C" "$cmd" --bucket "$bucket" --name bus79-console --arm --deadline-min 0 ) 2>&1
}
out79a="$(run79 in new bus79in)"
session79a="DEMO-nextleg-${today}A-bus79-console"
check "79 opted-in new: register --role console, no predecessor" "$(cat "$bus79/calls" 2>/dev/null)" "register $session79a --role console"
check "79 opted-in new: armed env carries only the registered name + the bind flag" \
    "$(cat "$tmp/work79"/*/launch-"$session79a".log 2>/dev/null | grep -c "^bus_name=$session79a extra=<unset> bind=1\$")" "1"
check "79 opted-in new: the launch log records the registration" \
    "$(cat "$tmp/work79"/*/launch-"$session79a".log 2>/dev/null | grep -c "bus: registered $session79a as console\$")" "1"
rm -f "$bus79/calls"
out79b="$(run79 in next bus79in)"
session79b="DEMO-nextleg-${today}B-bus79-console"
check "79 opted-in next: register carries --predecessor <outgoing session>" "$(cat "$bus79/calls" 2>/dev/null)" "register $session79b --role console --predecessor $session79a
succeed $session79b"
check "79 opted-in next: the launch log records the registration and the stamp" \
    "$(cat "$tmp/work79"/*/launch-"$session79b".log 2>/dev/null | grep -c "bus: registered $session79b as console, stamped successor of $session79a\$")" "1"
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/bus79in/$session79b.md" "$(token_of "$out79b")" >/dev/null 2>&1
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/bus79in/$session79a.md" "$(token_of "$out79a")" >/dev/null 2>&1
rm -f "$bus79/calls"
out79c="$(run79 out new bus79out)"
session79c="DEMO-nextleg-${today}A-bus79-console"
check "79 opted-out: bus never called" "$([ -e "$bus79/calls" ] && echo called || echo none)" "none"
check "79 opted-out: armed env carries no HIMMEL_BUS_* and no bind flag" \
    "$(cat "$tmp/work79"/*/launch-"$session79c".log 2>/dev/null | grep -c "^bus_name=<unset> extra=<unset> bind=<unset>\$")" "1"
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/bus79out/$session79c.md" "$(token_of "$out79c")" >/dev/null 2>&1
rm -f "$bus79/calls"
out79d="$(run79 in new bus79fail BUS79_FAIL=1)"
check "79 failed register: console still arms" "$(printf '%s\n' "$out79d" | grep -c '^armed: ')" "1"
check "79 failed register: warned" "$(printf '%s\n' "$out79d" | grep -c 'WARN bus register failed')" "1"
check "79 failed register: the warning lands in the launch log" \
    "$(cat "$tmp/work79"/*/launch-"DEMO-nextleg-${today}A-bus79-console".log 2>/dev/null | grep -c 'WARN: bus register failed for .* launching unbound')" "1"
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/bus79fail/DEMO-nextleg-${today}A-bus79-console.md" "$(token_of "$out79d")" >/dev/null 2>&1
# a successor whose register works but whose stamp fails still arms, bound, and says so in the launch log
rm -f "$bus79/calls"
out79e="$(run79 in new bus79stamp)"
out79f="$(run79 in next bus79stamp BUS79_FAIL=1 BUS79_FAIL_VERB=succeed)"
session79f="DEMO-nextleg-${today}B-bus79-console"
check "79 failed succeed: console still arms" "$(printf '%s\n' "$out79f" | grep -c '^armed: ')" "1"
check "79 failed succeed: warned on stderr" "$(printf '%s\n' "$out79f" | grep -c 'WARN bus succeed failed')" "1"
check "79 failed succeed: the warning lands in the launch log" \
    "$(cat "$tmp/work79"/*/launch-"$session79f".log 2>/dev/null | grep -c 'WARN: bus succeed failed for .* legs adopt only once')" "1"
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/bus79stamp/$session79f.md" "$(token_of "$out79f")" >/dev/null 2>&1
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/bus79stamp/DEMO-nextleg-${today}A-bus79-console.md" "$(token_of "$out79e")" >/dev/null 2>&1
# a profile probe that errors is not "opted out": the console arms unbound and the launch log says why
rm -f "$bus79/calls"
out79g="$(run79 broken new bus79probe)"
check "79 broken profile probe: console still arms" "$(printf '%s\n' "$out79g" | grep -c '^armed: ')" "1"
check "79 broken profile probe: bus never called" "$([ -e "$bus79/calls" ] && echo called || echo none)" "none"
check "79 broken profile probe: warned on stderr" "$(printf '%s\n' "$out79g" | grep -c 'WARN bus profile probe failed')" "1"
check "79 broken profile probe: the warning lands in the launch log" \
    "$(cat "$tmp/work79"/*/launch-"DEMO-nextleg-${today}A-bus79-console".log 2>/dev/null | grep -c 'WARN: bus profile probe failed')" "1"
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/bus79probe/DEMO-nextleg-${today}A-bus79-console.md" "$(token_of "$out79g")" >/dev/null 2>&1

# --- 80. wrap refuses while a non-harness process is alive -------------------
# wrap-subtree-check.sh and live-subagents.sh are stubbed through their seams;
# the stub subtree check reports WITHHELD rows from $w80/rows until the file is
# emptied, and the console-wait waiter case uses a REAL process so the TERM is
# observed, not logged.
w80="$tmp/wrap80"; mkdir -p "$w80"
printf '#!/usr/bin/env bash\necho live-subagents=0\n' > "$w80/lsa.sh"
cat > "$w80/subtree.sh" <<'STUB'
#!/usr/bin/env bash
rows="$W80/rows"
if [ -n "${W80_RC2:-}" ]; then echo "WITHHELD: cannot read the process table"; exit 2; fi
n=0; out=""
while read -r l; do
    [ -n "$l" ] || continue
    pid="${l#pid=}"; pid="${pid%% *}"
    kill -0 "$pid" 2>/dev/null || continue
    # an orphan reparented to init is no longer under the session
    pp="${l#*ppid=}"; pp="${pp%% *}"
    [ "$pp" = 1 ] || kill -0 "$pp" 2>/dev/null || continue
    n=$((n+1)); out="$out  $l
"
done < "$rows" 2>/dev/null
if [ "$n" -eq 0 ]; then echo "CLOSABLE: no non-harness process under claude pid 1"; exit 0; fi
printf 'WITHHELD: %s process(es) still alive under claude pid 1\n%s' "$n" "$out"
exit 1
STUB
chmod +x "$w80/lsa.sh" "$w80/subtree.sh"
wrap80() { # wrap80 <doc> <token>
    ( cd "$fixture_repo" && W80="$w80" HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
        CHIEF_WORK_DIR="$tmp/defaultwork" LIVE_SUBAGENTS_BIN="$w80/lsa.sh" WRAP_SUBTREE_CHECK_BIN="$w80/subtree.sh" \
        W80_RC2="${W80_RC2:-}" bash "$C" wrap "$1" "$2" ) 2>&1
}
mk80() { # mk80 <name> -> sets doc80 and tok80 (a live console doc with the lock held)
    doc80="$w80/$1.md"
    printf '%s\n' '# console' '## Results' '- 10:00 LIVE — up' > "$doc80"
    tok80="$(token_of "$(HANDOVER_DIR="$root" bash "$QL" acquire "$doc80" 2>&1)")"
}
lock80() { HANDOVER_DIR="$root" bash "$QL" status "$doc80" >/dev/null 2>&1 && echo free || echo held; }

mk80 sleeper
sleep 300 & sleeper80=$!
printf 'pid=%s ppid=1 etime=00:05 cmd=sleep 300\n' "$sleeper80" > "$w80/rows"
rc=0; out="$(wrap80 "$doc80" "$tok80")" || rc=$?
check "80 live sleep child: wrap refused (rc 5)" "$rc" "5"
check "80 live sleep child: refusal names the process" "$(printf '%s\n' "$out" | grep -c "pid=$sleeper80 .*cmd=sleep 300")" "1"
check "80 live sleep child: names the reason" "$(printf '%s\n' "$out" | grep -c 'wrap refused: .*non-harness process')" "1"
check "80 live sleep child: WRAPPED not written" "$(grep -c WRAPPED "$doc80")" "0"
check "80 live sleep child: lock still held" "$(lock80)" "held"
check "80 live sleep child: the process is untouched" "$(kill -0 "$sleeper80" 2>/dev/null && echo alive || echo dead)" "alive"
kill "$sleeper80" 2>/dev/null; wait "$sleeper80" 2>/dev/null

rc=0; out="$(W80_RC2=1 wrap80 "$doc80" "$tok80")" || rc=$?
check "80 unprovable subtree: wrap refused (rc 5)" "$rc" "5"
check "80 unprovable subtree: WRAPPED not written" "$(grep -c WRAPPED "$doc80")" "0"

: > "$w80/rows"
rc=0; out="$(wrap80 "$doc80" "$tok80")" || rc=$?
check "80 idle session: wrap succeeds" "$rc" "0"
check "80 idle session: WRAPPED written" "$(grep -c '^- .*WRAPPED' "$doc80")" "1"
check "80 idle session: lock released" "$(lock80)" "free"

# the console's own waiter (a real console-wait.sh process and its sleep child) is
# exempt, and the wrap stops it
mk80 waiter
printf '#!/usr/bin/env bash\nsleep 300\n' > "$w80/console-wait.sh"
bash "$w80/console-wait.sh" & waiter80=$!
sleep 0.3
child80="$(pgrep -P "$waiter80" | head -n 1)"
printf 'pid=%s ppid=1 etime=00:05 cmd=bash %s/console-wait.sh /x/inbox\npid=%s ppid=%s etime=00:05 cmd=sleep 300\n' "$waiter80" "$w80" "$child80" "$waiter80" > "$w80/rows"
rc=0; out="$(wrap80 "$doc80" "$tok80")" || rc=$?
check "80 console-wait waiter: wrap succeeds" "$rc" "0"
check "80 console-wait waiter: WRAPPED written" "$(grep -c '^- .*WRAPPED' "$doc80")" "1"
check "80 console-wait waiter: stopped by the wrap" "$(kill -0 "$waiter80" 2>/dev/null && echo alive || echo dead)" "dead"
check "80 console-wait waiter: its child is stopped too" "$(kill -0 "$child80" 2>/dev/null && echo alive || echo dead)" "dead"
kill "$waiter80" "$child80" 2>/dev/null; wait "$waiter80" 2>/dev/null

# a grandchild of the waiter (waiter -> bash child -> sleep) dies too, not only the direct child
mk80 grandchild
# shellcheck disable=SC2016  # the fixture script body must keep $0 literal
printf '#!/usr/bin/env bash\nbash "$(dirname "$0")/mid.sh" &\nwait\n' > "$w80/console-wait.sh"
printf '#!/usr/bin/env bash\nsleep 300\ntrue\n' > "$w80/mid.sh"
bash "$w80/console-wait.sh" & waiter80=$!
sleep 0.5
mid80="$(pgrep -P "$waiter80" | head -n 1)"
grand80="$(pgrep -P "$mid80" | head -n 1)"
check "80 waiter grandchild: fixture pids found" "$([ -n "$mid80" ] && [ -n "$grand80" ] && echo yes || echo no)" "yes"
printf 'pid=%s ppid=1 etime=00:05 cmd=bash %s/console-wait.sh /x/inbox\npid=%s ppid=%s etime=00:05 cmd=bash %s/mid.sh\npid=%s ppid=%s etime=00:05 cmd=sleep 300\n' "$waiter80" "$w80" "$mid80" "$waiter80" "$w80" "$grand80" "$mid80" > "$w80/rows"
rc=0; out="$(wrap80 "$doc80" "$tok80")" || rc=$?
check "80 waiter grandchild: wrap succeeds" "$rc" "0"
check "80 waiter grandchild: waiter stopped" "$(kill -0 "$waiter80" 2>/dev/null && echo alive || echo dead)" "dead"
check "80 waiter grandchild: direct child stopped" "$(kill -0 "$mid80" 2>/dev/null && echo alive || echo dead)" "dead"
check "80 waiter grandchild: grandchild stopped" "$(kill -0 "$grand80" 2>/dev/null && echo alive || echo dead)" "dead"
kill "$waiter80" "$mid80" "$grand80" 2>/dev/null; wait "$waiter80" 2>/dev/null

# a descendant that ignores TERM is KILLed, so it never outlives the waiter
mk80 stubborn
printf '#!/usr/bin/env bash\ntrap "" TERM\nsleep 300\ntrue\n' > "$w80/mid.sh"
# shellcheck disable=SC2016  # the fixture script body must keep $0 literal
printf '#!/usr/bin/env bash\nbash "$(dirname "$0")/mid.sh" &\nwait\n' > "$w80/console-wait.sh"
bash "$w80/console-wait.sh" & waiter80=$!
sleep 0.5
mid80="$(pgrep -P "$waiter80" | head -n 1)"
grand80="$(pgrep -P "$mid80" | head -n 1)"
check "80 TERM-ignoring descendant: fixture pids found" "$([ -n "$mid80" ] && [ -n "$grand80" ] && echo yes || echo no)" "yes"
printf 'pid=%s ppid=1 etime=00:05 cmd=bash %s/console-wait.sh /x/inbox\npid=%s ppid=%s etime=00:05 cmd=bash %s/mid.sh\npid=%s ppid=%s etime=00:05 cmd=sleep 300\n' "$waiter80" "$w80" "$mid80" "$waiter80" "$w80" "$grand80" "$mid80" > "$w80/rows"
rc=0; out="$(wrap80 "$doc80" "$tok80")" || rc=$?
check "80 TERM-ignoring descendant: wrap succeeds" "$rc" "0"
check "80 TERM-ignoring descendant: stopped" "$(kill -0 "$mid80" 2>/dev/null && echo alive || echo dead)" "dead"
kill -KILL "$waiter80" "$mid80" "$grand80" 2>/dev/null; wait "$waiter80" 2>/dev/null

# a descendant whose live argv no longer matches its snapshot row (a reused or exec'd pid)
# is never signalled: the wrap is refused and the waiter is left running
mk80 argvchanged
bash "$w80/console-wait.sh" & waiter80=$!
sleep 300 & foreign80=$!
sleep 0.3
printf 'pid=%s ppid=1 etime=00:05 cmd=bash %s/console-wait.sh /x/inbox\npid=%s ppid=%s etime=00:05 cmd=bash %s/other.sh\n' "$waiter80" "$w80" "$foreign80" "$waiter80" "$w80" > "$w80/rows"
rc=0; out="$(wrap80 "$doc80" "$tok80")" || rc=$?
check "80 changed descendant argv: wrap refused (rc 5)" "$rc" "5"
check "80 changed descendant argv: names the reason" "$(printf '%s\n' "$out" | grep -c 'descendant .* changed since the check')" "1"
check "80 changed descendant argv: descendant left running" "$(kill -0 "$foreign80" 2>/dev/null && echo alive || echo dead)" "alive"
check "80 changed descendant argv: waiter left running" "$(kill -0 "$waiter80" 2>/dev/null && echo alive || echo dead)" "alive"
check "80 changed descendant argv: lock still held" "$(lock80)" "held"
kill "$waiter80" "$foreign80" 2>/dev/null; wait 2>/dev/null

# an empty snapshot cmd would match any live process at that pid: refused the same way
mk80 emptycmd
bash "$w80/console-wait.sh" & waiter80=$!
sleep 300 & foreign80=$!
sleep 0.3
printf 'pid=%s ppid=1 etime=00:05 cmd=bash %s/console-wait.sh /x/inbox\npid=%s ppid=%s etime=00:05 cmd=\n' "$waiter80" "$w80" "$foreign80" "$waiter80" > "$w80/rows"
rc=0; out="$(wrap80 "$doc80" "$tok80")" || rc=$?
check "80 empty descendant cmd: wrap refused (rc 5)" "$rc" "5"
check "80 empty descendant cmd: descendant left running" "$(kill -0 "$foreign80" 2>/dev/null && echo alive || echo dead)" "alive"
check "80 empty descendant cmd: waiter left running" "$(kill -0 "$waiter80" 2>/dev/null && echo alive || echo dead)" "alive"
check "80 empty descendant cmd: lock still held" "$(lock80)" "held"
kill "$waiter80" "$foreign80" 2>/dev/null; wait 2>/dev/null

# the waiter does NOT hide a second, foreign process, and is left running on a refusal
mk80 mixed
bash "$w80/console-wait.sh" & waiter80=$!
sleep 300 & foreign80=$!
sleep 0.3
printf 'pid=%s ppid=1 etime=00:05 cmd=bash %s/console-wait.sh /x/inbox\npid=%s ppid=1 etime=00:05 cmd=sleep 300\n' "$waiter80" "$w80" "$foreign80" > "$w80/rows"
rc=0; out="$(wrap80 "$doc80" "$tok80")" || rc=$?
check "80 waiter plus foreign process: wrap refused (rc 5)" "$rc" "5"
check "80 waiter plus foreign process: waiter left running" "$(kill -0 "$waiter80" 2>/dev/null && echo alive || echo dead)" "alive"
check "80 waiter plus foreign process: WRAPPED not written" "$(grep -c WRAPPED "$doc80")" "0"
kill "$waiter80" "$foreign80" 2>/dev/null; wait 2>/dev/null

# a wrong token changes nothing: the waiter is not stopped for a wrap that is refused
mk80 badtoken
bash "$w80/console-wait.sh" & waiter80=$!
sleep 0.3
printf 'pid=%s ppid=1 etime=00:05 cmd=bash %s/console-wait.sh /x/inbox\n' "$waiter80" "$w80" > "$w80/rows"
rc=0; out="$(wrap80 "$doc80" "wrong-token")" || rc=$?
check "80 wrong token: wrap refused" "$([ "$rc" -ne 0 ] && echo refused || echo ran)" "refused"
check "80 wrong token: waiter left running" "$(kill -0 "$waiter80" 2>/dev/null && echo alive || echo dead)" "alive"
check "80 wrong token: WRAPPED not written" "$(grep -c WRAPPED "$doc80")" "0"
kill "$waiter80" 2>/dev/null; wait "$waiter80" 2>/dev/null

# a foreign process that merely names console-wait.sh is not the waiter: refused, never TERMed
mk80 lookalike
sleep 300 & foreign80=$!
sleep 0.3
printf 'pid=%s ppid=1 etime=00:05 cmd=tail -f %s/console-wait.sh.log\n' "$foreign80" "$w80" > "$w80/rows"
rc=0; out="$(wrap80 "$doc80" "$tok80")" || rc=$?
check "80 lookalike argv: wrap refused (rc 5)" "$rc" "5"
check "80 lookalike argv: process left running" "$(kill -0 "$foreign80" 2>/dev/null && echo alive || echo dead)" "alive"
kill "$foreign80" 2>/dev/null; wait "$foreign80" 2>/dev/null
HANDOVER_DIR="$root" bash "$QL" release "$doc80" "$tok80" >/dev/null 2>&1

# --- 81. next refuses a HANDOFF that drops the predecessor's decisions line --
# The outgoing console (letter B) succeeded A. `next` compares B's `decisions:`
# Live-state line with A's and refuses a missing, placeholder or shorter one
# unless B's Results carry a `DECISIONS-DROP: <reason>` bullet.
# mk81 <bucket> <pred-decisions|-> <out-decisions|-> [extra-bullet]; "-" = no line.
mk81() {
    local d="$root/tester/$1" pd="$2" od="$3" extra="${4:-}"
    mkdir -p "$d"
    {
        printf '# A — CONSOLE — successor to none (fill signal 70 %%)\n\n## Live state\n'
        [ "$pd" = "-" ] || printf 'decisions: %s\n' "$pd"
    } > "$d/DEMO-nextleg-${today}A-console.md"
    {
        printf '# B — CONSOLE — successor to DEMO-nextleg-%sA-console.md (fill signal 70 %%)\n\n## Live state\n' "$today"
        [ "$od" = "-" ] || printf 'decisions: %s\n' "$od"
        printf '\n## Current direction\n\nIn work: the fixture.\n\n## Results\n'
        [ -z "$extra" ] || printf '%s\n' "$extra"
    } > "$d/DEMO-nextleg-${today}B-console.md"
}
run81() { rc81=0; out81="$(console next --bucket "$1" --doc "$root/tester/$1/DEMO-nextleg-${today}B-console.md" 2>&1)" || rc81=$?; }
mk81 dec81a "rename ruling 00:05; keep N2" "rename ruling 00:05; keep N2"; run81 dec81a
check "81 equal decisions line passes" "$rc81" "0"
mk81 dec81b "rename ruling 00:05" "rename ruling 00:05; keep N2"; run81 dec81b
check "81 longer decisions line passes" "$rc81" "0"
mk81 dec81c "rename ruling 00:05; keep N2" "keep N2"; run81 dec81c
check "81 shorter decisions line refuses" "$rc81" "1"
check "81 refusal quotes the predecessor's line" "$(printf '%s\n' "$out81" | grep -cF 'rename ruling 00:05; keep N2')" "1"
check "81 refusal writes no HANDOFF" "$([ -f "$root/tester/dec81c/DEMO-nextleg-${today}B-console-HANDOFF.md" ] && echo yes || echo no)" "no"
mk81 dec81d "rename ruling 00:05; keep N2" "keep N2" "- 10:00 FINDING — DECISIONS-DROP: rename ruling superseded by the 10:00 ruling"; run81 dec81d
check "81 shorter line plus DECISIONS-DROP bullet passes" "$rc81" "0"
mk81 dec81d2 "rename ruling 00:05; keep N2" "keep N2"; printf -- '- DECISIONS-DROP: not in Results\n' >> "$root/tester/dec81d2/DEMO-nextleg-${today}B-console.md"
sed 's/^## Results$/## Other/' "$root/tester/dec81d2/DEMO-nextleg-${today}B-console.md" > "$root/tester/dec81d2.n" && mv "$root/tester/dec81d2.n" "$root/tester/dec81d2/DEMO-nextleg-${today}B-console.md"; run81 dec81d2
check "81 DECISIONS-DROP bullet outside Results does not exempt" "$rc81" "1"
mk81 dec81d3 "rename ruling 00:05; keep N2" "keep N2" "- 10:00 FINDING — DECISIONS-DROP: <reason>"; run81 dec81d3
check "81 DECISIONS-DROP with a placeholder reason does not exempt" "$rc81" "1"
mk81 dec81e "rename ruling 00:05" "-"; run81 dec81e
check "81 missing line when predecessor had one refuses" "$rc81" "1"
mk81 dec81f "rename ruling 00:05" "none"; run81 dec81f
check "81 placeholder none refuses" "$rc81" "1"
mk81 dec81g "rename ruling 00:05" "<fill in>"; run81 dec81g
check "81 angle-bracket placeholder refuses" "$rc81" "1"
mk81 dec81h "none" "-"; run81 dec81h
check "81 predecessor with placeholder decisions passes" "$rc81" "0"
mk81 dec81i "-" "-"; run81 dec81i
check "81 predecessor without a decisions line passes" "$rc81" "0"
mk81 dec81j "rename ruling 00:05" "-"; sed '1s/successor to .*/successor to none (fill signal 70 %)/' "$root/tester/dec81j/DEMO-nextleg-${today}B-console.md" > "$root/tester/dec81j.n" && mv "$root/tester/dec81j.n" "$root/tester/dec81j/DEMO-nextleg-${today}B-console.md"; run81 dec81j
check "81 doc with no predecessor passes" "$rc81" "0"
mk81 dec81k "rename ruling 00:05" "-"; rm "$root/tester/dec81k/DEMO-nextleg-${today}A-console.md"; run81 dec81k
check "81 predecessor doc absent passes" "$rc81" "0"

# --- 82: the rendered HANDOFF stays under the ~1.5k-token budget:
# a large open-PR set, many legs and a full Results tail become pointers; the
# Live state (rulings, tokens) is seeded into the successor doc whole.
out82="$(console new --bucket cap82)"
token82="$(token_of "$out82")"
doc82A="$root/tester/cap82/DEMO-nextleg-${today}A-console.md"
handoff82A="$root/tester/cap82/DEMO-nextleg-${today}A-console-HANDOFF.md"
# shellcheck disable=SC2016  # the loop is expanded by the generated stub
printf '#!/usr/bin/env bash\nfor i in $(seq 1 300); do echo "#$i [DEMO-$i] a fixture pull request title long enough to bulk (feat/branch-$i)"; done\n' > "$tmp/facts-prs82.sh"
legs82=""
for i in $(seq 1 30); do
    printf '%s\n' '# leg' '## Results' "- 10:00 LIVE — $(printf 'x%.0s' $(seq 1 180))" > "$root/tester/cap82/DEMO-leg82-N$i.md"
    legs82="$legs82${legs82:+,}{\"label\":\"N$i\",\"doc\":\"$root/tester/cap82/DEMO-leg82-N$i.md\"}"
done
printf '{"legs":[%s]}\n' "$legs82" > "$root/tester/cap82/DEMO-nextleg-${today}A-console.fleet.json"
for i in $(seq 1 20); do printf '%s\n' "- 11:$i LIVE — $(printf 'y%.0s' $(seq 1 200))" >> "$doc82A"; done
awk '/^queue:/ { print "queue: KEEP-82-MARKER"; next } /^decisions:/ { print "decisions: KEEP-82-DEC"; print "priority: KEEP-82-PRI"; next } { print }' "$doc82A" > "$doc82A.new" && mv "$doc82A.new" "$doc82A"
HANDOFF_FACTS_PRS="$tmp/facts-prs82.sh" console next --bucket cap82dst --doc "$doc82A" >/dev/null 2>&1
doc82B="$root/tester/cap82dst/DEMO-nextleg-${today}B-console.md"
check "82 HANDOFF is at most 6000 bytes" "$([ "$(wc -c < "$handoff82A")" -le 6000 ] && echo yes || echo no)" "yes"
check "82 over budget: open PRs become a pointer" "$(grep -c 'over the HANDOFF size budget — run: gh pr list' "$handoff82A")" "1"
check "82 the Live state content survives the fallback" "$(grep -c "^queue: KEEP-82-MARKER" "$doc82B")" "1"
check "82 the decisions line survives the fallback" "$(grep -c '^decisions: KEEP-82-DEC' "$doc82B")" "1"
check "82 the priority line survives the fallback" "$(grep -c '^priority: KEEP-82-PRI' "$doc82B")" "1"
check "82 the rulings section stays" "$(grep -c '^## Rulings and judgement notes' "$handoff82A")" "1"
check "82 the open-PR pointer names the repo" "$(grep -c 'gh pr list -R example/himmel --state open' "$handoff82A")" "1"
check "82 under budget: no over-budget note" "$(grep -c '^> HANDOFF over budget' "$handoff82A")" "0"
HANDOVER_DIR="$root" bash "$QL" release "$doc82A" "$token82" >/dev/null 2>&1

# --- 83: still over budget after the pointer pass: a stderr warning with the
# byte count and a one-line note in the HANDOFF; the rulings are not trimmed.
out83="$(console new --bucket cap83)"
token83="$(token_of "$out83")"
doc83A="$root/tester/cap83/DEMO-nextleg-${today}A-console.md"
handoff83A="$root/tester/cap83/DEMO-nextleg-${today}A-console-HANDOFF.md"
HANDOFF_BUDGET_BYTES=1000 console next --bucket cap83dst --doc "$doc83A" >/dev/null 2>"$tmp/err83"
check "83 stderr warns with the byte count" "$(grep -cE 'warning: HANDOFF over budget: [0-9]+ bytes \(limit 1000\)' "$tmp/err83")" "1"
check "83 the HANDOFF carries the over-budget note" "$(grep -cE '^> HANDOFF over budget: [0-9]+ bytes \(limit 1000\); wrapped-PR list [0-9]+ bytes' "$handoff83A")" "1"
check "83 the rulings section stays" "$(grep -c '^## Rulings and judgement notes' "$handoff83A")" "1"
HANDOVER_DIR="$root" bash "$QL" release "$doc83A" "$token83" >/dev/null 2>&1

# --- 84: a repo with no origin remote must not abort `next` mid-render: the
# pointer falls back to a placeholder and the wrapped-PR section is still written.
out84="$(console new --bucket cap84)"
token84="$(token_of "$out84")"
doc84A="$root/tester/cap84/DEMO-nextleg-${today}A-console.md"
handoff84A="$root/tester/cap84/DEMO-nextleg-${today}A-console-HANDOFF.md"
origin84="$(git -C "$fixture_repo" remote get-url origin)"
git -C "$fixture_repo" remote remove origin
rc84=0
HANDOFF_BUDGET_BYTES=1000 console next --bucket cap84dst --doc "$doc84A" >/dev/null 2>&1 || rc84=$?
git -C "$fixture_repo" remote add origin "$origin84"
check "84 next with no origin exits 0" "$rc84" "0"
check "84 the pointer falls back to the placeholder repo" "$(grep -cF 'gh pr list -R <owner/repo> --state open' "$handoff84A")" "1"
check "84 the wrapped-PR section is still written" "$(grep -c '^## Wrapped with open PR' "$handoff84A")" "1"
HANDOVER_DIR="$root" bash "$QL" release "$doc84A" "$token84" >/dev/null 2>&1

# --- 85: the wrapped-PR list counts toward the budget decision. Two identical
# fixtures (same-length bucket names); the second runs with a budget one byte
# under the first's final size, so only the wrapped bytes tip it over.
mk85() { # <bucket>
    local b="$1" d="$root/tester/$1"
    console new --bucket "$b" >"$tmp/out85-$b"
    printf '%s\n' '# leg' '## Results' '- 10:00 READY 5 aaaa GREEN' '- 10:05 WRAPPED — done' > "$d/DEMO-85-N1.md"
    printf '{"legs":[{"label":"N1","doc":"%s"}]}\n' "$d/DEMO-85-N1.md" > "$d/DEMO-nextleg-${today}A-console.fleet.json"
}
mk85 cap85x
mk85 cap85y
console next --bucket cap85xdst --doc "$root/tester/cap85x/DEMO-nextleg-${today}A-console.md" >/dev/null 2>&1
size85="$(wc -c < "$root/tester/cap85x/DEMO-nextleg-${today}A-console-HANDOFF.md")"
HANDOFF_BUDGET_BYTES=$((size85 - 1)) console next --bucket cap85ydst --doc "$root/tester/cap85y/DEMO-nextleg-${today}A-console.md" >/dev/null 2>&1
handoff85y="$root/tester/cap85y/DEMO-nextleg-${today}A-console-HANDOFF.md"
check "85 under budget: the first fixture keeps its open-PR facts inline" "$(grep -c 'over the HANDOFF size budget — run: gh pr list' "$root/tester/cap85x/DEMO-nextleg-${today}A-console-HANDOFF.md")" "0"
check "85 the wrapped-PR bytes tip the second fixture into the pointer pass" "$(grep -c 'over the HANDOFF size budget — run: gh pr list' "$handoff85y")" "1"
check "85 the wrapped-PR entry is still listed" "$(grep -c '^- PR #5 (N1)' "$handoff85y")" "1"

# --- 86. next carries every shift-spanning Live-state line into the successor --
# `priority:`, `decisions:`, `epics:`, `versions:` and `tracker-plan:` reach the
# successor doc verbatim, not only the HANDOFF; legs/queue/last GO/acked stay
# per-shift. Then the guard: an outgoing doc that lost its predecessor's
# `priority:` line is refused like a lost `decisions:` line.
out86="$(console new --bucket carrysrc)"
doc86A="$root/tester/carrysrc/DEMO-nextleg-${today}A-console.md"
doc86B="$root/tester/carrydst/DEMO-nextleg-${today}B-console.md"
pri86='priority: 6127 | 6137(K1) 6143(K7) | 6123 6125'
dec86='decisions: OPERATOR 10-17 (BINDING): free slots fill only from the priority pool'
epi86='epics: HIMMEL-6169=12'
ver86='versions: v1.1.3'
tpl86='tracker-plan: /fixture/plan'
rel86='release: v1.1.3-4'
rm86='rm: HIMMEL-rm-fixture /fixture/rm/doc.md epoch=2'
awk -v p="$pri86" -v d="$dec86" -v e="$epi86" -v v="$ver86" -v t="$tpl86" -v r="$rel86" -v m="$rm86" '
    /^epics: none$/ { print e; next }
    /^decisions: none$/ { print d; print p; print v; print t; print r; print m; next }
    { print }' "$doc86A" > "$doc86A.new" && mv "$doc86A.new" "$doc86A"
rc86=0
console next --bucket carrydst --doc "$doc86A" >/dev/null 2>&1 || rc86=$?
check "86 next succeeds against a doc carrying priority/decisions/epics" "$rc86" "0"
for line86 in "$pri86" "$dec86" "$epi86" "$ver86" "$tpl86" "$rel86" "$rm86"; do
    check "86 successor doc carries '${line86%%:*}:' verbatim" \
        "$(grep -Fxc "$line86" "$doc86B" 2>/dev/null)" "1"
done
check "86 successor doc has no placeholder decisions: none" \
    "$(grep -Fxc 'decisions: none' "$doc86B" 2>/dev/null)" "0"
check "86 successor doc has no unrendered {{...}} slot" \
    "$(grep -c '{{[A-Z_]*}}' "$doc86B" 2>/dev/null)" "0"
# Guard: A had priority:, outgoing B dropped it.
mkdir -p "$root/tester/pri86"
printf '# A — CONSOLE — successor to none (fill signal 70 %%)\n\n## Live state\n%s\n' "$pri86" \
    > "$root/tester/pri86/DEMO-nextleg-${today}A-console.md"
printf '# B — CONSOLE — successor to DEMO-nextleg-%sA-console.md (fill signal 70 %%)\n\n## Live state\nepics: none\n\n## Current direction\n\nIn work: the fixture.\n\n## Results\n' "$today" \
    > "$root/tester/pri86/DEMO-nextleg-${today}B-console.md"
rc86=0; out86="$(console next --bucket pri86 --doc "$root/tester/pri86/DEMO-nextleg-${today}B-console.md" 2>&1)" || rc86=$?
check "86 outgoing doc that lost the predecessor's priority: line refuses" "$rc86" "1"
check "86 refusal quotes the predecessor's priority line" \
    "$(printf '%s\n' "$out86" | grep -cF '6137(K1) 6143(K7)')" "1"
# A prune that closed every key leaves `priority: none`; a PRIORITY-PRUNE bullet accepts it.
printf '# B — CONSOLE — successor to DEMO-nextleg-%sA-console.md (fill signal 70 %%)\n\n## Live state\npriority: none\n\n## Current direction\n\nIn work: the fixture.\n\n## Results\n- 10:00 LIVE — PRIORITY-PRUNE: dropped 6127 6137 6143 6123 6125, all Done (operator OK)\n' "$today" \
    > "$root/tester/pri86/DEMO-nextleg-${today}B-console.md"
rc86=0; console next --bucket pri86 --doc "$root/tester/pri86/DEMO-nextleg-${today}B-console.md" >/dev/null 2>&1 || rc86=$?
check "86 a PRIORITY-PRUNE bullet accepts an emptied priority: line" "$rc86" "0"

# --- 87. a shorter decisions: line that points at a bucket decisions file ----
# It passes only when the file exists and every numbered "(N) " entry of the
# predecessor's line (and of any decisions file that line names) is found
# verbatim in the outgoing line or the file(s) it names; else DECISIONS-DROP.
# The entries are copied from a live console's decisions: line.
p87='OPERATOR 10-17 afternoon (BINDING, carry verbatim to every successor): (3) Residuals 6102-6108, 6110 deferred (out of v1.1.3). Windows/WSL support work is NEVER dispatched. (4) qmd fork: version with tags + main (bump main too, tag releases). (6) Use more fleet + Claude API + claudex budget; WORKER_SESSION_EFFORT high on claudex legs.'
e87_3='(3) Residuals 6102-6108, 6110 deferred (out of v1.1.3). Windows/WSL support work is NEVER dispatched.'
e87_4='(4) qmd fork: version with tags + main (bump main too, tag releases).'
e87_5='(6) Use more fleet + Claude API + claudex budget; WORKER_SESSION_EFFORT high on claudex legs.'
f87='specs/decisions/console-decisions-2026-10-20.md'
o87="$f87 holds #3-#4; active: $e87_5"
# mk87 <bucket> <file body|-> [pred-line]; "-" = no decisions file.
mk87() {
    mk81 "$1" "${3:-$p87}" "$o87"
    [ "$2" = "-" ] || { mkdir -p "$root/tester/$1/specs/decisions"; printf '%s\n' "$2" > "$root/tester/$1/$f87"; }
}
mk87 dec87a "$(printf '%s\n%s' "$e87_3" "$e87_4")"; run81 dec87a
check "87 pointer line whose file holds the moved entries verbatim passes" "$rc81" "0"
mk87 dec87b -; run81 dec87b
check "87 pointer line whose file is missing refuses" "$rc81" "1"
mk87 dec87c "$e87_3"; run81 dec87c
check "87 pointer line whose file lacks an entry refuses" "$rc81" "1"
check "87 refusal names the entry not found verbatim" "$(printf '%s\n' "$out81" | grep -cF 'not found verbatim: (4) qmd fork')" "1"
mk87 dec87d "$(printf '%s\n%s' "$e87_3" "${e87_4/tag releases/tag release}")"; run81 dec87d
check "87 pointer line whose file reworded an entry refuses" "$rc81" "1"
mk81 dec87e "$p87" "$e87_3 $e87_4 $e87_5"; run81 dec87e
check "87 shorter line with every entry but no decisions file refuses" "$rc81" "1"
mk87 dec87f "$(printf '%s\n%s' "$e87_3" "$e87_4")" "specs/decisions/console-decisions-2026-10-19.md holds #1; active: $e87_3 $e87_4 $e87_5"
mkdir -p "$root/tester/dec87f/specs/decisions"; printf '%s\n' '(1) TOP of v1.1.3 = the audit items as tickets.' > "$root/tester/dec87f/specs/decisions/console-decisions-2026-10-19.md"
run81 dec87f
check "87 pointer line dropping its predecessor's decisions file entries refuses" "$rc81" "1"
mk87 dec87g "$(printf '%s\n%s\n%s' '(1) TOP of v1.1.3 = the audit items as tickets.' "$e87_3" "$e87_4")" "specs/decisions/console-decisions-2026-10-19.md holds #1; active: $e87_3 $e87_4 $e87_5"
printf '%s\n' '(1) TOP of v1.1.3 = the audit items as tickets.' > "$root/tester/dec87g/specs/decisions/console-decisions-2026-10-19.md"
run81 dec87g
check "87 pointer line carrying its predecessor's file entries forward passes" "$rc81" "0"
mk87 dec87h "$(printf '%s\n%s\n%s' '(1) TOP of v1.1.3 = the audit items as tickets.' "$e87_3" "$e87_4")" "specs/decisions/console-decisions-2026-10-19.md holds #1; active: $e87_3 $e87_4 $e87_5"
printf '%s\n%s\n' '# Console decisions 2026-10-19' '(1) TOP of v1.1.3 = the audit items as tickets.' > "$root/tester/dec87h/specs/decisions/console-decisions-2026-10-19.md"
run81 dec87h
check "87 a heading in the predecessor's decisions file is not part of an entry" "$rc81" "0"
mk81 dec87i "specs/decisions/console-decisions-2026-10-19.md holds #1; active: $e87_3 $e87_4 $e87_5" "$e87_3 $e87_4 $e87_5 (7) Fleet cap 50; fill free slots from the FOCUS v1.1.3 To Do pool after draining owner-less In Progress."
mkdir -p "$root/tester/dec87i/specs/decisions"; printf '%s\n' '(1) TOP of v1.1.3 = the audit items as tickets.' > "$root/tester/dec87i/specs/decisions/console-decisions-2026-10-19.md"
run81 dec87i
check "87 a longer line that drops its predecessor's decisions file refuses" "$rc81" "1"
mk87 dec87j "$(printf '%s\n%s' "$e87_3" "$e87_4 Only on Sundays.")"; run81 dec87j
check "87 pointer line whose file extended an entry refuses" "$rc81" "1"

# --- 88: the pasted launch line binds the console on the bus, as the armed
# path does: the console profile's opt-in registers the session as a console
# (--predecessor on next) and binds the pid claude then runs as, and claude
# gets HIMMEL_BUS_NAME and none of the pasting shell's HIMMEL_BUS_*; opted-out
# calls nothing; a failed register still starts claude, unbound.
b88="$tmp/bus88"; mkdir -p "$b88/bin"
cat > "$b88/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'pid=%s bus_name=%s extra=%s\n' "$$" "${HIMMEL_BUS_NAME:-<unset>}" "${HIMMEL_BUS_EXTRA:-<unset>}" >> "$B88_SEEN"
STUB
cat > "$b88/bus" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/calls"
[ -z "${BUS88_HANG:-}" ] || exec sleep 30
[ -z "${BUS88_FAIL:-}" ]
STUB
chmod +x "$b88/bin/claude" "$b88/bus"
print88() { # <in|out> <new|next> <bucket>
  ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO CHIEF_WORK_DIR="$tmp/work88" \
      CHIEF_BUS_PROFILES_MJS="$bus79/profiles-$1.mjs" bash "$C" "$2" --bucket "$3" --name bus88-console ) 2>&1
}
paste88() { # <printed output> [extra env...]
  local line; line="$(printf '%s\n' "$1" | sed -n 's/^launch: //p')"; shift
  rm -f "$b88/calls" "$b88/seen"
  ( cd "$tmp" && env PATH="$b88/bin:$PATH" B88_SEEN="$b88/seen" CHIEF_BUS_CLI="$b88/bus" \
      HIMMEL_BUS_NAME=old-console HIMMEL_BUS_EXTRA=1 "$@" bash -c "$line" ) >/dev/null 2>&1
}
pid88() { sed -n 's/^pid=\([0-9]*\) .*/\1/p' "$b88/seen" 2>/dev/null; }
s88a="DEMO-nextleg-${today}A-bus88-console"
out88a="$(print88 in new bus88in)"
paste88 "$out88a"
check "88 opted-in new: the pasted line registers the console, then binds the pid claude runs as" \
    "$(cat "$b88/calls" 2>/dev/null)" "register $s88a --role console
bind $s88a $(pid88)"
check "88 opted-in new: claude gets HIMMEL_BUS_NAME and no other HIMMEL_BUS_*" \
    "$(sed 's/^pid=[0-9]* //' "$b88/seen" 2>/dev/null)" "bus_name=$s88a extra=<unset>"
s88b="DEMO-nextleg-${today}B-bus88-console"
out88b="$(print88 in next bus88in)"
paste88 "$out88b"
check "88 opted-in next: register carries --predecessor <outgoing session>" \
    "$(sed -n 1p "$b88/calls" 2>/dev/null)" "register $s88b --role console --predecessor $s88a"
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/bus88in/$s88b.md" "$(token_of "$out88b")" >/dev/null 2>&1
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/bus88in/$s88a.md" "$(token_of "$out88a")" >/dev/null 2>&1
out88c="$(print88 out new bus88out)"
paste88 "$out88c"
check "88 opted-out: bus never called" "$([ -e "$b88/calls" ] && echo called || echo none)" "none"
check "88 opted-out: claude still starts" "$([ -s "$b88/seen" ] && echo started || echo not-started)" "started"
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/bus88out/$s88a.md" "$(token_of "$out88c")" >/dev/null 2>&1
out88d="$(print88 in new bus88fail)"
paste88 "$out88d" BUS88_FAIL=1
check "88 failed register: no bind, claude starts unbound" \
    "$(cat "$b88/calls" 2>/dev/null)|$(sed 's/^pid=[0-9]* //' "$b88/seen" 2>/dev/null)" "register $s88a --role console|bus_name=<unset> extra=<unset>"
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/bus88fail/$s88a.md" "$(token_of "$out88d")" >/dev/null 2>&1
# a broken profile probe is not an opt-out: the printed line runs claude unbound and chief.sh says so
out88e="$(print88 broken new bus88probe)"
paste88 "$out88e"
check "88 broken profile probe: chief.sh warns the printed line runs unbound" \
    "$(printf '%s\n' "$out88e" | grep -c 'the printed console line runs claude unbound')" "1"
check "88 broken profile probe: bus never called, claude still starts" \
    "$([ -e "$b88/calls" ] && echo called || echo none)|$([ -s "$b88/seen" ] && echo started || echo not-started)" "none|started"
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/bus88probe/$s88a.md" "$(token_of "$out88e")" >/dev/null 2>&1

# --- 89: the pasted line never hangs on the bus: a bus call stuck past
# BUS_EXEC_SECS is killed and claude starts unbound; and a line whose
# console-bus-exec.sh is gone runs claude directly.
out89a="$(print88 in new bus89hang)"
if [ -n "$_TIMEOUT_BIN" ]; then
    rc89=0
    paste88 "$out89a" BUS88_HANG=1 BUS_EXEC_SECS=1 "$_TIMEOUT_BIN" 20 || rc89=$?
    check "89 stuck bus: the pasted line does not hang" "$rc89" "0"
    check "89 stuck bus: claude starts unbound" \
        "$(sed 's/^pid=[0-9]* //' "$b88/seen" 2>/dev/null)" "bus_name=<unset> extra=<unset>"
else
    echo "ok - SKIPPED: 89 stuck bus: no timeout or gtimeout on this host"
fi
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/bus89hang/$s88a.md" "$(token_of "$out89a")" >/dev/null 2>&1
out89b="$(print88 in new bus89gone)"
paste88 "$(printf '%s\n' "$out89b" | sed 's/console-bus-exec\.sh/console-bus-exec-gone.sh/g')"
check "89 wrapper missing: claude still starts" "$([ -s "$b88/seen" ] && echo started || echo not-started)" "started"
check "89 wrapper missing: bus never called" "$([ -e "$b88/calls" ] && echo called || echo none)" "none"
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/bus89gone/$s88a.md" "$(token_of "$out89b")" >/dev/null 2>&1

# --- 90: next pre-computes ACTION ZERO into the successor doc: the probes run
# with the successor's lock left free, the block leads with the verify-only
# instruction, and the DOC digest (the doc's own Live state) is not repeated.
printf '#!/usr/bin/env bash\necho "bank ok 9%%"\necho PROCEED\n' > "$tmp/az-bank.sh"
printf '#!/usr/bin/env bash\necho "OK   C29-child-session: none"\n' > "$tmp/az-doctor.sh"
printf '#!/usr/bin/env bash\necho partial\nexit 3\n' > "$tmp/az-fail.sh"
out90a="$(console new --bucket az90)"
token90a="$(token_of "$out90a")"
doc90A="$root/tester/az90/DEMO-nextleg-${today}A-console.md"
doc90B="$root/tester/az90/DEMO-nextleg-${today}B-console.md"
ACTION_ZERO_SCRIPT="$fixture_repo/scripts/handover/console-kit/action-zero.sh" ACTION_ZERO_BANK="$tmp/az-bank.sh" ACTION_ZERO_DOCTOR="$tmp/az-doctor.sh" \
    console next --bucket az90 >/dev/null
block90="$(awk '/^### Pre-computed by chief.sh next/ {s = 1} s && /^## / {exit} s' "$doc90B")"
check "90 next writes the pre-computed block" "$(printf '%s\n' "$block90" | grep -c '^### Pre-computed by chief.sh next at ')" "1"
check "90 the block tells the successor to verify, not re-run" "$(printf '%s\n' "$block90" | grep -c 'verify these results, do not re-run them')" "1"
check "90 the block carries every probe but C29" "$(printf '%s\n' "$block90" | grep -cE '^== (LOCKS|HEAD|BANK|PROCS|LOAD|LOCK)( |$)')" "6"
check "90 the block omits C29 (the successor runs it)" "$(printf '%s\n' "$block90" | grep -c '^== C29')" "0"
check "90 the block names the successor's C29 call" "$(printf '%s\n' "$block90" | grep -c 'himmel-doctor.sh\" --only C29')" "1"
check "90 the block carries the bank result" "$(printf '%s\n' "$block90" | grep -c '^bank ok 9%$')" "1"
check "90 the block reads the successor's lock as free" "$(printf '%s\n' "$block90" | sed -n '/^== LOCK (this document)/,$p' | grep -cx 'free')" "1"
check "90 the block omits the DOC digest" "$(printf '%s\n' "$block90" | grep -c '^== DOC')" "0"
check "90 next leaves the successor's lock free" "$(HANDOVER_DIR="$root" bash "$QL" status "$doc90B" 2>&1 | head -1)" "free"
check "90 the block sits inside ACTION ZERO, before the Live state" \
    "$(awk '/^## ACTION ZERO/ {a = NR} /^### Pre-computed by chief.sh next/ {b = NR} $0 == "## Live state" {c = NR} END {print (a && a < b && b < c) ? "yes" : "no"}' "$doc90B")" "yes"
HANDOVER_DIR="$root" bash "$QL" release "$doc90A" "$token90a" >/dev/null 2>&1
out90c="$(console new --bucket az90fail)"
token90c="$(token_of "$out90c")"
rc90=0
ACTION_ZERO_SCRIPT="$tmp/az-fail.sh" console next --bucket az90fail >/dev/null 2>&1 || rc90=$?
check "90 a failing action-zero does not stop next" "$rc90" "0"
check "90 a failing action-zero marks the block unavailable" \
    "$(grep -c '^unavailable (action-zero.sh exited 3): run it yourself$' "$root/tester/az90fail/DEMO-nextleg-${today}B-console.md")" "1"
HANDOVER_DIR="$root" bash "$QL" release "$root/tester/az90fail/DEMO-nextleg-${today}A-console.md" "$token90c" >/dev/null 2>&1
if [ -n "$_TIMEOUT_BIN" ]; then
    printf '#!/usr/bin/env bash\necho partial\nsleep 10\n' > "$tmp/az-hang.sh"
    out90d="$(console new --bucket az90hang)"
    rc90=0
    ACTION_ZERO_SCRIPT="$tmp/az-hang.sh" ACTION_ZERO_SECS=1 console next --bucket az90hang >/dev/null 2>&1 || rc90=$?
    check "90 a hung action-zero does not stop next" "$rc90" "0"
    check "90 a hung action-zero is cut at ACTION_ZERO_SECS and marked unavailable" \
        "$(grep -c '^unavailable (action-zero.sh exited 124): run it yourself$' "$root/tester/az90hang/DEMO-nextleg-${today}B-console.md")" "1"
    HANDOVER_DIR="$root" bash "$QL" release "$root/tester/az90hang/DEMO-nextleg-${today}A-console.md" "$(token_of "$out90d")" >/dev/null 2>&1
else
    echo "ok - SKIPPED: 90 hung action-zero: no timeout or gtimeout on this host"
fi

# --- 91. next refuses a succession that drops an operator ruling or the direction
# A Results bullet `OPERATOR ... (verbatim): "<quote>"` must have its quote on the
# outgoing `decisions:` line or in a decisions file that line names (exit 6); the
# doc's `## Current direction` block must be real (exit 7). A placeholder left in
# the HANDOFF facts header is reported. The bullet is shaped like a real one from
# the AB console doc; the header lines are the DF HANDOFF's own.
q91='move the 1.1.4 in progress to todo, as versions that aren'"'"'t released are never not in todo.'
b91="- 23:37 AB 00:5x: DECISION (46) OPERATOR 10-19 AB (verbatim): '$q91' Apply: only the active version holds started."
dir91='Chain order: 0 CI blocker, then 1 audit tickets. In work: N3296. Waits on the operator: the v1.1.3 tag.'
# mk91 <bucket> <decisions line> <Results bullet|-> <direction body|ABSENT>
mk91() {
    local d="$root/tester/$1"
    mkdir -p "$d"
    {
        printf '# B — CONSOLE — successor to none (fill signal 70 %%)\n\n## Live state\ndecisions: %s\n\n' "$2"
        [ "$4" = ABSENT ] || printf '## Current direction\n\n%s\n\n' "$4"
        printf '## Results\n'
        [ "$3" = "-" ] || printf '%s\n' "$3"
    } > "$d/DEMO-nextleg-${today}B-console.md"
}
run91() { rc91=0; out91="$(console next --bucket "$1" --doc "$root/tester/$1/DEMO-nextleg-${today}B-console.md" 2>&1)" || rc91=$?; }
mk91 rul91a "(46) other ruling" "$b91" "$dir91"; run91 rul91a
check "91 a verbatim OPERATOR quote missing from decisions: refuses (exit 6)" "$rc91" "6"
check "91 refusal names the missing ruling" "$(printf '%s\n' "$out91" | grep -cF "$q91")" "1"
check "91 refusal writes no HANDOFF" "$([ -f "$root/tester/rul91a/DEMO-nextleg-${today}B-console-HANDOFF.md" ] && echo yes || echo no)" "no"
mk91 rul91b "(46) $q91" "$b91" "$dir91"; run91 rul91b
check "91 the quote on the decisions: line passes" "$rc91" "0"
mk91 rul91c "specs/decisions/console-decisions-2026-10-19.md holds #46" "$b91" "$dir91"
mkdir -p "$root/tester/rul91c/specs/decisions"; printf '(46) %s\n' "$q91" > "$root/tester/rul91c/specs/decisions/console-decisions-2026-10-19.md"; run91 rul91c
check "91 the quote in a named decisions file passes" "$rc91" "0"
mk91 rul91d "(46) other ruling" "- 10:00 OPERATOR ran the post-3203 steps: himmel-update (no quoted ruling)" "$dir91"; run91 rul91d
check "91 a bullet with no (verbatim) quote is not a ruling" "$rc91" "0"
mk91 dir91a "(46) other ruling" "-" ""; run91 dir91a
check "91 an empty Current direction block refuses (exit 7)" "$rc91" "7"
check "91 refusal names the block" "$(printf '%s\n' "$out91" | grep -cF 'Current direction')" "1"
mk91 dir91b "(46) other ruling" "-" "<chain order; what is in work; what waits on the operator>"; run91 dir91b
check "91 a placeholder Current direction block refuses (exit 7)" "$rc91" "7"
mk91 dir91c "(46) other ruling" "-" ABSENT; run91 dir91c
check "91 a doc with no Current direction block refuses (exit 7)" "$rc91" "7"
mk91 dir91d "(46) other ruling" "-" "$dir91"; printf '[{"name":"0 — CI blocker","steps":[]},{"name":"1 — audit tickets","steps":[]}]\n' > "$root/tester/dir91d/focus-chains.json"; run91 dir91d
h91="$root/tester/dir91d/DEMO-nextleg-${today}B-console-HANDOFF.md"
check "91 a real block passes" "$rc91" "0"
check "91 the HANDOFF carries the outgoing direction block" "$(sed -n '/^## Current direction$/,/^## [^C]/p' "$h91" | grep -cF "$dir91")" "1"
check "91 the HANDOFF direction block lists the chain order from focus-chains.json" "$(sed -n '/^## Current direction$/,/^## [^C]/p' "$h91" | grep -cF 'Chain order (focus-chains.json): 0 — CI blocker; 1 — audit tickets')" "1"
check "91 the successor doc carries the direction block" "$(sed -n '/^## Current direction$/,/^## [^C]/p' "$root/tester/dir91d/DEMO-nextleg-${today}C-console.md" | grep -cF "$dir91")" "1"
check "91 a fresh HANDOFF reports its facts-header placeholders" "$(printf '%s\n' "$out91" | grep -c 'HANDOFF still has template placeholders')" "1"
mk91 hdr91 "(46) other ruling" "-" "$dir91"
cat > "$root/tester/hdr91/DEMO-nextleg-${today}B-console-HANDOFF.md" <<'HDR'
# DF → DG handoff state

> **This file wins over the DF Results tail**; use that tail
> only where a section here is empty.

**Head:** `e40b42b195b58c7ec4c0c06a676ed29e0115f7cb` on `main` at `/example/himmel`, remote `https://github.com/example/himmel.git`.
**Bank at write:** unavailable — run usage-preflight.sh
**Operator:** `<at the station / away / asleep>`.

## How DG starts

Run ACTION ZERO from `HIMMEL-nextleg-2026-10-22DG-roadmap-console.md` unchanged; expect at the root sweep
`<the locks the successor should find>`. Kit: `/example/himmel/scripts/handover/console-kit`.
HDR
run91 hdr91
check "91 an existing HANDOFF with a placeholder Operator line is reported" "$(printf '%s\n' "$out91" | grep -cF '**Operator:** `<at the station')" "1"
# shellcheck disable=SC2016  # the backticks are literal markdown code spans
check "91 an existing HANDOFF with a placeholder root-sweep line is reported" "$(printf '%s\n' "$out91" | grep -cF '`<the locks the successor should find>`')" "1"
mk91 hdr91b "(46) other ruling" "-" "$dir91"
printf '%s\n' '**Operator:** at the station.' > "$root/tester/hdr91b/DEMO-nextleg-${today}B-console-HANDOFF.md"; run91 hdr91b
check "91 a filled existing HANDOFF is not reported" "$(printf '%s\n' "$out91" | grep -c 'template placeholders')" "0"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
