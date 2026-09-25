---
description: Start or arm a console (new) or hand it over (next) from any repo — writes the doc, takes the queue lock.
argument-hint: new|next [--bucket <slug>] [--name <slug>] [--arm] [--dry-run] [--doc <path>] [--model <m>] [--project <dir>]
---

Starts or hands over a console (defined in `docs/glossary.md` in the himmel
checkout). Background + the operating contract: `docs/handover/running-a-console.md`.

This command runs from **any directory** (mirrors `himmel-update.md`,
HIMMEL-459): first resolve the himmel checkout using the same
checkout-resolution order — `$HIMMEL_REPO` → the current git toplevel →
canonical install paths → error — then point `console.sh` at the PROJECT this
session is actually running in via `--project`. That is the whole point of
this plugin copy over the project-local `.claude/commands/console.md`: a
console started from e.g. `~/Websites` or a Websites repo gets THAT project's
own bucket/prefix derived from it — never himmel's own `JIRA_PROJECT_KEY` —
and, when armed, opens the session in the project's own checkout, not in
himmel's.

```bash
# Resolve the himmel checkout: $HIMMEL_REPO -> git toplevel -> canonical -> error.
REPO="${HIMMEL_REPO:-}"
[ -n "$REPO" ] && [ -f "$REPO/scripts/handover/console/console.sh" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO" ] || [ ! -f "$REPO/scripts/handover/console/console.sh" ]; then
  for c in "$HOME/Documents/github/himmel" "$HOME/Documents/github/Himmel" "$HOME/github/himmel" "$HOME/github/Himmel" "$HOME/Himmel" "$HOME/himmel"; do
    [ -f "$c/scripts/handover/console/console.sh" ] && { REPO="$c"; break; }
  done
fi
[ -f "$REPO/scripts/handover/console/console.sh" ] || { echo "ERR: cannot locate himmel checkout — set HIMMEL_REPO to your himmel clone" >&2; exit 1; }

# The console opens in the directory this session runs in (its repo's primary checkout when inside git).
PROJECT="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && PROJECT="$(dirname "$PROJECT")" || PROJECT="$PWD"
cd "$REPO" && bash scripts/handover/console/console.sh $ARGUMENTS --project "$PROJECT"
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
- `--project <dir>` — this plugin copy always passes one, derived from the
  cwd this session is running in, AFTER your arguments — so it wins over a
  `--project` you pass yourself (console.sh keeps the last one). To target a
  different repo, start the session there, or override just the naming with
  `--bucket`/`--prefix`.

Record the printed `release-token: ` line — now backticked around the token
itself (HIMMEL-2910) — in the console's first Results bullet verbatim:
releasing the lock at wrap requires it.

Linux/macOS only — `--arm` launches through konsole. The Windows station arms
through `scripts/handover/arm-resume.sh`'s schtasks backend instead.
