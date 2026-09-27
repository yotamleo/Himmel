---
description: Start or arm a console (new) or hand it over (next) from any repo — writes the doc, takes the queue lock.
argument-hint: new|next [--bucket <slug>] [--name <slug>] [--arm] [--dry-run] [--doc <path>] [--model <m>] [--project <dir>]
---

Starts or hands over a console (defined in `docs/glossary.md` in the himmel
checkout). Background + the operating contract: `docs/handover/running-a-console.md`.

This command runs from **any directory**: first resolve the himmel checkout —
`$HIMMEL_REPO` → canonical install paths → error, never the cwd's own git
toplevel (a foreign repo shipping its own `console.sh` must never win over
himmel's) — then point `console.sh` at the PROJECT this session is actually
running in via `--project`. That is the whole point of this plugin copy over
the project-local `.claude/commands/console.md`: a console started from e.g.
`~/Websites` or a Websites repo gets THAT project's own bucket/prefix derived
from the handover registry (or its basename, unregistered) — never himmel's
own `JIRA_PROJECT_KEY`. The console session itself always runs in the himmel
checkout: `--project` is recorded as data in the console doc, and a leg for
the project is dispatched into it explicitly with `LEG_REPO=<path>`.

```bash
# Resolve the himmel checkout: $HIMMEL_REPO -> canonical paths -> error. Never
# the cwd's own git toplevel: a foreign repo shipping its own
# scripts/handover/console/console.sh would otherwise get ITS script executed
# in preference to himmel's (HIMMEL-3623 verdict J1268O change 5, F6).
REPO="${HIMMEL_REPO:-}"
if [ -z "$REPO" ] || [ ! -f "$REPO/scripts/handover/console/console.sh" ]; then
  for c in "$HOME/Documents/github/himmel" "$HOME/Documents/github/Himmel" "$HOME/github/himmel" "$HOME/github/Himmel" "$HOME/Himmel" "$HOME/himmel"; do
    [ -f "$c/scripts/handover/console/console.sh" ] && { REPO="$c"; break; }
  done
fi
[ -n "$REPO" ] && [ -f "$REPO/scripts/handover/console/console.sh" ] || { echo "ERR: cannot locate himmel checkout — set HIMMEL_REPO to your himmel clone" >&2; exit 1; }

# The console is FOR the project this session runs in: git toplevel, mapped
# from a linked worktree to its MAIN worktree (git worktree list's first
# entry) so a worktree checkout still resolves to the repo's own registry
# entry. --git-common-dir's dirname is wrong for submodules (yields
# super/.git/modules/<name>) and --separate-git-dir checkouts (yields the
# parent of the git dir) -- change 6, F7.
PROJECT="$PWD"
if TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  PROJECT="$TOPLEVEL"
  MAIN_WT="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -n1)"
  [ -n "$MAIN_WT" ] && PROJECT="$MAIN_WT"
fi

# A bare /himmel-ops:console (no subcommand) must print usage, not
# "unknown command: --project" (change 9, F11).
#
# --project is only ever DERIVED for `new`. A running console always lives
# in $REPO by design (see above), so deriving it the same way for `next`
# would force --project=$REPO on every handover of a foreign-project chain
# -- console.sh's `next` already inherits the predecessor doc's own
# recorded project when none is passed, and an operator's own explicit
# --project in $ARGUMENTS is passed through untouched either way (codex-1,
# pr-check round 1, HIMMEL-3623).
#
# Two more fixes here (codex-1, codex-2, pr-check round 2, HIMMEL-3623):
# the derived --project is appended only when $ARGUMENTS carries none of its
# own, so an operator's explicit `/console new --project <dir>` still wins
# (console.sh keeps the LAST --project, so appending ours unconditionally
# always clobbered theirs); and console.sh is invoked by absolute path with
# no `cd "$REPO"` first, since it resolves its own script dir from
# `${BASH_SOURCE[0]}` and never needs cwd == $REPO, and a `cd` before
# expanding $ARGUMENTS resolved any relative --doc/--project the operator
# passed against the himmel checkout instead of their own cwd.
case "$ARGUMENTS" in
  new|"new "*)
    case "$ARGUMENTS" in
      *--project*) bash "$REPO/scripts/handover/console/console.sh" $ARGUMENTS ;;
      *) bash "$REPO/scripts/handover/console/console.sh" $ARGUMENTS --project "$PROJECT" ;;
    esac
    ;;
  "")
    bash "$REPO/scripts/handover/console/console.sh"
    ;;
  *)
    bash "$REPO/scripts/handover/console/console.sh" $ARGUMENTS
    ;;
esac
```

- `/console new` — write `<handover-root>/<user>/<bucket>/<PREFIX>-nextleg-<date>A-console.md`
  from `docs/handover/console-template.md`, acquire the queue lock on it, and
  print the launch line. A second `new` the same day bumps the letter; it never
  overwrites.
- `/console next` — from a running console, write the successor stub (letter
  bumped, pointed at this console and its HANDOFF) plus this console's
  `-HANDOFF.md` skeleton. Run it at 45 % context fill or after 90 k input
  tokens in one turn.
- `--arm` — also arm the session headed via `scripts/handover/headed-arm.sh`,
  on a signal file plus a deadline; prints the arm log path. Launches with
  `--autocompact 200000` by default (HIMMEL-2973); set `CONSOLE_CONTEXT=1m`
  in the launching shell to opt into `--autocompact auto` instead.
- `--dry-run` — print what it would write, prefixed `would-`, and touch nothing.
- `--bucket <slug>` / `--prefix <P>` — override the project-derived defaults
  (e.g. `/console new --arm --bucket websites`); the resolved `--project`
  above only supplies the DEFAULT bucket/prefix, it never forces one.
- `--project <dir>` — this plugin copy derives one from the cwd this session
  is running in, but ONLY for `new`, and only when your own arguments carry
  no `--project` of their own — an explicit `/console new --project <dir>`
  always wins over the derived one (codex-1, pr-check round 2, HIMMEL-3623).
  `next` derives nothing here: with no `--project` of your own, console.sh
  inherits the predecessor doc's own recorded project instead (codex-1,
  pr-check round 1, HIMMEL-3623); an explicit `--project`/`--bucket`/`--prefix`
  on `next` still wins. To target a different repo on `new` without passing
  `--project`, start the session there, or override just the naming with
  `--bucket`/`--prefix`.

Record the printed `release-token: ` line — now backticked around the token
itself (HIMMEL-2910) — in the console's first Results bullet verbatim:
releasing the lock at wrap requires it.

Linux/macOS only — `--arm` launches through konsole. The Windows station arms
through `scripts/handover/arm-resume.sh`'s schtasks backend instead.
