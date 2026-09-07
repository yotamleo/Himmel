#!/usr/bin/env bash
# Pre-commit hook: enforce lockfile integrity (npm + bun).
#
# For every package.json under scripts/ (same scoping as check-npm-audit.sh):
#   1. A sibling package-lock.json (npm) or bun.lock (bun) must exist.
#   2. That lockfile must be tracked in git.
#   3. Package manager ci/install verification succeeds (catches lock drift).
#
# Blocks the commit on any failure. See docs/security/npm-policy.md.
set -euo pipefail

# Scoped to scripts/ so we don't recurse into nested worktrees under .claude/.
# bash 3.2-safe (macOS): no mapfile.
pkgs=()
while IFS= read -r _line; do pkgs+=("$_line"); done < <(find scripts -maxdepth 3 -name package.json -not -path '*/node_modules/*')

if [ ${#pkgs[@]} -eq 0 ]; then
    echo "→ lockfile-integrity: no npm/bun projects under scripts/, skipping"
    exit 0
fi

# Resolve bun without trusting PATH alone (HIMMEL-2439). bun's installer exports
# ~/.bun/bin from ~/.bashrc, and Debian/Ubuntu's stock ~/.bashrc opens with
# `case $- in *i*) ;; *) return;; esac` — it early-returns for every
# non-interactive shell. A hook inherits the environment of the git process that
# invoked it rather than building a fresh PATH, so a commit driven from an SSH
# command, a script, CI or an agent (himmel's normal case) never sees that
# layer, while the operator's own terminal does. Look in the installer's known
# locations before giving up. See docs/internals/environment-gotchas.md
# § "Linux: a stock Ubuntu user has TWO PATH layers".
BUN_LOOKED_IN="PATH, \$BUN_INSTALL/bin, \$HOME/.bun/bin"
BUN_BIN=""
BUN_VERSION=""

# A candidate counts as bun only if it actually reports a version: a binary that
# answers `--version` with nothing is unusable, and falling through to the next
# candidate beats stopping at it.
resolve_bun() {
    local cand ver
    for cand in "$(command -v bun 2>/dev/null || true)" \
                "${BUN_INSTALL:+$BUN_INSTALL/bin/bun}" \
                "${HOME:+$HOME/.bun/bin/bun}"; do
        [ -n "$cand" ] || continue
        [ -x "$cand" ] || continue
        ver="$("$cand" --version 2>/dev/null | head -1 | tr -d '\r' || true)"
        if [ -n "$ver" ]; then
            # `command -v` returns a path built from the matching PATH entry,
            # so a RELATIVE PATH entry yields a relative $cand. The check
            # below later runs BUN_BIN after `cd "$dir"` — a relative path
            # would then resolve against the wrong directory. Normalize
            # before storing. No `realpath`: macOS ships bash 3.2 without it.
            BUN_BIN="$(cd "$(dirname "$cand")" && pwd)/$(basename "$cand")"
            BUN_VERSION="$ver"
            return 0
        fi
    done
    return 1
}

# Does this commit stage anything under $1? A bun we could not find only has to
# block the commits it could actually be wrong about — a docs-only commit is not
# one of them. Scoped to the package directory rather than to `bun.lock*` alone:
# editing package.json without the lockfile is exactly the drift
# `--frozen-lockfile` exists to catch.
#
# Three-state, not boolean: an unreadable git index is not evidence the commit
# is safe to skip, so it must not collapse into "nothing staged".
# rc 0 = something is staged under $1
# rc 1 = nothing is staged under $1
# rc 2 = git could not say (fail-closed at the call site: an unreadable index
#        is not evidence that the commit is safe to skip). $STAGED_UNDER_ERR
#        holds git's own error text in this case.
staged_under() {
    local out
    STAGED_UNDER_ERR=""
    out=$(git diff --cached --name-only -- "$1" 2>&1) || { STAGED_UNDER_ERR="$out"; return 2; }
    [ -n "$out" ]
}

# Is anything staged AT ALL, anywhere — not just under one package? The skip
# above is only meaningful for an actual pre-commit run: `.github/workflows/
# ci.yml` invokes this hook directly against a clean index (today that step
# runs after `oven-sh/setup-bun@v2`, so bun IS on PATH there and this branch
# isn't currently reached in CI — this guard is about staying fail-closed if
# that setup step ever breaks or is removed). A clean index makes
# staged_under return 1 for every package, which must not be read as "this
# commit stages nothing under $dir, skip it" — that would silently skip every
# bun package outside a real commit. Same three-state discipline as
# staged_under: rc 0 = something is staged somewhere, rc 1 = nothing is
# staged anywhere, rc 2 = git could not say (fail-closed at the call site,
# same as staged_under's rc-2 path).
anything_staged() {
    local out
    STAGED_UNDER_ERR=""
    out=$(git diff --cached --name-only 2>&1) || { STAGED_UNDER_ERR="$out"; return 2; }
    [ -n "$out" ]
}

# Release bun only (HIMMEL-2010). A canary bun fails
# `bun install --frozen-lockfile` on a lockfile that is in fact clean, and this
# gate then blamed "bun.lock out of sync" — a misleading error that blocked
# every commit on the box while the lockfile was fine. Refuse the runtime with
# the actual fix instead. Same rule as scripts/lib/runtime-preflight.sh's bun
# policy; there it is an advisory scan, here it is the gate the canary breaks.
#
# `bun --version` is the probe: a release build prints a bare
# `<major>.<minor>.<patch>`, so a prerelease (`-canary.N`) or build-metadata
# (`+<hash>`) suffix is the refusal set. NOT `bun --revision`, which appends
# `+<hash>` to release builds too and would refuse every bun there is.
bun_is_release() {
    case "$BUN_VERSION" in
        *canary*|*CANARY*|*-*|*+*)
            echo "ERROR: bun $BUN_VERSION ($BUN_BIN) is not a release build" >&2
            echo "       install a stable bun release: https://bun.sh/docs/installation" >&2
            echo "       (winget Oven-sh.Bun on Windows) — canary bun breaks the lockfile gate" >&2
            return 1 ;;
    esac
    return 0
}

bun_ok=0
if resolve_bun; then bun_ok=1; fi

fail=0
for pkg in "${pkgs[@]}"; do
    dir=$(dirname "$pkg")

    # Determine lockfile type (bun.lock takes precedence). Warn if both are
    # present so a stray package-lock.json during an npm→bun migration can't
    # silently drop npm validation without anyone noticing.
    if [ -f "$dir/bun.lock" ]; then
        lock="$dir/bun.lock"
        pm="bun"
        if [ -f "$dir/package-lock.json" ]; then
            echo "→ lockfile-integrity: WARNING: both bun.lock and package-lock.json in $dir — using bun.lock" >&2
        fi
    else
        lock="$dir/package-lock.json"
        pm="npm"
    fi

    if [ ! -f "$lock" ]; then
        echo "ERROR: missing lockfile: $lock" >&2
        echo "       Every package.json must ship a committed sibling package-lock.json (npm) or bun.lock (bun)." >&2
        fail=1
        continue
    fi

    if ! git ls-files --error-unmatch "$lock" >/dev/null 2>&1; then
        echo "ERROR: lockfile not tracked in git: $lock" >&2
        echo "       Run: git add $lock" >&2
        fail=1
        continue
    fi

    if [ "$pm" = "npm" ]; then
        echo "→ lockfile-integrity: npm ci --dry-run in $dir"
        if ! (cd "$dir" && npm ci --dry-run --ignore-scripts); then
            echo "ERROR: lockfile drift detected in $dir" >&2
            echo "       package-lock.json is out of sync with package.json." >&2
            echo "       Run 'npm install' in $dir, then commit the updated lockfile." >&2
            fail=1
        fi
    else
        # bun: --frozen-lockfile errors if the lockfile is out of sync with
        # package.json; --dry-run resolves without installing. This is the bun
        # analogue of `npm ci --dry-run` — same drift-detection guarantee.
        if [ "$bun_ok" -eq 0 ]; then
            msg="no usable bun found — looked in: $BUN_LOOKED_IN"
            staged_rc=0
            staged_under "$dir" || staged_rc=$?
            if [ "$staged_rc" -eq 2 ]; then
                echo "ERROR: $msg" >&2
                echo "       git could not report what this commit stages under $dir, so $lock cannot" >&2
                echo "       be verified — and that also means the skip below cannot be justified." >&2
                echo "       Refusing fail-closed rather than treating an unreadable index as evidence" >&2
                echo "       the commit is safe. git said: $STAGED_UNDER_ERR" >&2
                fail=1
            elif [ "$staged_rc" -eq 0 ]; then
                echo "ERROR: $msg" >&2
                echo "       This commit stages changes under $dir, so $lock cannot be verified without it." >&2
                echo "       bun's installer exports ~/.bun/bin from ~/.bashrc, which non-interactive" >&2
                echo "       shells (hooks, SSH, CI, agents) never source. Put bun on a layer they do see:" >&2
                echo "         ln -sf ~/.bun/bin/bun ~/.local/bin/bun   # ~/.profile exports ~/.local/bin" >&2
                echo "       or export BUN_INSTALL=\"\$HOME/.bun\" in the context that runs git." >&2
                echo "       On Windows: install stable bun (winget Oven-sh.Bun)." >&2
                fail=1
            else
                # staged_rc == 1: nothing staged under $dir. That alone does
                # not license the skip — an empty index overall means this
                # isn't a pre-commit run at all (see anything_staged above).
                anything_rc=0
                anything_staged || anything_rc=$?
                if [ "$anything_rc" -eq 2 ]; then
                    echo "ERROR: $msg" >&2
                    echo "       git could not report whether this commit stages anything at all, so" >&2
                    echo "       whether this is even a pre-commit run cannot be determined either." >&2
                    echo "       Refusing fail-closed rather than treating an unreadable index as" >&2
                    echo "       evidence the commit is safe. git said: $STAGED_UNDER_ERR" >&2
                    fail=1
                elif [ "$anything_rc" -eq 0 ]; then
                    echo "→ lockfile-integrity: skipping $dir — $msg (this commit stages nothing under $dir)"
                else
                    echo "ERROR: $msg" >&2
                    echo "       The git index is empty, so this is not a pre-commit run (CI, a manual" >&2
                    echo "       invocation, or \`pre-commit run --all-files\`) — refusing to skip a check" >&2
                    echo "       it cannot perform for $lock." >&2
                    fail=1
                fi
            fi
            continue
        fi
        if ! bun_is_release; then fail=1; continue; fi
        echo "→ lockfile-integrity: bun install --frozen-lockfile --dry-run in $dir ($BUN_BIN $BUN_VERSION)"
        if ! (cd "$dir" && "$BUN_BIN" install --frozen-lockfile --dry-run); then
            echo "ERROR: lockfile drift detected in $dir" >&2
            echo "       bun.lock is out of sync with package.json." >&2
            echo "       Run 'bun install' in $dir, then commit the updated bun.lock." >&2
            fail=1
        fi
    fi
done

if [ $fail -ne 0 ]; then
    echo "" >&2
    echo "ERROR: lockfile-integrity check failed. Commit blocked." >&2
fi

exit $fail
