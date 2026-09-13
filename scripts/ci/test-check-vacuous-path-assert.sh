#!/usr/bin/env bash
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
#
# Smoke test for scripts/ci/check-vacuous-path-assert.sh (HIMMEL-2957).
#
# RED-first note: before this detector existed, a deliberately naive first
# cut ("flag every PATH= line followed anywhere later by an emptiness
# assertion", no per-command-prefix exclusion, no marker, no subshell
# exclusion) was run against cases B, C, E and G below and wrongly flagged
# all four safe idioms — that false-positive spread is the RED this suite's
# refinement fixes. The shipped detector narrows to exactly the ambient-scope
# shape; this suite pins that narrowing.
#
# Usage: bash scripts/ci/test-check-vacuous-path-assert.sh
#
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

GUARD="$(cd "$(dirname "$0")" && pwd)/check-vacuous-path-assert.sh"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/h2957.XXXXXX") || {
    echo "setup: mktemp -d failed" >&2
    exit 2
}
trap 'rm -rf "$tmp"' EXIT

# Case A: ambient `PATH=$(scrub_path …)` then an emptiness assertion in the
# same (persisted) shell scope -> the real HIMMEL-2812 shape, 1 finding.
echo "== Case A: ambient scrub_path scope -> 1 finding =="
cat > "$tmp/case-a.sh" <<'FIXTURE'
#!/usr/bin/env bash
PATH=$(scrub_path "$PATH" tool)
[ -z "$(tool foo)" ]
FIXTURE
out_a=$(bash "$GUARD" "$tmp/case-a.sh"); rc=$?
if [ "$rc" -eq 1 ]; then pass "case-a -> exit 1"; else fail "case-a -> expected 1 got $rc"; fi
if grep -q 'vacuous-path-assert: emptiness assertion after ambient PATH scrub at line 2' <<< "$out_a"; then
    pass "case-a -> message names the scrub line"
else
    fail "case-a -> message wrong: $out_a"
fi

# Case B: per-command prefix (the codebase's normal SAFE idiom) -> 0 findings.
echo "== Case B: per-command prefix is not ambient -> 0 findings =="
cat > "$tmp/case-b.sh" <<'FIXTURE'
#!/usr/bin/env bash
PATH=/stub bash "$S"
[ -z "$(tool foo)" ]
FIXTURE
bash "$GUARD" "$tmp/case-b.sh" >/dev/null; rc=$?
if [ "$rc" -eq 0 ]; then pass "case-b -> exit 0"; else fail "case-b -> expected 0 got $rc"; fi

# Case C: `env PATH=... cmd` -> 0 findings.
echo "== Case C: env-prefixed invocation -> 0 findings =="
cat > "$tmp/case-c.sh" <<'FIXTURE'
#!/usr/bin/env bash
env PATH=/stub cmd
[ -z "$(tool foo)" ]
FIXTURE
bash "$GUARD" "$tmp/case-c.sh" >/dev/null; rc=$?
if [ "$rc" -eq 0 ]; then pass "case-c -> exit 0"; else fail "case-c -> expected 0 got $rc"; fi

# Case D: the assertion runs BEFORE the scrub -> 0 findings.
echo "== Case D: assertion precedes the scrub -> 0 findings =="
cat > "$tmp/case-d.sh" <<'FIXTURE'
#!/usr/bin/env bash
[ -z "$(tool foo)" ]
export PATH="$STUB:$PATH"
FIXTURE
bash "$GUARD" "$tmp/case-d.sh" >/dev/null; rc=$?
if [ "$rc" -eq 0 ]; then pass "case-d -> exit 0"; else fail "case-d -> expected 0 got $rc"; fi

# Case E: a same-line `# vacuous-path-ok:` marker suppresses the finding.
# CR round 1 (codex-3): the scrub must be a NON-preserving one -- a
# preserving prepend like case G2's is already exempt by pattern A itself,
# so a marker-less version has to independently produce a finding for this
# case to actually prove marker suppression (not just re-prove G2).
echo "== Case E: marker suppresses the finding -> 0 findings =="
cat > "$tmp/case-e.sh" <<'FIXTURE'
#!/usr/bin/env bash
export PATH=$(scrub_path "$PATH" tool)
[ -z "$(tool foo)" ] # vacuous-path-ok: intentional, tool absence is under test
FIXTURE
bash "$GUARD" "$tmp/case-e.sh" >/dev/null; rc=$?
if [ "$rc" -eq 0 ]; then pass "case-e -> exit 0"; else fail "case-e -> expected 0 got $rc"; fi

# Case E2: the SAME fixture with the marker removed must produce a finding --
# proves case E's 0 findings is actually due to marker suppression, not to
# an already-exempt scrub shape.
echo "== Case E2: same fixture without the marker -> 1 finding =="
cat > "$tmp/case-e2.sh" <<'FIXTURE'
#!/usr/bin/env bash
export PATH=$(scrub_path "$PATH" tool)
[ -z "$(tool foo)" ]
FIXTURE
bash "$GUARD" "$tmp/case-e2.sh" >/dev/null; rc=$?
if [ "$rc" -eq 1 ]; then pass "case-e2 -> exit 1"; else fail "case-e2 -> expected 1 got $rc"; fi

# Case F: `export PATH=…` whole-line ambient scrub -> 1 finding.
echo "== Case F: export PATH= whole-line -> 1 finding =="
cat > "$tmp/case-f.sh" <<'FIXTURE'
#!/usr/bin/env bash
export PATH=$(scrub_path "$PATH" tool)
[ -z "$(tool foo)" ]
FIXTURE
bash "$GUARD" "$tmp/case-f.sh" >/dev/null; rc=$?
if [ "$rc" -eq 1 ]; then pass "case-f -> exit 1"; else fail "case-f -> expected 1 got $rc"; fi

# Case G: a one-line ( … ) subshell scopes the scrub to itself -> 0 findings.
echo "== Case G: one-line subshell -> 0 findings =="
cat > "$tmp/case-g.sh" <<'FIXTURE'
#!/usr/bin/env bash
( PATH="$STUB:$PATH"; cmd )
[ -z "$(tool foo)" ]
FIXTURE
bash "$GUARD" "$tmp/case-g.sh" >/dev/null; rc=$?
if [ "$rc" -eq 0 ]; then pass "case-g -> exit 0"; else fail "case-g -> expected 0 got $rc"; fi

# Case G2 (HIMMEL-2957 tree-run false positive): a pure additive prepend that
# verbatim retains $PATH can only ADD entries, never remove one, so no later
# assertion can be made vacuous by it -> 0 findings. This is the real shape
# the whole-tree run found across 4 suites (export PATH="$stub:$PATH").
echo "== Case G2: preserving PATH prepend -> 0 findings =="
cat > "$tmp/case-g2.sh" <<'FIXTURE'
#!/usr/bin/env bash
export PATH="$STUB:$PATH"
[ -z "$(tool foo)" ]
FIXTURE
bash "$GUARD" "$tmp/case-g2.sh" >/dev/null; rc=$?
if [ "$rc" -eq 0 ]; then pass "case-g2 -> exit 0"; else fail "case-g2 -> expected 0 got $rc"; fi

# Case G3 (HIMMEL-2957 self-scan false positive): the vacuous shape appearing
# inside a quoted heredoc BODY is data the enclosing shell writes out, not a
# statement it runs -> 0 findings. This is the real shape this detector's own
# test suite hits when pre-commit scans it (fixtures like case A/F above).
echo "== Case G3: vacuous shape inside a heredoc body -> 0 findings =="
cat > "$tmp/case-g3.sh" <<'FIXTURE'
#!/usr/bin/env bash
cat > "$out" <<'INNER'
PATH=$(scrub_path "$PATH" tool)
[ -z "$(tool foo)" ]
INNER
FIXTURE
bash "$GUARD" "$tmp/case-g3.sh" >/dev/null; rc=$?
if [ "$rc" -eq 0 ]; then pass "case-g3 -> exit 0"; else fail "case-g3 -> expected 0 got $rc"; fi

# Case K (CR round 1, codex-1): a quoted command substitution
# (`PATH="$(scrub_path "$PATH" tool)"`) must still be detected -- the plain
# quoted-string matcher stops at the FIRST embedded quote (the one around
# the inner "$PATH" argument), which used to leave a non-empty remainder
# and silently miss this ambient scrub entirely.
echo "== Case K: quoted command substitution -> 1 finding =="
cat > "$tmp/case-k.sh" <<'FIXTURE'
#!/usr/bin/env bash
PATH="$(scrub_path "$PATH" tool)"
[ -z "$(tool foo)" ]
FIXTURE
bash "$GUARD" "$tmp/case-k.sh" >/dev/null; rc=$?
if [ "$rc" -eq 1 ]; then pass "case-k -> exit 1"; else fail "case-k -> expected 1 got $rc"; fi

# Case L (CR round 1, codex-2): the preservation check must require an
# EXACT $PATH / ${PATH} reference, not merely the substring "PATH" preceded
# by `$`/`${` -- `$PATH_STUB` and `${PATH%:*}` both used to match the old
# unanchored regex and be wrongly treated as preserving, even though
# neither retains the real PATH value.
echo "== Case L: near-miss PATH-like tokens are NOT preserving -> 1 finding each =="
cat > "$tmp/case-l1.sh" <<'FIXTURE'
#!/usr/bin/env bash
export PATH="$PATH_STUB:/stub"
[ -z "$(tool foo)" ]
FIXTURE
bash "$GUARD" "$tmp/case-l1.sh" >/dev/null; rc=$?
if [ "$rc" -eq 1 ]; then pass "case-l1 -> exit 1"; else fail "case-l1 -> expected 1 got $rc"; fi

cat > "$tmp/case-l2.sh" <<'FIXTURE'
#!/usr/bin/env bash
export PATH="${PATH%:*}"
[ -z "$(tool foo)" ]
FIXTURE
bash "$GUARD" "$tmp/case-l2.sh" >/dev/null; rc=$?
if [ "$rc" -eq 1 ]; then pass "case-l2 -> exit 1"; else fail "case-l2 -> expected 1 got $rc"; fi

# Case M (CR round 2, codex-2): a COMMENTED mention of a heredoc redirect
# must not open heredoc state -- before the fix, the unanchored regex
# matched "<<EOF" inside the comment text, silently skipping every real
# line after it (including the ambient scrub + assertion below), so the
# finding would have gone undetected.
echo "== Case M: commented heredoc mention does not suppress detection -> 1 finding =="
cat > "$tmp/case-m.sh" <<'FIXTURE'
#!/usr/bin/env bash
# example: cat <<EOF
PATH=$(scrub_path "$PATH" tool)
[ -z "$(tool foo)" ]
FIXTURE
bash "$GUARD" "$tmp/case-m.sh" >/dev/null; rc=$?
if [ "$rc" -eq 1 ]; then pass "case-m -> exit 1"; else fail "case-m -> expected 1 got $rc"; fi

# Case N (CR round 3, codex-1): a TRAILING comment mentioning a heredoc
# redirect must not open heredoc state either -- only a whole-line comment
# was excluded after round 2; `echo ready # example: cat <<EOF` still
# matched the unanchored regex and silently skipped the real scrub +
# assertion below.
echo "== Case N: trailing-comment heredoc mention does not suppress detection -> 1 finding =="
cat > "$tmp/case-n.sh" <<'FIXTURE'
#!/usr/bin/env bash
echo ready # example: cat <<EOF
PATH=$(scrub_path "$PATH" tool)
[ -z "$(tool foo)" ]
FIXTURE
bash "$GUARD" "$tmp/case-n.sh" >/dev/null; rc=$?
if [ "$rc" -eq 1 ]; then pass "case-n -> exit 1"; else fail "case-n -> expected 1 got $rc"; fi

# Case O (CR round 3, codex-2): a $PATH reference retained WITHOUT a colon
# boundary merges a bogus segment onto the first real entry instead of
# adding a new one -- `PATH="/nonexistent$PATH"` is NOT preserving and
# must still be flagged.
echo "== Case O: no-colon-boundary PATH concatenation IS flagged -> 1 finding =="
cat > "$tmp/case-o.sh" <<'FIXTURE'
#!/usr/bin/env bash
export PATH="/nonexistent$PATH"
[ -z "$(tool foo)" ]
FIXTURE
bash "$GUARD" "$tmp/case-o.sh" >/dev/null; rc=$?
if [ "$rc" -eq 1 ]; then pass "case-o -> exit 1"; else fail "case-o -> expected 1 got $rc"; fi

# Case H: no-args tree walk over the real repo exits 0 or 1, never 2.
echo "== Case H: no-args tree walk exits 0/1, not 2 =="
( cd "$REPO_ROOT" && bash "$GUARD" ) >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    pass "no-args tree walk -> exit $rc (0 or 1)"
else
    fail "no-args tree walk -> expected 0 or 1 got $rc"
fi

# Case I: `.himmel-dev` absent in the invoking repo -> rc 0, gate skipped
# (exactly as check-claude-md-budget.sh does) -- even though the tracked
# fixture WOULD be flagged if the gate actually scanned it.
echo "== Case I: .himmel-dev absent -> gate skip (rc 0) =="
skip_repo="$tmp/skip-repo"
mkdir -p "$skip_repo/scripts"
git init -q "$skip_repo"
cat > "$skip_repo/scripts/test-would-flag.sh" <<'FIXTURE'
#!/usr/bin/env bash
export PATH=$(scrub_path "$PATH" tool)
[ -z "$(tool foo)" ]
FIXTURE
git -C "$skip_repo" add -A
git -C "$skip_repo" -c user.email=test@test -c user.name=test commit -q -m "fixture"
( cd "$skip_repo" && bash "$GUARD" ) >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then
    pass "no .himmel-dev marker -> exit 0 (skip)"
else
    fail "no .himmel-dev marker -> expected 0 got $rc"
fi

# Case J: a missing file passed directly fails closed rather than passing
# vacuously.
echo "== Case J: missing file fails closed =="
bash "$GUARD" "$tmp/nope.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "missing file -> exit 2"; else fail "missing file -> expected 2 got $rc"; fi

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; else echo "$failures FAILURE(S)"; fi
exit $(( failures > 0 ? 1 : 0 ))
