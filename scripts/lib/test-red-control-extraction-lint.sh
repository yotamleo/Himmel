#!/usr/bin/env bash
# scripts/lib/test-red-control-extraction-lint.sh -- unit tests for
# red-control-extraction-lint.sh (HIMMEL-3018), PLUS the repo-wide gate
# itself: T9 below runs the lint over the real scripts/ tree and FAILS the
# suite on any hit. run-shell-tests.sh auto-discovers every test-*.sh under
# scripts/, so this file being red is what makes the class fail CI -- no
# separate wiring needed.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+,
# matching the tool under test -- no .ps1 twin.
#
# Usage: bash scripts/lib/test-red-control-extraction-lint.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LINT="$SCRIPT_DIR/red-control-extraction-lint.sh"

pass=0
fails=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fails=$((fails+1)); echo "  FAIL: $1"; }
has() {
    case "$2" in
        *"$3"*) ok "$1" ;;
        *)      bad "$1 - output did not mention '$3': $2" ;;
    esac
}
lacks() {
    case "$2" in
        *"$3"*) bad "$1 - output unexpectedly mentioned '$3': $2" ;;
        *)      ok "$1" ;;
    esac
}

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/red-control-extraction-lint-test.XXXXXX")" || {
    echo "FATAL: could not create scratch dir" >&2; exit 1; }
trap 'rm -rf "$tmpdir"' EXIT

echo "[test-red-control-extraction-lint] T1 RED: an actual git-show blob extraction is flagged"
fx1="$tmpdir/t1"; mkdir -p "$fx1"
cat > "$fx1/test-sample.sh" <<'EOF'
#!/usr/bin/env bash
git -C "$SCRIPT_DIR/../.." show 6749462a6c22911d748b8a39254fbd86bdf14ece:scripts/hooks/foo.sh > out
EOF
out=$(bash "$LINT" "$fx1"); rc=$?
if [ "$rc" -eq 1 ]; then ok "T1 exits 1 on a hit"; else bad "T1 expected rc=1, got $rc"; fi
has "T1 names the offending file:line" "$out" "test-sample.sh:2"

echo "[test-red-control-extraction-lint] T2 RED: git show with a short (7-char) sha is still flagged"
fx2="$tmpdir/t2"; mkdir -p "$fx2"
cat > "$fx2/test-short.sh" <<'EOF'
#!/usr/bin/env bash
git show 6749462:scripts/foo.sh > out
EOF
out=$(bash "$LINT" "$fx2"); rc=$?
if [ "$rc" -eq 1 ]; then ok "T2 exits 1 on a short-sha hit"; else bad "T2 expected rc=1, got $rc"; fi
has "T2 names the offending file:line" "$out" "test-short.sh:2"

echo "[test-red-control-extraction-lint] T3 a committed-fixture cp extraction is not flagged"
fx3="$tmpdir/t3"; mkdir -p "$fx3"
cat > "$fx3/test-clean.sh" <<'EOF'
#!/usr/bin/env bash
cp "$SCRIPT_DIR/fixtures/red-control/foo.pre-fix.sh" "$dest"
EOF
out=$(bash "$LINT" "$fx3"); rc=$?
if [ "$rc" -eq 0 ]; then ok "T3 exits 0 on a cp-only file"; else bad "T3 expected rc=0, got $rc: $out"; fi

echo "[test-red-control-extraction-lint] T4 a provenance COMMENT naming a git-show extraction is not flagged"
fx4="$tmpdir/t4"; mkdir -p "$fx4"
cat > "$fx4/test-comment.sh" <<'EOF'
#!/usr/bin/env bash
# HIMMEL-3154: this commit's PR branch was deleted on squash-merge, so
# `git show <sha>:<path>` is unreachable from a fresh clone of origin.
# Verified both-direction against `git show 2bab2305:scripts/hooks/block-glm-external-writes.sh`
cp "$SCRIPT_DIR/fixtures/red-control/foo.sh" "$dest"
EOF
out=$(bash "$LINT" "$fx4"); rc=$?
if [ "$rc" -eq 0 ]; then ok "T4 exits 0 when only a comment mentions the pattern"; else bad "T4 expected rc=0, got $rc: $out"; fi

echo "[test-red-control-extraction-lint] T5 a bare *_SHA= label line is not flagged"
fx5="$tmpdir/t5"; mkdir -p "$fx5"
cat > "$fx5/test-label.sh" <<'EOF'
#!/usr/bin/env bash
RC5_PRE_SHA=6749462a6c22911d748b8a39254fbd86bdf14ece
PRE_FIX_SHA=6ac483e4ad49d66e5760a2ea632871bcab029576
EOF
out=$(bash "$LINT" "$fx5"); rc=$?
if [ "$rc" -eq 0 ]; then ok "T5 exits 0 on label-only lines"; else bad "T5 expected rc=0, got $rc: $out"; fi

echo "[test-red-control-extraction-lint] T6 an indented git-show extraction (SHA-named var, real historical shape) is still flagged"
fx6="$tmpdir/t6"; mkdir -p "$fx6"
cat > "$fx6/test-indented.sh" <<'EOF'
#!/usr/bin/env bash
rc4_extract_hook() {
    git -C "$SCRIPT_DIR/../.." show "$PRE_RC4_SHA:scripts/hooks/block-unresolved-cr-merge.sh" \
        > "$1/scripts/hooks/block-unresolved-cr-merge.sh" 2>/dev/null
}
EOF
out=$(bash "$LINT" "$fx6"); rc=$?
if [ "$rc" -eq 1 ]; then ok "T6 exits 1 on an indented hit"; else bad "T6 expected rc=1, got $rc"; fi

echo "[test-red-control-extraction-lint] T6b a refs/checkpoints/<name>:<path> lookup (test-stop-worker.sh, test-clean-garden-accounting.sh shape) is not flagged"
fx6b="$tmpdir/t6b"; mkdir -p "$fx6b"
cat > "$fx6b/test-checkpoint.sh" <<'EOF'
#!/usr/bin/env bash
ckpt=$(git -C "$REPO" show refs/checkpoints/wt-staged-autosave:new-staged-file.txt 2>/dev/null)
EOF
out=$(bash "$LINT" "$fx6b"); rc=$?
if [ "$rc" -eq 0 ]; then ok "T6b exits 0 on a checkpoint ref"; else bad "T6b expected rc=0, got $rc: $out"; fi

echo "[test-red-control-extraction-lint] T6c a HEAD:<path> lookup (test-clean-garden-accounting.sh shape) is not flagged"
fx6c="$tmpdir/t6c"; mkdir -p "$fx6c"
cat > "$fx6c/test-head.sh" <<'EOF'
#!/usr/bin/env bash
git -C "$WT_SONLY" show "HEAD:wt-sonly.txt" > "$WT_SONLY/wt-sonly.txt"
EOF
out=$(bash "$LINT" "$fx6c"); rc=$?
if [ "$rc" -eq 0 ]; then ok "T6c exits 0 on a HEAD: lookup"; else bad "T6c expected rc=0, got $rc: $out"; fi

echo "[test-red-control-extraction-lint] T6d a bare :<path> index-ref lookup (test-restore-to-head.sh shape) is not flagged"
fx6d="$tmpdir/t6d"; mkdir -p "$fx6d"
cat > "$fx6d/test-indexref.sh" <<'EOF'
#!/usr/bin/env bash
[ "$(git -C "$WT" show :link)" = recover-staged ]
EOF
out=$(bash "$LINT" "$fx6d"); rc=$?
if [ "$rc" -eq 0 ]; then ok "T6d exits 0 on a bare :path index ref"; else bad "T6d expected rc=0, got $rc: $out"; fi

echo "[test-red-control-extraction-lint] T6e a branch-ref:<path> lookup is not flagged"
fx6e="$tmpdir/t6e"; mkdir -p "$fx6e"
cat > "$fx6e/test-branchref.sh" <<'EOF'
#!/usr/bin/env bash
git -C "$REPO" show origin/main:scripts/foo.sh > out
EOF
out=$(bash "$LINT" "$fx6e"); rc=$?
if [ "$rc" -eq 0 ]; then ok "T6e exits 0 on a branch ref"; else bad "T6e expected rc=0, got $rc: $out"; fi

echo "[test-red-control-extraction-lint] T7 a non-*.sh file and a non-test-*.sh file are not scanned"
fx7="$tmpdir/t7"; mkdir -p "$fx7"
cat > "$fx7/lib.sh" <<'EOF'
git show 6749462a6c22911d748b8a39254fbd86bdf14ece:scripts/foo.sh > out
EOF
cat > "$fx7/notes.txt" <<'EOF'
git show 6749462a6c22911d748b8a39254fbd86bdf14ece:scripts/foo.sh > out
EOF
out=$(bash "$LINT" "$fx7"); rc=$?
if [ "$rc" -eq 0 ]; then ok "T7 exits 0 (only test-*.sh is walked)"; else bad "T7 expected rc=0, got $rc: $out"; fi

echo "[test-red-control-extraction-lint] T8 --help prints usage and exits 0"
out=$(bash "$LINT" --help); rc=$?
if [ "$rc" -eq 0 ]; then ok "T8 --help exits 0"; else bad "T8 --help expected rc=0, got $rc"; fi
has "T8 prints the usage line" "$out" "Usage: bash scripts/lib/red-control-extraction-lint.sh"

echo "[test-red-control-extraction-lint] T9 the repo-wide gate: the real scripts/ tree is clean"
# Exclude this file itself: its own heredoc fixtures (T1/T2/T6 above) contain
# lines shaped exactly like the pattern this lint flags, on purpose -- a
# self-scan would self-flag them. Every OTHER test-*.sh under scripts/ is the
# real gate surface.
real_files=()
while IFS= read -r f; do
    [ "$f" = "$SCRIPT_DIR/test-red-control-extraction-lint.sh" ] && continue
    real_files+=("$f")
done < <(find "$REPO_ROOT/scripts" -type f -name 'test-*.sh' | sort)
out=$(bash "$LINT" "${real_files[@]}" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
    ok "T9 real tree: 0 hits (this IS the CI gate for the class)"
else
    bad "T9 real tree has hit(s) -- a test suite extracts a RED-control mutant via git show <sha>:<path>; replace with a committed fixtures/red-control/ snapshot: $out"
fi
lacks "T9 the known-safe glm comment is not a false positive" "$out" "test-block-glm-external-writes.sh"

echo
echo "[test-red-control-extraction-lint] $pass passed, $fails failed"
[ "$fails" -eq 0 ]
