#!/usr/bin/env bash
# test-adopt-portable-libs.sh -- every library a portable hook sources is itself
# in adopt.sh's PORTABLE_FILES (HIMMEL-4994).
#
# A project-scope install copies PORTABLE_FILES into the target and nothing
# else. A hook that sources a lib outside that list fails closed in the
# installed tree (block-read-secrets: "cannot load .../lib/guard-unwrap.sh").
# The AUR container test (packaging/aur/test-pkgbuild.sh) only sees this inside
# a container; this check reads the hooks and the list, so it runs anywhere.
#
# Libs are found as `../lib/X.sh` / `../guardrails/X.sh` (relative to the hook)
# and `lib/X.sh` under the hook's own dir (the `${BASH_SOURCE[0]%/*}/lib/X.sh`
# shape), in non-comment lines. OPTIONAL libs are sourced inside an `if`/`||`
# that tolerates absence, so they need not ship.
#
# Env: ADOPT_SH overrides the adopt.sh read (the RED control points it at a copy
# with the lib removed).
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
adopt="${ADOPT_SH:-$repo_root/scripts/adopt.sh}"
OPTIONAL='scripts/lib/load-dotenv.sh'

fail=0
portable=$(awk '/^PORTABLE_FILES=\(/{f=1;next} f&&/^\)/{exit} f{print $1}' "$adopt")
[ -n "$portable" ] || { echo "FAIL: no PORTABLE_FILES parsed from $adopt" >&2; exit 1; }

checked=0
while IFS= read -r hook; do
  case "$hook" in scripts/hooks/*.sh) ;; *) continue ;; esac
  src="$repo_root/$hook"
  [ -f "$src" ] || { echo "FAIL: $hook is listed but missing" >&2; fail=1; continue; }
  code=$(grep -vE '^[[:space:]]*#' "$src")
  libs=$({ printf '%s\n' "$code" | grep -oE '\.\./(lib|guardrails)/[A-Za-z0-9_.-]+\.sh' | sed 's|^\.\./|scripts/|' || true
           printf '%s\n' "$code" | grep -oE '[%*}]/lib/[A-Za-z0-9_.-]+\.sh' | sed 's|^.*/lib/|scripts/hooks/lib/|' || true
         } | sort -u)
  for lib in $libs; do
    checked=$((checked + 1))
    case " $OPTIONAL " in *" $lib "*) continue ;; esac
    printf '%s\n' "$portable" | grep -qxF "$lib" \
      || { echo "FAIL: $hook sources $lib, which PORTABLE_FILES does not copy" >&2; fail=1; }
  done
done <<< "$portable"

[ "$checked" -gt 0 ] || { echo "FAIL: vacuous, no sourced lib found in any portable hook" >&2; exit 1; }
[ "$fail" -eq 0 ] || exit 1
echo "ok: all $checked sourced libs of the portable hooks are in PORTABLE_FILES"
