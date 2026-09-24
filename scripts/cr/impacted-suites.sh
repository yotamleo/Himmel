#!/usr/bin/env bash
# scripts/cr/impacted-suites.sh — which test suites exercise the files a PR
# changed (HIMMEL-2821).
#
# WHY. PR #2261 changed scripts/machine-setup/uninstall-plugins.sh and merged
# with scripts/test-uninstall.sh — a suite one directory UP that drives it end
# to end — never run: its implementor swept the owning directory, its certifier
# ran /pr-check, and nothing in the ship tail computed "which suites reference
# what this PR changed". Private main went red and it surfaced only on public
# CI. "Owning suites" was prose resolved by directory proximity; this is the
# structural replacement.
#
# Usage:
#   impacted-suites.sh <base>..<head> [--shell]
#       Print the union, one repo-relative path per line, sorted. For every
#       file changed between merge-base(<base>,<head>) and <head> (deletions
#       included, renames counted as delete+add), list each suite at <head>
#       whose text references the file's basename — or, for a slash command or
#       skill, `/<name>`. A changed suite lists itself. --shell keeps only
#       test-*.sh (what run-shell-tests.sh can run); the *.test.mjs / .js / .ts
#       suites are listed without it and are run by their own runner — see
#       --runner below for which one.
#   impacted-suites.sh --check <base>..<head>
#       The verdict gate. Reads one line per impacted suite from stdin:
#           SUITE <path> = PASS
#           SUITE <path> = SKIP <reason>          (reason required)
#           SUITE <path> = BLOCKED <denial>       (denial required)
#       Exit 0 when every impacted suite has a PASS or SKIP; exit 1, naming
#       each on stderr, when any is missing; exit 3 when every suite has a
#       verdict but one is BLOCKED — accounted for, yet the suite did not run,
#       so the /pr-check row is NOT clean until the console/operator rules.
#   impacted-suites.sh --runner <path>
#       Print the ONE command CI uses to run a JS/TS suite path (HIMMEL-3436),
#       e.g. `node --test scripts/hooks/foo.test.mjs` or
#       `cd scripts/jira && npx vitest run src/foo.test.ts`. The map is read
#       off .github/workflows/ci.yml, never guessed — a path CI does not run
#       (or a runner directory this script does not yet know) refuses non-zero
#       naming the path, rather than defaulting to `bun test` (HIMMEL-3436: a
#       node:test suite can pass under node --test and fail under bun test on
#       an unrelated bun fs quirk — a false red no code change caused).
#   impacted-suites.sh --runner-check
#       Drift check over ci.yml's run: lines, naming the offending line, exit
#       1 on any of: (a) unmapped — a JS/TS test invocation (node --test, bun
#       test, npm test, a direct npx/bunx vitest or vitest run, or
#       check-hook-lib-suites.sh) that no known marker recognises; (b) drifted
#       — a recognised marker's line now invokes a DIFFERENT runner family
#       than --runner emits for it (e.g. a mapped suite's `node --test`
#       switched to `bun test`); (c) ambiguous — a single line names more than
#       one runner family (cannot attribute one runner to it), reported
#       distinctly and failed closed rather than guessed. Exit 0 when every
#       matched line is mapped, in-kind, and unambiguous.
#   impacted-suites.sh --run <path>
#       Run ONE impacted suite (a test-*.sh, or a JS/TS suite via --runner),
#       first installing its owning package's deps when the nearest
#       package.json ancestor has no node_modules (HIMMEL-3553: a fresh
#       worktree is created with --no-install, so every package but the jira
#       CLI starts with no node_modules — a leg running a suite raw sees a
#       false SKIP/FAIL it mislabels "pre-existing"). The install is frozen
#       and offline-first (npm ci / bun install --frozen-lockfile) from
#       whichever lockfile the package dir commits. A suite with no
#       package.json ancestor, or whose node_modules already exists, runs
#       unchanged. Exit 2, naming the package dir and the install command,
#       on a missing lockfile or a failed install — never a SKIP, never a
#       bare FAIL — before the suite itself ever runs.
#
# Exit codes: 0 ok / clean; 1 EITHER --check found a missing verdict OR
# --runner-check found an unmapped/drifted/ambiguous invocation — these are
# two distinct checks that never run in the same invocation, so the meaning
# of exit 1 is fixed by which flag was passed; 2 usage, an unresolvable
# range, a failed search, --runner found no mapping, or --run's dep install
# failed; 3 --check found a BLOCKED suite. A range that cannot be resolved
# (or searched) is an ERROR, never an empty list: an empty impacted set reads
# as "nothing to run". --run otherwise exits with the suite's own exit code.
#
# ponytail: references are DIRECT and textual. A suite that reaches a changed
# file only through an intermediate script it calls (no mention of the changed
# file's basename), or builds the path at runtime ("$dir/uninstall-$kind.sh"),
# is not found — the union under-approximates. Widen a suite's text with the
# basename of what it really drives rather than adding a transitive walk here.
# A basename shared by many files (lib.sh) over-approximates on purpose; the
# safe direction for a gate is a suite too many, never one too few.
#
# Platform guard: POSIX bash 3.2+ (no mapfile / associative arrays); runs
# under Git Bash on Windows. No .ps1 twin — it is a git + grep pipeline.
set -uo pipefail
# HIMMEL-3495: a relative-entry copy that is not the anchor's hands off to it.
. "$(dirname "${BASH_SOURCE[0]}")/anchor-handoff.sh" || exit 2

# io_fail <what> — a step that builds the impacted list or the verdict set did
# not run; an empty or partial list must never read as "nothing to run".
io_fail() {
    echo "impacted-suites: ${1} failed — cannot trust the impacted list" >&2
    exit 2
}

usage() {
    sed -n '2,/^set -uo/p' "$0" | sed -n 's/^# \{0,1\}//p' >&2
}

# runner_for <path> — print the ONE command CI uses to run a JS/TS suite path
# (HIMMEL-3436), read off .github/workflows/ci.yml. Exit 2, naming the path,
# for anything this table does not cover — never a guessed default (a
# node:test suite can genuinely disagree with `bun test` on an unrelated bun
# fs quirk, so guessing is not a safe fallback here).
runner_for() {
    local path="$1" rel
    case "$path" in
        scripts/hooks/*.test.mjs|scripts/lib/*.test.mjs|scripts/lanes/tests/*.test.mjs|scripts/trust/tests/*.test.mjs)
            printf 'node --test %q\n' "$path" ;;
        scripts/jira/*.test.ts)
            rel="${path#scripts/jira/}"
            printf 'cd scripts/jira && npx vitest run %q\n' "$rel" ;;
        scripts/bitbucket/*.test.ts)
            rel="${path#scripts/bitbucket/}"
            printf 'cd scripts/bitbucket && npx vitest run %q\n' "$rel" ;;
        scripts/himmel-run/*.test.ts)
            rel="${path#scripts/himmel-run/}"
            printf 'cd scripts/himmel-run && npx vitest run %q\n' "$rel" ;;
        scripts/ci-orchestrator/*.test.ts)
            rel="${path#scripts/ci-orchestrator/}"
            printf 'cd scripts/ci-orchestrator && npx vitest run %q\n' "$rel" ;;
        scripts/luna-vitals/*.test.mjs|scripts/luna-vitals/*.test.js|scripts/luna-vitals/*.test.ts)
            rel="${path#scripts/luna-vitals/}"
            printf 'cd scripts/luna-vitals && bun test %q\n' "$rel" ;;
        scripts/telegram/*.test.mjs|scripts/telegram/*.test.js|scripts/telegram/*.test.ts)
            printf 'bun test %q --dots\n' "$path" ;;
        scripts/vault/tests/*.test.mjs|scripts/vault/tests/*.test.js|scripts/vault/tests/*.test.ts)
            printf 'bun test %q --dots\n' "$path" ;;
        marketplace/plugins/luna-correlate/*.test.mjs|marketplace/plugins/luna-correlate/*.test.js|marketplace/plugins/luna-correlate/*.test.ts)
            rel="${path#marketplace/plugins/luna-correlate/}"
            printf 'cd marketplace/plugins/luna-correlate && bun test %q\n' "$rel" ;;
        *)
            echo "impacted-suites.sh: --runner has no CI-runner mapping for '${path}' — refusing to guess" >&2
            return 2 ;;
    esac
}

# runner_known_markers — one `label|kind|locate` row per JS/TS invocation
# ci.yml is known to run today. `locate` is the literal substring that
# identifies the line (a path/glob, or the bare command for the ambiguous
# multi-directory cases); `kind` is the runner family runner_for's own
# command for that suite belongs to (node-test, bun-test, vitest, npm-test,
# or hook-lib — a script call, not a runner). Keep this list in lockstep with
# runner_for by hand; there is no way to derive one from the other without
# reimplementing the YAML.
#
# ponytail: this scans `run:` LINES only — a JS/TS test invocation written
# inside a `run: |` block scalar body (the command on a following indented
# line, not the `run:` line itself) is invisible to it. No current ci.yml step
# does this; widen the grep to a block-scalar-aware scan if one ever does.
#
# ponytail: the `npm test` marker (kind npm-test) matches by SUBSTRING only,
# with no directory context — it is satisfied by `npm test` run from ANY
# working directory, including a future one runner_for has no case for, and
# it cannot detect drift within itself (unlike the single-line markers below,
# nothing on the `run: npm test` line names which vitest directory it covers
# or would show a swap to a different runner there). Narrowing it means
# parsing ci.yml's `working-directory:` keys, which this grep-based check
# deliberately does not do — a line-level scan fails closed instead (see
# runner_check's ambiguous case) rather than guess at that attribution.
runner_known_markers() {
    cat <<'EOF'
lanes-node-suites|node-test|scripts/lanes/tests/**/*.test.mjs
trust-suites|node-test|scripts/trust/tests/*.test.mjs
hook-lib-suites|hook-lib|check-hook-lib-suites.sh
matrix-npm-test|npm-test|npm test
luna-vitals|bun-test|scripts/luna-vitals && bun install
telegram-suites|bun-test|bun test scripts/telegram --dots
vault-suites|bun-test|bun test scripts/vault/tests --dots
luna-correlate|bun-test|marketplace/plugins/luna-correlate && bun install
EOF
}

# line_kind <line> — which runner family a run: line invokes, by literal
# substring, bash 3.2/grep-level (no YAML parsing). "ambiguous" when more than
# one family's substring appears on the same line — that line cannot be
# attributed to one runner, so runner_check fails it closed rather than guess.
line_kind() {
    local line="$1" n=0 kind=""
    case "$line" in *"node --test"*) n=$((n + 1)); kind=node-test ;; esac
    case "$line" in *"bun test"*) n=$((n + 1)); kind=bun-test ;; esac
    case "$line" in *"npm test"*) n=$((n + 1)); kind=npm-test ;; esac
    case "$line" in *"npx vitest"*|*"bunx vitest"*|*"vitest run"*) n=$((n + 1)); kind=vitest ;; esac
    case "$line" in *"check-hook-lib-suites.sh"*) n=$((n + 1)); kind=hook-lib ;; esac
    if [ "$n" -gt 1 ]; then
        echo ambiguous
    elif [ "$n" -eq 0 ]; then
        echo unknown
    else
        echo "$kind"
    fi
}

runner_check() {
    local ci="$PWD/.github/workflows/ci.yml" line kind label exp_kind locate matched drift missing=0
    [ -f "$ci" ] || io_fail "reading ci.yml for --runner-check"
    while IFS= read -r line; do
        kind=$(line_kind "$line")
        if [ "$kind" = ambiguous ]; then
            echo "impacted-suites: --runner-check: ambiguous JS/TS test invocation — more than one runner family on one line, refusing to guess: ${line}" >&2
            missing=1
            continue
        fi
        matched=0
        drift=""
        while IFS='|' read -r label exp_kind locate; do
            case "$line" in
                *"$locate"*)
                    matched=1
                    [ "$exp_kind" = "$kind" ] || drift="${label} expects ${exp_kind}, ci.yml now runs ${kind}"
                    ;;
            esac
        done < <(runner_known_markers)
        if [ "$matched" -eq 0 ]; then
            echo "impacted-suites: --runner-check: ci.yml runs a JS/TS test invocation --runner does not map: ${line}" >&2
            missing=1
        elif [ -n "$drift" ]; then
            echo "impacted-suites: --runner-check: runner drift — ${drift}: ${line}" >&2
            missing=1
        fi
    done < <(grep -vE '^[[:space:]]*#' "$ci" | grep -E 'run:.*(node --test|bun test|npm test|npx vitest|bunx vitest|vitest run|check-hook-lib-suites\.sh)')
    [ "$missing" -eq 0 ]
}

# pkg_dir_for <suite_path> — the nearest ancestor directory (repo-relative,
# walking from the suite's own directory up to the repo root) that owns a
# package.json. Prints it and returns 0; returns 1 with no output when the
# suite has no package.json ancestor (a suite with no npm/bun deps at all).
pkg_dir_for() {
    local dir parent
    dir=$(dirname -- "$1")
    while :; do
        if [ -f "$dir/package.json" ]; then
            printf '%s\n' "$dir"
            return 0
        fi
        [ "$dir" = "." ] && return 1
        parent=$(dirname -- "$dir")
        [ "$parent" = "$dir" ] && return 1
        dir="$parent"
    done
}

# install_cmd_for <pkg_dir> — the ONE offline-first, frozen-lockfile install
# command for a package dir, chosen by the lockfile it commits
# (package-lock.json -> npm ci; bun.lock/bun.lockb -> bun install
# --frozen-lockfile). --ignore-scripts on both: a dependency's own postinstall
# reaching the network (a Playwright browser download — HIMMEL-3553 N446) must
# never block or slow a test-dep install; nothing this table maps needs its
# own postinstall to run to be test-ready (HIMMEL-3553 investigation: every
# mapped package.json builds its TS via an explicit `pretest`/`build` script,
# never npm lifecycle). Exit 2, naming the dir, when NEITHER lockfile exists —
# a missing lockfile is a hard fail, never a guessed install (HIMMEL-3553).
install_cmd_for() {
    local dir="$1"
    if [ -f "$dir/package-lock.json" ]; then
        printf 'npm ci --no-audit --no-fund --ignore-scripts\n'
        return 0
    fi
    if [ -f "$dir/bun.lock" ] || [ -f "$dir/bun.lockb" ]; then
        printf 'bun install --frozen-lockfile --ignore-scripts\n'
        return 0
    fi
    echo "impacted-suites: no lockfile (package-lock.json or bun.lock) in '${dir}' — refusing to guess an install" >&2
    return 2
}

# ensure_deps <suite_path> — install a suite's owning package's deps when its
# node_modules is missing (HIMMEL-3553: a fresh worktree is created with
# --no-install, so every package but the jira CLI starts with none). No-op
# (exit 0, silent) for a suite with no package.json ancestor, or one whose
# node_modules already exists — "no change to suites that need no npm deps".
# Exit 2 on a missing lockfile or a failed install command: a loud, named
# failure carrying the package dir and the install command, never a SKIP and
# never a bare FAIL a leg could mislabel "pre-existing".
ensure_deps() {
    local suite="$1" dir cmd rc
    dir=$(pkg_dir_for "$suite") || return 0
    [ -d "$dir/node_modules" ] && return 0
    cmd=$(install_cmd_for "$dir") || { echo "impacted-suites: FAIL_INSTALL ${suite} — no lockfile in ${dir}" >&2; return 2; }
    echo "impacted-suites: installing deps for ${dir} (${cmd})" >&2
    rc=0
    (cd "$dir" && eval "$cmd") || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "impacted-suites: FAIL_INSTALL ${suite} — '${cmd}' failed in ${dir} (rc=${rc})" >&2
        return 2
    fi
    echo "impacted-suites: installed deps for ${dir}" >&2
    return 0
}

# run_suite <suite_path> — ensure_deps, then run the suite: its own CI runner
# command for a JS/TS path (via runner_for), or `bash <path>` for a
# test-*.sh. Propagates ensure_deps's exit 2 (never runs a suite whose deps
# failed to install) and otherwise the suite's own exit code.
run_suite() {
    local path="$1" cmd
    case "$path" in
        ./*) path="${path#./}" ;;
    esac
    ensure_deps "$path" || return 2
    case "$path" in
        *.test.mjs|*.test.js|*.test.ts)
            cmd=$(runner_for "$path") || return 2
            eval "$cmd"
            return $? ;;
        *)
            bash "$path"
            return $? ;;
    esac
}

check=0
shell_only=0
range=""
runner_path=""
runner_check_mode=0
run_path=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check) check=1; shift ;;
        --shell) shell_only=1; shift ;;
        --runner)
            [ "$#" -ge 2 ] || { echo "impacted-suites.sh: --runner requires a path" >&2; exit 2; }
            runner_path="$2"; shift 2 ;;
        --runner-check) runner_check_mode=1; shift ;;
        --run)
            [ "$#" -ge 2 ] || { echo "impacted-suites.sh: --run requires a path" >&2; exit 2; }
            run_path="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "impacted-suites.sh: unknown flag: $1" >&2; exit 2 ;;
        *)
            if [ -n "$range" ]; then
                echo "impacted-suites.sh: unexpected argument: $1" >&2; exit 2
            fi
            range="$1"; shift ;;
    esac
done

if [ -n "$runner_path" ]; then
    runner_for "$runner_path"
    exit $?
fi
if [ "$runner_check_mode" -eq 1 ]; then
    top=$(git rev-parse --show-toplevel) || { echo "impacted-suites.sh: not inside a git work tree" >&2; exit 2; }
    cd "$top" || exit 2
    if runner_check; then
        exit 0
    else
        exit 1
    fi
fi
if [ -n "$run_path" ]; then
    top=$(git rev-parse --show-toplevel) || { echo "impacted-suites.sh: not inside a git work tree" >&2; exit 2; }
    cd "$top" || exit 2
    run_suite "$run_path"
    exit $?
fi

case "$range" in
    *..*) ;;
    *) echo "impacted-suites.sh: expected <base>..<head>, got '${range}'" >&2; exit 2 ;;
esac
base="${range%%..*}"
head="${range#*..}"
head="${head#.}"   # tolerate <base>...<head>
if [ -z "$base" ] || [ -z "$head" ]; then
    echo "impacted-suites.sh: expected <base>..<head>, got '${range}'" >&2; exit 2
fi

# git ls-tree and git grep are scoped to the cwd while git diff emits
# repo-relative paths: from a subdirectory the suites above it would drop out.
if ! top=$(git rev-parse --show-toplevel) || ! cd "$top"; then
    echo "impacted-suites.sh: not inside a git work tree" >&2; exit 2
fi

if ! base_sha=$(git rev-parse --verify --quiet --end-of-options "${base}^{commit}"); then
    echo "impacted-suites.sh: base '${base}' does not resolve to a commit" >&2; exit 2
fi
if ! head_sha=$(git rev-parse --verify --quiet --end-of-options "${head}^{commit}"); then
    echo "impacted-suites.sh: head '${head}' does not resolve to a commit" >&2; exit 2
fi
if ! mb=$(git merge-base "$base_sha" "$head_sha"); then
    echo "impacted-suites.sh: no merge-base between '${base}' and '${head}'" >&2; exit 2
fi
if ! changed=$(git -c core.quotepath=off diff --name-only --no-renames "$mb" "$head_sha"); then
    echo "impacted-suites.sh: git diff ${mb}..${head_sha} failed" >&2; exit 2
fi
if ! tree=$(git -c core.quotepath=off ls-tree -r --name-only "$head_sha"); then
    echo "impacted-suites.sh: git ls-tree ${head_sha} failed" >&2; exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/impacted-suites.XXXXXX") || { echo "impacted-suites.sh: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$work"' EXIT
pats="$work/patterns"
found="$work/found"
: > "$pats"
: > "$found"

suite_re='(^|/)test-[^/]*\.sh$|\.test\.(mjs|js|ts)$'
suites=$(grep -E "$suite_re" <<< "$tree"); [ $? -le 1 ] || io_fail "listing suites"   # rc 1 = none
# Basenames that name nothing on their own: match them by "<parent>/<name>"
# (a repo-root file has no parent, so it falls back to the bare name).
generic_re='^(README\.md|CLAUDE\.md|SKILL\.md|CHANGELOG\.md|index\.(js|mjs|ts)|package\.json|package-lock\.json|\.gitignore|LICENSE)$'

# add_needle <literal> — one ERE per needle: a literal bounded so `install.sh`
# never matches `uninstall.sh` and `/pr-check` never matches `/pr-check_x`.
add_needle() {
    local esc
    esc=$(printf '%s' "$1" | sed 's/[.[\*^$+?(){}|]/\\&/g') || io_fail "escaping a needle"
    printf '(^|[^A-Za-z0-9_.-])%s($|[^A-Za-z0-9_-])\n' "$esc" >> "$pats" || io_fail "writing a needle"
}

while IFS= read -r f; do
    [ -n "$f" ] || continue
    if grep -Eq "$suite_re" <<< "$f"; then
        # A changed suite is impacted by itself (unless the PR deleted it) —
        # and falls through so its basename is also a needle: a wrapper that
        # invokes it (test-arm-resume-fast.sh -> test-arm-resume.sh) is reached.
        if grep -Fxq -- "$f" <<< "$suites"; then printf '%s\n' "$f" >> "$found" || io_fail "recording a changed suite"; fi
    fi
    name="${f##*/}"
    if grep -Eq "$generic_re" <<< "$name"; then
        case "$f" in
            */*) parent="${f%/*}"; add_needle "${parent##*/}/$name" ;;
            # Repo root: no parent to qualify it, so the bare name is the only
            # needle — it also matches sub-directory copies (over-approximates).
            *) add_needle "$name" ;;
        esac
    else
        add_needle "$name"
    fi
    case "$f" in
        .claude/commands/*.md|marketplace/plugins/*/commands/*.md)
            add_needle "/${name%.md}" ;;
        */skills/*/SKILL.md)
            skill="${f%/SKILL.md}"; add_needle "/${skill##*/}" ;;
    esac
done <<< "$changed"

if [ -s "$pats" ]; then
    # git grep on the resolved <head> tree, not the working tree: the answer is
    # about the PR as pushed. -l prefixes each path with "<head_sha>:".
    # rc 1 is "no match"; anything higher is a search that did not run, which
    # must not read as an empty impacted set.
    grep_rc=0
    # core.quotepath=off like the diff and ls-tree above: a non-ASCII suite path
    # must come back as itself, not as a quoted "\303\251" the runner cannot open.
    git -c core.quotepath=off grep -l -E -f "$pats" "$head_sha" -- \
        ':(glob)**/test-*.sh' ':(glob)**/*.test.mjs' ':(glob)**/*.test.js' ':(glob)**/*.test.ts' \
        > "$work/grep.out" || grep_rc=$?
    if [ "$grep_rc" -gt 1 ]; then
        echo "impacted-suites: git grep failed (rc=$grep_rc) — cannot tell which suites are impacted" >&2
        exit 2
    fi
    sed "s/^${head_sha}://" "$work/grep.out" >> "$found" || io_fail "reading the search result"
fi

impacted="$work/impacted"
if [ "$shell_only" -eq 1 ]; then
    grep_rc=0
    grep -E '(^|/)test-[^/]*\.sh$' "$found" > "$work/shell" || grep_rc=$?   # rc 1 = no shell suite
    [ "$grep_rc" -le 1 ] || io_fail "filtering to shell suites"
    sort -u "$work/shell" > "$impacted" || io_fail "sorting the impacted list"
else
    sort -u "$found" > "$impacted" || io_fail "sorting the impacted list"
fi

if [ "$check" -eq 0 ]; then
    cat "$impacted"
    exit 0
fi

# --check: every impacted suite needs a valid verdict line on stdin.
have="$work/have"
blocked_raw="$work/blocked.raw"
: > "$blocked_raw"
awk -v blockedf="$blocked_raw" '
    # The path is everything between "SUITE " and the FIRST " = " (a suite path
    # may contain spaces); the verdict word and reason rules follow it.
    /^SUITE +/ {
        i = index($0, " = ")
        if (i == 0) next
        path = substr($0, 1, i - 1)
        sub(/^SUITE +/, "", path)
        sub(/ +$/, "", path)
        rest = substr($0, i + 3)
        sub(/^ +/, "", rest)
        if (path == "" || rest !~ /^(PASS|SKIP|BLOCKED)( +.*)?$/) next
        verdict = rest
        sub(/[ ].*$/, "", verdict)
        reason = rest
        sub(/^(PASS|SKIP|BLOCKED) */, "", reason)
        if (verdict == "PASS" || reason ~ /[^ \t\r]/) {
            print path
            if (verdict == "BLOCKED") print path > blockedf
        }
    }
' | sort -u > "$have" || io_fail "reading the verdicts"
missing="$work/missing"
comm -23 "$impacted" "$have" > "$missing" || io_fail "comparing verdicts to the impacted list"
n_impacted=$(wc -l < "$impacted" | tr -d ' ')
n_missing=$(wc -l < "$missing" | tr -d ' ')
printf 'impacted-suites: %s impacted, %s without a verdict\n' "$n_impacted" "$n_missing"
if [ "$n_missing" -gt 0 ]; then
    while IFS= read -r s; do
        printf 'impacted-suites: MISSING VERDICT %s\n' "$s" >&2
    done < "$missing"
    exit 1
fi
# Every suite has a verdict; a BLOCKED one is accounted for but did not run.
blocked="$work/blocked"
sort -u "$blocked_raw" | comm -12 "$impacted" - > "$blocked" || io_fail "finding BLOCKED verdicts"
if [ -s "$blocked" ]; then
    printf 'impacted-suites: %s BLOCKED (accounted for, NOT clean — the suite did not run)\n' "$(wc -l < "$blocked" | tr -d ' ')" >&2
    while IFS= read -r s; do
        printf 'impacted-suites: BLOCKED %s\n' "$s" >&2
    done < "$blocked"
    exit 3
fi
exit 0
