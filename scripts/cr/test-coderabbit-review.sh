#!/usr/bin/env bash
# Smoke test for scripts/cr/coderabbit-review.sh (HIMMEL-926). Bash 3.2 safe.
# Hermetic: throwaway git repo under mktemp, stub coderabbit binary via
# CODERABBIT_BIN, stub wsl launcher via CODERABBIT_WSL, temp HOME for the
# login-shell lane. Never touches the real HOME, repo, or CodeRabbit account.
# shellcheck disable=SC2015  # A && B || C intentional in the ok/bad asserts
set -uo pipefail
unset CODERABBIT_TIMEOUT_SECS 2>/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/coderabbit-review.sh"
# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/../lib/fixture-tempdir.sh"
tmp="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

# --- Hermetic repo: main + feat/x (adds branch-marker.txt) -------------------
repo="$tmp/repo"
mkdir -p "$repo" || exit 1
(
    fixture_enter_git_init_dir "$repo" || exit 1
    git -c init.defaultBranch=main init -q
    git config user.email t@t.test
    git config user.name tester
    echo base > f.txt
    git add f.txt
    git commit -q -m init
    git checkout -q -b feat/x
    echo marker > branch-marker.txt
    git add branch-marker.txt
    git commit -q -m marker
    git checkout -q main
    # Untracked working-tree file: must NEVER reach the review clone (the
    # committed-state pinning claim — gitignored/untracked secrets stay local).
    echo sekret > untracked-secret.txt
) || exit 1

# --- Stub coderabbit: records args, proves the clone checked out the branch --
stubs="$tmp/stubs"
mkdir -p "$stubs"
cat > "$stubs/coderabbit" <<'STUBEOF'
#!/usr/bin/env bash
[ -n "${STUB_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_LOG"
[ -n "${STUB_STDERR:-}" ] && printf '%s\n' "$STUB_STDERR" >&2
# Attribution tests (HIMMEL-1219): dump the CLONE's .git/config while the clone
# still lives, so a test can prove what origin URL the script wrote to disk
# (and that no embedded credential survived). cwd here is the clone root.
[ -n "${STUB_CONFIG_LOG:-}" ] && cat .git/config >> "$STUB_CONFIG_LOG" 2>/dev/null
if [ -f branch-marker.txt ]; then echo "saw-branch-marker"; fi
if git rev-parse --verify -q main >/dev/null; then echo "saw-base-branch"; fi
if [ -f untracked-secret.txt ]; then echo "LEAKED-untracked-file"; fi
echo "FAKE FINDINGS"
[ -n "${STUB_SLEEP_SECS:-}" ] && exec sleep "$STUB_SLEEP_SECS"
exit "${STUB_RC:-0}"
STUBEOF
chmod +x "$stubs/coderabbit"

# --- T1: CLI absent everywhere -> rc=3, skip note, NO availability line ------
err="$( (cd "$repo" && CODERABBIT_BIN="$tmp/nonexistent-bin" CODERABBIT_WSL="$tmp/nonexistent-wsl" \
    bash "$SCRIPT" --branch feat/x --base main) 2>&1 >/dev/null )"
rc=$?
[ "$rc" -eq 3 ] && ok "T1 rc=3 when CLI absent" || bad "T1: rc=$rc (want 3)"
case "$err" in
    *"coderabbit pass skipped"*) ok "T1 skip note printed" ;;
    *) bad "T1: skip note missing (got: $err)" ;;
esac
case "$err" in
    *"panel-availability"*) bad "T1: availability line printed for unconfigured CLI" ;;
    *) ok "T1 no availability line" ;;
esac


# --- T2: native lane success — real clone+fetch, stub review -----------------
export STUB_LOG="$tmp/stub.log"
: > "$STUB_LOG"
out="$(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" \
    bash "$SCRIPT" --branch feat/x --base main 2>"$tmp/t2.err")"
rc=$?
[ "$rc" -eq 0 ] && ok "T2 rc=0" || bad "T2: rc=$rc (want 0)"
case "$out" in
    *saw-branch-marker*) ok "T2 clone checked out the branch" ;;
    *) bad "T2: branch marker not seen in clone (got: $out)" ;;
esac
case "$out" in
    *saw-base-branch*) ok "T2 base branch fetched into clone" ;;
    *) bad "T2: base branch missing in clone" ;;
esac
case "$out" in
    *LEAKED-untracked-file*) bad "T2: untracked file leaked into review clone" ;;
    *) ok "T2 untracked file excluded from clone" ;;
esac
case "$(cat "$STUB_LOG")" in
    *"review --agent --type committed --base main"*) ok "T2 review args correct" ;;
    *) bad "T2: review args wrong (got: $(cat "$STUB_LOG"))" ;;
esac
case "$(cat "$tmp/t2.err")" in
    *"panel-availability: coderabbit ok"*) ok "T2 availability ok line" ;;
    *) bad "T2: availability ok line missing" ;;
esac

# --- T3: review failure -> rc=1, unavailable line ----------------------------
out="$(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" STUB_RC=7 \
    bash "$SCRIPT" --branch feat/x --base main 2>"$tmp/t3.err")"
rc=$?
[ "$rc" -eq 1 ] && ok "T3 rc=1 on review failure" || bad "T3: rc=$rc (want 1)"
case "$(cat "$tmp/t3.err")" in
    *"panel-availability: coderabbit unavailable (rc=7)"*) ok "T3 unavailable line" ;;
    *) bad "T3: unavailable line missing" ;;
esac

# --- T4: real timeout kill -> rc=1, timeout-flavored unavailable line --------
started="$(date +%s)"
(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" STUB_SLEEP_SECS=10 \
    CODERABBIT_TIMEOUT_SECS=2 \
    bash "$SCRIPT" --branch feat/x --base main >/dev/null 2>"$tmp/t4.err")
rc=$?
elapsed=$(( $(date +%s) - started ))
[ "$rc" -eq 1 ] && ok "T4 rc=1 on timeout" || bad "T4: rc=$rc (want 1)"
case "$(cat "$tmp/t4.err")" in
    *"panel-availability: coderabbit unavailable (timeout"*) ok "T4 timeout line" ;;
    *) bad "T4: timeout line missing (got: $(cat "$tmp/t4.err"))" ;;
esac
[ "$elapsed" -ge 2 ] && [ "$elapsed" -lt 10 ] \
    && ok "T4 real timeout killed stub after ${elapsed}s" \
    || bad "T4: elapsed=${elapsed}s (want >=2 and <10)"

# --- T5: usage guards --------------------------------------------------------
(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" \
    bash "$SCRIPT" --branch main --base main >/dev/null 2>&1)
[ $? -eq 2 ] && ok "T5 branch==base rc=2" || bad "T5: branch==base not refused"
(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" \
    bash "$SCRIPT" --branch 'bad branch' --base main >/dev/null 2>&1)
[ $? -eq 2 ] && ok "T5 whitespace branch rc=2" || bad "T5: whitespace branch not refused"

# --- T6: wsl lane via CODERABBIT_WSL seam ------------------------------------
# Requires CODERABBIT_ALLOW_WSL=1 (HIMMEL-1339 — the wsl lane is opt-in by
# default so the probe itself never boots WSL unasked; see T14/T15 below for
# the default-off behaviour this test's explicit opt-in bypasses).
# Fake wsl: drops the -e flag and execs the rest under a PATH that carries the
# coderabbit stub + a passthrough wslpath (so a C:/ src on a Windows test host
# resolves; Git Bash git accepts C:/ paths directly).
cat > "$stubs/wslpath" <<'WPEOF'
#!/usr/bin/env bash
printf '%s\n' "${2:-$1}"
WPEOF
chmod +x "$stubs/wslpath"
# No PATH injection here — the stub PATH must arrive via the login-shell
# profile below, proving the wrapper's `bash -lc` lane resolves ~/.local-style
# installs (coderabbit CR round on HIMMEL-926).
cat > "$tmp/fake-wsl" <<'FAKEWSLEOF'
#!/usr/bin/env bash
[ "${1:-}" = "-e" ] && shift
# The real wsl.exe call needs MSYS conversion disabled while Git Bash hands it
# the inner script. This shell seam is not that native boundary: if it keeps
# those flags, the inner Git-for-Windows clone leaves /tmp/... unconverted and
# creates the checkout somewhere other than the fixture's $tmp/repo path.
unset MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
exec "$@"
FAKEWSLEOF
chmod +x "$tmp/fake-wsl"
fake_home="$tmp/home"
mkdir -p "$fake_home"
# shellcheck disable=SC2016  # literal $PATH belongs in the written profile
printf 'export PATH="%s:$PATH"\n' "$stubs" > "$fake_home/.bash_profile"
: > "$STUB_LOG"
out="$(cd "$repo" && HOME="$fake_home" CODERABBIT_BIN=coderabbit CODERABBIT_WSL="$tmp/fake-wsl" \
    CODERABBIT_ALLOW_WSL=1 \
    PATH="$(dirname "$(command -v git)"):/usr/bin:/bin" \
    bash "$SCRIPT" --branch feat/x --base main 2>"$tmp/t6.err")"
rc=$?
[ "$rc" -eq 0 ] && ok "T6 wsl lane rc=0" || bad "T6: rc=$rc (want 0; err: $(cat "$tmp/t6.err"))"
case "$out" in
    *saw-branch-marker*) ok "T6 wsl lane clone checked out the branch" ;;
    *) bad "T6: branch marker not seen (got: $out)" ;;
esac
case "$(cat "$tmp/t6.err")" in
    *"panel-availability: coderabbit ok"*) ok "T6 availability ok line" ;;
    *) bad "T6: availability ok line missing" ;;
esac

# --- T7: rate-limit text -> rc=4 (distinct from generic failure rc=1; HIMMEL-1219)
# Same stub rc=1 a real 429 masquerades as, but the CLI text reveals it. Proves
# detection + that no findings leak to stdout (a rate-limited reviewer produced
# nothing valid) + that availability is recorded unavailable, never ok.
out="$(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" STUB_RC=1 \
    STUB_STDERR="Error: rate limit exceeded - too many requests, retry later" \
    bash "$SCRIPT" --branch feat/x --base main 2>"$tmp/t7.err")"
rc=$?
[ "$rc" -eq 4 ] && ok "T7 rc=4 on rate-limit text" || bad "T7: rc=$rc (want 4)"
case "$out" in
    "") ok "T7 no findings on stdout (rate-limit review produced nothing valid)" ;;
    *) bad "T7: findings leaked to stdout on rate-limit (got: $out)" ;;
esac
case "$(cat "$tmp/t7.err")" in
    *"coderabbit pass rate-limited"*) ok "T7 retry-later note printed" ;;
    *) bad "T7: retry-later note missing (got: $(cat "$tmp/t7.err"))" ;;
esac
case "$(cat "$tmp/t7.err")" in
    *"panel-availability: coderabbit unavailable (rc=4)"*) ok "T7 unavailable (rc=4) line" ;;
    *) bad "T7: unavailable (rc=4) line missing" ;;
esac
case "$(cat "$tmp/t7.err")" in
    *"panel-availability: coderabbit ok"*) bad "T7: ok line printed on rate-limit (would clear the marker on a review that never ran)" ;;
    *) ok "T7 no ok line on rate-limit" ;;
esac

# --- T8: normal failure (no rate-limit text) still rc=1, NOT misclassified -----
# Discriminator: identical stub rc=1 as T7, but a generic error message. Must
# stay a generic failure (rc=1, unavailable rc=1) and NOT be elevated to rc=4.
out="$(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" STUB_RC=1 \
    STUB_STDERR="Error: review failed - authentication required" \
    bash "$SCRIPT" --branch feat/x --base main 2>"$tmp/t8.err")"
rc=$?
[ "$rc" -eq 1 ] && ok "T8 rc=1 on normal failure (not misclassified as rate-limit)" || bad "T8: rc=$rc (want 1)"
case "$(cat "$tmp/t8.err")" in
    *"panel-availability: coderabbit unavailable (rc=1)"*) ok "T8 unavailable (rc=1) line" ;;
    *) bad "T8: unavailable (rc=1) line missing (got: $(cat "$tmp/t8.err"))" ;;
esac
case "$(cat "$tmp/t8.err")" in
    *"coderabbit pass rate-limited"*) bad "T8: rate-limit note printed on a normal failure" ;;
    *) ok "T8 no rate-limit note on normal failure" ;;
esac
# stdout must stay clean on a generic failure too (same invariant T7/T12 assert
# for the rate-limit / timeout paths): a non-zero review_rc routes review_out to
# stderr, so a failed review never leaks partial output as findings (HIMMEL-1219).
case "$out" in
    "") ok "T8 no findings on stdout (generic failure keeps stdout clean)" ;;
    *) bad "T8: findings leaked to stdout on generic failure (got: $out)" ;;
esac

# --- T12: timeout that is REALLY rate-limiting -> rc=4, not a silent timeout ---
# The round-4 MAJOR-1 fix. A review killed by the timeout WHILE the CLI was
# emitting rate-limit text must surface as rc=4 (a MISSING signal), NOT rc=124
# (a generic timeout the caller fails open on). Before the fix this path
# returned BEFORE the rate-limit grep AND discarded both captured streams, so a
# rate-limited hang was indistinguishable from a slow one AND yielded zero
# diagnostics - the exact silent-fail-open shape HIMMEL-1219 exists to kill.
# The stub sleeps past the 2s timeout with rate-limit text on stderr, so the
# inner script sees rc=124 + rate-limit text and must re-classify rc=4. Also
# asserts both captured streams reach the caller (the stub's rate-limit line is
# visible) and stdout stays clean (findings cat'd to stderr as debug only).
started="$(date +%s)"
out="$(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" \
    STUB_STDERR="Error: rate limit exceeded - too many requests, retry later" \
    STUB_SLEEP_SECS=10 CODERABBIT_TIMEOUT_SECS=2 \
    bash "$SCRIPT" --branch feat/x --base main 2>"$tmp/t12.err")"
rc=$?
elapsed=$(( $(date +%s) - started ))
[ "$rc" -eq 4 ] && ok "T12 rc=4 on timeout-while-rate-limited (not silent rc=1/124)" \
    || bad "T12: rc=$rc (want 4)"
[ "$elapsed" -ge 2 ] && [ "$elapsed" -lt 10 ] \
    && ok "T12 real timeout killed stub after ${elapsed}s" \
    || bad "T12: elapsed=${elapsed}s (want >=2 and <10)"
case "$out" in
    "") ok "T12 no findings on stdout (streams kept stderr-only)" ;;
    *) bad "T12: findings leaked to stdout on timeout (got: $out)" ;;
esac
case "$(cat "$tmp/t12.err")" in
    *"rate limit exceeded"*) ok "T12 captured stderr emitted (not discarded on timeout)" ;;
    *) bad "T12: stub stderr missing - streams discarded on timeout (got: $(cat "$tmp/t12.err"))" ;;
esac
case "$(cat "$tmp/t12.err")" in
    *"coderabbit pass rate-limited"*) ok "T12 retry-later note printed" ;;
    *) bad "T12: retry-later note missing (got: $(cat "$tmp/t12.err"))" ;;
esac
case "$(cat "$tmp/t12.err")" in
    *"panel-availability: coderabbit unavailable (rc=4)"*) ok "T12 unavailable (rc=4) line" ;;
    *) bad "T12: unavailable (rc=4) line missing (got: $(cat "$tmp/t12.err"))" ;;
esac
case "$(cat "$tmp/t12.err")" in
    *"panel-availability: coderabbit unavailable (timeout"*) bad "T12: classified as timeout (rate-limit masked)" ;;
    *) ok "T12 not classified as timeout" ;;
esac
case "$(cat "$tmp/t12.err")" in
    *"panel-availability: coderabbit ok"*) bad "T12: ok line printed on rate-limited timeout" ;;
    *) ok "T12 no ok line on rate-limited timeout" ;;
esac

# --- Attribution helpers (HIMMEL-1219) ----------------------------------------
# The clone-origin rewrite is the fix: CodeRabbit matches a review to an org by
# reading origin's URL. Spin a fresh primary checkout (main + feat/x, cloned from
# the hermetic repo so the branch graph is reusable) with a configurable origin,
# then read back the CLONE's .git/config (captured by the stub above while the
# clone still lived). Reading the file directly is hermetic and authoritative -
# no `git remote get-url` insteadOf rewriting can mask what is on disk.
make_src_repo() {
    local _dst="$1" _origin="$2"
    git clone -q "$repo" "$_dst"
    # A plain clone only materializes a local ref for the HEAD branch (main);
    # feat/x lands at refs/remotes/origin/feat/x. The script clones with
    # --branch feat/x, which needs refs/heads/feat/x - recreate it before the
    # script runs (do this while origin still exists, so the ref resolves).
    git -C "$_dst" branch -q feat/x refs/remotes/origin/feat/x
    if [ -n "$_origin" ]; then
        git -C "$_dst" remote set-url origin "$_origin" 2>/dev/null \
            || git -C "$_dst" remote add origin "$_origin"
    else
        git -C "$_dst" remote remove origin 2>/dev/null || true
    fi
}
config_origin_url() {
    sed -n 's/^[[:space:]]*url[[:space:]]*=[[:space:]]*//p' "$1" | head -n1
}
STUB_CONFIG_LOG="$tmp/stub-config.log"

# --- T9: clean HTTPS origin is copied verbatim to the clone -------------------
: > "$STUB_CONFIG_LOG"
src_clean="$tmp/src-clean"
make_src_repo "$src_clean" "https://github.com/example/repo.git"
(cd "$src_clean" && CODERABBIT_BIN="$stubs/coderabbit" STUB_CONFIG_LOG="$STUB_CONFIG_LOG" \
    bash "$SCRIPT" --branch feat/x --base main >/dev/null 2>"$tmp/t9.err")
rc=$?
[ "$rc" -eq 0 ] && ok "T9 rc=0 with clean upstream origin" || bad "T9: rc=$rc (want 0; err: $(cat "$tmp/t9.err"))"
clone_url="$(config_origin_url "$STUB_CONFIG_LOG")"
[ "$clone_url" = "https://github.com/example/repo.git" ] \
    && ok "T9 clone origin rewritten to the upstream URL" \
    || bad "T9: clone origin not the upstream URL (got: $clone_url)"

# --- T10: primary checkout with NO origin still completes; note printed -------
: > "$STUB_CONFIG_LOG"
src_noorigin="$tmp/src-noorigin"
make_src_repo "$src_noorigin" ""
(cd "$src_noorigin" && CODERABBIT_BIN="$stubs/coderabbit" STUB_CONFIG_LOG="$STUB_CONFIG_LOG" \
    bash "$SCRIPT" --branch feat/x --base main >/dev/null 2>"$tmp/t10.err")
rc=$?
[ "$rc" -eq 0 ] && ok "T10 rc=0 with no origin (attribution skipped, review proceeds)" \
    || bad "T10: rc=$rc (want 0; err: $(cat "$tmp/t10.err"))"
case "$(cat "$tmp/t10.err")" in
    *"primary checkout has no origin remote"*) ok "T10 no-origin note printed" ;;
    *) bad "T10: no-origin note missing (got: $(cat "$tmp/t10.err"))" ;;
esac
clone_url="$(config_origin_url "$STUB_CONFIG_LOG")"
case "$clone_url" in
    *"github.com"*) bad "T10: clone origin rewritten despite no upstream (got: $clone_url)" ;;
    *) ok "T10 clone origin left as the local path (no upstream to set)" ;;
esac

# --- T11: credentialed HTTPS origin is written WITHOUT credentials ------------
# THE security-critical case (HIMMEL-1219): a user:token@ origin must never
# reach the temp clone's .git/config. Assert both that the bare URL is written
# AND that the secret is absent from the WHOLE config dump.
: > "$STUB_CONFIG_LOG"
src_cred="$tmp/src-cred"
make_src_repo "$src_cred" "https://exampleuser:ghp_TOKENSECRET@github.com/example/repo.git"
(cd "$src_cred" && CODERABBIT_BIN="$stubs/coderabbit" STUB_CONFIG_LOG="$STUB_CONFIG_LOG" \
    bash "$SCRIPT" --branch feat/x --base main >/dev/null 2>"$tmp/t11.err")
rc=$?
[ "$rc" -eq 0 ] && ok "T11 rc=0 with credentialed origin" || bad "T11: rc=$rc (want 0; err: $(cat "$tmp/t11.err"))"
clone_url="$(config_origin_url "$STUB_CONFIG_LOG")"
[ "$clone_url" = "https://github.com/example/repo.git" ] \
    && ok "T11 clone origin stripped to bare HTTPS" \
    || bad "T11: clone origin not stripped to bare HTTPS (got: $clone_url)"
if grep -q 'TOKENSECRET' "$STUB_CONFIG_LOG"; then
    bad "T11: CREDENTIAL LEAKED into clone .git/config (url: $clone_url)"
else
    ok "T11 no credential in clone .git/config"
fi

# --- T13 (HIMMEL-1314): CODERABBIT_CLI_DISABLE=1 skips the CLI leg -----------
# rc 3 is the not-configured/skip contract (no availability line), and the run
# must NOT shell out to the lane probe: on Windows that probe boots the WSL
# distro, which is the cost this switch exists to avoid. A wsl stub that logs
# every invocation proves the probe never ran.
src_dis="$tmp/src-disable"
make_src_repo "$src_dis" "https://github.com/example/repo.git"
WSL_CALL_LOG="$tmp/wsl-calls.log"
: > "$WSL_CALL_LOG"
cat > "$stubs/wsl-probe-spy" <<EOF
#!/usr/bin/env bash
echo "invoked: \$*" >> "$WSL_CALL_LOG"
exit 1
EOF
chmod +x "$stubs/wsl-probe-spy"

(cd "$src_dis" && CODERABBIT_CLI_DISABLE=1 CODERABBIT_BIN="$stubs/coderabbit" \
    CODERABBIT_WSL="$stubs/wsl-probe-spy" \
    bash "$SCRIPT" --branch feat/x --base main >"$tmp/t13.out" 2>"$tmp/t13.err")
rc=$?
[ "$rc" -eq 3 ] && ok "T13 CODERABBIT_CLI_DISABLE=1 exits 3 (skip)" \
    || bad "T13: rc=$rc (want 3; err: $(cat "$tmp/t13.err"))"
grep -q 'CODERABBIT_CLI_DISABLE=1' "$tmp/t13.err" \
    && ok "T13 skip note names the operator opt-out" \
    || bad "T13: skip note does not name the opt-out (got: $(cat "$tmp/t13.err"))"
# No availability line — a deliberate opt-out is not a critic drop-out.
grep -q '^panel-availability:' "$tmp/t13.err" \
    && bad "T13: emitted a panel-availability line on a skip" \
    || ok "T13 no availability line on skip"
[ -s "$WSL_CALL_LOG" ] \
    && bad "T13: lane probe ran despite the opt-out (would boot WSL): $(cat "$WSL_CALL_LOG")" \
    || ok "T13 lane probe never ran (WSL not booted)"
# Guard the exact-"1" contract: any other value leaves the CLI enabled.
(cd "$src_dis" && CODERABBIT_CLI_DISABLE=0 CODERABBIT_BIN="$stubs/coderabbit" \
    bash "$SCRIPT" --branch feat/x --base main >/dev/null 2>"$tmp/t13b.err")
rc=$?
[ "$rc" -eq 0 ] && ok "T13b CODERABBIT_CLI_DISABLE=0 still reviews" \
    || bad "T13b: rc=$rc (want 0; err: $(cat "$tmp/t13b.err"))"
# T13c: an explicitly EMPTY live value is a deliberate "leave the CLI on"
# override and must beat a .env that says 1 — the "a live env value wins"
# contract. Guards the set-ness (+x) test: with `:-` an empty live value read as
# unset, the bridge loaded .env's 1, and the CLI was skipped against the
# operator's explicit instruction. A real .env carrying the flag is planted in
# the repo the script resolves as its primary checkout.
printf 'CODERABBIT_CLI_DISABLE=1\n' > "$src_dis/.env"
(cd "$src_dis" && CODERABBIT_CLI_DISABLE='' CODERABBIT_BIN="$stubs/coderabbit" \
    bash "$SCRIPT" --branch feat/x --base main >/dev/null 2>"$tmp/t13c.err")
rc=$?
[ "$rc" -eq 0 ] \
    && ok "T13c empty live value beats .env=1 (CLI still reviews)" \
    || bad "T13c: rc=$rc (want 0 — empty live override lost to .env; err: $(cat "$tmp/t13c.err"))"
# Control: with NO live value at all, the same .env DOES disable the CLI —
# proving T13c passed because the override won, not because the bridge is dead.
(cd "$src_dis" && env -u CODERABBIT_CLI_DISABLE CODERABBIT_BIN="$stubs/coderabbit" \
    bash "$SCRIPT" --branch feat/x --base main >/dev/null 2>"$tmp/t13d.err")
rc=$?
[ "$rc" -eq 3 ] \
    && ok "T13d unset live value lets .env=1 disable the CLI (bridge works)" \
    || bad "T13d: rc=$rc (want 3; err: $(cat "$tmp/t13d.err"))"
rm -f "$src_dis/.env"

# --- T14/T15 (HIMMEL-1339): the WSL lane is opt-IN, not opt-out -------------
# T14: no native binary, wsl.exe present, CODERABBIT_ALLOW_WSL explicitly
# empty — set-but-empty both skips the script's .env bridge and fails its =1
# check, so the test is isolated from an inherited opt-in or a checkout .env.
# The lane probe (which would boot the distro) must never run, and the skip
# note must name the opt-in. Reuses T13's wsl-probe-spy stub to prove no
# invocation.
: > "$WSL_CALL_LOG"
out="$(cd "$repo" && CODERABBIT_BIN="$tmp/nonexistent-bin" \
    CODERABBIT_WSL="$stubs/wsl-probe-spy" \
    CODERABBIT_ALLOW_WSL='' \
    bash "$SCRIPT" --branch feat/x --base main >"$tmp/t14.out" 2>"$tmp/t14.err")"
rc=$?
[ "$rc" -eq 3 ] && ok "T14 rc=3 when WSL lane not opted in" || bad "T14: rc=$rc (want 3)"
grep -q 'CODERABBIT_ALLOW_WSL=1' "$tmp/t14.err" \
    && ok "T14 skip note names the opt-in" \
    || bad "T14: skip note does not name CODERABBIT_ALLOW_WSL (got: $(cat "$tmp/t14.err"))"
[ -s "$WSL_CALL_LOG" ] \
    && bad "T14: WSL probe ran despite no opt-in (would boot WSL): $(cat "$WSL_CALL_LOG")" \
    || ok "T14 WSL probe never ran (WSL not booted)"

# T15: CODERABBIT_ALLOW_WSL=1 (live env) lets the wsl lane run — control,
# proving T14 failed because of the missing opt-in, not a broken wsl lane.
: > "$STUB_LOG"
out="$(cd "$repo" && HOME="$fake_home" CODERABBIT_BIN=coderabbit CODERABBIT_WSL="$tmp/fake-wsl" \
    CODERABBIT_ALLOW_WSL=1 \
    PATH="$(dirname "$(command -v git)"):/usr/bin:/bin" \
    bash "$SCRIPT" --branch feat/x --base main 2>"$tmp/t15.err")"
rc=$?
[ "$rc" -eq 0 ] && ok "T15 CODERABBIT_ALLOW_WSL=1 lets the wsl lane run" \
    || bad "T15: rc=$rc (want 0; err: $(cat "$tmp/t15.err"))"
case "$out" in
    *saw-branch-marker*) ok "T15 wsl lane reached the review" ;;
    *) bad "T15: wsl lane did not run (got: $out)" ;;
esac

# --- T16/T17 (HIMMEL-1175): --head pins the review to the caller's SHA -------
# /pr-check captures branch+HEAD up front and stamps its ledger rows with that
# SHA, but this wrapper reviewed whatever refs/heads/<branch> pointed at when it
# ran — so a checkout that moved mid-run got the new code reviewed and the old
# SHA certified. T16: a matching pin is transparent. T17: a branch tip that moved
# past the pin REFUSES (rc=5) without spending a CodeRabbit call.
pin_head="$(git -C "$repo" rev-parse feat/x)"
: > "$STUB_LOG"
out="$(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" \
    bash "$SCRIPT" --branch feat/x --base main --head "$pin_head" 2>"$tmp/t16.err")"
rc=$?
[ "$rc" -eq 0 ] && ok "T16 matching --head pin lets the review run" \
    || bad "T16: rc=$rc (want 0; err: $(cat "$tmp/t16.err"))"
case "$out" in
    *saw-branch-marker*) ok "T16 pinned run reviewed the pinned branch" ;;
    *) bad "T16: review never reached the clone (got: $out)" ;;
esac

(
    cd "$repo" || exit 1
    git checkout -q feat/x
    echo moved > moved-after-capture.txt
    git add moved-after-capture.txt
    git commit -q -m moved
    git checkout -q main
) || exit 1
: > "$STUB_LOG"
(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" \
    bash "$SCRIPT" --branch feat/x --base main --head "$pin_head" >"$tmp/t17.out" 2>"$tmp/t17.err")
rc=$?
[ "$rc" -eq 5 ] && ok "T17 rc=5 when the branch moved past the pin" \
    || bad "T17: rc=$rc (want 5; err: $(cat "$tmp/t17.err"))"
grep -q 'REFUSING' "$tmp/t17.err" && grep -q "the checkout moved since the caller captured its inputs" "$tmp/t17.err" \
    && ok "T17 refusal explains the stale pin" \
    || bad "T17: refusal message missing (got: $(cat "$tmp/t17.err"))"
grep -q 'panel-availability' "$tmp/t17.err" \
    && bad "T17: availability line emitted for a review that never ran" \
    || ok "T17 no availability line (nothing was reviewed)"
[ -s "$STUB_LOG" ] \
    && bad "T17: the CodeRabbit CLI was invoked despite the stale pin" \
    || ok "T17 CLI never invoked (no scarce call spent)"

# T18: a revision EXPRESSION is not a pin — `HEAD` and branch names resolve
# dynamically, so they would follow the very checkout move the pin exists to
# catch. Rejected at parse time as a usage error.
(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" \
    bash "$SCRIPT" --branch feat/x --base main --head HEAD >/dev/null 2>"$tmp/t18.err")
rc=$?
[ "$rc" -eq 2 ] && ok "T18 --head HEAD rejected as a usage error" || bad "T18: rc=$rc (want 2)"
grep -q 'not a revision expression' "$tmp/t18.err" \
    && ok "T18 rejection says why" \
    || bad "T18: rejection message missing (got: $(cat "$tmp/t18.err"))"

# T19: 97 is the INNER script's clone-time pin-mismatch code, but no exit code is
# reserved — the CodeRabbit CLI can return 97 too. The wrapper classifies on the
# MARKER the inner script drops, never on the code (panel r7): the CLI cannot
# write that marker, so a 97 carrying none is an ordinary review failure and must
# fail OPEN (rc=1 + an availability row), never a refusal that aborts /pr-check.
pin_now="$(git -C "$repo" rev-parse feat/x)"
: > "$STUB_LOG"
(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" STUB_RC=97 \
    bash "$SCRIPT" --branch feat/x --base main --head "$pin_now" >/dev/null 2>"$tmp/t19.err")
rc=$?
[ "$rc" -eq 1 ] && ok "T19 CLI exit 97 with a matching pin fails open (rc=1)" \
    || bad "T19: rc=$rc (want 1; err: $(cat "$tmp/t19.err"))"
grep -q 'panel-availability: coderabbit unavailable (rc=97)' "$tmp/t19.err" \
    && ok "T19 availability row still recorded" \
    || bad "T19: availability line missing (got: $(cat "$tmp/t19.err"))"
grep -q 'not a pin mismatch' "$tmp/t19.err" \
    && ok "T19 says why it is not a refusal" \
    || bad "T19: disambiguation note missing (got: $(cat "$tmp/t19.err"))"

# T20: the same CLI exit 97 on an UNPINNED run. --head is optional, so a run
# that never asked for a pin must never be classified as a pin mismatch — it
# fails open like any other CLI failure. (An earlier fix classified on the exit
# code plus the branch tip and got this backwards, refusing every unpinned 97.)
(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" STUB_RC=97 \
    bash "$SCRIPT" --branch feat/x --base main >/dev/null 2>"$tmp/t20.err")
rc=$?
[ "$rc" -eq 1 ] && ok "T20 unpinned CLI exit 97 fails open (rc=1)" \
    || bad "T20: rc=$rc (want 1; err: $(cat "$tmp/t20.err"))"
grep -q 'panel-availability: coderabbit unavailable (rc=97)' "$tmp/t20.err" \
    && ok "T20 unpinned 97 still records availability" \
    || bad "T20: availability line missing (got: $(cat "$tmp/t20.err"))"
grep -q 'REFUSED' "$tmp/t20.err" \
    && bad "T20: unpinned run reported a pin refusal" \
    || ok "T20 no pin refusal on an unpinned run"

# --- T21-T23 (HIMMEL-1984): --base-sha pins the OTHER end of the range -------
# --head froze the branch tip, but the base was still whatever refs/heads/<base>
# pointed at when the inner clone fetched it — so a base branch that moved
# between the caller's capture and this review changed the reviewed diff while
# the head pin kept passing. T21: a matching base pin is transparent. T22: a
# base that moved past the pin REFUSES (rc=5) without spending a CodeRabbit call.
pin_base="$(git -C "$repo" rev-parse main)"
pin_head_now="$(git -C "$repo" rev-parse feat/x)"
: > "$STUB_LOG"
out="$(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" \
    bash "$SCRIPT" --branch feat/x --base main --head "$pin_head_now" --base-sha "$pin_base" 2>"$tmp/t21.err")"
rc=$?
[ "$rc" -eq 0 ] && ok "T21 matching --base-sha pin lets the review run" \
    || bad "T21: rc=$rc (want 0; err: $(cat "$tmp/t21.err"))"
case "$out" in
    *saw-branch-marker*) ok "T21 base-pinned run reached the review" ;;
    *) bad "T21: review never reached the clone (got: $out)" ;;
esac

# The base branch moves on past the captured SHA — the race the base pin exists
# for. The branch tip is untouched, so the HEAD pin still passes: only the base
# pin can catch this.
(
    cd "$repo" || exit 1
    git checkout -q main
    echo "base moved after capture" > base-moved.txt
    git add base-moved.txt
    git commit -q -m "base moved"
) || exit 1
: > "$STUB_LOG"
(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" \
    bash "$SCRIPT" --branch feat/x --base main --head "$pin_head_now" --base-sha "$pin_base" >"$tmp/t22.out" 2>"$tmp/t22.err")
rc=$?
[ "$rc" -eq 5 ] && ok "T22 rc=5 when the base branch moved past the pin" \
    || bad "T22: rc=$rc (want 5; err: $(cat "$tmp/t22.err"))"
grep -q 'REFUSING' "$tmp/t22.err" && grep -q 'the base branch moved since the caller captured its inputs' "$tmp/t22.err" \
    && ok "T22 refusal explains the stale base pin" \
    || bad "T22: refusal message missing (got: $(cat "$tmp/t22.err"))"
grep -q 'panel-availability' "$tmp/t22.err" \
    && bad "T22: availability line emitted for a review that never ran" \
    || ok "T22 no availability line (nothing was reviewed)"
[ -s "$STUB_LOG" ] \
    && bad "T22: the CodeRabbit CLI was invoked despite the stale base pin" \
    || ok "T22 CLI never invoked (no scarce call spent)"

# T23: same as T18 for the base half — a revision expression follows the very
# move the pin exists to catch, so it is rejected at parse time.
(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" \
    bash "$SCRIPT" --branch feat/x --base main --base-sha main >/dev/null 2>"$tmp/t23.err")
rc=$?
[ "$rc" -eq 2 ] && ok "T23 --base-sha main rejected as a usage error" || bad "T23: rc=$rc (want 2)"
grep -q 'not a revision expression' "$tmp/t23.err" \
    && ok "T23 rejection says why" \
    || bad "T23: rejection message missing (got: $(cat "$tmp/t23.err"))"

# T24: --base-sha WITHOUT --head. The two pins are independent flags, and this
# shape puts an unset value in the MIDDLE of the inner script's positional args
# — the arrangement that must not shift the refusal-channel path into the head
# pin. A base-only pinned run reviews normally.
pin_base_now="$(git -C "$repo" rev-parse main)"
: > "$STUB_LOG"
out="$(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" \
    bash "$SCRIPT" --branch feat/x --base main --base-sha "$pin_base_now" 2>"$tmp/t24.err")"
rc=$?
[ "$rc" -eq 0 ] && ok "T24 --base-sha without --head runs" \
    || bad "T24: rc=$rc (want 0; err: $(cat "$tmp/t24.err"))"
case "$out" in
    *saw-branch-marker*) ok "T24 base-only pinned run reached the review" ;;
    *) bad "T24: review never reached the clone (got: $out)" ;;
esac
grep -q 'REFUSED' "$tmp/t24.err" \
    && bad "T24: base-only pin misread as a refusal" \
    || ok "T24 no spurious pin refusal"

# --- T25 (HIMMEL-2321): self-write findings into the CR ledger via
# ledger-append.sh --batch-file, so /pr-check step 4.5 never retypes
# CodeRabbit finding text into a shell fence. Real schema (confirmed against
# scripts/cr/test-pr-check-external.sh, the same --agent JSONL stream this
# script relays): {"type":"finding","severity":"critical|major|minor",
# "fileName":"<path>","codegenInstructions":"<text>"} -- no line field, so
# the ledger row always carries an empty line. Severity mapping
# (.claude/commands/pr-check.md step 3.2, HIMMEL-926): critical->crit,
# major->imp, minor->sug; a missing severity maps to imp (conservative --
# still blocking, never silently downgraded to a non-blocking Suggestion).
stub_ledger="$stubs/coderabbit-ledger"
cat > "$stub_ledger" <<'STUBEOF'
#!/usr/bin/env bash
cat <<'JSONL'
{"type":"status","phase":"analyzing","status":"reviewing"}
{"type":"finding","severity":"critical","fileName":"src/a.js","codegenInstructions":"the script's rc is unchecked"}
{"type":"finding","severity":"major","fileName":"src/b.js","codegenInstructions":"a major bug"}
{"type":"finding","severity":"minor","fileName":"src/c.js","codegenInstructions":"a nit"}
{"type":"finding","fileName":"src/d.js","codegenInstructions":"no severity field at all"}
{"type":"complete","status":"review_completed","findings":4}
JSONL
exit 0
STUBEOF
chmod +x "$stub_ledger"

HEAD25="$(cd "$repo" && git rev-parse feat/x)"
LEDGER25="$tmp/ledger25.jsonl"; : > "$LEDGER25"
out="$(cd "$repo" && CODERABBIT_BIN="$stub_ledger" CR_LEDGER="$LEDGER25" \
    bash "$SCRIPT" --branch feat/x --base main --head "$HEAD25" 2>"$tmp/t25.err")"
rc=$?
[ "$rc" -eq 0 ] && ok "T25 rc=0" || bad "T25: rc=$rc (want 0; err: $(cat "$tmp/t25.err"))"
case "$out" in
    *"the script's rc is unchecked"*) ok "T25 stdout still carries the raw JSONL verbatim (self-write is additive)" ;;
    *) bad "T25: stdout changed (got: $out)" ;;
esac
[ "$(wc -l < "$LEDGER25" | tr -d ' ')" = "4" ] \
    && ok "T25 wrote 4 finding rows (one per JSONL finding line)" \
    || bad "T25: wrong row count (got $(wc -l < "$LEDGER25" | tr -d ' '))"
sevs="$(node -e 'const fs=require("fs");console.log(fs.readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse).map(r=>r.finding_id+":"+r.severity).join(","))' "$LEDGER25")"
[ "$sevs" = "coderabbit-1:crit,coderabbit-2:imp,coderabbit-3:sug,coderabbit-4:imp" ] \
    && ok "T25 severity mapping + sequential ids (critical->crit, major->imp, minor->sug, missing->imp)" \
    || bad "T25: severity/id mapping wrong (got: $sevs)"
all_lines_empty="$(node -e 'const fs=require("fs");console.log(fs.readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse).every(r=>r.line===""))' "$LEDGER25")"
[ "$all_lines_empty" = "true" ] && ok "T25 line always empty (the real schema has no line field)" || bad "T25: a row carries a non-empty line"
all_verdicts_empty="$(node -e 'const fs=require("fs");console.log(fs.readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse).every(r=>r.verdict===""))' "$LEDGER25")"
[ "$all_verdicts_empty" = "true" ] && ok "T25 verdict left empty for the session to adjudicate" || bad "T25: a row already carries a verdict"

# --- T26 (HIMMEL-2321 acceptance bar): the apostrophe break, demonstrated,
# then the fix, demonstrated, then the round-trip. --------------------------
#
# THE BREAK: the runbook pastes reviewer text into a SINGLE-quoted shell
# fence (pr-check.md step 4.5's finding call, step 4.6's --text call — same
# quoting contract). A finding title containing an apostrophe breaks OUT of
# the surrounding quotes. Demonstrated in a sandbox: build the fence text the
# same way a session would (paste the literal title between single quotes in
# a command string), then let a real shell PARSE it — no payload does
# anything beyond touching a marker file inside this test's own $tmp.
finding_title="the script's rc is unchecked"
marker="$tmp/t26-marker"; rm -f "$marker"
old_fence_cmd="printf '%s\n' '$finding_title'; touch '$marker'"
broken_output="$(bash -c "$old_fence_cmd" 2>&1)"
broken_rc=$?
if [ "$broken_rc" -eq 0 ] && [ "$broken_output" = "$finding_title" ]; then
    bad "T26: the single-quote fence did NOT break on an apostrophe (rc=$broken_rc, got: $broken_output) -- the break precondition this test relies on no longer holds"
else
    ok "T26 break demonstrated: single-quoted fence mis-parses an apostrophe title (rc=$broken_rc, parsed as: $broken_output)"
fi
[ -f "$marker" ] && bad "T26: the touch after the broken quote still ran -- expected the parse error to abort the whole command" \
    || ok "T26 break confirmed structurally: the mis-parse aborts before the trailing command ever runs"

# THE FIX: the SAME apostrophe title, through the producer self-write path --
# never transits a shell fence (built via node/JSON.stringify, not string
# substitution into a command line).
LEDGER26="$tmp/ledger26.jsonl"; : > "$LEDGER26"
stub_apos="$stubs/coderabbit-apos"
cat > "$stub_apos" <<STUBEOF2
#!/usr/bin/env bash
cat <<JSONL
{"type":"finding","severity":"critical","fileName":"src/a.js","codegenInstructions":"$finding_title"}
{"type":"complete","status":"review_completed","findings":1}
JSONL
exit 0
STUBEOF2
chmod +x "$stub_apos"
HEAD26="$(cd "$repo" && git rev-parse feat/x)"
(cd "$repo" && CODERABBIT_BIN="$stub_apos" CR_LEDGER="$LEDGER26" \
    bash "$SCRIPT" --branch feat/x --base main --head "$HEAD26" >/dev/null 2>"$tmp/t26.err")
rc=$?
[ "$rc" -eq 0 ] && ok "T26 fix: producer self-write rc=0" || bad "T26: rc=$rc (want 0; err: $(cat "$tmp/t26.err"))"
stored_text="$(node -e 'const fs=require("fs");const o=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse)[0];console.log(o.text)' "$LEDGER26")"
[ "$stored_text" = "$finding_title" ] \
    && ok "T26 fix: apostrophe title lands byte-exact in the ledger (never transited a shell fence)" \
    || bad "T26: text corrupted (got: $stored_text)"

# ROUND-TRIP (ticket acceptance bar, future runbook shape): the session-side
# step needs only the id and a closed-vocabulary verdict -- no reviewer text.
CR_LEDGER="$LEDGER26" bash "$HERE/ledger-append.sh" amend --head "$HEAD26" --id coderabbit-1 --set verdict=agreed --reason 'fixed literal' >/dev/null 2>"$tmp/t26-amend.err"
rc=$?
[ "$rc" -eq 0 ] && ok "T26 round-trip: amend by id + closed-vocabulary verdict only succeeds" || bad "T26: round-trip amend failed (err: $(cat "$tmp/t26-amend.err"))"
final_verdict="$(node -e 'const fs=require("fs");const rs=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse);console.log(rs[rs.length-1].set.verdict)' "$LEDGER26")"
[ "$final_verdict" = "agreed" ] && ok "T26 round-trip: final ledger state carries the adjudicated verdict" || bad "T26: final verdict wrong (got: $final_verdict)"

# BACK-COMPAT: today's UNMODIFIED runbook still calls the single-row
# `finding --verdict` shape at step 4.5 (no --text — pr-check.md is out of
# this ticket fence). It must converge via ledger-append.sh's verdict-only
# auto-amend, not refuse as "different content" (the ledger-append.sh fix
# under test).
LEDGER26B="$tmp/ledger26b.jsonl"; : > "$LEDGER26B"
(cd "$repo" && CODERABBIT_BIN="$stub_apos" CR_LEDGER="$LEDGER26B" \
    bash "$SCRIPT" --branch feat/x --base main --head "$HEAD26" >/dev/null 2>/dev/null)
CR_LEDGER="$LEDGER26B" bash "$HERE/ledger-append.sh" finding --branch feat/x --head "$HEAD26" \
    --model coderabbit --id coderabbit-1 --severity crit --file 'src/a.js' --line '' \
    --verdict agreed >/dev/null 2>"$tmp/t26b.err"
rc=$?
[ "$rc" -eq 0 ] && ok "T26 back-compat: today's session-side finding --verdict call converges (no refusal)" || bad "T26: back-compat call refused (err: $(cat "$tmp/t26b.err"))"
final_state="$(node -e 'const fs=require("fs");const rs=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse);console.log(rs.filter(r=>r.kind==="finding").length+","+rs.filter(r=>r.kind==="amend").length)' "$LEDGER26B")"
[ "$final_state" = "1,1" ] && ok "T26 back-compat: one finding row + one amend (never a duplicate/refused write)" || bad "T26: unexpected ledger shape (got: $final_state)"

# --- T27 (HIMMEL-2321 codex-2 CR round 1): byte-exact stdout on a successful
# review, MULTIPLE trailing newlines. The old capture shape
# (REVIEW_STDOUT="$(...)" then printf '%s\n' "$REVIEW_STDOUT") strips every
# trailing newline via command substitution and adds back exactly one,
# corrupting a reviewer stream that legitimately ends in more than one.
# Fixed by redirecting straight to a file and `cat`ing it - no shell text
# processing at all. Compared by byte COUNT (wc -c), not string equality:
# a bash $(...) capture in the TEST ITSELF would reintroduce the very
# stripping this test exists to catch.
stub_multinl="$stubs/coderabbit-multinl"
printf '#!/usr/bin/env bash\nprintf '"'"'{"type":"finding","severity":"critical","fileName":"a.js","codegenInstructions":"x"}\\n\\n\\n'"'"'\nexit 0\n' > "$stub_multinl"
chmod +x "$stub_multinl"
raw_bytes="$("$stub_multinl" | wc -c | tr -d ' ')"
(cd "$repo" && CODERABBIT_BIN="$stub_multinl" bash "$SCRIPT" --branch feat/x --base main > "$tmp/t27.out" 2>"$tmp/t27.err")
rc=$?
[ "$rc" -eq 0 ] && ok "T27 rc=0" || bad "T27: rc=$rc (want 0; err: $(cat "$tmp/t27.err"))"
got_bytes="$(wc -c < "$tmp/t27.out" | tr -d ' ')"
[ "$got_bytes" = "$raw_bytes" ] \
    && ok "T27 stdout byte-exact with multiple trailing newlines (raw=$raw_bytes got=$got_bytes)" \
    || bad "T27: byte count differs (raw=$raw_bytes got=$got_bytes) - trailing newlines were normalized"

# --- T28 (HIMMEL-2321 codex-2 CR round 1): byte-exact stdout on a successful
# review, ZERO trailing newlines. The old shape's `printf '%s\n'` ADDS one
# even when the reviewer emitted none. Same byte-count comparison as T27.
stub_nonl="$stubs/coderabbit-nonl"
printf '#!/usr/bin/env bash\nprintf '"'"'{"type":"finding","severity":"critical","fileName":"a.js","codegenInstructions":"y"}'"'"'\nexit 0\n' > "$stub_nonl"
chmod +x "$stub_nonl"
raw_bytes2="$("$stub_nonl" | wc -c | tr -d ' ')"
(cd "$repo" && CODERABBIT_BIN="$stub_nonl" bash "$SCRIPT" --branch feat/x --base main > "$tmp/t28.out" 2>"$tmp/t28.err")
rc=$?
[ "$rc" -eq 0 ] && ok "T28 rc=0" || bad "T28: rc=$rc (want 0; err: $(cat "$tmp/t28.err"))"
got_bytes2="$(wc -c < "$tmp/t28.out" | tr -d ' ')"
[ "$got_bytes2" = "$raw_bytes2" ] \
    && ok "T28 stdout byte-exact with zero trailing newlines (raw=$raw_bytes2 got=$got_bytes2)" \
    || bad "T28: byte count differs (raw=$raw_bytes2 got=$got_bytes2) - a trailing newline was added"

# --- CR round 1 note (codex-1, Important, verified and NOT reproduced):
# "capturing stdout and printing only inside rc==0 suppresses stdout on
# failed reviews, whereas the previous direct invocation surfaced it
# regardless of exit status." Empirically checked against the pre-ticket
# blob, the previously-committed blob, AND this fixed code: on a NONZERO
# review exit, scripts/cr/coderabbit-review.sh's own embedded INNER script
# (the "review --agent" wrapper, unchanged by HIMMEL-2321) routes review_out
# to STDERR, never stdout, in ALL three - "not valid findings - keep stdout
# clean" is pre-existing, deliberate INNER behavior this ticket never
# touched. A reviewer that prints findings and then exits non-zero has NEVER
# surfaced them on real stdout, before or after this ticket; asserting so
# here would pin a false premise. The redirect-to-file refactor is kept
# anyway (T27/T28 above) because it removes the wrapper's OWN redundant
# rc==0 gate and is provably correct on the byte-exactness axis regardless.

# --- T29 (HIMMEL-2321 CR round 3, codex-1, HIMMEL-1175 head-drift class):
# an UNPINNED run (no --head) must never fall back to a post-hoc
# `git rev-parse refs/heads/$BRANCH` for the self-write - that resolves the
# branch tip AFTER the review returns, so a commit landing DURING the review
# silently re-keys findings onto a commit the reviewer never saw. The self-
# write must skip instead, exactly like any other unresolvable-head case.
#
# RED-FIRST: the stub CLI itself lands a concurrent commit on the PRIMARY
# checkout's feat/x branch WHILE "reviewing" (simulating a push racing the
# review), so the pre-round-3 code's post-hoc resolve sees a DIFFERENT
# commit than the one the clone actually reviewed. This test asserts NO
# ledger row is written at all for an unpinned run.
stub_drift="$stubs/coderabbit-drift"
cat > "$stub_drift" <<'STUBEOF'
#!/usr/bin/env bash
echo '{"type":"finding","severity":"critical","fileName":"a.js","codegenInstructions":"drift check"}'
# The primary checkout stays on main throughout (this script only ever
# clones it, never switches its checkout), so a commit landed without
# specifying the branch would land on main, not feat/x. Target feat/x
# directly via a throwaway worktree-free branch move: checkout, commit,
# restore - this only touches ref state, not the (unrelated) working tree.
git -C "$DRIFT_REPO" checkout -q feat/x
git -C "$DRIFT_REPO" commit -q --allow-empty -m "concurrent commit lands during the review (T29)"
git -C "$DRIFT_REPO" checkout -q main
exit 0
STUBEOF
chmod +x "$stub_drift"
PRE_TIP="$(git -C "$repo" rev-parse feat/x)"
LEDGER29="$tmp/ledger29.jsonl"; : > "$LEDGER29"
out="$(cd "$repo" && DRIFT_REPO="$repo" CODERABBIT_BIN="$stub_drift" CR_LEDGER="$LEDGER29" \
    bash "$SCRIPT" --branch feat/x --base main 2>"$tmp/t29.err")"
rc=$?
POST_TIP="$(git -C "$repo" rev-parse feat/x)"
[ "$rc" -eq 0 ] && ok "T29 rc=0" || bad "T29: rc=$rc (want 0; err: $(cat "$tmp/t29.err"))"
[ "$PRE_TIP" != "$POST_TIP" ] && ok "T29 setup: the concurrent commit actually landed (drift is real)" \
    || bad "T29: setup broken - feat/x did not advance, this test proves nothing"
case "$out" in
    *"drift check"*) ok "T29 stdout unaffected (self-write is a side effect only)" ;;
    *) bad "T29: stdout missing the finding (got: $out)" ;;
esac
case "$(cat "$tmp/t29.err")" in
    *"no --head pin"*) ok "T29 warns that an unpinned run cannot prove what it reviewed" ;;
    *) bad "T29: missing the no-pin warning (got: $(cat "$tmp/t29.err"))" ;;
esac
[ "$(wc -l < "$LEDGER29" | tr -d ' ')" = "0" ] \
    && ok "T29 NO ledger row written for an unpinned run (no stale-head stamp)" \
    || bad "T29: a row was written despite no --head pin (got: $(cat "$LEDGER29"))"

# --- T30 (HIMMEL-2321 CR round 3, codex-3): the stdout relay must not
# swallow a `cat` failure. Do NOT change the exit-code contract
# coderabbit-gate.sh consumes - a warning on stderr is the right shape.
# Forced with a fake `cat` on PATH that fails ONLY for the
# `coderabbit-stdout.*` relay file this ticket's mktemp creates (matched by
# basename pattern) and passes every other file through to the REAL cat
# unchanged - so INNER's own review_out/review_err handling
# (a completely different mktemp template, inside the throwaway clone) is
# untouched, and only the ONE relay call this finding is about is exercised.
# The real cat is RESOLVED from PATH and baked into the shim rather than
# hardcoded: it is /usr/bin/cat on Linux but /bin/cat on macOS, and a shim
# that exec'd a nonexistent path would fail for EVERY file, turning this
# case into a false pass (the warning would fire for the wrong reason).
fakecat_dir="$tmp/fakecat"
mkdir -p "$fakecat_dir"
real_cat="$(command -v cat)"
[ -n "$real_cat" ] && [ -x "$real_cat" ] \
    && ok "T30 setup: resolved the real cat at $real_cat" \
    || bad "T30: cannot resolve an executable cat on PATH - the shim would fail for every file"
cat > "$fakecat_dir/cat" <<STUBEOF
#!/usr/bin/env bash
case "\$1" in
    *coderabbit-stdout.*) exit 1 ;;
    *) exec "$real_cat" "\$@" ;;
esac
STUBEOF
chmod +x "$fakecat_dir/cat"
out="$(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" PATH="$fakecat_dir:$PATH" \
    bash "$SCRIPT" --branch feat/x --base main 2>"$tmp/t30.err")"
rc=$?
[ "$rc" -eq 0 ] && ok "T30 exit code unchanged despite the cat failure (still the review's own rc)" \
    || bad "T30: rc=$rc (want 0 - a relay failure must not change the review's own exit-code contract)"
case "$(cat "$tmp/t30.err")" in
    *"WARNING - failed to relay"*) ok "T30 cat failure is surfaced on stderr, not swallowed" ;;
    *) bad "T30: cat failure was silent (got: $(cat "$tmp/t30.err"))" ;;
esac
# T30 is also the LOST-FINDINGS case (HIMMEL-2321 CR round 1, codex-1): it runs
# UNPINNED, so the ledger self-write is skipped for want of a --head, and the
# relay just failed - the findings reached neither stdout nor the ledger. rc
# stays 0 (the contract coderabbit-gate.sh consumes never moves), so the
# availability line is the only honest channel left: `ok` here would let
# clear-cr-marker.sh gate 3 certify a review nobody can read.
case "$(cat "$tmp/t30.err")" in
    *"panel-availability: coderabbit unavailable (rc=0) reason=relay-lost"*)
        ok "T30 findings lost with no ledger fallback -> reviewer recorded unavailable, not ok" ;;
    *) bad "T30: findings reached neither stdout nor the ledger, yet the availability line was not downgraded (got: $(cat "$tmp/t30.err"))" ;;
esac
case "$(cat "$tmp/t30.err")" in
    *"panel-availability: coderabbit ok"*) bad "T30: recorded the reviewer ok on a run whose findings were lost" ;;
    *) ok "T30 no ok line on a lost-findings run" ;;
esac

# --- T31 (HIMMEL-2321 CR round 1, codex-1): NEGATIVE CONTROL for T30. Same
# relay failure, but the run is PINNED and the ledger is writable, so the
# self-write DID persist the findings. They are readable - just not on stdout -
# so the reviewer is still `ok` and the marker may still clear on it. This is
# what keeps the T30 downgrade narrow: it fires on findings that reached
# NOWHERE, never on a relay failure alone.
LEDGER31="$tmp/ledger31.jsonl"; : > "$LEDGER31"
HEAD31="$(cd "$repo" && git rev-parse feat/x)"
out="$(cd "$repo" && CODERABBIT_BIN="$stub_apos" CR_LEDGER="$LEDGER31" PATH="$fakecat_dir:$PATH" \
    bash "$SCRIPT" --branch feat/x --base main --head "$HEAD31" 2>"$tmp/t31.err")"
rc=$?
[ "$rc" -eq 0 ] && ok "T31 rc=0 (unchanged)" || bad "T31: rc=$rc (want 0; err: $(cat "$tmp/t31.err"))"
[ "$(wc -l < "$LEDGER31" | tr -d ' ')" != "0" ] \
    && ok "T31 setup: the ledger self-write actually persisted the findings" \
    || bad "T31: setup broken - nothing in the ledger, so this proves nothing about the fallback"
case "$(cat "$tmp/t31.err")" in
    *"WARNING - failed to relay"*) ok "T31 setup: the relay really did fail" ;;
    *) bad "T31: setup broken - the relay did not fail, so the negative control is vacuous (got: $(cat "$tmp/t31.err"))" ;;
esac
case "$(cat "$tmp/t31.err")" in
    *"reason=relay-lost"*) bad "T31: downgraded to unavailable even though the ledger holds the findings" ;;
    *"panel-availability: coderabbit ok"*) ok "T31 ledger fallback covered the lost relay -> reviewer stays ok" ;;
    *) bad "T31: no availability line at all (got: $(cat "$tmp/t31.err"))" ;;
esac

echo
if [ "$fail" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "FAILURES PRESENT"
exit 1
