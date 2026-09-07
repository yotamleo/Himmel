#!/usr/bin/env bash
# Hermetic tests for scripts/setup/check-user-slug.sh (HIMMEL-2537) and for
# setup.sh's step [0.5/9] wiring.
#
# The thing under test is a DISPOSITION, not a resolver: the resolver itself is
# covered by scripts/test-user-slug-resolve.sh. What matters here is that an
# unresolved slug leaves the install running (rc=3, never rc=1), says what that
# costs, and is still visible after "Setup complete." scrolls past.
#
# PLATFORM GUARD (WS5 T15) — no .ps1 twin, deliberately: this is the suite for
# a bash-only script (scripts/setup/check-user-slug.sh, which documents its own
# guard for the same reason — setup.ps1 has no USER_SLUG step to mirror). It
# runs under Git Bash on Windows like every other scripts/setup/test-*.sh, and
# its fixtures are POSIX shell plus git. A PowerShell twin would have nothing
# to exercise. If setup.ps1 ever grows a USER_SLUG step, its twin suite belongs
# with THAT change.
set -uo pipefail

here="$(cd -- "$(dirname -- "$0")" && pwd)"
script="$here/check-user-slug.sh"
setup_sh="$(cd -- "$here/.." && pwd)/setup.sh"
PASS=0; FAIL=0; TMP_ROOT=""
# shellcheck disable=SC2329,SC2317
cleanup() { [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ] && rm -rf "$TMP_ROOT" 2>/dev/null; return 0; }
trap cleanup EXIT
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want='$2' got='$3'"; fi; }
# grep -q with NO pipeline: under `set -o pipefail` a piped `grep -q` reports a
# SUCCESSFUL early match as a failed pipeline (SIGPIPE on the producer) —
# HIMMEL-1430, the same trap test-user-slug-resolve.sh documents.
assert_has() { if grep -q -F -- "$2" <<< "$3"; then pass "$1"; else fail "$1" "missing: $2"; fi; }
assert_lacks() { if grep -q -F -- "$2" <<< "$3"; then fail "$1" "unexpectedly present: $2"; else pass "$1"; fi; }

# An explicit template, because BSD/macOS requires one, and the failure is
# captured before anything builds a path on the result: unchecked, TMP_ROOT
# would be empty and the HOME override below would then point at /home.
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/check-user-slug.XXXXXX") || {
  echo "FAIL: mktemp -d failed" >&2; exit 1;
}
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

# Isolation, same recipe as test-user-slug-resolve.sh: a HOME the operator's
# ~/.gitconfig cannot reach, no GIT_CONFIG_* overrides, and a `gh` stub that is
# always unauthenticated — otherwise a tester with a real gh login resolves a
# slug and the unresolved arm silently never runs.
export HOME="$TMP_ROOT/home"; mkdir -p "$HOME"
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM 2>/dev/null || true
# Unsetting GIT_CONFIG_SYSTEM does NOT disable system config — it just
# restores git's DEFAULT system path (/etc/gitconfig). A machine with a
# system-wide user.name would then resolve a slug in the "unresolved" arms
# below and the tests would pass for the wrong reason (CR round 7 [codex-2]).
export GIT_CONFIG_NOSYSTEM=1
gh() { return 1; }
export -f gh

REPO="$TMP_ROOT/repo"
git init -q "$REPO"
git -C "$REPO" config user.email "test@test.invalid"
git -C "$REPO" remote add origin https://github.com/test/test.git

run() { ( cd "$REPO" && bash "$script" ); }

# ── 1. Resolved: stdout is the bare slug and NOTHING else, because setup.sh
# captures it straight into `export USER_SLUG=`.
echo "TEST: resolved -> rc=0, stdout is the bare slug"
out=$(USER_SLUG=alice run 2>/dev/null); rc=$?
assert_eq "resolved rc=0" "0" "$rc"
assert_eq "stdout is exactly the slug" "alice" "$out"
err=$(USER_SLUG=alice run 2>&1 >/dev/null)
assert_has "stderr names the source" "USER_SLUG env" "$err"

# ── 2. Unresolved: rc=3, and specifically NOT 1. rc=1 is what aborted the
# contributor install in the HIMMEL-2457 C4b cell; a regression to it would be
# invisible to a test that only asserted "non-zero".
echo "TEST: unresolved -> rc=3 (the advisory code), never rc=1"
git -C "$REPO" config --unset user.name 2>/dev/null || true
out=$(USER_SLUG='' run 2>/dev/null); rc=$?
assert_eq "unresolved rc=3" "3" "$rc"
assert_eq "unresolved stdout is empty" "" "$out"

err=$(USER_SLUG='' run 2>&1 >/dev/null)
assert_has "diagnostic is a WARN, since the run continues" "WARN user-slug" "$err"
assert_lacks "and is NOT framed as a fatal ERR" "ERR user-slug" "$err"
assert_has "says the setup continues" "Setup CONTINUES" "$err"
assert_has "names the consequence" "handover buckets" "$err"
assert_has "remedy 1: the env var" "USER_SLUG" "$err"
assert_has "remedy 2: the forge CLI" "gh auth login" "$err"
assert_has "remedy 3: the git identity" "git config" "$err"
assert_has "says no re-run of setup is needed" "no re-run of setup" "$err"

# ── 2b. The --dotenv-root bridge (CR round 1 [codex-1]). setup.sh's footer
# re-probes through this so an operator who supplied a slug at [5/9]'s
# --fill-env prompt is not then told to go and supply one.
echo "TEST: --dotenv-root resolves the way a consumer does"
ENV_ROOT="$TMP_ROOT/envroot"; mkdir -p "$ENV_ROOT"
printf 'USER_SLUG=your-slug\n' > "$ENV_ROOT/.env.example"

run_env() { ( cd "$REPO" && bash "$script" --dotenv-root "$ENV_ROOT" ); }

# No .env at all -> unchanged behaviour, still advised.
out=$(USER_SLUG='' run_env 2>/dev/null); rc=$?
assert_eq "no .env -> still rc=3" "3" "$rc"

# A real value in .env -> resolved, and the row must NOT fire.
printf 'USER_SLUG=filled-by-operator\n' > "$ENV_ROOT/.env"
out=$(USER_SLUG='' run_env 2>/dev/null); rc=$?
assert_eq ".env value -> rc=0" "0" "$rc"
assert_eq ".env value is the resolved slug" "filled-by-operator" "$out"

# The placeholder is NOT a value. A fresh .env is .env.example verbatim, so
# accepting it would report 'your-slug' as the operator's slug.
printf 'USER_SLUG=your-slug\n' > "$ENV_ROOT/.env"
out=$(USER_SLUG='' run_env 2>/dev/null); rc=$?
assert_eq "placeholder .env -> still rc=3" "3" "$rc"
assert_eq "placeholder is never printed as a slug" "" "$out"
err=$(USER_SLUG='' run_env 2>&1 >/dev/null)
assert_has "placeholder rejection says why" "still .env.example's placeholder" "$err"

# A live USER_SLUG outranks .env — load_dotenv's own non-clobbering rule.
printf 'USER_SLUG=from-file\n' > "$ENV_ROOT/.env"
out=$(USER_SLUG=from-env run_env 2>/dev/null); rc=$?
assert_eq "env outranks .env" "from-env" "$out"

# A malformed invocation must not be mistaken for the no-flag form.
out=$( ( cd "$REPO" && bash "$script" --dotenv-root ) 2>/dev/null); rc=$?
assert_eq "--dotenv-root with no value -> usage rc=2" "2" "$rc"
out=$( ( cd "$REPO" && bash "$script" --bogus ) 2>/dev/null); rc=$?
assert_eq "unknown flag -> usage rc=2" "2" "$rc"

# A trailing argument past --dotenv-root <dir> (CR round 2 [codex-2]): the
# parser used to stop reading at $2 and silently ignore anything after,
# proceeding as if the invocation were fine.
out=$( ( cd "$REPO" && bash "$script" --dotenv-root "$ENV_ROOT" extra ) 2>/dev/null); rc=$?
assert_eq "trailing arg after --dotenv-root <dir> -> usage rc=2" "2" "$rc"

# ── 3. The setup.sh wiring. The disposition is only real if the caller honours
# it, so pin the two halves that carry it: step 0.5 routes through this script
# and does not abort, and the footer still names the skipped step.
echo "TEST: setup.sh step [0.5/9] wiring"
setup_src=$(cat "$setup_sh")
assert_has "step 0.5 calls check-user-slug.sh" "setup/check-user-slug.sh" "$setup_src"
assert_has "an unresolved slug is recorded for the footer" "_user_slug_manual=1" "$setup_src"
assert_has "the footer names the skipped step" "STILL MANUAL: USER_SLUG" "$setup_src"
assert_has "the footer re-probes with .env bridged in" "--dotenv-root" "$setup_src"
# CR round 9 [codex-1]: the unverified row's PRESCRIBED command must carry
# --dotenv-root too. Without it an operator whose slug lives only in .env runs
# the suggested check, sees "unresolved", and concludes their setup is broken —
# the same defect round 4 fixed on himmelctl's row, which was never mirrored
# here. Asserted against the printed guidance, not the probe calls.
assert_has "the unverified row prescribes the .env-aware command" \
  "check-user-slug.sh --dotenv-root ." "$setup_src"
# CR round 6 [codex-1]: BOTH probes bridge .env, not just the footer one — a
# re-run of setup has an .env already, and the bare 0.5 probe would warn about
# a slug the consumers read fine, a WARN the footer then silently contradicts.
# Counted, not just grepped: one --dotenv-root would satisfy a bare `has`.
# Counts INVOCATIONS, not occurrences — the prose above this assertion's own
# fix mentions the flag too, and a bare occurrence count reads 3 and passes for
# the wrong reason (the same comment-matches-the-detector trap the
# [mktemp-no-template] fix hit earlier on this branch).
assert_eq "both probes bridge .env, not only the footer" "2" \
  "$(grep -c 'check-user-slug\.sh" --dotenv-root' "$setup_sh")"

# No `exit 1` between the [0.5/9] banner and the [1/9] banner — the abort this
# ticket removed. A line-range assertion rather than a whole-file grep, because
# setup.sh legitimately exits 1 elsewhere (the [0/9] preflight, [0.4/9]).
s_line=$(grep -n '\[0\.5/9\] Resolving USER_SLUG' "$setup_sh" | head -1 | cut -d: -f1)
e_line=$(grep -n '\[1/9\] Installing pre-commit' "$setup_sh" | head -1 | cut -d: -f1)
if [ -n "$s_line" ] && [ -n "$e_line" ] && [ "$e_line" -gt "$s_line" ]; then
  block=$(sed -n "${s_line},${e_line}p" "$setup_sh")
  assert_lacks "step 0.5 no longer aborts the install" "exit 1" "$block"
else
  fail "could not locate the [0.5/9]..[1/9] block" "start=$s_line end=$e_line"
fi

# ── 3b. Footer classification (CR round 3 [codex-1]): a genuinely unresolved
# slug (rc=3) and a probe that itself broke (any other rc) must render
# DIFFERENT footer rows, mirroring userSlugState()'s unverified/did-not-resolve
# split in scripts/himmelctl/bin.js. This is executed, not grepped: the
# classification depends on runtime state (_user_slug_manual, _slug_rc) that a
# source-text grep cannot exercise, and setup.sh itself can't be run end to end
# hermetically (it installs real tooling) — so the two if-blocks between the
# [0.5/9] footer comment and "NEXT:" are extracted and eval'd directly against
# a stubbed check-user-slug.sh, giving a real behavioural run of the footer
# logic without paying for the rest of setup.sh.
echo
echo "TEST: setup.sh footer classification (known rc=3 vs. unverified)"
# shellcheck disable=SC2016 # single-quoted on purpose: matching setup.sh's literal "$_user_slug_manual", not expanding our own
footer_start=$(grep -n '^if \[ "\$_user_slug_manual" = "1" \]; then$' "$setup_sh" | head -1 | cut -d: -f1)
footer_end_marker=$(grep -n '^echo "NEXT:' "$setup_sh" | head -1 | cut -d: -f1)
if [ -z "$footer_start" ] || [ -z "$footer_end_marker" ]; then
  fail "could not locate the footer block markers" "start=$footer_start end_marker=$footer_end_marker"
else
  footer_end=$((footer_end_marker - 1))
  footer_block=$(sed -n "${footer_start},${footer_end}p" "$setup_sh")

  FOOTER_REPO="$TMP_ROOT/footer-repo"
  mkdir -p "$FOOTER_REPO/scripts/setup"

  # args: $1 = rc the stubbed check-user-slug.sh --dotenv-root re-probe exits
  # with, $2 = the _slug_rc already latched by [0.5/9] before the footer runs.
  run_footer() {
    local probe_rc="$1" initial_rc="$2"
    printf '#!/usr/bin/env bash\nexit %s\n' "$probe_rc" > "$FOOTER_REPO/scripts/setup/check-user-slug.sh"
    chmod +x "$FOOTER_REPO/scripts/setup/check-user-slug.sh"
    ( set -uo pipefail
      # shellcheck disable=SC2034 # read by footer_block via eval below, invisible to static analysis
      REPO_ROOT="$FOOTER_REPO"
      _user_slug_manual=1
      _slug_rc=$initial_rc
      eval "$footer_block"
      echo "MANUAL=$_user_slug_manual"
    )
  }

  # [0.5/9] already found a KNOWN unresolved slug (rc=3); the footer re-probe
  # then breaks with an unrelated rc. The known verdict must stand — not be
  # silenced, and not be downgraded to "unverified".
  out=$(run_footer 5 3)
  assert_has "known rc=3 keeps the confident row" "STILL MANUAL: USER_SLUG did not resolve" "$out"
  assert_lacks "known rc=3 is not relabeled 'could NOT be verified'" "could NOT be verified" "$out"

  # [0.5/9] itself was inconclusive (rc=9, some unexpected value) and the
  # footer re-probe ALSO breaks, with a DIFFERENT unexpected rc (7). The row
  # must use the footer's own rc (proving it was actually adopted, not the
  # stale [0.5/9] one) and must NOT claim the confident "did not resolve".
  out=$(run_footer 7 9)
  assert_has "unverified state gets its own row, with the footer's own rc" "STILL MANUAL: USER_SLUG could NOT be verified (check-user-slug.sh exited rc=7)" "$out"
  assert_lacks "unverified state does not claim confident non-resolution" "did not resolve (see [0.5/9]" "$out"

  # A footer re-probe that SUCCEEDS clears the manual flag regardless of how
  # inconclusive [0.5/9] was — the "may only ever clear, never set" property.
  out=$(run_footer 0 9)
  assert_has "a successful footer re-probe clears the manual flag" "MANUAL=0" "$out"
fi

# ── 4. Broken probe (CR round 7 [codex-1]): the resolver lib this script
# sources is itself unreachable. Under `set -uo pipefail` (deliberately NOT
# `-e`) an unchecked source would fall through to the advisory path and
# report a probe that never ran as a confident rc=3 "confirmed unresolved" —
# the false confidence this whole ticket exists to remove. A scratch copy of
# check-user-slug.sh with no sibling ../lib/ dir reproduces the failure
# without touching anything in the real tree.
echo
echo "TEST: broken probe (sourced lib unreachable) -> rc=4, never 0/2/3"
BROKEN_ROOT="$TMP_ROOT/broken-probe/scripts/setup"
mkdir -p "$BROKEN_ROOT"
cp "$script" "$BROKEN_ROOT/check-user-slug.sh"
run_broken() { USER_SLUG='' bash "$BROKEN_ROOT/check-user-slug.sh"; }
out=$(run_broken 2>/dev/null); rc=$?
assert_eq "broken probe rc=4 (not 0, 2 or 3)" "4" "$rc"
assert_eq "broken probe prints nothing to stdout" "" "$out"
err=$(run_broken 2>&1 >/dev/null)
assert_has "stderr says the probe itself did not run" "the probe itself did not run" "$err"
assert_has "stderr names the unreachable lib path" "user-slug.sh" "$err"

# ── 4b. Broken probe (CR round 8 [codex-1]): the two SOURCE guards (round 7,
# above) do not cover the load_dotenv CALL itself on the --dotenv-root path —
# round 7 checked `. lib` but not `load_dotenv --root ...`'s own exit status,
# so a failing call fell through silently (USER_SLUG stays empty, the
# resolver then legitimately finds nothing) and reported the same false
# "confirmed unresolved" rc=3 that round 7 fixed for the sourcing case. A
# scratch copy of check-user-slug.sh with sibling lib stubs — a working
# user-slug.sh (never reached; the call fails before user_slug_verify runs)
# and a load-dotenv.sh whose load_dotenv() deliberately returns 1 — reproduces
# a genuine call failure without touching the real scripts/lib/load-dotenv.sh.
echo
echo "TEST: broken probe (load_dotenv call fails) -> rc=4, never 0/2/3"
BROKEN2_ROOT="$TMP_ROOT/broken-load-dotenv-call"
mkdir -p "$BROKEN2_ROOT/scripts/setup" "$BROKEN2_ROOT/scripts/lib"
cp "$script" "$BROKEN2_ROOT/scripts/setup/check-user-slug.sh"
cat > "$BROKEN2_ROOT/scripts/lib/user-slug.sh" <<'STUB'
user_slug_verify() { return 1; }
STUB
cat > "$BROKEN2_ROOT/scripts/lib/load-dotenv.sh" <<'STUB'
load_dotenv() { return 1; }
STUB
run_broken2() { USER_SLUG='' bash "$BROKEN2_ROOT/scripts/setup/check-user-slug.sh" --dotenv-root "$BROKEN2_ROOT"; }
out=$(run_broken2 2>/dev/null); rc=$?
assert_eq "load_dotenv call failure rc=4 (not 0, 2 or 3)" "4" "$rc"
assert_eq "load_dotenv call failure prints nothing to stdout" "" "$out"
err=$(run_broken2 2>&1 >/dev/null)
assert_has "stderr says the --dotenv-root probe itself did not run" "the --dotenv-root probe itself did not run" "$err"
assert_has "stderr says load_dotenv failed" "load_dotenv failed" "$err"

# ── 5. This suite's own isolation actually holds (CR round 7 [codex-2]).
# Unsetting GIT_CONFIG_SYSTEM only restores git's default /etc/gitconfig path
# — it does not disable system config — so a machine with a system-wide
# user.name would silently resolve a slug in the "unresolved" fixtures above.
echo
echo "TEST: suite isolation actually holds"
assert_eq "GIT_CONFIG_NOSYSTEM is exported (not just GIT_CONFIG_SYSTEM unset)" "1" "${GIT_CONFIG_NOSYSTEM:-}"

echo
echo "test summary: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
