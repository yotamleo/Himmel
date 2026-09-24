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
if [ "$rc" -eq 0 ] && grepq "$out" '^ok$'; then pass "--run installs missing npm deps then runs the suite (GREEN)"; else fail "--run npm install+run: rc=$rc out=$out"; fi
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
if [ "$rc" -eq 0 ] && grepq "$out" '^ok-bun$'; then pass "--run installs a bun.lock package via bun then runs the suite"; else fail "--run bun install+run: rc=$rc out=$out"; fi
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

echo
if [ "$failures" -eq 0 ]; then echo "OK: all cases passed"; exit 0; fi
echo "FAIL: $failures case(s) failed"
exit 1
