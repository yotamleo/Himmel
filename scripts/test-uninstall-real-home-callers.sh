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

# HIMMEL-3394: both halves are ALLOW-LISTS. Enumerating dangerous spellings lost six
# review rounds to shapes nobody had listed (HIMMEL-3345), so the rule is inverted: a
# write of the var counts as a lift unless it is provably not 1 (and a text matcher can
# prove nothing -- see scan_callers), and HOME counts as scratch only in the few shapes
# below. Anything else flags. A real caller that trips it is rewritten (a second mktemp,
# a guard), never the matcher loosened.

# join_continued <file> -- the file as the shell reads it: every backslash-newline removed.
join_continued() { sed -e ':a' -e '/\\$/N' -e 's/\\\n//' -e 'ta' "$1"; }

# home_is_scratch <file> -- succeed when EVERY assignment to HOME in the file (at least
# one) is one of exactly: "$v", $v, "${v}", ${v}, "$v/<literal path>" (no `..`), or a
# literal $(mktemp -d [template]), quoted or not; and the file never drops HOME
# (`unset HOME`, `export -n HOME`, `env -u HOME`, `env -i`, `exec -c`, quoted or not:
# a child without HOME falls back to the passwd home).
# v is scratch when EVERY assignment to it is one of the same shapes, a mktemp one
# followed by `|| exit` / `|| return` / `|| { ...; exit N; }` -- an unguarded failed
# mktemp leaves v empty, and "$v/home/<user>" is then the real HOME. The template is one
# word: a literal, or a quoted literal after at most one `$x` / `${x}` / `${x:-/tmp}`
# (mktemp -d prints a fresh directory or fails, whatever the template says).
# Everything else is NOT scratch -- $(dirname ...), `..`, $PWD, $1, "$v-x", a concatenation,
# and any write that is not a plain `NAME=` (`v+=`, `v[i]=`, `${v:=...}`).
# ponytail: flow-INSENSITIVE text tracing over `NAME=` on raw lines (continuations
# joined). It cannot see order (a HOME assigned from v BEFORE v's mktemp, or inherited
# from the caller's shell), scope (`local v` / a subshell / a function argument), or a
# write through `read` / `printf -v` / `declare -n` / a sourced file; and it does not tie a
# lift to the HOME on its own command (`HOME="$td" true; VAR=1 bash uninstall.sh` passes,
# the lift inheriting the real HOME). It reads text, so an assignment-shaped comment or
# printf fixture counts: a non-scratch one is a false flag, and a file whose only scratch
# HOME is text passes (HIMMEL-3345). Separating those needs a parser.
home_is_scratch() {
  local file="$1" line rest name s i j ok changed homes=0
  local assign_re='(^|[^A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)(\[[^]]*\])?([-+:*/%&|^]?)=(.*)'
  local end_re='^([[:space:];&|)]|$)' lit='[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*/?'
  local tpl='([A-Za-z0-9_./%+-]+|"(\$[A-Za-z_][A-Za-z0-9_]*|\$\{[A-Za-z_][A-Za-z0-9_]*(:-/tmp)?\})?[A-Za-z0-9_./%+-]*")'
  local mk='\$\(mktemp -d( '"$tpl"')?\)'
  local mk_re='^('"$mk"'|"'"$mk"'")(.*)$'
  # the brace form must END in an unconditional exit/return: every command before it is
  # `;`-separated with no `&&` / `||` / `&` / `|` bar a `>&N` redirect (`{ false && exit 1; }` falls through).
  local guard_re='^[[:space:]]*\|\|[[:space:]]*((exit|return)([[:space:]]+[0-9]+)?[[:space:]]*([;)#]|$)|\{(([^};&|]|>&[0-9])*;)*[[:space:]]*(exit|return)([[:space:]]+[0-9]+)?[[:space:]]*;[[:space:]]*\})'
  local drop_re='(^|[^A-Za-z0-9_])(unset([[:space:]]+-[A-Za-z]+)*([[:space:]]+[A-Za-z_][A-Za-z0-9_]*)*[[:space:]]+HOME|export[[:space:]]+-[A-Za-z]*n[A-Za-z]*([[:space:]]+[A-Za-z_][A-Za-z0-9_]*)*[[:space:]]+HOME|env[[:space:]].*(-u[[:space:]]*|--unset=)HOME)([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])(env([[:space:]]+-[A-Za-z]*i[A-Za-z]*|[[:space:]]+--ignore-environment|[[:space:]]+-)|exec[[:space:]]+-[A-Za-z]*c[A-Za-z]*)([[:space:]]|$)'
  local scratch=" " names=() vals=()
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ $drop_re || "${line//[\"\']/}" =~ $drop_re ]] && return 1   # quotes deleted too: `unset "HOME"`
    rest="$line"
    while [[ "$rest" =~ $assign_re ]]; do
      names+=("${BASH_REMATCH[2]}"); rest="${BASH_REMATCH[5]}"
      # `v+=`, `v[i]=`, `${v:=...}`: never a scratch shape (`<op>` matches none).
      if [ -n "${BASH_REMATCH[3]}${BASH_REMATCH[4]}" ]; then vals+=("<op>"); else vals+=("$rest"); fi
    done
  done < <(join_continued "$file")
  # scratch_value <value> <guard:0|1> -- the value (the text after `=`) is a scratch shape.
  scratch_value() {
    local val="$1" rest r
    if [[ "$val" =~ $mk_re ]]; then
      rest="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
      [[ "$rest" =~ $end_re ]] || return 1
      [ "$2" -eq 0 ] || [[ "$rest" =~ $guard_re ]]
      return
    fi
    for s in $scratch; do
      r='^("\$('"$s"'|\{'"$s"'\})(/'"$lit"')?"|\$('"$s"'|\{'"$s"'\}))(.*)$'
      [[ "$val" =~ $r ]] || continue
      rest="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
      [[ "${BASH_REMATCH[1]}" != *..* && "$rest" =~ $end_re ]] && return 0
    done
    return 1
  }
  while :; do   # least fixpoint: v joins once every assignment to it is scratch
    changed=0
    for ((i=0; i<${#names[@]}; i++)); do
      name="${names[$i]}"
      [ "$name" = HOME ] && continue
      case "$scratch" in *" $name "*) continue ;; esac
      ok=1
      for ((j=0; j<${#names[@]}; j++)); do
        [ "${names[$j]}" = "$name" ] || continue
        scratch_value "${vals[$j]}" 1 || { ok=0; break; }
      done
      [ "$ok" -eq 1 ] && { scratch="$scratch$name "; changed=1; }
    done
    [ "$changed" -eq 0 ] && break
  done
  for ((i=0; i<${#names[@]}; i++)); do
    [ "${names[$i]}" = HOME ] || continue
    scratch_value "${vals[$i]}" 0 || return 1
    homes=$((homes+1))
  done
  [ "$homes" -gt 0 ]
}

# VCI: the var name matching any case ([Hh][Ii]...): Windows env names are case-insensitive.
VCI=""; _up="$(printf '%s' "$V" | tr '[:lower:]' '[:upper:]')"; _lo="$(printf '%s' "$V" | tr '[:upper:]' '[:lower:]')"
for ((_k=0; _k<${#V}; _k++)); do
  case "${_up:$_k:1}" in [A-Z]) VCI="${VCI}[${_up:$_k:1}${_lo:$_k:1}]" ;; *) VCI="$VCI${_up:$_k:1}" ;; esac
done

# sets_var <file> -- succeed when the file WRITES the var anywhere: the name (any case,
# not inside a longer identifier), an optional `[subscript]` and closing quotes/brackets,
# then `=`, `+=` / `??=` / any operator-assignment, `:` (a JS/YAML key, `${VAR:=...}`)
# or `,` (SetEnvironmentVariable("VAR", ...), a JS shorthand key). Only the shell READS
# `${VAR:-...}` / `${VAR:+...}` / `${VAR:?...}` are exempt. Every write is a lift: no
# value is provably not 1 to a line matcher, because under `declare -i` / `let` /
# `(( ))` (possibly declared on another line) `1-extra`, `0|1`, `2 -1` and even an empty
# value followed by ` 1` are 1, and in JS `+"1"`, `1.0`, `0x1` are. So `=10`, `=unset`
# and `=0` flag too (a false flag, never a false pass). It runs on the raw lines AND on
# the continuation-joined text with every quote and backslash deleted, so a name split
# by a continuation, quotes or a backslash (`export HIMMEL_''..=1`) is still seen.
# ponytail: it will NOT see a write that never spells the name next to its operator: a
# computed name (`n=...; export "$n=1"`, a name split by an EMPTY EXPANSION like `${e}`),
# `read` / `printf -v` / `declare -n`, `Set-Item Env:`, or a JS env object built from a
# variable key. A mention with none of `=:,` after it (`unset VAR`, a comment) is a read.
sets_var() (   # rc 0 = writes the var, 1 = does not, 2 = the file could not be scanned
  set -o pipefail
  local file="$1" read_re site_re st
  read_re="\\\$\\{$VCI:[-+?]"
  site_re="(^|[^A-Za-z0-9_])$VCI(\\[[^]]*\\])?[]'\"}]*[[:space:]]*([-+*/%&|^?<>!]*=|:|,)"
  # grep without -q reads to EOF, so no producer takes SIGPIPE; any producer failure is rc 2.
  { cat -- "$file" && printf '\n' && join_continued "$file" | sed -e "s/\\\$\\([\"']\\)/\\1/g" -e "s/[\"'\\\\]//g"; } \
    | sed -E "s/$read_re//g" | grep -E "$site_re" >/dev/null
  st=("${PIPESTATUS[@]}")
  [ "${st[0]}" -eq 0 ] && [ "${st[1]}" -eq 0 ] && [ "${st[2]}" -le 1 ] || exit 2
  exit "${st[2]}"
)

# scan_callers <root> [allowed-path...] -- print (root-relative) every file under
# <root>/scripts that writes the var (sets_var) without a scratch HOME
# (home_is_scratch) and is not allowed. A new operator-path caller has to be added to
# ALLOW_PATHS on purpose; that friction is the point.
scan_callers() {
  local root="$1"; shift
  local f rel a allowed list rc
  # A failed traversal (unreadable subtree) is reported, not scanned around.
  list="$(find "$root/scripts" -path '*/node_modules' -prune -o -type f \
    \( -name '*.sh' -o -name '*.js' -o -name '*.mjs' -o -name '*.ts' -o -name '*.ps1' \) -print)" \
    || { printf 'scripts (find failed under %s)\n' "$root"; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$root"/}"
    # an unreadable file is reported rather than passed as a non-match.
    if [ ! -r "$f" ]; then printf '%s (unreadable)\n' "$rel"; continue; fi
    sets_var "$f"; rc=$?
    [ "$rc" -eq 1 ] && continue
    if [ "$rc" -ne 0 ]; then printf '%s (unreadable: scan rc=%s)\n' "$rel" "$rc"; continue; fi
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
printf '#!/usr/bin/env bash\ntd=$(mktemp -d /tmp/x.XXXXXX) || exit 1\nHOME="$td/home" %s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-scratch.sh"
# HIMMEL-3344: an unrelated mktemp does not make HOME a scratch dir.
printf '#!/usr/bin/env bash\ntmp="$(mktemp -d /tmp/x.XXXXXX)"\nHOME="$HOME"\n%s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-unrelated-mktemp.sh"
# HIMMEL-3344: HOME assigned from a variable that is NOT mktemp-derived.
printf '#!/usr/bin/env bash\ntmp="$(mktemp -d /tmp/x.XXXXXX)"\nother=/somewhere/real\nHOME="$other"\n%s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-home-from-other.sh"
# HIMMEL-3344: HOME derived from a mktemp variable through a second variable
# (the shape of test-e2e-symmetry-isolation.sh) passes.
printf '#!/usr/bin/env bash\ntd="$(mktemp -d /tmp/x.XXXXXX)" || exit 1\nctl="$td/ctlhome"\nHOME="$ctl" %s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-scratch-transitive.sh"
# HIMMEL-3344: a literal mktemp on the HOME assignment passes.
printf '#!/usr/bin/env bash\nHOME="$(mktemp -d /tmp/x.XXXXXX)" %s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-scratch-literal.sh"
# HIMMEL-3344: an expansion operator can swap the scratch value for the real one.
printf '#!/usr/bin/env bash\ntd="$(mktemp -d /tmp/x.XXXXXX)"\nHOME="${td:+$HOME}" %s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-scratch-operator.sh"
# ... but an operator INSIDE the mktemp command substitution is fine (test-uninstall.sh's shape).
printf '#!/usr/bin/env bash\ntd=$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX") || { echo no tmp; exit 1; }\nHOME="$td/home" %s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-scratch-tmpdir.sh"
printf '#!/usr/bin/env bash\ntd="$(mktemp -d /tmp/x.XXXXXX)"\nother=/somewhere/real\nHOME="${other:-$td}" %s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-scratch-inside-operator.sh"
# HIMMEL-3344: the word mktemp inside a path is not a mktemp call.
printf '#!/usr/bin/env bash\nHOME=/opt/mktemp-user %s=1 bash uninstall.sh --yes\n' "$V" > "$fx/scripts/test-mktemp-in-path.sh"
# HIMMEL-3344: fence lifted through a quoted JS key + numeric value, an unquoted
# key + numeric value, and a PowerShell $env: assignment -- all uncovered pre-fix.
printf "runSpawn(cmd, { env: { '%s': 1 } });\n" "$V" > "$fx/scripts/quoted-key.js"
printf 'runSpawn(cmd, { env: { %s: 1 } });\n' "$V" > "$fx/scripts/numeric-value.mjs"
printf '$env:%s = 1\n& uninstall.ps1 -Yes\n' "$V" > "$fx/scripts/ps-env.ps1"
# HIMMEL-3343 read these as not-lifts (uninstall.sh lifts only for exactly 1); HIMMEL-3394 flags
# them: under declare -i / let / (( )) `1-extra` is 1, so no value is provably not 1 (false flags).
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
# The shapes #1069 left unpinned (false passes at its base) are pinned below under
# HIMMEL-3394, which inverted the matcher to allow-lists. Never pin a lift as "passes":
# that assertion would enshrine the hole.
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
# HIMMEL-3394: the eleven false passes of the enumerating matcher (the console's review of #1069).
# shellcheck disable=SC1003  # the backslash is the fixture
pin v-backslash.sh '@V@=\1 bash uninstall.sh --yes'
pin v-ansi-c.sh "@V@=\$'1' bash uninstall.sh --yes"
pin v-empty-dq-bare.sh '@V@=""1 bash uninstall.sh --yes'
pin v-bare-redir.sh '@V@=1>/dev/null bash uninstall.sh --yes'
pin v-default.sh '@V@=${X:-1} bash uninstall.sh --yes'
pin v-assign-default.sh ': "${@V@:=1}"' 'export @V@' 'bash uninstall.sh --yes'
pin h-dirname-dirname.sh 'td=$(mktemp -d /tmp/x.XXXXXX) || exit 1' 'HOME=$(dirname "$(dirname "$td")") @V@=1 bash uninstall.sh --yes'
pin h-dirname-under-real.sh 'td=$(mktemp -d @H@/x.XXXXXX) || exit 1' 'HOME=$(dirname "$td") @V@=1 bash uninstall.sh --yes'
pin h-dotdot.sh 'td=$(mktemp -d "$HOME/x.XXXXXX") || exit 1' 'HOME="$td/.." @V@=1 bash uninstall.sh --yes'
pin h-cd-home-bare.sh 'td=$(mktemp -d) || exit 1' 'HOME=$(cd "$td"; cd; pwd) @V@=1 bash uninstall.sh --yes'
pin h-printenv-bare.sh 'td=$(mktemp -d) || exit 1' 'HOME=$(printenv HOME; : "$td") @V@=1 bash uninstall.sh --yes'
# HIMMEL-3394: classes the allow-list closes beyond the eleven.
QV="HIMMEL_UNINSTALL_''REAL_HOME"   # the name split by an empty quote; bash still reads the full name
pin w-split-name.sh "export $QV=1" 'bash uninstall.sh --yes'
pin w-continued-name.sh "export @V@\\" '=1' 'bash uninstall.sh --yes'
pin w-arith.sh 'declare -i @V@' '@V@=2-1 bash uninstall.sh --yes'
pin w-append.sh '@V@=' '@V@+=1 bash uninstall.sh --yes'
pin w-subscript.sh 'export @V@' '@V@[0]=1 bash uninstall.sh --yes'
pin w-js-unary.js 'spawn(c,{env:{@V@:+"1"}})'
pin w-js-logical.js 'process.env.@V@ ??= "1"; spawn(c)'
pin w-ps-setenv.ps1 "[Environment]::SetEnvironmentVariable('@V@', '1')" '& uninstall.ps1 -Yes'
pin w-lowercase.ps1 "\$env:$(printf '%s' "$V" | tr '[:upper:]' '[:lower:]') = 1" '& uninstall.ps1 -Yes'
pin h-unguarded.sh 'td=$(mktemp -d /nonexistent/x.XXXXXX)' 'HOME="$td@H@" @V@=1 bash uninstall.sh --yes'
pin h-v-reassigned.sh 'td=$(mktemp -d) || exit 1' 'td=$HOME' 'HOME="$td" @V@=1 bash uninstall.sh --yes'
pin h-second-home.sh 'td=$(mktemp -d) || exit 1' 'HOME="$td" true' 'HOME=~ @V@=1 bash uninstall.sh --yes'
pin h-unset-home.sh 'td=$(mktemp -d) || exit 1' 'HOME="$td" true' 'unset HOME' '@V@=1 bash uninstall.sh --yes'
pin h-env-i.sh 'td=$(mktemp -d) || exit 1' 'HOME="$td" true' 'env -i PATH=/usr/bin @V@=1 bash uninstall.sh --yes'
pin h-env-u.sh 'td=$(mktemp -d) || exit 1' 'HOME="$td" true' 'env -u HOME @V@=1 bash uninstall.sh --yes'
# HIMMEL-3415: the same drops, quoted or spelled another way.
pin h-unset-quoted.sh 'td=$(mktemp -d) || exit 1' 'HOME="$td" true' 'unset "HOME"' '@V@=1 bash uninstall.sh --yes'
pin h-export-n.sh 'td=$(mktemp -d) || exit 1' 'HOME="$td" true' 'export -n HOME' '@V@=1 bash uninstall.sh --yes'
pin h-env-i-quoted.sh 'td=$(mktemp -d) || exit 1' 'HOME="$td" true' 'env "-i" PATH=/usr/bin @V@=1 bash uninstall.sh --yes'
pin h-env-u-quoted.sh 'td=$(mktemp -d) || exit 1' 'HOME="$td" true' "env -u 'HOME' @V@=1 bash uninstall.sh --yes"
pin h-exec-c.sh 'td=$(mktemp -d) || exit 1' 'HOME="$td" true' 'exec -c env @V@=1 bash uninstall.sh --yes'
pin h-suffix-var.sh 'td=$(mktemp -d) || exit 1' 'HOME="$td/$1" @V@=1 bash uninstall.sh --yes'
pin h-subst-template.sh 'td=$(mktemp -d "$(printf %s "$HOME")") || exit 1' 'HOME="$td" @V@=1 bash uninstall.sh --yes'
pin h-mktemp-then.sh 'HOME="$(mktemp -d; printf %s "$HOME")" @V@=1 bash uninstall.sh --yes'
pin h-home-append.sh 'HOME=$(mktemp -d)' 'HOME+=/../..' '@V@=1 bash uninstall.sh --yes'
pin h-v-append.sh 'td=$(mktemp -d) || exit 1' 'td+=/../..' 'HOME="$td" @V@=1 bash uninstall.sh --yes'
pin h-home-default.sh 'HOME=$(mktemp -d)' ': "${HOME:=@H@}"' '@V@=1 bash uninstall.sh --yes'
pin h-v-subscript.sh 'td=$(mktemp -d) || exit 1' 'td[0]=@H@' 'HOME="$td" @V@=1 bash uninstall.sh --yes'
pin h-conditional-guard.sh 'td=$(mktemp -d /nonexistent/x.XXXXXX) || { false && exit 1; }' 'HOME="$td@H@" @V@=1 bash uninstall.sh --yes'
pin h-redirect-and-guard.sh 'td=$(mktemp -d /nonexistent/x.XXXXXX) || { echo no >&2 && exit 1; }' 'HOME="$td@H@" @V@=1 bash uninstall.sh --yes'
pin h-guard-exit-hyphen.sh 'td=$(mktemp -d /nonexistent/x.XXXXXX) || exit-later' 'HOME="$td@H@" @V@=1 bash uninstall.sh --yes'
pin h-guard-exit-later.sh 'td=$(mktemp -d /nonexistent/x.XXXXXX) || { exit_later=1; }' 'HOME="$td@H@" @V@=1 bash uninstall.sh --yes'
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
check "=10 is flagged (1 in an arithmetic context)" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-value-10.sh')" "1"
check "=1x is flagged (1 in an arithmetic context)" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-value-1x.sh')" "1"
check "=1.5 is flagged (1 in an arithmetic context)" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-value-1dot5.sh')" "1"
check "=1-extra is flagged (1 in an arithmetic context)" \
  "$(printf '%s' "$got" | grep -c 'scripts/test-value-1dash.sh')" "1"
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

sets_var "$fx/scripts/no-such-file.sh" 2>/dev/null; check "a read error in sets_var is rc 2, not a non-match" "$?" "2"
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
