#!/usr/bin/env bash
# scripts/handover/console/chief.sh — start or hand over a console session
#
# A console is a long-running headed Claude session that holds a queue lock
# on its own handover document, runs monitors, dispatches implementation
# legs, acts on the rulings on their questions, merges on GO, and arms its own
# successor when its context fills. This script packages what an operator used to do
# by hand:
#   chief.sh new  — write the console doc + acquire its queue lock, print
#                     the launch line.
#   chief.sh next — write the successor's doc stub, write the predecessor's
#                     HANDOFF skeleton, print the launch line.
#   chief.sh wrap — the predecessor's WRAPPED + lock release, refused while
#                     it has live subagents.
#
# Env seams: HANDOVER_DIR / USER_SLUG / JIRA_PROJECT_KEY (via .env, see
# load-dotenv.sh); CHIEF_BUCKET, CHIEF_DOC, CHIEF_MODEL,
# CHIEF_FILL_PERCENT, CHIEF_TEMPLATE_DIR, CHIEF_WORK_DIR (default:
# $XDG_RUNTIME_DIR/himmel-console when set and owned by this uid, else
# ${TMPDIR:-/tmp}/himmel-console-<uid>; an override is validated the same as
# the default — see below), CHIEF_HEADED_ARM, ACTION_ZERO_SCRIPT (the
# action-zero.sh that `next` pre-computes into the successor doc),
# ACTION_ZERO_SECS (its bound, default 300),
# CHIEF_ARM_FOREGROUND (test seam: run the arm in the foreground instead of
# detaching it).
# Each CHIEF_* env seam above, and CHIEF_CONTEXT and CHIEF_BUS_*, still reads
# its old name, CONSOLE_*.
# Flag seams: --name (both commands; on next it selects which console
# succession to continue) --arm --dry-run --model --bucket --prefix --project
# --deadline-min --doc
# --project (both commands; plugin /console from any repo -- points at a repo
# that is NOT this himmel checkout, e.g. run from ~/Websites: bucket/prefix
# derive from it instead of himmel's own repo basename/JIRA_PROJECT_KEY, and
# an --arm session opens there, not in himmel)
# --date (next only; overrides the day used for the SUCCESSOR's own name --
# letting a 23:5x console pre-mint tomorrow's A without
# waiting for midnight; passing --date always starts that day's succession at A,
# while omitting it continues the predecessor's own bijective sequence (Z ->
# AA -> ... -> ZZ) regardless of whether the calendar day rolled over since).
# See `-h`/`--help` for the full surface.
#
# Exit codes: 0 ok; 1 usage/state error (letters A-Z, AA-ZZ exhausted (past
# ZZ), no predecessor found, an unresolved {{PLACEHOLDER}} survived a
# render); 2 unresolved handover root / user slug / a missing template file
# / no sha256 hasher available to derive the per-chain digest
# / a malformed --date value; 3
# the work dir (default or CHIEF_WORK_DIR) exists but is a symlink, is not
# owned by this user, is group/other-writable, or could not be created; 4 `wrap` refused: this session has a live in-process
# subagent, or live-subagents.sh could not prove it has none; 5 `wrap` refused:
# this session has a live non-harness process (wrap-subtree-check.sh WITHHELD),
# other than its own console-wait.sh waiter, or that check could not run;
# 6 `next` refused: a Results bullet quotes an operator ruling (verbatim) that
# the decisions: line does not hold; 7 `next` refused: the outgoing doc has no
# real `## Current direction` block.
#
# Platform guard (gitbash-only): POSIX bash 3.2+; --arm launches through
# konsole (Linux/KDE, via headed-arm.sh), so no .ps1 twin — the Windows
# station arms via scripts/handover/arm-resume.sh's schtasks backend.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/leg-tail-status.sh
. "$HERE/../../lib/leg-tail-status.sh"

# The launch line below is PASTED by an operator, and the terminal
# they paste it into was itself spawned from a claude session -- so
# CLAUDE_CODE_CHILD_SESSION=1, CLAUDE_PID and CLAUDE_CODE_SESSION_ID are live in
# that shell. A console that adopts them writes no transcript and cannot read
# its own context fill, which is the signal its handover contract runs on.
# headed-arm.sh scrubs these on the --arm path; the printed line
# was missed, so an un-armed console silently became a throwaway child session.
# Keep this identical to headed-arm.sh's env prefix.
CHIEF_LAUNCH_ENV="env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1"
# shellcheck source=../../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/load-dotenv.sh"
# shellcheck source=../../lib/user-slug.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/user-slug.sh"
# shellcheck source=../../lib/handover-path.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/handover-path.sh"
. "$HERE/../../lib/chief-context.sh"
# shellcheck source=../../lib/env-alias.sh
. "$HERE/../../lib/env-alias.sh"
for _chief_seam in ARM_FOREGROUND BUCKET BUS_CLI BUS_PROFILES_MJS CONTEXT DOC \
    FILL_PERCENT HEADED_ARM MODEL TEMPLATE_DIR WORK_DIR; do
    alias_env "CHIEF_$_chief_seam" "CONSOLE_$_chief_seam"
done
# shellcheck source=../../lib/claude-version.sh
. "$HERE/../../lib/claude-version.sh"
# shellcheck source=../../lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh"
# Pin to this script's OWN checkout, never the caller's CWD repo
# (load_dotenv with no --root resolves via the process CWD's git repo — see
# bank-preflight.sh for the failure mode).
load_dotenv --root "$(_load_dotenv_primary_for "$HERE/../../..")" HANDOVER_DIR USER_SLUG JIRA_PROJECT_KEY

ALPHABET="ABCDEFGHIJKLMNOPQRSTUVWXYZ"

usage() {
    cat <<'USAGE'
usage: chief.sh new  [--name <slug>] [--arm] [--dry-run] [--model <m>]
                       [--bucket <b>] [--prefix <P>] [--project <dir>]
                       [--deadline-min <n>] [--context <1m|standard>]
       chief.sh next [--doc <path>] [--date <YYYY-MM-DD>] [--name <slug>]
                       [--arm] [--dry-run] [--model <m>] [--bucket <b>]
                       [--prefix <P>] [--project <dir>] [--deadline-min <n>]
                       [--context <1m|standard>] [--relay-on-live]
       chief.sh wrap <console-doc> <release-token> [<text>]
       chief.sh -h|--help

wrap (the predecessor's last step, run from its own session) writes the
WRAPPED bullet and releases the lock, and refuses (exit 4, nothing written)
while this session has a live in-process subagent (HIMMEL-5071).

Supervisor sessions (consoles) default to 1m. --context overrides CHIEF_CONTEXT and the default;
--context standard or CHIEF_CONTEXT=standard opts down to 200000.

--relay-on-live (next only) leaves a marker beside the outgoing console's inbox; its
console-wait.sh waiter then wakes the outgoing console ONCE, when the successor holds
its queue lock, with relay-batch.sh's SENDMESSAGE lines, so the outgoing console need
not ask before relaying. It sends nothing itself. A console with a bus identity
(HIMMEL_BUS_NAME) gets the marker without the flag.
--name on next selects which supervisor-session succession to continue; defaults to the name
implied by --doc's own basename when --doc is given and --name is not,
else "console".
--date on next overrides the day used for the successor's own name and
starts that day's succession at letter A; without --date the successor
continues the predecessor's own bijective letter sequence (rolling past Z
into AA, AB, ... as needed) regardless of whether the calendar day has
rolled over since.
--project points chief.sh at a repo that is NOT this himmel checkout
(plugin /console from any repo); bucket/prefix derive from it instead of
himmel's own repo basename/JIRA_PROJECT_KEY. The console session itself
always stays in this himmel checkout -- --project is recorded as data in
the console doc, and a worker session (leg) for the project is dispatched into it explicitly
with WORKER_SESSION_REPO=<path> (codex-4, pr-check round 2, HIMMEL-3623).
--bucket/--prefix still override it when given.
USAGE
}

err() { echo "console: $*" >&2; }

# slugify <value> -- lowercase, non-alnum runs -> '-', trim leading/trailing
# '-'. Mirrors user-slug.sh's _user_slug_slugify (bucket-name convention).
slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# resolve_repo -- the primary checkout root (parent of the shared git-common
# dir), which resolves correctly from a plain checkout OR a linked worktree.
# Anchored on THIS script's own location ($HERE), never the cwd: the plugin
# /console runs it with the cwd in a FOREIGN repo, and the template, kit and
# queue-lock.sh below must be himmel's, not that repo's.
resolve_repo() {
    local common
    if common="$(git_clean -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
        (cd "$(dirname "$common")" && pwd)
        return 0
    fi
    (cd "$HERE/../../.." && pwd)
}

# next_letter <A-Z or AA-ZZ> -- bijective base-26 successor: A..Y -> next
# letter, Z -> AA (same-day rollover past Z), AA..AY -> next
# second letter, AZ -> BA, ..., YZ -> ZA. Fails (rc=1, no stdout) at ZZ, the
# cap -- a third letter is out of scope.
next_letter() {
    local cur="$1"
    [ "$cur" = "ZZ" ] && return 1
    if [ "${#cur}" -eq 1 ]; then
        if [ "$cur" = "Z" ]; then
            printf '%s' "AA"
            return 0
        fi
        local before="${ALPHABET%%"$cur"*}"
        printf '%s' "${ALPHABET:$((${#before} + 1)):1}"
        return 0
    fi
    local first="${cur:0:1}" second="${cur:1:1}" before
    if [ "$second" = "Z" ]; then
        before="${ALPHABET%%"$first"*}"
        printf '%s' "${ALPHABET:$((${#before} + 1)):1}A"
    else
        before="${ALPHABET%%"$second"*}"
        printf '%s' "$first${ALPHABET:$((${#before} + 1)):1}"
    fi
}

# letter_value <A-Z or AA-ZZ> -- numeric rank (A=1 .. Z=26, AA=27 .. ZZ=702).
# Lexical string comparison puts "AA" before "B" even though AA is the
# LATER letter -- anywhere the code needs the "highest" letter, compare
# this value, never the raw string.
letter_value() {
    local s="$1" p
    if [ "${#s}" -eq 1 ]; then
        p="${ALPHABET%%"$s"*}"
        printf '%s' $(( ${#p} + 1 ))
        return 0
    fi
    local a="${s:0:1}" b="${s:1:1}" pa pb
    pa="${ALPHABET%%"$a"*}"
    pb="${ALPHABET%%"$b"*}"
    printf '%s' $(( 26 + ${#pa} * 26 + ${#pb} + 1 ))
}

# render_template <template> <out> KEY VALUE [KEY VALUE ...] -- literal
# {{KEY}} -> VALUE substitution over the whole file (bash parameter
# expansion, not sed s///, so a VALUE containing '/' — every path here —
# never needs escaping). Fails loudly, naming the placeholder, if any
# {{...}} survives in the written output.
render_template() {
    local template="$1" out="$2" leftover n=0
    shift 2
    # One awk pass, literal index()/substr() replacement; the pairs travel in
    # the environment so no value needs escaping ('/', '&', backslash). NOT
    # bash ${var//pat/rep}: bash 3.2 (macOS /bin/bash) is quadratic on this
    # 34 KB UTF-8 template (~60 s per render, 604 s across test-console.sh),
    # it keeps a quoted replacement's inner quotes literal, and bash 5.2+
    # patsub treats '&' in the replacement as the match.
    while [ "$#" -gt 0 ]; do
        export "RT_K$n=$1" "RT_V$n=$2"
        n=$((n + 1))
        shift 2
    done
    RT_N=$n awk '
        BEGIN { n = ENVIRON["RT_N"] + 0 }
        {
            line = $0
            for (i = 0; i < n; i++) {
                key = "{{" ENVIRON["RT_K" i] "}}"; val = ENVIRON["RT_V" i]
                res = ""
                while ((p = index(line, key)) > 0) {
                    res = res substr(line, 1, p - 1) val
                    line = substr(line, p + length(key))
                }
                line = res line
            }
            print line
        }' "$template" > "$out" || { rm -f "$out"; err "render failed for $template"; exit 1; }
    leftover="$(grep -oE '\{\{[A-Za-z_]+\}\}' "$out" 2>/dev/null | sort -u | head -n 1)" || leftover=""
    if [ -n "$leftover" ]; then
        rm -f "$out"
        err "unresolved placeholder $leftover in $template"
        exit 1
    fi
}

# find_free_letter -- first free letter (bijective base-26: A..Z, AA..ZZ)
# with no existing doc for today+name. Fails (rc=1) past ZZ, the cap.
find_free_letter() {
    local l="A"
    while :; do
        [ -e "$state_dir/${prefix}-nextleg-${date}${l}-${name}.md" ] || { printf '%s' "$l"; return 0; }
        l="$(next_letter "$l")" || return 1
    done
}

# Discovery metadata for /consoles. Best-effort; no Telegram message is sent
# until the new or successor console actually arms its waiter.
console_metadata() {
    command -v bun >/dev/null 2>&1 || return 0
    bun "$repo/scripts/telegram/console-route.ts" register "$1" "$bucket" "${project_dir:-$repo}" >/dev/null 2>&1 || true
}

# Set by cmd_next to the outgoing console's session name; assigned
# here so an ambient value can never name a predecessor.
CHIEF_BUS_PREDECESSOR=""

# console_bus_opted_in -- the console profile lists himmel-bus in its MCP servers.
# Returns 0 opted in, 1 not opted in, 2 the profile probe itself failed (its
# output is left in bus_probe_out): a broken probe is not an opt-out.
bus_probe_out=""
console_bus_opted_in() {
    local bus_names
    bus_probe_out=""
    bus_names="$(node "${CHIEF_BUS_PROFILES_MJS:-$HERE/../../lanes/plugin-profiles.mjs}" console --mcp-servers 2>&1)" || { bus_probe_out="$bus_names"; return 2; }
    case "$bus_names" in
        *'"himmel-bus"'*) return 0 ;;
    esac
    return 1
}

# bus_warn <log> <text> -- a bus-chain problem goes to stderr AND the launch log,
# which is the only place the operator looks after the console has detached.
bus_warn() {
    echo "chief.sh: WARN $2" >&2
    printf '%s WARN: %s\n' "$(date +%F_%T)" "$(printf '%s' "$2" | tr '\n' ' ')" >> "$1"
}

# bus_note <log> <text> -- a bus-chain step that worked, in the launch log.
bus_note() {
    printf '%s bus: %s\n' "$(date +%F_%T)" "$2" >> "$1"
}

# do_arm <session> <doc> <fill-signal> <log> -- launch (or foreground-run,
# under CHIEF_ARM_FOREGROUND=1) the headed-arm target and print the armed
# lines. deadline_epoch/model/workdir are read from the outer resolution
# (constant for the whole invocation), not passed positionally.
do_arm() {
    local session="$1" doc="$2" fill_signal="$3" log="$4" arm
    # CONSOLE_ROLE is retired (its only working value was the
    # implicit default; a relay is a leg, armed via headed-arm-leg.sh --relay,
    # never through this console path). A console is what chief.sh arms, so
    # nothing is forwarded to headed-arm.sh's --role; a stale CONSOLE_ROLE in
    # the environment is ignored.
    mkdir -p "$(dirname "$log")"
    arm="${CHIEF_HEADED_ARM:-$HERE/../headed-arm.sh}"
    # This process itself may BE a leg (chief.sh next --arm run
    # from inside one) -- a leg's own profile/launcher env stays live in its
    # shell for its whole session (see console_context_leg_env_unset_names),
    # and headed-arm.sh would otherwise resolve its ${HEADED_ARM_*:-default}
    # fallbacks and leg-profile vars from that leaked env. Scrub the whole
    # canonical set from THIS process's own environment before the launch
    # lines below run, so a fresh console always arms clean regardless of
    # what launched the process running this script -- do_arm is always the
    # last thing its caller does (end of cmd_new / cmd_next, script exits
    # right after), so nothing downstream in this process needs them back.
    local -a leg_env_names=()
    local leg_env_name
    for leg_env_name in $(console_context_leg_env_unset_names); do
        leg_env_names+=("$leg_env_name")
    done
    unset "${leg_env_names[@]}"
    # The console's bus identity is registered here,
    # by its launcher, and bound by headed-arm.sh once it confirms the claude
    # pid. Whatever HIMMEL_BUS_* this process carries (a predecessor console's
    # own HIMMEL_BUS_NAME is live in its shell) never reaches the successor, and
    # the console profile's opt-in decides whether anything is registered.
    # Fail-open: a failed register warns and the console launches unbound.
    local bus_var bus_cli bus_args
    for bus_var in $(compgen -v HIMMEL_BUS_); do unset "$bus_var"; done
    unset HEADED_ARM_BUS HEADED_ARM_BUS_CLI
    bus_cli="${CHIEF_BUS_CLI:-$HERE/../../../marketplace/plugins/himmel-bus/bin/bus}"
    local bus_opt=0 bus_stamp=""
    console_bus_opted_in || bus_opt=$?
    if [ "$bus_opt" -eq 2 ]; then
        bus_warn "$log" "bus profile probe failed for $session - launching unbound: $bus_probe_out"
    elif [ "$bus_opt" -eq 0 ]; then
        bus_args=(register "$session" --role console)
        [ -n "$CHIEF_BUS_PREDECESSOR" ] && bus_args+=(--predecessor "$CHIEF_BUS_PREDECESSOR")
        if bus_out="$("$bus_cli" "${bus_args[@]}" 2>&1)"; then
            export HIMMEL_BUS_NAME="$session" HEADED_ARM_BUS=1 HEADED_ARM_BUS_CLI="$bus_cli"
            # Still the outgoing console here (identity is process ancestry):
            # stamp the successor so each leg's adopt passes while this one is live.
            if [ -n "$CHIEF_BUS_PREDECESSOR" ]; then
                if bus_out="$("$bus_cli" succeed "$session" 2>&1)"; then
                    bus_stamp=", stamped successor of $CHIEF_BUS_PREDECESSOR"
                else
                    bus_warn "$log" "bus succeed failed for $session - legs adopt only once $CHIEF_BUS_PREDECESSOR is gone: $bus_out"
                fi
            fi
            bus_note "$log" "registered $session as console$bus_stamp"
        else
            bus_warn "$log" "bus register failed for $session - launching unbound: $bus_out"
        fi
    fi
    # plugin /console from any repo: a
    # foreign --project selects the bucket/prefix and is recorded in the
    # doc as data (see project_doc_value below) -- the console session
    # itself ALWAYS opens in the himmel checkout, never HEADED_ARM_REPO'd
    # into the project. Himmel's own project-scoped hooks (the GO-file merge
    # gate, block-leg-askuserquestion) and the console-kit's relative paths
    # only load there. Legs for the project are dispatched into it
    # explicitly with WORKER_SESSION_REPO=<project> (headed-arm-leg.sh), never by the
    # console inheriting a repo override.
    if [ "$CONTEXT_GIVEN" -eq 1 ]; then
        export CHIEF_CONTEXT="$CHIEF_CONTEXT_RESOLVED_MODE"
    fi
    if [ "${CHIEF_ARM_FOREGROUND:-0}" = "1" ]; then
        bash "$arm" --role console "$session" "$doc" "$fill_signal" "$deadline_epoch" "$log" "$model"
    elif command -v setsid >/dev/null 2>&1; then
        setsid nohup bash "$arm" --role console "$session" "$doc" "$fill_signal" "$deadline_epoch" "$log" "$model" >/dev/null 2>&1 &
    else
        nohup bash "$arm" --role console "$session" "$doc" "$fill_signal" "$deadline_epoch" "$log" "$model" >/dev/null 2>&1 &
    fi
    echo "armed: name=$session doc=$doc signal=$fill_signal deadline=$deadline_epoch log=$log"
    echo "arm-log: $log"
}

# The predecessor's wrap. A console run inside its own session
# ($CLAUDE_CODE_SESSION_ID) writes WRAPPED and releases its lock only when
# live-subagents.sh proves it has no in-process subagent still running (a judge
# call whose verdict would otherwise die with the session); a live child, or no
# way to tell, refuses with exit 4 and writes nothing.
# ponytail: a console can still hand-write WRAPPED with append-results.sh and
# release by hand; close-wrapped-leg.sh's exit 7 is the backstop that refuses to
# TERM it then, so the child is never killed. Gate append-results.sh itself if
# that path is seen in use.
#
# Same for a non-harness process (a CI watcher, a suite run, a Monitor): the
# session's own wrap-subtree-check.sh must find none, or wrap refuses with exit 5
# naming each one. The console's own console-wait.sh waiter (and what it forked)
# is the one exemption: it is stopped here, and only after nothing else blocks.
wrap_subtree_gate() {
    local sub src=0 plan kills blocks pid subs sp cmd now
    sub=$(bash "${WRAP_SUBTREE_CHECK_BIN:-$HERE/../wrap-subtree-check.sh}" 2>&1) || src=$?
    [ "$src" -ne 0 ] || return 0
    if [ "$src" -ne 1 ]; then
        printf '%s\n' "$sub" >&2
        err "wrap refused: cannot prove this session has no live processes (above) - run it from the console's own session"
        exit 5
    fi
    plan=$(printf '%s\n' "$sub" | awk '
        /^  pid=/ { n++; for (i = 1; i <= NF; i++) { split($i, kv, "="); if (kv[1] == "pid") p = kv[2]; if (kv[1] == "ppid") q = kv[2] }
                    pid[n] = p; par[n] = q; row[n] = $0 }
        function wrapper(r) { return r ~ /cmd=[^ ]*(bash|zsh|sh) -c (source|\.) [^ ]*shell-snapshots\/snapshot-/ }
        END {
            for (a = 1; a <= n; a++) if (row[a] ~ /cmd=([^ ]*\/)?(bash|sh|zsh) ([^ ]*\/)?console-wait\.sh( |$)/) { ex[pid[a]] = 1; w[pid[a]] = 1 }
            for (pass = 0; pass < 8; pass++) for (a = 1; a <= n; a++) {
                if (par[a] in ex) ex[pid[a]] = 1
                if (wrapper(row[a])) {
                    kids = 0; bad = 0
                    for (b = 1; b <= n; b++) if (par[b] == pid[a]) { kids++; if (!(pid[b] in ex)) bad++ }
                    if (kids > 0 && !bad) ex[pid[a]] = 1
                }
            }
            for (a = 1; a <= n; a++) if (pid[a] in w) dep[pid[a]] = 0
            for (pass = 0; pass < 8; pass++) for (a = 1; a <= n; a++) if ((par[a] in dep) && !(pid[a] in dep)) dep[pid[a]] = dep[par[a]] + 1
            for (a = 1; a <= n; a++) { if (pid[a] in w) print "KILL " pid[a]; else if (pid[a] in dep) { c = row[a]; sub(/^.*cmd=/, "", c); print "SUB " dep[pid[a]] " " pid[a] " " c } else if (!(pid[a] in ex)) print "BLOCK " row[a] }
        }')
    blocks=$(printf '%s\n' "$plan" | sed -n 's/^BLOCK //p')
    kills=$(printf '%s\n' "$plan" | sed -n 's/^KILL //p')
    subs=$(printf '%s\n' "$plan" | sed -n 's/^SUB //p' | sort -rn)
    if [ -n "$blocks" ] || [ -z "$kills" ]; then
        printf '%s\n' "$sub" >&2
        err "wrap refused: this session has live non-harness processes (above) - stop them or let them finish, then re-run"
        exit 5
    fi
    for pid in $kills; do
        # a recycled pid must not be TERMed: only a live console-wait.sh process is
        if ps -o args= -p "$pid" 2>/dev/null | grep -Eq '^([^ ]*/)?(bash|sh|zsh) ([^ ]*/)?console-wait\.sh( |$)'; then
            # its whole subtree first, deepest-first, each pid confirmed gone, so
            # no descendant outlives it as an orphan the re-check below can no
            # longer see
            while read -r _ sp cmd; do
                # a gone pid is skipped; a live one whose argv no longer matches its
                # snapshot row (reused pid, or an exec) is never signalled, and the
                # wrap is refused with the waiter left running
                now=$(ps -o args= -p "$sp" 2>/dev/null) || now=""
                [ -n "$now" ] || continue
                # an empty snapshot cmd would match any live process at that pid
                case "$now" in "$cmd"*) [ -n "$cmd" ] || { err "wrap refused: descendant $sp of the console-wait waiter has no recorded command - waiter left running, re-run"; exit 5; } ;; *)
                    err "wrap refused: descendant $sp of the console-wait waiter changed since the check (now: $now) - waiter left running, re-run"
                    exit 5 ;;
                esac
                kill -TERM "$sp" 2>/dev/null || true
                for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$sp" 2>/dev/null || break; sleep 0.2; done
                if kill -0 "$sp" 2>/dev/null; then
                    kill -KILL "$sp" 2>/dev/null || true
                    sleep 0.2
                fi
                if kill -0 "$sp" 2>/dev/null; then
                    err "wrap refused: descendant $sp of the console-wait waiter survived TERM and KILL - waiter left running, re-run once it exits"
                    exit 5
                fi
            done <<EOS
$subs
EOS
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        src=0; sub=$(bash "${WRAP_SUBTREE_CHECK_BIN:-$HERE/../wrap-subtree-check.sh}" 2>&1) || src=$?
        [ "$src" -ne 0 ] || return 0
        sleep 0.5
    done
    printf '%s\n' "$sub" >&2
    err "wrap refused: processes are still alive after stopping the console-wait waiter (above) - re-run once they exit"
    exit 5
}

cmd_wrap() {
    if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
        echo "usage: chief.sh wrap <console-doc> <release-token> [<text>]" >&2
        exit 1
    fi
    local doc="$1" token="$2" text="${3:-handed over}" out rc=0
    out=$(bash "${LIVE_SUBAGENTS_BIN:-$HERE/../console-kit/live-subagents.sh}" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$out" >&2
        if [ "$rc" -eq 1 ]; then
            err "wrap refused: this session has live subagents (above) - wait for their results, then re-run"
        else
            err "wrap refused: cannot prove this session has no live subagents (above) - run it from the console's own session"
        fi
        exit 4
    fi
    # prove the token first (heartbeat refuses a wrong one and changes nothing),
    # so neither a wrong token nor a failed append leaves a half-done wrap, and
    # the gate below never stops the waiter for a wrap that will be refused
    bash "$HERE/../queue-lock.sh" heartbeat "$doc" "$token" >/dev/null || exit 1
    wrap_subtree_gate
    bash "$HERE/../console-kit/append-results.sh" "$doc" "WRAPPED — $text" || exit 1
    bash "$HERE/../queue-lock.sh" release "$doc" "$token" || exit 1
}

# The HANDOFF's open-judge-calls fact: this session's running
# subagents when `next` runs. Fails open to a note, like handoff-facts.sh.
judge_calls_now() {
    local out rc=0
    out=$(bash "$HERE/../console-kit/live-subagents.sh" 2>&1) || rc=$?
    case "$rc" in
        0) echo "none running" ;;
        1) printf '%s\n' "$out" | sed -n 's/^LIVE-SUBAGENT /- /p' ;;
        *) echo "unavailable ($(printf '%s\n' "$out" | head -n 1))" ;;
    esac
}

# The HANDOFF's "Wrapped with open PR" section: every fleet-manifest leg
# whose last marker is WRAPPED and whose doc still names a PR that is open, so
# the successor cannot drop it when the carry-forward is hand-written prose.
# ponytail: the PR is read off the leg doc's own text (READY/PR/# followed by a number),
# so a wrap that never names its PR is invisible here; the tick's unowned-prs= still
# catches it. Open set = handoff-facts.sh prs, so it shares that field's seam and limit.
wrapped_open_prs_section() { # <predecessor doc>
    local doc="$1" manifest="${1%.md}.fleet.json" facts="$HERE/../console-kit/handoff-facts.sh"
    local open rows label ldoc n found=0 mtime lookup_failed=""
    printf '## Wrapped with open PR\n\n'
    printf 'The successor dispositions each entry below (relaunch, GO or close) BEFORE its first dispatch.\n\n'
    open="$(bash "$facts" prs "$doc" --repo "$repo" 2>/dev/null | sed -n 's/^#\([0-9][0-9]*\) .*/\1/p')" || { open=""; lookup_failed=1; }
    if [ -f "$manifest" ] && [ -n "$open" ] && rows="$(jq -r '.legs[] | "\(.label)\t\(.doc)"' "$manifest" 2>/dev/null)"; then
        while IFS="$(printf '\t')" read -r label ldoc; do
            [ -f "$ldoc" ] || continue
            [ "$(leg_tail_status "$ldoc")" = WRAPPED ] || continue
            # shellcheck disable=SC2013 # the words are bare digits
            for n in $(grep -oE '(READY|PR|#)[ #]*[0-9]+' "$ldoc" | grep -oE '[0-9]+$' | sort -u); do
                printf '%s\n' "$open" | grep -qx "$n" || continue
                mtime="$(date -r "$ldoc" '+%Y-%m-%d %H:%M' 2>/dev/null)" || mtime="unknown"
                printf -- '- PR #%s (%s), orphan since %s: %s\n' "$n" "$label" "$mtime" "$ldoc"
                found=1
            done
        done <<EOF_ROWS
$rows
EOF_ROWS
    fi
    if [ -n "$lookup_failed" ]; then
        printf 'unknown — the open-PR lookup failed, so check the open PRs against the WRAPPED legs by hand.\n'
    elif [ "$found" -ne 1 ]; then
        printf 'none — no WRAPPED leg in the fleet manifest names a PR that is still open.\n'
    fi
}

CMD="${1:-}"
case "$CMD" in
    -h|--help) usage; exit 0 ;;
    wrap) shift; cmd_wrap "$@"; exit 0 ;;
    new|next) shift ;;
    "") usage >&2; exit 1 ;;
    *) err "unknown command: $CMD"; usage >&2; exit 1 ;;
esac

NAME="console"
NAME_GIVEN=0
ARM=0
RELAY_ON_LIVE=0
DRY_RUN=0
MODEL=""
CONTEXT=""
CONTEXT_GIVEN=0
BUCKET=""
PREFIX=""
PROJECT_ARG=""
DEADLINE_MIN=480
DOC_ARG=""
DATE_ARG=""
DATE_GIVEN=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --name)
            [ "$#" -ge 2 ] || { usage >&2; exit 1; }
            NAME="$2"; NAME_GIVEN=1; shift 2 ;;
        --name=*)
            NAME="${1#--name=}"; NAME_GIVEN=1; shift ;;
        --doc)
            [ "$CMD" = next ] || { err "--doc is only valid for 'next'"; usage >&2; exit 1; }
            [ "$#" -ge 2 ] || { usage >&2; exit 1; }
            DOC_ARG="$2"; shift 2 ;;
        --doc=*)
            [ "$CMD" = next ] || { err "--doc is only valid for 'next'"; usage >&2; exit 1; }
            DOC_ARG="${1#--doc=}"; shift ;;
        --date)
            [ "$CMD" = next ] || { err "--date is only valid for 'next'"; usage >&2; exit 1; }
            [ "$#" -ge 2 ] || { usage >&2; exit 1; }
            DATE_ARG="$2"; DATE_GIVEN=1; shift 2 ;;
        --date=*)
            [ "$CMD" = next ] || { err "--date is only valid for 'next'"; usage >&2; exit 1; }
            DATE_ARG="${1#--date=}"; DATE_GIVEN=1; shift ;;
        --arm) ARM=1; shift ;;
        --relay-on-live)
            [ "$CMD" = next ] || { err "--relay-on-live is only valid for 'next'"; usage >&2; exit 1; }
            RELAY_ON_LIVE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --model) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; MODEL="$2"; shift 2 ;;
        --model=*) MODEL="${1#--model=}"; shift ;;
        --context)
            if [ "$#" -lt 2 ] || ! console_context_valid "$2"; then
                err "--context must be 1m or standard"; exit 2
            fi
            CONTEXT="$2"; CONTEXT_GIVEN=1; shift 2 ;;
        --context=*)
            CONTEXT="${1#--context=}"
            console_context_valid "$CONTEXT" || { err "--context must be 1m or standard"; exit 2; }
            CONTEXT_GIVEN=1; shift ;;
        --bucket) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; BUCKET="$2"; shift 2 ;;
        --bucket=*) BUCKET="${1#--bucket=}"; shift ;;
        --prefix) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; PREFIX="$2"; shift 2 ;;
        --prefix=*) PREFIX="${1#--prefix=}"; shift ;;
        --project) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; PROJECT_ARG="$2"; shift 2 ;;
        --project=*) PROJECT_ARG="${1#--project=}"; shift ;;
        --deadline-min) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; DEADLINE_MIN="$2"; shift 2 ;;
        --deadline-min=*) DEADLINE_MIN="${1#--deadline-min=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) err "unknown arg: $1"; usage >&2; exit 1 ;;
    esac
done

case "$DEADLINE_MIN" in
    ''|*[!0-9]*) err "--deadline-min must be a positive integer, got '$DEADLINE_MIN'"; exit 1 ;;
esac

# --- resolve root / slug / repo (moved ahead of the project-inheritance
# block below): the cross-bucket auto-discovery block that
# follows needs root/slug to search with, and nothing between here and the
# old position depended on the previous ordering.
if ! root="$(handover_root)"; then
    err "set HANDOVER_DIR or run /handover-setup."
    exit 2
fi
# #1410: resolve from this script's OWN checkout, like load_dotenv above --
# user_slug's forge/git-config fallbacks read the cwd, and the plugin console
# runs from any directory, so a foreign cwd forked the chain into another slug.
# The subshell also scrubs GIT_DIR & co (git-clean.sh): an inherited one would
# void the cd, git answering about ITS repo instead.
if ! slug="$(cd "$HERE/../../.." && git_env_scrub && user_slug)"; then
    err "cannot resolve USER_SLUG. Set USER_SLUG or configure your forge login / git user.name."
    exit 2
fi
repo="$(resolve_repo)"

# A bare `next` with nothing pinning down where to search (no
# --doc, no $CHIEF_DOC, no --bucket/$CHIEF_BUCKET/--prefix/--project)
# cannot resolve state_dir before searching for a predecessor -- state_dir
# derives from bucket, which derives from the project this block is trying
# to discover in the first place. Widen the search across every bucket this
# operator has ever used, rank candidates by the same date+letter key
# resolve_predecessor's own cross-date branch uses below (never a raw name
# sort -- AA sorts before B lexically despite being the later letter), and
# hand the winner to DOC_ARG so the EXISTING --doc-given machinery (the
# project-inheritance block right after this one, the --name-from-doc
# inference further down, resolve_predecessor itself) does the rest
# unmodified -- including refusing a poisoned recorded project exactly as
# --project would. Any of --doc/$CHIEF_DOC/--bucket/
# $CHIEF_BUCKET/--prefix/--project pins the search on its own and skips
# this block entirely, so explicit flags always still win.
if [ "$CMD" = next ] && [ -z "$PROJECT_ARG" ] && [ -z "$DOC_ARG" ] && [ -z "${CHIEF_DOC:-}" ] && [ -z "$BUCKET" ] && [ -z "${CHIEF_BUCKET:-}" ] && [ -z "$PREFIX" ]; then
    _auto_name="$(slugify "$NAME")"
    if [ -n "$_auto_name" ]; then
        _auto_newest="" _auto_newest_key=""
        for _auto_cand in "$root/$slug/"*/*"-nextleg-"*"-${_auto_name}.md"; do
            [ -f "$_auto_cand" ] || continue
            _auto_base="$(basename "$_auto_cand")"
            _auto_stem="${_auto_base%.md}"
            _auto_prefix_part="${_auto_stem%-"$_auto_name"}"
            [ "$_auto_prefix_part" = "$_auto_stem" ] && continue
            if [[ "$_auto_prefix_part" =~ ^[A-Z0-9]+-nextleg-([0-9]{4}-[0-9]{2}-[0-9]{2})([A-Z]{1,2})$ ]]; then
                _auto_cdate="${BASH_REMATCH[1]}"
                _auto_cletter="${BASH_REMATCH[2]}"
            else
                continue
            fi
            _auto_key="${_auto_cdate}-$(printf '%03d' "$(letter_value "$_auto_cletter")")"
            if [ -z "$_auto_newest_key" ] || [[ "$_auto_key" > "$_auto_newest_key" ]]; then
                _auto_newest_key="$_auto_key"
                _auto_newest="$_auto_cand"
            fi
        done
        [ -n "$_auto_newest" ] && DOC_ARG="$_auto_newest"
        unset _auto_cand _auto_base _auto_stem _auto_prefix_part _auto_cdate _auto_cletter _auto_key _auto_newest _auto_newest_key
    fi
    unset _auto_name
fi

# A `next` with no explicit
# --project must not silently record the successor as running "in the
# himmel checkout itself" for a chain that is FOR a foreign project -- the
# console session always lives in $REPO by design, so the plugin /console
# wrapper never derives --project from cwd for `next` (only for `new`), and
# without one this defaults PROJECT_ARG from the predecessor doc's own
# recorded project line, feeding the SAME bucket/prefix/registry resolution
# below as an explicit --project would. Possible either when the predecessor
# doc is known up front (--doc / $CHIEF_DOC) or once the auto-discovery
# block above has populated DOC_ARG; an explicit --project always still wins.
if [ "$CMD" = next ] && [ -z "$PROJECT_ARG" ]; then
    _predecessor_doc_early="${DOC_ARG:-${CHIEF_DOC:-}}"
    if [ -n "$_predecessor_doc_early" ] && [ -f "$_predecessor_doc_early" ]; then
        # shellcheck disable=SC2016  # single-quoted sed pattern; no expansion wanted
        _predecessor_project_early="$(sed -n 's/.*The project this console is FOR is \*\*`\([^`]*\)`\*\*.*/\1/p' "$_predecessor_doc_early" | head -n1)"
        case "$_predecessor_project_early" in
            ''|none*) _predecessor_project_early="" ;;
        esac
        # A recorded project that is not an absolute, existing directory is
        # refused exactly as --project would refuse it: dropping it would silently turn a foreign chain into a himmel
        # one. A relative value is refused too -- it would resolve against
        # whatever cwd this run happens to have.
        if [ -n "$_predecessor_project_early" ]; then
            case "$_predecessor_project_early" in
                /*) [ -d "$_predecessor_project_early" ] || _predecessor_project_bad=1 ;;
                *) _predecessor_project_bad=1 ;;
            esac
            if [ -n "${_predecessor_project_bad:-}" ]; then
                err "--project must be an existing directory, got '$_predecessor_project_early'"
                err "(recorded as the project in the predecessor doc $_predecessor_doc_early)"
                exit 1
            fi
            PROJECT_ARG="$_predecessor_project_early"
        fi
    fi
    unset _predecessor_doc_early _predecessor_project_early
fi
# plugin /console from any repo -- himmel's own JIRA_PROJECT_KEY and repo
# aren't the project's. --project marks the session as being FOR a DIFFERENT
# checkout than this one: when it resolves to somewhere other than $repo,
# bucket/prefix below derive from the PROJECT instead of from himmel, and the
# project is recorded as data in the console doc (see project_doc_value) --
# the console session itself always stays in $repo (do_arm above never
# retargets it). Canonicalized with `pwd -P`: a symlink to himmel, or two spellings of the SAME real repo (a
# trailing slash, a relative path), still compare equal and count as "not
# foreign".
project_dir=""
if [ -n "$PROJECT_ARG" ]; then
    [ -d "$PROJECT_ARG" ] || { err "--project must be an existing directory, got '$PROJECT_ARG'"; exit 1; }
    project_canon="$(cd "$PROJECT_ARG" && pwd -P)"
    if [ "$project_canon" != "$repo" ]; then
        project_dir="$project_canon"
    fi
fi
project_doc_value="none — this console runs in the himmel checkout itself"
[ -n "$project_dir" ] && project_doc_value="$project_dir"

# registry_lookup_for_project <project_dir> -- prints "<key>\t<jira_project>" and returns 0 on a match: an exact
# registered path, or the project's slugified basename against one of a
# registry key's ALIASES (curated, so no path check needed). 1 on no match,
# 2 on an unreadable registry. Refuses instead (exit 1, caller exits 1) when
# the basename-derived slug merely equals an existing key's NAME but that
# key's own path differs -- a bare name coincidence is not confirmation the
# two are the same repo, and silently mixing two unrelated projects into one
# bucket/prefix chain (P4) is worse than a loud refusal to disambiguate.
registry_lookup_for_project() {
    local dir="$1" reg rr_canon bn_slug out rc
    reg="${HANDOVER_REGISTRY:-$HOME/.claude/handover/registry.json}"
    [ -f "$reg" ] || return 1
    # shellcheck disable=SC1003  # '\\' is a literal backslash for tr, not a quote escape
    rr_canon="$(printf '%s' "$dir" | tr '\\' '/' | sed 's:/*$::' | tr '[:upper:]' '[:lower:]')"
    bn_slug="$(slugify "$(basename "$dir")")"
    out="$(REG="$reg" RR="$rr_canon" BN="$bn_slug" node -e '
        const fs = require("fs"), e = process.env;
        let j;
        try { j = JSON.parse(fs.readFileSync(e.REG, "utf8")); } catch (err) { process.exit(2); }
        const repos = (j && j.repos) || {};
        const norm = p => String(p || "").replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();
        for (const k of Object.keys(repos)) {
            if (norm(repos[k].path) === e.RR) {
                process.stdout.write([k, repos[k].jira_project || ""].join("\t"));
                process.exit(0);
            }
        }
        // A key-NAME or ALIAS match (no path confirmation) is only a
        // coincidence unless it is the registered projects own path too --
        // checked above and already returned. Treat it as a collision, not a
        // match: an unrelated project sharing a basename (a repo named
        // himmel, internal or docs at another path) must not silently inherit
        // another projects bucket/prefix.
        const display = p => String(p || "").replace(/\\/g, "/").replace(/\/+$/, "");
        for (const k of Object.keys(repos)) {
            const aliases = (repos[k].aliases || []).map(a => String(a).toLowerCase());
            if (k.toLowerCase() === e.BN || aliases.includes(e.BN)) {
                process.stdout.write([k, display(repos[k].path)].join("\t"));
                process.exit(3);
            }
        }
        process.exit(1);
    ')"
    rc=$?
    printf '%s' "$out"
    return "$rc"
}
# The lookup above runs inside a `$( )` command substitution, so an `exit`
# there would only kill that subshell, not the script -- a collision (rc 3)
# would silently fall through to the "not registered" warning below instead
# of refusing. So all exit-bearing decisions on its result happen HERE, in
# the real script scope.
project_registry_key=""
project_registry_jira=""
if [ -n "$project_dir" ]; then
    # `if x=$(...); then` is the errexit-safe form under `set -e` -- a plain
    # `x=$(...); rc=$?` assignment would abort the script on a non-zero
    # substitution (the collision/unreadable cases) before `rc=$?` ever runs.
    if _reg_match="$(registry_lookup_for_project "$project_dir")"; then
        _reg_rc=0
    else
        _reg_rc=$?
    fi
    case "$_reg_rc" in
        0)
            project_registry_key="${_reg_match%%$'\t'*}"
            project_registry_jira="${_reg_match#*$'\t'}"
            ;;
        2)
            err "handover registry unreadable (${HANDOVER_REGISTRY:-$HOME/.claude/handover/registry.json})"
            exit 2
            ;;
        3)
            # An explicit --bucket already disambiguates the collision the
            # message below is warning about -- refusing anyway would make
            # the documented remedy unusable.
            if [ -z "$BUCKET" ]; then
                err "resolved bucket '$(slugify "$(basename "$project_dir")")' for --project '$project_dir' collides with the registered project at '${_reg_match#*$'\t'}' — pass --bucket to disambiguate, or register this path: /handover register"
                exit 1
            fi
            ;;
        *)
            err "'$project_dir' is not in the handover registry — using its basename for bucket/prefix. Register it for stable naming: /handover register"
            ;;
    esac
fi

# bucket: --bucket, else $CHIEF_BUCKET, else the registry key for a
# registered foreign --project, else basename of a foreign --project, else
# derived from the repo basename — every branch already goes through
# `slugify` uniformly, so no ONE source can bypass sanitization the others
# get (the class of bug a --prefix flag branch alone would leave open). The only gap
# slugify itself doesn't close is a source that slugifies to nothing (e.g.
# CHIEF_BUCKET='###') — refused once, after precedence settles, same
# principle as prefix below.
if [ -n "$BUCKET" ]; then
    bucket="$(slugify "$BUCKET")"
elif [ -n "${CHIEF_BUCKET:-}" ]; then
    bucket="$(slugify "$CHIEF_BUCKET")"
elif [ -n "$project_registry_key" ]; then
    bucket="$(slugify "$project_registry_key")"
elif [ -n "$project_dir" ]; then
    bucket="$(slugify "$(basename "$project_dir")")"
else
    bucket="$(slugify "$(basename "$repo")")"
fi
if [ -z "$bucket" ]; then
    err "resolved --bucket is empty after slugifying — pass an explicit --bucket with at least one alphanumeric character"
    exit 1
fi
# prefix: --prefix, else the registry's jira_project for a registered foreign
# --project, else $JIRA_PROJECT_KEY (only when NOT a foreign --project --
# himmel's own key doesn't belong to another project), else derived from
# bucket. Validated ONCE here, on the RESOLVED value, after precedence
# settles — not per-branch — so no source (flag, env, or a future derivation
# change) can bypass it. Validating only the --prefix flag branch would leave
# JIRA_PROJECT_KEY reaching the same path construction unvalidated. Unlike --name/--bucket (slugified),
# a malformed prefix is refused rather than silently rewritten: a Jira-style
# project key is uppercase alphanumerics, and '../OTHER' copied verbatim
# would escape the selected bucket entirely.
if [ -n "$PREFIX" ]; then
    prefix="$PREFIX"
    prefix_source="--prefix"
elif [ -n "$project_registry_jira" ]; then
    prefix="$project_registry_jira"
    prefix_source="registry jira_project"
elif [ -z "$project_dir" ] && [ -n "${JIRA_PROJECT_KEY:-}" ]; then
    prefix="$JIRA_PROJECT_KEY"
    prefix_source="JIRA_PROJECT_KEY"
else
    prefix="$(printf '%s' "$bucket" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9')"
    prefix_source="derived from --bucket"
fi
case "$prefix" in
    ''|*[!A-Z0-9]*)
        err "resolved prefix ($prefix_source) must be non-empty uppercase alphanumeric (A-Z0-9), got '$prefix'"
        exit 1
        ;;
esac
# `next` without an explicit --name derives the chain name from --doc's own
# basename (<PREFIX>-nextleg-<DATE><LETTER>-<NAME>.md) — a cross-bucket
# --doc flow must not force the operator to also repeat --name.
if [ "$CMD" = next ] && [ "$NAME_GIVEN" -ne 1 ]; then
    _doc_for_name="${DOC_ARG:-${CHIEF_DOC:-}}"
    if [ -n "$_doc_for_name" ]; then
        _stem_for_name="$(basename "$_doc_for_name")"
        _stem_for_name="${_stem_for_name%.md}"
        if [[ "$_stem_for_name" =~ ^"$prefix"-nextleg-[0-9]{4}-[0-9]{2}-[0-9]{2}[A-Z]{1,2}-(.+)$ ]]; then
            NAME="${BASH_REMATCH[1]}"
        fi
    fi
fi

# slugify --name too: it lands in a file path and a session name, so a raw
# '--name ../evil' or a name with spaces must not reach either verbatim.
name="$(slugify "$NAME")"
if [ -z "$name" ]; then
    err "--name resolved to an empty slug (got '$NAME')"
    exit 1
fi
# stop-console-idle-guard (*-console.lock), guard-console-dispatch
# (*-console.md) and console-compact-reinject (-n name) all key on the -console
# suffix, so a console armed without it silently loses them. The bare default
# `console` already yields the `…A-console` doc.
case "$name" in
    console|*-console) ;;
    *)
        err "--name '$NAME' (slug '$name') must be 'console' or end in '-console' (the console guards key on that suffix)"
        exit 1 ;;
esac
date="$(date +%F)"
# successor_date: the day used for `next`'s SUCCESSOR name only.
# Defaults to today; --date overrides it so a 23:5x console can pre-mint
# TOMORROW's console without waiting for midnight. Nothing else (predecessor
# resolution, `new`) reads this — they keep using $date.
successor_date="$date"
if [ "$DATE_GIVEN" -eq 1 ]; then
    case "$DATE_ARG" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
            # Shape alone isn't enough ('2026-99-99' matches it): round-trip
            # through the platform date(1) and require the output to equal
            # the input, so a shape-valid but nonexistent calendar date
            # (also '2026-02-30') is rejected too.
            _date_round_trip="$(date -d "$DATE_ARG" +%F 2>/dev/null)" || _date_round_trip="$(date -j -f %Y-%m-%d "$DATE_ARG" +%F 2>/dev/null)" || _date_round_trip=""
            [ "$_date_round_trip" = "$DATE_ARG" ] || { err "--date must be a real calendar date, got '$DATE_ARG'"; usage >&2; exit 2; }
            successor_date="$DATE_ARG"
            ;;
        *) err "--date must be YYYY-MM-DD, got '$DATE_ARG'"; usage >&2; exit 2 ;;
    esac
fi
state_dir="$root/$slug/$bucket"
# The console parent defaults to Opus (default parent tier);
# Fable is the escalation target, reached only via --model / CHIEF_MODEL.
model="${MODEL:-${CHIEF_MODEL:-claude-opus-5-5}}"
fill_percent="${CHIEF_FILL_PERCENT:-45}"
# Resolve once for both printed and armed launches. An explicit
# --context overrides the console-only environment choice and 1m default.
if [ "$CONTEXT_GIVEN" -eq 1 ]; then
    CHIEF_CONTEXT_RESOLVED_MODE="$CONTEXT"
else
    console_context_default 1 "${CHIEF_CONTEXT:-}"
fi
console_autocompact="$(console_context_autocompact "$CHIEF_CONTEXT_RESOLVED_MODE")"
launch_model="$(console_context_strip_1m_suffix "$model")"
if [ "$CHIEF_CONTEXT_RESOLVED_MODE" = 1m ] && ! console_context_model_is_fable "$launch_model" \
    && console_context_model_takes_1m_suffix "$launch_model"; then
    launch_model="${launch_model}[1m]"
fi
# The launch line carries --autocompact and an Opus 5.5 id, which a
# CLI below the floor rejects at parse time. An --arm run refuses here, before
# any doc, lock or arm exists; a print-only or dry-run only warns.
_floor_dry=1
{ [ "$ARM" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; } && _floor_dry=0
claude_floor_gate chief.sh "$_floor_dry" "${HEADED_ARM_CLAUDE_CLI:-claude}" || exit 2

# launch_cmd <session> <doc> -- the command line printed for an operator to
# paste. No launcher runs for it, so the console's durable launch
# row is written by the command itself (record-launch.sh, then claude), never
# when the line is merely printed -- a row for a console nobody started would
# be indistinguishable from a real one. The row carries the mode/source/
# autocompact resolved above, the same values the claude flags below carry.
# `;` not `&&`: a row that cannot be written must not stop the console.
# An --arm console is launched by headed-arm.sh, which writes its own row; the
# line printed beside it is informational and is not pasted.
# The line opens with `cd <himmel checkout> && { ...; }` because the
# plugin prints it to an operator sitting in a FOREIGN repo, and the
# console must start in himmel for its project hooks and GO gate. The group
# keeps a failed cd from falling through to claude in the wrong directory.
launch_cmd() {
    # The printed console line carries the `console` plugin profile
    # (--settings), like the armed launch; fails closed (no profile, no line).
    local console_settings
    console_settings=$(bash "$HERE/../../lanes/profile-settings.sh" console) \
        || { err "the console plugin profile did not resolve; refusing to print a full-plugin-set console launch (HIMMEL-4013)"; exit 2; }
    # Only the profile's MCP servers (--strict-mcp-config), as the
    # armed launch does; the flags sit between --model and --autocompact.
    local console_mcp mcp_flags=""
    console_mcp=$(bash "$HERE/../../lanes/profile-settings.sh" console --mcp-config) \
        || { err "the console MCP allowlist did not resolve; refusing to print a console launch with every user-level MCP server (HIMMEL-5310)"; exit 2; }
    [ -z "$console_mcp" ] || mcp_flags="$(printf -- '--mcp-config %q --strict-mcp-config ' "$console_mcp")"
    local claude_cmd
    claude_cmd="$(printf '%s claude --settings %q --model %q %s--autocompact %s -n %s "load %s and continue"' \
        "$CHIEF_LAUNCH_ENV" "$console_settings" "$launch_model" "$mcp_flags" "$console_autocompact" "$1" "$2")"
    # No launcher binds a pasted console on the bus, so the line runs claude
    # through console-bus-exec.sh, which registers and binds it first; a line
    # pasted after that file is gone runs claude directly.
    local bus_opt=0
    console_bus_opted_in || bus_opt=$?
    [ "$bus_opt" -ne 2 ] || err "WARN the console bus profile probe failed ($bus_probe_out); the printed console line runs claude unbound"
    if [ "$bus_opt" -eq 0 ]; then
        local bus_exec
        bus_exec="$(printf 'bash %q %q ' "$HERE/console-bus-exec.sh" "$1")"
        [ -z "$CHIEF_BUS_PREDECESSOR" ] || bus_exec+="$(printf -- '--predecessor %q ' "$CHIEF_BUS_PREDECESSOR")"
        claude_cmd="$(printf 'if [ -f %q ]; then %s-- %s; else %s; fi' "$HERE/console-bus-exec.sh" "$bus_exec" "$claude_cmd" "$claude_cmd")"
    fi
    printf 'cd %q && { bash %q %s %s %s %s; %s; }' \
        "$repo" "$HERE/record-launch.sh" "$1" "$CHIEF_CONTEXT_RESOLVED_MODE" "$(console_context_source_label "$CONTEXT_GIVEN")" "$console_autocompact" \
        "$claude_cmd"
}

# _console_sha256_8 <string> -- first 8 hex chars of sha256(<string>). Small
# per-script helper, matching the repo's own convention of duplicating this
# rather than centralizing it (already inlined the same way in
# queue-lock.sh's _ql_digest_of, artifact-sync.sh's sha256_of, and
# arm-resume.sh). Fails closed (exit 2, alongside this script's other
# unresolved-root/tooling cases) rather than silently falling back to an
# unhashed or truncated root, which would reopen the exact collision this
# digest exists to prevent.
_console_sha256_8() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | cut -d' ' -f1 | cut -c1-8
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1 | cut -c1-8
    else
        err "no sha256 hasher available (need sha256sum or shasum) to derive the per-chain work-dir digest"
        exit 2
    fi
}

# Two consoles under DIFFERENT $HANDOVER_DIR roots that happen
# to agree on slug/bucket/prefix/date/letter/name would otherwise collide on
# the same signal/log path — touching one chain's signal could arm the
# other's successor. Folding a digest of the RESOLVED, CANONICALIZED root
# into the chain dir name fixes that; canonicalizing first (via the same
# _arm_realpath already used to normalize the root elsewhere) means two
# spellings of one root (a symlink alias, a trailing slash) still digest
# identically instead of splitting one chain's history in two.
root_canon="$(_arm_realpath "$root")"
root_digest="$(_console_sha256_8 "$root_canon")"

# _console_group_or_world_writable <dir> -- true if <dir>'s own permission
# bits allow group or other write. console_workdir_ensure only ever validates the CHILD it creates
# ($XDG_RUNTIME_DIR/himmel-console); it never checks the PARENT
# ($XDG_RUNTIME_DIR itself). Unix permission semantics mean write access to
# a directory controls its entries regardless of the entries' own
# permissions (absent a sticky bit, which /tmp has but an arbitrary
# XDG_RUNTIME_DIR is not guaranteed to), so a group- or world-writable
# parent lets another local user swap the child out from under this
# process even after the child passed its own validation. A separate
# helper (rather than folding this into console_workdir_ensure) keeps that
# already-tested function's exact error-message wording untouched.
_console_group_or_world_writable() {
    local mode
    mode=$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null)  # gnu-ok: GNU stat -c is paired with the BSD stat -f fallback on this same line
    [ -n "$mode" ] || return 0  # unreadable bits: fail closed, treat as writable so the caller falls back
    local oth="${mode: -1}" grp="${mode%?}"
    grp="${grp: -1}"
    case "$oth$grp" in
        *2*|*3*|*6*|*7*) return 0 ;;
        *) return 1 ;;
    esac
}

# The default work dir is a PREDICTABLE path
# (${TMPDIR:-/tmp}/himmel-console-<uid>) another local user could pre-create
# — as a directory they own, or as a symlink elsewhere — before this
# process's first run; `mkdir -p` silently accepts an existing directory
# regardless of who made it or what it actually resolves to. Prefer
# $XDG_RUNTIME_DIR/himmel-console (already a per-user 0700 directory on
# systemd hosts) when it is set AND already owned by this uid AND not
# itself group- or world-writable; otherwise fall back to the uid-qualified
# /tmp path. Modeled directly on headed-arm.sh's LOCKDIR hardening:
# `-L` before `-d` before `-O` (plain test operators, no
# stat/uid comparison needed), then a stat-based permission-bit check for
# the GNU/BSD split. Exit 3 is a new, distinct code for this whole class of
# refusal — never conflated with the exit-1 usage errors or the exit-2
# unresolved-root/tooling errors above.
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -O "$XDG_RUNTIME_DIR" ] \
    && ! _console_group_or_world_writable "$XDG_RUNTIME_DIR"; then
    _console_default_workdir="$XDG_RUNTIME_DIR/himmel-console"
else
    _console_default_workdir="${TMPDIR:-/tmp}/himmel-console-$(id -u)"
fi
# CHIEF_WORK_DIR is a durable test/operator seam, not an escape hatch from
# this hardening: an override is exactly as reachable by another local user
# guessing or being told the path as the default is, so it goes through the
# SAME validation rather than being trusted outright.
workdir="${CHIEF_WORK_DIR:-$_console_default_workdir}"

# _console_dir_component_unsafe <dir> -- true if <dir> is group- or
# world-writable AND (lacks the sticky bit OR the sticky bit is present but
# <dir> is owned by neither root nor us). console_workdir_ensure (below) validates only $workdir
# itself, in every one of its three origins -- the XDG_RUNTIME_DIR default,
# a CHIEF_WORK_DIR override, or the TMPDIR fallback. The XDG_RUNTIME_DIR
# case alone got a parent check (the `if` above deciding whether to prefer
# it); the override and TMPDIR-fallback parents would be left
# unchecked, so another local user with write access to either parent could
# still swap the (already-validated) work dir out from under this process,
# same as the XDG_RUNTIME_DIR case. A sticky bit changes that: it restores
# per-entry protection inside an otherwise world-writable directory -- but
# ONLY against users who are neither the entry's owner, the directory's
# owner, nor root; the directory's OWNER can still rename/unlink entries
# inside their own directory regardless of the sticky bit, so a sticky directory owned by an attacker is not
# actually safe -- the exemption must also require the directory itself be
# owned by root or by us. This is exactly what makes plain /tmp (mode 1777,
# root-owned) a safe TMPDIR-fallback parent despite being world-writable,
# and is why the plain group/world-writable check the XDG_RUNTIME_DIR
# preference above uses needs no such exemption (XDG_RUNTIME_DIR is never
# expected to need a sticky-bit exception: a systemd-provided one is 0700,
# and an operator-provided one is a config choice, not a shared temp dir).
_console_dir_component_unsafe() {
    local owner
    owner=$(stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null)  # gnu-ok: GNU stat -c is paired with the BSD stat -f fallback on this same line
    [ -n "$owner" ] || return 0  # unreadable owner: fail closed, treat as unsafe
    if [ "$owner" != "0" ] && [ "$owner" != "$(id -u)" ]; then
        # An attacker-owned
        # directory is unsafe REGARDLESS of its current permission bits --
        # its owner can chmod it to add write access (or already has owner
        # write access even at e.g. mode 0755) at any point after this
        # check runs, so ownership by neither root nor us is disqualifying
        # on its own, before even looking at group/world-writable bits.
        return 0
    fi
    local mode
    # #1413: BSD %Lp drops the sticky bit (/tmp -> 777); %Mp%Lp keeps it (1777), like GNU %a.
    mode=$(stat -c %a "$1" 2>/dev/null || stat -f %Mp%Lp "$1" 2>/dev/null)  # gnu-ok: GNU stat -c is paired with the BSD stat -f fallback on this same line
    [ -n "$mode" ] || return 0  # unreadable bits: fail closed, treat as unsafe
    local oth="${mode: -1}" grp="${mode%?}"
    grp="${grp: -1}"
    case "$oth$grp" in
        *2*|*3*|*6*|*7*) : ;;  # group/world-writable -- fall through to the sticky check
        *) return 1 ;;  # trusted owner, not group/world-writable: safe
    esac
    local sticky=0
    if [ "${#mode}" -ge 4 ]; then
        case "${mode:0:1}" in
            1|3|5|7) sticky=1 ;;
        esac
    fi
    [ "$sticky" -eq 1 ] && return 1  # trusted owner + sticky: non-owners can't rename/unlink our entry: safe
    return 0  # trusted owner but group/world-writable without sticky: other non-owning local users could tamper
}
# _console_ancestor_unsafe <dir> -- true if <dir> or any of its existing
# ancestors is unsafe per _console_dir_component_unsafe. Checking only the immediate parent leaves the
# REST of the ancestor chain unchecked -- a local user with write access to
# a GRANDPARENT (or higher) can rename/replace that ancestor, substituting
# the entire subtree beneath it (including an immediate parent that, in
# isolation, looks perfectly safe), so every existing ancestor up to the
# filesystem root must be checked, not just the nearest one. A non-existent
# ancestor is skipped (mirroring the existing single-parent check): `mkdir -p`
# will create it, and its own ancestors are still walked and checked.
_console_ancestor_unsafe() {
    local d="$1" prev=""
    while [ "$d" != "$prev" ]; do
        if [ -d "$d" ] && _console_dir_component_unsafe "$d"; then
            return 0
        fi
        prev="$d"
        d="$(dirname "$d")"
    done
    return 1
}
# The ancestor walk is a
# lexical `dirname` loop -- on a RELATIVE workdir (e.g. CHIEF_WORK_DIR=work)
# `dirname` stops at "." after one step ("." is its own dirname), so only the
# current working directory itself is ever checked, never anything above it.
# Canonicalizing to an absolute path first (the same _arm_realpath already
# used to normalize the handover root above) makes the walk always reach the
# real filesystem root regardless of how workdir was spelled.
_console_workdir_abs="$(_arm_realpath "$workdir")"
_console_workdir_parent="$(dirname "$_console_workdir_abs")"
if _console_ancestor_unsafe "$_console_workdir_parent"; then
    err "refusing to use work dir '$workdir' — its parent directory '$_console_workdir_parent' (or an ancestor of it) is group- or world-writable without adequate sticky-bit/ownership protection, so another local user could replace it out from under this process (HIMMEL-2881)"
    exit 3
fi
# Ancestor validation above runs
# against the CANONICALIZED path, so every use below this point (creation,
# chain_dir) must use that path rather than the ORIGINAL $workdir spelling -- if a symlink
# in one of workdir's own path components resolved to a safe tree at
# validation time, an attacker could repoint that symlink before the actual
# create/access below, and the two would silently diverge. Adopting the
# already-validated canonical path for every subsequent use closes that
# window: what was checked is exactly what gets used. This MUST run before
# the reassignment below: `realpath -m` resolves a symlink at $workdir's own
# last component away entirely, so console_workdir_ensure's own -L check
# would never see it once $workdir has already been replaced by its
# resolved form (case 27's pre-created-symlink-as-workdir regression).
if [ -L "$workdir" ]; then
    err "refusing to use work dir '$workdir' — it is a SYMLINK, so this process does not control what it actually resolves to (HIMMEL-2881)"
    exit 3
fi
workdir="$_console_workdir_abs"

# _console_mkdir_chain_safe <dir> -- create <dir> and every missing ancestor
# ONE COMPONENT AT A TIME (never a single `mkdir -p`), validating ownership
# of each component the instant it exists -- whether because this call just
# created it or because it was already there. `_console_ancestor_unsafe` above only walks EXISTING
# ancestors -- a missing one is skipped on the assumption that `mkdir -p`
# will create it safely -- but `mkdir -p` silently adopts any ancestor an
# attacker races into existence between that walk and this create step, with
# NO ownership check of its own, and that attacker-owned ancestor can later
# be used to replace the whole subtree beneath it. Building the chain
# top-down with plain `mkdir` (no -p) closes the window: each `mkdir` either
# succeeds (so this process owns the new directory, created at mode 0700 --
# unconditionally safe) or fails because the component already exists, in
# which case it is validated exactly like a pre-existing ancestor before
# anything is created beneath it.
_console_mkdir_chain_safe() {
    local target="$1" prefix="$1" p
    local -a missing=()
    while [ ! -e "$prefix" ]; do
        missing=("$prefix" ${missing[@]+"${missing[@]}"})
        prefix="$(dirname "$prefix")"
        [ "$prefix" = "/" ] && break
    done
    # The scan above just stops at the first EXISTING directory and hands it to
    # the create loop below as a trusted base -- but "existing" only means
    # existing NOW, at scan time, not at the time the OUTER ancestor-unsafe
    # walk (which ran before this function was ever called) last looked. An
    # attacker who races a brand-new ancestor into existence in that window
    # becomes this scan's stopping point and would otherwise never be
    # checked at all. Re-running the same ancestor walk against it here --
    # right before it is trusted -- closes that window.
    if _console_ancestor_unsafe "$prefix"; then
        err "refusing to use work dir '$target' — its ancestor '$prefix' (or one above it) is unsafe, and appeared after the initial check ran (HIMMEL-2881)"
        exit 3
    fi
    # `${missing[@]+...}` -- `missing` is empty whenever the work
    # dir already exists, and bash < 4.4 (macOS 3.2) aborts a bare
    # "${missing[@]}" of an empty array under `set -u`.
    for p in ${missing[@]+"${missing[@]}"}; do
        # shellcheck disable=SC2174
        if ! mkdir -m 0700 "$p" 2>/dev/null; then
            if [ -L "$p" ] || [ ! -d "$p" ] || _console_dir_component_unsafe "$p"; then
                err "refusing to use work dir '$target' — could not safely create ancestor '$p': it was raced into existence by something this process does not control (HIMMEL-2881)"
                exit 3
            fi
        fi
    done
}
# console_workdir_ensure <dir> -- create at 0700 if absent, then ALWAYS
# validate what actually exists at $d afterward -- never return early on a
# bare mkdir success. `mkdir -p` is a documented no-op on a path that already
# exists (including one whose last component is a symlink resolving to a
# directory), so a hostile dir/symlink planted in the TOCTOU window between
# the existence check below and the mkdir call would otherwise be silently
# trusted; falling through into the same checks a pre-existing directory gets
# closes that race, since -L/-O/permission-bits are evaluated on whatever is
# actually at $d now, not on what mkdir believes it created. This is also why
# a passing directory is never chmod'd here: fixing up an existing hostile
# dir's mode would let it pass while the attacker still owns it, laundering
# exactly the thing this check exists to catch.
console_workdir_ensure() {
    local d="$1"
    if [ ! -e "$d" ] && [ ! -L "$d" ]; then
        _console_mkdir_chain_safe "$d"
    fi
    if [ -L "$d" ]; then
        err "refusing to use work dir '$d' — it is a SYMLINK, so this process does not control what it actually resolves to (HIMMEL-2881)"
        exit 3
    fi
    if [ ! -d "$d" ]; then
        err "refusing to use work dir '$d' — it is not a directory (HIMMEL-2881)"
        exit 3
    fi
    if [ ! -O "$d" ]; then
        err "refusing to use work dir '$d' — it is not owned by this user (HIMMEL-2881)"
        exit 3
    fi
    local mode
    mode=$(stat -c %a "$d" 2>/dev/null || stat -f %Lp "$d" 2>/dev/null)  # gnu-ok: GNU stat -c is paired with the BSD stat -f fallback on this same line
    if [ -z "$mode" ]; then
        err "refusing to use work dir '$d' — could not read its permission bits (HIMMEL-2881)"
        exit 3
    fi
    local oth="${mode: -1}" grp="${mode%?}"
    grp="${grp: -1}"
    case "$oth$grp" in
        *2*|*3*|*6*|*7*)
            err "refusing to use work dir '$d' — it is group- or world-writable (HIMMEL-2881)"
            exit 3
            ;;
    esac
}
console_workdir_ensure "$workdir"

# Namespaced by chain identity (slug+bucket+root digest), NOT just session
# name: the session name is keyed on <PREFIX>-nextleg-<date><letter>-<name>
# only (the established, fleet-wide convention — out of scope to change), so
# two chains that differ just by bucket, or just by handover root, but share
# everything else would otherwise collide on the SAME signal/log path and
# touching one chain's signal could arm the other's successor.
chain_dir="$workdir/${slug}-${bucket}-${root_digest}"
# 10# forces base-10: DEADLINE_MIN passed the digits-only check above, but a
# leading zero (e.g. "08") is otherwise read as octal in arithmetic context,
# and 8/9 are not valid octal digits.
deadline_epoch=$(( $(date +%s) + 10#$DEADLINE_MIN * 60 ))
template_dir="${CHIEF_TEMPLATE_DIR:-$repo/docs/handover}"
console_template="$template_dir/console-template.md"
handoff_template="$template_dir/console-handoff-template.md"
kit="$repo/scripts/handover/console-kit"

# --- new --------------------------------------------------------------
cmd_new() {
    [ -f "$console_template" ] || { err "missing template $console_template"; exit 2; }

    if [ "$DRY_RUN" -eq 1 ]; then
        local letter
        letter="$(find_free_letter)" || { err "all letters A-Z, AA-ZZ (past ZZ) are taken for today's '$name' console in $state_dir"; exit 1; }
        local doc="$state_dir/${prefix}-nextleg-${date}${letter}-${name}.md"
        local session="${prefix}-nextleg-${date}${letter}-${name}"
        local fill_signal="$chain_dir/sig-$session"
        local log="$chain_dir/launch-$session.log"
        echo "would-doc: $doc"
        echo "would-session: $session"
        echo "would-kit: $kit"
        if [ -n "$project_dir" ]; then
            echo "would-project: $project_dir"
        fi
        launch_line=$(launch_cmd "$session" "$doc") || exit $?
        echo "would-launch: $launch_line"
        if [ "$ARM" -eq 1 ]; then
            echo "would-armed: name=$session doc=$doc signal=$fill_signal deadline=$deadline_epoch log=$log"
            echo "would-arm-log: $log"
        fi
        return 0
    fi

    mkdir -p "$state_dir"
    # Claim a letter by ATOMIC EXCLUSIVE CREATE, never scan-then-create (the
    # repo's own convention — see headed-arm.sh): two
    # concurrent `new` runs racing a plain find_free_letter could both pick
    # the same free letter, and the second would truncate the first's doc
    # before either took its queue lock. `set -C` (noclobber) makes `: >`
    # refuse an existing target instead of overwriting it; on a collision
    # (either a real pre-existing doc or a losing race) this advances to the
    # next letter rather than failing.
    local letter="A" doc create_error claimed=0
    set -C
    while :; do
        doc="$state_dir/${prefix}-nextleg-${date}${letter}-${name}.md"
        if create_error="$( { : > "$doc"; } 2>&1 )"; then
            claimed=1
            break
        fi
        # Only an existing document (or symlink reserved by another caller)
        # is a collision. Other failures must keep their actual diagnostic.
        if [ ! -f "$doc" ] && [ ! -L "$doc" ]; then
            set +C
            err "could not create console doc $doc: $create_error"
            exit 1
        fi
        letter="$(next_letter "$letter")" || break
    done
    set +C
    [ "$claimed" -eq 1 ] || { err "all letters A-Z, AA-ZZ (past ZZ) are taken for today's '$name' console in $state_dir"; exit 1; }
    local session="${prefix}-nextleg-${date}${letter}-${name}"
    # The Telegram inbox, resolved here (same default as
    # arm-resume.sh / bus.ts) so step 10/11 print a literal, runnable path.
    local inbox="${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}/consoles/${session}.md"
    local fill_signal="$chain_dir/sig-$session"
    local log="$chain_dir/launch-$session.log"

    # Resolve the launch line (and so the console profile) BEFORE
    # the lock and the render, as cmd_next does before clearing its cleanup
    # trap: a profile refusal must leave neither a rendered doc nor a held lock.
    # The doc claimed above is still the empty placeholder, so remove it.
    local launch_rc=0
    launch_line=$(launch_cmd "$session" "$doc") || launch_rc=$?
    if [ "$launch_rc" -ne 0 ]; then
        rm -f "$doc"
        exit "$launch_rc"
    fi

    echo "doc: $doc"
    echo "session: $session"
    echo "kit: $kit"

    # The lock is what makes a console single-writer — starting one without
    # it is exactly the failure the lock exists to prevent. Abort before the
    # launch line and before any arm; the written doc is left in place
    # (harmless — a later `new` bumps the letter, and the letter claim above
    # already reserved it regardless of what happens here).
    #
    # Acquired BEFORE the render (not after, as earlier rounds had it): the
    # token this prints is embedded into the document itself via
    # {{RELEASE_TOKEN}}, so ACTION ZERO can adopt it from the doc it already
    # loaded instead of depending on operator scrollback — and on --arm,
    # nothing else could ever have delivered it to the launched console at
    # all (do_arm's own argv carries no token, and the per-session
    # token file is keyed to THIS process, not the one `--arm` launches).
    # Only stdout is captured (not stderr): queue-lock.sh's own diagnostics
    # ("stderr says which" on a takeover) still stream live; only the
    # release-token line needs to reach the render. Printed back out below,
    # in the same position this contract has always used, so nothing is
    # silently swallowed.
    local lock_out release_token
    if ! lock_out="$(HANDOVER_DIR="$root" bash "$repo/scripts/handover/queue-lock.sh" acquire "$doc")"; then
        err "WARNING queue-lock acquire failed for $doc — refusing to launch without the lock (doc left in place)"
        exit 1
    fi
    release_token="$(printf '%s\n' "$lock_out" | sed -n 's/^release-token: //p')"
    # Acquire now prints the token backticked
    # ("release-token: `<token>`"), so this extraction would otherwise embed
    # the backticks into {{RELEASE_TOKEN}} too -- strip a matched pair.
    # Tolerates the pre-2910 bare form too -- a no-op when there are no
    # backticks to strip.
    release_token="${release_token#\`}"
    release_token="${release_token%\`}"
    if [ -z "$release_token" ]; then
        err "queue-lock acquire for $doc reported success but printed no release-token line — refusing to render a document with an empty or bogus token"
        exit 1
    fi

    render_template "$console_template" "$doc" \
        FLEET_MANIFEST "${doc%.md}.fleet.json" \
        FLEET_MANIFEST_NOTE "none carried (first console of the chain); create it with fleet-manifest.sh add" \
        LETTER "$letter" \
        PREDECESSOR "none — first console of the chain" \
        PREDECESSOR_HANDOFF "none" \
        SESSION_NAME "$session" \
        INBOX "$inbox" \
        HANDOVER_ROOT "$root" \
        STATE_DIR "$state_dir" \
        REPO "$repo" \
        PREFIX "$prefix" \
        BUCKET "$bucket" \
        KIT "$kit" \
        FILL_SIGNAL "$fill_signal" \
        FILL_PERCENT "$fill_percent" \
        RELEASE_TOKEN "$release_token" \
        BOARD_URL "none yet — publish it at ACTION ZERO step 12" \
        TRACKER_URL "none" \
        CARRIED_LIVE_STATE "epics: none
decisions: none" \
        CARRIED_DIRECTION "Chain order: none yet (first console of the chain). In work: nothing. Waits on the operator: nothing." \
        MODEL "$model" \
        PROJECT "$project_doc_value"

    console_metadata "$inbox"
    printf '%s\n' "$lock_out"

    echo "launch: $launch_line"

    if [ "$ARM" -eq 1 ]; then
        do_arm "$session" "$doc" "$fill_signal" "$log"
    fi
}

# --- next -------------------------------------------------------------

# resolve_predecessor -- print the predecessor doc path, per the precedence
# in the header: --doc, CHIEF_DOC, today's highest letter, else the
# newest <PREFIX>-nextleg-*-<NAME>.md by name sort.
resolve_predecessor() {
    if [ -n "$DOC_ARG" ]; then
        printf '%s' "$DOC_ARG"
        return 0
    fi
    if [ -n "${CHIEF_DOC:-}" ]; then
        printf '%s' "$CHIEF_DOC"
        return 0
    fi
    # Bijective base-26 letters ("AA" < "B" lexically, even though AA is the
    # LATER letter) break a plain name sort: rank candidates by letter_value,
    # never by string comparison.
    local cand best_cand="" best_val=0 base stem letter_part val
    for cand in "$state_dir/${prefix}-nextleg-${date}"*"-${name}.md"; do
        [ -f "$cand" ] || continue
        base="$(basename "$cand")"
        stem="${base%.md}"
        letter_part="${stem%-"$name"}"
        [ "$letter_part" = "$stem" ] && continue
        letter_part="${letter_part#"${prefix}-nextleg-${date}"}"
        case "$letter_part" in
            [A-Z]|[A-Z][A-Z]) ;;
            *) continue ;;
        esac
        val="$(letter_value "$letter_part")"
        if [ "$val" -gt "$best_val" ]; then
            best_val="$val"
            best_cand="$cand"
        fi
    done
    [ -n "$best_cand" ] && { printf '%s' "$best_cand"; return 0; }
    # Glob instead of `find -maxdepth` (GNU-only). Unlike the same-day scan
    # above, this crosses dates, so a plain name sort would still be right
    # for the date part (ISO sorts lexically) but wrong for the letter part
    # for the same AA-vs-B reason — build a composite date+numeric-letter key
    # and compare THAT, never the raw filename. An unmatched glob expands to
    # the literal pattern (no nullglob here), so each candidate is
    # existence-checked before it can win. The directory and name stay
    # QUOTED and only the wildcard is bare: building the whole pattern into
    # one variable and leaving `$pattern` unquoted word-splits on IFS (a
    # space in the handover root, say) before globbing ever runs.
    local newest="" newest_key="" prefix_part cdate cletter key
    for cand in "$state_dir/${prefix}-nextleg-"*"-${name}.md"; do
        [ -f "$cand" ] || continue
        base="$(basename "$cand")"
        stem="${base%.md}"
        prefix_part="${stem%-"$name"}"
        [ "$prefix_part" = "$stem" ] && continue
        if [[ "$prefix_part" =~ ^.*-nextleg-([0-9]{4}-[0-9]{2}-[0-9]{2})([A-Z]{1,2})$ ]]; then
            cdate="${BASH_REMATCH[1]}"
            cletter="${BASH_REMATCH[2]}"
        else
            continue
        fi
        key="${cdate}-$(printf '%03d' "$(letter_value "$cletter")")"
        if [ -z "$newest_key" ] || [[ "$key" > "$newest_key" ]]; then
            newest_key="$key"
            newest="$cand"
        fi
    done
    [ -n "$newest" ] || return 1
    printf '%s' "$newest"
}

# The text of every bucket decisions file a decisions: line names
# (specs/decisions/console-decisions-<date>.md, relative to the bucket), one
# after another. Fails when the line names none, or one is not a readable file.
# Args: line, bucket dir.
decisions_files_text() {
    local line="$1" dir="$2" f n=0
    while IFS= read -r f; do
        [ -f "$dir/$f" ] && [ -r "$dir/$f" ] || return 1
        cat "$dir/$f" || return 1
        n=$((n + 1))
    done < <(printf '%s\n' "$line" | grep -o 'specs/decisions/console-decisions-[0-9-]*\.md')
    [ "$n" -gt 0 ]
}

# A decisions: line keeps every operator ruling when it names a bucket
# decisions file and every numbered "(N) " entry of the predecessor's line, and
# of the decisions files that line names, is found verbatim in the outgoing line
# or the files it names, as a whole entry: an entry runs to the next "(N) " or
# the end of its line, so a heading in a decisions file is part of no entry and
# a ruling with words appended is not the ruling. Fails closed: an
# unreadable file or no numbered entry fails, and the first entry not found is
# printed to stderr.
# Args: predecessor line, outgoing line, bucket dir.
decisions_kept_verbatim() {
    local prev="$1" out="$2" dir="$3" have need
    have="$(decisions_files_text "$out" "$dir")" || return 1
    need="$prev"
    case "$prev" in
        *specs/decisions/console-decisions-*)
            need="$need"$'\n'"$(decisions_files_text "$prev" "$dir")" || return 1 ;;
    esac
    awk '
        function entries(line,    rest, len, entry, k) {
            rest = line; k = 0
            while (match(rest, /\([0-9]+\) /)) {
                rest = substr(rest, RSTART); len = RLENGTH
                if (match(substr(rest, len + 1), /\([0-9]+\) /)) {
                    entry = substr(rest, 1, len + RSTART - 1); rest = substr(rest, len + RSTART)
                } else { entry = rest; rest = "" }
                sub(/[[:space:]]+$/, "", entry); got[++k] = entry
            }
            return k
        }
        FNR == NR { for (i = entries($0); i > 0; i--) have[got[i]] = 1; next }
        {
            k = entries($0)
            for (i = 1; i <= k; i++) {
                n++
                if (!(got[i] in have)) { print "  not found verbatim: " substr(got[i], 1, 100) > "/dev/stderr"; bad = 1; exit 1 }
            }
        }
        END { if (!bad && !n) { print "  no numbered (N) entry in the predecessor decisions" > "/dev/stderr"; exit 1 } }
        ' <(printf '%s\n%s\n' "$out" "$have") <(printf '%s\n' "$need")
}

# Refuse a handover whose <field>: Live-state line is missing or a
# placeholder (for `decisions:`, also shorter or, once the predecessor's names
# a decisions file, any length, unless decisions_kept_verbatim)
# where the doc the outgoing console itself succeeded (named on its first line)
# had a real one, unless its Results carry a `<MARKER>: <reason>` bullet. No
# predecessor, or one without a real line, passes. `priority:` shrinks as its
# keys ship, so it is held to presence only, and a PRIORITY-PRUNE bullet
# (priority-prune.sh --apply) also exempts it.
# Args: field, drop marker, outgoing doc, outgoing Live state.
check_live_line_kept() {
    local field="$1" marker="$2" outgoing="$3" live="$4" prev_name prev_doc prev_line out_line why="" prune=""
    [ "$field" != priority ] || prune="|PRIORITY-PRUNE"
    prev_name="$(sed -n '1s/^.* successor to \([^ ]*\.md\).*$/\1/p' "$outgoing")"
    [ -n "$prev_name" ] || return 0
    prev_doc="$(dirname "$outgoing")/$prev_name"
    [ -f "$prev_doc" ] || return 0
    prev_line="$(awk -v k="$field:" '
        $0 == "## Live state" { f = 1; next }
        f && /^## / { exit }
        f && index($0, k) == 1 { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
    ' "$prev_doc")"
    case "$prev_line" in ""|none|"none "*|"<"*) return 0 ;; esac
    out_line="$(printf '%s\n' "$live" | sed -n "s/^$field:[[:space:]]*//p" | head -n 1)"
    case "$out_line" in
        ""|none|"none "*|"<"*) ;;
        *) case "$field:$prev_line" in decisions:*specs/decisions/console-decisions-*) ;;
               *) { [ "$field" != decisions ] || [ "${#out_line}" -ge "${#prev_line}" ]; } && return 0 ;; esac
           if [ "$field" = decisions ]; then
               why="$(decisions_kept_verbatim "$prev_line" "$out_line" "$(dirname "$outgoing")" 2>&1 >/dev/null)" && return 0
           fi ;;
    esac
    awk '$0 == "## Results" { f = 1; next } f && /^## / { f = 0 } f' "$outgoing" \
        | grep -Eq "^- .*($marker$prune):[[:space:]]*[^[:space:]<]" && return 0
    err "refusing to hand over: the $field: line in $outgoing is missing, a placeholder, shorter than its predecessor's or drops one of its rulings ($prev_name):"
    err "  predecessor: $field: $prev_line"
    [ -z "$why" ] || err "$why"
    err "  restore it, or record a Results bullet '$marker: <reason>' and retry"
    [ "$field" != decisions ] || err "  or move rulings verbatim to specs/decisions/console-decisions-<date>.md in the bucket and name that file on the line"
    return 1
}

# The body of a doc's `## Current direction` block, without its `>` guidance lines.
# Args: doc.
direction_block() {
    awk '$0 == "## Current direction" { f = 1; next } f && /^## / { exit } f && !/^>/' "$1"
}

# Refuse a handover whose outgoing doc has no real `## Current direction` block:
# absent, empty, `none`, or only a `<...>` placeholder.
# Args: outgoing doc.
check_direction_real() {
    local body first
    body="$(direction_block "$1")"
    first="$(printf '%s\n' "$body" | sed -n '/[^[:space:]]/{p;q;}' | sed 's/^[[:space:]]*//')"
    case "$first" in
        ""|none|"none "*|"<"*) ;;
        *) return 0 ;;
    esac
    err "refusing to hand over: $1 has no real '## Current direction' block (absent, empty or a placeholder)."
    err "  write the chain order, what is in work and what waits on the operator, then retry"
    return 1
}

# The verbatim quote of every `OPERATOR ... (verbatim): "<quote>"` (or '<quote>')
# Results bullet of a doc, one per line. A quote ends at the first matching
# quote mark not followed by a letter or digit, so an apostrophe inside is kept.
# ponytail: a quote that spans bullets or holds a quote mark before a space is cut short, a structured ruling record would not.
# Args: doc.
verbatim_rulings() {
    awk '
        $0 == "## Results" { f = 1; next }
        f && /^## / { f = 0 }
        f && /^- / {
            i = index($0, "(verbatim):"); if (!i || substr($0, 1, i - 1) !~ /OPERATOR/) next
            rest = substr($0, i + 11); sub(/^[ \t]+/, "", rest); q = substr(rest, 1, 1)
            if (q != "\"" && q != "\047") next
            rest = substr(rest, 2); n = length(rest)
            for (k = 1; k <= n; k++)
                if (substr(rest, k, 1) == q && substr(rest, k + 1, 1) !~ /[A-Za-z0-9]/) { print substr(rest, 1, k - 1); break }
        }' "$1"
}

# Refuse a handover when an operator ruling quoted verbatim in the outgoing
# Results is on neither the outgoing `decisions:` line nor a decisions file
# that line names; every missing ruling is named.
# Args: outgoing doc, outgoing Live state.
check_rulings_recorded() {
    local outgoing="$1" live="$2" line hay q absent=""
    line="$(printf '%s\n' "$live" | sed -n 's/^decisions:[[:space:]]*//p' | head -n 1)"
    hay="$line"$'\n'"$(decisions_files_text "$line" "$(dirname "$outgoing")" 2>/dev/null)" || true  # swallow-ok: no readable decisions file leaves the line itself as the only record
    while IFS= read -r q; do
        [ -n "$q" ] || continue
        case "$hay" in *"$q"*) ;; *) absent="$absent  $q"$'\n' ;; esac
    done < <(verbatim_rulings "$outgoing")
    [ -n "$absent" ] || return 0
    err "refusing to hand over: $outgoing carries operator rulings (verbatim) that the decisions: line does not hold:"
    printf '%s' "$absent" >&2
    err "  add each to the decisions: line, or to the decisions file it names, then retry"
    return 1
}

# The chain order of <doc dir>/focus-chains.json as one line; nothing when the
# file is absent or unreadable.
# Args: dir.
chain_order_line() {
    [ -f "$1/focus-chains.json" ] || return 0
    python3 -c '
import json, sys
names = [c.get("name", "") for c in json.load(open(sys.argv[1], encoding="utf-8"))]
print("Chain order (focus-chains.json): " + "; ".join(n for n in names if n))' "$1/focus-chains.json" 2>/dev/null || true  # swallow-ok: an unreadable chains file leaves the block as the console wrote it
}

# Report the whole-span `<...>` placeholders still in a HANDOFF's facts header
# and start section (the Operator line, the root-sweep locks).
# Args: handoff file.
report_handoff_placeholders() {
    local left
    # shellcheck disable=SC2016  # the backticks are literal markdown code spans
    left="$(grep -n '`<[^`]*>`' "$1" 2>/dev/null)" || return 0  # swallow-ok: no match (or no file) means no placeholder to report
    err "warning: HANDOFF still has template placeholders ($1):"
    printf '%s\n' "$left" | sed 's/^/  /' >&2
}

# A decisions: line over CHIEF_DECISIONS_SPILL_BYTES (default 4096) is written
# byte for byte to a fresh specs/decisions/console-decisions-<date>[-N].md under
# <dir>, and a one-line pointer naming it, and every decisions file the line
# names, is printed instead, so the successor's handover still finds each ruling
# verbatim (decisions_kept_verbatim). A failed write prints the line unchanged.
# Args: decisions line, dir, predecessor name.
spill_decisions() {
    local line="$1" dir="$2" from="$3" base rel n=1 bytes names
    bytes="$(printf '%s' "$line" | wc -c | tr -d ' ')"
    [ "$bytes" -gt "${CHIEF_DECISIONS_SPILL_BYTES:-4096}" ] || { printf '%s\n' "$line"; return 0; }
    base="specs/decisions/console-decisions-$(date +%F)"
    rel="$base.md"
    while [ -e "$dir/$rel" ]; do n=$((n + 1)); rel="$base-$n.md"; done
    if mkdir -p "$dir/specs/decisions" && (set -C; printf '%s\n' "$line" > "$dir/$rel") 2>/dev/null; then
        names="$(printf '%s\n' "$line" | grep -o 'specs/decisions/console-decisions-[0-9-]*\.md' | sort -u | tr '\n' ' ')"
        printf 'decisions: carried verbatim in %s (%s bytes from %s; read it before ruling)%s\n' "$rel" "$bytes" "$from" "${names:+; it names ${names% }}"
    else
        err "warning: could not spill the decisions: line to $dir/$rel; carried it unchanged"
        printf '%s\n' "$line"
    fi
}

# The shift-spanning Live-state lines `next` copies verbatim into the
# successor doc; `epics:` and `decisions:` fall back to `none`, and an
# oversize `decisions:` line is spilled (spill_decisions).
# Args: live state, successor doc dir, predecessor name.
carried_live_state() {
    local live="$1" field line
    for field in epics decisions priority versions tracker-plan release rm focus-version focus-plan; do
        line="$(printf '%s\n' "$live" | grep -m 1 "^$field:")" || line=""
        case "$field" in epics|decisions) [ -n "$line" ] || line="$field: none" ;; esac
        [ "$field" != decisions ] || line="$(spill_decisions "$line" "$2" "$3")"
        [ -z "$line" ] || printf '%s\n' "$line"
    done
}

# One per-shift Live-state field of the predecessor, without its `<field>:`
# prefix: for `legs:`, the whole block tick.sh reads (the wrapped lines up to
# a blank, `word:`, list-marker, `>` or `#` line). Absent field -> empty.
seeded_live_field() {
    printf '%s\n' "$1" | awk -v k="$2:" -v block="$([ "$2" = legs ] && echo 1)" '
        !f && index($0, k) == 1 { f = 1; sub(/^[^:]*:[[:space:]]*/, ""); print; if (!block) exit; next }
        f && (/^[[:space:]]*$/ || /^[A-Za-z][A-Za-z ]*:/ || /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/ || /^[[:space:]]*[>#]/) { exit }
        f { print }
    '
}

# seed_live_fields <doc> <predecessor live state>: replace each `<field>: <...>`
# placeholder line in the doc's `## Live state` with the predecessor's value,
# verbatim; a field the predecessor lacks keeps its placeholder.
seed_live_fields() {
    local doc="$1" live="$2"
    SL_legs="$(seeded_live_field "$live" legs)" SL_queue="$(seeded_live_field "$live" queue)" \
    SL_last_GO="$(seeded_live_field "$live" "last GO")" SL_acked="$(seeded_live_field "$live" acked)" awk '
        $0 == "## Live state" { f = 1; print; next }
        f && /^## / { f = 0 }
        f && /^(legs|queue|last GO|acked): </ {
            name = substr($0, 1, index($0, ":") - 1); v = ENVIRON["SL_" (name == "last GO" ? "last_GO" : name)]
            if (v != "") { print name ": " v; next }
        }
        { print }' "$doc" > "$doc.seed" || { rm -f "$doc.seed"; err "could not seed the Live state into $doc"; exit 1; }
    mv "$doc.seed" "$doc"
}

# ACTION ZERO steps 2-6 run here, so the successor verifies their results
# instead of spending turns on them. Read-only: the successor acquires its own
# lock (step 8, --lock-only). The DOC section is dropped, the doc carries its
# own Live state, and so is C29: it must see the successor's own session,
# which does not exist yet. A failing run, or one cut at ACTION_ZERO_SECS
# (default 300), leaves an unavailable line, never stops next.
precompute_action_zero() {
    local doc="$1" az="${ACTION_ZERO_SCRIPT:-$kit/action-zero.sh}" out arc=0 tb
    tb="$(bash -c '. "$1" >/dev/null 2>&1; printf %s "$_TIMEOUT_BIN"' _ "$HERE/../../lib/timeout-bin.sh" 2>/dev/null)" # swallow-ok: no timeout binary = an unbounded run
    out="$(${tb:+"$tb" -k 2 "${ACTION_ZERO_SECS:-300}"} bash "$az" --doc "$doc" --root "$root" --prefix "$prefix" --repo "$repo" 2>&1)" || arc=$?
    out="$(printf '%s\n' "$out" | awk '/^== (DOC|C29)$/ { s = 1; next } /^== / { s = 0 } !s')"
    [ "$arc" -eq 0 ] || out="$out
unavailable (action-zero.sh exited $arc): run it yourself"
    AZ_BLOCK="### Pre-computed by chief.sh next at $(date -u +%Y-%m-%dT%H:%MZ)

Steps 2–6 ran when \`next\` wrote this doc: verify these results, do not re-run them.
Re-run action-zero.sh only if they are over 15 minutes old or a section reads
unavailable. C29 is left out (it must see your own session): run it in the
same batch as step 8, which is one call each:
\`bash \"$repo/scripts/himmel-doctor.sh\" --only C29\`
\`timeout 90 bash \"$kit/action-zero.sh\" --doc \"$doc\" --root \"$root\" --acquire --lock-only\`

\`\`\`text
$out
\`\`\`" awk '{ print } !d && /^## ACTION ZERO/ { print ""; print ENVIRON["AZ_BLOCK"]; d = 1 }
        END { if (!d) { print ""; print ENVIRON["AZ_BLOCK"] } }' "$doc" > "$doc.az" \
        || { rm -f "$doc.az"; err "could not write the pre-computed ACTION ZERO into $doc"; return 0; }
    mv "$doc.az" "$doc"
}

cmd_next() {
    [ -f "$console_template" ] || { err "missing template $console_template"; exit 2; }
    [ -f "$handoff_template" ] || { err "missing template $handoff_template"; exit 2; }

    local predecessor_doc predecessor_base predecessor_stem predecessor_prefix_part predecessor_letter predecessor_live_state predecessor_board predecessor_tracker
    predecessor_doc="$(resolve_predecessor)" || { err "no predecessor console doc found under $state_dir for '$name' — pass --doc <path>"; exit 1; }
    # An explicit --doc / CHIEF_DOC is used as given, with no existence
    # check inside resolve_predecessor (the auto-discovery branches already
    # only ever return a path that exists) — a typo with a plausible
    # basename must not be allowed to happily create a successor and a
    # HANDOFF for a console that was never there.
    if [ ! -f "$predecessor_doc" ]; then
        err "predecessor console doc does not exist: $predecessor_doc"
        exit 1
    fi
    # The predecessor's `## Live state` (nonces, lock
    # tokens, held queue, last GO) is seeded verbatim into the successor's own
    # Live state below, its one on-disk copy: the HANDOFF only points at it, so
    # the successor never re-copies authority-bearing state by hand and
    # `action-zero.sh --render-legs` finds every nonce it keeps. Absent section
    # -> empty string -> each field falls back to its template placeholder.
    predecessor_live_state="$(awk '
        $0 == "## Live state" { f = 1; print; next }
        f && /^## / { exit }
        f { print }
    ' "$predecessor_doc")"
    check_live_line_kept decisions DECISIONS-DROP "$predecessor_doc" "$predecessor_live_state" || exit 1
    check_live_line_kept priority PRIORITY-DROP "$predecessor_doc" "$predecessor_live_state" || exit 1
    check_rulings_recorded "$predecessor_doc" "$predecessor_live_state" || exit 6
    check_direction_real "$predecessor_doc" || exit 7
    # The outgoing direction rides into the successor doc and the HANDOFF; the
    # successor's block starts as the predecessor's (a stale one is not detected).
    local predecessor_direction
    predecessor_direction="$(direction_block "$predecessor_doc" | sed '/./,$!d')"
    # The console board's artifact URL rides on the `board:` line
    # of that Live state; the successor's own Live state starts from it, so it
    # updates the same artifact instead of minting a new one.
    predecessor_board="$(printf '%s\n' "$predecessor_live_state" | sed -n 's/^board:[[:space:]]*//p' | head -n 1)"
    case "$predecessor_board" in
        ""|"none yet"*) predecessor_board="none yet — publish it at ACTION ZERO step 12" ;;
    esac
    # The roadmap tracker's URL rides on `tracker:` the same way.
    predecessor_tracker="$(printf '%s\n' "$predecessor_live_state" | sed -n 's/^tracker:[[:space:]]*//p' | head -n 1)"
    [ -n "$predecessor_tracker" ] || predecessor_tracker="none"
    predecessor_base="$(basename "$predecessor_doc")"
    predecessor_stem="${predecessor_base%.md}"
    CHIEF_BUS_PREDECESSOR="$predecessor_stem"
    predecessor_prefix_part="${predecessor_stem%-"$name"}"
    if [ "$predecessor_prefix_part" = "$predecessor_stem" ]; then
        err "cannot parse predecessor doc name '$predecessor_base' (expected suffix '-$name.md')"
        exit 1
    fi
    if [[ "$predecessor_prefix_part" =~ ^.*-nextleg-[0-9]{4}-[0-9]{2}-[0-9]{2}([A-Z]{1,2})$ ]]; then
        predecessor_letter="${BASH_REMATCH[1]}"
    else
        err "cannot parse a letter from predecessor doc name '$predecessor_base'"
        exit 1
    fi
    # An explicit --date pre-mints a NEW day's chain (the whole point: a
    # 23:5x console at letter Z mints tomorrow's console immediately) and
    # starts that chain at "A". With no --date, the successor continues the
    # predecessor's own bijective sequence (Z -> AA -> ... -> ZZ) regardless
    # of whether the calendar day has actually rolled over since (case 15:
    # a predecessor dated yesterday still continues to today's next letter).
    local successor_letter
    if [ -n "$DATE_ARG" ]; then
        successor_letter="A"
    else
        successor_letter="$(next_letter "$predecessor_letter")" || { err "predecessor '$predecessor_base' is already at letter ZZ — no successor letter available (past ZZ)"; exit 1; }
    fi

    local doc="$state_dir/${prefix}-nextleg-${successor_date}${successor_letter}-${name}.md"
    local session="${prefix}-nextleg-${successor_date}${successor_letter}-${name}"
    # The Telegram inbox, resolved here (same default as
    # arm-resume.sh / bus.ts) so step 10/11 print a literal, runnable path.
    local inbox="${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}/consoles/${session}.md"
    # HANDOFF sits beside the predecessor's OWN doc, not in $state_dir — a
    # --doc pointing outside $state_dir (a different bucket, a different
    # root entirely) must still get its HANDOFF written next to it.
    local predecessor_dir predecessor_handoff predecessor_handoff_ref successor_doc_ref
    predecessor_dir="$(dirname "$predecessor_doc")"
    # Canonicalise: a RELATIVE --doc outside $state_dir would otherwise
    # leave predecessor_handoff_ref relative too, breaking the "absolute
    # reference" promise below the moment the successor is launched from a
    # different cwd. _arm_realpath (sourced via handover-path.sh) is the
    # repo's own portable realpath — GNU `realpath -m`, else python
    # pathlib, else unchanged — so this needs no GNU-only flag of its own.
    # Canonicalising also makes the state_dir comparison below robust to a
    # relative --doc that happens to point INSIDE state_dir.
    predecessor_dir="$(_arm_realpath "$predecessor_dir")"
    predecessor_handoff="$predecessor_dir/${predecessor_stem}-HANDOFF.md"
    # The successor doc must be able to actually RESOLVE this reference: a
    # bare basename only works when the HANDOFF sits in the successor's own
    # state_dir (the common case); a cross-bucket --doc needs the absolute
    # path, since the successor would otherwise look for it next to itself
    # and never find it.
    if [ "$predecessor_dir" = "$state_dir" ]; then
        predecessor_handoff_ref="$(basename "$predecessor_handoff")"
        successor_doc_ref="$(basename "$doc")"
    else
        predecessor_handoff_ref="$predecessor_handoff"
        successor_doc_ref="$doc"
    fi
    local fill_signal="$chain_dir/sig-$session"
    local log="$chain_dir/launch-$session.log"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "would-doc: $doc"
        echo "would-session: $session"
        if [ -f "$predecessor_handoff" ]; then
            echo "would-handoff: $predecessor_handoff (exists — left unchanged)"
        else
            echo "would-handoff: $predecessor_handoff"
        fi
        if [ -n "$project_dir" ]; then
            echo "would-project: $project_dir"
        fi
        launch_line=$(launch_cmd "$session" "$doc") || exit $?
        echo "would-launch: $launch_line"
        if [ "$ARM" -eq 1 ]; then
            echo "would-armed: name=$session doc=$doc signal=$fill_signal deadline=$deadline_epoch log=$log"
            echo "would-arm-log: $log"
        fi
        return 0
    fi

    # The successor doc is never re-rendered once it exists: unlike the
    # HANDOFF just below (existence-guarded) and `new` (which bumps the
    # letter), a second `next --doc <same predecessor>` would otherwise
    # silently destroy whatever the successor already wrote. Claimed the
    # same atomic-exclusive-create way `new` claims a letter (closes the
    # same check-then-write race), but a collision here is an ERROR, not an
    # advance — `next` computes exactly one successor letter, never a range
    # to retry across.
    mkdir -p "$state_dir"
    set -C
    if ! : 2>/dev/null > "$doc"; then
        set +C
        err "successor doc already exists, refusing to re-render it: $doc"
        exit 1
    fi
    set +C

    # This invocation owns the exclusively claimed stub. Any abort before
    # both renders finish (including render_template's exit) must remove it
    # so a repaired template or directory can be retried without hand cleanup.
    trap 'rm -f "$doc"' EXIT

    # `next` never acquires a lock itself (the successor takes its own at
    # ACTION ZERO) — so, unlike `new`, there is no real token to carry here.
    # An honest, explicit placeholder rather than an empty string: the
    # successor's own ACTION ZERO acquires and records it, exactly as the
    # console-template's own instructions already tell it to.
    # Carry the predecessor's fleet manifest to the successor's
    # stem so its waiter can start with --legs-from and keep watching the same
    # legs. A COPY, not a rename: the outgoing console's waiter still reads
    # its own until that console releases. No manifest = no-op.
    local predecessor_manifest successor_manifest manifest_note
    predecessor_manifest="$predecessor_dir/${predecessor_stem}.fleet.json"
    successor_manifest="${doc%.md}.fleet.json"
    manifest_note="none carried (the predecessor had no manifest); create it with fleet-manifest.sh add"
    if [ -f "$predecessor_manifest" ]; then
        cp "$predecessor_manifest" "$successor_manifest" || { err "could not copy fleet manifest $predecessor_manifest to $successor_manifest"; exit 1; }
        manifest_note="carried from the predecessor, already in place: start the waiter with --legs-from on it"
    fi
    render_template "$console_template" "$doc" \
        FLEET_MANIFEST "$successor_manifest" \
        FLEET_MANIFEST_NOTE "$manifest_note" \
        LETTER "$successor_letter" \
        PREDECESSOR "$predecessor_base" \
        PREDECESSOR_HANDOFF "$predecessor_handoff_ref" \
        SESSION_NAME "$session" \
        INBOX "$inbox" \
        HANDOVER_ROOT "$root" \
        STATE_DIR "$state_dir" \
        REPO "$repo" \
        PREFIX "$prefix" \
        BUCKET "$bucket" \
        KIT "$kit" \
        FILL_SIGNAL "$fill_signal" \
        FILL_PERCENT "$fill_percent" \
        RELEASE_TOKEN "none yet — acquire your own at ACTION ZERO and record it here" \
        BOARD_URL "$predecessor_board" \
        TRACKER_URL "$predecessor_tracker" \
        CARRIED_LIVE_STATE "$(carried_live_state "$predecessor_live_state" "$(dirname "$doc")" "$predecessor_base")" \
        CARRIED_DIRECTION "$predecessor_direction" \
        MODEL "$model" \
        PROJECT "$project_doc_value"
    seed_live_fields "$doc" "$predecessor_live_state"
    precompute_action_zero "$doc"

    echo "doc: $doc"
    echo "session: $session"

    # Same class as the successor-doc race: a
    # plain `[ -f ]` check here is check-then-write, so two concurrent
    # `next` runs targeting DIFFERENT successor buckets but the SAME
    # predecessor (e.g. both via --doc) could both see "missing" and both
    # render, the second clobbering the first's HANDOFF. Claimed the same
    # exclusive-create way — but unlike the successor doc, losing the claim
    # here is NOT an error: an existing HANDOFF is deliberately left
    # unchanged and reported, exactly as before.
    set -C
    if : 2>/dev/null > "$predecessor_handoff"; then
        set +C
        # Every mechanically derivable field is filled here so the
        # outgoing console writes only its judgement notes (one Edit), not
        # ~18 turns of hand derivation. Each fact fails open to "unavailable".
        local facts="$HERE/../console-kit/handoff-facts.sh"
        local hf_legs hf_prs hf_summary hf_slug hf_total hf_note hf_budget="${HANDOFF_BUDGET_BYTES:-6000}"
        hf_legs="$(bash "$facts" legs "$predecessor_doc" --repo "$repo")"
        hf_prs="$(bash "$facts" prs "$predecessor_doc" --repo "$repo")"
        hf_summary="$(bash "$facts" summary "$predecessor_doc" --repo "$repo")"
        # ponytail: the cap trims only the re-derivable fact sections; the rulings and the wrapped-PR list stay inline even over budget, an oversized wrapped-PR list needs its own pointer.
        local hf_pass=1 hf_wrapped hf_wrapped_bytes hf_chain hf_direction
        hf_chain="$(chain_order_line "$predecessor_dir")"
        hf_direction="${hf_chain:+$hf_chain
}$predecessor_direction"
        hf_wrapped="$(wrapped_open_prs_section "$predecessor_doc")"
        hf_wrapped_bytes="$(printf '%s\n' "$hf_wrapped" | wc -c)"
        while :; do
            render_template "$handoff_template" "$predecessor_handoff" \
                CURRENT_DIRECTION "$hf_direction" \
                HEAD_LINE "$(bash "$facts" head "$predecessor_doc" --repo "$repo")" \
                BANK_LINE "$(bash "$facts" bank "$predecessor_doc" --repo "$repo")" \
                WORKER_SESSION_LIST "$hf_legs" \
                OPEN_PRS "$hf_prs" \
                SHIFT_SUMMARY "$hf_summary" \
                QUEUE_LINE "$(bash "$facts" queue "$predecessor_doc" --repo "$repo")" \
                LAST_GO "$(bash "$facts" lastgo "$predecessor_doc" --repo "$repo")" \
                JUDGE_CALLS "$(judge_calls_now)" \
                PREDECESSOR_LETTER "$predecessor_letter" \
                LETTER "$successor_letter" \
                PREDECESSOR "$predecessor_base" \
                SUCCESSOR_DOC "$successor_doc_ref" \
                REPO "$repo" \
                BUCKET "$bucket" \
                KIT "$kit" \
                LIVE_STATE "Live state: seeded into \`$successor_doc_ref\`"
            # Over budget: the bulky fact sections (all re-derivable) become
            # pointers; the rulings stay inline.
            [ "$hf_pass" -eq 1 ] && [ $(( $(wc -c < "$predecessor_handoff") + hf_wrapped_bytes )) -gt "$hf_budget" ] || break
            hf_pass=2
            hf_legs="over the HANDOFF size budget — run: bash $facts legs $predecessor_doc --repo $repo"
            hf_slug="$(git_clean -C "$repo" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|[a-z+]+://[^/]+/)##; s#\.git$##')" || hf_slug=""  # swallow-ok: an unreadable remote falls back to the <owner/repo> placeholder in the pointer
            hf_prs="over the HANDOFF size budget — run: gh pr list -R ${hf_slug:-<owner/repo>} --state open"
            hf_summary="over the HANDOFF size budget — read the tail of $predecessor_doc ## Results"
        done
        [ -z "$hf_wrapped" ] || printf '%s\n' "$hf_wrapped" >> "$predecessor_handoff"
        # Still over budget after the pointer pass: the remainder is the rulings
        # and the wrapped-PR list, which are never trimmed — say so loudly.
        hf_total="$(wc -c < "$predecessor_handoff")"
        if [ "$hf_total" -gt "$hf_budget" ]; then
            hf_note="HANDOFF over budget: $hf_total bytes (limit $hf_budget); wrapped-PR list $hf_wrapped_bytes bytes"
            printf '\n> %s\n' "$hf_note" >> "$predecessor_handoff"
            err "warning: $hf_note"
        fi
        report_handoff_placeholders "$predecessor_handoff"
        echo "handoff: $predecessor_handoff"
    else
        set +C
        # `: >` under noclobber fails for ANY reason, not just a genuine
        # collision — including a non-writable predecessor directory. Only
        # a REAL pre-existing file gets the "left unchanged" treatment; any
        # other failure means the create never happened for a real reason,
        # so this must abort (before the launch line and before any arm)
        # rather than silently claim a HANDOFF exists when it does not —
        # the successor would otherwise launch without its only required
        # read.
        if [ -f "$predecessor_handoff" ]; then
            report_handoff_placeholders "$predecessor_handoff"
            echo "handoff: $predecessor_handoff (exists — left unchanged)"
        else
            err "could not create HANDOFF at $predecessor_handoff — this is not a collision (the file does not exist); check permissions on $(dirname "$predecessor_handoff")"
            exit 1
        fi
    fi
    # Resolved BEFORE the cleanup trap is cleared, so a profile
    # refusal (exit 2) removes the claimed successor doc and a retry is not
    # blocked by "successor doc already exists".
    launch_line=$(launch_cmd "$session" "$doc") || exit $?
    trap - EXIT
    console_metadata "$inbox"
    echo "launch: $launch_line"
    # Handover mode for the OUTGOING console's waiter, set only now
    # that the successor doc, HANDOFF and launch line all validated. The marker
    # sits beside the predecessor's inbox (console-wait.sh reads it): its waiter
    # keeps delivering Telegram lines but stops tick/bank/page sampling, so an
    # outgoing console merely waiting for LIVE takes no tick wakes. Best-effort:
    # a failed write leaves the waiter as it was.
    local pred_inbox
    pred_inbox="${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}/consoles/${predecessor_stem}.md"
    if mkdir -p "$(dirname "$pred_inbox")" 2>/dev/null && printf '%s\n' "$session" > "$pred_inbox.handover" 2>/dev/null; then
        echo "handover-mode: $pred_inbox.handover"
        # --relay-on-live: the outgoing waiter wakes its console once, when the successor
        # holds its lock, with the relay lines (line 1 successor session, line 2 its doc).
        # A console with a bus identity always gets it: the legs' bus adopt needs the bus
        # record relay-batch.sh sends, which a hand relay never does.
        # Written to a temp name then renamed, so the waiter never reads half a marker.
        if { [ "$RELAY_ON_LIVE" -eq 1 ] || [ -n "${HIMMEL_BUS_NAME:-}" ]; } && printf '%s\n%s\n' "$session" "$doc" > "$pred_inbox.relay-on-live.tmp" 2>/dev/null \
            && mv -f "$pred_inbox.relay-on-live.tmp" "$pred_inbox.relay-on-live" 2>/dev/null; then
            echo "relay-on-live: $pred_inbox.relay-on-live"
        fi
    fi

    if [ "$ARM" -eq 1 ]; then
        do_arm "$session" "$doc" "$fill_signal" "$log"
    fi
}

case "$CMD" in
    new) cmd_new ;;
    next) cmd_next ;;
esac
