#!/usr/bin/env bash
# shellcheck disable=SC2016  # fixture suite bodies are single-quoted on purpose: their $vars must stay literal
# Hermetic test for scripts/cr/impacted-suites.sh (HIMMEL-2821). Builds a
# throwaway repo shaped like PR #2261: a changed script (uninstall-plugins.sh)
# whose end-to-end suite (test-uninstall.sh) lives one directory UP and that
# neither a directory sweep nor "the owning suites" prose would have reached.
#
# Platform guard: POSIX bash 3.2+; runs under Git Bash on Windows too.
#
# Usage: bash scripts/cr/test-impacted-suites.sh
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# grepq <text> [grep-args...] — `grep -q` with no pipeline (pipefail SIGPIPE
# trap, HIMMEL-1430).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
IS="$REPO_ROOT/scripts/cr/impacted-suites.sh"
# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/fixture-tempdir.sh"
failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

if [ ! -f "$IS" ]; then
    fail "impacted-suites.sh not found at $IS"
    echo "FAIL: $failures case(s) failed"
    exit 1
fi

FX="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX"' EXIT

# --- fixture repo ---------------------------------------------------------
mkf() { mkdir -p "$FX/$(dirname "$1")"; printf '%s\n' "${2:-# $1}" > "$FX/$1"; }
(
    fixture_enter_git_init_dir "$FX" || exit 1
    git init -q
    git config user.email t@e
    git config user.name t
)
mkf scripts/machine-setup/uninstall-plugins.sh
mkf scripts/machine-setup/install.sh
mkf scripts/uninstall.sh
mkf scripts/test-uninstall.sh 'bash "$d/machine-setup/uninstall-plugins.sh"; bash "$d/uninstall.sh"'
mkf scripts/test-other.sh 'bash "$d/uninstall.sh"'
mkf scripts/test-wrapper.sh 'bash "$d/test-other.sh"'
mkf scripts/test-installer.sh 'bash "$d/machine-setup/install.sh"'
mkf scripts/lanes/tests/plugins.test.mjs "// drives uninstall-plugins.sh"
mkf .claude/commands/pr-check.md
mkf scripts/test-cmd.sh 'grep -q "/pr-check" x'
mkf scripts/test-clean-cmd.sh 'grep -q "/pr-check_extra" x'
mkf docs/foo/README.md
mkf scripts/test-readme-foo.sh 'grep -q foo/README.md x'
mkf scripts/test-readme-bare.sh 'grep -q README.md x'
mkf package.json '{}'
mkf scripts/test-pkg.sh 'grep -q "$root/package.json" x'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: base"

# change <file> — append a line to <file>, commit, set $range to that commit.
change() {
    printf '# changed\n' >> "$FX/$1"
    git -C "$FX" add -A
    git -C "$FX" commit -q -m "fix: change $1"
    range="$(git -C "$FX" rev-parse HEAD~1)..$(git -C "$FX" rev-parse HEAD)"
}
run_is() { ( cd "$FX" && bash "$IS" "$@" 2>/dev/null ); }

# --- 1. the #2261 shape: the far-away end-to-end suite is listed -----------
change scripts/machine-setup/uninstall-plugins.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-uninstall\.sh$'; then pass "uninstall-plugins.sh -> scripts/test-uninstall.sh (one dir up)"; else fail "test-uninstall.sh not listed: $out"; fi
if grepq "$out" '^scripts/lanes/tests/plugins\.test\.mjs$'; then pass ".test.mjs suite listed"; else fail "mjs suite not listed: $out"; fi
if ! grepq "$out" 'test-other\.sh'; then pass "suite naming only uninstall.sh is not listed"; else fail "test-other.sh listed for an uninstall-plugins.sh change: $out"; fi
out="$(run_is "$range" --shell)"
if ! grepq "$out" '\.mjs$' && grepq "$out" '^scripts/test-uninstall\.sh$'; then pass "--shell keeps only test-*.sh"; else fail "--shell output wrong: $out"; fi

# --- 2. word boundary: install.sh must not match uninstall.sh ---------------
change scripts/machine-setup/install.sh
out="$(run_is "$range")"
if [ "$out" = "scripts/test-installer.sh" ]; then pass "install.sh change lists only its own suite (not uninstall.sh mentions)"; else fail "install.sh boundary: $out"; fi

# --- 3. command form: /pr-check, and /pr-check_extra is a different word -----
change .claude/commands/pr-check.md
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-cmd\.sh$'; then pass "commands/pr-check.md -> suite naming /pr-check"; else fail "/pr-check suite not listed: $out"; fi
if ! grepq "$out" 'test-clean-cmd\.sh'; then pass "/pr-check_extra is not /pr-check"; else fail "boundary broke on /pr-check_extra: $out"; fi

# --- 4. generic basename (README.md) needs its parent dir --------------------
change docs/foo/README.md
out="$(run_is "$range")"
if [ "$out" = "scripts/test-readme-foo.sh" ]; then pass "README.md matched via foo/README.md, bare README.md mention ignored"; else fail "generic basename: $out"; fi

# --- 5. a changed suite lists itself ----------------------------------------
change scripts/test-other.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-other\.sh$'; then pass "a changed suite is impacted by itself"; else fail "changed suite not listed: $out"; fi
if grepq "$out" '^scripts/test-wrapper\.sh$'; then pass "a suite that invokes the changed suite is impacted too"; else fail "caller of the changed suite not listed: $out"; fi

# --- 6. a deleted file still lists the suites that reference it --------------
git -C "$FX" rm -q scripts/machine-setup/install.sh
git -C "$FX" commit -q -m "chore: drop install.sh"
range="$(git -C "$FX" rev-parse HEAD~1)..$(git -C "$FX" rev-parse HEAD)"
out="$(run_is "$range")"
if [ "$out" = "scripts/test-installer.sh" ]; then pass "deleted install.sh still lists test-installer.sh"; else fail "deleted file: $out"; fi

# --- 7. fail-closed on a range that does not resolve ------------------------
out="$( cd "$FX" && bash "$IS" 'nope..alsonope' 2>/dev/null )"; rc=$?
if [ "$rc" -eq 2 ] && [ -z "$out" ]; then pass "unresolvable range -> rc2, empty stdout"; else fail "bad range rc=$rc out=$out"; fi
( cd "$FX" && bash "$IS" 'HEAD' >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass "range without .. -> rc2"; else fail "no-dots range rc=$rc"; fi

# --- 8. --check: RED control for the ticket ----------------------------------
# The #2261 PR: uninstall-plugins.sh touched, test-uninstall.sh never run.
change scripts/machine-setup/uninstall-plugins.sh
( cd "$FX" && printf '' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "RED control: impacted suites with NO verdict -> row NOT clean (rc1)"; else fail "no-verdict fixture PR passed the row: rc=$rc"; fi
err="$( cd "$FX" && printf '' | bash "$IS" --check "$range" 2>&1 >/dev/null )"
if grepq "$err" 'scripts/test-uninstall\.sh'; then pass "the missing verdict names test-uninstall.sh"; else fail "missing suite not named: $err"; fi

V1='SUITE scripts/test-uninstall.sh = PASS'
V2='SUITE scripts/lanes/tests/plugins.test.mjs = SKIP no node on this host'
( cd "$FX" && printf '%s\n%s\n' "$V1" "$V2" | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 0 ]; then pass "PASS + SKIP-with-reason for every impacted suite -> clean (rc0)"; else fail "full verdict set refused: rc=$rc"; fi

( cd "$FX" && printf '%s\n%s\n' "$V1" 'SUITE scripts/lanes/tests/plugins.test.mjs = SKIP' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "SKIP without a reason is not a verdict (rc1)"; else fail "reasonless SKIP accepted: rc=$rc"; fi

err="$( cd "$FX" && printf '%s\n%s\n' "$V1" 'SUITE scripts/lanes/tests/plugins.test.mjs = BLOCKED denied: bun not permitted' | bash "$IS" --check "$range" 2>&1 >/dev/null )"; rc=$?
if [ "$rc" -eq 3 ] && grepq "$err" 'BLOCKED scripts/lanes/tests/plugins\.test\.mjs'; then pass "BLOCKED-with-denial is accounted for but NOT clean (rc3, names the suite)"; else fail "BLOCKED suite: rc=$rc err=$err"; fi

( cd "$FX" && printf '%s\n' 'SUITE scripts/lanes/tests/plugins.test.mjs = BLOCKED denied: bun not permitted' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "a missing verdict (rc1) still outranks BLOCKED (rc3)"; else fail "missing+blocked ordering: rc=$rc"; fi

( cd "$FX" && printf '%s\n%s\n' "$V1" 'SUITE scripts/lanes/tests/plugins.test.mjs = MAYBE' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "an unknown verdict word is not a verdict (rc1)"; else fail "unknown verdict accepted: rc=$rc"; fi

( cd "$FX" && printf '%s\n' 'SUITE scripts/test-uninstall.sh = PASS' 'SUITE scripts/test-elsewhere.sh = PASS' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "a verdict for a suite that is not impacted does not cover the one that is (rc1)"; else fail "stray verdict covered a missing suite: rc=$rc"; fi

# --- 9. --check with nothing impacted is clean, and says so -----------------
change docs/foo/other.md
out="$( cd "$FX" && printf '' | bash "$IS" --check "$range" 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" '0 impacted'; then pass "no impacted suites -> rc0 '0 impacted'"; else fail "empty impacted set: rc=$rc out=$out"; fi

# --- 10. a search that fails is an error, never an empty impacted set --------
# A `git` shim that fails only `grep` (fatal, rc 128); every other subcommand
# reaches the real git so the range still resolves and needles are built.
SHIM="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX" "$SHIM"' EXIT
printf '#!/usr/bin/env bash\nfor a in "$@"; do if [ "$a" = grep ]; then echo "fatal: injected" >&2; exit 128; fi; done\nexec "%s" "$@"\n' "$(command -v git)" > "$SHIM/git"
chmod +x "$SHIM/git"
change scripts/machine-setup/uninstall-plugins.sh
out="$( cd "$FX" && PATH="$SHIM:$PATH" bash "$IS" "$range" 2>/dev/null )"; rc=$?
if [ "$rc" -eq 2 ] && [ -z "$out" ]; then pass "a failing git grep -> rc2, empty stdout (not an empty impacted set)"; else fail "git grep failure: rc=$rc out=$out"; fi
err="$( cd "$FX" && PATH="$SHIM:$PATH" bash "$IS" "$range" 2>&1 >/dev/null )"
if grepq "$err" 'git grep failed'; then pass "the failed search is named on stderr"; else fail "git grep failure not named: $err"; fi

# --- 11. a root-level generic file has no parent to qualify it ---------------
# package.json / CLAUDE.md at the repo root: the bare name is the only needle.
change package.json
out="$(run_is "$range")"
if [ "$out" = "scripts/test-pkg.sh" ]; then pass "root-level package.json -> suite naming package.json"; else fail "root-level generic file reached nothing: $out"; fi

# --- 12. the answer does not depend on the cwd it is run from ----------------
# git ls-tree / git grep are cwd-scoped; from a subdirectory the suites one
# level up would silently drop out and --check would pass on a partial set.
change scripts/machine-setup/uninstall-plugins.sh
out="$( cd "$FX/scripts/machine-setup" && bash "$IS" "$range" 2>/dev/null )"
if grepq "$out" '^scripts/test-uninstall\.sh$'; then pass "run from a subdirectory: repo-relative list still reaches test-uninstall.sh"; else fail "subdirectory run dropped suites: $out"; fi

# --- 13. a non-ASCII suite path comes back as itself, not quoted -------------
# git grep -l quotes such a path ("scripts/test-caf\303\251.sh") unless
# core.quotepath is off; the runner would then filter it out as "not a suite".
mkf scripts/uniq-widget.sh
mkf 'scripts/test-café.sh' 'bash "$d/uniq-widget.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add widget + café suite"
change scripts/uniq-widget.sh
out="$(run_is "$range" --shell)"
if [ "$out" = "scripts/test-café.sh" ]; then pass "non-ASCII suite path is emitted verbatim"; else fail "non-ASCII suite path mangled: $out"; fi

# --- 14. a step that builds the list and fails is an error, not a short list --
# A `sort` shim that fails: the shell-only filter used to end in `|| true`, so
# an empty impacted set (rc 0) was the result of a pipeline that never ran.
SHIM2="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX" "$SHIM" "$SHIM2"' EXIT
printf '#!/usr/bin/env bash\necho "sort: injected" >&2\nexit 2\n' > "$SHIM2/sort"
chmod +x "$SHIM2/sort"
out="$( cd "$FX" && PATH="$SHIM2:$PATH" bash "$IS" "$range" --shell 2>/dev/null )"; rc=$?
if [ "$rc" -eq 2 ] && [ -z "$out" ]; then pass "a failing sort -> rc2, empty stdout (not an empty impacted set)"; else fail "sort failure: rc=$rc out=$out"; fi
err="$( cd "$FX" && PATH="$SHIM2:$PATH" bash "$IS" "$range" --shell 2>&1 >/dev/null )"
if grepq "$err" 'sorting the impacted list failed'; then pass "the failed step is named on stderr"; else fail "sort failure not named: $err"; fi

# --- 15. a suite path containing spaces can receive a verdict (HIMMEL-3243) --
# The verdict path is everything between "SUITE " and the FIRST " = ", so a
# spaced path is accepted; a " = " inside the reason must not move the split.
mkf scripts/uniq-gadget.sh
mkf 'scripts/test-with space.sh' 'bash "$d/uniq-gadget.sh"'
mkf 'scripts/test-a=b.sh' 'bash "$d/uniq-gadget.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add gadget + spaced suites"
change scripts/uniq-gadget.sh
out="$(run_is "$range" --shell)"
if [ "$out" = "$(printf 'scripts/test-a=b.sh\nscripts/test-with space.sh')" ]; then pass "spaced suite paths are listed verbatim"; else fail "spaced suite paths not listed: $out"; fi
SP1='SUITE scripts/test-with space.sh = PASS'
SP2='SUITE scripts/test-a=b.sh = SKIP no gadget = here'
( cd "$FX" && printf '%s\n%s\n' "$SP1" "$SP2" | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 0 ]; then pass "verdicts for spaced/'='-bearing suite paths -> clean (rc0)"; else fail "spaced-path verdicts refused: rc=$rc"; fi
( cd "$FX" && printf '%s\n' "$SP2" | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "a spaced suite without its own verdict stays missing (rc1)"; else fail "missing spaced verdict passed: rc=$rc"; fi
( cd "$FX" && printf '%s\n%s\n' "$SP1" 'SUITE scripts/test-a=b.sh = SKIP' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "a reasonless SKIP on a spaced-path row is still no verdict (rc1)"; else fail "reasonless SKIP accepted on spaced path: rc=$rc"; fi

# --- 16. --runner-check: direct vitest steps + runner drift (HIMMEL-3445) ---
# Fixture workflow files in a scratch dir under $FX, never the real
# .github/workflows (case (c) below reads the real one as a control).
mkdir -p "$FX/.github/workflows"
run_rc() { ( cd "$FX" && bash "$IS" --runner-check 2>&1 ); }

# (a) a direct `npx vitest run` step for an unmapped directory is invisible
# to the old grep (it only looked for node --test/bun test/npm test/
# check-hook-lib-suites.sh) and passed silently; it must now fail, naming it.
cat > "$FX/.github/workflows/ci.yml" <<'YAML'
name: ci
on: push
jobs:
  new-suite:
    runs-on: ubuntu-latest
    steps:
      - run: npx vitest run scripts/newthing/foo.test.ts
YAML
out="$(run_rc)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'newthing'; then pass "unmapped direct vitest step fails --runner-check, naming it"; else fail "unmapped vitest step: rc=$rc out=$out"; fi

# (b) a mapped suite whose invocation drifted from node --test to bun test:
# the old marker matched by path substring alone (still present after the
# swap), so drift went undetected. --runner still emits `node --test` for
# this path.
cat > "$FX/.github/workflows/ci.yml" <<'YAML'
name: ci
on: push
jobs:
  lanes-and-trust-suites:
    runs-on: ubuntu-latest
    steps:
      - run: bun test "scripts/lanes/tests/**/*.test.mjs"
YAML
out="$(run_rc)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'lanes'; then pass "runner drift (node --test -> bun test) fails --runner-check, naming the suite"; else fail "runner drift: rc=$rc out=$out"; fi

# (c) control: today's real .github/workflows/ci.yml still passes.
out="$( cd "$REPO_ROOT" && bash "$IS" --runner-check 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ]; then pass "control: today's real ci.yml still passes --runner-check"; else fail "real ci.yml regressed: rc=$rc out=$out"; fi

# (d) an ambiguous line — two runner families on one `run:` line — cannot be
# attributed to a single runner; fail closed and name it, never guess.
cat > "$FX/.github/workflows/ci.yml" <<'YAML'
name: ci
on: push
jobs:
  weird:
    runs-on: ubuntu-latest
    steps:
      - run: node --test "scripts/lanes/tests/**/*.test.mjs" && bun test "scripts/lanes/tests/**/*.test.mjs"
YAML
out="$(run_rc)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'ambiguous'; then pass "a line naming two runner families fails closed as ambiguous"; else fail "ambiguous line: rc=$rc out=$out"; fi

# --- 17. --run: a fresh worktree's missing npm deps install before the
# suite runs (HIMMEL-3553: worktrees are created with --no-install, so a leg
# running an impacted suite raw sees a false SKIP/FAIL it mislabels
# "pre-existing" — N441/N440/N446 in one shift). -----------------------------
mkdir -p "$FX/pkg-npm"
cat > "$FX/pkg-npm/package.json" <<'JSON'
{
  "name": "fixture-npm",
  "version": "1.0.0",
  "dependencies": { "picocolors": "1.1.1" }
}
JSON
cat > "$FX/pkg-npm/package-lock.json" <<'JSON'
{
  "name": "fixture-npm",
  "version": "1.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": { "name": "fixture-npm", "version": "1.0.0", "dependencies": { "picocolors": "1.1.1" } },
    "node_modules/picocolors": {
      "version": "1.1.1",
      "resolved": "https://registry.npmjs.org/picocolors/-/picocolors-1.1.1.tgz",
      "integrity": "sha512-xceH2snhtb5M9liqDsmEw56le376mTZkEX/jEb/RxNFyegNul7eNslCXP9FDj/Lcu0X8KEyMceP2ntpaHrDEVA==",
      "license": "ISC"
    }
  }
}
JSON
cat > "$FX/pkg-npm/script.mjs" <<'JS'
import pc from 'picocolors';
console.log(pc.red('ok'));
JS
cat > "$FX/pkg-npm/test-uses-dep.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
node "$dir/script.mjs"
SH
chmod +x "$FX/pkg-npm/test-uses-dep.sh"
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add npm fixture package"

# RED control: today (no --run), the suite run raw with no node_modules
# fails MODULE_NOT_FOUND — the base bug, not something --check can rescue.
if (cd "$FX" && bash pkg-npm/test-uses-dep.sh >/dev/null 2>&1); then
    fail "RED control: raw suite should fail without node_modules installed"
else
    pass "RED control: raw suite fails without node_modules (base bug reproduced)"
fi
if [ ! -d "$FX/pkg-npm/node_modules" ]; then pass "RED control: node_modules absent before --run"; else fail "node_modules unexpectedly present before --run"; fi

out="$( cd "$FX" && bash "$IS" --run pkg-npm/test-uses-dep.sh 2>&1 )"; rc=$?
out_plain="$(printf '%s' "$out" | sed $'s/\x1b\\[[0-9;]*m//g')"
if [ "$rc" -eq 0 ] && grepq "$out_plain" '^ok$'; then pass "--run installs missing npm deps then runs the suite (GREEN)"; else fail "--run npm install+run: rc=$rc out=$out"; fi
if [ -d "$FX/pkg-npm/node_modules/picocolors" ]; then pass "--run left node_modules installed from the lockfile"; else fail "--run did not install node_modules"; fi
if grepq "$out" 'installing deps for pkg-npm'; then pass "--run names the package dir it is installing"; else fail "--run install message missing: $out"; fi

# idempotent second run: node_modules already present -> no reinstall.
out2="$( cd "$FX" && bash "$IS" --run pkg-npm/test-uses-dep.sh 2>&1 )"; rc2=$?
if [ "$rc2" -eq 0 ] && ! grepq "$out2" 'installing deps'; then pass "--run is idempotent: no reinstall once node_modules exists"; else fail "--run second run: rc=$rc2 out=$out2"; fi

# --- 18. --run: a bun.lock package installs via bun, --ignore-scripts ------
mkdir -p "$FX/pkg-bun"
cat > "$FX/pkg-bun/package.json" <<'JSON'
{
  "name": "fixture-bun",
  "version": "1.0.0",
  "dependencies": { "picocolors": "1.1.1" }
}
JSON
cat > "$FX/pkg-bun/bun.lock" <<'LOCK'
{
  "lockfileVersion": 2,
  "configVersion": 1,
  "workspaces": {
    "": {
      "name": "fixture-bun",
      "dependencies": {
        "picocolors": "1.1.1",
      },
    },
  },
  "packages": {
    "picocolors": ["picocolors@1.1.1", "", {}, "sha512-xceH2snhtb5M9liqDsmEw56le376mTZkEX/jEb/RxNFyegNul7eNslCXP9FDj/Lcu0X8KEyMceP2ntpaHrDEVA=="],
  }
}
LOCK
cat > "$FX/pkg-bun/script.mjs" <<'JS'
import pc from 'picocolors';
console.log(pc.red('ok-bun'));
JS
cat > "$FX/pkg-bun/test-uses-dep.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
bun "$dir/script.mjs"
SH
chmod +x "$FX/pkg-bun/test-uses-dep.sh"
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add bun fixture package"

out="$( cd "$FX" && bash "$IS" --run pkg-bun/test-uses-dep.sh 2>&1 )"; rc=$?
out_plain="$(printf '%s' "$out" | sed $'s/\x1b\\[[0-9;]*m//g')"
if [ "$rc" -eq 0 ] && grepq "$out_plain" '^ok-bun$'; then pass "--run installs a bun.lock package via bun then runs the suite"; else fail "--run bun install+run: rc=$rc out=$out"; fi
if [ -d "$FX/pkg-bun/node_modules/picocolors" ]; then pass "--run left node_modules installed from bun.lock"; else fail "--run did not install bun node_modules"; fi
if grepq "$out" 'bun install --frozen-lockfile --ignore-scripts'; then pass "--run picks the frozen, script-ignoring bun install command"; else fail "--run bun install command not named: $out"; fi

# --- 19. --run: a missing lockfile is a hard FAIL naming the package dir and
# the suite never runs — never a SKIP, never a bare FAIL (HIMMEL-3553). ------
mkdir -p "$FX/pkg-nolock"
cat > "$FX/pkg-nolock/package.json" <<'JSON'
{ "name": "fixture-nolock", "version": "1.0.0", "dependencies": { "left-pad": "1.0.0" } }
JSON
cat > "$FX/pkg-nolock/test-nolock.sh" <<'SH'
#!/usr/bin/env bash
echo should-not-run
SH
chmod +x "$FX/pkg-nolock/test-nolock.sh"
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add nolock fixture package"
out="$( cd "$FX" && bash "$IS" --run pkg-nolock/test-nolock.sh 2>&1 )"; rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" 'no lockfile' && grepq "$out" 'pkg-nolock'; then pass "--run: missing lockfile is a hard FAIL naming the package dir (rc2), never a SKIP"; else fail "--run missing-lockfile: rc=$rc out=$out"; fi
if ! grepq "$out" 'should-not-run'; then pass "--run: the suite itself never ran after a failed install"; else fail "suite ran despite a missing lockfile: $out"; fi

# --- 20. --run: a suite with no package.json ancestor runs unchanged -------
# (fixture step 9 left a root-level package.json in $FX for a naming test;
# drop it here so this suite genuinely has no package.json ancestor.)
rm -f "$FX/package.json"
mkf scripts/test-no-deps.sh 'echo unaffected'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add no-deps suite, drop root package.json"
out="$( cd "$FX" && bash "$IS" --run scripts/test-no-deps.sh 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" 'unaffected'; then pass "--run: a suite with no package.json ancestor runs unchanged"; else fail "--run no-deps suite: rc=$rc out=$out"; fi

# --- 21. HIMMEL-3798 round 3: --check --from-file reads verdict lines from a
# path instead of stdin. -------------------------------------------------
change scripts/machine-setup/uninstall-plugins.sh
FF="$FX/from-file-21.txt"
printf 'SUITE scripts/test-uninstall.sh = PASS\nSUITE scripts/lanes/tests/plugins.test.mjs = SKIP no node on this host\n' > "$FF"
err="$( cd "$FX" && bash "$IS" --check "$range" --from-file "$FF" 2>&1 >/dev/null )"; rc=$?
if [ "$rc" -eq 0 ]; then pass "--check --from-file with the impacted suite's verdict -> clean (rc0)"; else fail "--from-file full verdict set refused: rc=$rc err=$err"; fi

# --- 22. --from-file without --check refuses (rc2). -------------------------
( cd "$FX" && bash "$IS" "$range" --from-file "$FF" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass "--from-file without --check refuses (rc2)"; else fail "--from-file sans --check: rc=$rc"; fi

# --- 23. --from-file naming a missing path refuses (rc2), fails closed. -----
err="$( cd "$FX" && bash "$IS" --check "$range" --from-file "$FX/nope-23.txt" 2>&1 >/dev/null )"; rc=$?
if [ "$rc" -eq 2 ] && grepq "$err" 'does not exist'; then pass "--from-file missing path -> rc2, names the reason"; else fail "--from-file missing path: rc=$rc err=$err"; fi

# --- 24. --from-file naming a symlink refuses (rc2) without reading through
# it. `ln -s` silently falls back to a plain copy without admin/Developer-Mode
# privilege on Windows — skip the assertion there (same probe idiom as T4e in
# test-write-verdicts.sh). --------------------------------------------------
printf 'SUITE scripts/test-uninstall.sh = PASS\n' > "$FX/real-24.txt"
ln -s "$FX/real-24.txt" "$FX/link-24.txt" 2>/dev/null
if [ -L "$FX/link-24.txt" ]; then
    err="$( cd "$FX" && bash "$IS" --check "$range" --from-file "$FX/link-24.txt" 2>&1 >/dev/null )"; rc=$?
    if [ "$rc" -eq 2 ] && grepq "$err" 'symlink'; then pass "--from-file symlinked path -> rc2, names the reason"; else fail "--from-file symlink: rc=$rc err=$err"; fi
else
    echo "SKIP 24: platform cannot create symlinks without elevated privilege"
fi

# --- 25. HIMMEL-3798 round 4: --from-file naming a genuinely empty regular
# file is ALLOWED (same "no candidates" semantics as empty stdin, test 9) —
# but --check's own n_impacted/n_missing reconciliation, computed independently
# from the diff rather than from this file, still catches it as a missing
# verdict (rc1) when the impacted set from `change scripts/machine-setup/
# uninstall-plugins.sh` (test 21) is non-empty: this is the downstream catch
# for a wrongly-empty --from-file when real candidates exist. -----------------
: > "$FX/empty-25.txt"
out="$( cd "$FX" && bash "$IS" --check "$range" --from-file "$FX/empty-25.txt" 2>&1 )"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'without a verdict'; then pass "--from-file empty path with a non-empty impacted set -> rc1, names the gap"; else fail "--from-file empty path against impacted suites: rc=$rc out=$out"; fi

# --- 26. --from-file naming a genuinely empty file against a genuinely empty
# impacted set is clean (rc0) — the case the runbook's own zero-candidate
# instruction relies on. ------------------------------------------------------
change docs/bar/other-26.md
out="$( cd "$FX" && bash "$IS" --check "$range" --from-file "$FX/empty-25.txt" 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" '0 impacted'; then pass "--from-file empty path with an empty impacted set -> rc0 '0 impacted'"; else fail "--from-file empty path against no impacted suites: rc=$rc out=$out"; fi

# --- 27. HIMMEL-3896: source closure. A suite that names only mid.sh must be
# listed when far.sh (two source hops behind mid.sh) changes. -----------------
mkf scripts/lib/far.sh
mkf scripts/lib/deep.sh '. "$here/far.sh"'
mkf scripts/lib/mid.sh 'source "$here/deep.sh"'
mkf scripts/test-top.sh 'bash "$d/lib/mid.sh"'
mkf scripts/lib/noise.sh 'echo "see far.sh and deep.sh"'
mkf scripts/test-noise.sh 'bash "$d/lib/noise.sh"'
mkf scripts/lib/cyc-a.sh '. "$here/cyc-b.sh"'
mkf scripts/lib/cyc-b.sh '. "$here/cyc-a.sh"'
mkf scripts/test-cyc.sh 'bash "$d/lib/cyc-a.sh"'
gv_a=HIMMEL_UNINSTALL_   # name split across two variables so this file never matches the callers scan itself
gv_b=REAL_HOME
mkf scripts/guard-setter.sh "${gv_a}${gv_b}=1 bash x"
mkf scripts/guard-plain.sh 'echo nothing'
mkf scripts/test-uninstall-real-home-callers.sh 'grep -r "$V" scripts'
mkf scripts/lib/sp-a.sh
mkf scripts/lib/sp-b.sh 'source sp-a.sh'
mkf scripts/lib/sp-c.sh '. sp-b.sh'
mkf scripts/test-sp.sh 'bash "$d/lib/sp-c.sh"'
mkf scripts/lib/vs-lib.sh
mkf scripts/vs-user.sh $'_VS_LIB="$d/lib/vs-lib.sh"\nfor _l in "$_VS_LIB"; do\n  . "$_l"\ndone'
mkf scripts/test-vs.sh 'bash "$d/vs-user.sh"'
mkf scripts/lib/dr-lib.sh
mkf scripts/dr-user.sh $'# shellcheck source=lib/dr-lib.sh\n. "$(pick_lib)"'
mkf scripts/test-dr.sh 'bash "$d/dr-user.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: closure fixtures"
change scripts/lib/far.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-top\.sh$'; then pass "far.sh (2 source hops behind mid.sh) -> test-top.sh"; else fail "closure miss: $out"; fi
if ! grepq "$out" 'test-noise\.sh'; then pass "a non-source mention of far.sh/deep.sh does not widen"; else fail "non-source line widened the closure: $out"; fi
change scripts/lib/cyc-b.sh
change scripts/lib/sp-a.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-sp\.sh$'; then pass "single-space 'source x' / '. x' forms are followed (2 hops)"; else fail "single-space source form missed: $out"; fi
change scripts/lib/vs-lib.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-vs\.sh$'; then pass "variable sourcing (_LIB=...; . \"\$_l\") is followed (backfill-sessions idiom)"; else fail "variable-sourcing miss: $out"; fi
change scripts/lib/dr-lib.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-dr\.sh$'; then pass "a '# shellcheck source=<path>' directive is followed"; else fail "shellcheck-directive miss: $out"; fi
change scripts/lib/cyc-b.sh
# gnu-ok: timeout is guarded by command -v and falls back to an unbounded run
if command -v timeout >/dev/null 2>&1; then out="$( cd "$FX" && timeout 20 bash "$IS" "$range" 2>/dev/null )"; rc=$?; else out="$(run_is "$range")"; rc=0; fi
if [ "$rc" -eq 0 ] && grepq "$out" '^scripts/test-cyc\.sh$'; then pass "source cycle terminates and still lists test-cyc.sh"; else fail "cycle rc=$rc out=$out"; fi

# --- 28. HIMMEL-3868: a file that sets the fence-lifting variable pulls in the
# path-scanning callers suite, which never names it. -------------------------
change scripts/guard-setter.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-uninstall-real-home-callers\.sh$'; then pass "fence-lifting setter -> callers scan listed"; else fail "3868 miss: $out"; fi
change scripts/guard-plain.sh
out="$(run_is "$range")"
if ! grepq "$out" 'real-home-callers'; then pass "a file without the variable does not pull the callers scan"; else fail "callers scan over-selected: $out"; fi

# --- 29. selector-miss: a red suite the PR's selection skipped is recorded. --
change scripts/lib/far.sh
printf 'scripts/test-other.sh\nscripts/test-top.sh\n' > "$FX/red-29.txt"
out="$( cd "$FX" && bash "$IS" --selector-miss "$range" --red-file "$FX/red-29.txt" 2>/dev/null )"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^selector-miss: scripts/test-other\.sh scripts/lib/far\.sh$' && ! grepq "$out" 'test-top'; then pass "selector-miss row for the skipped red suite only (rc1)"; else fail "selector-miss rc=$rc out=$out"; fi
printf 'scripts/test-top.sh\n' > "$FX/red-29b.txt"
out="$( cd "$FX" && bash "$IS" --selector-miss "$range" --red-file "$FX/red-29b.txt" 2>/dev/null )"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "every red suite was selected -> no rows (rc0)"; else fail "selector-miss clean case rc=$rc out=$out"; fi
( cd "$FX" && bash "$IS" --selector-miss "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass "--selector-miss without --red-file -> rc2"; else fail "selector-miss usage rc=$rc"; fi

# --- 30. HIMMEL-3963: the word "source" in a full-line COMMENT is prose, not a
# source edge. A comment naming the changed helper must not join the closure
# (bank-preflight.sh:1084 "# Same source and spelling as tick.sh's ..." pulled
# ~136 suites in for a tracker.py change); a real source line, however it is
# indented or chained, still must. ------------------------------------------
mkf scripts/lib/cm-lib.sh
mkf scripts/lib/cm-prose.sh $'# Same source and spelling as cm-lib.sh\'s field\n  # source cm-lib.sh is the real one\necho prose'
mkf scripts/test-cm-prose.sh 'bash "$d/lib/cm-prose.sh"'
mkf scripts/lib/cm-asg.sh $'_CM="$d/cm-lib.sh"\n# the source $_CM line lives elsewhere\necho asg'
mkf scripts/test-cm-asg.sh 'bash "$d/lib/cm-asg.sh"'
mkf scripts/lib/cm-real.sh $'if x; then\n    source "$here/cm-lib.sh"   # trailing comment\nfi'
mkf scripts/test-cm-real.sh 'bash "$d/lib/cm-real.sh"'
mkf scripts/lib/cm-chain.sh 'true; . cm-lib.sh'
mkf scripts/test-cm-chain.sh 'bash "$d/lib/cm-chain.sh"'
mkf scripts/lib/cm-var.sh $'_CM="$d/cm-lib.sh"\n    . "$_CM"'
mkf scripts/test-cm-var.sh 'bash "$d/lib/cm-var.sh"'
mkf scripts/lib/cm-sub.sh $'(source cm-lib.sh)\n(. "$_CM")'
mkf scripts/test-cm-sub.sh 'bash "$d/lib/cm-sub.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: comment-prose closure fixtures"
change scripts/lib/cm-lib.sh
out="$(run_is "$range")"
if ! grepq "$out" 'test-cm-prose\.sh'; then pass "a comment that says 'source ... cm-lib.sh' does not widen"; else fail "comment prose widened the closure: $out"; fi
if ! grepq "$out" 'test-cm-asg\.sh'; then pass "a comment 'source \$var' does not make an assigning file a variable sourcer"; else fail "comment var-source widened the closure: $out"; fi
if grepq "$out" '^scripts/test-cm-real\.sh$'; then pass "an indented real source line with a trailing comment is still followed"; else fail "indented source missed: $out"; fi
if grepq "$out" '^scripts/test-cm-chain\.sh$'; then pass "a chained '; . x' source is still followed"; else fail "chained source missed: $out"; fi
if grepq "$out" '^scripts/test-cm-var\.sh$'; then pass "an indented variable-sourcing file is still followed"; else fail "indented var-source missed: $out"; fi
if grepq "$out" '^scripts/test-cm-sub\.sh$'; then pass "a subshell '(source x)' is still followed"; else fail "subshell source missed: $out"; fi

# --- 31. HIMMEL-4256: the PR-1734 shape. A NEW file under a tree that a suite
# walks (lint-fail-open scans scripts/lanes/) lists that suite, though no suite
# names the file; a new file outside every declared tree does not. -----------
mkf scripts/guardrails/test-lint-fail-open.sh 'bash "$d/lint-fail-open.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: scan-roots fixtures"
mkdir -p "$FX/scripts/lanes/lib" "$FX/docs/scan-31"
change scripts/lanes/lib/leg-cost-row.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/guardrails/test-lint-fail-open\.sh$'; then pass "a new file under scripts/lanes/ -> test-lint-fail-open.sh (scan root)"; else fail "scan-root miss on the PR-1734 shape: $out"; fi
change docs/scan-31/new.sh
out="$(run_is "$range")"
if ! grepq "$out" 'test-lint-fail-open'; then pass "a new file outside every scan root does not list the scanning suite"; else fail "scan root over-selected: $out"; fi

# --- 32. HIMMEL-4323: npm-licenses row (RED control) and the veto rows. -----
NPM=scripts/hooks/test-check-npm-licenses\\.sh
PCR=scripts/cr/test-pr-check-run\\.sh
LSP=scripts/lanes/test-launch-site-profiles\\.sh
mkf scripts/hooks/test-check-npm-licenses.sh 'echo npm'
mkf scripts/cr/test-pr-check-run.sh 'echo pcr'
mkf scripts/lanes/test-launch-site-profiles.sh 'echo lsp'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: veto fixtures"
mkdir -p "$FX/tools/new" "$FX/tools/node_modules/dep" "$FX/scripts/lanes/bench/fixtures/x" "$FX/scripts/handover" "$FX/scripts/lanes/dist" "$FX/scripts/a"
change tools/new/package.json
out="$(run_is "$range")"
if grepq "$out" "^${NPM}\$"; then pass "a new package.json -> test-check-npm-licenses.sh"; else fail "npm-licenses row missed: $out"; fi
change tools/node_modules/dep/package.json
out="$(run_is "$range")"
if ! grepq "$out" "^${NPM}\$"; then pass "a node_modules package.json does not select npm-licenses"; else fail "npm-licenses veto (node_modules) missed: $out"; fi
change scripts/lanes/bench/fixtures/x/package.json
out="$(run_is "$range")"
if ! grepq "$out" "^${NPM}\$"; then pass "a bench-fixtures package.json does not select npm-licenses"; else fail "npm-licenses veto (fixtures) missed: $out"; fi
change scripts/a/tool.sh
out="$(run_is "$range")"
if grepq "$out" "^${PCR}\$" && grepq "$out" "^${LSP}\$"; then pass "a scripts/a/tool.sh selects pr-check-run and launch-site-profiles"; else fail "scripts/*.sh rows lost: $out"; fi
change scripts/a/test-foo.sh
out="$(run_is "$range")"
if ! grepq "$out" "^${LSP}\$"; then pass "scripts/a/test-foo.sh does not select launch-site-profiles"; else fail "launch-site veto (test-*) missed: $out"; fi
if grepq "$out" "^${PCR}\$"; then pass "scripts/a/test-foo.sh still selects pr-check-run (its walk reads it)"; else fail "pr-check-run over-vetoed scripts/a/test-foo.sh: $out"; fi
change scripts/cr/test-foo.sh
out="$(run_is "$range")"
if ! grepq "$out" "^${PCR}\$"; then pass "scripts/cr/test-foo.sh does not select pr-check-run"; else fail "pr-check-run veto (scripts/cr/test-*) missed: $out"; fi
change scripts/lanes/dist/gen.sh
out="$(run_is "$range")"
if ! grepq "$out" "^${LSP}\$"; then pass "a dist/ file does not select launch-site-profiles"; else fail "launch-site veto (dist) missed: $out"; fi
if grepq "$out" "^${PCR}\$"; then pass "a dist/ file still selects pr-check-run"; else fail "pr-check-run lost dist/ file: $out"; fi

# --- 33. HIMMEL-4488: a changed .claude/commands/*.html selects the CR
# terminology suite (RED control: the .md row alone missed it). ----------------
TERM=scripts/ci/test-check-cr-terminology\\.sh
mkf scripts/ci/test-check-cr-terminology.sh 'echo term'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: terminology fixture"
mkdir -p "$FX/.claude/commands"
change .claude/commands/x.html
out="$(run_is "$range")"
if grepq "$out" "^${TERM}\$"; then pass "a .claude/commands/x.html -> test-check-cr-terminology.sh"; else fail "commands html row missed: $out"; fi

# --- 34. HIMMEL-4453: a change to the CR guarded closure selects
# test-cr-guarded-closure.sh (#1851: leg-jira-status.sh, reached from the
# guarded scripts/lanes/leg-pr-open.sh, was added without selecting it). --------
GC=scripts/cr/test-cr-guarded-closure\\.sh
mkf scripts/cr/test-cr-guarded-closure.sh 'echo gc'
mkf scripts/cr/pr-check-context.sh 'cr_guarded="scripts/cr scripts/lib
scripts/lanes/leg-pr-open.sh"'
mkf scripts/lanes/leg-pr-open.sh 'bash "$d/../handover/console-kit/leg-jira-status.sh"'
mkf scripts/lanes/unrelated.sh 'echo unrelated'
mkf scripts/handover/console-kit/leg-jira-status.sh 'echo jira'
mkf scripts/handover/console-kit/tracker.py 'print(1)'
mkf scripts/cr/test-names-tracker.sh 'grep -q tracker.py x'
mkf .agents/skills/pr-check/SKILL.md 'runbook'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: guarded-closure fixtures"
change scripts/lanes/leg-pr-open.sh
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "a guarded file (leg-pr-open.sh) -> test-cr-guarded-closure.sh"; else fail "guarded file missed: $out"; fi
change scripts/handover/console-kit/leg-jira-status.sh
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "the #1851 shape: an unguarded file a guarded file names -> test-cr-guarded-closure.sh"; else fail "#1851 shape missed: $out"; fi
change .agents/skills/pr-check/SKILL.md
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "the runbook twin -> test-cr-guarded-closure.sh"; else fail "runbook seed missed: $out"; fi
change scripts/handover/console-kit/tracker.py
out="$(run_is "$range")"
if ! grepq "$out" "^${GC}\$"; then pass "tracker.py (named only by a guarded test, reached by no guarded file) does not select the closure suite"; else fail "closure row over-selected tracker.py: $out"; fi
change scripts/lanes/unrelated.sh
out="$(run_is "$range")"
if ! grepq "$out" "^${GC}\$"; then pass "an unreferenced scripts/lanes file does not select the closure suite"; else fail "closure row over-selected scripts/lanes: $out"; fi

# --- 35. HIMMEL-4533/4534/4535: closure arms. -------------------------------
# 4534: arm 1 alone. brand-new.sh sits under the guarded scripts/cr dir and no
# guarded file names it, so arm 2 (a guarded file names the change) cannot fire.
mkf scripts/cr/brand-new.sh 'echo new'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: arm-1 fixture"
change scripts/cr/brand-new.sh
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "arm 1 alone: a file inside a guarded dir that nothing names -> closure suite"; else fail "arm 1 alone missed: $out"; fi
# 4533: arm 2 is not limited to handover/lanes/lib: a guarded file naming
# scripts/telegram/status.sh makes a change to it select the closure suite.
mkf scripts/lanes/names-tg.sh 'bash "$d/../telegram/status.sh"'
mkf scripts/telegram/status.sh 'echo status'
mkf scripts/cr/pr-check-context.sh 'cr_guarded="scripts/cr scripts/lib
scripts/lanes/leg-pr-open.sh scripts/lanes/names-tg.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: telegram fixtures"
change scripts/telegram/status.sh
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "arm 2 beyond handover/lanes/lib: scripts/telegram/status.sh -> closure suite"; else fail "telegram edge missed: $out"; fi
# 4535: a head without pr-check-context.sh must not silently skip the suite.
git -C "$FX" rm -q scripts/cr/pr-check-context.sh
git -C "$FX" commit -q -m "chore: drop pr-check-context.sh"
change scripts/lanes/unrelated.sh
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "a head with no pr-check-context.sh still selects the closure suite"; else fail "closure suite skipped on an unreadable guarded set: $out"; fi

echo
if [ "$failures" -eq 0 ]; then echo "OK: all cases passed"; exit 0; fi
echo "FAIL: $failures case(s) failed"
exit 1
