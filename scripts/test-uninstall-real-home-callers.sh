#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A && B || C is the check() idiom; the printf fixtures are literal shell text
# test-uninstall-real-home-callers.sh -- HIMMEL-3336: nothing under scripts/ may
# lift uninstall.sh's wet-run fence (HIMMEL_UNINSTALL_REAL_HOME=1) unless it is
# either pointed at a scratch HOME or is a named operator-path caller.
#
# WHY a static rule and not a runtime one: the fence-lifting call that deleted an
# operator's live hud config (scripts/test-e2e-symmetry.sh before #1015) and the
# himmelctl wizard's confirmed teardown look IDENTICAL to uninstall.sh at
# runtime -- both set the var and both may carry per-row overrides
# (HIMMELCTL_CACHE_DIR, BRIDGE_ROOT, ...) inherited from the operator's shell.
# The only difference is WHO is calling, so the rule is enforced where the
# caller is known: in the source. A runtime refusal on "REAL_HOME plus an
# override" would break the wizard operator with a non-default install.
#
# Usage: bash scripts/test-uninstall-real-home-callers.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"   # <repo>/scripts
repo_root="$(cd "$here/.." && pwd)"
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

# The var name is assembled so this file's own text never matches the scan.
V="HIMMEL_UNINSTALL_""REAL_HOME"

# Operator-path callers: they run uninstall against the machine the operator
# just confirmed offboarding, so a scratch HOME would defeat them. One reason
# each; a new entry is a deliberate act.
ALLOW_PATHS=(
  "scripts/himmelctl/bin.js"
  "scripts/uninstall.sh"
)
ALLOW_WHY=(
  "the wizard's confirmed wet teardown spawn: it must lift the fence for the operator's real HOME"
  "matches only remedy TEXT (the re-run hint printed for a refused wet run); it never sets the variable itself"
)

# scan_callers <root> [allowed-path...] -- print (root-relative) every file under
# <root>/scripts that sets the var to 1 without a scratch HOME and is not allowed.
# ponytail: a TEXT heuristic, not a data-flow check. "Sets the var" is the literal
# `VAR=1` / `VAR: '1'` / `VAR = '1'`; "scratch HOME" is any `HOME=` assignment plus
# the word `mktemp` somewhere in the same file. It will NOT catch a HOME reassigned
# through an indirect helper or sourced file, a fence lift spelled another way
# (e.g. a computed variable name), or a mktemp that feeds something other than the
# HOME it assigns. A new operator-path caller has to be added to ALLOW_PATHS on
# purpose; that friction is the point.
scan_callers() {
  local root="$1"; shift
  local set_re="${V}(=1|[[:space:]]*[:=][[:space:]]*['\"]1['\"])"
  local f rel a allowed
  while IFS= read -r f; do
    grep -Eq "$set_re" "$f" || continue
    rel="${f#"$root"/}"
    allowed=0
    for a in "$@"; do [ "$rel" = "$a" ] && allowed=1; done
    [ "$allowed" -eq 1 ] && continue
    if grep -q 'mktemp' "$f" && grep -Eq '(^|[^A-Za-z0-9_])HOME[[:space:]]*=' "$f"; then
      continue
    fi
    printf '%s\n' "$rel"
  done < <(find "$root/scripts" -path '*/node_modules' -prune -o -type f \
    \( -name '*.sh' -o -name '*.js' -o -name '*.mjs' -o -name '*.ts' -o -name '*.ps1' \) -print)
}

echo "== fixtures =="
td="$(mktemp -d "${TMPDIR:-/tmp}/real-home-callers.XXXXXX")" || { echo "test-uninstall-real-home-callers: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$td"' EXIT
fx="$td/tree"; mkdir -p "$fx/scripts"

# pre-#1015 shape: fence lifted, HOME never reassigned.
printf '#!/usr/bin/env bash\n%s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-pre1015.sh"
# a HOME-shaped variable is not HOME.
printf '#!/usr/bin/env bash\ntd=$(mktemp -d)\nFAKE_HOME="$td"\n%s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-fake-home.sh"
# HOME reassigned, but not to a scratch dir.
printf '#!/usr/bin/env bash\nHOME="$HOME"\n%s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-not-scratch.sh"
# scratch HOME in the same file.
printf '#!/usr/bin/env bash\ntd=$(mktemp -d)\nHOME="$td/home" %s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-scratch.sh"
# a JS operator-path caller, on the allowlist below.
printf "runSpawn(cmd, { env: { ...process.env, %s: '1' } });\n" "$V" > "$fx/scripts/wizard.js"
# only unsets / reads it.
printf '#!/usr/bin/env bash\nunset %s\necho "${%s:-unset}"\n' "$V" "$V" > "$fx/scripts/test-unset-only.sh"

got="$(scan_callers "$fx" "scripts/wizard.js" | sort | tr '\n' ' ')"
check "pre-#1015 shape (fence lifted, HOME not reassigned) is flagged" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-pre1015.sh')" "1"
check "a FAKE_HOME-style variable does not count as a scratch HOME" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-fake-home.sh')" "1"
check "HOME reassigned to a non-mktemp value is flagged" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-not-scratch.sh')" "1"
check "scratch-HOME file passes" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-scratch.sh')" "0"
check "allowlisted file passes" \
  "$(printf '%s' "$got" | grep -c 'scripts/wizard.js')" "0"
check "file that only unsets/reads the var passes" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-unset-only.sh')" "0"
got_noallow="$(scan_callers "$fx" | tr '\n' ' ')"
check "the same JS file is flagged when NOT allowlisted" \
  "$(printf '%s' "$got_noallow" | grep -c 'scripts/wizard.js')" "1"

echo "== the real tree =="
check "no un-allowlisted fence-lifting caller under scripts/" \
  "$(scan_callers "$repo_root" "${ALLOW_PATHS[@]}" | tr '\n' ' ')" ""
# Control: without the allowlist the scan finds exactly the allowlisted files, so
# the real-tree scan above is not vacuous and every other caller passes on its
# own scratch HOME.
check "without the allowlist the scan flags exactly the allowlisted files" \
  "$(scan_callers "$repo_root" | sort | tr '\n' ' ')" "$(printf '%s\n' "${ALLOW_PATHS[@]}" | sort | tr '\n' ' ')"
i=0
for p in "${ALLOW_PATHS[@]}"; do
  [ -f "$repo_root/$p" ] && present=yes || present=no
  check "allowlist entry exists: $p" "$present" "yes"
  check "allowlist entry carries a reason: $p" "$([ -n "${ALLOW_WHY[$i]:-}" ] && echo yes || echo no)" "yes"
  i=$((i+1))
done

[ "$fails" -eq 0 ] && echo "REAL-HOME-CALLERS ALL PASS" || { echo "$fails FAILED"; exit 1; }
