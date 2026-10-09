#!/usr/bin/env bash
# scripts/ci/test-run-shell-tests-scanroot.sh — the run-shell-tests.sh scan-root
# guard (HIMMEL-2504).
#
# The runner cds to its OWN repo (REPO_ROOT) before it parses a single
# argument, so invoked by absolute path from a different checkout (a worktree
# calling the primary's copy) it silently scanned the script's repo, and with
# --pr posted a green SUMMARY certifying code the PR does not contain. Now it
# refuses (rc 2) when the caller's cwd is a git work tree whose toplevel is not
# the script's repo, unless --scan-repo-of-script is passed, and it names the
# tree it scanned (root, branch, sha) in the plan header and the --pr SUMMARY.
#
#   26a  foreign git cwd              -> rc 6 (own code, HIMMEL-5104), names the flag, runs nothing
#   26b  foreign git cwd + the flag   -> runs, rc 0
#   26c  cwd = the script's own repo  -> unaffected (rc 0)
#   26d  cwd not in any git work tree -> unaffected (rc 0)
#   26e  the plan header (--list and a real run) carries the scanning line
#   26f  the --pr SUMMARY body carries the scanning line
#   26g  an absolute scan root inside ANOTHER work tree -> rc 6, runs nothing
#   26h  an exported GIT_DIR cannot redirect the scanning line or the head
#   26i  an exported GIT_COMMON_DIR cannot either
#   26j  a git that names no toplevel (a test's fake git) is no mismatch
#   26k  caller_top: a git printing nothing is "no tree known" (HIMMEL-5111)
#   26l  CDPATH cannot steer the guard's cd or the scanned root
#   26m  GIT_INDEX_FILE / GIT_OBJECT_DIRECTORY do not reach the suites
#   26n  a runner outside any work tree + a scan root inside one -> rc 6 (fail-closed)
#   26o  the scripts default is applied before the guard
#
# Platform guard: bash-only, like every suite in this family, and no .ps1
# twin — it runs under Git Bash on Windows as well as Linux.
#
# Usage: bash scripts/ci/test-run-shell-tests-scanroot.sh
#
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$RST_FIXTURE_DIR/../lib/fixture-tempdir.sh"

SRC_ROOT="$(cd "$RST_FIXTURE_DIR/../.." && pwd)"

FOREIGN="$(fixture_mktemp_dir)" || exit 1
SCANDIR="$(fixture_mktemp_dir)" || exit 1
PLAIN="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FOREIGN" "$SCANDIR" "$PLAIN" "$SUITE_LOCK_SANDBOX"' EXIT

# A second, unrelated git repo: the caller's cwd.
(
  fixture_enter_git_init_dir "$FOREIGN" || exit 1
  git init -q
) || exit 1

# One trivial suite to scan; it lives outside both repos, so only the cwd
# differs between the cases.
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCANDIR/test-trivial.sh"

# --- 26a. foreign git cwd is refused ---------------------------------------
out=$(cd "$FOREIGN" && env -u SUITE_TIER_MODE bash "$RUNNER" "$SCANDIR" 2>&1); rc=$?
if [ "$rc" -eq 6 ] && grepq "$out" -- '--scan-repo-of-script' && ! grepq "$out" '\[PASS\]'; then
  pass "26a: foreign git cwd -> rc 6, names --scan-repo-of-script, ran nothing"
else
  fail "26a: rc=$rc output: $out"
fi
out=$(cd "$FOREIGN" && env -u SUITE_TIER_MODE bash "$RUNNER" --list "$SCANDIR" 2>&1); rc=$?
if [ "$rc" -eq 6 ]; then
  pass "26a: --list is refused from a foreign git cwd too"
else
  fail "26a: --list rc=$rc output: $out"
fi

# --- 26b. the explicit opt-in -----------------------------------------------
out=$(cd "$FOREIGN" && env -u SUITE_TIER_MODE bash "$RUNNER" --scan-repo-of-script "$SCANDIR" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" 'test-trivial\.sh'; then
  pass "26b: --scan-repo-of-script from a foreign git cwd runs (rc 0)"
else
  fail "26b: rc=$rc output: $out"
fi

# --- 26c. cwd in the script's own repo is untouched ---------------------------
out=$(cd "$SRC_ROOT" && env -u SUITE_TIER_MODE bash "$RUNNER" "$SCANDIR" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" 'test-trivial\.sh'; then
  pass "26c: cwd inside the script's repo -> no refusal (rc 0)"
else
  fail "26c: rc=$rc output: $out"
fi
out=$(cd "$SRC_ROOT/scripts" && env -u SUITE_TIER_MODE bash "$RUNNER" "$SCANDIR" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  pass "26c: a subdirectory of the script's repo -> no refusal (rc 0)"
else
  fail "26c: subdir rc=$rc output: $out"
fi

# --- 26d. cwd outside any git work tree is untouched --------------------------
out=$(cd "$PLAIN" && env -u SUITE_TIER_MODE GIT_CEILING_DIRECTORIES="$PLAIN/.." bash "$RUNNER" "$SCANDIR" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" 'test-trivial\.sh'; then
  pass "26d: cwd outside any git work tree -> no refusal (rc 0)"
else
  fail "26d: rc=$rc output: $out"
fi

# --- 26e. the plan header names the scanned tree ------------------------------
want_root="$(cd "$SRC_ROOT" && pwd -P)"
want_sha=$(git -C "$SRC_ROOT" rev-parse --short HEAD)
for mode in "--list" ""; do
  # shellcheck disable=SC2086  # $mode is deliberately empty or one flag
  out=$(cd "$SRC_ROOT" && env -u SUITE_TIER_MODE bash "$RUNNER" $mode "$SCANDIR" 2>&1)
  line=$(grep -m1 '^scanning:' <<< "$out" || true)
  if [ -n "$line" ] && grepq "$line" "root=$want_root" && grepq "$line" 'branch=' && grepq "$line" "sha=$want_sha"; then
    pass "26e: ${mode:-run} plan header has 'scanning: root= branch= sha=' ($line)"
  else
    fail "26e: ${mode:-run} no scanning line naming $want_root / $want_sha: $out"
  fi
done

# --- 26f. the --pr SUMMARY body names the scanned tree ------------------------
GH_STUB="$PLAIN/gh-stub.sh"
GH_BODY="$PLAIN/gh-body.txt"
cat > "$GH_STUB" <<'EOF'
#!/usr/bin/env bash
# gh pr comment <N> --body <text>: record the body.
printf '%s' "$5" > "$GH_BODY_FILE"
EOF
chmod +x "$GH_STUB"
out=$(cd "$SRC_ROOT" && env -u SUITE_TIER_MODE GH_CMD="$GH_STUB" GH_BODY_FILE="$GH_BODY" bash "$RUNNER" --pr 1 "$SCANDIR" 2>&1); rc=$?
body=$(cat "$GH_BODY" 2>/dev/null || true)
if [ "$rc" -eq 0 ] && grepq "$body" "^ scanning: root=$want_root " && grepq "$body" "sha=$want_sha"; then
  pass "26f: --pr SUMMARY body carries the scanning line"
else
  fail "26f: rc=$rc body: $body output: $out"
fi

# --- 26g. an absolute scan root inside another work tree (HIMMEL-5104) --------
mkdir -p "$FOREIGN/suites"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FOREIGN/suites/test-trivial.sh"
out=$(cd "$SRC_ROOT" && env -u SUITE_TIER_MODE bash "$RUNNER" "$FOREIGN/suites" 2>&1); rc=$?
if [ "$rc" -eq 6 ] && ! grepq "$out" '\[PASS\]'; then
  pass "26g: absolute scan root in another work tree -> rc 6, ran nothing"
else
  fail "26g: rc=$rc output: $out"
fi
out=$(cd "$SRC_ROOT" && env -u SUITE_TIER_MODE bash "$RUNNER" --scan-repo-of-script "$FOREIGN/suites" 2>&1); rc=$?
if [ "$rc" -eq 6 ]; then
  pass "26g: --scan-repo-of-script does not excuse a root in another work tree"
else
  fail "26g: flag rc=$rc output: $out"
fi

# --- 26h. an exported GIT_DIR cannot redirect the head or the scanning line ----
git -C "$FOREIGN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
rm -f "$GH_BODY"
want_head=$(git -C "$SRC_ROOT" rev-parse HEAD)
out=$(cd "$SRC_ROOT" && env -u SUITE_TIER_MODE GIT_DIR="$FOREIGN/.git" GH_CMD="$GH_STUB" GH_BODY_FILE="$GH_BODY" bash "$RUNNER" --pr 1 "$SCANDIR" 2>&1); rc=$?
body=$(cat "$GH_BODY" 2>/dev/null || true)
if [ "$rc" -eq 0 ] && grepq "$body" "head: $want_head" && grepq "$body" "sha=$want_sha"; then
  pass "26h: GIT_DIR=<foreign repo> leaves head and scanning sha on the scanned tree"
else
  fail "26h: rc=$rc body: $body output: $out"
fi

# --- 26i. an exported GIT_COMMON_DIR cannot redirect them either ----------------
rm -f "$GH_BODY"
out=$(cd "$SRC_ROOT" && env -u SUITE_TIER_MODE GIT_COMMON_DIR="$FOREIGN/.git" GH_CMD="$GH_STUB" GH_BODY_FILE="$GH_BODY" bash "$RUNNER" --pr 1 "$SCANDIR" 2>&1); rc=$?
body=$(cat "$GH_BODY" 2>/dev/null || true)
if [ "$rc" -eq 0 ] && grepq "$body" "head: $want_head" && grepq "$body" "sha=$want_sha"; then
  pass "26i: GIT_COMMON_DIR=<foreign repo> leaves head and scanning sha on the scanned tree"
else
  fail "26i: rc=$rc body: $body output: $out"
fi

# --- 26j. a git that names no toplevel is "no tree known", never a mismatch -----
# CI's case 22f puts a fake git on PATH: `git -C <dir> rev-parse --show-toplevel`
# prints nothing (rc 0) and the plain call exits 1. An empty answer used to be
# cd'd into in place and compared against the empty root top -> a false refusal.
FAKEBIN="$PLAIN/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  rev-parse) exit 1 ;;
esac
exit 0
EOF
chmod +x "$FAKEBIN/git"
out=$(cd "$SRC_ROOT" && env -u SUITE_TIER_MODE PATH="$FAKEBIN:$PATH" bash "$RUNNER" "$SCANDIR" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! grepq "$out" 'REFUSED'; then
  pass "26j: a git that names no toplevel does not refuse the scan root"
else
  fail "26j: rc=$rc output: $out"
fi
rm -f "$GH_STUB" "$GH_BODY"

# --- 26k. caller_top: a git that prints nothing is "no tree known" (HIMMEL-5111) -
# `rev-parse --show-toplevel` printing nothing at rc 0 used to be cd'd into in
# place, so the caller's own cwd became its "work tree" and was refused against
# the script's repo. From a cwd outside every tree that must be no mismatch.
cat > "$FAKEBIN/git" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKEBIN/git"
out=$(cd "$PLAIN" && env -u SUITE_TIER_MODE PATH="$FAKEBIN:$PATH" bash "$RUNNER" "$SCANDIR" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! grepq "$out" 'REFUSED'; then
  pass "26k: a git printing nothing for the caller's toplevel is no mismatch"
else
  fail "26k: rc=$rc output: $out"
fi

# --- 26m. GIT_INDEX_FILE / GIT_OBJECT_DIRECTORY do not reach the suites ---------
ENVPROBE="$(fixture_mktemp_dir)" || exit 1
ENVOUT="$ENVPROBE/seen.txt"
cat > "$ENVPROBE/test-envprobe.sh" <<'EOF'
#!/usr/bin/env bash
printf 'index=%s objdir=%s\n' "${GIT_INDEX_FILE-unset}" "${GIT_OBJECT_DIRECTORY-unset}" > "$ENVPROBE_OUT"
exit 0
EOF
out=$(cd "$SRC_ROOT" && env -u SUITE_TIER_MODE ENVPROBE_OUT="$ENVOUT" GIT_INDEX_FILE=/nonexistent/index GIT_OBJECT_DIRECTORY=/nonexistent/objects bash "$RUNNER" "$ENVPROBE" 2>&1); rc=$?
seen=$(cat "$ENVOUT" 2>/dev/null || true)
if [ "$rc" -eq 0 ] && [ "$seen" = "index=unset objdir=unset" ]; then
  pass "26m: GIT_INDEX_FILE and GIT_OBJECT_DIRECTORY are cleared with the other GIT_* vars"
else
  fail "26m: rc=$rc seen='$seen' output: $out"
fi
rm -rf "$ENVPROBE"

# --- 26n. a runner outside any work tree, scan root inside one (HIMMEL-5111) -----
# A tarball install has no tree; a scan root that DOES name one is a mismatch
# (fail-closed). A scan root outside every tree stays allowed.
TARBALL="$PLAIN/tarball"
mkdir -p "$TARBALL/scripts/ci" "$TARBALL/scripts/lib"
cp "$SRC_ROOT/scripts/ci/run-shell-tests.sh" "$TARBALL/scripts/ci/"
cp -R "$SRC_ROOT/scripts/lib/." "$TARBALL/scripts/lib/"
out=$(cd "$PLAIN" && env -u SUITE_TIER_MODE bash "$TARBALL/scripts/ci/run-shell-tests.sh" "$FOREIGN/suites" 2>&1); rc=$?
if [ "$rc" -eq 6 ] && ! grepq "$out" '\[PASS\]'; then
  pass "26n: tarball runner + scan root in a work tree -> rc 6, ran nothing"
else
  fail "26n: rc=$rc output: $out"
fi
out=$(cd "$PLAIN" && env -u SUITE_TIER_MODE bash "$TARBALL/scripts/ci/run-shell-tests.sh" "$SCANDIR" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" 'test-trivial\.sh'; then
  pass "26n: tarball runner + scan root outside every tree -> runs (rc 0)"
else
  fail "26n: outside-tree rc=$rc output: $out"
fi

# --- 26l. CDPATH cannot steer the guard's or the resolution's cd (HIMMEL-5111) ---
# The same runner copy, now inside its own work tree. CDPATH=<foreign tree> and a
# relative root named like a dir under it: the cd used to land in the foreign
# tree, so the guard refused (or the scan ran there).
git -C "$TARBALL" init -q
mkdir -p "$TARBALL/cdp-probe" "$FOREIGN/cdp-probe"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TARBALL/cdp-probe/test-trivial.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FOREIGN/cdp-probe/test-trivial.sh"
out=$(cd "$TARBALL" && env -u SUITE_TIER_MODE CDPATH="$FOREIGN" bash "$TARBALL/scripts/ci/run-shell-tests.sh" cdp-probe 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! grepq "$out" 'REFUSED' && grepq "$out" 'cdp-probe/test-trivial\.sh' && ! grepq "$out" "$FOREIGN"; then
  pass "26l: CDPATH=<foreign tree> changes neither the guard's verdict nor the scanned root"
else
  fail "26l: rc=$rc output: $out"
fi
rm -rf "$TARBALL"

# (4) the default scan root is applied before the guard: `cd ""` succeeds in
# place, so a guard run on an empty root checked the cwd, not `scripts`. In the
# runner's own tree the two coincide, so no behavioural row can tell them apart;
# the ordering is a source fact, pinned here.
# shellcheck disable=SC2016  # the patterns are literal source text, not expansions
rootline=$(grep -n '^scan="${scan:-scripts}"' "$RUNNER" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016
guardline=$(grep -n '^_scan_dir=\$(cd "\$scan"' "$RUNNER" | head -1 | cut -d: -f1)
if [ -n "$rootline" ] && [ -n "$guardline" ] && [ "$rootline" -lt "$guardline" ]; then
  pass "26o: the scripts default is applied before the scan-root guard"
else
  fail "26o: default at line '$rootline', guard at line '$guardline'"
fi

rst_tally
