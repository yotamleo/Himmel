#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-legs.sh — transport wrapper for the shared leg resolver (HIMMEL-444).
# legs.sh holds ZERO leg logic; it locates the himmel checkout and re-execs
# scripts/lib/initiative-legs.sh so the leg `case` lives in exactly one place.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../../.." && pwd)"   # himmel checkout root (4 up from .../himmel-ops/scripts)
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

# execute leg active → surfaces in the wrapper output (via HIMMEL_REPO anchor).
out="$(HIMMEL_REPO="$repo" HIMMEL_INITIATIVE='prcheck,execute' bash "$here/legs.sh")"
case " $out " in *" execute "*) echo "ok - execute surfaced";; *) echo "FAIL: execute missing [$out]"; fails=$((fails+1));; esac

# execute leg absent → not in output.
out="$(HIMMEL_REPO="$repo" HIMMEL_INITIATIVE='prcheck' bash "$here/legs.sh")"
case " $out " in *" execute "*) echo "FAIL: execute leaked [$out]"; fails=$((fails+1));; *) echo "ok - execute absent";; esac

# no anchor + cwd inside the himmel checkout → resolves via git toplevel of cwd.
out="$(cd "$repo" && env -u HIMMEL_REPO HIMMEL_INITIATIVE='execute' bash "$here/legs.sh")"
case " $out " in *" execute "*) echo "ok - resolves via cwd git-toplevel";; *) echo "FAIL: cwd resolution [$out]"; fails=$((fails+1));; esac

# fail-open: wrapper copied OUTSIDE any himmel checkout + no anchor → empty, exit 0.
td="$(mktemp -d)"; cp "$here/legs.sh" "$td/legs.sh"
out="$(cd "$td" && env -u HIMMEL_REPO HIMMEL_INITIATIVE='execute' bash "$td/legs.sh")"; rc=$?
{ [ -z "$out" ] && [ "$rc" = 0 ]; } && echo "ok - fail-open with no reachable resolver" || { echo "FAIL: not fail-open [$out] rc=$rc"; fails=$((fails+1)); }
rm -rf "$td"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
