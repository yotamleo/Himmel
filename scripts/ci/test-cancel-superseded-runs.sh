#!/usr/bin/env bash
# Test for scripts/ci/cancel-superseded-runs.sh (HIMMEL-3811).
# A fake gh serves canned `pr list` / `run list` JSON and records every
# `run cancel`; the script's own jq filtering runs for real. No real run is
# ever cancelled.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ci/cancel-superseded-runs.sh"
TMP="$(mktemp -d "/tmp/himmel-test-cancel-superseded.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }
is()  { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1: want '$2' got '$3'"; fi; }

mkdir -p "$TMP/bin" "$TMP/fx"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# fake gh. Fixtures live in $FX; cancels are appended to $FX/cancelled.
# FAKE_GH_FAIL=pr|ci|gate|cancel:<id> makes that call fail.
case "$1 $2" in
  "pr list")
    [ "${FAKE_GH_FAIL:-}" = pr ] && { echo "fake-gh: pr list failed" >&2; exit 1; }
    echo "$*" > "$FX/pr-args"
    head=""
    for a in "$@"; do [ "$prev" = --head ] && head="$a"; prev="$a"; done
    # like real gh, --head narrows the list to that branch
    jq -c --arg h "$head" 'map(select($h == "" or .headRefName == $h))' "$FX/prs.json" ;;
  "run list")
    wf=""
    for a in "$@"; do case "$prev" in --workflow) wf="$a" ;; esac; prev="$a"; done
    case "$wf" in
      ci.yml) [ "${FAKE_GH_FAIL:-}" = ci ] && { echo "fake-gh: run list failed" >&2; exit 1; }; cat "$FX/runs-ci.json" ;;
      codeowner-review-gate.yml) [ "${FAKE_GH_FAIL:-}" = gate ] && { echo "fake-gh: run list failed" >&2; exit 1; }; cat "$FX/runs-gate.json" ;;
      *) echo "fake-gh: unsupported workflow '$wf'" >&2; exit 1 ;;
    esac ;;
  "run cancel")
    [ "${FAKE_GH_FAIL:-}" = "cancel:$3" ] && { echo "fake-gh: cancel $3 failed" >&2; exit 1; }
    echo "$3" >> "$FX/cancelled" ;;
  *) echo "fake-gh: unsupported: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"

# PR 10 (branch feat/a) head=NEW10; PR 11 (branch feat/b) head=NEW11.
cat > "$TMP/prs.json" <<'EOF'
[{"number":10,"headRefName":"feat/a","headRefOid":"NEW10","isCrossRepository":false},
 {"number":11,"headRefName":"feat/b","headRefOid":"NEW11","isCrossRepository":false}]
EOF
# run <id> <status> <event> <branch> <sha> -> one gh run list element
r() { printf '{"databaseId":%s,"status":"%s","event":"%s","headBranch":"%s","headSha":"%s","workflowName":"CI"}' "$@"; }
reset() { rm -rf "$TMP/fx"; mkdir -p "$TMP/fx"; cp "$TMP/prs.json" "$TMP/fx/prs.json"; echo '[]' > "$TMP/fx/runs-ci.json"; echo '[]' > "$TMP/fx/runs-gate.json"; }
run() { FX="$TMP/fx" PATH="$TMP/bin:$PATH" bash "$SCRIPT" "$@" 2>&1; }
cancelled() { if [ -f "$TMP/fx/cancelled" ]; then sort "$TMP/fx/cancelled" | tr '\n' ' ' | sed 's/ $//'; else echo "none"; fi; }

if bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "syntax"; fi

# superseded pull_request run (queued) cancelled; current-head kept
reset
echo "[$(r 1 queued pull_request feat/a OLD10),$(r 2 queued pull_request feat/a NEW10)]" > "$TMP/fx/runs-ci.json"
out="$(run)"; rc=$?
is "superseded PR run cancelled, current kept" "1" "$(cancelled)"
is "  exit 0" "0" "$rc"
case "$out" in *"cancel 1 "*) ok "  one line per cancel names the run" ;; *) bad "  cancel line missing: $out" ;; esac

# every live status is cancellable
reset
echo "[$(r 1 queued pull_request feat/a OLD),$(r 2 pending pull_request feat/a OLD),$(r 3 in_progress pull_request feat/a OLD),$(r 4 waiting pull_request feat/a OLD)]" > "$TMP/fx/runs-ci.json"
run >/dev/null
is "queued|pending|in_progress|waiting all cancelled" "1 2 3 4" "$(cancelled)"

# completed runs are never touched
reset
echo "[$(r 1 completed pull_request feat/a OLD),$(r 9 queued pull_request feat/a OLD)]" > "$TMP/fx/runs-ci.json"
run >/dev/null
is "completed run at old head kept (queued sibling cancelled)" "9" "$(cancelled)"

# main and schedule kept even though their sha != any PR head
reset
echo "[$(r 1 queued push main OLDMAIN),$(r 2 queued schedule main OLDMAIN),$(r 3 queued schedule feat/a OLD10),$(r 9 queued pull_request feat/a OLD10)]" > "$TMP/fx/runs-ci.json"
run >/dev/null
is "main push, main schedule and a schedule run on a PR branch kept (PR sibling cancelled)" "9" "$(cancelled)"

# a branch with no open PR is left alone (PR head unreadable -> fail safe)
reset
echo "[$(r 1 queued pull_request feat/orphan OLD),$(r 9 queued pull_request feat/a OLD)]" > "$TMP/fx/runs-ci.json"
run >/dev/null
is "run on a branch with no open PR kept (PR sibling cancelled)" "9" "$(cancelled)"

# codeowner-review-gate: old head cancelled, current head kept
reset
echo "[$(r 1 queued pull_request feat/b OLD11),$(r 2 queued pull_request feat/b NEW11)]" > "$TMP/fx/runs-gate.json"
run >/dev/null
is "codeowner run: old head cancelled, current kept" "1" "$(cancelled)"

# workflow_dispatch at an old head cancelled; at the current head kept
reset
echo "[$(r 1 queued workflow_dispatch feat/a OLD10),$(r 2 queued workflow_dispatch feat/a NEW10)]" > "$TMP/fx/runs-ci.json"
run >/dev/null
is "dispatch: old head cancelled, current kept" "1" "$(cancelled)"

# per-PR heads are independent (a run at PR 10's head on PR 11's branch is superseded)
reset
echo "[$(r 1 queued pull_request feat/b NEW10),$(r 2 queued pull_request feat/b NEW11)]" > "$TMP/fx/runs-ci.json"
run >/dev/null
is "each branch compared to its own PR head" "1" "$(cancelled)"

# ambiguous or unreadable PR heads are left alone (fail safe). Each case has a
# must-cancel sibling on feat/a so it cannot pass vacuously.
sib="$(r 9 queued pull_request feat/a OLD10)"
# a fork PR shares the branch name feat/x: its runs cannot be attributed to a head
reset
cat > "$TMP/fx/prs.json" <<'EOF'
[{"number":10,"headRefName":"feat/a","headRefOid":"NEW10","isCrossRepository":false},
 {"number":12,"headRefName":"feat/x","headRefOid":"FORKX","isCrossRepository":true}]
EOF
echo "[$sib,$(r 1 queued pull_request feat/x OLDX)]" > "$TMP/fx/runs-ci.json"
run >/dev/null
is "branch shared with a cross-repo (fork) PR kept" "9" "$(cancelled)"
# a same-repo PR whose head branch is main: main is never touched
reset
cat > "$TMP/fx/prs.json" <<'EOF'
[{"number":10,"headRefName":"feat/a","headRefOid":"NEW10","isCrossRepository":false},
 {"number":13,"headRefName":"main","headRefOid":"MAINPR","isCrossRepository":false}]
EOF
echo "[$sib,$(r 1 queued push main OLDMAIN),$(r 2 queued pull_request main OLDMAIN)]" > "$TMP/fx/runs-ci.json"
run >/dev/null
is "main kept even when it is an open PR's head branch" "9" "$(cancelled)"
# a PR entry with no readable headRefOid
reset
cat > "$TMP/fx/prs.json" <<'EOF'
[{"number":10,"headRefName":"feat/a","headRefOid":"NEW10","isCrossRepository":false},
 {"number":14,"headRefName":"feat/c","isCrossRepository":false}]
EOF
echo "[$sib,$(r 1 queued pull_request feat/c OLDC)]" > "$TMP/fx/runs-ci.json"
run >/dev/null
is "PR entry without headRefOid kept" "9" "$(cancelled)"
# two open PRs from one branch with different heads (different bases): ambiguous
reset
cat > "$TMP/fx/prs.json" <<'EOF'
[{"number":10,"headRefName":"feat/a","headRefOid":"NEW10","isCrossRepository":false},
 {"number":15,"headRefName":"feat/d","headRefOid":"D1","isCrossRepository":false},
 {"number":16,"headRefName":"feat/d","headRefOid":"D2","isCrossRepository":false}]
EOF
echo "[$sib,$(r 1 queued pull_request feat/d D1)]" > "$TMP/fx/runs-ci.json"
run >/dev/null
is "branch with two open PRs at different heads kept" "9" "$(cancelled)"

# nothing to cancel -> exit 0
reset
echo "[$(r 1 queued pull_request feat/a NEW10)]" > "$TMP/fx/runs-ci.json"
out="$(run)"; rc=$?
is "nothing to cancel: exit 0" "0" "$rc"
is "nothing to cancel: no cancel issued" "none" "$(cancelled)"

# gh failure at each read: nothing cancelled, non-zero
for f in pr ci gate; do
  reset
  echo "[$(r 1 queued pull_request feat/a OLD)]" > "$TMP/fx/runs-ci.json"
  echo "[$(r 2 queued pull_request feat/a OLD)]" > "$TMP/fx/runs-gate.json"
  out="$(FAKE_GH_FAIL=$f run)"; rc=$?
  is "gh $f read fails: nothing cancelled" "none" "$(cancelled)"
  if [ "$rc" -ne 0 ]; then ok "gh $f read fails: non-zero exit"; else bad "gh $f read fails: exit was 0"; fi
done

# malformed gh output is a read failure too
reset
echo "not json" > "$TMP/fx/runs-ci.json"
out="$(run)"; rc=$?
is "malformed run list: nothing cancelled" "none" "$(cancelled)"
if [ "$rc" -ne 0 ]; then ok "malformed run list: non-zero exit"; else bad "malformed run list: exit was 0"; fi

# a failed cancel does not stop the rest, and exits non-zero
reset
echo "[$(r 1 queued pull_request feat/a OLD),$(r 2 queued pull_request feat/a OLD)]" > "$TMP/fx/runs-ci.json"
out="$(FAKE_GH_FAIL=cancel:1 run)"; rc=$?
is "failed cancel: the other run still cancelled" "2" "$(cancelled)"
if [ "$rc" -ne 0 ]; then ok "failed cancel: non-zero exit"; else bad "failed cancel: exit was 0"; fi

# --dry-run prints what it would do and cancels nothing
reset
echo "[$(r 1 queued pull_request feat/a OLD10),$(r 2 queued pull_request feat/a NEW10)]" > "$TMP/fx/runs-ci.json"
out="$(run --dry-run)"; rc=$?
is "--dry-run: nothing cancelled" "none" "$(cancelled)"
is "--dry-run: exit 0" "0" "$rc"
case "$out" in *"would-cancel 1 "*) ok "--dry-run names the run it would cancel" ;; *) bad "--dry-run line missing: $out" ;; esac

# --branch limits the PR scan to that branch
reset
echo "[$(r 1 queued pull_request feat/a OLD),$(r 2 queued pull_request feat/b OLD)]" > "$TMP/fx/runs-ci.json"
run --branch feat/a >/dev/null
is "--branch feat/a: only that branch's runs cancelled" "1" "$(cancelled)"
case "$(cat "$TMP/fx/pr-args")" in *"--head feat/a"*) ok "--branch passes --head to gh pr list" ;; *) bad "--head not passed: $(cat "$TMP/fx/pr-args")" ;; esac

# bad usage
out="$(run --bogus)"; rc=$?
is "unknown flag: exit 2" "2" "$rc"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: cancel-superseded-runs"; exit 0; fi
echo "FAIL: $fails" >&2; exit 1
