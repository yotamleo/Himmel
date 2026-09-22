#!/usr/bin/env bash
# scripts/handover/headed-arm.sh - launch a HEADED successor session (a konsole
# window with a real TTY) when a signal file appears OR a hard deadline passes,
# whichever comes first.
#
# WHY HEADED (HIMMEL-2534): a leg launched through `at` has no TTY, and such a
# session exits at the first idle cross-session message - five legs were lost
# that way on 2026-09-05. A headed window survives, and the operator can watch
# the context threshold.
#
# WHY THE env -u (HIMMEL-2545): claude exports CLAUDE_CODE_CHILD_SESSION=1 and
# CLAUDE_PID into every process it spawns, so a session launched from inside a
# claude tool call inherits a THROWAWAY-CHILD marker: transcript saving off,
# `scripts/context-fill.sh` blind (rc=4), no armed-resume archaeology, nothing
# for the luna session-capture hook. Every console and leg of the 2026-09-05
# night run was launched that way. The launch below clears both and forces
# persistence ON. CLAUDE_PID is the HIMMEL-2514 sibling: the launched session
# must not inherit the launcher's pid either. CLAUDE_CODE_SESSION_ID is a
# third clear in the same family (round 6): claude generates its OWN id and
# exports the correct one to its own tool subprocesses regardless, so this
# never affected context-fill.sh - but the launched claude PROCESS's own
# environ still carried the ARMING session's stale id until cleared, which
# is exactly the surface this ticket taught people to inspect
# (/proc/<claude pid>/environ) and actively misled that inspection.
#
# Usage:
#   headed-arm.sh <session-name> <handover-doc> <signal-file> <deadline-epoch> \
#                 <log> [model] [context: 1m|standard]
# [context] (HIMMEL-2658, default flipped by HIMMEL-2973): arming-time
# context-window choice, same two measured levers as
# scripts/handover/arm-resume.sh's --context (the [1m] model-id suffix,
# silently a no-op on a Fable-family model, and the actual cost-driving
# --autocompact auto|200000). Defaults to `standard` (200000): the 2026-09-12
# cost audit found Fable consoles launched with the old 1m default averaging
# 241-275k tokens/turn, ~40% of a console's context per shift, so 1m context
# now requires CONSOLE_CONTEXT=1m set in the LAUNCHING shell -- an explicit
# operator opt-in, refused otherwise (same shape as the HIMMEL-2779 leg-side
# REQUIRED_AUTOCOMPACT refusal below).
# Run detached, so it outlives the session that armed it:
#   setsid nohup bash scripts/handover/headed-arm.sh ... >/dev/null 2>&1 &
#
# Platform guard (gitbash-only): POSIX bash 3.2+ plus a terminal emulator -
# konsole on Linux/KDE, and on macOS (HIMMEL-2534) the konsole-macos.sh shim
# this defaults to there, which translates the SAME konsole argv into the
# house `open -a <App> <file>.command` launch arm-resume.sh already uses.
# macOS has no /proc, so the confirmation read degrades to a lossy scan -
# see session_confirmed() below. No .ps1 twin - the Windows station arms through
# scripts/handover/arm-resume.sh's schtasks backend, which carries the same
# HIMMEL-2545 clears in its generated .bat. This marker sits ABOVE the
# exit-code table below, rather than after it: that table gains an entry
# almost every CR round and would otherwise keep pushing this marker toward
# (and eventually past) the first 60 lines of the file, the window
# scripts/parity/test-ws5-invariants.sh's T15 check scans for one - it has
# already done so twice.
#
# Exit codes: 2 usage / bad argument; 3 no konsole on PATH; 13 (HIMMEL-2534
# CR fix, N346) could not resolve this script's own directory to locate the
# macOS konsole shim, a distinct failure from 3 above; 4 no pgrep on
# PATH (see codex-4 below); 5 the claim-lock root could not be created (see
# r2-codex-2 below - an environment fault, never a dedup hit); 6 the claim
# retry budget was exhausted without ever confirming a running session (see
# r3-codex-1 below - an UNRESOLVED arm, never a dedup hit either); 7 konsole
# survived its settle but the named session never became visible to pgrep
# within the post-launch budget (see r4-codex-1 below - UNCONFIRMED, never
# a confirmed launch either); 8 a claimed lock's "acquired" stamp could not
# be written (see r4-codex-3 below - an unstampable lock is refused rather
# than held); 9 a pgrep scan itself failed (rc>1, a usage or fatal error,
# never a genuine no-match) at ANY of the four session_confirmed() call
# sites (see r8-codex-3 below - an INDETERMINATE scan, refused rather than
# read as either "nothing running" or "confirmed"); 1 the launch itself
# failed - cd into REPO failed, OR the terminal pid was never confirmed
# alive by session_confirmed AND the pid itself is also gone (see codex-1
# and r8-codex-4 below: a dead pid ALONE is no longer sufficient, since
# konsole can hand off to an already-running instance and exit after a
# SUCCESSFUL launch); 0 armed, and either launched or correctly deduped (a
# real pgrep-confirmed running session - including one that appeared after
# this arm claimed the lock, see r7-codex-2, or one confirmed despite the
# launcher's own pid having already exited, see r8-codex-4 - or a genuine
# successful launch this run made AND confirmed).
#
# CR PANEL FIXES ROUND 1 (HIMMEL-2545 follow-up, all four AGREED):
#  - codex-1: backgrounding the konsole launch used to be reported successful
#    UNCONDITIONALLY (`... &`; log "launched"; exit 0). A konsole that dies
#    immediately (no DISPLAY, a bad invocation) silently lost the armed
#    successor while this script still exited 0 -- defeating its entire
#    purpose. The pid is now settled briefly and checked alive (`kill -0`)
#    before the success line is written; a dead process is a loud failure.
#  - codex-2: the pgrep dedup below is a non-atomic check-then-launch -- two
#    arms racing on the exact same NAME could both see "no match" and open
#    duplicate windows. An atomic `mkdir` claim (this repo's convention --
#    "claim by atomic mkdir, never scan-then-create") now sits between the
#    pgrep check and the launch. See the STALE-LOCK POLICY comment at the
#    claim site for what happens to a lock left by a crashed arm.
#  - codex-3: $NAME reached pgrep's -f ERE unescaped, so a name carrying
#    regex metacharacters (`.`, `(`, `|`, ...) could false-match an unrelated
#    session or false-miss its own. It is now ERE-escaped first, so the
#    match is on the literal name in both directions.
#  - codex-4: $PGREP was never availability-checked, unlike $KONSOLE right
#    above it. A missing pgrep used to fail the dedup call rc=127, which
#    reads exactly like "no matching session" and silently disabled dedup --
#    failing OPEN into duplicate windows. It is now checked the same way
#    konsole is, and refuses closed with a distinct exit code.
#
# CR PANEL FIXES ROUND 2 (four of five findings landed here; the fifth,
# treating an EMPTY CLAUDE_CODE_FORCE_SESSION_PERSISTENCE value as absent,
# is context-fill.sh's fix, not this file's -- prefixed r2-codex-N below to
# avoid colliding with round 1's codex-N labels on DIFFERENT findings):
#  - r2-codex-1 (CRITICAL): the round-1 stale-lock reclaim
#    (`rm -rf "$LOCK"; mkdir "$LOCK"`) was ITSELF non-atomic -- two
#    reclaimers could both classify the same lock stale, and whichever
#    finished its rm+mkdir SECOND would silently remove the FIRST one's
#    brand-new lock and create its own, so both believed they held it: the
#    exact duplicate window the lock exists to prevent. Fixed with an
#    atomic `mv`-based steal (see steal_stale_lock below) -- rename(2) lets
#    exactly one racer win, the other gets ENOENT and must not proceed.
#  - r2-codex-2 (CRITICAL): `mkdir -p "$LOCKDIR"`'s result used to be
#    discarded, so an unwritable/unavailable lock root made every `mkdir
#    "$LOCK"` fail exactly like a genuine concurrent claim -- the script
#    logged "already claimed" and exited 0, silently skipping a launch
#    nobody actually claimed. Now checked, with its own distinct exit 5.
#  - r2-codex-3 (IMPORTANT): a contender that found the lock held used to
#    exit 0 immediately, never learning what the holder did. Now retries
#    the claim for a couple of seconds (never the stale timeout) before
#    giving up -- a lock that clears with a real session running is a
#    genuine dedup; one that clears with nothing running means the holder
#    failed and this arm takes over the launch.
#
# CR PANEL FIXES ROUND 3 (three of four findings landed here; the fourth,
# aligning himmel-doctor.sh's C29 with context-fill.sh's empty-value
# contract, is that file's fix, not this file's; a fifth, tightening the
# test suite's race assertion, is test-headed-arm.sh's fix):
#  - r3-codex-1 (IMPORTANT): exhausting the r2-codex-3 retry budget used to
#    exit 0 -- the SAME code as a genuine pgrep-confirmed dedup. A holder
#    that crashes while its lock is still FRESH (age < STALE_LOCK_SECS)
#    cannot be stolen from for 120s (extending the retry to match would be
#    worse: a 120s block), so a contender that gives up after ~2s without
#    ever seeing pgrep confirm a session has NOT deduped against anything
#    real -- the armed successor may be genuinely lost. Now a distinct,
#    non-zero exit 6, never sharing an outcome with a confirmed dedup.
#  - r3-codex-2 (IMPORTANT): the lock used to be released the instant
#    konsole survived its 0.3s settle, before the named claude process was
#    actually visible to pgrep. During a slow terminal/claude startup,
#    another contender could claim the freed lock in that window and
#    launch a genuine duplicate. Now polls pgrep for the same literal-name
#    match on a bounded budget (SESSION_VISIBLE_RETRY_ITERS/SLEEP) before
#    releasing; releases anyway if the budget expires (holding forever is
#    worse), but logs a slow start plainly rather than staying silent.
#
# CR PANEL FIXES ROUND 4 (three of four findings landed here; the fourth is
# DEFERRED to HIMMEL-2558, not fixed in this PR - see below):
#  - r4-codex-1 (CRITICAL): the r3-codex-2 post-launch poll expiring used to
#    log a WARNING and still exit 0 -- the SAME code as a confirmed launch.
#    A konsole that survives its settle but whose claude child then fails
#    (or never appears) was reported as a successfully armed successor when
#    no session exists. Now a distinct, non-zero exit 7; the lock is still
#    released either way (holding it forever remains worse). RESOLVED IN
#    FAVOUR OF LOUDNESS: a genuinely slow start now also reports failure,
#    deliberately - a claude process appears in pgrep at exec time, long
#    before it finishes loading, and the post-launch budget is already
#    ~5s, so a miss that long is suspicious, not routine.
#  - r4-codex-3 (IMPORTANT): `date +%s > "$LOCK/acquired" || true` used to
#    discard its own failure. An unstamped lock is read by claim_lock()'s
#    own case statement as "not stale by definition", so it could NEVER be
#    reclaimed - a permanent wedge for this session name, reached through
#    the stale-lock policy's own bookkeeping. Now checked (stamp_or_fail_
#    loudly): a failed stamp write removes the lock and exits 8 rather than
#    holding an unstampable one.
#  - r4-codex-4 (SUGGESTION): test-himmel-doctor.sh's own fix, not this
#    file's - a leaked temp dir in that suite, now cleaned up on exit.
#  - r4-codex-2 (deferred to HIMMEL-2558, not fixed in this file): the
#    best-effort restore in steal_stale_lock (`mv "$victim" "$LOCK"` when
#    the stolen stamp does not match) can itself lose a race, orphaning the
#    real holder's lock so that its later release deletes a DIFFERENT
#    arm's lock. The lock's identity lives in its PATH, not in its own
#    contents, so a restore that loses the mv race cannot tell "put back
#    the lock I displaced" apart from "a different arm's lock now occupies
#    this path" - closing that gap needs identity carried inside the lock
#    itself, which is a redesign of the primitive, tracked as HIMMEL-2558.
#
# CR PANEL FIXES ROUND 6 (the only finding landed here; the other is the
# HIMMEL-2558 deferral re-raised, unchanged, not fixed in this file):
#  - r6-codex-2 (security hardening): the lock root used to default to a
#    PREDICTABLE, SHARED path under /tmp - another local user on the same
#    host could pre-create it (as a directory they own, or a symlink) and
#    every lock operation would then happen inside a directory this
#    process does not control. Now prefers $XDG_RUNTIME_DIR (per-user 0700
#    on systemd hosts already) and otherwise falls back to a uid-qualified
#    path under ${TMPDIR:-/tmp}, created 0700; the resulting root - and an
#    explicit HEADED_ARM_LOCK_DIR override, identically - is then VALIDATED
#    (not a symlink, owned by this user, not group/world-writable) before
#    anything is claimed inside it. See the validation block at the claim
#    site for the exact checks.
#
# CR PANEL FIXES ROUND 7 (fresh critic model, on code six earlier rounds had
# already reviewed - both findings land here; the other two re-raise the
# HIMMEL-2558 deferral, unchanged, not fixed in this file):
#  - r7-codex-1 (IMPORTANT, and worse than that severity suggests: it made
#    two EARLIER fixes vacuous): `pgrep -f` matches the FULL command line,
#    and konsole's OWN argv literally quotes the whole claude invocation it
#    was told to run (`konsole ... -e env -u ... claude --model X -n NAME
#    "load ..."`), so the dedup/visibility pattern below matched konsole's
#    OWN process, not the claude process it spawns. That meant the
#    post-launch visibility poll (r3-codex-2) confirmed a session the
#    instant konsole itself appeared in pgrep - essentially instantly - so
#    r4-codex-1's exit 7 for a never-confirmed launch could almost never
#    fire, and the dedup layers could likewise be satisfied by a surviving
#    terminal with no claude inside it. Same class this repo's own
#    himmel-doctor.sh C29 check already guards against: a launcher whose
#    argv quotes the claude command is not a claude session. Fixed the same
#    way - see session_confirmed() below.
#  - r7-codex-2 (IMPORTANT): checking pgrep only BEFORE acquiring the lock
#    still allowed a duplicate: a contender sees no session, is
#    descheduled, the holder launches and releases, then the contender
#    acquires the now-freed lock and launches anyway. Now re-checked
#    immediately AFTER acquiring the lock, before konsole is ever touched -
#    see the recheck right after the claim retry loop below.
#
# CR PANEL FIXES ROUND 8 (0 Critical; both findings land here - the other
# two re-raise the HIMMEL-2558 deferral, unchanged, not fixed in this file):
#  - r8-codex-4 (filed a Suggestion, treated as the important one - a real
#    launch bug, verified on this machine: `konsole --help` genuinely lists
#    `--separate`/`--nofork` as opt-in): the success check assumed the
#    konsole process backgrounded above stays alive, but konsole can hand
#    off to an ALREADY-RUNNING instance and let the pid this script
#    backgrounded exit immediately - on any station with a konsole already
#    open, that turns a SUCCESSFUL hand-off into `kill -0` failing, which
#    used to be read as FAILED (exit 1) on a launch that actually worked -
#    the exact inversion of round 4's fix. Fixed both halves: (1) `konsole`
#    is now invoked with `--separate`, so the pid backgrounded here is
#    genuinely its own process, not a hand-off target, and the pid check
#    means something again; (2) even so, a dead pid is no longer treated as
#    failure ON ITS OWN - the post-launch session_confirmed() poll now
#    always runs regardless of whether the pid still looks alive at the
#    0.3s settle point, and only "never confirmed AND the pid is also gone"
#    reaches the exit-1 FAILED branch. This keeps the check robust even
#    against a future konsole that ignores the flag.
#  - r8-codex-3 (IMPORTANT): session_confirmed() folded EVERY pgrep failure
#    into "no match" (`|| return 1`), but pgrep exits 1 for a genuine
#    no-match and 2 or 3 for a usage or fatal scan error - a broken scan
#    then silently read as "nothing running" and bypassed dedup. Same
#    principle this file has now applied five times over: an indeterminate
#    answer must never be reported as a confirmed one. session_confirmed()
#    now distinguishes rc 1 (return 1, genuinely not running) from rc > 1
#    (return 2, the scan itself failed); every one of its four call sites
#    refuses with a new, distinct exit 9 on the latter rather than treating
#    it as either a dedup hit or a green light to launch.
#
# CR PANEL FIXES ROUND 9 (0 Critical; the one Suggestion lands here because
# it deletes a whole class rather than patching an instance - the two
# Importants re-raise the HIMMEL-2558 deferral, unchanged, not fixed in
# this file):
#  - r9-codex-3 (SUGGESTION, taken anyway): `pgrep -f` matches a FLATTENED
#    command line, so an unrelated claude session whose PROMPT happened to
#    contain "-n <our name> ", or whose OWN name merely had ours as a
#    prefix, could satisfy the dedup pattern and silently suppress a launch
#    that should have happened. Fixed by requiring a POSITIONAL, EXACT
#    match against the real NUL-separated argv (see _argv_has_n_name and
#    the r9-codex-3 note above session_confirmed()) rather than trusting
#    that a flattened-string match means `-n NAME` was actually an option.
#
# CR PANEL FIXES ROUND 10 (0 Critical; both findings land here - the other
# two re-raise the HIMMEL-2558 deferral, unchanged, not fixed in this
# file):
#  - r10-codex-3 (IMPORTANT): $LOG and the lock root are both used AFTER
#    `cd "$REPO"` - the konsole redirect, every status line, and the
#    post-launch `rm -rf "$LOCK"` cleanup on every exit path. A RELATIVE
#    $LOG silently started writing somewhere else (or failed outright), and
#    a relative HEADED_ARM_LOCK_DIR override made the cleanup target a path
#    that no longer resolved to where the lock actually lived - LEAKING it,
#    blocking every arm for that name until the stale timeout: the exact
#    failure mode this file has spent four rounds keeping out, arriving
#    through a path nobody was looking at. Both now resolved to absolute
#    before anything can cd - see the r10-codex-3 notes at each variable's
#    own construction site (right after REPO is set, and right after
#    LOCKDIR is computed) for the resolution mechanism and why SIGNAL and
#    DOC do not need the same treatment.
#  - r10-codex-4 (SUGGESTION, taken anyway): the pgrep candidate pattern
#    required a trailing space after the name, so a command line that
#    ENDS at the name (no trailing prompt argument) was filtered out
#    before the exact argv check ever saw it, and could receive a genuine
#    duplicate successor. Now that the positional argv walk is
#    authoritative, the pre-filter is permissive rather than precise -
#    see the r10-codex-4 note above _argv_has_n_name.
#
# Seams (tests only): KONSOLE_CMD / PGREP_CMD pin the two external binaries by
# name so a suite can shim them on PATH; HEADED_ARM_REPO overrides the repo
# root this otherwise derives from its own location; HEADED_ARM_LOCK_DIR
# overrides the durable per-name claim-lock root (default: $XDG_RUNTIME_DIR
# if set, else a uid-qualified path under ${TMPDIR:-/tmp} - see r6-codex-2
# below) so a suite can point it at a throwaway directory - the override is
# validated exactly like the default is, never a way around that check;
# HEADED_ARM_STALE_HOOK (a no-op by default) is invoked right after a lock
# is classified stale but before it is stolen, so a suite can
# deterministically interleave two real
# contenders at the exact race window (see r2-codex-1 below);
# HEADED_ARM_PROC overrides the procfs root session_confirmed() reads each
# candidate pid's comm from (default: /proc - see r7-codex-1 below), so a
# suite can point a matched pid at a fixture comm without a genuinely
# running claude process.
#
# HIMMEL-2782: HEADED_ARM_LAUNCHER overrides the binary the konsole tab
# execs (default: claude, PATH-resolved - unchanged for every existing
# caller). HEADED_ARM_LAUNCHER_ENV is a space-separated list of extra
# NAME=VALUE tokens (same "no spaces inside a value" contract as
# codex-bank-probe.ts's CODEX_BANK_PROBE_CMD) added to the `env` command
# ahead of the launcher, for a lane that needs its own opt-in/effort env
# (e.g. the claudex lane's CLAUDEX_LANE_OK=1). HEADED_ARM_RECORDER=1 wraps
# the launcher in `script -q -f "$LOG" -c ...` instead of execing it
# directly: konsole's own `-e` output is otherwise lost, and a launcher
# whose own child can die silently (the codex proxy path) leaves no trace
# at all - measured on the claudex pilots (N41b: no process, empty log).
# The default launcher keeps the plain exec (unchanged argv shape - every
# existing test asserts its exact form) since it has never shown this
# failure mode; only a caller that sets HEADED_ARM_RECORDER=1 pays for the
# extra tty layer.
#
# --role (HIMMEL-2975, renamed HIMMEL-3133; HIMMEL-3136 R1): an optional
# leading `--role console` flag, ahead of the positionals, for the console arm
# path only. `console` clears HIMMEL_CONSOLE_RELAY from the child env (so a
# console session never inherits a relay marker from whatever armed it) and
# stamps `role=console` on the `armed:` log line. It is the ONLY accepted
# value: a relay is a LEG, armed via headed-arm-leg.sh --relay (Task 25,
# #752), never through this console-oriented launcher, so it is not a role
# here. Omitting --role keeps today's behaviour byte-identical
# (`role=unsplit` on the log line, no env change).
#
# --dry-run (HIMMEL-3140): prints the resolved argv this would hand to
# konsole, plus the env it would apply, and exits 0 -- BEFORE the
# signal/deadline wait loop, the dedup pgrep scan, the claim lock, or konsole
# are ever touched. Every usage/argument validation below (usage-arity,
# --role, context, the placeholder-name refusal, the NAME/DEADLINE shape
# checks, and konsole/pgrep PATH availability) still runs first and can still
# exit non-zero -- --dry-run only skips the parts that actually cost a real
# launch. WHY: proving this launcher accepts a flag or a resolved argv used
# to mean a REAL billed konsole+claude launch, twice (N279, N13-of-3133) --
# second occurrence, structural seam.
set -u

usage() {
    echo "usage: headed-arm.sh [--dry-run] [--role console] <session-name> <handover-doc> <signal-file> <deadline-epoch> <log> [model] [context: 1m|standard]" >&2
}

ROLE=""
DRY_RUN=0
while :; do
    case "${1:-}" in
        --dry-run) DRY_RUN=1; shift ;;
        --role)
            if [ "$#" -lt 2 ]; then
                usage
                exit 2
            fi
            ROLE="$2"
            case "$ROLE" in
                console) : ;;
                *)
                    usage
                    echo "headed-arm.sh: --role must be console, got: $ROLE" >&2
                    exit 2
                    ;;
            esac
            shift 2
            ;;
        *) break ;;
    esac
done

if [ "$#" -lt 5 ]; then
    usage
    exit 2
fi

# HIMMEL-2975 T6: resolved from $0, NOT $HEADED_ARM_REPO -- tests point that
# override at a synthetic tmp repo with no scripts/lib of its own, and this
# script's own source location never moves with it.
. "$(cd "$(dirname "$0")" && pwd)/../lib/console-context.sh"

# HIMMEL-3079: the console parent defaults to Opus (default parent tier);
# Fable is the escalation target, reached only via an explicit [model].
NAME="$1"; DOC="$2"; SIGNAL="$3"; DEADLINE="$4"; LOG="$5"; MODEL="${6:-claude-opus-5-5}"
# HIMMEL-2973 (default re-pinned by HIMMEL-2975 T6, resolution now shared
# via scripts/lib/console-context.sh): --context resolution, arming-time
# only (see the header comment above). Defaults to `standard`
# (--autocompact 200000): the console arm path is the largest cache-read
# cost driver on the fleet (2026-09-12 cost audit), so 1m is now an explicit
# operator opt-in via CONSOLE_CONTEXT=1m in the LAUNCHING shell, never the
# bare default. $#-ge 7 (not just "${7:-}" non-empty) is what distinguishes
# an explicit empty-string 7th positional from "omitted" for the log line
# below -- nothing currently passes an empty string here, but the
# distinction costs nothing and matches how arm-resume.sh tells explicit
# from default. This launcher is always console-class (is_console=1) --
# it has no non-console callers, unlike arm-resume.sh's handover-name test.
if [ "$#" -ge 7 ]; then
    CONTEXT="$7"
    _headed_context_source=$(console_context_source_label 1)
else
    console_context_default 1 "${CONSOLE_CONTEXT:-}"
    CONTEXT="$CONSOLE_CONTEXT_RESOLVED_MODE"
    # HIMMEL-3279/3282: the source word (an env opt-in spells `explicit` too)
    # is the shared one arm-resume.sh emits, so the two paths cannot disagree.
    _headed_context_source=$(console_context_source_label 0)
fi
if ! console_context_valid "$CONTEXT"; then
    usage
    echo "headed-arm: context must be 1m or standard, got: $CONTEXT" >&2
    exit 2
fi
# HIMMEL-2973: 1m is an explicit operator opt-in -- refuse before the claim
# lock or konsole is ever touched (same refusal shape as the HIMMEL-2779
# leg-side REQUIRED_AUTOCOMPACT check below) unless CONSOLE_CONTEXT=1m was
# set in the launching shell. A resolved CONTEXT of 1m always means that
# check already passed (the `elif` above only reaches 1m when it did), so
# this only ever fires for an explicit positional `1m` without the env.
if [ "$CONTEXT" = "1m" ] && [ "${CONSOLE_CONTEXT:-}" != "1m" ]; then
    usage
    echo "headed-arm: refusing 1m context: set CONSOLE_CONTEXT=1m in the launching shell to opt in; omit [context] or pass standard for the --autocompact 200000 default." >&2
    exit 2
fi
# Fable-family match (shared with arm-resume.sh via console_context_model_is_fable)
# -- only an explicit Fable [model] takes this branch now (the default MODEL
# is Opus, HIMMEL-3079).
_headed_model_is_fable=0
if console_context_model_is_fable "$MODEL"; then
    _headed_model_is_fable=1
fi
# Strip any [1m] suffix the caller may have typed into MODEL directly, so
# `standard` can guarantee its absence and `1m` never doubles it.
MODEL="$(console_context_strip_1m_suffix "$MODEL")"
AUTOCOMPACT="$(console_context_autocompact "$CONTEXT")"
if [ "$CONTEXT" = "1m" ]; then
    if [ "$_headed_model_is_fable" -eq 1 ]; then
        # Measured fact: the CLI silently strips [1m] for Fable-family
        # models -- never claim to have set 1m context on one.
        CONTEXT_REASON="context=1m ($_headed_context_source); model=$MODEL is Fable-family -- the CLI silently strips a [1m] suffix there, so it is NOT applied (autocompact=auto still is)"
    else
        MODEL="${MODEL}[1m]"
        CONTEXT_REASON="context=1m ($_headed_context_source); model=$MODEL"
    fi
else
    CONTEXT_REASON="context=standard ($_headed_context_source); model=$MODEL"
fi
# HIMMEL-2534: macOS has no konsole. The default resolves to the shim beside
# this script rather than branching the two launch blocks below - every
# existing test asserts their exact argv shape, and a shim keeps that
# contract instead of forking it per platform. KONSOLE_CMD still overrides
# on every platform, unchanged.
# codex-review S11: the platform read is a seam, like PGREP_CMD and
# HEADED_ARM_PROC already are, so the macOS-only resolution and budget below
# are testable on a Linux runner instead of silently reporting green there.
HEADED_ARM_UNAME="${HEADED_ARM_UNAME:-$(uname -s 2>/dev/null)}"
# Whether this station launches through `open -a` rather than konsole. This
# tracks the PLATFORM, not which binary won the resolution below: an explicit
# KONSOLE_CMD on a Mac is still an `open -a`-shaped launch and still needs the
# larger visibility budget (see SESSION_VISIBLE_RETRY_ITERS).
KONSOLE_IS_MACOS_SHIM=0
[ "$HEADED_ARM_UNAME" = "Darwin" ] && KONSOLE_IS_MACOS_SHIM=1
# Whether THIS run resolved the shim itself, as opposed to being handed a
# launcher. Narrower than the platform flag above on purpose: an explicit
# KONSOLE_CMD means the caller owns what the launcher does with the argv,
# so the recorder refusal below must not speak for it.
KONSOLE_IS_RESOLVED_SHIM=0
if [ -n "${KONSOLE_CMD:-}" ]; then
    KONSOLE="$KONSOLE_CMD"
elif [ "$HEADED_ARM_UNAME" = "Darwin" ]; then
    # codex-review S12: an unchecked `cd` here collapses to the literal
    # "/konsole-macos.sh", and the refusal below then names a path that never
    # existed -- "the shim is missing" instead of "I could not resolve my own
    # directory". Fail with the real reason.
    _here="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _here=""
    if [ -z "$_here" ]; then
        # HIMMEL-2534 CR fix (N346): exit 3 already means "no konsole/CLI dep
        # on PATH" (below); this is a different failure (can't even resolve
        # this script's own directory) and needs its own code, not a collision.
        echo "headed-arm: could not resolve this script's own directory to locate the macOS konsole shim" >&2
        # 13, not 10 (N357 r2 codex-3): headed-arm-leg.sh execs into this
        # script and already owns 10-12 and 17 for its own refusals.
        exit 13
    fi
    KONSOLE="$_here/konsole-macos.sh"
    KONSOLE_IS_MACOS_SHIM=1
    KONSOLE_IS_RESOLVED_SHIM=1
else
    KONSOLE="konsole"
fi
PGREP="${PGREP_CMD:-pgrep}"
PROC="${HEADED_ARM_PROC:-/proc}"
REPO="${HEADED_ARM_REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
INIT="execute,prcheck,pr,ticket,merge,public,handover"
LAUNCHER="${HEADED_ARM_LAUNCHER:-claude}"
LAUNCHER_ENV="${HEADED_ARM_LAUNCHER_ENV:-}"
RECORDER="${HEADED_ARM_RECORDER:-0}"
REQUIRED_AUTOCOMPACT="${HEADED_ARM_REQUIRED_AUTOCOMPACT:-}"
unset HEADED_ARM_REQUIRED_AUTOCOMPACT
# HIMMEL-3403: headed-arm-leg.sh --headless sets these. HEADLESS launches the
# session in the background (no konsole) and confirms it through
# `$CLAUDE_CLI agents --json` - a background session's process comm is the
# CLI version string, not `claude`, so the pgrep census below never sees it.
HEADLESS="${HEADED_ARM_HEADLESS:-0}"
CLAUDE_CLI="${HEADED_ARM_CLAUDE_CLI:-claude}"
LAUNCH_RECORD="${HEADED_ARM_LAUNCH_RECORD:-}"
unset HEADED_ARM_HEADLESS HEADED_ARM_LAUNCH_RECORD
# HIMMEL-2975 (renamed HIMMEL-3133): a console session must never inherit a
# relay marker from whatever armed it -- ROLE_ENV_UNSET is an extra `-u`
# token added to BOTH konsole launch branches' env -u list below,
# unconditional (not merely "if set"), so a HIMMEL_CONSOLE_RELAY already
# present in the arming shell's own env is cleared the same way
# CLAUDE_CODE_CHILD_SESSION etc already are.
ROLE_ENV_UNSET=""
# HIMMEL-2973 S3: a console also gets HIMMEL_CONSOLE_DOC / HIMMEL_CONSOLE_WORKDIR
# exported, which is what switches on the PreCompact snapshot hook
# (scripts/hooks/console-precompact-snapshot.sh); every other session gets
# neither, so that hook stays a silent no-op fleet-wide. The workdir is
# dirname(SIGNAL) -- console.sh's chain dir, 0700 and non-symlink. An array,
# not a word-split string, so a path with a space survives.
# ponytail: keyed on --role console only. A console armed without --role (a
# hand-pasted headed-arm.sh line) gets no export and so no snapshot; G11
# (compacted-check.sh) reports that as `no snapshot` rc 2, never a false pass.
CONSOLE_ENV=()
if [ "$ROLE" = "console" ]; then
    ROLE_ENV_UNSET="-u HIMMEL_CONSOLE_RELAY"
    # HIMMEL-3035: the `-u` above sits BEFORE $LAUNCHER_ENV in both konsole
    # branches, and `env -u FOO FOO=1` ends with FOO=1 -- so a
    # HIMMEL_CONSOLE_RELAY=<v> token carried in HEADED_ARM_LAUNCHER_ENV would
    # silently undo the unconditional clear. Drop that exact name here (a
    # prefix-sharing name, e.g. HIMMEL_CONSOLE_RELAY_X, is left alone). noglob
    # keeps the word-split from expanding a `*` in a token, matching the
    # unquoted use at the launch sites.
    _kept_env=""
    set -f
    for _tok in $LAUNCHER_ENV; do
        case "$_tok" in
            HIMMEL_CONSOLE_RELAY=*) ;;
            *) _kept_env="${_kept_env:+$_kept_env }$_tok" ;;
        esac
    done
    set +f
    LAUNCHER_ENV="$_kept_env"
    # A relative DOC resolves against REPO (the session's --workdir, see the
    # DOC note below), but the PreCompact hook runs in whatever cwd the session
    # has by then -- export it absolute so the hook opens the file the console
    # was actually told to load.
    case "$DOC" in
        /*) _console_doc="$DOC" ;;
        *)  _console_doc="$REPO/$DOC" ;;
    esac
    CONSOLE_ENV=("HIMMEL_CONSOLE_DOC=$_console_doc" "HIMMEL_CONSOLE_WORKDIR=$(dirname -- "$SIGNAL")")
fi
LAUNCH_ARGV=("$LAUNCHER" --model "$MODEL" --autocompact "$AUTOCOMPACT" -n "$NAME" "load $DOC and continue")
if [ "$HEADLESS" = "1" ]; then
    # auto is what a headed leg runs in (defaultMode=auto in the operator's
    # user settings), declared here because an unattended launch must never
    # rely on the default (CLAUDE.md "Claude invocation billing").
    # headless-claude-ok: HIMMEL-3403 console-armed leg; headed-arm-leg.sh ran the bank/fleet preflight
    LAUNCH_ARGV=("$LAUNCHER" --bg --permission-mode auto --model "$MODEL" --autocompact "$AUTOCOMPACT" -n "$NAME" "load $DOC and continue")
fi

# HIMMEL-2779: headed-arm-leg.sh sets this required value. Validate the same
# argv array both launch branches consume, so a future renderer cannot drop or
# change the cost-driving pair while the wrapper still reports standard mode.
if [ -n "$REQUIRED_AUTOCOMPACT" ]; then
    _headed_required_found=0
    _headed_i=0
    while [ "$_headed_i" -lt "${#LAUNCH_ARGV[@]}" ]; do
        if [ "${LAUNCH_ARGV[$_headed_i]}" = "--autocompact" ] \
           && [ "$((_headed_i + 1))" -lt "${#LAUNCH_ARGV[@]}" ] \
           && [ "${LAUNCH_ARGV[$((_headed_i + 1))]}" = "$REQUIRED_AUTOCOMPACT" ]; then
            _headed_required_found=1
            break
        fi
        _headed_i=$((_headed_i + 1))
    done
    if [ "$_headed_required_found" -ne 1 ]; then
        echo "headed-arm-leg: refusing leg launch: resolved argv lacks --autocompact $REQUIRED_AUTOCOMPACT. Retry with standard leg context; use a console arm for 1m context." >&2
        exit 2
    fi
fi

# r10-codex-3: $LOG is used AFTER `cd "$REPO"` below - the konsole redirect
# (`>> "$LOG"`), and every status line this script writes on every exit
# path. A RELATIVE $LOG would silently start writing somewhere else (or
# fail outright) the instant the cwd changes. The lock root has the SAME
# problem for a different reason: HEADED_ARM_LOCK_DIR is a caller-supplied
# override, and the post-launch `rm -rf "$LOCK"` cleanup (every exit path,
# see the claim site below) runs AFTER the cd too - a relative lock root
# leaves that cleanup targeting a path that no longer resolves to where the
# lock actually lives, LEAKING it: the exact failure mode this file has
# spent four rounds keeping out, arriving through a path nobody was
# looking at. Resolved to absolute HERE, before anything can cd (and
# before the wait loop, since $LOG is written there too - see the "armed:"
# line below) - `$_here` is captured via `pwd` (the builtin, which queries
# the OS directly) rather than trusted from a possibly-stale `$PWD` in the
# launching environment. A plain prefix, not a `cd`-based realpath, is
# deliberate: $LOG's FILE, and the lock root's DIRECTORY, may not exist yet
# - what has to exist is the caller's OWN cwd, already guaranteed by the
# fact this script is running at all, so prefixing needs nothing
# pre-created and is exact for a later open()/mkdir() regardless of
# whether the target exists yet. The lock root itself is resolved the same
# way at its own construction site below (see r10-codex-3 there) - the
# round-6 validation that follows it there applies to this RESOLVED path,
# never the pre-resolution one, so a relative override that would have
# resolved into someone else's directory is still refused.
#
# SIGNAL and DOC were considered and deliberately left alone: SIGNAL is
# only ever tested (`[ -e "$SIGNAL" ]`) inside the wait loop below, which
# runs entirely BEFORE the cd, so it is never evaluated against a changed
# cwd. DOC is passed into the CHILD's prompt, and the child is launched
# with `--workdir "$REPO"` - so a relative DOC resolves the way a caller
# who thinks in repo-relative paths would actually expect, which is the
# convention this whole system already uses elsewhere; changing that would
# be a behaviour change nobody asked for, not a fix.
_here="$(pwd)"
case "$LOG" in
    /*) : ;;
    *) LOG="$_here/$LOG" ;;
esac

# NAME becomes a directory-name component below (the claim lock) - reject a
# slash outright rather than silently nesting into an unintended path.
case "$NAME" in
    */*) echo "headed-arm: session name must not contain '/': '$NAME'" >&2; exit 2 ;;
esac

# HIMMEL-3140: no legitimate caller (console.sh, headed-arm-leg.sh) ever
# passes one of the usage string's own placeholder tokens - both build a
# real session name first. The likeliest way one of these reaches NAME is a
# human copy-pasting the usage line verbatim (including the angle brackets)
# while hand-testing --dry-run. Refuse loudly rather than let a --dry-run
# report look like a genuine one for args nobody meant to pass.
case "$NAME" in
    name|session|'<session-name>')
        echo "headed-arm: '$NAME' looks like a placeholder copied from the usage string, not a real session name - check what you're actually invoking" >&2
        exit 2
        ;;
esac

case "$DEADLINE" in
    ''|*[!0-9]*) echo "headed-arm: deadline must be an epoch second, got '$DEADLINE'" >&2; exit 2 ;;
esac
if [ "$HEADLESS" = "1" ]; then
    if [ -z "${LEG_PROFILE_SETTINGS:-}" ]; then
        echo "headed-arm: a headless launch needs LEG_PROFILE_SETTINGS (the leg's env rides in that settings file) - launch through headed-arm-leg.sh --headless --profile <name>" >&2
        exit 2
    fi
    for _hl_need in "$CLAUDE_CLI" jq; do
        if ! command -v "$_hl_need" >/dev/null 2>&1; then
            echo "headed-arm: no '$_hl_need' on PATH - a headless launch needs it to list and confirm background sessions" >&2
            exit 3
        fi
    done
elif ! command -v "$KONSOLE" >/dev/null 2>&1; then
    echo "headed-arm: no '$KONSOLE' on PATH - this launcher needs a terminal emulator to give the session a TTY (HIMMEL-2534)" >&2
    exit 3
fi
# codex-4: unchecked, a missing pgrep fails the dedup call below rc=127,
# which reads exactly like "no matching session" and silently disables
# dedup - failing OPEN into duplicate windows. This script is already
# tied to a terminal emulator (konsole, or the macOS shim), so refusing here
# is honest, not restrictive.
if ! command -v "$PGREP" >/dev/null 2>&1; then
    echo "headed-arm: no '$PGREP' on PATH - dedup needs pgrep (procps) to tell whether a session named $NAME is already running; refusing rather than risk launching a duplicate (HIMMEL-2545)" >&2
    exit 4
fi

# HIMMEL-3140: everything above this point is pure argument resolution and
# validation (usage-arity, --role, context, the placeholder-name refusal,
# NAME/DEADLINE shape, konsole/pgrep PATH availability) - none of it writes
# to $LOG, touches the claim lock, or execs anything. Report the resolved
# argv and env here and exit, before the ONLY parts of this script that cost
# a real launch: the signal/deadline wait loop, the dedup pgrep scan, the
# claim lock, and konsole itself.
if [ "$DRY_RUN" -eq 1 ]; then
    printf 'headed-arm: would exec: %s\n' "$(printf '%q ' "${LAUNCH_ARGV[@]}")"
    printf 'headed-arm: env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID%s CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 HIMMEL_INITIATIVE=%s ARMAUTOMERGE=1%s%s\n' \
        "${ROLE_ENV_UNSET:+ $ROLE_ENV_UNSET}" "$INIT" "${CONSOLE_ENV[0]:+ ${CONSOLE_ENV[0]} ${CONSOLE_ENV[1]}}" "${LAUNCHER_ENV:+ $LAUNCHER_ENV}"
    printf 'headed-arm: name=%s doc=%s signal=%s deadline=%s log=%s role=%s\n' \
        "$NAME" "$DOC" "$SIGNAL" "$DEADLINE" "$LOG" "${ROLE:-unsplit}"
    printf 'headed-arm: %s (autocompact=%s)\n' "$CONTEXT_REASON" "$AUTOCOMPACT"
    printf 'headed-arm: launcher=%s recorder=%s konsole=%s pgrep=%s repo=%s\n' \
        "$LAUNCHER" "$RECORDER" "$KONSOLE" "$PGREP" "$REPO"
    if [ "$HEADLESS" = "1" ]; then
        printf 'headed-arm: headless=1 claude-cli=%s settings=%s\n' "$CLAUDE_CLI" "$LEG_PROFILE_SETTINGS"
    fi
    exit 0
fi

echo "$(date +%F_%T) armed: name=$NAME doc=$DOC signal=$SIGNAL deadline=$DEADLINE role=${ROLE:-unsplit}" >> "$LOG"
# r5-codex-3: the header calls $DEADLINE a hard deadline, but a flat `sleep
# 30` let the loop overshoot it by up to nearly 30s before the launch even
# started - the wait loop woke on its own schedule, not the deadline's.
# Fixed to sleep for the SHORTER of 30s and the time actually remaining, so
# the loop wakes AT the deadline instead of up to 30s past it. The deadline
# check above always runs first and only falls through here when
# DEADLINE - now is at least 1 (strictly greater than 0), so the remaining
# computed below is never zero or negative and this never busy-spins; the
# signal-file check keeps running every iteration, on the same or a
# tighter cadence than before. Kept integer-valued throughout for bash 3.2.
while :; do
    if [ -e "$SIGNAL" ]; then echo "$(date +%F_%T) signal seen" >> "$LOG"; break; fi
    now="$(date +%s)"
    if [ "$now" -ge "$DEADLINE" ]; then echo "$(date +%F_%T) deadline reached" >> "$LOG"; break; fi
    # DEADLINE is validated above to be digits-only, but NOT to be free of a
    # leading zero (e.g. "0123456789" passes that check) - `$(( ))` is an
    # ARITHMETIC context, where a leading zero means octal, and an octal
    # digit outside 0-7 (e.g. the 8 or 9 in that example) is a bash
    # arithmetic error. `10#$DEADLINE` forces base-10 regardless.
    remaining=$(( 10#$DEADLINE - now ))
    [ "$remaining" -le 30 ] || remaining=30
    sleep "$remaining"
done

# codex-3: ERE-escape NAME before it reaches pgrep -f, so a name carrying
# regex metacharacters (e.g. '.' or '(') matches only itself, never as a
# wildcard against an unrelated session's command line.
# The single quotes are LOAD-BEARING: this is a sed BRE/ERE pattern, and its
# $ (end-of-bracket-expression marker, not a shell variable) must reach sed
# unexpanded.
# shellcheck disable=SC2016
ere_escape() {
    printf '%s' "$1" | sed -e 's/[][\\.*^$(){}?+|]/\\&/g'
}
NAME_ERE="$(ere_escape "$NAME")"

# r7-codex-1: `pgrep -f` matches the FULL command line, and konsole's OWN
# argv literally quotes the whole claude invocation it was told to run
# (`konsole ... -e env -u ... claude --model X -n NAME "load ..."`) - the
# bracket trick above only keeps pgrep from matching ITS OWN invocation, it
# does nothing about konsole's. So the pattern below matched konsole's OWN
# process too, not just the claude process it spawns: the post-launch
# visibility poll confirmed a session the instant konsole itself appeared in
# pgrep, and the dedup layers could likewise be satisfied by a surviving
# terminal with no claude inside it at all. Same class this repo's own
# himmel-doctor.sh C29 check already guards against - a launcher whose argv
# quotes the claude command is not a claude session. Fixed by confirming
# each matched pid's own comm actually IS claude before believing the
# match, exactly like C29 does. A pid that vanishes between pgrep and the
# comm read is silently skipped (`|| continue`), never treated as an error.
# r8-codex-3: this used to fold EVERY pgrep failure into "no match"
# (`|| return 1`), but pgrep exits 1 for a genuine no-match and 2 or 3 for a
# usage or fatal scan error - a broken scan then silently read as "nothing
# running" and bypassed dedup, or a green light to launch, either way an
# indeterminate answer reported as a confirmed one. Now returns a third
# state (2) for rc>1 so every call site can refuse rather than guess.
#
# r9-codex-3: matching a FLATTENED command line does not establish that
# `-n NAME` is actually an OPTION - `pgrep -f` matches against the whole
# argv joined by spaces, so an unrelated claude session whose PROMPT text
# happens to contain "-n <our session name> " (or whose OWN session name
# merely has ours as a PREFIX, e.g. HIMMEL-2545-x while this arm is
# HIMMEL-2545) could satisfy the pattern and suppress a launch that should
# have happened - a silently skipped successor, the exact failure class
# this whole ticket exists to eliminate. Fixed below (_argv_has_n_name) by
# reading that same pid's /proc/<pid>/cmdline - NUL-separated, so it is the
# REAL argv, not a flattened string - and requiring a POSITIONAL, EXACT
# match: an element that equals "-n" immediately followed by an element
# that equals $NAME. Prompt text and name-prefix collisions can no longer
# satisfy this. pgrep stays the cheap CANDIDATE filter (its pattern no
# longer has to be exact); the argv walk is what actually decides.
# ere_escape() above is NOT deleted for this - it is belt-and-braces rather
# than the sole guard now, but an unescaped metacharacter in $NAME could
# still make the pgrep pre-filter itself MISS a candidate pid it should
# have returned, and the positional decision below never gets a chance to
# run on a candidate pgrep never handed back.
#
# r10-codex-4 (SUGGESTION): the pattern used to require a trailing space
# after $NAME_ERE, so a command line that ENDS at the name (no trailing
# prompt argument) was filtered out before the exact argv check ever saw
# it - our own launches always put a prompt after the name, but another
# arm's need not, and that candidate could then receive a genuine
# duplicate. Now that the positional argv walk above is authoritative, the
# pre-filter is made PERMISSIVE rather than precise: `(space or
# end-of-line)` after the name, via the ERE alternation `( |$)` every call
# site below uses.
_argv_has_n_name() { # _argv_has_n_name <pid> - true iff /proc/<pid>/cmdline
                      # has an element exactly "-n" immediately followed by
                      # an element exactly equal to $NAME (positional and
                      # exact, from the real NUL-separated argv - never a
                      # substring or regex match against flattened text)
    local pid="$1" prev="" cur
    [ -r "$PROC/$pid/cmdline" ] || return 1
    while IFS= read -r -d '' cur; do
        [ "$prev" = "-n" ] && [ "$cur" = "$NAME" ] && return 0
        prev="$cur"
    done < "$PROC/$pid/cmdline"
    return 1
}
# HIMMEL-3403: the headless census. A background session is listed by
# `agents --json` with its pid while it runs. A CLI or jq failure is the same
# third state (2) as a failed pgrep scan, and so is an answer that is not a
# JSON array (jq's error() exits 5).
headless_session_listed() {
    local out
    out="$("$CLAUDE_CLI" agents --json 2>/dev/null)" || return 2
    printf '%s' "$out" | jq -e --arg n "$NAME" \
        'if type == "array" then any(.[]; .name == $n and .pid != null) else error("not an array") end' >/dev/null 2>&1
    case $? in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

_LOSSY_WARNED=0
session_confirmed() { # session_confirmed <pgrep-ere-pattern> - returns
                       # 0 confirmed, 1 genuinely not running, 2 the SCAN
                       # ITSELF failed (indeterminate, never "not running")
    if [ "$HEADLESS" = "1" ]; then
        headless_session_listed
        return $?
    fi
    local pat="$1" pid comm pids pg_rc
    pids="$("$PGREP" -f "$pat" 2>/dev/null)"
    pg_rc=$?
    [ "$pg_rc" -gt 1 ] && return 2
    # HIMMEL-2534: where $PROC is absent (macOS) there is no real-argv source
    # to read, so this degrades to the flattened pgrep match exactly the way
    # scripts/lanes/lib/claude-sessions.sh already rules for the same gap -
    # and says so once, rather than silently answering "not running" forever
    # (which is what the /proc walk below does on a Mac: every `cat` fails,
    # every pid is skipped, dedup fails OPEN into duplicate windows and every
    # launch lands UNCONFIRMED/rc 7). $pat already asserted `-n <name>` on the
    # flattened line; comm is still checked per pid via `ps`, so the only
    # guarantee lost is the whole HIMMEL-2999 class, not merely a whitespace
    # edge case (codex-review I3): confirmation rests on $pat matching the
    # FLATTENED line, so ANY free-text argv element of any claude process -
    # the trailing prompt, --append-system-prompt, --system-prompt - that
    # contains the literal "-n <NAME>" satisfies it, which is exactly what
    # _argv_has_n_name was written to stop (see its own note above). Direction
    # of harm: a false confirm at the dedup layer SKIPS the arm entirely
    # ("already running - not launching"), i.e. the silently-lost successor
    # this ticket exists to eliminate, reached from the other side. Lossy,
    # bounded, and announced - never silent.
    if [ ! -d "$PROC" ]; then
        if [ "$_LOSSY_WARNED" -eq 0 ]; then
            echo "WARN headed-arm: no $PROC on this platform - session confirmation falls back to a lossy flattened pgrep scan (HIMMEL-2534)" >&2
            _LOSSY_WARNED=1
        fi
        # ps rc 1 = that pid vanished since pgrep saw it (skip it); any other
        # failure (a missing or broken ps) means the scan itself failed, so
        # it is indeterminate (2), never "not running" (N357, codex-2).
        local ps_rc
        for pid in $pids; do
            ps_rc=0
            comm="$(ps -o comm= -p "$pid" 2>/dev/null)" || ps_rc=$?
            [ "$ps_rc" -eq 1 ] && continue
            [ "$ps_rc" -eq 0 ] || return 2
            [ "${comm##*/}" = claude ] || continue
            return 0
        done
        return 1
    fi
    for pid in $pids; do
        comm="$(cat "$PROC/$pid/comm" 2>/dev/null)" || continue
        [ "$comm" = claude ] || continue
        _argv_has_n_name "$pid" && return 0
    done
    return 1
}

# Dedup layer 1: an already-running claude session (launched by an earlier,
# unrelated arm). The bracket in the pattern keeps the pgrep from matching
# its own command line.
session_confirmed "[c]laude .*-n $NAME_ERE( |\$)"; sc_rc=$?
if [ "$sc_rc" -eq 0 ]; then
    echo "$(date +%F_%T) a session named $NAME is already running - not launching" >> "$LOG"
    exit 0
elif [ "$sc_rc" -eq 2 ]; then
    echo "headed-arm: pgrep scan failed checking for an existing session named $NAME - refusing to treat an indeterminate scan as 'nothing running' (HIMMEL-2545)" >&2
    echo "$(date +%F_%T) INDETERMINATE: pgrep scan failed checking for $NAME - refusing rather than risk a duplicate" >> "$LOG"
    exit 9
fi

# Dedup layer 2 (codex-2): the check above is a non-atomic check-then-launch
# - two arms racing on the exact same NAME could both see "no match" here
# and both proceed to launch. Claim atomically with `mkdir` (fails if the
# directory already exists - this repo's convention for exactly this
# problem: "claim by atomic mkdir AND RETRY, never scan-then-create") before
# doing anything else.
#
# STALE-LOCK POLICY (deliberate choice): this script only ever holds the
# lock for the few seconds between this claim and the post-launch aliveness
# check below - the long wait for the signal/deadline happens BEFORE this
# point, never while holding the lock. So a lock older than STALE_LOCK_SECS
# was left by an arm that crashed or was killed mid-launch, not a live one,
# and is safe to reclaim; a lock that could NEVER go stale would mean one
# crashed arm permanently blocks every future arm for that session name,
# which is worse than the rare duplicate window this guards against. The
# lock is also removed on EVERY exit path below (launched or failed) so a
# healthy run never depends on the staleness timeout at all - the timeout
# only matters for a lock a crashed process actually left behind. The
# acquire timestamp is a file WRITTEN into the lock (not the directory's own
# mtime, which a stray `touch` or a slow/foreign filesystem could disturb),
# mirroring the acquired-stamp idiom scripts/graphify/refresh-graph-map.sh
# already uses for its own mkdir promote lock.
# HIMMEL-3403: a background session gets the env of the claude daemon (the
# process the first background launch spawned, from whatever shell ran it),
# not ours. Measured: a session launched with FOO=second read FOO=first, the
# daemon spawner's value. The one per-session channel is the settings file's
# `env` block, which reaches every tool and hook subprocess. So the leg's
# env is written there. Every leg var in our own env is mirrored; the vars a
# headed launch passes through konsole's env are set explicitly; every
# leg-shaped var the daemon carries that the leg should not have is set to
# "", which every gate reading these vars treats as unset. Values of
# secret-named vars are never copied into the file.
_hl_leg_var() {
    case "$1" in
        HIMMEL_*|LEG_*|CONSOLE_*|HANDOVER_*|IMPL_*|*_OK|CR_*|ARM*|JIRA_PROJECT_KEY) return 0 ;;
    esac
    return 1
}
# The name shapes of scripts/hooks/stop-queue.mjs SECRET_NAME_SHAPES, matched
# case-insensitively the same way, plus PASS and PAT as whole name tokens:
# `HIMMEL_*` would otherwise mirror HIMMEL_MQTT_PASS and HIMMEL_GITHUB_PAT.
# BYPASS is not a PASS token, so the *_BYPASS_OK gates still pass through.
_hl_secret_var() {
    local rc=1 nocase=0
    [ "$1" = JIRA_PROJECT_KEY ] && return 1
    shopt -q nocasematch && nocase=1
    shopt -s nocasematch
    case "$1" in
        *TOKEN*|*SECRET*|*KEY*|*PASSWORD*|*PASSWD*|*CREDENTIAL*|*COOKIE*|*AUTH*|*CHAT_ID*|*DSN*|*_URL*|*CONNECTION*|*PRIVATE*|*CERT*|*BEARER*|*SIGNATURE*|*SESSION_ID*) rc=0 ;;
        PASS|PASS_*|*_PASS|*_PASS_*|PAT|PAT_*|*_PAT|*_PAT_*) rc=0 ;;
    esac
    [ "$nocase" = 1 ] || shopt -u nocasematch
    return "$rc"
}
# The background service is qualified on its cmdline (an argv entry whose
# basename is `claude`, then `daemon run`), not on its comm, which for a bg
# process can be the CLI version string.
_hl_service_pid() {
    local arg prev2="" prev1=""
    while IFS= read -r -d '' arg; do
        [ "${prev2##*/}" = claude ] && [ "$prev1" = daemon ] && [ "$arg" = run ] && return 0  # t13b-ok: read-only argv match of the Claude Code service, starts nothing
        prev2="$prev1"; prev1="$arg"
    done < "$PROC/$1/cmdline"
    return 1
}
HL_KEYS=()
HL_VALS=()
_hl_set() { # _hl_set <name> <value> - last write wins
    local i=0
    while [ "$i" -lt "${#HL_KEYS[@]}" ]; do
        if [ "${HL_KEYS[$i]}" = "$1" ]; then HL_VALS[i]="$2"; return 0; fi
        i=$((i + 1))
    done
    HL_KEYS+=("$1")
    HL_VALS+=("$2")
}
_hl_has() {
    local k
    for k in ${HL_KEYS[@]+"${HL_KEYS[@]}"}; do [ "$k" = "$1" ] && return 0; done
    return 1
}
headless_fail() { # headless_fail <rc> <message>
    echo "headed-arm: $2" >&2
    echo "$(date +%F_%T) FAILED: $2" >> "$LOG"
    rm -rf "$LOCK" 2>/dev/null
    exit "$1"
}
# ponytail: the daemon env is read once, just before the launch. A daemon
# that exits and is respawned by some other shell in between would hand the
# leg vars this scan never saw. The window is the few ms between this read
# and the launch call.
# ponytail: only leg-shaped names (the case list in _hl_leg_var) are
# overridden. Anything else the daemon spawner had - PATH, CLAUDE_CODE_*,
# the CLAUDE_PID / CLAUDE_CODE_SESSION_ID a headed launch clears with env -u -
# still reaches the leg from the daemon.
headless_launch() {
    local name val tok pid pids pg_rc settings="$LEG_PROFILE_SETTINGS" tmp_settings pair
    [ -f "$settings" ] || headless_fail 2 "headless: settings file $settings is missing - it must exist before the launch"
    for name in $(compgen -e); do
        _hl_leg_var "$name" || continue
        _hl_secret_var "$name" && continue
        [ "$name" = HIMMEL_HOOK_INTEGRITY_BYPASS_OK ] && continue
        _hl_set "$name" "${!name}"
    done
    _hl_set CLAUDE_CODE_FORCE_SESSION_PERSISTENCE 1
    _hl_set HIMMEL_INITIATIVE "$INIT"
    _hl_set ARMAUTOMERGE 1
    set -f
    # The role's `env -u` removals, applied before the explicit env exactly as
    # the konsole branches order them (HIMMEL-3035: LAUNCHER_ENV may re-set).
    for tok in $ROLE_ENV_UNSET; do
        [ "$tok" = "-u" ] || _hl_set "$tok" ""
    done
    for tok in ${CONSOLE_ENV[@]+"${CONSOLE_ENV[@]}"} $LAUNCHER_ENV; do
        case "$tok" in *=*) _hl_set "${tok%%=*}" "${tok#*=}" ;; esac
    done
    set +f
    # Only a launcher the operator started with the bypass hands it on; a
    # daemon spawned from a bypass shell never does.
    val=""
    [ "${HIMMEL_HOOK_INTEGRITY_BYPASS_OK:-}" = "1" ] && val=1
    _hl_set HIMMEL_HOOK_INTEGRITY_BYPASS_OK "$val"
    pids="$("$PGREP" -f '[c]laude daemon run' 2>/dev/null)"  # t13b-ok: read-only pgrep lookup of the Claude Code service, starts nothing
    pg_rc=$?
    [ "$pg_rc" -gt 1 ] && headless_fail 9 "headless: pgrep scan for the claude background service failed - its env decides what the leg inherits, refusing to launch blind"
    local qualified=0
    for pid in $pids; do
        _hl_service_pid "$pid" 2>/dev/null || continue
        qualified=$((qualified + 1))
        [ -r "$PROC/$pid/environ" ] || headless_fail 9 "headless: cannot read the claude background service's env (pid $pid) - refusing to launch blind"
        while IFS= read -r -d '' pair; do
            name="${pair%%=*}"
            _hl_leg_var "$name" || continue
            _hl_has "$name" || _hl_set "$name" ""
        done < "$PROC/$pid/environ"
    done
    [ -n "$pids" ] && [ "$qualified" -eq 0 ] && headless_fail 9 "headless: pgrep matched pid(s) ${pids//$'\n'/ } but none has a claude background service cmdline - refusing to launch blind"
    local jq_args=() i=0
    while [ "$i" -lt "${#HL_KEYS[@]}" ]; do
        jq_args+=("${HL_KEYS[$i]}" "${HL_VALS[$i]}")
        i=$((i + 1))
    done
    tmp_settings="$settings.tmp.$$"
    # shellcheck disable=SC2016  # $ARGS / $a / $i are jq variables, not shell ones.
    if ! ( umask 077 && jq --args '.env = ((.env // {}) + ($ARGS.positional as $a | reduce range(0; $a | length; 2) as $i ({}; . + {($a[$i]): $a[$i + 1]})))' \
            "${jq_args[@]}" < "$settings" > "$tmp_settings" ) || ! mv -f "$tmp_settings" "$settings"; then
        rm -f "$tmp_settings" 2>/dev/null
        headless_fail 1 "headless: could not write the leg env into $settings"
    fi
    chmod 600 "$settings" 2>/dev/null || true

    local lrc=0
    # shellcheck disable=SC2086  # deliberately word-split env tokens, the same shape as the konsole branches.
    env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID $ROLE_ENV_UNSET \
        CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 HIMMEL_INITIATIVE="$INIT" ARMAUTOMERGE=1 ${CONSOLE_ENV[@]+"${CONSOLE_ENV[@]}"} $LAUNCHER_ENV \
        "${LAUNCH_ARGV[@]}" < /dev/null >> "$LOG" 2>&1 || lrc=$?
    [ "$lrc" -eq 0 ] || headless_fail 1 "headless: the background launch for $NAME exited $lrc - see $LOG for its output"

    local n=0 seen=0 row="" out
    while [ "$n" -lt 100 ]; do
        headless_session_listed; sc_rc=$?
        [ "$sc_rc" -eq 2 ] && headless_fail 9 "headless: agents census failed confirming $NAME after launch"
        if [ "$sc_rc" -eq 0 ]; then seen=1; break; fi
        n=$((n + 1))
        sleep 0.2
    done
    [ "$seen" -eq 1 ] || headless_fail 7 "UNCONFIRMED: headless launch of $NAME exited 0 but it never appeared in \`agents --json\`"
    out="$("$CLAUDE_CLI" agents --json 2>/dev/null)"
    row="$(printf '%s' "$out" | jq -r --arg n "$NAME" '[.[] | select(.name == $n and .pid != null)][0] | "\(.pid) \(.sessionId // "-") \(.id // "-")"' 2>/dev/null)"
    # shellcheck disable=SC2086  # deliberately split: "<pid> <session-id> <short-id>".
    set -- $row
    # The line the fleet UI and the console read. out= is where the launch
    # call's own output went; the session's screen is `claude logs <short-id>`.
    local line
    line="headless=1 pid=${1:--} session-id=${2:--} short-id=${3:--} name=$NAME settings=$settings out=$LOG argv=$(printf '%q ' "${LAUNCH_ARGV[@]}")"
    echo "$(date +%F_%T) $line" >> "$LOG"
    if [ -n "$LAUNCH_RECORD" ]; then
        ( umask 077 && printf 'headed-arm: %s launched=%s\n' "$line" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LAUNCH_RECORD" ) 2>/dev/null \
            || echo "$(date +%F_%T) WARN headless launch line NOT written to $LAUNCH_RECORD" >> "$LOG"
    fi
    rm -rf "$LOCK" 2>/dev/null
    exit 0
}

STALE_LOCK_SECS=120
# r6-codex-2: the lock root used to default to a PREDICTABLE, SHARED path
# under /tmp. On a multi-user host another local user could pre-create that
# exact path - as a directory they own, or a symlink elsewhere - before
# this script ever ran; `mkdir -p` on an ALREADY-EXISTING path succeeds
# regardless of who owns it, so every lock operation would then happen
# inside a directory this process does not control: pre-creating every
# $NAME.lock denies arms indefinitely, or the directory's contents reveal
# which sessions are being armed. This script ships in the repo for
# adopters, so "our station is single-user" is not the threat model to
# design against.
#
# Fixed: prefer $XDG_RUNTIME_DIR (already a per-user 0700 directory on
# systemd hosts - exactly the property wanted) when it is set; otherwise
# fall back to a uid-qualified path under ${TMPDIR:-/tmp}, created 0700.
# HEADED_ARM_LOCK_DIR stays an explicit override, but the SAME validation
# below applies to it too, so a test seam cannot become the one
# unvalidated path.
if [ -n "${HEADED_ARM_LOCK_DIR:-}" ]; then
    LOCKDIR="$HEADED_ARM_LOCK_DIR"
elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    LOCKDIR="$XDG_RUNTIME_DIR/himmel-headed-arm-locks"
else
    LOCKDIR="${TMPDIR:-/tmp}/himmel-headed-arm-locks.$(id -u)"
fi
# r10-codex-3: resolved to absolute the SAME way $LOG was above ($_here
# prefix, no `cd`) and for the same reason - the post-launch `rm -rf
# "$LOCK"` cleanup below runs AFTER `cd "$REPO"`, so a relative
# HEADED_ARM_LOCK_DIR override would leave that cleanup targeting a path
# that no longer resolves to where the lock actually lives, leaking it.
# Done BEFORE `mkdir -p` and every validation check that follows, so those
# checks - and every reader of $LOCKDIR from here on - see only the
# resolved path; a relative override that would have resolved into
# someone else's directory is still caught by that validation, not
# silently exempted by resolving late.
case "$LOCKDIR" in
    /*) : ;;
    *) LOCKDIR="$_here/$LOCKDIR" ;;
esac
# r2-codex-2: an unwritable/unavailable lock root used to be swallowed here,
# so every subsequent `mkdir "$LOCK"` failed the same way a genuine
# concurrent claim would, and the script logged "already claimed" and
# exited 0 -- an ENVIRONMENT FAULT read as a successful dedup, silently
# skipping a launch that was never actually claimed by anyone. The two
# outcomes must never share an exit code or a log message.
# `-m` only applying to the deepest dir on a multi-level create (SC2174 in
# the shellcheck linter, suppressed below) is fine here on purpose: an
# unconditional chmod after this call would "launder" a pre-existing
# group/world-writable (or symlinked) LOCKDIR left by another local user
# BEFORE the r6-codex-2 validation below ever inspects it, defeating that
# exact check. `mkdir -p` is a documented no-op on a path that already
# exists, so a hostile pre-created root survives untouched into the
# validation, which is what actually has to catch it.
# shellcheck disable=SC2174
if ! mkdir -p -m 0700 "$LOCKDIR" 2>/dev/null; then
    echo "headed-arm: cannot create the claim-lock root '$LOCKDIR' - refusing to silently skip a launch that was never actually claimed (HIMMEL-2545)" >&2
    exit 5
fi
# r6-codex-2: VALIDATE the root rather than trusting it, regardless of
# where it came from - mkdir -p is a no-op on a path that already exists,
# so a pre-created directory (or symlink) from another user survives the
# mkdir above untouched. `-L` is checked before `-d`, since a symlink TO a
# directory this process happens to own would otherwise pass a plain `-d`
# test while still not being a path this process actually controls the
# resolution of. `-O` (bash/ksh test extension) and `-L` are plain test
# operators - no `stat` call, so no GNU/BSD portability split to worry
# about. Any failure reuses the existing loud lock-root exit (5): silently
# continuing into a directory this process does not control is exactly the
# outcome to prevent.
if [ -L "$LOCKDIR" ]; then
    echo "headed-arm: refusing to use the claim-lock root '$LOCKDIR' - it is a SYMLINK, so this process does not control what it actually resolves to (HIMMEL-2545)" >&2
    exit 5
fi
if [ ! -d "$LOCKDIR" ]; then
    echo "headed-arm: refusing to use the claim-lock root '$LOCKDIR' - it is not a directory (HIMMEL-2545)" >&2
    exit 5
fi
if [ ! -O "$LOCKDIR" ]; then
    echo "headed-arm: refusing to use the claim-lock root '$LOCKDIR' - it is not owned by this user (HIMMEL-2545)" >&2
    exit 5
fi
# No bash test operator covers permission BITS, so this is the same
# GNU->BSD `stat` ladder scripts/hooks/qmd-staleness-notice.sh's
# _qmd_not_shared_writable uses. A permission-testing `find` invocation
# piped into `grep -q` was tried here first, but that shape trips two
# known-findings.sh classes at once: a GNU-leaning find flag, and this
# script's `set -o pipefail` turning a SUCCESSFUL match into a
# pipeline-status failure (grep exits the instant it matches, the producer
# then SIGPIPEs writing the rest, HIMMEL-1430) -- so a bare `if <that> | grep
# -q .` here would read backwards. An unreadable mode counts as untrusted
# (fail closed, same as every other check in this block).
_lockdir_mode=$(stat -c %a "$LOCKDIR" 2>/dev/null || stat -f %Lp "$LOCKDIR" 2>/dev/null)  # gnu-ok: GNU stat -c is paired with the BSD stat -f fallback on this same line
if [ -z "$_lockdir_mode" ]; then
    echo "headed-arm: refusing to use the claim-lock root '$LOCKDIR' - could not read its permission bits (HIMMEL-2545)" >&2
    exit 5
fi
_lockdir_oth="${_lockdir_mode: -1}"
_lockdir_grp="${_lockdir_mode%?}"
_lockdir_grp="${_lockdir_grp: -1}"
case "$_lockdir_oth$_lockdir_grp" in
    *2*|*3*|*6*|*7*)
        echo "headed-arm: refusing to use the claim-lock root '$LOCKDIR' - it is group- or world-writable (HIMMEL-2545)" >&2
        exit 5
        ;;
esac
LOCK="$LOCKDIR/$NAME.lock"

# r2-codex-1: stale-lock reclamation used to be a non-atomic
# `rm -rf "$LOCK"; mkdir "$LOCK"` pair. Two reclaimers can both classify the
# SAME lock stale (both read the same old "acquired" stamp); if A completes
# its rm+mkdir before B starts, B's OWN unconditional rm then removes A's
# BRAND NEW lock and B's mkdir succeeds too - both believe they hold it,
# which is exactly the duplicate window this whole lock exists to prevent.
#
# `mv` alone is NOT enough (verified empirically with a deterministic
# barrier harness - see the PR/scratchpad evidence log): rename(2) IS
# atomic between two RACING renames of the exact same source, but nothing
# stops a LATER steal from renaming away a lock that a WINNING racer has
# already, legitimately, freshly recreated a few microseconds earlier -
# steal_stale_lock() has no way to tell "the stale lock I decided to steal"
# from "whatever happens to be at this path right now" unless it checks.
# Fixed with mv-then-VERIFY: after the mv, compare the stolen directory's
# OWN "acquired" stamp against the exact stale value THIS call observed
# before stealing; a mismatch means we stole someone else's fresh, live
# claim by mistake, so we put it back (best-effort) and back off instead of
# recreating over it. This is optimistic-concurrency-style compare-and-swap,
# not just a bare atomic move.
#
# HEADED_ARM_STALE_HOOK is a TEST-ONLY seam (default a no-op): a suite can
# point it at a script that pauses right after staleness is confirmed but
# before the steal, to deterministically interleave two real contenders at
# the exact race window instead of guessing at timing.
# r4-codex-3: a claimed lock whose "acquired" stamp fails to write is left
# UNSTAMPED. claim_lock()'s own case statement below reads a missing or
# unreadable stamp as "not stale by definition" - so an unstamped lock can
# NEVER be reclaimed, permanently blocking every future arm for this
# session name. That is exactly the wedge the stale-lock policy exists to
# avoid, reached through its own bookkeeping. If the stamp write fails, do
# not proceed holding an unstampable lock: remove it and fail loudly with
# a distinct exit instead of silently wedging every future arm.
stamp_or_fail_loudly() {
    if date +%s > "$LOCK/acquired" 2>/dev/null; then
        return 0
    fi
    # HIMMEL-3182: the failed stamp write usually means $LOCK was mkdir'd mode
    # 000 (umask 0777); BSD/macOS `rm -rf` cannot remove such a directory
    # (EACCES), so restore owner access to the lock this claim created first.
    chmod -R u+rwx "$LOCK" 2>/dev/null
    rm -rf "$LOCK" 2>/dev/null
    echo "headed-arm: claimed the lock '$LOCK' but could not write its acquired stamp - refusing to hold an unstampable lock that could never be reclaimed (HIMMEL-2545)" >&2
    exit 8
}
steal_stale_lock() { # steal_stale_lock <expected-acquired-stamp>
    local expected_at="$1" victim stolen_at
    victim="$LOCK.stale.$$.$RANDOM"
    if ! mv "$LOCK" "$victim" 2>/dev/null; then
        # Someone else already stole (or the owner released) it first -
        # this attempt lost the race; not an error, just not ours.
        return 1
    fi
    stolen_at="$(cat "$victim/acquired" 2>/dev/null)" || stolen_at=""
    if [ "$stolen_at" != "$expected_at" ]; then
        # We stole the WRONG thing: a fresh, legitimate claim someone else
        # made after we read the stale stamp but before our mv landed. Put
        # it back so the real holder is not clobbered; if the restore
        # itself loses a race (rare), leave the orphaned $victim rather
        # than risk a second bad steal - never claim in this branch either
        # way.
        mv "$victim" "$LOCK" 2>/dev/null
        return 1
    fi
    rm -rf "$victim" 2>/dev/null
    if mkdir "$LOCK" 2>/dev/null; then
        stamp_or_fail_loudly
        return 0
    fi
    # Another claimant (a fresh arm, or another reclaimer) grabbed the now-
    # empty path in the instant between our mv and our mkdir - lost this
    # race too, not an error.
    return 1
}
claim_lock() {
    if mkdir "$LOCK" 2>/dev/null; then
        stamp_or_fail_loudly
        return 0
    fi
    local held_at age
    held_at="$(cat "$LOCK/acquired" 2>/dev/null)" || held_at=""
    case "$held_at" in
        # No readable stamp yet: either a fresh claim (the stamp write above
        # races the mkdir by a hair) or a crash between mkdir and the stamp
        # write - either way, not stale by definition, so not ours to take.
        ''|*[!0-9]*) return 1 ;;
    esac
    age=$(( $(date +%s) - held_at ))
    [ "$age" -ge "$STALE_LOCK_SECS" ] || return 1
    if [ -n "${HEADED_ARM_STALE_HOOK:-}" ]; then "$HEADED_ARM_STALE_HOOK"; fi
    steal_stale_lock "$held_at"
}

# r2-codex-3: a contender that found the lock held used to exit 0 IMMEDIATELY,
# without ever finding out what the holder did - "claim by atomic mkdir AND
# RETRY, never scan-then-create" (this repo's convention) means retrying,
# not giving up on the first no. The lock is only ever held for the
# fraction of a second between a claim and the aliveness check below, so a
# bounded retry of a couple of seconds (never the STALE_LOCK_SECS timeout)
# is enough to observe the holder's actual outcome: if the lock clears and
# pgrep now shows a session running, that is a genuine dedup (exit 0); if
# it clears and no session is running, the holder failed and THIS arm takes
# over the launch. Only real, sustained contention (never resolved within
# the retry budget) falls through to the deferred exit.
#
# ORDER MATTERS: pgrep is checked BEFORE every claim attempt, not just
# after the retries run out. A lock clearing because the holder's launch
# SUCCEEDED must win over this arm racing to grab the now-free lock and
# launching a duplicate - checking pgrep only once, after the whole loop,
# would let a claim attempt slip in on the very iteration the lock frees up
# but before this arm ever looks at pgrep again.
CLAIM_RETRY_ITERS=40
CLAIM_RETRY_SLEEP=0.05
# r3-codex-2: named budget for the post-launch pgrep-visibility poll below
# (kept next to the claim-retry constants, same shape).
SESSION_VISIBLE_RETRY_ITERS=100
SESSION_VISIBLE_RETRY_SLEEP=0.05
# HIMMEL-2534 (codex-review C1, CRITICAL): the 5s budget above was sized for
# konsole, where the window and the claude exec are effectively instantaneous.
# The macOS shim is NOT: `open -a` has to bring the app up first, measured at
# ~16s for a first-ever (cold) iTerm start and ~1s warm. Left at 5s, a cold
# arm gives up, RELEASES THE LOCK (see the rm -rf "$LOCK" below) and exits 7
# UNCONFIRMED at t=5s -- and then the window opens at t=16s and a real,
# untracked session runs anyway, so the next arm on the same NAME launches a
# genuine duplicate. That is the exact failure r3-codex-2/r4-codex-1/r8-codex-4
# exist to prevent, reached through a budget mismatch instead of a race.
#
# Both budgets are now derived from the SAME env var the shim itself reads
# (KONSOLE_MACOS_STARTUP_TICKS, 0.1s per tick), so they cannot drift apart:
# cover the shim's whole startup budget, THEN still allow the original 5s for
# claude to become visible once the window is actually up. Every macOS launch
# pays this, including one with an explicit KONSOLE_CMD (still an `open -a`-
# shaped launch - see KONSOLE_IS_MACOS_SHIM above); konsole keeps today's 5s.
#
# 10# is load-bearing, not decoration: the shim reads the same var in a `[ ]`
# test, which is always decimal, while THIS is an arithmetic context, where a
# leading zero is octal. Unnormalised, KONSOLE_MACOS_STARTUP_TICKS=0200 makes
# this budget 128 ticks while the shim still waits 200 -- the exact drift the
# shared var exists to prevent -- and 08/09 abort the arm outright with
# "value too great for base".
if [ "$KONSOLE_IS_MACOS_SHIM" = "1" ]; then
    SESSION_VISIBLE_RETRY_ITERS=$(( 10#${KONSOLE_MACOS_STARTUP_TICKS:-200} * 2 + SESSION_VISIBLE_RETRY_ITERS ))
fi
claimed=0
n=0
while :; do
    session_confirmed "[c]laude .*-n $NAME_ERE( |\$)"; sc_rc=$?
    if [ "$sc_rc" -eq 0 ]; then
        echo "$(date +%F_%T) a session named $NAME is already running - not launching" >> "$LOG"
        exit 0
    elif [ "$sc_rc" -eq 2 ]; then
        echo "headed-arm: pgrep scan failed checking for an existing session named $NAME - refusing to treat an indeterminate scan as 'nothing running' (HIMMEL-2545)" >&2
        echo "$(date +%F_%T) INDETERMINATE: pgrep scan failed checking for $NAME - refusing rather than risk a duplicate" >> "$LOG"
        exit 9
    fi
    if claim_lock; then claimed=1; break; fi
    n=$((n+1))
    [ "$n" -lt "$CLAIM_RETRY_ITERS" ] || break
    sleep "$CLAIM_RETRY_SLEEP"
done
# r3-codex-1: exhausting the retry budget used to exit 0, sharing its exit
# code with the genuine-dedup branch above. A holder that crashes while its
# lock is still FRESH (age < STALE_LOCK_SECS) cannot be stolen from for
# 120s - not extended here, a 120s block would be worse - so a contender
# that gives up after ~2s without ever seeing pgrep confirm a running
# session has NOT deduped against anything real: the armed successor may be
# genuinely lost, and reporting that as exit 0 success is exactly the class
# of bug r2-codex-2 already fixed for an unwritable lock root. An
# indeterminate outcome must not share an exit code with a confirmed one.
if [ "$claimed" -ne 1 ]; then
    echo "$(date +%F_%T) UNRESOLVED: a launch for $NAME is still claimed after waiting, and no running session was ever confirmed - the armed successor may be lost" >> "$LOG"
    exit 6
fi

# r7-codex-2: pgrep was only ever checked BEFORE acquiring the lock. A
# contender can see "no session" there, get descheduled, and by the time it
# actually acquires the lock - freed by the ORIGINAL holder's own
# successful launch and release - a genuine session now exists; launching
# at that point would create a real duplicate, exactly the race this lock
# exists to close. Re-check immediately after acquiring, before konsole is
# ever touched: if a session now exists, release the lock this arm just
# took and defer to it instead of launching a duplicate.
session_confirmed "[c]laude .*-n $NAME_ERE( |\$)"; sc_rc=$?
if [ "$sc_rc" -eq 0 ]; then
    echo "$(date +%F_%T) a session named $NAME appeared after this arm claimed the lock - releasing and not launching" >> "$LOG"
    rm -rf "$LOCK" 2>/dev/null
    exit 0
elif [ "$sc_rc" -eq 2 ]; then
    echo "headed-arm: pgrep scan failed re-checking for $NAME right after claiming the lock - refusing to launch on an indeterminate scan (HIMMEL-2545)" >&2
    echo "$(date +%F_%T) INDETERMINATE: pgrep scan failed re-checking for $NAME after claiming the lock - releasing rather than launch blind" >> "$LOG"
    rm -rf "$LOCK" 2>/dev/null
    exit 9
fi

cd "$REPO" || { rm -rf "$LOCK" 2>/dev/null; exit 1; }
# HIMMEL-3403: a headless launch never reaches konsole; headless_launch exits.
if [ "$HEADLESS" = "1" ]; then
    headless_launch
fi
# r6-codex (session-id leak): env -u cleared CLAUDE_CODE_CHILD_SESSION and
# CLAUDE_PID but NOT CLAUDE_CODE_SESSION_ID, so the launched claude PROCESS
# inherited the ARMING session's id in its own environ. claude generates
# its own session id and exports the CORRECT one to ITS OWN tool
# subprocesses, so context-fill.sh and anything reading its own env are
# unaffected - what was polluted is the claude process's environ itself,
# exactly the surface this ticket taught people to inspect
# (/proc/<claude pid>/environ), so a stale id there actively misled that
# diagnostic and is how one console came to see another's session id.
# r8-codex-4: `--separate` (equivalently `--nofork`) forces konsole to run
# in its own process rather than handing this invocation off to an
# ALREADY-RUNNING konsole instance and letting the pid backgrounded below
# exit immediately - opt-in behaviour verified on this machine
# (`konsole --help` lists it). Without it, the pid this script owns is not
# necessarily the window that got created, so the aliveness check right
# below means nothing on a station that already has a konsole open.
# HIMMEL-2534 (codex-review I6): the recorder branch below runs
# `script -q -a -f "$LOG" -c "$LAUNCH_CMD"`, which is util-linux syntax. BSD
# script (macOS) has neither -f nor -c ("illegal option -- f"; it takes the
# file positionally and the command as trailing argv), so on a Mac the branch
# dies in milliseconds. That is not a rare seam: console-kit/headed-arm-leg.sh
# exports HEADED_ARM_RECORDER=1 unconditionally for --lane claudex. Refuse
# with the real reason instead of letting the lane fail as a mystery FAILED.
# Gated on KONSOLE_IS_RESOLVED_SHIM, not the platform: with an explicit
# KONSOLE_CMD the `script` argv is handed to a launcher of the caller's
# choosing and may never be executed by BSD script at all (every existing
# --lane claudex case passes a recording stub), so refusing there would
# break a launch that works.
# The lock is already CLAIMED by this point, and this script has no EXIT
# trap - every other refusal past the claim releases it by hand (the two
# session_confirmed branches and the `cd "$REPO"` guard just above all do).
# Without the release here the refusal holds $LOCK for STALE_LOCK_SECS, so
# the re-arm that follows it -- and on a Mac --lane claudex refuses EVERY
# time, so there always is one -- dies in the claim-retry loop as exit 6
# "the armed successor may be lost" instead of reporting this real reason.
if [ "$RECORDER" = "1" ] && [ "$KONSOLE_IS_RESOLVED_SHIM" = "1" ]; then
    echo "headed-arm: HEADED_ARM_RECORDER=1 is not supported on macOS - the recorder uses util-linux 'script -f/-c' syntax that BSD script rejects, so the --lane claudex tty recorder cannot run here (HIMMEL-2534)" >&2
    rm -rf "$LOCK" 2>/dev/null
    exit 2
fi
if [ "$RECORDER" = "1" ]; then
    # HIMMEL-2782: give the launcher a real tty via `script` rather than
    # execing it straight under konsole -e (see the RECORDER seam doc
    # above). $LAUNCH_CMD is a single shell-quoted argv string built with
    # bash's own %q, which `script -c` hands to the shell named by ITS OWN
    # $SHELL (or /bin/sh if unset) - NOT necessarily bash (codex-2, HIMMEL-2782
    # CR fix: a zsh launching shell would otherwise leak into script's
    # environment and interpret bash's %q quoting under zsh's own rules).
    # BASH_BIN below is passed through `env` as SHELL=... so `script -c`
    # always interprets $LAUNCH_CMD with the same shell that quoted it,
    # regardless of the launching shell. $LAUNCHER itself is NOT
    # force-wrapped in `bash` (codex CR fix) - the default/non-recorder
    # branch below execs it directly via its own shebang, and forcing
    # `bash "$LAUNCHER"` here only for the recorder path broke a non-bash-script
    # HEADED_ARM_LEG_CLAUDEX_BIN override (e.g. a compiled binary or a python
    # entrypoint) that works fine under plain exec.
    BASH_BIN="$(command -v bash || echo /bin/bash)"
    LAUNCH_CMD=$(printf '%q ' "${LAUNCH_ARGV[@]}")
    # shellcheck disable=SC2086  # LAUNCHER_ENV is a deliberately
    # word-split list of NAME=VALUE tokens (HEADED_ARM_LAUNCHER_ENV's
    # documented contract above), never a single value.
    # shellcheck disable=SC2094  # script -a -f appends the terminal
    # transcript to $LOG; the outer >> "$LOG" separately captures konsole's
    # own launch stdout/stderr (spawn errors before script even starts) into
    # the same file. -a is load-bearing (codex CR fix): without it, `script
    # -f` TRUNCATES $LOG on open, discarding whatever the outer >> already
    # wrote there.
    # shellcheck disable=SC2086  # ROLE_ENV_UNSET is either empty or the
    # single literal token pair "-u HIMMEL_CONSOLE_RELAY" (HIMMEL-2975) --
    # deliberately unquoted, same word-split contract as LAUNCHER_ENV above.
    "$KONSOLE" --separate --workdir "$REPO" -p "tabtitle=$NAME" \
        -e env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID $ROLE_ENV_UNSET \
            CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 HIMMEL_INITIATIVE="$INIT" ARMAUTOMERGE=1 ${CONSOLE_ENV[@]+"${CONSOLE_ENV[@]}"} SHELL="$BASH_BIN" $LAUNCHER_ENV \
            script -q -a -f "$LOG" -c "$LAUNCH_CMD" \
        >> "$LOG" 2>&1 &
else
    # shellcheck disable=SC2086  # LAUNCHER_ENV word-split, same contract as
    # the recorder branch above (codex CR fix: this branch dropped it).
    # shellcheck disable=SC2086  # ROLE_ENV_UNSET, same contract as the
    # recorder branch above (HIMMEL-2975).
    "$KONSOLE" --separate --workdir "$REPO" -p "tabtitle=$NAME" \
        -e env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID $ROLE_ENV_UNSET \
            CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 HIMMEL_INITIATIVE="$INIT" ARMAUTOMERGE=1 ${CONSOLE_ENV[@]+"${CONSOLE_ENV[@]}"} $LAUNCHER_ENV \
            "${LAUNCH_ARGV[@]}" \
        >> "$LOG" 2>&1 &
fi
KPID=$!

# HIMMEL-3279: the arm log ($LOG) lives on tmpfs under /run/user and is gone
# at the next reboot, and it is the only place a console's launch context was
# recorded - so the attribution HIMMEL-2973 needs was unrecoverable for every
# console before the last boot. Write the mode durably, at launch (retention
# on a timer would still lose whatever was written since its last copy), as a
# row in the HIMMEL-3270 launch record dir (btrfs, already the cost cohort's
# source, already removed by uninstall): one more line format in the same
# per-session file, keyed `headed-arm:` so it cannot read as a leg's
# `headed-arm-leg:` profile line. Console arms only - a leg's own record is
# headed-arm-leg.sh's, and it is always `standard`. Best-effort like that
# one: a record that cannot be written is noted in $LOG, never stops the
# launch (the reader then says `unknown`, never a proxy). The row itself comes
# from console_context_write_record (scripts/lib/console-context.sh), the same
# function arm-resume.sh calls (HIMMEL-3282), so the two arming paths write one
# shape.
if [ "$ROLE" = "console" ]; then
    if ! console_context_write_record "$NAME" "$CONTEXT" "$_headed_context_source" "$AUTOCOMPACT"; then
        echo "$(date +%F_%T) WARN context record NOT written under ${CONSOLE_CONTEXT_RECORD_DIR:-<no cache dir>} (this console's launch context is unrecoverable after a reboot)" >> "$LOG"
    fi
fi

# codex-1: settle briefly, then note whether the process still looks alive
# - see the header CR-fixes note.
sleep 0.3
sv_alive=0
if kill -0 "$KPID" 2>/dev/null; then
    sv_alive=1
    echo "$(date +%F_%T) konsole launched pid=$KPID for $NAME" >> "$LOG"
    # HIMMEL-2658: same stdout-report-not-error reasoning as arm-resume.sh's
    # context line -- report the resolved mode next to the launch record it
    # governs, not just at usage-error time.
    echo "$(date +%F_%T) $CONTEXT_REASON (autocompact=$AUTOCOMPACT)" >> "$LOG"
    # HIMMEL-2534 (codex-review C1): record the reconciled budget next to the
    # launch it governs, same stdout-report-not-error reasoning as the context
    # line above. An UNCONFIRMED on a Mac is then readable against the budget
    # that actually applied, instead of the 5s konsole default one might assume.
    if [ "$KONSOLE_IS_MACOS_SHIM" = "1" ]; then
        echo "$(date +%F_%T) macOS launch: session-visibility budget $SESSION_VISIBLE_RETRY_ITERS iters x ${SESSION_VISIBLE_RETRY_SLEEP}s (covers the launcher startup budget of ${KONSOLE_MACOS_STARTUP_TICKS:-200} ticks, then the standard post-launch allowance)" >> "$LOG"
    fi
fi
# r8-codex-4: even with --separate above, a dead pid at this point is not
# treated as failure ON ITS OWN anymore - `kill -0` failing used to
# short-circuit straight to FAILED (exit 1), which inverted round 4's fix
# on any station where a hand-off (or a future konsole ignoring the flag)
# let this pid exit after a launch that actually SUCCEEDED. The
# session_confirmed() poll below now ALWAYS runs regardless of $sv_alive;
# only "never confirmed AND the pid is also gone" reaches exit 1 below.
#
# r3-codex-2: the lock used to be released the instant konsole survived the
# 0.3s settle, before the named claude process was actually visible to
# pgrep. During a slow terminal/claude startup, another contender could
# claim the freed lock in that window and launch a genuine duplicate.
# Poll for the SAME literal-name match the dedup layers use, on a bounded
# budget; release regardless once the budget expires (holding the lock
# forever is worse than a rare missed duplicate window), but log a slow
# start plainly so it is visible rather than silent.
sv_n=0
sv_seen=0
sv_indeterminate=0
while :; do
    session_confirmed "[c]laude .*-n $NAME_ERE( |\$)"; sc_rc=$?
    if [ "$sc_rc" -eq 0 ]; then sv_seen=1; break; fi
    if [ "$sc_rc" -eq 2 ]; then sv_indeterminate=1; break; fi
    sv_n=$((sv_n+1))
    [ "$sv_n" -lt "$SESSION_VISIBLE_RETRY_ITERS" ] || break
    sleep "$SESSION_VISIBLE_RETRY_SLEEP"
done
# r4-codex-1: the budget expiring used to log a WARNING and still exit 0
# -- the SAME code as "launched and confirmed". A konsole that survives
# its 0.3s settle but whose claude child then fails (or never appears)
# was reported as a successfully armed successor when no session
# exists: the same class this file has now fixed twice (exit 5 for an
# unwritable lock root, exit 6 for an exhausted claim retry). An
# outcome we could not CONFIRM must not share an exit code with one we
# did. The lock is still released either way -- holding it forever is
# worse -- but a confirmed launch and an unconfirmed one are DIFFERENT
# outcomes now.
#
# RESOLVED IN FAVOUR OF LOUDNESS, deliberately: a genuinely slow
# terminal/claude startup now also reports failure, and that is
# accepted - a claude process appears in pgrep at exec time, long
# before it finishes loading, and the budget above is already ~5s
# (SESSION_VISIBLE_RETRY_ITERS * SLEEP). A 5s miss on a process that
# should already be exec'd is genuinely suspicious, not routine, so
# treating it as confirmed-failure is the correct default, not an
# overreaction.
rm -rf "$LOCK" 2>/dev/null
if [ "$sv_indeterminate" -eq 1 ]; then
    echo "headed-arm: pgrep scan failed confirming the post-launch session for $NAME - refusing to report an indeterminate scan as either success or failure (HIMMEL-2545)" >&2
    echo "$(date +%F_%T) INDETERMINATE: pgrep scan failed confirming $NAME after launch" >> "$LOG"
    exit 9
fi
if [ "$sv_seen" -eq 1 ]; then
    exit 0
fi
# r8-codex-4: only reached once session_confirmed has ALSO never found a
# real claude process within the whole post-launch budget - see the note
# above the poll. A dead pid alone is no longer sufficient on its own.
if [ "$sv_alive" -eq 1 ]; then
    echo "$(date +%F_%T) UNCONFIRMED: konsole (pid $KPID) survived its settle, but $NAME never became visible to pgrep within the post-launch budget - no session was ever confirmed for $NAME" >> "$LOG"
    exit 7
fi
echo "$(date +%F_%T) FAILED: konsole (pid $KPID) exited immediately for $NAME - see $LOG for its output" >> "$LOG"
exit 1
