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
# is missed (a false flag, never a false pass). It wants `mktemp` as a bare command
# word, so /usr/bin/mktemp is a false flag; but it does not prove the word is
# INVOKED, so `HOME="$(echo mktemp)"` still passes. A scratch variable counts only as a
# plain `$v` / `${v}`, and a value carrying ANY `${x<op>...}` expansion is never
# scratch (a false flag, never a false pass). It reads raw lines and cannot tell an
# executable assignment from assignment-shaped TEXT: `HOME="$(mktemp -d)"` inside a
# comment or a single-quoted `printf` argument (a fixture the file writes) counts as
# one, so such a file can PASS while lifting the fence with the real HOME
# (HIMMEL-3345; separating code from quoted text needs a parser).
# The quoted dirname-of-scratch (`HOME="$(dirname "$td")"`, td a mktemp) is a false flag
# ON PURPOSE (HIMMEL-3345): teaching this text matcher to trace it was tried and reverted,
# because every rule that widened what counts as scratch opened a real false pass (six
# review rounds, the last two Critical: `$(printenv HOME; : "$td")`, `$(cd "$td"; cd; pwd)`,
# a mktemp under a real dir whose dirname is the real HOME). A caller that needs a scratch
# HOME should take a second mktemp, not a dirname. The false-pass shapes those rounds found
# are pinned below as must-flag fixtures; do not delete one to make a widening pass.
home_is_scratch() {
  local file="$1" line rest name rhs nocmd v changed is_scratch ref_re home_ok=0
  local dq='"[^"]*"' sq="'[^']*'" cs='\$\([^)]*\)' bare='[^[:space:]]*'
  local assign_re="(^|[^A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)=($dq|$sq|$cs|$bare)"
  local mk_re='(^|[^A-Za-z0-9_./-])mktemp([[:space:])"`]|$)'   # mktemp as a command word, not a path part like /opt/mktemp-user
  local xp_re='\$\{[A-Za-z_][A-Za-z0-9_]*[^A-Za-z0-9_}]'   # a parameter expansion with an operator
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
        # ${x:-...} / ${x:+...} / ${x%...} outside a $(...) may select a non-scratch value;
        # inside one (mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX") it only shapes mktemp's argument.
        nocmd="$rhs"
        while [[ "$nocmd" =~ $cs ]]; do nocmd="${nocmd/"${BASH_REMATCH[0]}"/}"; done
        [[ "$nocmd" =~ $xp_re ]] && continue
        if [[ "$rhs" =~ $mk_re ]]; then is_scratch=1; fi
        if [ "$is_scratch" -eq 0 ]; then
          for v in $scratch; do
            ref_re='\$('"$v"'([^A-Za-z0-9_{]|$)|\{'"$v"'\})'   # $v or ${v}, never ${v:+...} / ${v%/*}
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
# followed by whitespace, a quote, or one of `;&|,)}]` and backtick (no `10` /
# `1x` / `1.5` / `1-x`; a `1` ended by any other character is a false negative). A
# closing quote counts as the end of the value, so shell concatenation (`"1"x`, whose
# value is `1x`) is a false flag ON PURPOSE (HIMMEL-3345): a version that read it as a
# concatenation was tried and reverted, because each rule that ended a quoted `1` more
# precisely let a real lift through (`"1">/dev/null`, `"1"</dev/null`, `"1"$y`, `"1"""`,
# JS `"1"+""`, `"1"/*x*/`; six review rounds, the last two Critical). The shapes those
# rounds found are pinned below as must-flag fixtures; do not delete one to make a
# loosening pass. If a real caller trips this, rewrite the caller (`V=1`), not the matcher.
# It will NOT catch a fence lift spelled another way (a computed
# variable name, `Set-Item Env:`, `[Environment]::SetEnvironmentVariable`, a
# `process.env` object built from a variable name) or the value carried in a
# variable (`v=1; ... $v`). "Scratch HOME" is home_is_scratch above, with its own
# limits. A new operator-path caller has to be added to ALLOW_PATHS on purpose;
# that friction is the point.
scan_callers() {
  local root="$1"; shift
  local set_re="(^|[^A-Za-z0-9_])${V}[]'\"}]*[[:space:]]*[:=][[:space:]]*['\"]?1([][:space:];&|,)}'\"\`]|\$)"
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
# HIMMEL-3344: an expansion operator can swap the scratch value for the real one.
printf '#!/usr/bin/env bash\ntd="$(mktemp -d /tmp/x.XXXXXX)"\nHOME="${td:+$HOME}" %s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-scratch-operator.sh"
# ... but an operator INSIDE the mktemp command substitution is fine (test-uninstall.sh's shape).
printf '#!/usr/bin/env bash\ntd=$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX")\nHOME="$td/home" %s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-scratch-tmpdir.sh"
printf '#!/usr/bin/env bash\ntd="$(mktemp -d /tmp/x.XXXXXX)"\nother=/somewhere/real\nHOME="${other:-$td}" %s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-scratch-inside-operator.sh"
# HIMMEL-3344: the word mktemp inside a path is not a mktemp call.
printf '#!/usr/bin/env bash\nHOME=/opt/mktemp-user %s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-mktemp-in-path.sh"
# HIMMEL-3344: fence lifted through a quoted JS key + numeric value, an unquoted
# key + numeric value, and a PowerShell $env: assignment -- all uncovered pre-fix.
printf "runSpawn(cmd, { env: { '%s': 1 } });\n" "$V" > "$fx/scripts/quoted-key.js"
printf 'runSpawn(cmd, { env: { %s: 1 } });\n' "$V" > "$fx/scripts/numeric-value.mjs"
printf '$env:%s = 1\n& uninstall.ps1 -Yes\n' "$V" > "$fx/scripts/ps-env.ps1"
# HIMMEL-3343: uninstall.sh lifts the fence only for exactly 1, so =10 / =1x are not lifts.
printf '#!/usr/bin/env bash\n%s=10 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-value-10.sh"
printf '#!/usr/bin/env bash\n%s=1x bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-value-1x.sh"
printf '#!/usr/bin/env bash\n%s=1.5 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-value-1dot5.sh"
printf '#!/usr/bin/env bash\n%s=1-extra bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-value-1dash.sh"
# HIMMEL-3345: shapes that MUST stay flagged, pinned after the matcher was tried with
# looser rules (a quoted 1 read as a concatenation, a dirname of a scratch dir read as
# scratch) and each loosening opened a real false pass. Each of these lifts the fence for
# real (the shell sets the value to 1, or HOME resolves to the real HOME) and is flagged
# by the strict matcher. Cited: an independent false-pass review of the loosened matcher
# (2 Critical) plus the panel's own five rounds. @V@ stands for the variable name.
# ponytail: shapes origin/main already PASSES (false passes that predate this ticket) are
# NOT pinned, since they cannot be must-flag without a matcher change: an unquoted
# redirect after the value (1>/dev/null), the value spelled $'1', ${V:=1}, ${X:-1}, \1
# or ""1, and a HOME that reaches the real HOME through a second dirname, a dotdot, a
# literal /home dirname or an unquoted $HOME-in-scratch-ref. HIMMEL-3394 owns them: it
# inverts the matcher to an allow-list of provably-scratch values. Do not pin them here as
# "passes": an assertion that a lift passes would enshrine the hole.
pinned=()
RH=/ho"me"/someone   # @H@ in a fixture: a literal real home dir, spelled apart so the leak gate skips this source
pin() {   # pin <file> <line>... -- write one must-flag fixture under scripts/
  local name="$1" line; shift
  : > "$fx/scripts/$name"
  for line in "$@"; do line="${line//@V@/$V}"; printf '%s\n' "${line//@H@/$RH}" >> "$fx/scripts/$name"; done
  pinned+=("$name")
}
CR=$'\r'
# the two ticket shapes, flagged on purpose: a quoted 1 glued to a word, a dirname of a scratch dir.
pin ticket-concat-dq-word.sh '@V@="1"x bash uninstall.sh --yes'
pin ticket-concat-sq-word.sh "@V@='1'x bash uninstall.sh --yes"
pin ticket-concat-dq-dq.sh '@V@="1""x" bash uninstall.sh --yes'
pin ticket-dirname-scratch-dq.sh 'td=$(mktemp -d /tmp/x.XXXXXX)' 'HOME="$(dirname "$td")" @V@=1 bash uninstall.sh --yes'
# a quoted 1 followed by an expansion or an empty string is still 1.
pin q-var-dq.sh '@V@="1"$y bash uninstall.sh --yes'
pin q-var-dq-dq.sh '@V@="1""$y" bash uninstall.sh --yes'
pin q-var-sq.sh "@V@='1'\$y bash uninstall.sh --yes"
pin q-var-braced.sh '@V@="1""${y}" bash uninstall.sh --yes'
pin q-empty-dq.sh '@V@="1""" bash uninstall.sh --yes'
pin q-empty-sq.sh "@V@='1''' bash uninstall.sh --yes"
pin q-empty-dq-sq.sh "@V@=\"1\"'' bash uninstall.sh --yes"
pin q-empty-sq-dq.sh "@V@='1'\"\" bash uninstall.sh --yes"
pin q-empty-dq-dq-sq.sh "@V@=\"1\"\"\"'' bash uninstall.sh --yes"
pin q-empty-ansi.sh "@V@=\"1\"\$'' bash uninstall.sh --yes"
pin q-bare-1-dq.sh '@V@=1"" bash uninstall.sh --yes'
# a quoted 1 followed by a redirect, a control operator or a comment is a lift.
pin q-redir-dq.sh '@V@="1">/dev/null bash uninstall.sh --yes'
pin q-redir-sq.sh "@V@='1'>/dev/null bash uninstall.sh --yes"
pin q-redir-in-dq.sh '@V@="1"</dev/null bash uninstall.sh --yes'
pin q-redir-env.sh 'env @V@="1">log bash uninstall.sh --yes'
pin q-amp.sh '@V@="1"&&bash uninstall.sh'
pin q-paren.sh '( @V@="1") ; bash uninstall.sh'
pin q-hash.sh '@V@="1"#c bash uninstall.sh --yes'
pin q-space.sh '@V@="1" bash uninstall.sh --yes'
pin q-space-sq.sh "@V@='1' bash uninstall.sh --yes"
pin q-eol.sh 'export @V@="1"'
pin q-semi.sh '@V@="1";bash uninstall.sh --yes'
# shellcheck disable=SC1003  # the trailing backslash is the fixture, not an escape attempt
pin q-continued.sh '@V@="1"\' '  bash uninstall.sh --yes'
# shellcheck disable=SC1003
pin q-bs-newline.sh '@V@="1"\' ' bash uninstall.sh --yes'
pin q-enclosing.sh "sh -c \"@V@='1' bash uninstall.sh --yes\""
pin q-declare.sh 'declare -x @V@="1"' 'bash uninstall.sh --yes'
pin q-export.sh 'export @V@="1"' 'bash uninstall.sh --yes'
pin q-readonly.sh "readonly @V@='1'" 'bash uninstall.sh --yes'
# JS and PowerShell spellings of a quoted 1 that something follows.
pin q-js-comment.js 'spawn(c,{env:{@V@:"1"/*x*/}})'
pin q-js-linecomment.js "spawn(c,{env:{@V@: \"1\"//x" '}})'
pin q-js-plus.js 'spawn(c,{env:{@V@:"1"+""}})'
pin q-js-crlf.js "spawn(c,{env:{@V@: \"1\"$CR" "}})$CR"
pin q-ps-crlf.ps1 "\$env:@V@ = \"1\"$CR" "& uninstall.ps1 -Yes$CR"
pin q-ps-hash.ps1 '$env:@V@ = "1"#c' '& uninstall.ps1 -Yes'
# HOME resolves to the real HOME although a scratch dir is named on the line.
pin h-under-home.sh 'td=$(mktemp -d "$HOME/x.XXXXXX")' 'HOME="$(dirname "$td")" @V@=1 bash uninstall.sh --yes'
pin h-under-tilde-dq.sh 'td=$(mktemp -d ~/x.XXXXXX)' 'HOME="$(dirname "$td")" @V@=1 bash uninstall.sh --yes'
pin h-dirname-other.sh 'other=/somewhere/real' 'HOME=$(dirname "$other") @V@=1 bash uninstall.sh --yes'
pin h-dirname-real-home.sh 'td=$(mktemp -d /tmp/x.XXXXXX)' 'HOME=$(dirname "$HOME") @V@=1 bash uninstall.sh --yes'
pin h-dirname-operator.sh 'td=$(mktemp -d /tmp/x.XXXXXX)' 'HOME=$(dirname "${td:+$HOME}") @V@=1 bash uninstall.sh --yes'
pin h-nested-subst.sh 'HOME="$(echo "$(mktemp -d)" >/dev/null; printf %s "$HOME")" @V@=1 bash uninstall.sh --yes'
pin h-subst-scratch-ref.sh 'td=$(mktemp -d)' 'HOME="$(printf %s "$HOME"; : "$td")" @V@=1 bash uninstall.sh --yes'
pin h-printenv.sh 'td=$(mktemp -d)' 'HOME="$(printenv HOME; : "$td")"' '@V@=1 bash uninstall.sh --yes'
pin h-cd-home.sh 'td=$(mktemp -d)' 'HOME="$(cd "$td"; cd; pwd)"' '@V@=1 bash uninstall.sh --yes'
pin h-cd-up.sh 'td=$(mktemp -d)' 'cd "$td"/..; HOME=$PWD' '@V@=1 bash uninstall.sh --yes'
pin h-dirname-literal-home.sh 'td=$(mktemp -d @H@/x.XXXXXX)' 'HOME="$(dirname "$td")"' '@V@=1 bash uninstall.sh --yes'
pin h-dirname-p.sh 'td=$(mktemp -d -p "$USERDIR")' 'HOME="$(dirname "$td")"' '@V@=1 bash uninstall.sh --yes'
pin h-echo-escaped.sh 'td=$(mktemp -d)' 'HOME="$(eval echo "\\$""HOME"; : "$td")"' '@V@=1 bash uninstall.sh --yes'
pin h-eval.sh 'td=$(mktemp -d)' 'HOME="$(eval "echo \\${td:+\\$USER_HOME_DIR}")"' '@V@=1 bash uninstall.sh --yes'
pin h-getent.sh 'td=$(mktemp -d)' 'HOME="$(getent passwd "$USER" | cut -d: -f6; : "$td")"' '@V@=1 bash uninstall.sh --yes'
pin h-heredoc.sh 'td=$(mktemp -d)' 'HOME="$(cat <<X' '@H@ $td' 'X' ')"' '@V@=1 bash uninstall.sh --yes'
pin h-pwd.sh 'cd' 'td=$(mktemp -d "$PWD/x.XXXXXX")' 'HOME="$(dirname "$td")"' '@V@=1 bash uninstall.sh --yes'
pin h-realpath.sh 'td=$(mktemp -d)' 'HOME="$(realpath "$td/../..@H@")"' '@V@=1 bash uninstall.sh --yes'
pin h-td-reassigned.sh 'td=$(mktemp -d)' 'td=@H@' 'HOME="$(dirname "$td")/overlord"' '@V@=1 bash uninstall.sh --yes'
pin h-td-real.sh 'td=$HOME' 'HOME="$td"' '@V@=1 bash uninstall.sh --yes'
pin h-td-tilde.sh 'td=~' 'HOME="$td"' '@V@=1 bash uninstall.sh --yes'
pin h-tmpdir.sh 'td=$(TMPDIR=@H@ mktemp -d)' 'HOME="$(dirname "$td")"' '@V@=1 bash uninstall.sh --yes'
# HIMMEL-3344 (CodeRabbit): a longer identifier ending in the name is not the name.
printf '#!/usr/bin/env bash\nNOT_%s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-prefixed-name.sh"
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
check "a scratch variable behind an expansion operator (\${td:+\$HOME}) is flagged" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-scratch-operator.sh')" "1"
check "an expansion operator inside the mktemp command substitution still passes" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-scratch-tmpdir.sh')" "0"
check "a scratch variable inside another variable's expansion operator is flagged" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-scratch-inside-operator.sh')" "1"
check "the word mktemp inside a HOME path is flagged" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-mktemp-in-path.sh')" "1"
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
check "=1.5 is not a fence lift (not flagged)" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-value-1dot5.sh')" "0"
check "=1-extra is not a fence lift (not flagged)" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-value-1dash.sh')" "0"
check "a longer identifier ending in the name is not a fence lift (not flagged)" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-prefixed-name.sh')" "0"
for name in "${pinned[@]}"; do
  check "pinned false-pass shape is flagged: $name" \
    "$(printf '%s' "$got" | grep -cF "scripts/$name ")" "1"
done
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
