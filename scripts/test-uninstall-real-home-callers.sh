#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A && B || C is the check() idiom; the printf fixtures are literal shell text
# test-uninstall-real-home-callers.sh -- HIMMEL-3336: nothing under scripts/ may
# lift uninstall.sh's wet-run fence (the REAL_HOME opt-in variable, set to 1;
# spelled out in full only in $V below, so this text never matches the scan)
# unless it is either pointed at a scratch HOME or is a named operator-path caller.
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

# home_is_scratch <file> -- succeed when the file assigns HOME from a mktemp-derived
# value: a literal `mktemp`, or a variable that (transitively, through other
# simple `NAME=value` assignments) was itself assigned from `mktemp`.
# ponytail: flow-INSENSITIVE text tracing over simple `NAME=<word|"..."|'...'|$(...)>`
# tokens. It will NOT follow a HOME set through a helper function, a sourced file,
# `read` / `printf -v` / `declare -n`, or an env block passed as a variable; it
# ignores order, so a scratch variable reassigned to something real AFTER the trace
# still passes; and a mktemp buried past the first inner quote of a quoted `$(...)`
# is missed (a false flag, never a false pass).
home_is_scratch() {
  local file="$1" line rest name rhs v changed is_scratch ref_re home_ok=0
  local dq='"[^"]*"' sq="'[^']*'" cs='\$\([^)]*\)' bare='[^[:space:]]*'
  local assign_re="(^|[^A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)=($dq|$sq|$cs|$bare)"
  local scratch=" " lines=()
  while IFS= read -r line || [ -n "$line" ]; do lines+=("$line"); done < "$file"
  for _ in 1 2 3 4 5 6 7 8; do   # fixpoint: one pass per link of an assignment chain
    changed=0
    for line in "${lines[@]}"; do
      rest="$line"
      while [[ "$rest" =~ $assign_re ]]; do
        name="${BASH_REMATCH[2]}"; rhs="${BASH_REMATCH[3]}"
        rest="${rest#*"${BASH_REMATCH[0]}"}"
        is_scratch=0
        case "$rhs" in *mktemp*) is_scratch=1 ;; esac
        if [ "$is_scratch" -eq 0 ]; then
          for v in $scratch; do
            ref_re='\$\{?'"$v"'([^A-Za-z0-9_]|$)'
            if [[ "$rhs" =~ $ref_re ]]; then is_scratch=1; break; fi
          done
        fi
        [ "$is_scratch" -eq 1 ] || continue
        if [ "$name" = HOME ]; then home_ok=1; continue; fi
        case "$scratch" in *" $name "*) ;; *) scratch="$scratch$name "; changed=1 ;; esac
      done
    done
    [ "$changed" -eq 0 ] && break
  done
  [ "$home_ok" -eq 1 ]
}

# scan_callers <root> [allowed-path...] -- print (root-relative) every file under
# <root>/scripts that sets the var to 1 without a scratch HOME and is not allowed.
# ponytail: a TEXT heuristic, not a data-flow check. "Sets the var" is `VAR=1`,
# `VAR: 1`, `'VAR': '1'`, `VAR = "1"`, `$env:VAR = 1` -- the name, an optional
# closing quote/bracket, `=` or `:`, an optional opening quote, and exactly `1`
# (no `10` / `1x`). It will NOT catch a fence lift spelled another way (a computed
# variable name, `Set-Item Env:`, `[Environment]::SetEnvironmentVariable`, a
# `process.env` object built from a variable name) or the value carried in a
# variable (`v=1; ... $v`). "Scratch HOME" is home_is_scratch above, with its own
# limits. A new operator-path caller has to be added to ALLOW_PATHS on purpose;
# that friction is the point.
scan_callers() {
  local root="$1"; shift
  local set_re="${V}[]'\"}]*[[:space:]]*[:=][[:space:]]*['\"]?1([^A-Za-z0-9_]|\$)"
  local f rel a allowed rc list
  # A failed traversal (unreadable subtree) is reported, not scanned around.
  list="$(find "$root/scripts" -path '*/node_modules' -prune -o -type f \
    \( -name '*.sh' -o -name '*.js' -o -name '*.mjs' -o -name '*.ts' -o -name '*.ps1' \) -print)" \
    || { printf 'scripts (find failed under %s)\n' "$root"; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -Eq "$set_re" "$f"; rc=$?
    [ "$rc" -eq 1 ] && continue
    rel="${f#"$root"/}"
    # rc>1 is a read error: report the file rather than let it pass as a non-match.
    if [ "$rc" -ne 0 ]; then printf '%s (unreadable: grep rc=%s)\n' "$rel" "$rc"; continue; fi
    allowed=0
    for a in "$@"; do [ "$rel" = "$a" ] && allowed=1; done
    [ "$allowed" -eq 1 ] && continue
    home_is_scratch "$f" && continue
    printf '%s\n' "$rel"
  done <<< "$list"
}

echo "== fixtures =="
td="$(mktemp -d "${TMPDIR:-/tmp}/real-home-callers.XXXXXX")" || { echo "test-uninstall-real-home-callers: mktemp failed" >&2; exit 2; }
trap 'chmod -R u+rwx "$td" 2>/dev/null; rm -rf "$td"' EXIT
fx="$td/tree"; mkdir -p "$fx/scripts"

# pre-#1015 shape: fence lifted, HOME never reassigned.
printf '#!/usr/bin/env bash\n%s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-pre1015.sh"
# a HOME-shaped variable is not HOME.
printf '#!/usr/bin/env bash\ntd=$(mktemp -d /tmp/x.XXXXXX)\nFAKE_HOME="$td"\n%s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-fake-home.sh"
# HOME reassigned, but not to a scratch dir.
printf '#!/usr/bin/env bash\nHOME="$HOME"\n%s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-not-scratch.sh"
# scratch HOME in the same file.
printf '#!/usr/bin/env bash\ntd=$(mktemp -d /tmp/x.XXXXXX)\nHOME="$td/home" %s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-scratch.sh"
# HIMMEL-3344: an unrelated mktemp does not make HOME a scratch dir.
printf '#!/usr/bin/env bash\ntmp="$(mktemp -d /tmp/x.XXXXXX)"\nHOME="$HOME"\n%s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-unrelated-mktemp.sh"
# HIMMEL-3344: HOME assigned from a variable that is NOT mktemp-derived.
printf '#!/usr/bin/env bash\ntmp="$(mktemp -d /tmp/x.XXXXXX)"\nother=/somewhere/real\nHOME="$other"\n%s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-home-from-other.sh"
# HIMMEL-3344: HOME derived from a mktemp variable through a second variable
# (the shape of test-e2e-symmetry-isolation.sh) passes.
printf '#!/usr/bin/env bash\ntd="$(mktemp -d /tmp/x.XXXXXX)"\nctl="$td/ctlhome"\nHOME="$ctl" %s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-scratch-transitive.sh"
# HIMMEL-3344: a literal mktemp on the HOME assignment passes.
printf '#!/usr/bin/env bash\nHOME="$(mktemp -d /tmp/x.XXXXXX)" %s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-scratch-literal.sh"
# HIMMEL-3344: fence lifted through a quoted JS key + numeric value, an unquoted
# key + numeric value, and a PowerShell $env: assignment -- all uncovered pre-fix.
printf "runSpawn(cmd, { env: { '%s': 1 } });\n" "$V" > "$fx/scripts/quoted-key.js"
printf 'runSpawn(cmd, { env: { %s: 1 } });\n' "$V" > "$fx/scripts/numeric-value.mjs"
printf '$env:%s = 1\n& uninstall.ps1 -Yes\n' "$V" > "$fx/scripts/ps-env.ps1"
# HIMMEL-3343: uninstall.sh lifts the fence only for exactly 1, so =10 / =1x are not lifts.
printf '#!/usr/bin/env bash\n%s=10 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-value-10.sh"
printf '#!/usr/bin/env bash\n%s=1x bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-value-1x.sh"
# a JS operator-path caller, on the allowlist below.
printf "runSpawn(cmd, { env: { ...process.env, %s: '1' } });\n" "$V" > "$fx/scripts/wizard.js"
# only unsets / reads it.
printf '#!/usr/bin/env bash\nunset %s\necho "${%s:-unset}"\n' "$V" "$V" > "$fx/scripts/test-unset-only.sh"
# a caller the scan cannot read (root reads through the mode, so it is skipped there).
printf '#!/usr/bin/env bash\n%s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-unreadable.sh"
chmod 000 "$fx/scripts/test-unreadable.sh"

got="$(scan_callers "$fx" "scripts/wizard.js" | sort | tr '\n' ' ')"
check "pre-#1015 shape (fence lifted, HOME not reassigned) is flagged" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-pre1015.sh')" "1"
check "a FAKE_HOME-style variable does not count as a scratch HOME" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-fake-home.sh')" "1"
check "HOME reassigned to a non-mktemp value is flagged" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-not-scratch.sh')" "1"
check "scratch-HOME file passes" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-scratch.sh')" "0"
check "an unrelated mktemp plus HOME=\"\$HOME\" is flagged" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-unrelated-mktemp.sh')" "1"
check "HOME assigned from a non-mktemp variable is flagged" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-home-from-other.sh')" "1"
check "HOME derived from mktemp through a second variable passes" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-scratch-transitive.sh')" "0"
check "a literal mktemp on the HOME assignment passes" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-scratch-literal.sh')" "0"
check "quoted JS key with a numeric value is flagged" \
  "$(printf '%s' "$got" | grep -c 'scripts/quoted-key.js')" "1"
check "unquoted JS key with a numeric value is flagged" \
  "$(printf '%s' "$got" | grep -c 'scripts/numeric-value.mjs')" "1"
check "PowerShell \$env: assignment is flagged" \
  "$(printf '%s' "$got" | grep -c 'scripts/ps-env.ps1')" "1"
check "=10 is not a fence lift (not flagged)" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-value-10.sh')" "0"
check "=1x is not a fence lift (not flagged)" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-value-1x.sh')" "0"
check "allowlisted file passes" \
  "$(printf '%s' "$got" | grep -c 'scripts/wizard.js')" "0"
check "file that only unsets/reads the var passes" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-unset-only.sh')" "0"
if [ "$(id -u)" -ne 0 ]; then
  check "an unreadable file is flagged, not passed as a non-match" \
    "$(printf '%s' "$got" | grep -c 'scripts/test-unreadable.sh (unreadable')" "1"
  # a separate tree: a failed traversal returns early, so it would mask the checks above.
  mkdir -p "$td/locked/scripts/sub"; chmod 000 "$td/locked/scripts/sub"
  check "an unreadable subtree is flagged, not scanned around" \
    "$(scan_callers "$td/locked" 2>/dev/null | grep -c 'find failed')" "1"
else
  echo "ok - unreadable-file control skipped (running as root)"
fi
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
