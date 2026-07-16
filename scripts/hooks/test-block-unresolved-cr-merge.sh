#!/usr/bin/env bash
# Tests for scripts/hooks/block-unresolved-cr-merge.sh (HIMMEL-936). Hermetic.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/block-unresolved-cr-merge.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${GH_STUB_LOG:?}"
case "${GH_STUB_MODE:?}" in
  error) exit 1 ;;
esac
case "$1 $2" in
  "pr view")
    # deadbeef simulates a mis-extracted selector (a value-taking flag's
    # argument) that resolves to no PR - drives the rc=3 re-anchor path.
    [ "${3:-}" = "deadbeef" ] && exit 1
    echo '{"number":42,"headRefOid":"abc123","url":"https://github.com/o/r/pull/42"}' ;;
  "api graphql")
    case "$GH_STUB_MODE" in
      unresolved|zombie-unresolved) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]}}}}}' ;;
      other-author) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"someuser"}}]}}]}}}}}' ;;
      zombie-paged) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true},"nodes":[{"isResolved":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]}}}}}' ;;
      zombie-nopageinfo) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]}}}}}' ;;
      *) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]}}}}}' ;;
    esac ;;
  "api repos/o/r/commits/abc123/check-runs"*)
    case "$GH_STUB_MODE" in
      inflight|zombie|zombie-unresolved|zombie-no-status|zombie-status-error|zombie-paged|zombie-nopageinfo) echo '{"check_runs":[{"name":"CodeRabbit","status":"in_progress","started_at":"2000-01-01T00:00:00Z","conclusion":null}]}' ;;
      young) echo "{\"check_runs\":[{\"name\":\"CodeRabbit\",\"status\":\"in_progress\",\"started_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"conclusion\":null}]}" ;;
      # HIMMEL-1043 CI-gate cases: a completed CodeRabbit run keeps the CR gate
      # green (it only looks at CodeRabbit); a non-CodeRabbit run carries the
      # red/green signal only the CI gate reads.
      ci-red)   echo '{"check_runs":[{"name":"CodeRabbit","status":"completed","conclusion":"success"},{"name":"tests","status":"completed","conclusion":"failure"}]}' ;;
      ci-green) echo '{"check_runs":[{"name":"CodeRabbit","status":"completed","conclusion":"success"},{"name":"tests","status":"completed","conclusion":"success"}]}' ;;
      *)        echo '{"check_runs":[{"name":"CodeRabbit","status":"completed","conclusion":"success"}]}' ;;
    esac ;;
  "api repos/o/r/commits/abc123/status")
    case "$GH_STUB_MODE" in
      zombie|zombie-unresolved|zombie-paged|zombie-nopageinfo) echo '{"statuses":[{"context":"CodeRabbit","state":"success"}]}' ;;
      zombie-status-error) exit 1 ;;
      zombie-no-status) echo '{"statuses":[]}' ;;
      ci-green) echo '{"state":"success","total_count":1,"statuses":[{"context":"ci","state":"success"}]}' ;;
      *) echo '{"statuses":[{"context":"CodeRabbit","state":"pending"}]}' ;;
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

GH_STUB_MODE=unresolved t merge-with-unresolved-blocks   2 Bash "gh pr merge 42 --squash"
GH_STUB_MODE=clean      t merge-clean-allows             0 Bash "gh pr merge 42 --squash"
GH_STUB_MODE=error      t api-error-fails-open           0 Bash "gh pr merge 42 --squash"
GH_STUB_MODE=inflight   t inflight-review-blocks         2 Bash "gh pr merge 42 --squash"
GH_STUB_MODE=zombie     t zombie-review-allows           0 Bash "gh pr merge 42 --squash"
GH_STUB_MODE=young      t young-inflight-blocks          2 Bash "gh pr merge 42 --squash"
GH_STUB_MODE=zombie-no-status t zombie-no-success-blocks 2 Bash "gh pr merge 42 --squash"
GH_STUB_MODE=zombie-unresolved t zombie-unresolved-blocks 2 Bash "gh pr merge 42 --squash"
GH_STUB_MODE=zombie-status-error t zombie-status-error-blocks 2 Bash "gh pr merge 42 --squash"
GH_STUB_MODE=zombie-paged t zombie-paged-threads-blocks 2 Bash "gh pr merge 42 --squash"
GH_STUB_MODE=zombie-nopageinfo t zombie-nopageinfo-blocks 2 Bash "gh pr merge 42 --squash"
GH_STUB_MODE=other-author t other-author-thread-allows 0 Bash "gh pr merge 42 --squash"
CR_ZOMBIE_CHECKRUN_MINS=090 GH_STUB_MODE=zombie t zombie-leading-zero-mins-allows 0 Bash "gh pr merge 42 --squash"
# ── HIMMEL-1043: CI-green gate runs SECOND (after the CR gate) ──
# ci-red: CR gate passes (resolved CodeRabbit thread + completed CodeRabbit
# check-run), but a non-CodeRabbit check-run ("tests") failed -> CI gate
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

# passthrough cases must not touch gh at all (coderabbit: assert EVERY one)
for pt in non-merge-passthrough string-literal-passthrough quoted-merge-text-passthrough; do
    [ -s "$TMP/calls-$pt.log" ] && { echo "FAIL $pt called gh"; fail=$((fail+1)); }
done
# block reason surfaces on stderr (hook contract: stderr shown to model+user)
grep -qi "unresolved" "$TMP/err-merge-with-unresolved-blocks" || { echo "FAIL stderr reason missing"; fail=$((fail+1)); }
# HIMMEL-1043: the CI gate's block surfaces with its own prefix on stderr
grep -q "block-red-ci-merge" "$TMP/err-merge-over-red-ci-blocks" || { echo "FAIL ci-block stderr reason missing"; fail=$((fail+1)); }
grep -q "zombie check-run override:.*commit status=success + 0 unresolved threads.*HIMMEL-980" "$TMP/err-zombie-review-allows" || { echo "FAIL zombie override line missing"; fail=$((fail+1)); }

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
