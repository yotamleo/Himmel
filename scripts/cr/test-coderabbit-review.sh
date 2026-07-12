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
if [ -f branch-marker.txt ]; then echo "saw-branch-marker"; fi
if git rev-parse --verify -q main >/dev/null; then echo "saw-base-branch"; fi
if [ -f untracked-secret.txt ]; then echo "LEAKED-untracked-file"; fi
echo "FAKE FINDINGS"
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

# --- T4: timeout rc (124) -> rc=1, timeout-flavored unavailable line ---------
(cd "$repo" && CODERABBIT_BIN="$stubs/coderabbit" STUB_RC=124 \
    bash "$SCRIPT" --branch feat/x --base main >/dev/null 2>"$tmp/t4.err")
rc=$?
[ "$rc" -eq 1 ] && ok "T4 rc=1 on timeout" || bad "T4: rc=$rc (want 1)"
case "$(cat "$tmp/t4.err")" in
    *"panel-availability: coderabbit unavailable (timeout"*) ok "T4 timeout line" ;;
    *) bad "T4: timeout line missing (got: $(cat "$tmp/t4.err"))" ;;
esac

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

echo
if [ "$fail" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "FAILURES PRESENT"
exit 1
