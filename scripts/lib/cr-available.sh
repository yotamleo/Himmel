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

cr_app_configured() {
    # The explicit opt-out wins over every signal below — an operator who set it
    # is telling us the answer, and HIMMEL-1072 documents it as THE switch for a
    # CodeRabbit-less repo.
    [ "${CR_PROFILE:-}" = "none" ] && return 1

    case "${CR_APP:-}" in
        1) return 0 ;;
        0) return 1 ;;
    esac

    local dir="${1:-$PWD}" val
    # --local, not plain --get: a value in ~/.gitconfig would arm EVERY repo on
    # the machine, which is the same over-reach as the inherited config file.
    # Availability is per-repo. In a worktree this reads the shared .git/config,
    # so arming the primary checkout arms its worktrees too — which is right:
    # they are the same repo.
    # --bool lets git normalize its OWN boolean spellings (true/1/yes/on ->
    # "true"; false/0/no/off/"" -> "false") and, importantly, ERROR on a
    # non-boolean value (coderabbit-14) — so a typo is a hard "not armed" rather
    # than a silent maybe. On error/unset the substitution is empty; only a
    # normalized "true" arms.
    # `|| val=""` (codex-1, PR #1470 round 2): git config exits nonzero on an
    # unset key, and a failing `val=$(...)` ASSIGNMENT propagates that status —
    # under a caller's `set -e` a bare `cr_app_configured` call would abort the
    # caller right here instead of returning rc 1 as the header promises.
    # Current callers are condition-context (`|| return 0`), which suspends
    # set -e, but the sourceable contract must hold for bare calls too.
    val=$(cd "$dir" 2>/dev/null && git config --bool --local --get himmel.coderabbit 2>/dev/null) || val=""
    [ "$val" = "true" ] && return 0
    # Anything else — unset, false, a non-boolean, or not a repo at all — is NOT
    # an armed gate. Default-disarmed is the whole posture: the adopter who has no
    # CodeRabbit does nothing and is never blocked.
    return 1
}
