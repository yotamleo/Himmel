#!/usr/bin/env bash
# scripts/cr/coderabbit-review.sh - CodeRabbit CLI finding pass for /pr-check (HIMMEL-926).
#
# Runs `coderabbit review` over the current branch's COMMITTED diff vs the base
# branch and prints the findings on stdout, so /pr-check can merge them as
# [coderabbit-N] blocking candidates (same merge contract as the codex
# adversarial pass, step 3.1). Availability-gated + fail-open: a missing CLI,
# a dead WSL, a timeout, a rate-limit/quota-exhaustion, or a CodeRabbit error
# never blocks the gate - the caller degrades to the remaining critics.
#
# Invocation lanes (resolved in order):
#   1. native - `coderabbit` on PATH (Linux/macOS, or any host with a native
#               install). Always available when present - never gated.
#   2. wsl    - Windows host with the CLI installed inside WSL. OPT-IN via
#               CODERABBIT_ALLOW_WSL=1 (HIMMEL-1339) - probing wsl.exe is what
#               BOOTS the whole distro (and dockerd/containerd/ollama with it,
#               HIMMEL-1314) just to answer "is the CLI here?", so this lane is
#               skipped by default rather than paying that cost on every run.
#               The CodeRabbit APP is the default/primary reviewer on Windows
#               (structural PR-create trigger, HIMMEL-1362); this lane is for
#               an operator who deliberately wants the local CLI pass too.
#   Neither -> exit 3 with a one-line skip note (caller prints it and moves on).
#
# Both lanes review a TEMP CLONE of the primary checkout, not the live tree:
#   - WSL git cannot resolve a Windows-created worktree (the worktree's .git
#     pointer file holds a C:/ absolute path), and /pr-check usually runs from
#     a worktree.
#   - The clone pins the review to committed state - uncommitted noise in the
#     working tree never leaks into the review.
# The clone is cheap (single-branch, --no-tags).
#
# Usage: coderabbit-review.sh [--branch <b>] [--base <ref>] [--base-sha <sha>] [--head <sha>]
#   default --branch = current branch; default --base = repo default branch.
#   --head <sha> PINS the review to the SHA the caller captured (HIMMEL-1175);
#   --base-sha <sha> pins the BASE end of the reviewed range (HIMMEL-1984).
#     7-64 hex chars only - a revision expression (`HEAD`, a branch name) is
#     refused, because git resolves it dynamically and it would follow the very
#     checkout move the pin exists to catch.
#     /pr-check captures branch+HEAD up front and stamps its ledger rows with
#     that SHA, but this pass reviewed whatever `refs/heads/<branch>` pointed at
#     when it ran — so a checkout that moved mid-run (a same-SHA branch switch
#     is the case clear-cr-marker.sh cannot catch) recorded a review of code
#     that was never reviewed. With --head the run REFUSES (exit 5) unless the
#     reviewed branch's tip still equals the pin, instead of silently reviewing
#     live state.
#
# Env: CODERABBIT_CLI_DISABLE - operator opt-out (HIMMEL-1314). Set to exactly
#          "1" to skip the CLI leg entirely and exit 3, for setups where the
#          CodeRabbit APP already reviews every PR in CI and a second, local
#          pass is duplicated spend against the same rate-limited account.
#          Checked BEFORE lane resolution so a disabled run never probes
#          wsl.exe - on Windows that probe is what BOOTS the WSL distro (and
#          with it dockerd/containerd/ollama), so a late check would still pay
#          the cost this switch exists to avoid. Only "1" activates; any other
#          value (including "0") leaves the CLI enabled, matching the
#          HIMMEL_HEADROOM_PROXY convention.
#      CODERABBIT_ALLOW_WSL - operator opt-IN (HIMMEL-1339). The wsl lane is
#          skipped by default (exit 3, same skip contract as CLI_DISABLE)
#          because PROBING wsl.exe for the binary is what boots the distro -
#          the cost was already paid just to find out the CLI isn't wanted.
#          Set to exactly "1" to allow this lane. Same set-ness/live-env-wins
#          bridge convention as CODERABBIT_CLI_DISABLE.
#      CODERABBIT_TIMEOUT_SECS - wall-clock cap for the review call inside the
#          clone; clone/fetch use one quarter (default 900).
#      CODERABBIT_BIN - test seam: overrides the binary probed/invoked.
#      CODERABBIT_WSL - test seam: overrides the wsl.exe launcher (also lets a
#          POSIX test force the wsl lane).
#
# stdout = CodeRabbit findings (--agent mode). stderr = one panel-availability line
# in the ledger contract (slug = 2nd token, status = 3rd token):
#   "panel-availability: coderabbit ok"
#   "panel-availability: coderabbit unavailable (rc=N)"
#   "panel-availability: coderabbit unavailable (rc=0) reason=relay-lost"
#     - rc=0 with an UNAVAILABLE line. Not a contradiction: the review itself
#       completed, but its findings reached neither stdout nor the ledger, so
#       nobody can read them. The rc contract coderabbit-gate.sh consumes does
#       not move; the availability line carries the truth (HIMMEL-2321).
# Exit: 0 = review completed (zero findings included); 1 = review failed
# (fail-open at caller); 2 = usage; 3 = not configured (skip, no availability
# line - a machine without the CLI is not a critic drop-out); 4 = rate-limited
# or quota-exhausted (a MISSING review signal - the caller records it
# unavailable and retries later, distinct from a skip and from a real failure);
# 5 = REFUSED before anything was reviewed - an ABORT, never a degrade. Two
#     causes share this code because they share that contract and the caller's
#     correct response (re-run /pr-check from step 1); the specific one is on
#     STDERR, which coderabbit-gate.sh relays:
#       (a) --head/--base-sha pin mismatch - the checkout or the base branch
#           moved since the caller captured its inputs;
#       (b) a setup failure that would make (a) or the review's own output
#           silently degrade - the pin refusal channel (mktemp -d, HIMMEL-1175)
#           or the stdout relay file (mktemp, HIMMEL-2321) could not be created.
# bash 3.2-safe.
set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<'EOF'
Usage: coderabbit-review.sh [--branch <b>] [--base <ref>] [--base-sha <sha>] [--head <sha>]

Reviews the branch's committed diff vs the base via the CodeRabbit CLI
(native PATH install, or inside WSL on Windows) in a temp clone of the
primary checkout. stdout = findings; stderr = one panel-availability line.
--head <sha> pins the review to the caller's captured SHA (HIMMEL-1175);
--base-sha <sha> pins the other end of the range, the caller's captured BASE
SHA, so a base branch that moved since capture refuses too (HIMMEL-1984).
Exit: 0 review completed; 1 review failed (fail-open); 2 usage; 3 CLI absent; 4 rate-limited/quota; 5 --head/--base-sha pin mismatch.
EOF
}

BRANCH=""
BASE=""
HEAD_PIN=""
BASE_SHA_PIN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --branch) [ $# -ge 2 ] || { echo "coderabbit-review: --branch needs an argument" >&2; exit 2; }; BRANCH="$2"; shift 2 ;;
        --base)   [ $# -ge 2 ] || { echo "coderabbit-review: --base needs an argument" >&2; exit 2; }; BASE="$2"; shift 2 ;;
        --base-sha) [ $# -ge 2 ] || { echo "coderabbit-review: --base-sha needs an argument" >&2; exit 2; }; BASE_SHA_PIN="$2"; shift 2 ;;
        --head)   [ $# -ge 2 ] || { echo "coderabbit-review: --head needs an argument" >&2; exit 2; }; HEAD_PIN="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "coderabbit-review: unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$BRANCH" ] || BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ -n "$BRANCH" ] || { echo "coderabbit-review: no --branch and cannot resolve current branch" >&2; exit 2; }
if [ -z "$BASE" ]; then
    # shellcheck disable=SC1091
    BASE="$(. "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null && default_branch || echo main)"
fi
if [ "$BRANCH" = "$BASE" ]; then
    echo "coderabbit-review: branch equals base ($BASE) - nothing to review" >&2
    exit 2
fi
# Both names ride the wsl.exe command line as positional args - refuse anything
# outside the safe ref-name alphabet rather than trying to quote it through.
case "$BRANCH$BASE" in
    *[!A-Za-z0-9._/+-]*) echo "coderabbit-review: branch/base contains unsupported characters" >&2; exit 2 ;;
esac

# HIMMEL-1175 — input pinning. The review below clones `refs/heads/$BRANCH` as
# it stands NOW, but the caller (/pr-check) stamps its ledger rows with the SHA
# it captured up front. Without this check a checkout that moved between capture
# and review (the same-SHA branch switch clear-cr-marker.sh cannot catch) has the
# new code reviewed and the OLD sha certified. Verified BEFORE the lane probes so
# a stale-input run never boots WSL or spends a scarce CodeRabbit call. Both
# sides go through rev-parse so a short pin compares equal to a full tip.
if [ -n "$HEAD_PIN" ]; then
    # Hex-only, 7..64 chars (HIMMEL-1175, codex-3): a permissive alphanumeric
    # class also accepts `HEAD` or a branch name, which git resolves DYNAMICALLY
    # — a "pin" that follows the checkout is not a pin at all. Only an immutable
    # object name is accepted.
    case "$HEAD_PIN" in
        *[!0-9a-fA-F]*) echo "coderabbit-review: --head must be a commit SHA, not a revision expression (got: $HEAD_PIN)" >&2; exit 2 ;;
    esac
    # Upper bound 64, not 40: a SHA-256 git repository names commits with 64 hex
    # chars, and a 40 cap would reject every full OID there (panel r5).
    if [ "${#HEAD_PIN}" -lt 7 ] || [ "${#HEAD_PIN}" -gt 64 ]; then
        echo "coderabbit-review: --head must be a 7-64 character commit SHA (got: $HEAD_PIN)" >&2
        exit 2
    fi
    # Deliberately `refs/heads/$BRANCH`, NOT the checkout's current branch: this
    # pass never reads a working tree, it clones the NAMED branch below. So the
    # captured `--branch` IS the review target and verifying its tip is what
    # pins the review — a checkout that switched to another branch cannot change
    # what gets reviewed here, and requiring the checkout to still be on $BRANCH
    # would refuse the supported shape where /pr-check runs from another
    # worktree. (critic-panel.sh needs the extra branch-identity check because
    # ITS diff and ledger stamp do come from the live checkout.)
    _tip="$(git rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}" 2>/dev/null)" || _tip=""
    _pin="$(git rev-parse --verify --quiet "$HEAD_PIN^{commit}" 2>/dev/null)" || _pin=""
    if [ -z "$_pin" ]; then
        echo "coderabbit-review: REFUSING - --head $HEAD_PIN does not resolve to a commit in this repository (HIMMEL-1175)" >&2
        exit 5
    fi
    if [ "$_tip" != "$_pin" ]; then
        echo "coderabbit-review: REFUSING - branch $BRANCH is at ${_tip:-<unresolvable>} but the review was pinned to $_pin; the checkout moved since the caller captured its inputs, so this review would be recorded against a SHA it never covered (HIMMEL-1175). Re-run /pr-check from step 1." >&2
        exit 5
    fi
fi

# HIMMEL-1984 — the BASE end of the same range. --head froze the branch tip, but
# the base was still whatever `refs/heads/$BASE` pointed at when the inner clone
# fetched it — and unlike the panel's three-dot diff, this lane hands that TIP to
# the CodeRabbit CLI, so a base that moved between the caller's capture and this
# review changes what the vendor tool compares against. `refs/heads/$BASE` (not a bare
# `$BASE`) is deliberate: that is the exact ref the inner script fetches, and a
# bare name would also match a tag. Same refusal contract as --head: exit 5,
# before the lane probes, so nothing is reviewed and no scarce call is spent.
if [ -n "$BASE_SHA_PIN" ]; then
    case "$BASE_SHA_PIN" in
        *[!0-9a-fA-F]*) echo "coderabbit-review: --base-sha must be a commit SHA, not a revision expression (got: $BASE_SHA_PIN)" >&2; exit 2 ;;
    esac
    if [ "${#BASE_SHA_PIN}" -lt 7 ] || [ "${#BASE_SHA_PIN}" -gt 64 ]; then
        echo "coderabbit-review: --base-sha must be a 7-64 character commit SHA (got: $BASE_SHA_PIN)" >&2
        exit 2
    fi
    _base_tip="$(git rev-parse --verify --quiet "refs/heads/$BASE^{commit}" 2>/dev/null)" || _base_tip=""
    _bpin="$(git rev-parse --verify --quiet "$BASE_SHA_PIN^{commit}" 2>/dev/null)" || _bpin=""
    if [ -z "$_bpin" ]; then
        echo "coderabbit-review: REFUSING - --base-sha $BASE_SHA_PIN does not resolve to a commit in this repository (HIMMEL-1984)" >&2
        exit 5
    fi
    if [ "$_base_tip" != "$_bpin" ]; then
        echo "coderabbit-review: REFUSING - base $BASE is at ${_base_tip:-<unresolvable>} but the review was pinned to base $_bpin; the base branch moved since the caller captured its inputs, so this review would cover a different range than the one the caller computed (HIMMEL-1984). Re-run /pr-check from step 1." >&2
        exit 5
    fi
fi

# Operator opt-out (HIMMEL-1314), checked BEFORE any lane resolution. On a
# Windows host the lane probe shells out to wsl.exe, which BOOTS the distro
# (and everything that autostarts in it) purely to answer "is the CLI here?" —
# so an opt-out placed after that probe would still pay the cost it exists to
# avoid. Exits 3, the established not-configured/skip contract: the caller
# prints the note, records NO availability line, and the panel/codex legs
# still cover the SHA. Exact-"1" only, matching HIMMEL_HEADROOM_PROXY.
# Bridge the flag from the primary checkout's .env when the process env carries
# no signal, mirroring how clear-cr-marker.sh bridges CR_REQUIRE_CROSS_MODEL and
# /pr-check bridges CR_PROFILE — so the opt-out holds when this script is invoked
# directly or from a worktree (a worktree has no .env of its own). A live env
# value wins outright. Unlike that gate's flag this one can only make the run do
# LESS work, never weaken a gate: skipping records no availability row, so the
# marker still needs a real responder from the panel/codex legs. That is why a
# .env read failure here is non-fatal — it just leaves the CLI enabled (the
# pre-1314 behaviour), rather than refusing.
# Set-NESS test (+x), not emptiness (:-): an explicitly empty live
# CODERABBIT_CLI_DISABLE= is a deliberate "leave the CLI on" override and must
# win over .env, which is what "a live env value wins" above promises. With
# `:-` an empty live value read as unset, fell through to the bridge, and a
# .env value of 1 would then skip the CLI against the operator's explicit
# instruction. Matches arm-resume.sh's HIMMEL_HEADROOM_PROXY convention.
if [ -z "${CODERABBIT_CLI_DISABLE+x}" ] && [ -f "$SCRIPT_DIR/../lib/load-dotenv.sh" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/../lib/load-dotenv.sh"
    load_dotenv CODERABBIT_CLI_DISABLE 2>/dev/null || true
fi
if [ "${CODERABBIT_CLI_DISABLE:-}" = "1" ]; then
    echo "coderabbit pass skipped (CODERABBIT_CLI_DISABLE=1 — the CodeRabbit App reviews in CI)" >&2
    exit 3
fi

# WSL lane opt-IN (HIMMEL-1339). Default OFF: unlike CODERABBIT_CLI_DISABLE
# (an opt-OUT of the whole CLI leg), this narrows just the wsl.exe fallback —
# a native install (macOS/Linux, or any future native Windows binary) is
# NEVER gated by this and reaches LANE="native" below regardless. It exists
# because on a Windows host with no native binary, the wsl.exe PROBE ITSELF
# boots the distro (dockerd/containerd/ollama autostart alongside it,
# HIMMEL-1314 measured vmmemWSL at 3.45GB) — so leaving the fallback
# opt-out (rather than opt-in) still pays that cost on every /pr-check run
# unless CODERABBIT_CLI_DISABLE is ALSO set. Same bridge/set-ness convention
# as CODERABBIT_CLI_DISABLE just above.
if [ -z "${CODERABBIT_ALLOW_WSL+x}" ] && [ -f "$SCRIPT_DIR/../lib/load-dotenv.sh" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/../lib/load-dotenv.sh"
    load_dotenv CODERABBIT_ALLOW_WSL 2>/dev/null || true
fi

# Timeout validation (same convention as critic-panel.sh).
CODERABBIT_TIMEOUT_SECS="${CODERABBIT_TIMEOUT_SECS:-900}"
if expr "$CODERABBIT_TIMEOUT_SECS" : '^[0-9][0-9]*$' > /dev/null 2>&1 && [ "$CODERABBIT_TIMEOUT_SECS" -gt 0 ]; then
    : # valid
else
    echo "coderabbit-review: CODERABBIT_TIMEOUT_SECS=$CODERABBIT_TIMEOUT_SECS invalid, using 900" >&2
    CODERABBIT_TIMEOUT_SECS="900"
fi

# Clone source = the PRIMARY checkout root (worktree branches live in its
# shared refs; a worktree path itself is not cloneable from WSL).
common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
[ -n "$common" ] || { echo "coderabbit-review: not in a git repository" >&2; exit 2; }
SRC="$(cd "$common/.." && pwd -P)" || { echo "coderabbit-review: cannot resolve primary checkout from $common" >&2; exit 2; }

CR_BIN="${CODERABBIT_BIN:-coderabbit}"
WSL_BIN="${CODERABBIT_WSL:-wsl.exe}"
case "$CR_BIN" in
    *[!A-Za-z0-9._/-]*) echo "coderabbit-review: CODERABBIT_BIN contains unsupported characters" >&2; exit 2 ;;
esac

# Lane resolution: native binary first, then WSL probe (Windows) — the WSL
# probe itself is gated on CODERABBIT_ALLOW_WSL=1 (HIMMEL-1339): probing
# wsl.exe is what boots the distro, so an unset/non-"1" value skips straight
# to the "neither" skip below rather than paying that cost by default.
LANE=""
if command -v "$CR_BIN" >/dev/null 2>&1; then
    LANE="native"
elif [ "${CODERABBIT_ALLOW_WSL:-}" = "1" ] && command -v "$WSL_BIN" >/dev/null 2>&1; then
    probe_rc=0
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 5 30 "$WSL_BIN" -e bash -lc "command -v $CR_BIN" >/dev/null 2>&1 || probe_rc=$?
    else
        "$WSL_BIN" -e bash -lc "command -v $CR_BIN" >/dev/null 2>&1 || probe_rc=$?
    fi
    if [ "$probe_rc" -eq 0 ]; then
        LANE="wsl"
        # WSL consumes Windows paths only after wslpath translation; hand it the
        # mixed form (C:/...) which survives the command line unmangled.
        if command -v cygpath >/dev/null 2>&1; then
            SRC="$(cygpath -m "$SRC")"
        fi
    elif [ "$probe_rc" -eq 124 ] || [ "$probe_rc" -eq 137 ]; then
        echo "panel-availability: coderabbit unavailable (WSL probe timeout 30s)" >&2
        exit 1
    fi
fi
if [ -z "$LANE" ]; then
    if [ "${CODERABBIT_ALLOW_WSL:-}" != "1" ] && command -v "$WSL_BIN" >/dev/null 2>&1; then
        echo "coderabbit pass skipped (no native CLI; WSL lane available but not enabled — set CODERABBIT_ALLOW_WSL=1 to allow booting WSL for it, or leave it off and rely on the CodeRabbit App, HIMMEL-1339)" >&2
    else
        echo "coderabbit pass skipped (coderabbit CLI not found on PATH or in WSL)" >&2
    fi
    exit 3
fi

# Inner script, shared by both lanes. Runs under the TARGET bash (native or
# WSL) with positional args: $1=src $2=branch $3=base $4=timeout-secs $5=bin
# $6=head-pin (may be empty) $7=pin-flag dir $8=base-pin (may be empty).
# A C:/ src is translated via wslpath (present only inside WSL). Clone, fetch,
# and review are timeboxed when coreutils timeout exists; degrade without it
# (same graceful-degrade convention as critic-panel.sh). --agent = the
# agent-readable output mode the coderabbitai/skills code-review skill
# prescribes (findings grouped Critical/Warning/Info).
# shellcheck disable=SC2016  # single-quoted on purpose: expands in the TARGET shell
INNER='set -u
src="$1"; branch="$2"; base="$3"; to="$4"; bin="$5"
# ${6:-}/${7:-}, not $6/$7: an EMPTY trailing arg (the unpinned case) can be
# dropped on the way through wsl.exe, and under `set -u` a bare $6 would then
# abort the whole inner script instead of running an unpinned review.
# $6/$7/$8 are the two pins and the refusal-channel dir. Each can be "not set",
# and an EMPTY arg is not a safe way to say that here: an empty TRAILING arg can
# be dropped on the way through wsl.exe, which would shift every later arg by one
# (HIMMEL-1984 — with two independent pins, "head unset, base set" would otherwise
# slide the pinflag PATH into $pin and compare it as a SHA). The outer passes a
# literal `-` for every unset slot instead, so no arg is ever empty and position
# is stable; ${N:-} still guards a caller that predates the sentinel.
pin="${6:-}"; [ "$pin" = "-" ] && pin=""
# Directory the OUTER script owns, where this one drops a marker file if the
# clone-time pin check refuses. A marker is unambiguous where an exit code is
# not: no code is reserved (the CodeRabbit CLI can return any of them), and
# re-deriving the fact from the mutable branch tip afterwards is guesswork
# (panel r7). Translated like $src because a Windows path reaches us as C:/...
pinflag="${7:-}"; [ "$pinflag" = "-" ] && pinflag=""
case "$pinflag" in [A-Za-z]:/*) pinflag="$(wslpath -a "$pinflag")" ;; esac
basepin="${8:-}"; [ "$basepin" = "-" ] && basepin=""
op_to=$((to / 4))
# Floor the per-git-step timeout: clone/fetch here are LOCAL ops (<1s normally),
# but a slow machine (Windows Git-Bash) can exceed a tiny op_to and time the
# clone out BEFORE the review runs, masking the rate-limit path (HIMMEL-1219
# T12). 15s is generous for a local clone and never bites production, where the
# default to=900 gives op_to=225.
[ "$op_to" -ge 15 ] || op_to=15
run_git_step() {
    step="$1"; shift
    step_rc=0
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 5 "$op_to" "$@" || step_rc=$?
    else
        "$@" || step_rc=$?
    fi
    if [ "$step_rc" -eq 124 ] || [ "$step_rc" -eq 137 ]; then
        echo "coderabbit-review: $step timed out after ${op_to}s" >&2
    fi
    return "$step_rc"
}
case "$src" in [A-Za-z]:/*) src="$(wslpath -a "$src")" ;; esac
tmp="$(mktemp -d -t coderabbit-cr.XXXXXX)" || exit 1
trap '\''rm -rf "$tmp"'\'' EXIT
run_git_step "git clone" git clone --quiet --no-tags --single-branch --branch "$branch" "$src" "$tmp/repo" || exit $?
cd "$tmp/repo" || exit 1
# HIMMEL-1175 (codex-2) — the outer pre-flight check verified the branch tip
# BEFORE this clone, leaving a window in which the branch could advance and this
# clone snapshot a commit the caller never pinned. The clone IS what gets
# reviewed, so verify the pin against the snapshot itself: this check is the one
# that cannot be raced. Exit 5 = the outer refusal contract (nothing reviewed).
if [ -n "$pin" ]; then
    cloned="$(git rev-parse HEAD 2>/dev/null || true)"
    if [ "$cloned" != "$pin" ]; then
        echo "coderabbit-review: REFUSING - the review clone came up at ${cloned:-<unresolvable>} but the review was pinned to $pin; $branch advanced during the clone (HIMMEL-1175)" >&2
        # The MARKER is what the outer lane classifies on; the exit code is only
        # a hint. A CLI failure can carry any code, so a code alone can never
        # separate "this script refused" from "the CLI exited with that number".
        # The outer refuses to start a pinned run without a writable channel,
        # so this write failing is not a reachable degrade in practice - but say
        # so loudly if it ever does, because the outer would then report this
        # refusal as an ordinary review failure (panel r8, codex-1).
        if [ -n "$pinflag" ] && ! : > "$pinflag/pin-mismatch" 2>/dev/null; then
            echo "coderabbit-review: WARNING - could not write the pin refusal marker under $pinflag; the outer lane will report this refusal as an ordinary review failure (HIMMEL-1175)" >&2
        fi
        exit 97
    fi
fi
run_git_step "git fetch" git fetch --quiet origin "+refs/heads/$base:refs/heads/$base" || exit $?
# HIMMEL-1984 — the base half of the clone-time check. The outer verified the
# base tip BEFORE the clone, leaving the same unraceable-only-here window the
# head pin closed: a fetch landing in the primary between the two would put a
# base in this clone that the caller never pinned. The FETCHED ref is what the
# review diffs against, so verify that.
if [ -n "$basepin" ]; then
    cbase="$(git rev-parse --verify --quiet "refs/heads/$base^{commit}" 2>/dev/null || true)"
    if [ "$cbase" != "$basepin" ]; then
        echo "coderabbit-review: REFUSING - the review clone fetched base $base at ${cbase:-<unresolvable>} but the review was pinned to base $basepin; the base branch moved during the clone (HIMMEL-1984)" >&2
        if [ -n "$pinflag" ] && ! : > "$pinflag/pin-mismatch" 2>/dev/null; then
            echo "coderabbit-review: WARNING - could not write the pin refusal marker under $pinflag; the outer lane will report this refusal as an ordinary review failure (HIMMEL-1984)" >&2
        fi
        exit 97
    fi
fi
# Point the clone origin at the real upstream so CodeRabbit attributes the
# review to the org plan (HIMMEL-1219). Live evidence (2026-07-20 /pr-check on
# this repo): with origin left as the local primary-checkout filesystem path,
# CodeRabbit reported isProUser:false, orgAttributed:false and the message
# "...will use the free CLI allowance" / "Rate limit exceeded ... waitTime 13
# minutes ... cannot apply an organization plan until this repository is
# connected to CodeRabbit", even though the repo IS connected (the CodeRabbit
# App posts reviews + statuses on its PRs). The CLI matches a review to an
# organization by reading the origin URL; a filesystem path matches nothing,
# so every CLI review burned the free tier instead of the paid org plan - the
# most plausible cause of the exhaustion this ticket exists to manage.
#
# ORDERING IS LOAD-BEARING. The clone + fetch above run while origin is still
# the local path (fast, no network, no credentials). Only AFTER the fetch do
# we rewrite origin to the upstream URL. CodeRabbit reads the URL for
# attribution only and never fetches from it; rewriting before the fetch would
# turn the fetch into a slow network op that needs credentials.
upstream="$(git -C "$src" remote get-url origin 2>/dev/null || true)"
if [ -z "$upstream" ]; then
    # No origin in the primary checkout: CodeRabbit cannot attribute this
    # review to an org. Never fail the review over attribution - proceed on
    # the free allowance exactly as before.
    echo "coderabbit-review: primary checkout has no origin remote; review will use the free CLI allowance" >&2
else
    # SECURITY: strip any embedded credential (user:token@ or bare token@)
    # from an HTTPS origin before writing it into the temp clone config. A
    # credential must not reach disk even briefly (the temp dir is removed on
    # exit, but a secret is never written in the first place). SSH forms
    # (git@github.com:owner/repo.git, ssh://git@host/...) carry no secret -
    # the userinfo is the conventional git SSH username - so they pass
    # through verbatim. Only http(s)://userinfo@host is rewritten, to the
    # bare scheme://host. The [^/]* class matches up to the LAST @ in the
    # authority (greedy, but it cannot cross a slash), so even a malformed
    # password containing a literal @ is fully stripped, while an @ that
    # lives in the PATH (after a slash) is never mistaken for userinfo.
    clean_url="$(printf '\''%s\n'\'' "$upstream" | sed -E '\''s#^(https?://)[^/]*@#\1#'\'')"
    git remote set-url origin "$clean_url" 2>/dev/null \
        || echo "coderabbit-review: git remote set-url failed; review will use the free CLI allowance" >&2
fi
# Capture the review call so a rate-limit/quota message can be classified
# from the CLI text. The CLI exit code is NOT a stable signal for rate-
# limiting - a 429 currently lands as rc=1 (generic failure), which the
# caller fails OPEN, dropping a missing-review signal silently. Streams
# replay to their original fds on the success path so findings still reach
# stdout unchanged.
review_out="$tmp/review.out"
review_err="$tmp/review.err"
if command -v timeout >/dev/null 2>&1; then
    timeout -k 5 "$to" "$bin" review --agent --type committed --base "$base" >"$review_out" 2>"$review_err"
else
    "$bin" review --agent --type committed --base "$base" >"$review_out" 2>"$review_err"
fi
review_rc=$?
if [ "$review_rc" -eq 124 ] || [ "$review_rc" -eq 137 ]; then
    # Timeout. Two defects both lived here, both fixed:
    # 1. A review that hangs BECAUSE it is being rate-limited must NOT surface
    #    as a generic timeout (rc=124). That is exactly the silent-fail-open
    #    shape this ticket exists to kill: under a bare rc=124 a rate-limited
    #    reviewer is indistinguishable from a slow one, and the caller fails
    #    open on it. Run the SAME rate-limit grep the non-timeout path uses
    #    against both captured streams and classify rc=4 when it matches,
    #    rc=124 otherwise.
    # 2. Emit both captured streams. A timed-out run previously discarded
    #    $review_out / $review_err entirely (they were never emitted on this
    #    path), so a hang yielded zero diagnostic output - you could not tell
    #    why it hung. They are not valid findings, so they go to stderr.
    cat "$review_err" >&2
    cat "$review_out" >&2  # not valid findings - surface for debug, keep stdout clean
    if grep -Ei "rate[ -]?limit|429|too many requests|quota" "$review_out" "$review_err" >/dev/null 2>&1; then
        exit 4
    fi
    exit 124  # genuine timeout - let the outer lane map it to the timeout-flavored line
fi
# Rate-limit/quota detection from the CLI text (case-insensitive, both
# streams - wording and stream choice are not a stable contract). Only
# checked on a FAILED review so a successful run with incidental matching
# text (e.g. a finding that quotes "quota") is never misclassified. Prefer
# a false-positive (loud + retryable) over a false-negative (silent fail-
# open = the bug being fixed).
if [ "$review_rc" -ne 0 ] && grep -Ei "rate[ -]?limit|429|too many requests|quota" "$review_out" "$review_err" >/dev/null 2>&1; then
    cat "$review_err" >&2
    cat "$review_out" >&2  # not valid findings - surface for debug, keep stdout clean
    exit 4
fi
cat "$review_err" >&2
if [ "$review_rc" -eq 0 ]; then
    cat "$review_out"
else
    cat "$review_out" >&2  # not valid findings - keep stdout clean
fi
exit "$review_rc"'

# HIMMEL-2321 -- self-write CodeRabbit findings into the CR ledger, so /pr-check
# step 4.5 never has to retype CodeRabbit finding text into a shell fence (a
# reviewer-authored title containing an apostrophe breaks out of the single
# quotes the runbook pastes it into -- the vulnerability this ticket closes).
# Mirrors critic-panel.sh's existing self-write shape (--batch-file, HIMMEL-2052):
# one node process builds the batch JSONL (safe JSON escaping, no shell
# quoting of reviewer text at all), verdict left empty exactly like the
# panel writes it, so the session's later verdict-only call converges via
# ledger-append.sh's amend carve-out.
#
# Schema (confirmed against the CLI's real --agent JSONL, the same stream
# scripts/cr/pr-check-external.sh already parses): a finding line is
# {"type":"finding","severity":"critical|major|minor","fileName":"<path>",
# "codegenInstructions":"<text>"} -- no line-number field, so the ledger row
# always carries an empty line (HIMMEL-1494's citation-less-finding shape).
# Severity mapping (.claude/commands/pr-check.md step 3.2, HIMMEL-926):
# critical->crit, major->imp, minor->sug; a missing/unrecognized severity
# maps to imp (conservative -- still blocking, not silently downgraded to a
# non-blocking Suggestion).
# ids are minted coderabbit-1, coderabbit-2, ... in stream order, the exact
# mechanical rule the runbook already documents for the session to follow by
# hand (pr-check.md step 3.2 phase B, HIMMEL-926) -- a producer numbering
# them itself changes nothing about what a session doing it by hand would
# have produced, on the SAME stream.
#
# Best-effort: a ledger-write failure warns on stderr and never turns a
# successful review into a failed one. Unlike critic-panel.sh (which owns its
# own exit-code contract and decertifies a run on a ledger-write failure),
# coderabbit-review.sh's exit code is a load-bearing contract consumed by
# coderabbit-gate.sh (out of this ticket fence) -- changing its shape on a
# ledger hiccup is a wider change than this ticket, so stdout/exit code stay
# byte-identical to today on every path; only the ADDITIONAL ledger rows are
# new.
# Set to 1 by _cr_ledger_self_write ONLY when the batch actually reached the
# ledger. Read by the relay-loss check below (HIMMEL-2321 CR round 1, codex-1).
_CRL_PERSISTED=0
_cr_ledger_self_write() {
    # HIMMEL-2321 codex-1/codex-2 fix: takes a FILE PATH, never a captured
    # string -- so the caller can just `cat` it for byte-exact stdout instead
    # of capturing it into a variable (command substitution strips trailing
    # newlines; a captured empty-vs-nonempty check also had to gate the
    # eventual print, which this removes). The reviewer output is already a
    # file (redirected there by the caller) - no separate staging copy needed.
    _crl_file="$1"
    [ -s "$_crl_file" ] || return 0
    # HIMMEL-2321 CR round 3 (codex-1, HIMMEL-1175 head-drift class): only
    # the CALLER's pinned --head proves what the review actually saw. A
    # post-hoc `git rev-parse refs/heads/$BRANCH` here would resolve the
    # branch tip AFTER the review returns - a commit landing on the branch
    # DURING the review would silently re-key these findings onto a commit
    # the reviewer never reviewed. Skip rather than guess: unpinned runs
    # (direct invocation, no --head) get no self-write, same as any other
    # unresolvable-head case below.
    _crl_head="${_pin:-}"
    if [ -z "$_crl_head" ]; then
        echo "coderabbit-review: no --head pin - cannot prove what commit this review covered, CR-ledger self-write skipped (HIMMEL-2321/HIMMEL-1175)" >&2
        return 0
    fi
    _crl_batch="$(mktemp -t coderabbit-ledger-batch.XXXXXX)" || { echo "coderabbit-review: mktemp failed -- CR-ledger self-write skipped (HIMMEL-2321)" >&2; return 0; }
    if BRANCH="$BRANCH" HEAD_SHA="$_crl_head" node -e '
        const e=process.env;
        const lines=require("fs").readFileSync(0,"utf8").split("\n").filter(Boolean);
        let n=0; const out=[];
        for (const line of lines) {
            let obj;
            try { obj=JSON.parse(line); } catch { continue; }
            if (!obj || obj.type !== "finding") continue;
            n++;
            const sevRaw=String(obj.severity||"").toLowerCase();
            const sev = sevRaw==="critical" ? "crit" : sevRaw==="minor" ? "sug" : "imp";
            const row={branch:e.BRANCH, head:e.HEAD_SHA, model:"coderabbit", id:"coderabbit-"+n,
                       severity:sev, file:obj.fileName||"", line:"", verdict:""};
            if (obj.codegenInstructions) row.text=String(obj.codegenInstructions);
            out.push(JSON.stringify(row));
        }
        process.stdout.write(out.length ? out.join("\n")+"\n" : "");
    ' < "$_crl_file" > "$_crl_batch"; then
        if [ -s "$_crl_batch" ]; then
            # HIMMEL-2321 CR round 1 (codex-1): remember whether the rows
            # ACTUALLY landed. The self-write stays best-effort (it never
            # changes rc), but "the ledger has them" is the fallback the
            # availability line below leans on when the stdout relay fails --
            # so it has to be a fact, not an assumption.
            if bash "$SCRIPT_DIR/ledger-append.sh" finding --batch-file "$_crl_batch" >&2; then
                _CRL_PERSISTED=1
            else
                echo "coderabbit-review: CR-ledger self-write failed -- findings still printed on stdout, but the ledger is missing them until the next successful run (HIMMEL-2321)" >&2
            fi
        fi
    else
        echo "coderabbit-review: failed to build CR-ledger batch rows from the review output -- self-write skipped (HIMMEL-2321)" >&2
    fi
    rm -f "$_crl_batch"
}

rc=0
# HIMMEL-2321 codex-1/codex-2 fix: redirect the reviewer invocation's stdout
# to a FILE, never capture it into a shell variable via $(...) - command
# substitution unconditionally strips every trailing newline (codex-2), and a
# captured string forced an `if rc -eq 0` gate around the eventual print that
# the pre-ticket direct invocation never had (codex-1: on the OLD code, the
# inner script's own stdout was the outer script's stdout, so whatever the
# inner wrote reached real stdout regardless of the outer's later exit-code
# classification). `cat`ing this file on every path below reproduces that
# byte-exact, unconditionally - same mktemp-failure convention as
# PIN_FLAG_DIR just below (check status, exit 5 loudly, never silently
# degrade to losing output).
REVIEW_STDOUT_FILE="$(mktemp -t coderabbit-stdout.XXXXXX)" || { echo "coderabbit-review: REFUSING - cannot create the stdout capture file (mktemp failed), so review output could not be safely relayed (HIMMEL-2321)" >&2; exit 5; }
# ${_pin:-} / ${_bpin:-} = the resolved full SHAs when --head / --base-sha were
# given, else empty (the inner script skips the matching clone-time check when a
# pin is unset). They cross the boundary as `-` when unset, never as an empty
# arg: wsl.exe can drop an empty TRAILING arg, and with two independent pins that
# would shift the remaining args by one. PIN_FLAG_DIR is the side channel the
# inner uses to say "I refused" — see the classification below; EITHER pin needs it.
PIN_FLAG_DIR=""
PIN_FLAG_ARG=""
if [ -n "${_pin:-}" ] || [ -n "${_bpin:-}" ]; then
    # The marker dir IS the refusal channel, so a pinned run that cannot create
    # one must not start (panel r8, codex-1): the inner script would still exit
    # 97 on a clone-time mismatch, the outer would find no marker, and the
    # refusal would degrade into an ordinary fail-open review failure - the exact
    # silent degrade --head exists to prevent. Refuse up front instead.
    PIN_FLAG_DIR="$(mktemp -d -t coderabbit-pin.XXXXXX)" || PIN_FLAG_DIR=""
    if [ -z "$PIN_FLAG_DIR" ]; then
        echo "coderabbit-review: REFUSING - cannot create the pin refusal channel (mktemp -d failed), so a clone-time pin mismatch could not be reported and would fail open (HIMMEL-1175)" >&2
        rm -f "$REVIEW_STDOUT_FILE"
        exit 5
    fi
    PIN_FLAG_ARG="$PIN_FLAG_DIR"
fi
if [ "$LANE" = "native" ]; then
    # HIMMEL-2321: redirected to REVIEW_STDOUT_FILE (see its mktemp comment
    # above), never captured into a variable.
    bash -c "$INNER" coderabbit-review "$SRC" "$BRANCH" "$BASE" "$CODERABBIT_TIMEOUT_SECS" "$CR_BIN" "${_pin:--}" "${PIN_FLAG_ARG:--}" "${_bpin:--}" > "$REVIEW_STDOUT_FILE" || rc=$?
else
    # WSL reads Windows paths only after wslpath translation; hand it the mixed
    # form (C:/...) the inner script knows how to translate, same as $SRC.
    # Same reasoning as the mktemp refusal above (panel r8, codex-1): an
    # UNtranslated MSYS path (/tmp/...) makes the inner script write its marker
    # inside WSL's own /tmp, where the outer can never read it, so the refusal
    # would fail open. Translate it or refuse - never hand WSL a path only this
    # side of the boundary understands. The dir is still empty here, so rmdir.
    if [ -n "$PIN_FLAG_ARG" ]; then
        _pin_flag_win="$(cygpath -m "$PIN_FLAG_ARG" 2>/dev/null)" || _pin_flag_win=""
        if [ -z "$_pin_flag_win" ]; then
            echo "coderabbit-review: REFUSING - cannot translate the pin refusal channel for WSL (cygpath unavailable), so a clone-time pin mismatch could not be reported and would fail open (HIMMEL-1175)" >&2
            rmdir "$PIN_FLAG_DIR" 2>/dev/null || true
            rm -f "$REVIEW_STDOUT_FILE"
            exit 5
        fi
        PIN_FLAG_ARG="$_pin_flag_win"
    fi
    # MSYS arg conversion would rewrite /-prefixed fragments inside the inner
    # script on the way to a native exe - disable it for this one call.
    # HIMMEL-2321: redirected, same reason as the native lane above.
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
        "$WSL_BIN" -e bash -lc "$INNER" coderabbit-review "$SRC" "$BRANCH" "$BASE" "$CODERABBIT_TIMEOUT_SECS" "$CR_BIN" "${_pin:--}" "${PIN_FLAG_ARG:--}" "${_bpin:--}" > "$REVIEW_STDOUT_FILE" || rc=$?
fi

# Classify the clone-time refusal from the MARKER, never from the exit code
# (panel r7): no code is reserved — the CodeRabbit CLI can return 97 as easily
# as 5 — and re-deriving the fact afterwards from the mutable branch tip is
# guesswork (the branch can move again, in either direction, meanwhile). An
# UNPINNED run has no marker dir at all and therefore can never be classified
# as a pin mismatch, which is what makes --head genuinely optional.
PIN_MISMATCH=0
if [ -n "$PIN_FLAG_DIR" ]; then
    [ -f "$PIN_FLAG_DIR/pin-mismatch" ] && PIN_MISMATCH=1
    rm -rf "$PIN_FLAG_DIR"
fi

# HIMMEL-2321 codex-1/codex-2 fix: self-write, then relay stdout byte-exact
# on EVERY path below - not just rc==0 - matching the pre-ticket direct
# invocation, where the inner script's own stdout WAS this script's stdout
# regardless of the eventual exit-code classification. On every failure path
# the inner script itself already sent review_out to STDERR instead (see the
# INNER heredoc above: "not valid findings - keep stdout clean"), so this
# file is simply empty there - `cat` reproduces that with no special-casing.
# A ledger-write failure only warns (see _cr_ledger_self_write above), it
# never withholds output.
_cr_ledger_self_write "$REVIEW_STDOUT_FILE"
# HIMMEL-2321 CR round 3 (codex-3): check cat's own status - a broken pipe or
# read error here must be visible, not swallowed. Warn only: the exit-code
# contract below (coderabbit-gate.sh consumes it) is keyed on the REVIEW's
# rc, not the relay's, so a cat failure never changes it. Round 1 of THIS
# PR extends that: the rc still never moves, but when the relay AND the
# ledger self-write both fail the availability line downgrades to
# unavailable (see the relay-loss check below) - a warning alone let a
# review whose findings reached nobody still record as ok.
# Whether there was anything to deliver, captured BEFORE the relay consumes and
# removes the file (HIMMEL-2321 CR round 1, codex-1).
_CR_HAD_OUTPUT=0
[ -s "$REVIEW_STDOUT_FILE" ] && _CR_HAD_OUTPUT=1
_CR_RELAY_RC=0
cat "$REVIEW_STDOUT_FILE" || _CR_RELAY_RC=$?
[ "$_CR_RELAY_RC" -eq 0 ] || echo "coderabbit-review: WARNING - failed to relay review output from $REVIEW_STDOUT_FILE (cat rc=$_CR_RELAY_RC) - findings may be lost on this run (HIMMEL-2321)" >&2
rm -f "$REVIEW_STDOUT_FILE"

# HIMMEL-2321 CR round 1 (codex-1): the relay warning above and the ledger
# self-write are BOTH best-effort, and each is a fine fallback for the other --
# but when they fail TOGETHER on a review that had output, the findings exist
# nowhere: not on stdout, not in the ledger. rc stays 0 (the contract
# coderabbit-gate.sh consumes is keyed on the REVIEW's own rc and this PR does
# not move it), so the honest signal is the AVAILABILITY line: a review whose
# findings were lost did not happen as far as the gate is concerned, exactly
# like a rate-limited one. `ok` here would let clear-cr-marker.sh gate 3
# certify a review nobody can read (HIMMEL-1126 fail-closed-on-attempted).
if [ "$rc" -eq 0 ] && [ "$_CR_HAD_OUTPUT" -eq 1 ] && [ "$_CR_RELAY_RC" -ne 0 ] && [ "$_CRL_PERSISTED" -ne 1 ]; then
    echo "coderabbit-review: findings were LOST - the stdout relay failed and the CR-ledger self-write did not persist them either; recording the reviewer unavailable rather than ok, so the marker cannot clear on a review nobody can read (HIMMEL-2321)" >&2
    echo "panel-availability: coderabbit unavailable (rc=0) reason=relay-lost" >&2
    exit 0
fi

if [ "$rc" -eq 0 ]; then
    echo "panel-availability: coderabbit ok" >&2
    exit 0
fi
if [ "$PIN_MISMATCH" = "1" ]; then
    # Nothing was reviewed, so — exactly like the pre-flight refusal — emit NO
    # availability line: an availability row would tell the ledger a reviewer
    # had an opinion about this SHA.
    echo "coderabbit pass REFUSED - the review clone did not come up at the pinned inputs (head=${_pin:-<none>} base=${_bpin:-<none>}); nothing was reviewed (HIMMEL-1175/HIMMEL-1984)" >&2
    exit 5
fi
if [ "$rc" -eq 97 ]; then
    # 97 without the marker is the CodeRabbit CLI's own exit code, not this
    # script's refusal — an ordinary review failure that fails OPEN.
    echo "coderabbit-review: the CodeRabbit CLI exited 97 and the clone-pin marker was NOT set - ordinary review failure, not a pin mismatch (HIMMEL-1175)" >&2
fi
if [ "$rc" -eq 4 ]; then
    # Rate-limited/quota-exhausted: a MISSING review signal, distinct from a
    # real failure (rc=1) and from not-configured (rc=3). Surface a loud
    # retry-later note for a reader scanning the output, then the availability
    # line so the caller records unavailable (never ok - a rate-limited
    # reviewer never happened, and clear-cr-marker.sh gate 3 would otherwise
    # clear the marker on a review that did not run).
    echo "coderabbit pass rate-limited/quota-exhausted - retry later" >&2
    echo "panel-availability: coderabbit unavailable (rc=4)" >&2
    exit 4
fi
if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "panel-availability: coderabbit unavailable (timeout ${CODERABBIT_TIMEOUT_SECS}s)" >&2
else
    echo "panel-availability: coderabbit unavailable (rc=$rc)" >&2
fi
exit 1
