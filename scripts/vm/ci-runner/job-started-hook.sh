#!/usr/bin/env bash
# job-started-hook.sh — the runner-side fork guard for the himmel-vm
# self-hosted runner (HIMMEL-5037). Installed in the guest image and wired as
# ACTIONS_RUNNER_HOOK_JOB_STARTED, so the runner runs it before the first step
# of EVERY job; a non-zero exit fails the job before any workflow code runs.
#
# Why a runner-side guard as well as the ci.yml `if:`: the repo is public, and
# a fork PR can propose a workflow that names `runs-on: himmel-vm` itself. The
# workflow-level guard lives in the very file such a PR edits; this one lives
# in the VM image, outside anything a PR can change.
#
# Allowed (everything else exits 1):
#   push              to refs/heads/main only
#   pull_request      whose head repo IS this repo (never a fork), started by
#                     the operator's accounts (below)
#   workflow_dispatch started by the operator's accounts (below), any ref
#   schedule          (runs the default branch's workflow)
# The operator's accounts are yotamleo and yotamleo11-test: GITHUB_ACTOR (who
# started the run) and, when set, GITHUB_TRIGGERING_ACTOR (who re-ran it) must
# both be one of them. A same-repo branch can carry any workflow and a
# collaborator's PR is same-repo, so repo membership alone is not trusted. A
# pull_request additionally needs the PR's author (pull_request.user.login) and
# the event's sender to be operator accounts: an owner re-running a Dependabot or
# third-party same-repo PR must not run its code here (HIMMEL-5070).
# GITHUB_REPOSITORY must equal HIMMEL_CI_RUNNER_REPO (baked into the image).
set -u

deny() { echo "himmel-vm fork guard: REFUSED — $1" >&2; exit 1; }

owner_only() {
    local a
    for a in "${GITHUB_ACTOR:-}" "${GITHUB_TRIGGERING_ACTOR:-${GITHUB_ACTOR:-}}"; do
        case "$a" in
            yotamleo|yotamleo11-test) ;;
            *) deny "$GITHUB_EVENT_NAME started by '${a:-<none>}', not an operator account" ;;
        esac
    done
}

want="${HIMMEL_CI_RUNNER_REPO:-}"
[ -n "$want" ] || deny "HIMMEL_CI_RUNNER_REPO is not set in the runner environment"
[ "${GITHUB_REPOSITORY:-}" = "$want" ] || deny "repository '${GITHUB_REPOSITORY:-}' is not '$want'"
[ -r "${GITHUB_EVENT_PATH:-}" ] || deny "no readable event payload at '${GITHUB_EVENT_PATH:-}'"

case "${GITHUB_EVENT_NAME:-}" in
    push)
        [ "${GITHUB_REF:-}" = "refs/heads/main" ] || deny "push to '${GITHUB_REF:-}', not refs/heads/main"
        ;;
    pull_request)
        { IFS= read -r head; IFS= read -r author; IFS= read -r sender; } < <(python3 -c '
import json, sys
try:
    e = json.load(open(sys.argv[1]))
    print(e["pull_request"]["head"]["repo"]["full_name"])
    print(e["pull_request"]["user"]["login"])
    print(e["sender"]["login"])
except Exception:
    pass
' "$GITHUB_EVENT_PATH")
        [ "$head" = "$want" ] || deny "pull_request head repo '${head:-<none>}' is not '$want' (fork PRs run on hosted runners)"
        owner_only
        for a in "$author" "$sender"; do
            case "$a" in
                yotamleo|yotamleo11-test) ;;
                *) deny "pull_request author/sender '${a:-<none>}' is not an operator account" ;;
            esac
        done
        ;;
    workflow_dispatch) owner_only ;;
    schedule) ;;
    *) deny "event '${GITHUB_EVENT_NAME:-}' is not routed to this runner" ;;
esac
echo "himmel-vm fork guard: allowed ${GITHUB_EVENT_NAME} on ${GITHUB_REPOSITORY} (${GITHUB_REF:-})"
