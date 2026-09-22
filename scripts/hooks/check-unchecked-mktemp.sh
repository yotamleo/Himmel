#!/usr/bin/env bash
# scripts/hooks/check-unchecked-mktemp.sh -- unchecked-mktemp pre-commit gate
# (HIMMEL-2709).
#
# Fail-closed. A missing or unreadable predicate library, an unresolvable
# repo root, a failing `git diff`, a failed added-lines scan, or an unreadable
# staged blob refuses the commit rather than waving it through -- each with
# its own distinct message so the mode is never ambiguous. `git diff`'s own
# failure is captured and its exit status checked BEFORE its (by-then
# known-good) output is ever read as "nothing staged" -- never
# `2>/dev/null || true`, which silently turns a genuine git error into a
# false "clean". Single-run bypass: UNCHECKED_MKTEMP_OK=1.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure git + the shared predicate; no .ps1 twin needed -- the only consumers
# are a shell pre-commit hook and a shell suite, both gitbash-only already.
#
# The CR ledger's single most-repeated defect class in the 14 days to
# 2026-09-07: `T=$(mktemp -d)` with the status unchecked, 10 separate `agreed`
# findings, every one a BARE capture with no guard at all. When mktemp fails
# the variable is EMPTY and every path built from it collapses to a
# filesystem-root path -- reviewers named `/repo/.env`, `/bash`, `/bin` and
# `/main` as the concrete things a failed allocation would then create,
# truncate or delete. The class already had a known-findings entry
# (`test-setup-unchecked-vacuous-green`) as a critic PROMPT only; this gate is
# that rule made structural, so it reaches the commit path and adopters, not
# just this repo's own review panel.
#
# Refuses a commit whose staged diff ADDS an unguarded mktemp capture --
# predicate shared with the suite via scripts/lib/unchecked-mktemp.sh so the
# two cannot drift. Only ADDED lines are ever considered (git diff --cached
# -U0 hunk headers): a large pre-existing count is expected and must never
# block an unrelated commit.
#
# The predicate's contract is deliberately simple: a capture is offending
# only when it has NO guard signal at all (a `||` anywhere on the line, the
# `mktemp-unchecked-ok:` escape, a same-line-remainder-or-next-3-line test of
# the variable, or `${VAR:?...}`) -- see scripts/lib/unchecked-mktemp.sh's
# header for the full rule list, why it dropped a guard-QUALITY allowlist
# that produced a self-blocking false positive, and the false negatives that
# tradeoff accepts on purpose. Two things worth calling out here because they
# affect what this gate scans: a line inside a QUOTED heredoc body with a
# matching terminator later in the file (a shell fixture a script writes to
# disk, e.g. `cat > f.sh <<'EOF'`) is never treated as a candidate assignment
# -- it is text, not code this repo executes -- while an UNQUOTED heredoc
# (`<<EOF`) still expands and executes, so a capture inside one is scanned
# normally. And a same-line guard after the capture (`T=$(mktemp -d); : "${T
# :?x}"`) counts exactly like a next-line one -- including on a
# declaration-prefixed line for a VALUE guard (`${VAR:?...}` or a test
# construct), since those read the variable's actual value rather than the
# declaration builtin's masked exit status; only a same-line `||` stays
# excluded on a declaration-prefixed line, where only a later line (or
# splitting the declaration from the assignment) can guard it.
#
# Reads the STAGED index only, never the working tree: every staged *.sh with
# additions is materialized from its staged blob (`git show ":$path"`) into a
# guarded mktemp scratch dir and scanned there. A CR finding on this gate's own
# sibling (check-new-shell-platform-guard.sh) was exactly the working-tree
# version of this bug: an untracked file satisfying a check that then didn't
# land in the commit.
#
# Staged names come from `git diff --cached -M -z --diff-filter=AMR
# --name-status`: `-z` NUL-delimits so a quoted path (git quotes
# non-ASCII/special-char names by default) is never mis-parsed by a
# line-oriented reader, and `--name-status` (rather than `--name-only`) is
# what makes a rename's SOURCE path available at all. A per-file `git diff
# --cached -U0 -- <dst>` restricted to the destination alone cannot pair with
# its delete-side source, so git shows the whole renamed file as ADDED and
# every pre-existing unguarded capture in it then blocks an unrelated rename
# (round-4 finding 3). Each staged rename/copy (`R###`) is instead diffed as
# `git diff --cached -M -U0 -- <src> <dst>`, giving git both sides so rename
# pairing (and therefore added-lines-only scoping) actually works; a plain
# add/modify is diffed by its single path as before. A rename that genuinely
# ADDS an unguarded capture in its new content is still scanned and refused
# exactly like any other addition.
#
# Exclusions: paths under archive/, and any path with a /testdata/ component
# (fixture data -- the known-findings convention).
#
# Exit codes: 0 = clean (nothing added, or every addition passes), 1 = an
# added line carries an unguarded mktemp capture, or an infrastructure
# failure (fail-closed).
set -uo pipefail

if [ "${UNCHECKED_MKTEMP_OK:-0}" = 1 ]; then
    echo "check-unchecked-mktemp: UNCHECKED_MKTEMP_OK=1 -- skipping (bypass used)" >&2
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Repo root resolved from the CWD's git context (not SCRIPT_DIR), so this gate
# can be exercised in place against a throwaway fixture repo -- same pattern
# as check-new-shell-platform-guard.sh / check-doc-guard.sh.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
    echo "FAIL: check-unchecked-mktemp: not inside a git repository" >&2
    exit 1
fi
cd "$REPO_ROOT" || { echo "FAIL: check-unchecked-mktemp: cannot cd to repo root $REPO_ROOT" >&2; exit 1; }

UNCHECKED_MKTEMP_LIB="$SCRIPT_DIR/../lib/unchecked-mktemp.sh"
if [ ! -r "$UNCHECKED_MKTEMP_LIB" ]; then
    echo "FAIL: check-unchecked-mktemp: predicate library missing or unreadable: $UNCHECKED_MKTEMP_LIB (fail-closed)" >&2
    exit 1
fi
# shellcheck source=scripts/lib/unchecked-mktemp.sh
# shellcheck disable=SC1091
. "$UNCHECKED_MKTEMP_LIB"

scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/check-unchecked-mktemp.XXXXXX")" || {
    echo "FAIL: check-unchecked-mktemp: mktemp -d failed" >&2
    exit 1
}
trap 'rm -rf "$scratch_dir"' EXIT

# Capture output/rc first (codex-2 shape from check-new-shell-platform-guard.sh):
# a genuine git error must surface, never read as "nothing staged". NUL-
# delimited (-z) output is written straight to a FILE, never captured into a
# shell variable -- bash strings are C strings and would silently truncate at
# the first embedded NUL, dropping every name after the first. stdout and
# stderr are captured separately for the same reason (stderr is plain text,
# not NUL-delimited, and merging the two streams would corrupt both).
diff_status_file="$scratch_dir/diff-status.nul"
diff_err_file="$scratch_dir/diff-status.err"
if ! git diff --cached -M -z --diff-filter=AMR --name-status \
        >"$diff_status_file" 2>"$diff_err_file"; then
    diff_err="$(cat "$diff_err_file" 2>/dev/null)"
    echo "FAIL: check-unchecked-mktemp: git diff --cached --name-status failed: $diff_err" >&2
    exit 1
fi

# Reshape the NUL-delimited name-status stream into NUL-delimited
# <dst>\0<src>\0 pairs (src is empty for a plain add/modify) -- a rename
# status field (`R###`) is followed by TWO paths (old, new) instead of one,
# so this has to walk the stream field-by-field rather than treat every
# record as a single path (round-4 finding 3).
diff_names_file="$scratch_dir/diff-names.nul"
: > "$diff_names_file"
while IFS= read -r -d '' status_field; do
    case "$status_field" in
        R*)
            IFS= read -r -d '' src_field || {
                echo "FAIL: check-unchecked-mktemp: truncated rename record in git diff --name-status output (fail-closed)" >&2
                exit 1
            }
            IFS= read -r -d '' dst_field || {
                echo "FAIL: check-unchecked-mktemp: truncated rename record in git diff --name-status output (fail-closed)" >&2
                exit 1
            }
            printf '%s\0%s\0' "$dst_field" "$src_field" >> "$diff_names_file"
            ;;
        *)
            IFS= read -r -d '' path_field || {
                echo "FAIL: check-unchecked-mktemp: truncated record in git diff --name-status output (fail-closed)" >&2
                exit 1
            }
            printf '%s\0%s\0' "$path_field" "" >> "$diff_names_file"
            ;;
    esac
done < "$diff_status_file"

# Added-line numbers (new-file numbering) for one staged file, from its own
# -U0 hunk headers -- `@@ -a,b +c,d @@` -> lines c..c+d-1. `+c` alone (no
# `,d`) is a single added line. A hunk that only removes (`+c,0`) contributes
# nothing. Printed one lineno per line into $3. $2 is the rename SOURCE path
# (empty for a plain add/modify) -- when set, both sides are handed to git so
# `-M` can actually pair the rename instead of showing the whole destination
# as added (round-4 finding 3).
added_lines_for() {
    local path="$1" src_path="$2" out="$3" hunks rc
    if [ -n "$src_path" ]; then
        if ! hunks="$(git diff --cached -M -U0 -- "$src_path" "$path" 2>&1)"; then
            echo "FAIL: check-unchecked-mktemp: git diff --cached -M -U0 -- $src_path $path failed: $hunks" >&2
            return 1
        fi
    else
        if ! hunks="$(git diff --cached -U0 -- "$path" 2>&1)"; then
            echo "FAIL: check-unchecked-mktemp: git diff --cached -U0 -- $path failed: $hunks" >&2
            return 1
        fi
    fi
    # rc captured right off the pipeline itself (pipefail is active, set at
    # the top of this file): $? here is the rightmost nonzero of {printf,
    # awk}, or 0 only if both -- including awk's own write to "$out" --
    # actually succeeded. Without this, an awk failure (a bad program, or an
    # unwritable "$out") would silently yield an empty added-line list, and
    # every violation on that file would go unreported -- the exact
    # fail-open hole the caller's fail-closed contract exists to prevent.
    printf '%s\n' "$hunks" | awk '
        /^@@ / {
            if (!match($0, /\+[0-9]+(,[0-9]+)?/)) next
            spec = substr($0, RSTART + 1, RLENGTH - 1)
            n = split(spec, parts, ",")
            start = parts[1] + 0
            count = (n > 1) ? parts[2] + 0 : 1
            for (i = 0; i < count; i++) print start + i
        }
    ' > "$out"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL: check-unchecked-mktemp: added-lines awk scan failed for $path (rc=$rc) (fail-closed)" >&2
        return 1
    fi
    return 0
}

fail=0
n_seen=0
n_scanned=0
n_violations=0
while IFS= read -r -d '' sh_path && IFS= read -r -d '' src_path; do
    [ -n "$sh_path" ] || continue
    # `.sh` filter and the fixture-data exclusion, both by pattern rather than
    # a piped grep -- `-z` above means $sh_path is the raw, unquoted path byte
    # for byte, so a case match here never falls victim to git's quoting.
    case "$sh_path" in
        *.sh) : ;;
        *) continue ;;
    esac
    case "$sh_path" in
        archive/*|*/testdata/*) continue ;;
    esac

    n_seen=$((n_seen + 1))
    added_file="$scratch_dir/$n_seen-added.txt"
    if ! added_lines_for "$sh_path" "$src_path" "$added_file"; then
        fail=1
        continue
    fi
    [ -s "$added_file" ] || continue
    n_scanned=$((n_scanned + 1))

    stage_sh="$scratch_dir/$n_seen-$(basename "$sh_path")"
    if ! git show ":$sh_path" > "$stage_sh" 2>/dev/null; then
        fail=1
        echo "⛔ check-unchecked-mktemp: cannot read the staged content of $sh_path (fail-closed)." >&2
        continue
    fi

    offending="$(unchecked_mktemp_scan "$stage_sh")" || {
        fail=1
        echo "⛔ check-unchecked-mktemp: predicate scan failed on the staged content of $sh_path (fail-closed)." >&2
        continue
    }
    [ -n "$offending" ] || continue

    while IFS="$(printf '\t')" read -r lineno text; do
        # (IFS set to a literal tab via printf -- $'\t' avoided so this file
        # stays byte-identical in tools that mangle ANSI-C quoting.)
        [ -n "$lineno" ] || continue
        # grep exit 1 = the line was not added; any other non-zero is a
        # lookup error, which must refuse rather than read as "not added".
        added_rc=0
        grep -Fxq "$lineno" "$added_file" || added_rc=$?
        [ "$added_rc" -eq 1 ] && continue
        if [ "$added_rc" -ne 0 ]; then
            fail=1
            echo "⛔ check-unchecked-mktemp: added-line lookup failed for $sh_path:$lineno (grep rc=$added_rc, fail-closed)." >&2
            continue
        fi
        fail=1
        n_violations=$((n_violations + 1))
        echo "⛔ check-unchecked-mktemp: $sh_path:$lineno: $text" >&2
        # A declaration builtin (local/export/declare/typeset/readonly) masks
        # mktemp's exit status with its own -- the fix is to split the
        # declaration from the assignment, not to add/adjust a `||`, so it
        # gets its own remedy text.
        case "$text" in
            local\ * | export\ * | declare\ * | typeset\ * | readonly\ *)
                echo "   Remedy: split the declaration from the assignment -- \`local VAR; VAR=\$(mktemp -d) || exit 1\` -- a same-line \`||\` on a local/export/declare/typeset/readonly line sees the declaration builtin's OWN exit status (always 0), never mktemp's." >&2
                ;;
            *)
                echo "   Remedy: guard the mktemp capture -- a same-line \`||\` (\`|| exit 1\`), a same-window \`[ -n/-z/-d \"\$VAR\" ]\`/\`[[ ]]\`/\`test\` check of \$VAR, or \`\${VAR:?msg}\` (the colon form -- \`\${VAR?msg}\` does not count, it only catches VAR being unset, not empty) -- or mark it \`# mktemp-unchecked-ok: <reason>\` if it genuinely cannot fail." >&2
                ;;
        esac
    done <<EOF
$offending
EOF
done < "$diff_names_file"

if [ "$fail" -ne 0 ]; then
    if [ "$n_violations" -gt 0 ]; then
        echo "FAIL: check-unchecked-mktemp: $n_violations unchecked mktemp capture(s) on added lines (see above)." >&2
        echo "   Bypass (single run, ships the unchecked capture): UNCHECKED_MKTEMP_OK=1 git commit ..." >&2
    fi
    exit 1
fi
echo "OK: check-unchecked-mktemp: $n_scanned staged *.sh with additions scanned, no unchecked mktemp on added lines."
exit 0
