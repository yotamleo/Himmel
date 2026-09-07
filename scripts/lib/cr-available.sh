#!/usr/bin/env bash
# cr-available.sh — the ONE answer to "is CodeRabbit's App configured for THIS
# repo?" (HIMMEL-1125).
#
# WHY THIS EXISTS — the adopter-hostile default it removes:
# HIMMEL-1072 made an ABSENT CodeRabbit verdict a BLOCKER ("an unreviewed head
# is not a green one"). That is right for a repo that HAS CodeRabbit. But the
# harness ships to adopters who do not, and for them "absent" is the permanent
# steady state — so `check-ci.sh` exited 2 and `cr_merge_gate` blocked EVERY
# merge, forever, until they happened to discover `CR_PROFILE=none`. The gate was
# armed by default on repos it could never pass on.
#
# The fix is not to weaken the gate — it is to arm it only where it can mean
# something.
#
# WHICH SURFACE THIS PROBE COVERS (the load-bearing distinction):
# CodeRabbit has two independent surfaces and they arm DIFFERENT gates:
#
#   the CLI  -> reviews a local diff at PRE-PUSH. Posts nothing to GitHub: no
#               commit status, no review thread. Its availability probe already
#               lives in scripts/cr/coderabbit-review.sh (native PATH, else WSL)
#               and arms exactly one thing — /pr-check's CLI finding pass.
#   the App  -> reviews the PR AFTER `gh pr create`. It is the ONLY surface that
#               posts the commit status cr-signal.sh reads and the review threads
#               check-ci gates on.
#
# Everything here gates POST-PR state, so it describes the APP and must not
# consult the CLI: a machine with the CLI but no App would arm a status gate that
# can never go green, and an App-only repo with no local CLI would lose the gate.
# Each surface arms the bar it actually covers.
#
# THE SIGNAL: a repo-scoped, NON-VERSIONED git config value.
#
#   git config --local himmel.coderabbit true
#
# Why not the committed `.coderabbit.yaml` (rejected — codex-adv-1, operator
# call 2026-07-17)? Because a committed file is not evidence of an App
# INSTALLATION, and it is wrong in BOTH directions:
#   - Config WITHOUT the App: `.coderabbit.yaml` is tracked, so every clone/fork
#     of a CodeRabbit repo inherits it while inheriting no App installation. Since
#     this harness ships BY being cloned, that is the MAIN adopter path — and it
#     would arm their gate and block every merge forever. Precisely the bug this
#     ticket exists to remove.
#   - App WITHOUT config: an App running on defaults publishes no config, so the
#     gate would silently disarm on a repo that really does have CodeRabbit.
# A file the PR can edit is also attacker-controlled at exactly the moment the
# gate matters: a diff that DELETED the config would disarm the very CodeRabbit
# requirement reviewing it. `git config --local` lives in `.git/config` — it is
# not part of any tree, so it cannot be inherited by a fork, cannot be added or
# deleted by a PR, and says something about THIS clone rather than about a file
# someone copied.
#
# THE TRADE-OFF, STATED PLAINLY: this REVERSES the HIMMEL-1072 fail-closed
# default. An operator who never arms a repo silently has no CodeRabbit merge
# gate there. That is the accepted cost of never blocking an adopter who does not
# have CodeRabbit at all (the ticket's hard requirement), and it is why arming is
# a documented setup step. `/himmel-doctor` growing a "repo has .coderabbit.yaml
# but is not armed" check is the natural follow-up.
#
# cr_app_configured [<dir>]
#   rc 0 = CodeRabbit's App is configured here -> CR-specific gates are ARMED
#   rc 1 = absent -> CR-specific gates are a NO-OP (never block, never warn)
#   <dir> defaults to $PWD; the probe resolves the enclosing repo.
#   Silent: prints nothing on either path. An adopter must not notice it exists.
#
# Env:
#   CR_PROFILE=none      forces rc 1. The established opt-out (HIMMEL-1072 —
#                        check-ci / cr-merge-gate read it), kept authoritative so
#                        an operator who already set it sees no change. Any OTHER
#                        value is a critic-TIER filter (free,paid — see
#                        .env.example), NOT an availability signal: only `none` is
#                        read here. To force the gate ON, use CR_APP=1.
#   CR_APP=1|0           explicit override + the test seam. Wins over the git
#                        config; loses to CR_PROFILE=none.
#
# SCOPE: this describes the LOCAL clone. It cannot speak for a different repo —
# see cr-merge-gate.sh, which refuses to apply the local answer to a foreign
# `--repo` target rather than guessing (codex-adv-2).
#
# Sourceable from hooks and scripts: uses only `return`, never `exit`; does not
# toggle set -e. bash 3.2-safe.

# cr_app_state [<dir>] (HIMMEL-2380)
#   Echoes ONE word on stdout — WHY the gates above are armed or not — and
#   always returns 0. Nothing is ever written to stderr.
#
#     armed           -> CodeRabbit's App is configured here; gates ARE armed.
#     not-configured  -> nothing was ever set. THE adopter. Nothing is missing,
#                        because nothing was expected: callers stay SILENT here.
#     disabled        -> a deliberate act — CR_PROFILE=none, CR_APP=0, or
#                        `himmel.coderabbit false`. Someone chose this.
#     broken          -> the marker IS set, to a value `git config --bool`
#                        cannot parse.
#
# WHY `broken` is a separate word, and the only one that is a defect:
# cr_app_configured returns 1 for `broken` exactly as it does for the adopter
# (test-cr-available.sh case 5 pins that, and it stays pinned — default-disarmed
# is the posture). Those two rc-1s mean opposite things. The adopter has no
# CodeRabbit and is correctly never blocked. The `broken` repo HAS CodeRabbit,
# lost its gate to a typo, and every green it certifies afterwards asserts a
# review that never ran — the one genuinely VACUOUS pass in this design, and
# invisible today because the parse error is swallowed. This file's own header
# predicted it and parked it as a /himmel-doctor follow-up; naming the state is
# what lets a caller speak up.
#
# What callers must NOT do with it: narrate `not-configured`. "An adopter must
# not notice it exists" is a tested invariant (case 15 here, and
# scripts/test-check-ci.sh case 57 greps a whole clean adopter run for the word
# "CodeRabbit"). HIMMEL-2380 asked for an unconditional "CodeRabbit: not
# configured" line; console ruling 88 narrowed it to the states where a review
# was actually EXPECTED — a pass is only vacuous when something was missing.
#
# Separating `broken` from unset needs a SECOND read, because --bool collapses
# them: it exits 128 on a bad boolean and 1 on an unset key, but both leave the
# capture empty. A plain --local --get succeeds only when the key exists. Both
# reads are --local, so a value in ~/.gitconfig is no more this repo's state
# here than it is above (case 14 / case 24).
cr_app_state() {
    # Precedence is cr_app_configured's, unchanged and deliberately so: the
    # explicit opt-out is read BEFORE the marker, so it names the state even
    # over a broken marker. An operator who set CR_PROFILE=none is not waiting
    # to hear about a typo in a marker their own setting already overrides.
    [ "${CR_PROFILE:-}" = "none" ] && { printf 'disabled\n'; return 0; }

    case "${CR_APP:-}" in
        1) printf 'armed\n'; return 0 ;;
        0) printf 'disabled\n'; return 0 ;;
    esac

    local dir="${1:-$PWD}" val
    val=$(cd "$dir" 2>/dev/null && git config --bool --local --get himmel.coderabbit 2>/dev/null) || val=""
    case "$val" in
        true)  printf 'armed\n'; return 0 ;;
        false) printf 'disabled\n'; return 0 ;;
    esac

    # --bool yielded nothing: the key is either unset or unparseable. Only this
    # second, non---bool read tells them apart. stdout is discarded — its
    # SUCCESS is the whole signal — and stderr with it, so a caller capturing
    # our stdout never also catches git's "bad boolean config value" complaint.
    if ( cd "$dir" 2>/dev/null && git config --local --get himmel.coderabbit ) >/dev/null 2>&1; then
        printf 'broken\n'
    else
        printf 'not-configured\n'
    fi
    return 0
}

# cr_app_configured is now the yes/no VIEW of cr_app_state — one probe, one
# place the git config is read, exactly as this file's header argues. Its
# contract is unchanged and pinned by cases 1-15 + the case-26 negative
# controls: rc 0 only for `armed`, rc 1 for every other state, silent on both.
# (The old `|| val=""` note about set -e no longer applies here — there is no
# assignment left to propagate a nonzero status — but it still guards the read
# inside cr_app_state above, for the same reason it always did.)
cr_app_configured() {
    [ "$(cr_app_state "${1:-$PWD}")" = "armed" ]
}
