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
tmp="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf $tmp" EXIT
fail=0

ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

# --- Hermetic repo: main + feat/x (adds branch-marker.txt) -------------------
repo="$tmp/repo"
git -c init.defaultBranch=main init -q "$repo"
(
    cd "$repo" || exit 1
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
)

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
exec "$@"
FAKEWSLEOF
chmod +x "$tmp/fake-wsl"
fake_home="$tmp/home"
mkdir -p "$fake_home"
# shellcheck disable=SC2016  # literal $PATH belongs in the written profile
printf 'export PATH="%s:$PATH"\n' "$stubs" > "$fake_home/.bash_profile"
: > "$STUB_LOG"
out="$(cd "$repo" && HOME="$fake_home" CODERABBIT_BIN=coderabbit CODERABBIT_WSL="$tmp/fake-wsl" \
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
make_src_repo "$src_clean" "https://github.com/yotamleo/himmel-private.git"
(cd "$src_clean" && CODERABBIT_BIN="$stubs/coderabbit" STUB_CONFIG_LOG="$STUB_CONFIG_LOG" \
    bash "$SCRIPT" --branch feat/x --base main >/dev/null 2>"$tmp/t9.err")
rc=$?
[ "$rc" -eq 0 ] && ok "T9 rc=0 with clean upstream origin" || bad "T9: rc=$rc (want 0; err: $(cat "$tmp/t9.err"))"
clone_url="$(config_origin_url "$STUB_CONFIG_LOG")"
[ "$clone_url" = "https://github.com/yotamleo/himmel-private.git" ] \
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
make_src_repo "$src_cred" "https://yotamleo:ghp_TOKENSECRET@github.com/yotamleo/himmel-private.git"
(cd "$src_cred" && CODERABBIT_BIN="$stubs/coderabbit" STUB_CONFIG_LOG="$STUB_CONFIG_LOG" \
    bash "$SCRIPT" --branch feat/x --base main >/dev/null 2>"$tmp/t11.err")
rc=$?
[ "$rc" -eq 0 ] && ok "T11 rc=0 with credentialed origin" || bad "T11: rc=$rc (want 0; err: $(cat "$tmp/t11.err"))"
clone_url="$(config_origin_url "$STUB_CONFIG_LOG")"
[ "$clone_url" = "https://github.com/yotamleo/himmel-private.git" ] \
    && ok "T11 clone origin stripped to bare HTTPS" \
    || bad "T11: clone origin not stripped to bare HTTPS (got: $clone_url)"
if grep -q 'TOKENSECRET' "$STUB_CONFIG_LOG"; then
    bad "T11: CREDENTIAL LEAKED into clone .git/config (url: $clone_url)"
else
    ok "T11 no credential in clone .git/config"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "FAILURES PRESENT"
exit 1
