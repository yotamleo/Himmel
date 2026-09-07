#!/usr/bin/env bash
# USER_SLUG resolve-or-advise (HIMMEL-145; disposition HIMMEL-2537).
#
# Usage: bash scripts/setup/check-user-slug.sh [--dotenv-root <dir>]
#
#   resolved    stdout = the bare slug, stderr = its source line, rc=0
#   unresolved  stderr = a WARN diagnostic + the consequence + the remedy, rc=3
#   usage error stderr = the usage line, rc=2
#   probe broke stderr = which sourced lib failed to load, rc=4 (see below)
#
# --dotenv-root <dir> resolves the way a CONSUMER does rather than the way a
# bare shell does (CR round 1 [codex-1]): before falling through to the forge
# and git-identity sources, bridge <dir>/.env's USER_SLUG the same way
# scripts/lib/load-dotenv.sh bridges it for scripts/handover/* and the hooks.
# Without it, setup.sh's own footer told an operator who had JUST typed a slug
# at step [5/9]'s --fill-env prompt to go and set one — the value lands in
# .env, which the bare resolver does not read.
#
# A value equal to .env.example's is NOT a value: a fresh .env is copied from
# the example verbatim, placeholder and all, so accepting it would report
# `your-slug` as a resolved slug — a wrong answer stated confidently, which is
# worse than the honest "not resolved" this script exists to give.
#
# Extracted from setup.sh step 0.5 so the disposition is hermetic-testable
# (test-check-user-slug.sh), the same reason step 0.4's check-jira-key.sh is
# its own file.
#
# PLATFORM GUARD (WS5 T15) — no .ps1 twin, deliberately. This is a step of
# scripts/setup.sh, and the Windows installer twin scripts/setup.ps1 has NO
# USER_SLUG step at all, so there is nothing on that side to mirror; a twin
# here would be a file no code path reaches. That asymmetry is not incidental
# — it is evidence line 6 in the HIMMEL-2537 rationale below. On Windows this
# runs under Git Bash like the rest of scripts/setup.sh's chain; it uses only
# POSIX shell plus git, and both `--dotenv-root` sources (load-dotenv.sh,
# user-slug.sh) are themselves bash-only libs with no PowerShell counterpart.
# If setup.ps1 ever grows a USER_SLUG step, the twin belongs with THAT change.
#
# WHY rc=3 and not rc=1 (HIMMEL-2537). Step 0.5 used to `exit 1` here, which
# aborted a contributor install on a stock guest with no USER_SLUG, no
# authenticated forge CLI and no git identity — measured on the HIMMEL-2457
# Linux acceptance matrix, cell C4b. That abort was not buying anything:
#
#   1. No later setup.sh step reads USER_SLUG, and no sub-script setup.sh
#      invokes reads it either (checked across scripts/setup/*, handover-link,
#      the wire-* helpers and install-plugins).
#   2. Nothing setup.sh WRITES embeds the slug: .env is copied verbatim from
#      .env.example (which carries the USER_SLUG= placeholder for the operator
#      to fill), and the settings.json wiring is statusline/HIMMEL_REPO/hooks.
#   3. `export USER_SLUG` dies with the setup.sh process, so it cannot reach a
#      consumer even in principle.
#   4. Every real consumer — scripts/handover/{hop,schedule-resume,leg-timeline},
#      hooks/block-edit-on-main.sh, lib/load-dotenv.sh, upstreams/upstream-watch,
#      luna/file-clipper-tickets — calls this same resolver itself at use time,
#      so an unset slug degrades cleanly and self-heals the moment any of the
#      three sources is set.
#   5. The abort landed BEFORE step [5/9], which is what creates .env and, under
#      --fill-env, prompts for USER_SLUG — it pre-empted its own remedy.
#   6. scripts/setup.ps1, the Windows twin, has no USER_SLUG step at all, so the
#      hard failure was an unmatched asymmetry rather than a shared invariant.
#
# So the honest shape is the HIMMEL-2536 one: continue, and make the summary
# say plainly that a step was left undone. rc=3 (not 0) is what lets setup.sh
# distinguish "resolved" from "advised" and carry it into that summary; a bare
# rc=0 would hand the caller the same silence 2536 exists to end.
set -uo pipefail

_dotenv_root=""
case "${1:-}" in
  --dotenv-root) _dotenv_root="${2:-}" ;;
  "") ;;
  *) echo "usage: check-user-slug.sh [--dotenv-root <dir>]" >&2; exit 2 ;;
esac
if [ "${1:-}" = "--dotenv-root" ] && [ -z "$_dotenv_root" ]; then
  echo "usage: check-user-slug.sh [--dotenv-root <dir>]" >&2; exit 2
fi
# A bare call takes 0 args and --dotenv-root <dir> takes exactly 2 (CR round 2
# [codex-2]); anything left over past those is a malformed invocation that the
# case above let through silently rather than rejecting.
if [ "$#" -gt 2 ] || { [ -z "${1:-}" ] && [ "$#" -gt 0 ]; }; then
  echo "usage: check-user-slug.sh [--dotenv-root <dir>]" >&2; exit 2
fi

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# rc=4 for a sourced lib that did not load (CR round 7 [codex-1]): this script
# runs under `set -uo pipefail`, deliberately NOT `-e`, so an unchecked
# `. "$lib"` that fails (missing file, unreadable, a syntax error in the lib)
# would silently fall through with user_slug_verify left undefined; the `if`
# around it then just fails and execution reaches the advisory path below,
# reporting a BROKEN PROBE as a confidently "confirmed unresolved" slug — the
# exact false confidence this whole ticket exists to remove. rc=4 is neither
# 0 (resolved), 2 (usage error) nor 3 (genuinely advised): setup.sh already
# treats any rc outside {0,3} as an unverified probe (its own
# "expected 0 or 3" WARNING), and himmelctl's userSlugState()/buildSummary
# render a distinct "could NOT be verified" row for exactly that case.
_user_slug_lib="$_here/../lib/user-slug.sh"
# shellcheck source=../lib/user-slug.sh
# shellcheck disable=SC1091
if ! . "$_user_slug_lib" || ! declare -F user_slug_verify >/dev/null 2>&1; then
  echo "user-slug: could not load the resolver at $_user_slug_lib — the probe itself did not run (this is NOT a resolved-or-advised outcome)" >&2
  exit 4
fi

# The .env bridge (see the header). Only ever FILLS an unset/empty USER_SLUG —
# a value already in the environment is the operator's explicit intent and
# outranks a file, which is load_dotenv's own non-clobbering rule.
if [ -n "$_dotenv_root" ] && [ -z "${USER_SLUG:-}" ]; then
  _load_dotenv_lib="$_here/../lib/load-dotenv.sh"
  # shellcheck source=../lib/load-dotenv.sh
  # shellcheck disable=SC1091
  if ! . "$_load_dotenv_lib" || ! declare -F load_dotenv >/dev/null 2>&1; then
    echo "user-slug: could not load $_load_dotenv_lib — the --dotenv-root probe itself did not run (this is NOT a resolved-or-advised outcome)" >&2
    exit 4
  fi
  # rc=4 for the CALL failing, not just the sourcing (CR round 8 [codex-1]):
  # round 7 guarded the two `.` source lines but left this call's own status
  # unchecked, and this script runs `set -uo pipefail`, deliberately NOT `-e`,
  # so a failing load_dotenv would fall through with USER_SLUG left empty —
  # the resolver then legitimately finds nothing and exits 3, reporting a
  # BROKEN PROBE as a confidently "confirmed unresolved" slug, same defect
  # class as round 7. Checked (scripts/lib/load-dotenv.sh, HIMMEL-2537 round
  # 8): load_dotenv returns 0 for every benign case, including no .env file at
  # the given root at all (it `return 0`s explicitly there, and its only other
  # exit path is a `while read` loop whose bash-defined exit status is 0 both
  # when the key isn't in the file and when it is) — so a plain status check
  # cannot false-positive on "no .env" and needs no extra filtering.
  if ! load_dotenv --root "$_dotenv_root" USER_SLUG; then
    echo "user-slug: load_dotenv failed for --root $_dotenv_root — the --dotenv-root probe itself did not run (this is NOT a resolved-or-advised outcome)" >&2
    exit 4
  fi
  # Placeholder rejection: compare against .env.example's own value for the
  # key rather than hardcoding it here, so the example file stays the single
  # source of truth (the same posture fill-env.sh takes).
  if [ -n "${USER_SLUG:-}" ] && [ -f "$_dotenv_root/.env.example" ]; then
    _example_slug=$(sed -n 's/^USER_SLUG=//p' "$_dotenv_root/.env.example" | head -1)
    if [ -n "$_example_slug" ] && [ "$USER_SLUG" = "$_example_slug" ]; then
      echo "user-slug: ignoring .env's USER_SLUG — it is still .env.example's placeholder ('$_example_slug'), not a slug you chose" >&2
      USER_SLUG=""
    fi
  fi
fi

if _slug=$(user_slug_verify WARN); then
  printf '%s' "$_slug"
  exit 0
fi

cat >&2 <<'SLUG_ADVISORY'

  Setup CONTINUES — no step below this one uses USER_SLUG.
  Consequence: until you set one of the three sources above, the tooling that
  DOES use it cannot derive your paths — handover buckets
  (<state-root>/<USER_SLUG>/...), registry.json's user field, and scratch dir
  names. Each resolves the slug when it runs, so setting any source later fixes
  them all with no re-run of setup.
SLUG_ADVISORY
exit 3
