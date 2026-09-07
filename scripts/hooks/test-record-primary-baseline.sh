#!/usr/bin/env bash
# Smoke test for record-primary-baseline.sh (HIMMEL-2526).
#
# Platform guard (gitbash-only): POSIX bash 3.2+, incl. Git Bash on Windows.
# No .ps1 twin — the hook under test has none either (see its own header).
#
# Hermetic: git fixtures built under the REAL home (a temp dir there, NOT
# under /tmp — the FIXTURE RULE this suite follows), a hermetic HOME set
# only after that fixture is captured, and HIMMEL_PRIMARY_BASELINE_DIR /
# HIMMEL_HOOK_INTEGRITY_DIR both pointed at fixture subdirectories so this
# suite never touches the operator's real ~/.claude.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HOOKS_DIR/record-primary-baseline.sh"
[ -f "$SCRIPT" ] || { echo "hook not found: $SCRIPT" >&2; exit 1; }

command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }

_REAL_HOME="$HOME"
FIX="$(mktemp -d "${_REAL_HOME}/.himmel-2526-recfix-XXXXXX")" || exit 1
trap 'rm -rf "$FIX"' EXIT

# Build fixtures under the real HOME BEFORE overriding it.
MAIN="$FIX/main"
mkdir -p "$MAIN"
git init -q "$MAIN"
printf 'hello\n' > "$MAIN/file.txt"
git -C "$MAIN" add file.txt
git -C "$MAIN" -c user.email=t@example.invalid -c user.name=t commit -q -m init
git -C "$MAIN" branch -q feat/x
WT="$FIX/wt"
git -C "$MAIN" worktree add -q "$WT" feat/x

NONGIT="$FIX/nongit"
mkdir -p "$NONGIT"

# Now go hermetic.
export HOME="$FIX/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$FIX/gitconfig"

BASE_DIR="$FIX/baseline"
INTEG_DIR="$FIX/integrity"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# RED-control contract (HIMMEL-2518): scratch space for the stderr captures
# red_control_run writes, under the fixture root — never /tmp directly.
# Consumed by the sourced red-control.sh below (shellcheck cannot follow
# that indirection).
# shellcheck disable=SC2034
RED_CONTROL_TMPDIR="$FIX"
# shellcheck source=../lib/red-control.sh
# shellcheck disable=SC1091
. "$HOOKS_DIR/../lib/red-control.sh"

# Mutants live under a scratch tree that mirrors scripts/hooks + scripts/
# guardrails (not a flat dir): record-primary-baseline.sh resolves
# scripts/guardrails/lib.sh RELATIVE TO ITS OWN LOCATION
# ("$SCRIPT_DIR/../guardrails/lib.sh"), so a mutant copied anywhere else
# fails that source (`|| exit 0`) and the control would silently exit 0 for
# BOTH the mutant and the correct run — a vacuous "genuinely-not-red" that
# has nothing to do with the mutation itself.
MUTANTS="$FIX/mutant-tree/scripts/hooks"
mkdir -p "$MUTANTS" "$FIX/mutant-tree/scripts/guardrails"
cp "$HOOKS_DIR/../guardrails/lib.sh" "$FIX/mutant-tree/scripts/guardrails/lib.sh"

# _mutate_line SRC DST OLD_LINE NEW_LINE -- byte-exact single-line swap into a
# scratch copy. Never mutates SRC in place. Fails (rc=1, DST not usable) when
# OLD_LINE is not found verbatim, so a control cannot silently degrade into
# testing an unmutated copy of the real script if the source drifts.
#
# Pure bash, deliberately NOT awk -v: awk's -v assignment C-unescapes its
# value (\n -> a real newline, \t -> tab, ...), so a target line containing a
# literal two-character `\n` would silently never compare equal to $0.
# `read -r` + `[ = ]` do a byte-exact comparison with no escape processing.
_mutate_line() {
    local src="$1" dst="$2" old="$3" new="$4" line found=0
    : > "$dst"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$old" ]; then
            printf '%s\n' "$new" >> "$dst"
            found=1
        else
            printf '%s\n' "$line" >> "$dst"
        fi
    done < "$src"
    [ "$found" -eq 1 ]
}

# _get_line FILE PATTERN -- print the SOLE line of FILE containing PATTERN
# (fixed-string match), or nothing + rc=1 if it is missing or ambiguous.
_get_line() {
    local f="$1" pat="$2" n
    n="$(grep -Fc -- "$pat" "$f" 2>/dev/null)"
    [ "$n" = "1" ] || return 1
    grep -F -- "$pat" "$f"
}

run_hook() {  # run_hook <payload-json> [ENV=val ...]
    local payload="$1"; shift
    printf '%s' "$payload" | env "$@" bash "$SCRIPT"
}

echo "== row: writes <sid>.primary-baseline with the primary's porcelain output =="
printf 'hello\nmore\n' > "$MAIN/file.txt"   # unstaged modification -> tracked-file dirt
expected="$(git -C "$MAIN" --no-optional-locks status --porcelain -uno)"
[ -n "$expected" ] || { echo "FIXTURE BROKEN: expected dirty MAIN to have porcelain output" >&2; exit 1; }
run_hook '{"session_id":"sess-baseline"}' \
    CLAUDE_PROJECT_DIR="$MAIN" HIMMEL_PRIMARY_BASELINE_DIR="$BASE_DIR" HIMMEL_HOOK_INTEGRITY_DIR="$INTEG_DIR"
rc=$?
BASELINE_FILE="$BASE_DIR/sess-baseline.primary-baseline"
if [ "$rc" -eq 0 ] && [ -f "$BASELINE_FILE" ] && [ "$(cat "$BASELINE_FILE")" = "$expected" ]; then
    ok "baseline file written with the primary's porcelain output"
else
    bad "rc=$rc file_present=$([ -f "$BASELINE_FILE" ] && echo yes || echo no) content=[$(cat "$BASELINE_FILE" 2>/dev/null)] expected=[$expected]"
fi

echo "== row: writes NOTHING into HIMMEL_HOOK_INTEGRITY_DIR (stay off the 2528 transaction) =="
if [ ! -e "$INTEG_DIR" ] || [ -z "$(ls -A "$INTEG_DIR" 2>/dev/null)" ]; then
    ok "integrity dir untouched"
else
    bad "integrity dir was written to: $(ls -A "$INTEG_DIR" 2>/dev/null)"
fi

echo "== row: session_id shape guard =="
for bad_sid in 'sess/1' '../evil' 'sess..1'; do
    before_count=$(find "$BASE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    run_hook "{\"session_id\":\"$bad_sid\"}" \
        CLAUDE_PROJECT_DIR="$MAIN" HIMMEL_PRIMARY_BASELINE_DIR="$BASE_DIR" HIMMEL_HOOK_INTEGRITY_DIR="$INTEG_DIR"
    rc=$?
    after_count=$(find "$BASE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$rc" -eq 0 ] && [ "$before_count" = "$after_count" ]; then
        ok "malformed session_id '$bad_sid' -> exit 0, no file created anywhere"
    else
        bad "malformed session_id '$bad_sid': rc=$rc before=$before_count after=$after_count"
    fi
done

echo "== row: missing CLAUDE_PROJECT_DIR -> exit 0, no file =="
before_count=$(find "$BASE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
env -u CLAUDE_PROJECT_DIR sh -c "printf '%s' '{\"session_id\":\"sess-noproj\"}' | HIMMEL_PRIMARY_BASELINE_DIR=\"$BASE_DIR\" bash \"$SCRIPT\""
rc=$?
NOPROJ_FILE="$BASE_DIR/sess-noproj.primary-baseline"
if [ "$rc" -eq 0 ] && [ ! -f "$NOPROJ_FILE" ]; then
    ok "missing CLAUDE_PROJECT_DIR -> exit 0, no file"
else
    bad "rc=$rc file_present=$([ -f "$NOPROJ_FILE" ] && echo yes || echo no)"
fi

echo "== row: run from a LINKED WORKTREE, baseline still describes the PRIMARY =="
run_hook '{"session_id":"sess-wt"}' \
    CLAUDE_PROJECT_DIR="$WT" HIMMEL_PRIMARY_BASELINE_DIR="$BASE_DIR" HIMMEL_HOOK_INTEGRITY_DIR="$INTEG_DIR"
rc=$?
WT_BASELINE="$BASE_DIR/sess-wt.primary-baseline"
if [ "$rc" -eq 0 ] && [ -f "$WT_BASELINE" ] && [ "$(cat "$WT_BASELINE")" = "$expected" ]; then
    ok "SessionStart from a linked worktree still records the PRIMARY's dirt"
else
    bad "rc=$rc file_present=$([ -f "$WT_BASELINE" ] && echo yes || echo no) content=[$(cat "$WT_BASELINE" 2>/dev/null)] expected=[$expected]"
fi

echo "== row (codex-9, HIMMEL-2526): the temp file must be created INSIDE out_dir, not \${TMPDIR:-/tmp}, so the rename is same-filesystem =="
# \`mv\` is only atomic WITHIN one filesystem; \${TMPDIR:-/tmp} and \$HOME can
# be (and on this station ARE: /tmp is tmpfs, \$HOME is btrfs) different
# filesystems, in which case \`mv\` silently falls back to copy+unlink and a
# concurrent reader (detect-dirty-primary.sh) could see a partial file — the
# exact guarantee the code comment claims. Verified here by intercepting
# mktemp's TEMPLATE argument via a PATH-shadowing shim (a real cross-
# filesystem partial-read race is not practically reproducible in a unit
# test) and asserting the template lives under out_dir.
FAKEBIN2="$FIX/fakebin-mktemp"
mkdir -p "$FAKEBIN2"
MKTEMP_LOG="$FIX/mktemp-template.log"
rm -f "$MKTEMP_LOG"
REAL_MKTEMP="$(command -v mktemp)"
cat > "$FAKEBIN2/mktemp" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
    case "\$a" in
        -*) : ;;
        *) printf '%s\n' "\$a" >> "$MKTEMP_LOG" ;;
    esac
done
exec "$REAL_MKTEMP" "\$@"
EOF
chmod +x "$FAKEBIN2/mktemp"
run_hook '{"session_id":"sess-tmp-locality"}' \
    CLAUDE_PROJECT_DIR="$MAIN" HIMMEL_PRIMARY_BASELINE_DIR="$BASE_DIR" HIMMEL_HOOK_INTEGRITY_DIR="$INTEG_DIR" PATH="$FAKEBIN2:$PATH"
rc=$?
tmpl="$(cat "$MKTEMP_LOG" 2>/dev/null)"
case "$tmpl" in
    "$BASE_DIR"/*) ok "temp file template is inside HIMMEL_PRIMARY_BASELINE_DIR — same filesystem as the rename target (codex-9)" ;;
    *) bad "temp file template NOT inside out_dir (codex-9): got [$tmpl] rc=$rc — expected a path under $BASE_DIR/" ;;
esac

echo "== RED CONTROL (recorder stays off the integrity pin): writing into HIMMEL_HOOK_INTEGRITY_DIR instead of the baseline dir =="
# The single-quoted pattern below is deliberate -- it must stay literal, not
# shell-expand, so it matches the real script's SOURCE TEXT byte-for-byte.
# shellcheck disable=SC2016
old4="$(_get_line "$SCRIPT" 'out_dir="${HIMMEL_PRIMARY_BASELINE_DIR:-$HOME/.claude/himmel/primary-baseline}"')"
if [ -z "$old4" ]; then
    bad "RED control (recorder-off-integrity-pin) setup: exact target line not found in $SCRIPT — script drifted, control cannot run"
else
    new4="${old4/HIMMEL_PRIMARY_BASELINE_DIR/HIMMEL_HOOK_INTEGRITY_DIR}"
    new4="${new4/primary-baseline/hook-integrity}"
    mutant="$MUTANTS/record-into-integrity-dir.sh"
    if ! _mutate_line "$SCRIPT" "$mutant" "$old4" "$new4"; then
        bad "RED control (recorder-off-integrity-pin) setup: mutation did not apply"
    else
        CID=sess-ctrl-integrity
        CTRL_BASE="$FIX/ctrl-baseline"
        CTRL_INTEG="$FIX/ctrl-integrity"
        mkdir -p "$CTRL_BASE" "$CTRL_INTEG"

        probe="$MUTANTS/probe-integrity.sh"
        cat > "$probe" <<PROBE
#!/usr/bin/env bash
out="\$(printf '{"session_id":"%s"}' "$CID" | \\
    env CLAUDE_PROJECT_DIR="$MAIN" HIMMEL_PRIMARY_BASELINE_DIR="$CTRL_BASE" HIMMEL_HOOK_INTEGRITY_DIR="$CTRL_INTEG" bash "$mutant" 2>&1 >/dev/null)"
rc=\$?
bfile=absent
[ -f "$CTRL_BASE/$CID.primary-baseline" ] && bfile=present
ifile=absent
[ -f "$CTRL_INTEG/$CID.primary-baseline" ] && ifile=present
printf 'rc=%s baseline_file=%s integrity_file=%s' "\$rc" "\$bfile" "\$ifile"
PROBE
        chmod +x "$probe"

        red_control_run -- bash "$probe"
        if red_control_assert \
            --label "recorder-off-integrity-pin" \
            --observed     "$RED_CONTROL_OUT" \
            --expect-wrong "rc=0 baseline_file=absent integrity_file=present" \
            --correct      "rc=0 baseline_file=present integrity_file=absent" \
            --note "WITHOUT resolving out_dir from HIMMEL_PRIMARY_BASELINE_DIR, the recorder's output lands in the HIMMEL-2528 integrity-pin directory instead of its own, and the baseline detect-dirty-primary.sh depends on is never written"
        then pass=$((pass+1)); else fail=$((fail+1)); fi
    fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
