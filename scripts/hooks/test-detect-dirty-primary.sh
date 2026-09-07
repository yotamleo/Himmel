#!/usr/bin/env bash
# Smoke test for detect-dirty-primary.sh (HIMMEL-2526).
#
# Platform guard (gitbash-only): POSIX bash 3.2+, incl. Git Bash on Windows.
# No .ps1 twin — the hook under test has none either (see its own header).
#
# Hermetic: git fixtures built under the REAL home (a temp dir there, NOT
# under /tmp — the FIXTURE RULE this suite follows), a hermetic HOME set
# only after that fixture is captured, and HIMMEL_PRIMARY_BASELINE_DIR
# pointed at a fixture subdirectory so this suite never touches the
# operator's real ~/.claude. Baselines are built by actually invoking the
# sibling record-primary-baseline.sh, cross-validating the pair rather than
# hand-writing baseline files.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
RECORD="$HOOKS_DIR/record-primary-baseline.sh"
DETECT="$HOOKS_DIR/detect-dirty-primary.sh"
[ -f "$RECORD" ] || { echo "recorder not found: $RECORD" >&2; exit 1; }
[ -f "$DETECT" ] || { echo "detector not found: $DETECT" >&2; exit 1; }

command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }

REAL_GIT="$(command -v git)"

_REAL_HOME="$HOME"
FIX="$(mktemp -d "${_REAL_HOME}/.himmel-2526-detfix-XXXXXX")" || exit 1
trap 'rm -rf "$FIX"' EXIT

MAIN="$FIX/main"
mkdir -p "$MAIN"
git init -q "$MAIN"
printf 'A\n' > "$MAIN/a.txt"
printf 'B\n' > "$MAIN/b.txt"
printf 'C\n' > "$MAIN/c.txt"
git -C "$MAIN" add a.txt b.txt c.txt
git -C "$MAIN" -c user.email=t@example.invalid -c user.name=t commit -q -m init
git -C "$MAIN" branch -q feat/x
WT="$FIX/wt"
git -C "$MAIN" worktree add -q "$WT" feat/x

# Fake, PATH-shadowing git that fails ONLY on `status`, delegating every
# other subcommand (rev-parse, etc. — needed by primary_checkout_root) to
# the real binary resolved above.
FAKEBIN="$FIX/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
    if [ "\$a" = "status" ]; then
        exit 1
    fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$FAKEBIN/git"

# Now go hermetic.
export HOME="$FIX/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$FIX/gitconfig"

BASE_DIR="$FIX/baseline"

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
# guardrails (not a flat dir): detect-dirty-primary.sh resolves
# scripts/guardrails/lib.sh RELATIVE TO ITS OWN LOCATION
# ("$SCRIPT_DIR/../guardrails/lib.sh"), so a mutant copied anywhere else
# fails that source (`|| exit 0`) and every control would silently exit 0
# for BOTH the mutant and the correct run — a vacuous "genuinely-not-red"
# that has nothing to do with the mutation itself.
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
# literal two-character `\n` (e.g. printf '%s\n' inside detect-dirty-
# primary.sh) silently never compares equal to $0 and the mutation looks
# like it "did not apply" for a reason that has nothing to do with the file
# having drifted. `read -r` + `[ = ]` do a byte-exact comparison with no
# escape processing at all.
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
# (fixed-string match), or nothing + rc=1 if it is missing or ambiguous. Used
# to capture an exact OLD_LINE for _mutate_line straight from the real
# script, rather than hand-transcribing it (and risking a byte that silently
# fails to match).
_get_line() {
    local f="$1" pat="$2" n
    n="$(grep -Fc -- "$pat" "$f" 2>/dev/null)"
    [ "$n" = "1" ] || return 1
    grep -F -- "$pat" "$f"
}

reset_main() {
    git -C "$MAIN" checkout -q -- .
    git -C "$MAIN" clean -qfd -- . >/dev/null 2>&1 || true
}

record_baseline() {  # record_baseline <session_id> <project_dir>
    printf '{"session_id":"%s"}' "$1" | \
        env CLAUDE_PROJECT_DIR="$2" HIMMEL_PRIMARY_BASELINE_DIR="$BASE_DIR" bash "$RECORD"
}

run_detect() {  # run_detect <session_id> <project_dir> [ENV=val ...]
    local sid="$1" proj="$2"; shift 2
    printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"true"}}' "$sid" | \
        env CLAUDE_PROJECT_DIR="$proj" HIMMEL_PRIMARY_BASELINE_DIR="$BASE_DIR" "$@" bash "$DETECT"
}

echo "== row (INCIDENT / UNGATED): baseline clean, a new tracked file is modified, HIMMEL_WORKER unset =="
reset_main
SID=sess-incident
record_baseline "$SID" "$MAIN" >/dev/null
printf 'A modified\n' > "$MAIN/a.txt"
unset HIMMEL_WORKER 2>/dev/null || true
out="$(run_detect "$SID" "$MAIN" env -u HIMMEL_WORKER 2>&1)"
rc=$?
if [ "$rc" -eq 2 ] && [[ "$out" == *a.txt* ]] && [[ "$out" == *"$MAIN"* ]]; then
    ok "incident shape (ungated, no HIMMEL_WORKER): exit 2, report names a.txt and the primary path"
else
    bad "incident shape: rc=$rc out=[$out]"
fi

echo "== row: reported ONCE — immediate second run with no further change =="
out2="$(run_detect "$SID" "$MAIN" 2>&1)"
rc2=$?
if [ "$rc2" -eq 0 ] && [ -z "$out2" ]; then
    ok "second run with no further change is silent (baseline rewritten after the report)"
else
    bad "second run: rc=$rc2 out=[$out2]"
fi

echo "== row: a SECOND, different new dirty file after the first report =="
printf 'B modified\n' > "$MAIN/b.txt"
out3="$(run_detect "$SID" "$MAIN" 2>&1)"
rc3=$?
if [ "$rc3" -eq 2 ] && [[ "$out3" == *b.txt* ]] && [[ "$out3" != *a.txt* ]]; then
    ok "second distinct dirty file: exit 2, names only b.txt (not the already-reported a.txt)"
else
    bad "second distinct dirty file: rc=$rc3 out=[$out3]"
fi
reset_main

echo "== row: a file already dirty at baseline time -> silent =="
SID=sess-alreadydirty
printf 'C already dirty at baseline\n' > "$MAIN/c.txt"
record_baseline "$SID" "$MAIN" >/dev/null
out4="$(run_detect "$SID" "$MAIN" 2>&1)"
rc4=$?
if [ "$rc4" -eq 0 ] && [ -z "$out4" ]; then
    ok "file already dirty when the session started is never reported"
else
    bad "already-dirty case: rc=$rc4 out=[$out4]"
fi
reset_main

echo "== row: no baseline file for the session -> exit 0 silent =="
SID=sess-nobaseline
out5="$(run_detect "$SID" "$MAIN" 2>&1)"
rc5=$?
if [ "$rc5" -eq 0 ] && [ -z "$out5" ]; then
    ok "no baseline file -> exit 0 silent (fail-open)"
else
    bad "no-baseline case: rc=$rc5 out=[$out5]"
fi

echo "== row: git status invocation failing -> exit 0, no verdict, once-per-session log marker =="
SID=sess-statusfail
record_baseline "$SID" "$MAIN" >/dev/null
out6="$(run_detect "$SID" "$MAIN" env PATH="$FAKEBIN:$PATH" 2>&1)"
rc6=$?
MARKER="$BASE_DIR/$SID.status-failed"
if [ "$rc6" -eq 0 ] && [ -z "$out6" ] && [ -f "$MARKER" ]; then
    ok "failed git status -> exit 0, no verdict, once-per-session marker written"
else
    bad "status-fail case: rc=$rc6 out=[$out6] marker_present=$([ -f "$MARKER" ] && echo yes || echo no)"
fi

echo "== row: run from a LINKED WORKTREE, dirt in the PRIMARY is still detected =="
reset_main
SID=sess-wt-detect
record_baseline "$SID" "$WT" >/dev/null
printf 'A dirtied via worktree-scoped session\n' > "$MAIN/a.txt"
out7="$(run_detect "$SID" "$WT" 2>&1)"
rc7=$?
if [ "$rc7" -eq 2 ] && [[ "$out7" == *a.txt* ]] && [[ "$out7" == *"$MAIN"* ]]; then
    ok "session scoped to a linked worktree still detects dirt in the PRIMARY"
else
    bad "linked-worktree case: rc=$rc7 out=[$out7]"
fi
reset_main

echo "== row (codex-8, HIMMEL-2526): comm must run under LC_ALL=C too, not the session locale =="
if ! locale -a 2>/dev/null | grep -qi '^en_US\.utf8$'; then
    echo "  SKIP comm-locale row: en_US.utf8 locale not installed on this station"
else
    reset_main
    SID=sess-comm-locale
    # apple.txt / Zebra.txt: case-mixed names whose relative order FLIPS
    # between the C locale (ASCII: uppercase before lowercase, so
    # "Zebra.txt" < "apple.txt") and a real installed locale like en_US.utf8
    # (dictionary order: base letter decides first, case-insensitively, so
    # "apple.txt" < "Zebra.txt") — exactly the disagreement codex-8 reports.
    # Both `sort` calls are already forced to LC_ALL=C; only `comm` itself was
    # left on the session locale.
    printf 'apple\n' > "$MAIN/apple.txt"
    printf 'zebra\n' > "$MAIN/Zebra.txt"
    git -C "$MAIN" add apple.txt Zebra.txt
    git -C "$MAIN" -c user.email=t@example.invalid -c user.name=t commit -q -m "add apple/Zebra fixtures"
    printf 'apple dirtied BEFORE baseline\n' > "$MAIN/apple.txt"
    record_baseline "$SID" "$MAIN" >/dev/null
    printf 'zebra dirtied AFTER baseline\n' > "$MAIN/Zebra.txt"
    out8="$(run_detect "$SID" "$MAIN" env LC_ALL=en_US.utf8 2>&1)"
    rc8=$?
    if [ "$rc8" -eq 2 ] && [[ "$out8" == *Zebra.txt* ]] && [[ "$out8" != *apple.txt* ]]; then
        ok "comm runs under LC_ALL=C: only the genuinely-new Zebra.txt is reported, apple.txt (already dirty at baseline) is not re-reported under a non-C session locale (codex-8)"
    else
        bad "comm-locale case (codex-8): rc=$rc8 out=[$out8] — expected rc=2 naming Zebra.txt but NOT apple.txt"
    fi
    reset_main
fi

echo "== row (codex-6, HIMMEL-2526 CR round 3): the rewrite temp file must be created INSIDE out_dir, not \${TMPDIR:-/tmp}, so the rename is same-filesystem =="
# \`mv\` is only atomic WITHIN one filesystem; \${TMPDIR:-/tmp} and \$HOME can
# be (and on this station ARE: /tmp is tmpfs, \$HOME is btrfs) different
# filesystems, in which case \`mv\` silently falls back to copy+unlink and a
# concurrent reader could see a partial file — the exact guarantee the code
# comment claims. Verified by intercepting mktemp's TEMPLATE argument via a
# PATH-shadowing shim, mirroring test-record-primary-baseline.sh's codex-9
# row rather than inventing a second technique.
reset_main
SID=sess-tmp-locality
record_baseline "$SID" "$MAIN" >/dev/null
printf 'A dirtied for tmp-locality row\n' > "$MAIN/a.txt"
FAKEBIN3="$FIX/fakebin-mktemp"
mkdir -p "$FAKEBIN3"
MKTEMP_LOG="$FIX/mktemp-template.log"
rm -f "$MKTEMP_LOG"
REAL_MKTEMP="$(command -v mktemp)"
cat > "$FAKEBIN3/mktemp" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
    case "\$a" in
        -*) : ;;
        *) printf '%s\n' "\$a" >> "$MKTEMP_LOG" ;;
    esac
done
exec "$REAL_MKTEMP" "\$@"
EOF
chmod +x "$FAKEBIN3/mktemp"
run_detect "$SID" "$MAIN" env PATH="$FAKEBIN3:$PATH" >/dev/null 2>&1
tmpl="$(cat "$MKTEMP_LOG" 2>/dev/null)"
case "$tmpl" in
    "$BASE_DIR"/*) ok "temp file template is inside HIMMEL_PRIMARY_BASELINE_DIR — same filesystem as the rename target (codex-6)" ;;
    *) bad "temp file template NOT inside out_dir (codex-6): got [$tmpl] — expected a path under $BASE_DIR/" ;;
esac
reset_main

echo "== RED CONTROL 1 (reported-once): dropped baseline rewrite still re-reports on the next call =="
reset_main
SID=sess-ctrl-reported-once
record_baseline "$SID" "$MAIN" >/dev/null
printf 'A dirtied for control 1\n' > "$MAIN/a.txt"

# Single-quoted and deliberate (SC2016): the pattern must stay literal so it
# matches the real script's source text byte-for-byte.
# shellcheck disable=SC2016
old1="$(_get_line "$DETECT" 'mv -f "$tmp" "$baseline_file"')"
if [ -z "$old1" ]; then
    bad "RED control 1 (reported-once) setup: exact target line not found in $DETECT — script drifted, control cannot run"
else
    mutant="$MUTANTS/detect-no-rewrite.sh"
    if ! _mutate_line "$DETECT" "$mutant" "$old1" "        true"; then
        bad "RED control 1 (reported-once) setup: mutation did not apply"
    else
        # First call against the mutant advances state exactly as the real
        # script would (nothing has diverged yet on the FIRST report) --
        # setup, not the assertion under test.
        printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"true"}}' "$SID" | \
            env CLAUDE_PROJECT_DIR="$MAIN" HIMMEL_PRIMARY_BASELINE_DIR="$BASE_DIR" bash "$mutant" >/dev/null 2>&1

        probe="$MUTANTS/probe-reported-once.sh"
        cat > "$probe" <<PROBE
#!/usr/bin/env bash
out="\$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"true"}}' "$SID" | \\
    env CLAUDE_PROJECT_DIR="$MAIN" HIMMEL_PRIMARY_BASELINE_DIR="$BASE_DIR" bash "$mutant" 2>&1 >/dev/null)"
rc=\$?
names=""
for n in a.txt b.txt c.txt; do
    case "\$out" in
        *"\$n"*) names="\${names:+\$names,}\$n" ;;
    esac
done
[ -n "\$names" ] || names=none
printf 'rc=%s names=%s' "\$rc" "\$names"
PROBE
        chmod +x "$probe"

        # Second call, no further change -- THIS is the assertion: the
        # correct script rewrote its baseline after the first report and is
        # now silent; the mutant, having dropped that rewrite, reports the
        # SAME file again.
        red_control_run -- bash "$probe"
        if red_control_assert \
            --label "reported-once" \
            --observed     "$RED_CONTROL_OUT" \
            --expect-wrong "rc=2 names=a.txt" \
            --correct      "rc=0 names=none" \
            --note "WITHOUT the baseline rewrite after a report, a.txt is re-reported on every subsequent Bash call for the rest of the session instead of once"
        then pass=$((pass+1)); else fail=$((fail+1)); fi
    fi
fi
reset_main

echo "== RED CONTROL 2 (baseline-aware): ignoring the baseline re-reports an already-dirty file =="
reset_main
SID=sess-ctrl-baseline-aware
printf 'C already dirty at baseline (control 2)\n' > "$MAIN/c.txt"
record_baseline "$SID" "$MAIN" >/dev/null

old2="$(_get_line "$DETECT" 'baseline_out" | LC_ALL=C sort')"
if [ -z "$old2" ]; then
    bad "RED control 2 (baseline-aware) setup: exact target line not found in $DETECT — script drifted, control cannot run"
else
    # Remove ONLY the "$baseline_out" token, turning the baseline side of the
    # comm(1) diff into an always-empty source -- everything currently dirty
    # then reads as "new", regardless of the recorded baseline.
    new2="${old2/\$baseline_out/}"
    mutant="$MUTANTS/detect-ignore-baseline.sh"
    if ! _mutate_line "$DETECT" "$mutant" "$old2" "$new2"; then
        bad "RED control 2 (baseline-aware) setup: mutation did not apply"
    else
        probe="$MUTANTS/probe-baseline-aware.sh"
        cat > "$probe" <<PROBE
#!/usr/bin/env bash
out="\$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"true"}}' "$SID" | \\
    env CLAUDE_PROJECT_DIR="$MAIN" HIMMEL_PRIMARY_BASELINE_DIR="$BASE_DIR" bash "$mutant" 2>&1 >/dev/null)"
rc=\$?
names=""
for n in a.txt b.txt c.txt; do
    case "\$out" in
        *"\$n"*) names="\${names:+\$names,}\$n" ;;
    esac
done
[ -n "\$names" ] || names=none
printf 'rc=%s names=%s' "\$rc" "\$names"
PROBE
        chmod +x "$probe"

        red_control_run -- bash "$probe"
        if red_control_assert \
            --label "baseline-aware" \
            --observed     "$RED_CONTROL_OUT" \
            --expect-wrong "rc=2 names=c.txt" \
            --correct      "rc=0 names=none" \
            --note "WITHOUT baseline-awareness, c.txt (already dirty when the session started) is reported as if it were newly dirtied"
        then pass=$((pass+1)); else fail=$((fail+1)); fi
    fi
fi
reset_main

echo "== RED CONTROL 3 (status-failure never interpreted): a failed git status read as clean skips the once-per-session marker =="
SID=sess-ctrl-status-fail
record_baseline "$SID" "$MAIN" >/dev/null

# Single-quoted and deliberate (SC2016): the pattern must stay literal so it
# matches the real script's source text byte-for-byte.
# shellcheck disable=SC2016
old3="$(_get_line "$DETECT" 'if [ "$rc" -ne 0 ]; then')"
if [ -z "$old3" ]; then
    bad "RED control 3 (status-failure) setup: exact target line not found in $DETECT — script drifted, control cannot run"
else
    mutant="$MUTANTS/detect-status-fail-as-clean.sh"
    if ! _mutate_line "$DETECT" "$mutant" "$old3" 'if false; then'; then
        bad "RED control 3 (status-failure) setup: mutation did not apply"
    else
        marker="$BASE_DIR/$SID.status-failed"
        rm -f "$marker"
        probe="$MUTANTS/probe-status-fail.sh"
        cat > "$probe" <<PROBE
#!/usr/bin/env bash
out="\$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"true"}}' "$SID" | \\
    env CLAUDE_PROJECT_DIR="$MAIN" HIMMEL_PRIMARY_BASELINE_DIR="$BASE_DIR" PATH="$FAKEBIN:\$PATH" bash "$mutant" 2>&1 >/dev/null)"
rc=\$?
marker=absent; [ -f "$marker" ] && marker=present
printf 'rc=%s marker=%s stderr_empty=%s' "\$rc" "\$marker" "\$([ -z "\$out" ] && echo yes || echo no)"
PROBE
        chmod +x "$probe"

        # Both the real script and this mutant exit 0 with no stderr here --
        # a failed git status is silent EITHER way. The only observable
        # difference a mutant that "reads failure as clean and continues"
        # produces is that it never reaches the branch that writes the
        # once-per-session failure marker. An inequality on rc or on stdout
        # alone would NOT catch this mutation -- which is exactly why this
        # control asserts on the marker file's presence instead.
        red_control_run -- bash "$probe"
        if red_control_assert \
            --label "status-failure-never-interpreted" \
            --observed     "$RED_CONTROL_OUT" \
            --expect-wrong "rc=0 marker=absent stderr_empty=yes" \
            --correct      "rc=0 marker=present stderr_empty=yes" \
            --note "WITHOUT treating a failed git status as unverifiable, the once-per-session failure marker is never written -- a second failed call in the same session would re-attempt logging silently forever instead of exactly once"
        then pass=$((pass+1)); else fail=$((fail+1)); fi
    fi
fi
reset_main

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
