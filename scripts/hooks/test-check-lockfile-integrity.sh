#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-lockfile-integrity.sh.
#
# Scope: the bun RUNTIME guard (HIMMEL-2010) and bun RESOLUTION (HIMMEL-2439).
#
# Resolution: bun's installer exports ~/.bun/bin from ~/.bashrc, which
# non-interactive shells never source — so a hook, an SSH command, CI or an
# agent sees no bun on a box where the operator's own terminal does, and every
# commit (docs-only included) was blocked. The gate must find bun in the
# installer's known locations, and when it genuinely cannot, block only the
# commits that stage something the lockfile check could be wrong about.
#
# Runtime guard: a canary bun fails
# `bun install --frozen-lockfile` on a lockfile that is in fact clean, and the
# gate used to blame "bun.lock out of sync" — a misleading error that blocked
# every commit on the box while the lockfile was fine. The guard must refuse the
# runtime first, and say how to fix it.
#
# Hermetic: a throwaway git repo holding ONE bun package (no npm package, so
# `npm ci` never runs) plus a stub `bun` first on PATH, so nothing installs and
# nothing touches the network.
#
# Usage: bash scripts/hooks/test-check-lockfile-integrity.sh
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline (a here-string is not a pipeline, so `set -o pipefail` cannot report
# a SUCCESSFUL early match as a failed producer). HIMMEL-1430.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GATE="$SCRIPT_DIR/check-lockfile-integrity.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/fixture-tempdir.sh"

# Resolve bash ONCE from the suite's own unmodified PATH, before any test
# hands the gate a narrowed one (HIMMEL-2520, shape from HIMMEL-2470/
# HIMMEL-1567). Every no-bun invocation below runs the gate via this absolute
# path so the narrowed PATH decides what the GATE sees, never whether it can
# start at all.
BASH_ABS=$(command -v bash)
if [ -z "$BASH_ABS" ]; then
    echo "FATAL: cannot resolve bash on PATH" >&2
    exit 1
fi
# Refusing a relative PATH is deliberate: these are hermetic fixtures.
# A bash resolved through a relative PATH means the invoking environment
# is already broken in a way that makes any result untrustworthy
# (HIMMEL-2520, CR [codex-1]).
case "$BASH_ABS" in
    /*) ;;
    *) echo "FATAL: bash resolved to a non-absolute path ('$BASH_ABS') — this fixture invokes it after a cd and/or as a shim shebang, both of which need an absolute path" >&2; exit 1 ;;
esac

FAILED=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label"
        echo "     expected: $expected"
        echo "     actual:   $actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_says() {
    local label="$1" needle="$2" text="$3"
    if grepq "$text" -- "$needle"; then
        echo "PASS $label"
    else
        echo "FAIL $label"
        echo "     output: $text"
        FAILED=$((FAILED + 1))
    fi
}

# One tracked bun package under scripts/ — the gate's own discovery scope.
make_bun_repo() {
    local dir
    dir=$(fixture_mktemp_dir) || return 1
    (
        fixture_enter_git_init_dir "$dir" || exit 1
        git init -q -b main
        git config user.email t@t
        git config user.name t
        mkdir -p scripts/vitals
        echo '{"name":"vitals"}' > scripts/vitals/package.json
        echo '# lockfile' > scripts/vitals/bun.lock
        echo '# docs' > README.md
        git add -A
        git -c commit.gpgsign=false commit -q -m "init"
    ) || { rm -rf "$dir"; return 1; }
    echo "$dir"
}

# A `bun` that answers --version from $BUN_STUB_VERSION (empty = says nothing,
# the not-installed/unreadable case) and succeeds on `bun install`, so a
# release-shaped version reaches the normal path without installing anything.
make_bun_stub() {
    local dir
    dir=$(fixture_mktemp_dir) || return 1
    cat > "$dir/bun" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    --version)
        [ -n "${BUN_STUB_VERSION:-}" ] && printf '%s\n' "$BUN_STUB_VERSION"
        exit 0 ;;
esac
exit 0
STUB
    chmod +x "$dir/bun"
    echo "$dir"
}

# A HOME with no ~/.bun — so a real bun in the operator's home can never make a
# "bun is missing" case pass by accident.
make_empty_home() { fixture_mktemp_dir; }

# A HOME whose ~/.bun/bin/bun is a stub reporting $1 — the exact shape bun's
# official installer leaves behind, on the layer ~/.bashrc (not ~/.profile)
# exports.
make_bun_home() {
    local dir
    dir=$(fixture_mktemp_dir) || return 1
    mkdir -p "$dir/.bun/bin"
    cat > "$dir/.bun/bin/bun" <<STUB
#!/usr/bin/env bash
case "\$1" in
    --version) printf '%s\n' "$1"; exit 0 ;;
esac
exit 0
STUB
    chmod +x "$dir/.bun/bin/bun"
    echo "$dir"
}

# A $BUN_INSTALL-shaped dir whose ~/.bun/bin/bun is a stub reporting $1 — the
# layout bun's installer sets $BUN_INSTALL to (<dir>/bin/bun), which differs
# from make_bun_home's $HOME-shaped <dir>/.bun/bin/bun.
make_bun_install_dir() {
    local dir
    dir=$(fixture_mktemp_dir) || return 1
    mkdir -p "$dir/bin"
    cat > "$dir/bin/bun" <<STUB
#!/usr/bin/env bash
case "\$1" in
    --version) printf '%s\n' "$1"; exit 0 ;;
esac
exit 0
STUB
    chmod +x "$dir/bin/bun"
    echo "$dir"
}

# A curated allowlist PATH -- a scratch dir holding ONLY forwarding shims for
# the tools the gate needs when it cannot find a usable bun (find, git,
# dirname, basename, head, tr), plus bash itself -- several of this suite's
# own fixtures (make_bun_home, make_bun_install_dir, make_relpath_bun,
# make_stub_git) are `#!/usr/bin/env bash` scripts, and `env` resolves that
# "bash" argument through ITS OWN inherited PATH (the allowlist), not the
# suite's -- each resolved from THIS host's live PATH, and NO bun/bunx
# anywhere in it (HIMMEL-2520, shape from HIMMEL-2470).
#
# A directory-stripping approach (the prior version of this fixture, kept as
# path_without_bun's comment history) breaks on any host where bun shares a
# directory with the rest of the toolchain -- on this Arch/CachyOS station bun
# and bunx sit in /usr/bin alongside bash, git, find and coreutils, so
# stripping bun's directory silently guts every tool the gate needs before it
# even reaches the bun check. HIMMEL-2160's insight (a machine can have more
# than one bun install on PATH, so a single `command -v` strip is not enough)
# is still true, but an allowlist makes it moot: bun/bunx are simply never
# placed in it, no matter how many real installs exist elsewhere on the host.
#
# Shims are wrapper scripts (`exec "$real" "$@"`), not symlinks/copies --
# MSYS/Cygwin binaries resolve sibling runtime DLLs relative to argv0's
# invocation path, so a relocated copy fails to load on Git-Bash even though
# the real binary works fine; a wrapper relocates nothing and behaves
# identically on Linux/macOS/Windows.
make_no_bun_path() {
    local dir tool tpath
    dir=$(fixture_mktemp_dir) || return 1
    for tool in find git dirname basename head tr bash; do
        tpath=$(command -v "$tool" 2>/dev/null) || { echo "COULD NOT RESOLVE $tool ON PATH" >&2; return 1; }
        printf '#!%s\nexec "%s" "$@"\n' "$BASH_ABS" "$tpath" > "$dir/$tool"
        chmod +x "$dir/$tool"
    done
    echo "$dir"
}

# A `git` that fails only `diff` (simulating an unreadable index) and delegates
# everything else to the real git. Resolved ONCE at fixture-build time so the
# stub bakes in an absolute path rather than calling `git` (which would find
# itself first on PATH and recurse forever).
make_stub_git() {
    local dir real_git
    dir=$(fixture_mktemp_dir) || return 1
    real_git=$(command -v git) || return 1
    cat > "$dir/git" <<STUBGIT
#!/usr/bin/env bash
if [ "\$1" = "diff" ]; then
    echo "fatal: simulated unreadable index" >&2
    exit 128
fi
exec "$real_git" "\$@"
STUBGIT
    chmod +x "$dir/git"
    echo "$dir"
}

# A bun reachable ONLY through a RELATIVE PATH entry, planted inside $REPO
# itself (outside scripts/, so the gate's own package scan never sees it).
# `command -v` resolves a relative PATH entry into a relative path (e.g.
# "relbin/bun"); the gate later `cd`s into the package directory before
# running $BUN_BIN, so an un-normalized relative BUN_BIN then resolves
# against the WRONG directory. $1 = version to report.
make_relpath_bun() {
    mkdir -p "$REPO/relbin"
    cat > "$REPO/relbin/bun" <<STUB
#!/usr/bin/env bash
case "\$1" in
    --version) printf '%s\n' "$1"; exit 0 ;;
esac
exit 0
STUB
    chmod +x "$REPO/relbin/bun"
}

REPO=$(make_bun_repo) || exit 1
STUB=$(make_bun_stub) || exit 1
EMPTY_HOME=$(make_empty_home) || exit 1
BUN_HOME=$(make_bun_home "1.4.0") || exit 1
BUN_INSTALL_DIR=$(make_bun_install_dir "1.4.0") || exit 1
NO_BUN_PATH=$(make_no_bun_path) || exit 1
STUBGIT=$(make_stub_git) || exit 1
make_relpath_bun "1.4.0"
trap 'rm -rf "$REPO" "$STUB" "$EMPTY_HOME" "$BUN_HOME" "$BUN_INSTALL_DIR" "$STUBGIT" "$NO_BUN_PATH"' EXIT

# Positive control for the instrument: the allowlist PATH has no bun AND
# genuinely resolves every tool the gate needs before (and around) its bun
# check -- a "bun not found" verdict proves nothing if bun was never removed,
# and an over-narrow allowlist that silently dropped (say) `git` would make
# the gate fail for the wrong reason while looking identical to the case
# under test (HIMMEL-2520).
missing=""
for tool in find git dirname basename head tr bash; do
    PATH="$NO_BUN_PATH" command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if PATH="$NO_BUN_PATH" command -v bun >/dev/null 2>&1; then
    echo "FAIL fixture control: allowlist PATH still resolves bun"
    FAILED=$((FAILED + 1))
elif [ -n "$missing" ]; then
    echo "FAIL fixture control: allowlist PATH missing required tool(s):$missing"
    FAILED=$((FAILED + 1))
else
    echo "PASS fixture control: allowlist PATH resolves no bun and every required tool"
fi

# Stage a change under the bun package (and clear it again), so the
# stages-something-vs-stages-nothing branch is exercised both ways.
stage_lockfile() { ( cd "$REPO" && echo "# touched" >> scripts/vitals/bun.lock && git add scripts/vitals/bun.lock ); }
unstage_all()    { ( cd "$REPO" && git reset -q && git checkout -q -- scripts/vitals/bun.lock ); }

# Stage a change OUTSIDE the bun package — the real docs-only-commit shape
# case 7 exists to cover: something is staged, but nothing under scripts/vitals.
stage_docs_change()   { ( cd "$REPO" && echo "# touched" >> README.md && git add README.md ); }
unstage_docs_change() { ( cd "$REPO" && git reset -q && git checkout -q -- README.md ); }

run_gate() { # $1 = version the stub on PATH reports
    ( cd "$REPO" && PATH="$STUB:$PATH" HOME="$EMPTY_HOME" BUN_STUB_VERSION="$1" \
        env -u BUN_INSTALL bash "$GATE" 2>&1 )
}

# No bun on PATH at all; $1 (optional) = HOME to run under (default: bun-less).
#
# Invoked via $BASH_ABS directly rather than `env -u BUN_INSTALL bash` --
# `env` resolves the command name ("bash") using the PATH it was just handed,
# so a narrowed allowlist PATH would decide whether bash itself is findable,
# not just what the gate sees once running (HIMMEL-2520, shape from
# HIMMEL-1567). `unset` inside this subshell only affects the subshell.
run_gate_no_path_bun() {
    ( cd "$REPO" && unset BUN_INSTALL && PATH="$NO_BUN_PATH" HOME="${1:-$EMPTY_HOME}" \
        "$BASH_ABS" "$GATE" 2>&1 )
}

# Case 1: canary bun → refused, with the stable-bun fix, and NEVER the
# lock-drift error (the misleading message this guard exists to replace).
rc=0
out=$(run_gate "1.4.1-canary.20260101T140000") || rc=$?
assert_eq "canary bun → gate blocks (exit 1)" "1" "$rc"
assert_says "canary bun → names the stable-bun fix" \
    "install a stable bun release" "$out"
if grepq "$out" 'out of sync'; then
    echo "FAIL canary bun → does NOT blame lockfile drift"
    echo "     output: $out"
    FAILED=$((FAILED + 1))
else
    echo "PASS canary bun → does NOT blame lockfile drift"
fi

# Case 2: release bun → normal path, gate passes.
rc=0
out=$(run_gate "1.4.0") || rc=$?
assert_eq "release bun → gate passes (exit 0)" "0" "$rc"
assert_says "release bun → the frozen-lockfile check still runs" \
    "frozen-lockfile" "$out"

# Case 3: a `+<hash>` build-metadata version is not a release build either.
rc=0
out=$(run_gate "1.4.0+01c4e2fd6") || rc=$?
assert_eq "build-metadata bun → gate blocks (exit 1)" "1" "$rc"
assert_says "build-metadata bun → names the stable-bun fix" \
    "install a stable bun release" "$out"

# Case 4: a bun on PATH that answers --version with nothing is unusable. With a
# lockfile change staged it must still block — naming what it looked for, never
# a bogus drift error.
stage_lockfile
rc=0
out=$(run_gate "") || rc=$?
unstage_all
assert_eq "silent bun + staged lockfile → gate blocks (exit 1)" "1" "$rc"
assert_says "silent bun → names where it looked for bun" \
    "looked in: PATH" "$out"
if grepq "$out" 'out of sync'; then
    echo "FAIL silent bun → does NOT blame lockfile drift"
    echo "     output: $out"
    FAILED=$((FAILED + 1))
else
    echo "PASS silent bun → does NOT blame lockfile drift"
fi

# --- HIMMEL-2439: bun resolution off the PATH layer hooks cannot see ---------

# Case 5: bun absent from PATH but present at $HOME/.bun/bin (where the official
# installer puts it) → the gate resolves it and runs the real check. This is the
# fix: pre-HIMMEL-2439 this same fixture died with "bun did not report a
# version" and blocked the commit.
rc=0
out=$(run_gate_no_path_bun "$BUN_HOME") || rc=$?
assert_eq "bun only in \$HOME/.bun/bin → gate passes (exit 0)" "0" "$rc"
assert_says "bun only in \$HOME/.bun/bin → the frozen-lockfile check still runs" \
    "frozen-lockfile" "$out"

# Case 6 (negative control): no bun anywhere AND a lockfile change staged → the
# gate must still FAIL. The skip in case 7 must not be a way to lose the check.
stage_lockfile
rc=0
out=$(run_gate_no_path_bun) || rc=$?
unstage_all
assert_eq "no bun + staged lockfile → gate blocks (exit 1)" "1" "$rc"
assert_says "no bun + staged lockfile → names every location it looked in" \
    "looked in: PATH, \$BUN_INSTALL/bin, \$HOME/.bun/bin" "$out"
assert_says "no bun + staged lockfile → names the ~/.local/bin remedy" \
    "ln -sf ~/.bun/bin/bun ~/.local/bin/bun" "$out"

# Case 7: no bun anywhere, and this is a real pre-commit run that stages a
# docs-only change OUTSIDE the bun package (the reported bug — a docs-only
# commit blocked by a bun the hook cannot see) → SKIP, with the same honest
# line about what was looked for.
stage_docs_change
rc=0
out=$(run_gate_no_path_bun) || rc=$?
unstage_docs_change
assert_eq "no bun + docs-only commit → gate passes (exit 0)" "0" "$rc"
assert_says "no bun + docs-only commit → says it skipped that package" \
    'skipping scripts/vitals' "$out"
assert_says "no bun + docs-only commit → still names every location it looked in" \
    "looked in: PATH, \$BUN_INSTALL/bin, \$HOME/.bun/bin" "$out"

# Case 7b (HIMMEL-2440): no bun anywhere and the index is ENTIRELY empty —
# the CI shape (.github/workflows/ci.yml invokes this hook directly, not via
# a commit) — must BLOCK, not silently skip every bun package. An empty index
# is not evidence of a pre-commit run.
rc=0
out=$(run_gate_no_path_bun) || rc=$?
assert_eq "no bun + empty index → gate blocks (exit 1)" "1" "$rc"
assert_says "no bun + empty index → says the index is empty / not a pre-commit run" \
    "index is empty, so this is not a pre-commit run" "$out"
assert_says "no bun + empty index → still names every location it looked in" \
    "looked in: PATH, \$BUN_INSTALL/bin, \$HOME/.bun/bin" "$out"

# Case 8: bun absent from PATH and $HOME/.bun/bin, but $BUN_INSTALL points at
# it (the middle branch of the HIMMEL-2439 resolution chain — cases 5 and 6/7
# cover the PATH and $HOME/.bun/bin branches, but every runner above passes
# `env -u BUN_INSTALL`, so this one was never exercised) → the gate resolves it
# and runs the real check.
rc=0
out=$(cd "$REPO" && PATH="$NO_BUN_PATH" HOME="$EMPTY_HOME" \
    BUN_INSTALL="$BUN_INSTALL_DIR" "$BASH_ABS" "$GATE" 2>&1) || rc=$?
assert_eq "bun only via \$BUN_INSTALL/bin → gate passes (exit 0)" "0" "$rc"
assert_says "bun only via \$BUN_INSTALL/bin → the frozen-lockfile check still runs" \
    "frozen-lockfile" "$out"

# --- HIMMEL-2440: staged_under must fail-closed when git can't say ---------

# Case 9: `git diff` fails (simulated unreadable index), no bun resolvable
# anywhere, nothing staged → the gate must still BLOCK. An index git cannot
# read is not evidence the commit is safe to skip (the fail-open case 7's
# skip must never become) — it must fail closed and name why.
rc=0
out=$(cd "$REPO" && unset BUN_INSTALL && PATH="$STUBGIT:$NO_BUN_PATH" HOME="$EMPTY_HOME" \
    "$BASH_ABS" "$GATE" 2>&1) || rc=$?
assert_eq "unreadable index → gate blocks (exit 1), fail-closed not skip" "1" "$rc"
assert_says "unreadable index → names the unreadable-index reason" \
    "simulated unreadable index" "$out"
assert_says "unreadable index → says the skip cannot be justified" \
    "cannot be justified" "$out"

# --- HIMMEL-2439 fix 2: resolve_bun must store an ABSOLUTE BUN_BIN ---------

# Case 10: bun resolvable ONLY through a RELATIVE PATH entry. The gate later
# runs $BUN_BIN after `cd`-ing into the package directory — an un-normalized
# relative BUN_BIN would resolve against the wrong directory there and fail.
rc=0
out=$(cd "$REPO" && unset BUN_INSTALL && PATH="relbin:$NO_BUN_PATH" HOME="$EMPTY_HOME" \
    "$BASH_ABS" "$GATE" 2>&1) || rc=$?
assert_eq "bun via relative PATH entry → gate passes (exit 0)" "0" "$rc"
assert_says "bun via relative PATH entry → the frozen-lockfile check still runs" \
    "frozen-lockfile" "$out"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED case(s) FAILED"
exit 1
