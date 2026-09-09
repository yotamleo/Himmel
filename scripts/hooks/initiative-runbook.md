# Initiative runbook

The full text behind the `HIMMEL_INITIATIVE` / `HIMMEL_INITIATIVE_OVERNIGHT`
SessionStart pointer (`scripts/hooks/inject-initiative.sh`, HIMMEL-2036). The
hook injects ~370 B naming the **active steps** and pointing here; this file
carries the bodies. The pointer names the two moments to open it, and an
ordinary session opens it at neither:

- **On a handover resume** — read "First — seed the tasklist" below. It has no
  step token and is not gated by `Active steps:`; it applies whenever this
  session was resumed from a handover.
- **At a natural completion point** — read the `## Steps` sections named by the
  pointer's `Active steps:` line, and ignore the rest.

Take initiative: drive the current work to done without waiting for an explicit
"ship it" each time. Fire only at a *natural completion point* (a logical chunk
of work is finished AND verified), never on every small edit, and never
mid-task.

## First — seed the tasklist (HIMMEL-539)

If this session was resumed from a handover (you were asked to "load
`<handover>`"), seed your native tasklist from the handover's ordered step list
BEFORE anything else, whatever heading that list uses (e.g. a "How to execute" /
numbered-steps section): call `TaskCreate` once per step, then `TaskUpdate` each
task as you start and finish it so progress stays glanceable. Keeping it updated
through the run is best-effort. If you were not resumed from a handover, skip
this.

## Steps

Steps run in this canonical order; only the tokens on the pointer's
`Active steps:` line apply to this session.

- **plan** — reserved vocabulary token. No behavior yet.

- **execute** — when a critic-hardened plan exists, hand it to execution:
  invoke `superpowers:subagent-driven-development` (recommended) to implement it
  task-by-task. Advisory — it does not relax any rail.

- **prcheck** — run `/pr-check` and loop: fix every finding, re-run, until CR is
  clean.

- **pr** — when CR is clean, open or refresh the PR.

- **ticket** — transition the Jira ticket to the appropriate status.

- **merge** — when CR is clean and the PR is open, squash-merge to main.
  Armed auto-merge (`ARMAUTOMERGE=1`, HIMMEL-1042) is
  `bash scripts/handover/merge-on-green.sh` (exactly, to match the standing
  allow-rule) — it gates on `check-ci.sh` green + a certified head SHA and
  merges only then, but it also hard-refuses (exit 12) any repo that is not
  confirmed PRIVATE, and `origin` has been public since the HIMMEL-2705
  cutover — so on this repo the armed path is **unavailable** until the
  HIMMEL-2869 policy decision. Use `scripts/handover/pr-merge.sh` instead
  (plain-first; defer to the operator on real branch protection; never
  `--admin`). Advisory — branch protection still applies. A blocked gate on
  this branch parks it and moves to the next queue item — never retry-loop;
  see
  [Park protocol](../../docs/handover/overnight-mode.md#park-protocol-himmel-2128).

- **public** — RETIRED at the HIMMEL-2705 cutover (2026-09-09): `origin` IS the
  public repo; a merge to `main` (the `merge` step above) is the public
  landing. Nothing to run.

- **handover** — write the handover.

## Scope and limits

- When the `merge` step is NOT on the pointer's `Active steps:` line, do NOT
  merge — merge stays an operator action. The pointer repeats this inline.
- This directive does NOT relax any safety rail. The CR-marker hook still
  HARD-blocks `gh pr create` until a clean `/pr-check`; attestation trailers
  must be in the FIRST commit; reactive `git commit --amend` and self-editing
  `.claude/settings.json` to widen rules are still HARD-vetoed. The pointer
  repeats this inline too.

## Turning it off / narrowing it

Unset the variable named in the pointer (`HIMMEL_INITIATIVE`, or
`HIMMEL_INITIATIVE_OVERNIGHT` under `HIMMEL_OVERNIGHT`) in the **launching**
shell and restart claude — env vars do not propagate into a running session.

**Unsetting is not always enough:** the hook also reads the himmel clone's
`.env` (non-clobbering — the process env only *wins*, it does not suppress). If
the leg came from there, unsetting the shell variable just falls back to the
`.env` value. Set it to `0` in the launching shell instead — that wins over
`.env` without touching it. Changing the `.env` entry itself is an **operator**
action: it is gitignored, secret-bearing, and outside what an agent edits.

For per-part control, set it to a comma-separated subset of: `execute`,
`prcheck`, `pr`, `ticket`, `merge`, `public`, `handover`
(e.g. `HIMMEL_INITIATIVE=prcheck,pr`).
