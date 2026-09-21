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
# HIMMEL-3360 (operator ruling 2026-09-21): CodeRabbit's commit-status state is
# advisory only. The removed `zombie*`/`young` cases here drove the HIMMEL-980
# override off a CodeRabbit CHECK-RUN that production never emits; the
# HIMMEL-1072 `pending`/`absent`/identity-mismatch BLOCK cases they replaced
# are themselves demoted below — only the thread + body-findings gates still
# block a merge.
GH_STUB_MODE=inflight   t inflight-review-allows         0 Bash "gh pr merge 42 --squash"
# An unreviewed head no longer blocks a merge on its own — the #1243
# regression fixture, but HIMMEL-3360 supersedes HIMMEL-1072's stance.
GH_STUB_MODE=cr-absent  t absent-review-allows           0 Bash "gh pr merge 42 --squash"
# Identity over display name (HIMMEL-1058): still resolves to `absent`, still
# advisory only.
GH_STUB_MODE=cr-spoofed t spoofed-creator-id-allows      0 Bash "gh pr merge 42 --squash"
GH_STUB_MODE=other-author t other-author-thread-allows 0 Bash "gh pr merge 42 --squash"
# HIMMEL-3360: the review-FRESHNESS mechanism (HIMMEL-1181) is removed from
# cr-merge-gate.sh entirely — a stale-anchored review object no longer blocks.
# Regression pin: allow, and the freshness endpoint is never even queried.
GH_STUB_MODE=clean GH_STUB_FRESHNESS=stale t freshness-stale-no-longer-blocks 0 Bash "gh pr merge 42 --squash"
grep -qi "reviews(last:" "$TMP/calls-freshness-stale-no-longer-blocks.log" && { echo "FAIL freshness-stale-no-longer-blocks still queries the removed freshness endpoint"; fail=$((fail+1)); }
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

# HIMMEL-3154: extracted via `git show <sha>:<path>` until this ticket. A
# historical PR-branch commit is only reachable while its PR stays open; once
# squash-merged the branch commit is unreachable from a fresh clone forever,
# so the extraction silently produced an empty file in CI while a developer's
# stale local checkout still had the object loose and stayed green. Replaced
# with a committed fixture snapshot (frozen at commit 6ac483e4, still a live
# main ancestor and not actually affected by that bug, but converted here too
# for consistency with the other fixtures in this directory).
PRE_FIX_SHA=6ac483e4ad49d66e5760a2ea632871bcab029576
PRE_FIX_PAYLOAD="$TMP/red-control-payload.json"
payload Bash "gh pr merge 42 --squash" > "$PRE_FIX_PAYLOAD"

PRE_FIX_ROOT="$TMP/pre-fix-hook"
mkdir -p "$PRE_FIX_ROOT/scripts/hooks" "$PRE_FIX_ROOT/scripts/lib"
cp "$SCRIPT_DIR/fixtures/red-control/block-unresolved-cr-merge.pre-fix.sh" \
    "$PRE_FIX_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" 2>/dev/null
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
# HIMMEL-3154: this commit's PR branch was deleted on squash-merge, so
# `git show <sha>:<path>` is unreachable from a fresh clone of origin — see
# the note on the PRE_FIX_SHA extraction above. Replaced with a committed
# fixture snapshot.
PRE_PIN_SHA=ef6f995aabf01bae0e19a1cefa04de2ae2977d18
PRE_PIN_PAYLOAD="$TMP/red-control-pin-payload.json"
payload Bash "gh pr merge 42 --squash" > "$PRE_PIN_PAYLOAD"

PRE_PIN_ROOT="$TMP/pre-pin-hook"
mkdir -p "$PRE_PIN_ROOT/scripts/hooks" "$PRE_PIN_ROOT/scripts/lib"
cp "$SCRIPT_DIR/fixtures/red-control/block-unresolved-cr-merge.pre-pin.sh" \
    "$PRE_PIN_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" 2>/dev/null
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

# ── HIMMEL-3142 CR round 3: THIRD RED control — both callers tested
# `[ "$go_rc" = "2" ]`, enumerating go_gate's one documented refusal code
# instead of enforcing "nonzero = failure". A go-gate.sh that sources cleanly
# (rc=0) but never DEFINES go_gate (truncated) makes the later call fail with
# "command not found" (go_rc=127), which is != "2" — so the pre-fix hook fell
# through the guard entirely and reached the pin check using go_sha from its
# OWN gh pr view read, not from go_gate. A leg that pins
# --match-head-commit <that same head> then merges with NO go_gate call
# ever having succeeded and NO GO file anywhere. Prove it two ways: the
# pre-fix blob (head 6749462a, before this round's fix) is allowed (rc=0)
# against a truncated go-gate.sh; the shipped, fixed hook against the SAME
# truncated go-gate.sh is refused (rc=2), via its new `command -v go_gate`
# precondition.
TRUNC_GOGATE="$TMP/go-gate-truncated.sh"
head -n 29 "$SCRIPT_DIR/../lib/go-gate.sh" > "$TRUNC_GOGATE"
if grep -q '^go_gate()' "$TRUNC_GOGATE"; then
    fail=$((fail+1)); echo "FAIL red-control setup: go-gate.sh header grew past line 29 — the truncated copy still defines go_gate, so this control no longer exercises a missing-symbol source"
elif ! grep -q '^console_leg()' "$TRUNC_GOGATE"; then
    fail=$((fail+1)); echo "FAIL red-control setup: go-gate.sh's console_leg() no longer fits in the first 29 lines — the truncated copy would fail the new console_leg lib-missing check instead of exercising the go_gate missing-symbol source this control targets"
else
    RC127_PAYLOAD="$TMP/red-control-rc127-payload.json"
    payload Bash "gh pr merge 42 --squash --match-head-commit abc123" > "$RC127_PAYLOAD"

    # HIMMEL-3154: this commit's PR branch was deleted on squash-merge, so
    # `git show <sha>:<path>` is unreachable from a fresh clone of origin —
    # see the note on the PRE_FIX_SHA extraction above. Replaced with a
    # committed fixture snapshot.
    PRE_RC127_SHA=6749462a6c22911d748b8a39254fbd86bdf14ece
    PRE_RC127_ROOT="$TMP/pre-rc127-hook"
    mkdir -p "$PRE_RC127_ROOT/scripts/hooks" "$PRE_RC127_ROOT/scripts/lib"
    cp "$SCRIPT_DIR/fixtures/red-control/block-unresolved-cr-merge.pre-rc127-fix.sh" \
        "$PRE_RC127_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" 2>/dev/null
    cp "$SCRIPT_DIR/../lib/cr-merge-gate.sh" "$PRE_RC127_ROOT/scripts/lib/cr-merge-gate.sh"
    cp "$SCRIPT_DIR/../lib/ci-green-gate.sh" "$PRE_RC127_ROOT/scripts/lib/ci-green-gate.sh"
    cp "$SCRIPT_DIR/../lib/handover-path.sh" "$PRE_RC127_ROOT/scripts/lib/handover-path.sh"
    cp "$TRUNC_GOGATE" "$PRE_RC127_ROOT/scripts/lib/go-gate.sh"

    cat > "$PRE_RC127_ROOT/run.sh" <<RUNEOF
#!/usr/bin/env bash
bash "$PRE_RC127_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" < "$RC127_PAYLOAD"
echo "rc=\$?"
RUNEOF
    chmod +x "$PRE_RC127_ROOT/run.sh"

    if [ ! -s "$PRE_RC127_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" ]; then
        fail=$((fail+1)); echo "FAIL red-control setup: could not extract the pre-rc127-fix hook from head $PRE_RC127_SHA"
    else
        red_control_run \
            --env HIMMEL_CONSOLE_LEG=1 --env "HANDOVER_DIR=$GOROOT" --env GH_STUB_MODE=clean \
            --env "GH_STUB_LOG=$TMP/calls-red-control-rc127.log" \
            -- bash "$PRE_RC127_ROOT/run.sh"
        if red_control_assert --label "HIMMEL-3142-RC127-RC" --expect-rc 0 \
            --observed     "$RED_CONTROL_OUT" \
            --expect-wrong "rc=0" \
            --correct      "rc=2" \
            --note "pre-round-3-fix block-unresolved-cr-merge.sh (head $PRE_RC127_SHA) tested go_rc = \"2\" only; a truncated go-gate.sh sources cleanly but never defines go_gate, so the call fails with rc=127 (command not found), the test is false, and the hook falls through to a pin check it can satisfy with its own gh pr view read — no GO file needed at all"
        then
            pass=$((pass+1)); echo "ok   red-control-rc127-pre-fix-allowed"
        else
            fail=$((fail+1)); echo "FAIL red-control-rc127-pre-fix-allowed"
        fi
    fi

    POST_RC127_ROOT="$TMP/post-rc127-hook"
    mkdir -p "$POST_RC127_ROOT/scripts/hooks" "$POST_RC127_ROOT/scripts/lib"
    cp "$HOOK" "$POST_RC127_ROOT/scripts/hooks/block-unresolved-cr-merge.sh"
    cp "$SCRIPT_DIR/../lib/cr-merge-gate.sh" "$POST_RC127_ROOT/scripts/lib/cr-merge-gate.sh"
    cp "$SCRIPT_DIR/../lib/ci-green-gate.sh" "$POST_RC127_ROOT/scripts/lib/ci-green-gate.sh"
    cp "$SCRIPT_DIR/../lib/handover-path.sh" "$POST_RC127_ROOT/scripts/lib/handover-path.sh"
    cp "$TRUNC_GOGATE" "$POST_RC127_ROOT/scripts/lib/go-gate.sh"

    POST_RC127_OUT="$TMP/post-rc127-out"
    POST_RC127_ERR="$TMP/post-rc127-err"
    HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GOROOT" GH_STUB_MODE=clean \
        GH_STUB_LOG="$TMP/calls-red-control-rc127-post.log" \
        bash "$POST_RC127_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" \
        < "$RC127_PAYLOAD" > "$POST_RC127_OUT" 2>"$POST_RC127_ERR"
    post_rc127_rc=$?
    if [ "$post_rc127_rc" -eq 2 ] && grep -qi "not defined" "$POST_RC127_ERR"; then
        pass=$((pass+1)); echo "ok   red-control-rc127-post-fix-refuses"
    else
        fail=$((fail+1)); echo "FAIL red-control-rc127-post-fix-refuses rc=$post_rc127_rc (want 2, stderr naming 'not defined')"
    fi
fi

# ── HIMMEL-3149 follow-up: a non-leg session must stay untouched by a
# COMPLETELY BROKEN go-gate.sh, not just a missing symbol. Self-review before
# /pr-check found that centralizing console_leg had widened gate 3's blast
# radius: sourcing go-gate.sh and failing closed on load failure used to live
# INSIDE the HIMMEL_CONSOLE_LEG-truthy branch (a non-leg session never
# attempted it), but the first cut of this commit moved that unconditionally
# before the leg check -- a broken go-gate.sh would then refuse EVERY merge,
# leg or not, contradicting this file's own header ("untouched for a non-leg
# session"). Fixed by gating the source on a cheap non-empty check on the raw
# var first. Prove both halves against the SAME unparseable go-gate.sh: a
# non-leg session must proceed (rc=0, no "cannot load" on stderr); a leg
# session must still fail closed (rc=2, "cannot load" on stderr) -- the fix
# narrows the blast radius, it does not remove the fail-closed guarantee for
# actual legs.
BROKEN_GOGATE="$TMP/go-gate-unparseable.sh"
printf '#!/usr/bin/env bash\nif this is not valid bash (((\n' > "$BROKEN_GOGATE"
BROKEN_GOGATE_ROOT="$TMP/broken-gogate-hook"
mkdir -p "$BROKEN_GOGATE_ROOT/scripts/hooks" "$BROKEN_GOGATE_ROOT/scripts/lib"
cp "$HOOK" "$BROKEN_GOGATE_ROOT/scripts/hooks/block-unresolved-cr-merge.sh"
cp "$SCRIPT_DIR/../lib/cr-merge-gate.sh" "$BROKEN_GOGATE_ROOT/scripts/lib/cr-merge-gate.sh"
cp "$SCRIPT_DIR/../lib/ci-green-gate.sh" "$BROKEN_GOGATE_ROOT/scripts/lib/ci-green-gate.sh"
cp "$SCRIPT_DIR/../lib/handover-path.sh" "$BROKEN_GOGATE_ROOT/scripts/lib/handover-path.sh"
cp "$BROKEN_GOGATE" "$BROKEN_GOGATE_ROOT/scripts/lib/go-gate.sh"

BROKEN_GOGATE_PAYLOAD="$TMP/broken-gogate-payload.json"
payload Bash "gh pr merge 42 --squash" > "$BROKEN_GOGATE_PAYLOAD"

BROKEN_GOGATE_NONLEG_OUT="$TMP/broken-gogate-nonleg-out"
BROKEN_GOGATE_NONLEG_ERR="$TMP/broken-gogate-nonleg-err"
GH_STUB_MODE=clean GH_STUB_LOG="$TMP/calls-broken-gogate-nonleg.log" \
    bash "$BROKEN_GOGATE_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" \
    < "$BROKEN_GOGATE_PAYLOAD" > "$BROKEN_GOGATE_NONLEG_OUT" 2>"$BROKEN_GOGATE_NONLEG_ERR"
broken_gogate_nonleg_rc=$?
if [ "$broken_gogate_nonleg_rc" -eq 0 ] && ! grep -qi "cannot load" "$BROKEN_GOGATE_NONLEG_ERR"; then
    pass=$((pass+1)); echo "ok   broken-go-gate-nonleg-untouched"
else
    fail=$((fail+1)); echo "FAIL broken-go-gate-nonleg-untouched rc=$broken_gogate_nonleg_rc (want 0, no 'cannot load' on stderr) err=$(cat "$BROKEN_GOGATE_NONLEG_ERR")"
fi

BROKEN_GOGATE_LEG_OUT="$TMP/broken-gogate-leg-out"
BROKEN_GOGATE_LEG_ERR="$TMP/broken-gogate-leg-err"
HIMMEL_CONSOLE_LEG=1 GH_STUB_MODE=clean GH_STUB_LOG="$TMP/calls-broken-gogate-leg.log" \
    bash "$BROKEN_GOGATE_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" \
    < "$BROKEN_GOGATE_PAYLOAD" > "$BROKEN_GOGATE_LEG_OUT" 2>"$BROKEN_GOGATE_LEG_ERR"
broken_gogate_leg_rc=$?
if [ "$broken_gogate_leg_rc" -eq 2 ] && grep -qi "cannot load" "$BROKEN_GOGATE_LEG_ERR"; then
    pass=$((pass+1)); echo "ok   broken-go-gate-leg-still-fails-closed"
else
    fail=$((fail+1)); echo "FAIL broken-go-gate-leg-still-fails-closed rc=$broken_gogate_leg_rc (want 2, 'cannot load' on stderr) err=$(cat "$BROKEN_GOGATE_LEG_ERR")"
fi

# ── HIMMEL-3142 CR round 4: FOURTH and FIFTH RED controls — `command -v
# go_gate` (round 3's fix) answers "is the name go_gate callable", not "did
# sourcing go-gate.sh define the function". Two distinct ways that diverges,
# each needing its own control, against the SAME truncated go-gate.sh
# ($TRUNC_GOGATE, built above — does not define go_gate):
#   (A) a PATH executable named go_gate: `command -v` finds it on PATH and
#       PASSES; the hook then CALLS it (not a function — the real binary),
#       it exits 0, go_rc=0, and the hook proceeds to a full GO bypass.
#       `declare -F` (bash-function-only) correctly rejects this.
#   (B) an inherited `export -f go_gate` in the launching shell: it IS a
#       real bash function, so `declare -F` ALSO passes it through — the
#       symbol check alone cannot distinguish "the file just defined this"
#       from "this was already in scope before we sourced". Only
#       `unset -f go_gate` BEFORE the source (so a stale/inherited
#       definition cannot survive it) closes this half.
# The pre-fix blob for both is head 6fe4ad20 (round 3's shipped hook, the
# `command -v` version) — control (B) also proves round 3's own fix does not
# close this second door, motivating the unset-then-declare-F combination.
PRE_RC4_SHA=6fe4ad205612f59c71c8354ff9f5981c5d23bb5f
RC4_PAYLOAD="$TMP/red-control-rc4-payload.json"
payload Bash "gh pr merge 42 --squash --match-head-commit abc123" > "$RC4_PAYLOAD"

rc4_extract_hook() {
    # $1 = dest root
    # HIMMEL-3154: this commit's PR branch was deleted on squash-merge, so
    # `git show <sha>:<path>` is unreachable from a fresh clone of origin —
    # see the note on the PRE_FIX_SHA extraction above. Replaced with a
    # committed fixture snapshot.
    mkdir -p "$1/scripts/hooks" "$1/scripts/lib"
    cp "$SCRIPT_DIR/fixtures/red-control/block-unresolved-cr-merge.pre-rc4-fix.sh" \
        "$1/scripts/hooks/block-unresolved-cr-merge.sh" 2>/dev/null
    cp "$SCRIPT_DIR/../lib/cr-merge-gate.sh" "$1/scripts/lib/cr-merge-gate.sh"
    cp "$SCRIPT_DIR/../lib/ci-green-gate.sh" "$1/scripts/lib/ci-green-gate.sh"
    cp "$SCRIPT_DIR/../lib/handover-path.sh" "$1/scripts/lib/handover-path.sh"
    cp "$TRUNC_GOGATE" "$1/scripts/lib/go-gate.sh"
}

if [ ! -s "$TRUNC_GOGATE" ] || grep -q '^go_gate()' "$TRUNC_GOGATE"; then
    fail=$((fail+1)); echo "FAIL red-control setup: TRUNC_GOGATE unusable for round-4 controls"
else
    # (A) PATH-executable go_gate
    RC4A_BIN="$TMP/rc4a-bin"
    mkdir -p "$RC4A_BIN"
    cat > "$RC4A_BIN/go_gate" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$RC4A_BIN/go_gate"

    PRE_RC4A_ROOT="$TMP/pre-rc4a-hook"
    rc4_extract_hook "$PRE_RC4A_ROOT"
    if [ ! -s "$PRE_RC4A_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" ]; then
        fail=$((fail+1)); echo "FAIL red-control setup: could not extract the pre-rc4-fix hook from head $PRE_RC4_SHA"
    else
        cat > "$PRE_RC4A_ROOT/run.sh" <<RUNEOF
#!/usr/bin/env bash
bash "$PRE_RC4A_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" < "$RC4_PAYLOAD"
echo "rc=\$?"
RUNEOF
        chmod +x "$PRE_RC4A_ROOT/run.sh"
        red_control_run \
            --env HIMMEL_CONSOLE_LEG=1 --env "HANDOVER_DIR=$GOROOT" --env GH_STUB_MODE=clean \
            --env "GH_STUB_LOG=$TMP/calls-red-control-rc4a.log" \
            --env "PATH=$RC4A_BIN:$PATH" \
            -- bash "$PRE_RC4A_ROOT/run.sh"
        if red_control_assert --label "HIMMEL-3142-RC4A-RC" --expect-rc 0 \
            --observed     "$RED_CONTROL_OUT" \
            --expect-wrong "rc=0" \
            --correct      "rc=2" \
            --note "round-3-shipped block-unresolved-cr-merge.sh (head $PRE_RC4_SHA) used \`command -v go_gate\`, which finds a PATH executable named go_gate exactly as readily as a sourced function; against a truncated go-gate.sh plus a PATH-executable go_gate that exits 0, the hook calls that executable, treats go_rc=0 as a real GO, and merges with no go_gate function ever having run"
        then
            pass=$((pass+1)); echo "ok   red-control-rc4a-pre-fix-allowed"
        else
            fail=$((fail+1)); echo "FAIL red-control-rc4a-pre-fix-allowed"
        fi
    fi

    POST_RC4A_ROOT="$TMP/post-rc4a-hook"
    mkdir -p "$POST_RC4A_ROOT/scripts/hooks" "$POST_RC4A_ROOT/scripts/lib"
    cp "$HOOK" "$POST_RC4A_ROOT/scripts/hooks/block-unresolved-cr-merge.sh"
    cp "$SCRIPT_DIR/../lib/cr-merge-gate.sh" "$POST_RC4A_ROOT/scripts/lib/cr-merge-gate.sh"
    cp "$SCRIPT_DIR/../lib/ci-green-gate.sh" "$POST_RC4A_ROOT/scripts/lib/ci-green-gate.sh"
    cp "$SCRIPT_DIR/../lib/handover-path.sh" "$POST_RC4A_ROOT/scripts/lib/handover-path.sh"
    cp "$TRUNC_GOGATE" "$POST_RC4A_ROOT/scripts/lib/go-gate.sh"

    POST_RC4A_OUT="$TMP/post-rc4a-out"
    POST_RC4A_ERR="$TMP/post-rc4a-err"
    HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GOROOT" GH_STUB_MODE=clean \
        GH_STUB_LOG="$TMP/calls-red-control-rc4a-post.log" \
        PATH="$RC4A_BIN:$PATH" \
        bash "$POST_RC4A_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" \
        < "$RC4_PAYLOAD" > "$POST_RC4A_OUT" 2>"$POST_RC4A_ERR"
    post_rc4a_rc=$?
    if [ "$post_rc4a_rc" -eq 2 ] && grep -qi "not defined" "$POST_RC4A_ERR"; then
        pass=$((pass+1)); echo "ok   red-control-rc4a-post-fix-refuses"
    else
        fail=$((fail+1)); echo "FAIL red-control-rc4a-post-fix-refuses rc=$post_rc4a_rc (want 2, stderr naming 'not defined')"
    fi

    # (B) inherited `export -f go_gate`
    # shellcheck disable=SC2329,SC2317  # invoked indirectly via export -f in a child bash process (rc4b fixture)
    go_gate() { exit 0; }
    export -f go_gate

    PRE_RC4B_ROOT="$TMP/pre-rc4b-hook"
    rc4_extract_hook "$PRE_RC4B_ROOT"
    if [ ! -s "$PRE_RC4B_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" ]; then
        fail=$((fail+1)); echo "FAIL red-control setup: could not extract the pre-rc4-fix hook from head $PRE_RC4_SHA (control B)"
    else
        cat > "$PRE_RC4B_ROOT/run.sh" <<RUNEOF
#!/usr/bin/env bash
bash "$PRE_RC4B_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" < "$RC4_PAYLOAD"
echo "rc=\$?"
RUNEOF
        chmod +x "$PRE_RC4B_ROOT/run.sh"
        red_control_run \
            --env HIMMEL_CONSOLE_LEG=1 --env "HANDOVER_DIR=$GOROOT" --env GH_STUB_MODE=clean \
            --env "GH_STUB_LOG=$TMP/calls-red-control-rc4b.log" \
            -- bash "$PRE_RC4B_ROOT/run.sh"
        if red_control_assert --label "HIMMEL-3142-RC4B-RC" --expect-rc 0 \
            --observed     "$RED_CONTROL_OUT" \
            --expect-wrong "rc=0" \
            --correct      "rc=2" \
            --note "round-3-shipped block-unresolved-cr-merge.sh (head $PRE_RC4_SHA) used \`command -v go_gate\` with no unset -f before sourcing; an inherited export -f go_gate in the launching shell is a real bash function, so command -v finds it exactly like one the file just defined, and a truncated go-gate.sh never overrides it"
        then
            pass=$((pass+1)); echo "ok   red-control-rc4b-pre-fix-allowed"
        else
            fail=$((fail+1)); echo "FAIL red-control-rc4b-pre-fix-allowed"
        fi
    fi

    POST_RC4B_ROOT="$TMP/post-rc4b-hook"
    mkdir -p "$POST_RC4B_ROOT/scripts/hooks" "$POST_RC4B_ROOT/scripts/lib"
    cp "$HOOK" "$POST_RC4B_ROOT/scripts/hooks/block-unresolved-cr-merge.sh"
    cp "$SCRIPT_DIR/../lib/cr-merge-gate.sh" "$POST_RC4B_ROOT/scripts/lib/cr-merge-gate.sh"
    cp "$SCRIPT_DIR/../lib/ci-green-gate.sh" "$POST_RC4B_ROOT/scripts/lib/ci-green-gate.sh"
    cp "$SCRIPT_DIR/../lib/handover-path.sh" "$POST_RC4B_ROOT/scripts/lib/handover-path.sh"
    cp "$TRUNC_GOGATE" "$POST_RC4B_ROOT/scripts/lib/go-gate.sh"

    POST_RC4B_OUT="$TMP/post-rc4b-out"
    POST_RC4B_ERR="$TMP/post-rc4b-err"
    HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GOROOT" GH_STUB_MODE=clean \
        GH_STUB_LOG="$TMP/calls-red-control-rc4b-post.log" \
        bash "$POST_RC4B_ROOT/scripts/hooks/block-unresolved-cr-merge.sh" \
        < "$RC4_PAYLOAD" > "$POST_RC4B_OUT" 2>"$POST_RC4B_ERR"
    post_rc4b_rc=$?
    if [ "$post_rc4b_rc" -eq 2 ] && grep -qi "not defined" "$POST_RC4B_ERR"; then
        pass=$((pass+1)); echo "ok   red-control-rc4b-post-fix-refuses"
    else
        fail=$((fail+1)); echo "FAIL red-control-rc4b-post-fix-refuses rc=$post_rc4b_rc (want 2, stderr naming 'not defined')"
    fi

    unset -f go_gate
fi

# passthrough cases must not touch gh at all (coderabbit: assert EVERY one)
for pt in non-merge-passthrough string-literal-passthrough quoted-merge-text-passthrough; do
    [ -s "$TMP/calls-$pt.log" ] && { echo "FAIL $pt called gh"; fail=$((fail+1)); }
done
# block reason surfaces on stderr (hook contract: stderr shown to model+user)
grep -qi "unresolved" "$TMP/err-merge-with-unresolved-blocks" || { echo "FAIL stderr reason missing"; fail=$((fail+1)); }
# HIMMEL-1043: the CI gate's block surfaces with its own prefix on stderr
grep -q "block-red-ci-merge" "$TMP/err-merge-over-red-ci-blocks" || { echo "FAIL ci-block stderr reason missing"; fail=$((fail+1)); }
# HIMMEL-3360: an absent or stale-anchored CodeRabbit review no longer blocks
# a merge at all — the old block wording must not appear (a degrade note from
# this stub's unstubbed body-findings/check-runs queries is expected and fine,
# same as every other allow-case above; only the removed BLOCK reasons matter).
grep -qi "has not reviewed" "$TMP/err-absent-review-allows" && { echo "FAIL absent-review-allows still blocks with the removed absent-review wording"; fail=$((fail+1)); }
grep -qi "shaOLD\|never re-reviewed" "$TMP/err-freshness-stale-no-longer-blocks" && { echo "FAIL freshness-stale-no-longer-blocks still blocks with the removed stale-anchor wording"; fail=$((fail+1)); }

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

# HIMMEL-3154: guard against reintroducing extraction of a historical
# commit's blob via `git show <sha>:<path>` — the class of fragility this
# ticket fixed. Once a PR's branch is squash-merged, that commit is
# permanently unreachable from a fresh clone; a RED-control mutant must come
# from a committed fixtures/red-control/ snapshot, never a live git-show of a
# past ref.
if grep -vE '^[[:space:]]*#' "$SCRIPT_DIR/test-block-unresolved-cr-merge.sh" \
    | grep -Eq 'git[[:space:]]+(-C[[:space:]]+\S+[[:space:]]+)?show[[:space:]].*:scripts/'; then
    fail=$((fail+1)); echo "FAIL lint: this file extracts a historical blob via git show <ref>:<path> — use a committed fixtures/red-control/ snapshot instead (HIMMEL-3154)"
else
    pass=$((pass+1)); echo "ok   lint-no-historical-git-show-extraction"
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
