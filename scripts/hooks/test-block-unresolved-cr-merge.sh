#!/usr/bin/env bash
# Tests for scripts/hooks/block-unresolved-cr-merge.sh (HIMMEL-936). Hermetic.
set -uo pipefail

# HIMMEL-1495 — an --automerge-armed launching shell carries ARMAUTOMERGE=1 +
# CR_MERGE_GATE_OK=1 by design; an ambient value in the operator's shell must
# not decide the result (the 34e/34f precedent in test-check-ci.sh,
# generalized). This hook sources cr_merge_gate, which short-circuits to allow
# on CR_MERGE_GATE_OK=1 (cr-merge-gate.sh:166), so without this scrub every CR
# block-case below inherits the bypass and reads rc 0 (the CI-gate-only cases
# still block — the CI gate is independent of CR_MERGE_GATE_OK, HIMMEL-1043).
unset ARMAUTOMERGE CR_MERGE_GATE_OK

# HIMMEL-3142 — a console-spawned leg's own launching shell carries
# HIMMEL_CONSOLE_LEG=1, which arms the new gate-3 console-GO check below. An
# ambient value here (this suite is itself frequently run FROM such a leg)
# would refuse every allow-case below with "no console GO" before gate 3 is
# even under test (same precedent as test-merge-on-green.sh). Gate 3 gets its
# own dedicated cases further down, each setting HIMMEL_CONSOLE_LEG itself.
unset HIMMEL_CONSOLE_LEG

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/block-unresolved-cr-merge.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

# The repo the hook runs IN (HIMMEL-1125). CodeRabbit availability is now a
# repo-scoped, non-versioned git config, and cr_merge_gate only answers for the
# repo it stands in. The fixtures all resolve to PR o/r#42, so the cwd must BE
# o/r and must be armed — otherwise the gate short-circuits to "allow" and every
# block-case below would pass vacuously. Pinned explicitly so the suite cannot
# change meaning with the ambient checkout's config. $HOOK is absolute, so the
# cd is safe.
mkdir -p "$TMP/repo"
git -C "$TMP/repo" init --quiet >/dev/null 2>&1
git -C "$TMP/repo" remote add origin https://github.com/o/r.git
git -C "$TMP/repo" config --local himmel.coderabbit true
cd "$TMP/repo" || { echo "FATAL: cannot cd to the test repo"; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${GH_STUB_LOG:?}"
case "${GH_STUB_MODE:?}" in
  error) exit 1 ;;
esac
# CodeRabbit's review-FRESHNESS query (HIMMEL-1181) — a SEPARATE GraphQL
# query from the reviewThreads one below (both are `gh api graphql`), so this
# is intercepted on QUERY TEXT first. Default 'fresh' (anchored to abc123, the
# fixed head every case here resolves to) so every UNRELATED case is
# unaffected.
#
# Every BOT node carries a non-empty `body` and a non-zero `comments.totalCount`
# on purpose: HIMMEL-1824 taught the reader to DROP empty review shells
# (`chat.auto_reply` and incremental passes mint COMMENTED objects with neither),
# so a bodyless fixture classifies as `none` no matter which oid it names — which
# silently disarmed BOTH arms here (the default `fresh` turned every allow-case
# into a HIMMEL-1374 zero-reviews-ever BLOCK, and `stale` stopped reaching the
# stale-anchor arm at all). Same repair as test-cr-merge-gate.sh in #1763
# (HIMMEL-1974, found 2026-08-20).
case "$*" in
  *"reviews(last:"*)
    case "${GH_STUB_FRESHNESS:-fresh}" in
      fresh) echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"commit":{"oid":"abc123"},"state":"COMMENTED","body":"looks fine","comments":{"totalCount":1}}]}}}}}' ;;
      stale) echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"commit":{"oid":"shaOLD"},"state":"COMMENTED","body":"found something earlier","comments":{"totalCount":2}}]}}}}}' ;;
      fail)  echo "reviews boom" >&2; exit 1 ;;
    esac
    exit 0 ;;
esac
case "$1 $2" in
  "pr view")
    # deadbeef simulates a mis-extracted selector (a value-taking flag's
    # argument) that resolves to no PR - drives the rc=3 re-anchor path.
    [ "${3:-}" = "deadbeef" ] && exit 1
    echo '{"number":42,"headRefOid":"abc123","url":"https://github.com/o/r/pull/42"}' ;;
  "api graphql")
    case "$GH_STUB_MODE" in
      unresolved) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]}}}}}' ;;
      other-author) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"someuser"}}]}}]}}}}}' ;;
      *) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]}}}}}' ;;
    esac ;;
  # CodeRabbit posts NO check-run (HIMMEL-1072) — these carry only the
  # tests/lint/build signal the CI gate reads.
  "api repos/o/r/commits/abc123/check-runs"*)
    case "$GH_STUB_MODE" in
      ci-red)   echo '{"check_runs":[{"name":"tests","status":"completed","conclusion":"failure"}]}' ;;
      ci-green) echo '{"check_runs":[{"name":"tests","status":"completed","conclusion":"success"}]}' ;;
      *)        echo '{"check_runs":[]}' ;;
    esac ;;
  # CodeRabbit's real signal: a commit STATUS with creator identity. Glob the
  # tail — the gates query `/statuses?per_page=100`, and an exact-match arm
  # silently falls through to the `*)` catch-all and degrades the gate open.
  "api repos/o/r/commits/abc123/statuses"*)
    case "$GH_STUB_MODE" in
      inflight)   echo '[{"context":"CodeRabbit","state":"pending","created_at":"2026-07-16T19:08:46Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
      cr-absent)  echo '[]' ;;
      cr-spoofed) echo '[{"context":"CodeRabbit","state":"success","created_at":"2026-07-16T19:10:05Z","creator":{"id":999999,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
      ci-green)   echo '[{"context":"CodeRabbit","state":"success","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}},{"context":"ci","state":"success","created_at":"2026-07-16T19:10:05Z","creator":{"id":1,"login":"ci","type":"Bot"}}]' ;;
      *)          echo '[{"context":"CodeRabbit","state":"success","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
    esac ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# The hook's rc=3 re-anchor resolves the cwd branch - make TMP a repo with a
# named branch so `git -C "$TMP" branch --show-current` yields `trunk`.
git init -q -b trunk "$TMP" 2>/dev/null || git init -q "$TMP"

payload() { # payload <tool_name> <command>
  printf '{"tool_name":"%s","tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$2" "$TMP"
}

pass=0; fail=0
t() { # t <name> <expected-rc> <tool> <command>
  local name="$1" want="$2" tool="$3" cmd="$4" rc=0
  export GH_STUB_LOG="$TMP/calls-$name.log"; : > "$GH_STUB_LOG"
  payload "$tool" "$cmd" | bash "$HOOK" >"$TMP/out-$name" 2>"$TMP/err-$name" || rc=$?
  if [ "$rc" = "$want" ]; then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name (rc=$rc want=$want)"; sed 's/^/  err: /' "$TMP/err-$name"; fi
}

# HIMMEL-1495 hermeticity probe — when this suite re-execs itself under the
# armed bypass env (see the guard at the end), short-circuit here: the startup
# unset has already scrubbed ARMAUTOMERGE/CR_MERGE_GATE_OK, so a CR block
# fixture must STILL block. Exit 0 = scrub held (hook rc EXACTLY 2, the block
# code); any other rc — 0 = the bypass leaked and the hook failed open, else =
# a broken fixture/hook — exits 1 so an errored probe can never falsely
# validate the guard. Keeps the reinvoked copy to ONE hook invocation.
if [ "${HIMMEL_1495_SELF:-0}" = "1" ]; then
    export GH_STUB_LOG="$TMP/armed-probe.log"; : > "$GH_STUB_LOG"
    export GH_STUB_MODE=unresolved
    probe_rc=0
    payload Bash "gh pr merge 42 --squash" | bash "$HOOK" >/dev/null 2>&1 || probe_rc=$?
    [ "$probe_rc" = "2" ] || exit 1
    exit 0
fi

GH_STUB_MODE=unresolved t merge-with-unresolved-blocks   2 Bash "gh pr merge 42 --squash"
GH_STUB_MODE=clean      t merge-clean-allows             0 Bash "gh pr merge 42 --squash"
GH_STUB_MODE=error      t api-error-fails-open           0 Bash "gh pr merge 42 --squash"
# HIMMEL-1072 — the CodeRabbit signal is a commit STATUS on the head SHA. The
# removed `zombie*`/`young` cases here drove the HIMMEL-980 override off a
# CodeRabbit CHECK-RUN that production never emits: the override could not fire,
# and these fixtures were the only place its trigger existed.
GH_STUB_MODE=inflight   t inflight-review-blocks         2 Bash "gh pr merge 42 --squash"
# An unreviewed head must not merge — the #1243 regression.
GH_STUB_MODE=cr-absent  t absent-review-blocks           2 Bash "gh pr merge 42 --squash"
# Identity over display name (HIMMEL-1058).
GH_STUB_MODE=cr-spoofed t spoofed-creator-id-blocks      2 Bash "gh pr merge 42 --squash"
GH_STUB_MODE=other-author t other-author-thread-allows 0 Bash "gh pr merge 42 --squash"
# ── HIMMEL-1181 (B2): review-freshness — the latest bot review's commit
# anchor must match the head SHA, or the merge blocks even though the status
# + thread gates above both already passed (the PR #1273 shape). ──
GH_STUB_MODE=clean GH_STUB_FRESHNESS=stale t freshness-stale-blocks       2 Bash "gh pr merge 42 --squash"
# a broken freshness query is not evidence — fails OPEN, same posture as the
# status/thread/body degrades above.
GH_STUB_MODE=clean GH_STUB_FRESHNESS=fail  t freshness-infra-fails-open   0 Bash "gh pr merge 42 --squash"
# ── HIMMEL-1043: CI-green gate runs SECOND (after the CR gate) ──
# ci-red: CR gate passes (resolved CodeRabbit thread + a success CodeRabbit
# STATUS), but a non-CodeRabbit check-run ("tests") failed -> CI gate
# blocks. ci-green: every check-run green -> merge allowed.
GH_STUB_MODE=ci-red   t merge-over-red-ci-blocks    2 Bash "gh pr merge 42 --squash"
GH_STUB_MODE=ci-green t merge-over-green-ci-allows  0 Bash "gh pr merge 42 --squash"
# CodeRabbit #1230: a CR-gate bypass must NOT disable the independent CI gate.
# A red-CI merge with CR_MERGE_GATE_OK=1 (or CR_PROFILE=none) is STILL blocked
# by the CI gate. (Under the old top early-exit these returned 0 — the bug.)
CR_MERGE_GATE_OK=1 GH_STUB_MODE=ci-red t cr-bypass-still-ci-blocks      2 Bash "gh pr merge 42 --squash"
CR_PROFILE=none    GH_STUB_MODE=ci-red t cr-profile-none-still-ci-blocks 2 Bash "gh pr merge 42 --squash"
GH_STUB_MODE=unresolved t non-merge-passthrough          0 Bash "gh pr view 42"
GH_STUB_MODE=unresolved t string-literal-passthrough     0 Bash "echo \\\"gh pr merge 42\\\""
GH_STUB_MODE=unresolved t powershell-payload-blocks      2 PowerShell "gh pr merge 42 --squash"
GH_STUB_MODE=unresolved t merge-with-repo-flag-blocks    2 Bash "gh pr merge 42 --squash --repo o/r"
GH_STUB_MODE=unresolved t compound-earlier-merge-blocks  2 Bash "git merge main && gh pr merge 42 --squash"
GH_STUB_MODE=unresolved t double-space-merge-blocks      2 Bash "gh  pr  merge 42 --squash"
# codex-adv-1: quoted selector must not dodge the gate (quoted span vanishes,
# gate re-anchors to the cwd branch)
GH_STUB_MODE=unresolved t quoted-selector-blocks         2 Bash "gh pr merge \\\"42\\\" --squash"
# codex-1/coderabbit: a value-taking flag's argument is consumed, the real
# selector still gates
GH_STUB_MODE=unresolved t flag-value-selector-reanchors  2 Bash "gh pr merge --match-head-commit deadbeef 42 --squash"
# coderabbit false-block vector: a merge phrase INSIDE quotes is not a merge
GH_STUB_MODE=unresolved t quoted-merge-text-passthrough  0 Bash "git commit -m \\\"done; gh pr merge 42\\\""
# coderabbit app round: quoted --repo value must not eat the selector (token
# positions preserved by the Q placeholder; bogus repo re-anchors repo-less)
GH_STUB_MODE=unresolved t quoted-repo-value-blocks       2 Bash "gh pr merge --repo \\\"o/r\\\" 42 --squash"
GH_STUB_MODE=unresolved CR_MERGE_GATE_OK=1 t bypass-allows 0 Bash "gh pr merge 42 --squash"
unset CR_MERGE_GATE_OK
GH_STUB_MODE=unresolved CR_PROFILE=none t profile-none-allows 0 Bash "gh pr merge 42 --squash"
unset CR_PROFILE

# ── HIMMEL-3142 gate 3: console-GO merge gate — runs only when
# HIMMEL_CONSOLE_LEG is truthy, after the CR/CI gates above already pass
# (GH_STUB_MODE=clean). Shares scripts/lib/go-gate.sh with
# merge-on-green.sh's own HIMMEL-2919 gate, so the fixture shape (pr=42,
# head=abc123, GO file at <go_root>/.locks/go/<pr>.<head>) mirrors that
# suite's 2919-* cases.
GOROOT="$TMP/handover_root"
mkdir -p "$GOROOT/.locks/go"

# leg + no GO file at all -> refused (the PR #798 shape this ticket exists to close)
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GOROOT" GH_STUB_MODE=clean t leg-no-go-blocks 2 Bash "gh pr merge 42 --squash"

# leg + a GO file for the exact certified head, and the merge command pins
# that exact head -> bound, merge allowed
printf 'pr=42\nhead=abc123\nby=test\nat=now\n' > "$GOROOT/.locks/go/42.abc123"
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GOROOT" GH_STUB_MODE=clean t leg-valid-go-allows 0 Bash "gh pr merge 42 --squash --match-head-commit abc123"

# HIMMEL-3142 CR round: a confirmed GO is bound to $go_sha, but that's only
# THIS hook's own `gh pr view` read -- the merge command that follows is a
# separate invocation and can land a different commit unless it pins one
# itself. Three more cases against the SAME valid-GO fixture above:
# (a) no pin at all -> refused (the gap CodeRabbit found)
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GOROOT" GH_STUB_MODE=clean t leg-valid-go-no-pin-blocks 2 Bash "gh pr merge 42 --squash"
# (b) pin naming a DIFFERENT sha than the GO was bound to -> refused
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GOROOT" GH_STUB_MODE=clean t leg-valid-go-wrong-pin-blocks 2 Bash "gh pr merge 42 --squash --match-head-commit WRONGSHA"
# (c) --match-head-commit=<sha> (the = form; the old parser silently
# discarded it via the --*|-* catch-all instead of capturing it) naming the
# exact certified head -> allowed
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GOROOT" GH_STUB_MODE=clean t leg-valid-go-pin-eq-form-allows 0 Bash "gh pr merge 42 --squash --match-head-commit=abc123"
rm -f "$GOROOT/.locks/go/42.abc123"

# leg + a GO file present but for a DIFFERENT (stale) head -> still refused
printf 'pr=42\nhead=OLDSHA\nby=test\nat=now\n' > "$GOROOT/.locks/go/42.abc123"
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GOROOT" GH_STUB_MODE=clean t leg-stale-go-blocks 2 Bash "gh pr merge 42 --squash"
rm -f "$GOROOT/.locks/go/42.abc123"

# HIMMEL_CONSOLE_LEG=0 is the falsy convention (go.sh/merge-on-green.sh share
# it) -> gate 3 never activates, no GO file needed
HIMMEL_CONSOLE_LEG=0 HANDOVER_DIR="$GOROOT" GH_STUB_MODE=clean t leg-marker-falsy-allows 0 Bash "gh pr merge 42 --squash"

# inversion control: a VALID matching GO file present, marker flipped OFF ->
# still allowed. Discriminates the marker from the go_root/file as the thing
# that gates -- leg-marker-falsy-allows above proves the marker gates when no
# GO file exists at all, but that alone cannot rule out an implementation
# that is really keying off go_root/file presence rather than the marker; a
# GO file genuinely present here removes that ambiguity.
printf 'pr=42\nhead=abc123\nby=test\nat=now\n' > "$GOROOT/.locks/go/42.abc123"
HIMMEL_CONSOLE_LEG=0 HANDOVER_DIR="$GOROOT" GH_STUB_MODE=clean t leg-marker-falsy-with-go-present-allows 0 Bash "gh pr merge 42 --squash"
rm -f "$GOROOT/.locks/go/42.abc123"

# a non-leg session (HIMMEL_CONSOLE_LEG unset, the suite default) is
# completely untouched by gate 3 even with an unresolvable go_root
# (HANDOVER_DIR left unset here) -- "a gate that blocks everything is not a
# gate".
GH_STUB_MODE=clean t non-leg-untouched-by-go-gate 0 Bash "gh pr merge 42 --squash"

grep -qi "no console GO" "$TMP/err-leg-no-go-blocks" || { echo "FAIL leg-no-go reason missing"; fail=$((fail+1)); }
grep -q "42.abc123" "$TMP/err-leg-no-go-blocks" || { echo "FAIL leg-no-go reason missing GO path"; fail=$((fail+1)); }
grep -qi "no console GO" "$TMP/err-leg-stale-go-blocks" || { echo "FAIL leg-stale-go reason missing"; fail=$((fail+1)); }
grep -qi "must pin" "$TMP/err-leg-valid-go-no-pin-blocks" || { echo "FAIL leg-valid-go-no-pin reason missing"; fail=$((fail+1)); }
grep -qi "does not match" "$TMP/err-leg-valid-go-wrong-pin-blocks" || { echo "FAIL leg-valid-go-wrong-pin reason missing"; fail=$((fail+1)); }

# ── HIMMEL-3142 contract item 6: RED control — the pre-fix hook (base
# 6ac483e4, before this ticket) never consulted .locks/go/ at all, so a
# console-spawned leg with no GO file could run `gh pr merge` straight
# through (the PR #798 shape this ticket exists to close). Prove it: extract
# that exact script into a scratch mutant, run the SAME leg-no-go fixture
# leg-no-go-blocks used above against it, and confirm it was allowed (rc=0)
# where the shipped hook (proven by leg-no-go-blocks, above) refuses (rc=2).
export RED_CONTROL_TMPDIR="$TMP"
# shellcheck source=scripts/lib/red-control.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/red-control.sh"

PRE_FIX_SHA=6ac483e4ad49d66e5760a2ea632871bcab029576
PRE_FIX_PAYLOAD="$TMP/red-control-payload.json"
payload Bash "gh pr merge 42 --squash" > "$PRE_FIX_PAYLOAD"

PRE_FIX_ROOT="$TMP/pre-fix-hook"
mkdir -p "$PRE_FIX_ROOT/scripts/hooks" "$PRE_FIX_ROOT/scripts/lib"
git -C "$SCRIPT_DIR/../.." show "$PRE_FIX_SHA:scripts/hooks/block-unresolved-cr-merge.sh" \
    > "$PRE_FIX_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" 2>/dev/null
cp "$SCRIPT_DIR/../lib/cr-merge-gate.sh" "$PRE_FIX_ROOT/scripts/lib/cr-merge-gate.sh"
cp "$SCRIPT_DIR/../lib/ci-green-gate.sh" "$PRE_FIX_ROOT/scripts/lib/ci-green-gate.sh"
# The mutant wrapper always exits 0 itself (it prints the gated hook's rc as
# data rather than propagating it) -- same shape as the RC-3 grep-mutant in
# test-merge-on-green.sh: point (a) "the mutant RAN" is then trivially
# satisfied, so the real evidence is the SPECIFIC printed value (point c),
# which is why this echoes "rc=<n>" to stdout rather than relying on the
# wrapper's own exit status.
cat > "$PRE_FIX_ROOT/run.sh" <<RUNEOF
#!/usr/bin/env bash
bash "$PRE_FIX_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" < "$PRE_FIX_PAYLOAD"
echo "rc=\$?"
RUNEOF
chmod +x "$PRE_FIX_ROOT/run.sh"

if [ ! -s "$PRE_FIX_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" ]; then
    fail=$((fail+1)); echo "FAIL red-control setup: could not extract the pre-fix hook from base $PRE_FIX_SHA"
else
    red_control_run \
        --env HIMMEL_CONSOLE_LEG=1 --env "HANDOVER_DIR=$GOROOT" --env GH_STUB_MODE=clean \
        --env "GH_STUB_LOG=$TMP/calls-red-control-pre.log" \
        -- bash "$PRE_FIX_ROOT/run.sh"
    if red_control_assert --label "HIMMEL-3142-RC" --expect-rc 0 \
        --observed     "$RED_CONTROL_OUT" \
        --expect-wrong "rc=0" \
        --correct      "rc=2" \
        --note "pre-fix block-unresolved-cr-merge.sh (base $PRE_FIX_SHA) had no console-GO gate at all, so it let a console-spawned leg with NO GO file merge straight through; the shipped hook's leg-no-go-blocks case (above, same fixture) refuses it"
    then
        pass=$((pass+1)); echo "ok   red-control-pre-fix-allowed-post-fix-refuses"
    else
        fail=$((fail+1)); echo "FAIL red-control-pre-fix-allowed-post-fix-refuses"
    fi
fi

# ── HIMMEL-3142 CR round: SECOND RED control — the previously-shipped hook
# (head ef6f995a, before the --match-head-commit pin check existed) resolved
# go_num/go_sha and confirmed a GO was bound to that head, but never checked
# the merge command's OWN --match-head-commit value, so a leg with a valid
# GO and no pin at all merged straight through. Prove it: extract that exact
# blob, run the SAME leg-valid-go-no-pin fixture against it, and confirm it
# was allowed (rc=0) where the shipped hook (proven by
# leg-valid-go-no-pin-blocks, above) refuses (rc=2). Deliberately NOT run
# against PRE_FIX_SHA above: that blob predates go-gate.sh entirely, so it
# would fail this fixture for the unrelated reason of having no GO concept
# at all, proving nothing about the pin specifically.
PRE_PIN_SHA=ef6f995aabf01bae0e19a1cefa04de2ae2977d18
PRE_PIN_PAYLOAD="$TMP/red-control-pin-payload.json"
payload Bash "gh pr merge 42 --squash" > "$PRE_PIN_PAYLOAD"

PRE_PIN_ROOT="$TMP/pre-pin-hook"
mkdir -p "$PRE_PIN_ROOT/scripts/hooks" "$PRE_PIN_ROOT/scripts/lib"
git -C "$SCRIPT_DIR/../.." show "$PRE_PIN_SHA:scripts/hooks/block-unresolved-cr-merge.sh" \
    > "$PRE_PIN_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" 2>/dev/null
cp "$SCRIPT_DIR/../lib/cr-merge-gate.sh" "$PRE_PIN_ROOT/scripts/lib/cr-merge-gate.sh"
cp "$SCRIPT_DIR/../lib/ci-green-gate.sh" "$PRE_PIN_ROOT/scripts/lib/ci-green-gate.sh"
cp "$SCRIPT_DIR/../lib/go-gate.sh" "$PRE_PIN_ROOT/scripts/lib/go-gate.sh"
cp "$SCRIPT_DIR/../lib/handover-path.sh" "$PRE_PIN_ROOT/scripts/lib/handover-path.sh"

cat > "$PRE_PIN_ROOT/run.sh" <<RUNEOF
#!/usr/bin/env bash
bash "$PRE_PIN_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" < "$PRE_PIN_PAYLOAD"
echo "rc=\$?"
RUNEOF
chmod +x "$PRE_PIN_ROOT/run.sh"

printf 'pr=42\nhead=abc123\nby=test\nat=now\n' > "$GOROOT/.locks/go/42.abc123"
if [ ! -s "$PRE_PIN_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" ]; then
    fail=$((fail+1)); echo "FAIL red-control setup: could not extract the pre-pin hook from head $PRE_PIN_SHA"
else
    red_control_run \
        --env HIMMEL_CONSOLE_LEG=1 --env "HANDOVER_DIR=$GOROOT" --env GH_STUB_MODE=clean \
        --env "GH_STUB_LOG=$TMP/calls-red-control-pin.log" \
        -- bash "$PRE_PIN_ROOT/run.sh"
    if red_control_assert --label "HIMMEL-3142-PIN-RC" --expect-rc 0 \
        --observed     "$RED_CONTROL_OUT" \
        --expect-wrong "rc=0" \
        --correct      "rc=2" \
        --note "pre-pin block-unresolved-cr-merge.sh (head $PRE_PIN_SHA) confirmed a GO was bound to \$go_sha but never checked the merge command's own --match-head-commit, so a leg with a valid GO and no pin at all merged straight through; the shipped hook's leg-valid-go-no-pin-blocks case (above, same fixture) refuses it"
    then
        pass=$((pass+1)); echo "ok   red-control-pin-pre-fix-allowed-post-fix-refuses"
    else
        fail=$((fail+1)); echo "FAIL red-control-pin-pre-fix-allowed-post-fix-refuses"
    fi
fi
rm -f "$GOROOT/.locks/go/42.abc123"

# passthrough cases must not touch gh at all (coderabbit: assert EVERY one)
for pt in non-merge-passthrough string-literal-passthrough quoted-merge-text-passthrough; do
    [ -s "$TMP/calls-$pt.log" ] && { echo "FAIL $pt called gh"; fail=$((fail+1)); }
done
# block reason surfaces on stderr (hook contract: stderr shown to model+user)
grep -qi "unresolved" "$TMP/err-merge-with-unresolved-blocks" || { echo "FAIL stderr reason missing"; fail=$((fail+1)); }
# HIMMEL-1043: the CI gate's block surfaces with its own prefix on stderr
grep -q "block-red-ci-merge" "$TMP/err-merge-over-red-ci-blocks" || { echo "FAIL ci-block stderr reason missing"; fail=$((fail+1)); }
# HIMMEL-1072: an absent review must say so — "no CodeRabbit status" is the
# actionable half; a bare "blocked" would read as a false-block and get bypassed.
grep -qi "has not reviewed" "$TMP/err-absent-review-blocks" || { echo "FAIL absent-review reason missing"; fail=$((fail+1)); }
# HIMMEL-1181: a stale review's block must name the stale anchor (actionable),
# distinct wording from "has not reviewed" (absent) above.
grep -qi "shaOLD" "$TMP/err-freshness-stale-blocks" || { echo "FAIL freshness-stale reason missing stale anchor"; fail=$((fail+1)); }
grep -qi "never re-reviewed" "$TMP/err-freshness-stale-blocks" || { echo "FAIL freshness-stale reason missing remedy"; fail=$((fail+1)); }
grep -q "block-unresolved-cr-merge" "$TMP/err-freshness-stale-blocks" || { echo "FAIL freshness-stale missing hook prefix"; fail=$((fail+1)); }

# HIMMEL-1495 hermeticity guard — prove the startup scrub holds. Re-run this
# suite in a subprocess EXPORTING the exact armed bypass env an
# --automerge-armed shell carries; the reinvoked copy's startup unset must
# neutralize it, so its probe block-case still blocks and it exits 0. Remove
# the startup `unset ARMAUTOMERGE CR_MERGE_GATE_OK` and the reinvoked copy's
# CR block-case instead fails open (rc 0) and exits non-zero. Recursion-safe:
# the sentinel suppresses the guard in the reinvoked copy.
if [ "${HIMMEL_1495_SELF:-0}" != "1" ]; then
    if CR_MERGE_GATE_OK=1 ARMAUTOMERGE=1 HIMMEL_1495_SELF=1 bash "$SCRIPT_DIR/test-block-unresolved-cr-merge.sh" >"$TMP/armed.log" 2>&1; then
        pass=$((pass+1)); echo "ok   hermetic-to-armed-env (self-reinvoke exits 0)"
    else
        fail=$((fail+1)); echo "FAIL hermetic-to-armed-env (startup scrub missing?)"; sed 's/^/  armed: /' "$TMP/armed.log"
    fi
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
