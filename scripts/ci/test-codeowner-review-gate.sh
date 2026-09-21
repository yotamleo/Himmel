#!/usr/bin/env bash
# Suite for scripts/ci/codeowner-review-gate.mjs + .github/workflows/codeowner-review-gate.yml
# (HIMMEL-3372).
#
# Part 1 — decision logic over JSON/text fixtures (offline, no network):
#   pr.json, permission.json, reviews.json, files.txt, CODEOWNERS.
# Part 2 — live mode (--repo/--pr-number/--base-sha) against a stub `gh` on PATH:
#   pins WHICH endpoints are called and at WHICH ref (CODEOWNERS from the BASE sha).
# Part 3 — static assertions over the workflow YAML (no pull_request_target, no
#   checkout, minimal permissions, sha-pinned actions, no `${{ }}` in run:), each
#   with a negative control proving the checker CAN fail.
#
# Usage: bash scripts/ci/test-codeowner-review-gate.sh
# Exit: 0 all passed, 1 at least one failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
GATE="$HERE/codeowner-review-gate.mjs"
WF="$REPO_ROOT/.github/workflows/codeowner-review-gate.yml"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/codeowner-gate-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# grepq <text> [grep-args...] — pipeline-free grep -q (see test-check-no-secrets.sh).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

if ! command -v node >/dev/null 2>&1; then
  echo "FATAL: node not found on PATH — this suite cannot run (not skipped: a skip would be vacuous)"
  exit 1
fi

# The script must exist: an absent script makes `node` exit 1, which is ALSO the
# gate's "policy FAIL" code — so every expect-fail case would pass vacuously.
if [ -f "$GATE" ]; then pass "gate script exists"; else fail "gate script exists ($GATE)"; fi
if [ -f "$WF" ]; then pass "workflow exists"; else fail "workflow exists ($WF)"; fi

# ---------------------------------------------------------------- part 1
echo 0 > "$TMP/rv_n"
# rv <login> <STATE> <commit> — one review object; submitted_at climbs per call.
# The counter lives in a file: rv runs inside $(...), so a shell variable would
# never advance and every review would share one timestamp.
rv() {
  local n
  n=$(( $(cat "$TMP/rv_n") + 1 ))
  echo "$n" > "$TMP/rv_n"
  printf '{"user":{"login":"%s"},"state":"%s","commit_id":"%s","submitted_at":"2026-09-21T10:%02d:00Z"}' \
    "$1" "$2" "$3" "$n"
}

reset_fx() {
  echo 0 > "$TMP/rv_n"
  FX_AUTHOR=outsider; FX_TYPE=User; FX_SHA=head111
  FX_PERM='{"permission":"read","role_name":"read"}'
  FX_REVIEWS='[]'
  FX_FILES='README.md'
  FX_OWNERS='* @yotamleo'
}

N=0
# run_gate — materialise the FX_* fixture, run the script; sets OUT and RC.
run_gate() {
  N=$((N+1)); local d="$TMP/fx.$N"; mkdir -p "$d"
  printf '{"user":{"login":"%s","type":"%s"},"head":{"sha":"%s"}}\n' "$FX_AUTHOR" "$FX_TYPE" "$FX_SHA" > "$d/pr.json"
  printf '%s\n' "$FX_PERM" > "$d/permission.json"
  printf '%s\n' "$FX_REVIEWS" > "$d/reviews.json"
  printf '%s\n' "$FX_FILES" > "$d/files.txt"
  printf '%s\n' "$FX_OWNERS" > "$d/CODEOWNERS"
  OUT=$(node "$GATE" --pr-file "$d/pr.json" --permission-file "$d/permission.json" \
        --reviews-file "$d/reviews.json" --files-file "$d/files.txt" \
        --codeowners-file "$d/CODEOWNERS" 2>&1)
  RC=$?
}

# expect <name> <pass|fail|error> [substring-in-output]
expect() {
  local name="$1" want="$2" sub="${3:-}" rc_want marker
  case "$want" in
    pass)  rc_want=0; marker='codeowner-review-gate: PASS' ;;
    fail)  rc_want=1; marker='codeowner-review-gate: FAIL' ;;
    error) rc_want=2; marker='codeowner-review-gate: ERROR' ;;
    *) fail "$name (bad expectation $want)"; return ;;
  esac
  if [ "$RC" -ne "$rc_want" ]; then fail "$name -> rc $RC, want $rc_want: $OUT"; return; fi
  if ! grepq "$OUT" -F "$marker"; then fail "$name -> rc ok but no '$marker' in: $OUT"; return; fi
  if [ -n "$sub" ] && ! grepq "$OUT" -F -- "$sub"; then fail "$name -> output lacks '$sub': $OUT"; return; fi
  pass "$name"
}

echo "== part 1: decision logic =="

reset_fx; FX_AUTHOR=yotamleo; FX_PERM='{"permission":"admin","role_name":"admin"}'
run_gate; expect "owner author (admin) -> pass, no review needed" pass

reset_fx; FX_AUTHOR=collab; FX_PERM='{"permission":"write","role_name":"write"}'
run_gate; expect "collaborator with write -> pass" pass

reset_fx; FX_AUTHOR=maint; FX_PERM='{"permission":"write","role_name":"maintain"}'
run_gate; expect "maintain role -> pass" pass

reset_fx; FX_AUTHOR=triager; FX_PERM='{"permission":"read","role_name":"triage"}'
run_gate; expect "triage (read) is outside -> fail, names the owner" fail "@yotamleo"

reset_fx
run_gate; expect "outside author, no review -> fail, names the owner" fail "@yotamleo"

reset_fx; FX_REVIEWS="[$(rv yotamleo APPROVED older999)]"
run_gate; expect "owner APPROVED at an older sha -> fail" fail "@yotamleo"

reset_fx; FX_REVIEWS="[$(rv yotamleo APPROVED head111)]"
run_gate; expect "owner APPROVED at the head -> pass" pass

reset_fx; FX_REVIEWS="[$(rv yotamleo APPROVED head111),$(rv yotamleo CHANGES_REQUESTED head111)]"
run_gate; expect "APPROVED then CHANGES_REQUESTED -> fail" fail "@yotamleo"

reset_fx; FX_REVIEWS="[$(rv yotamleo CHANGES_REQUESTED head111),$(rv yotamleo APPROVED head111)]"
run_gate; expect "CHANGES_REQUESTED then APPROVED at head -> pass" pass

# Order comes from submitted_at, not array position: the later CHANGES_REQUESTED
# is listed FIRST, so an index-only reading would wrongly take the APPROVED.
reset_fx; FX_REVIEWS='[{"user":{"login":"yotamleo"},"state":"CHANGES_REQUESTED","commit_id":"head111","submitted_at":"2026-09-21T10:30:00Z"},{"user":{"login":"yotamleo"},"state":"APPROVED","commit_id":"head111","submitted_at":"2026-09-21T10:10:00Z"}]'
run_gate; expect "later CHANGES_REQUESTED listed first still wins by submitted_at -> fail" fail "@yotamleo"

reset_fx; FX_REVIEWS='[{"user":{"login":"yotamleo"},"state":"APPROVED","commit_id":"head111","submitted_at":"2026-09-21T10:30:00Z"},{"user":{"login":"yotamleo"},"state":"CHANGES_REQUESTED","commit_id":"head111","submitted_at":"2026-09-21T10:10:00Z"}]'
run_gate; expect "later APPROVED listed first still wins by submitted_at -> pass" pass

reset_fx; FX_REVIEWS="[$(rv randomperson APPROVED head111)]"
run_gate; expect "approval from a non-owner -> fail" fail "@yotamleo"

reset_fx; FX_REVIEWS="[$(rv yotamleo APPROVED head111),$(rv yotamleo COMMENTED head111)]"
run_gate; expect "a later COMMENTED does not retract an approval -> pass" pass

reset_fx; FX_REVIEWS="[$(rv yotamleo DISMISSED head111)]"
run_gate; expect "DISMISSED review -> fail" fail "@yotamleo"

reset_fx; FX_REVIEWS="[$(rv YotamLeo APPROVED head111)]"
run_gate; expect "reviewer login matches the owner case-insensitively -> pass" pass

reset_fx; FX_AUTHOR='dependabot[bot]'; FX_TYPE=Bot; FX_PERM='{"permission":"write","role_name":"write"}'
run_gate; expect "dependabot needs approval even if the API reports write -> fail" fail "@yotamleo"

reset_fx; FX_AUTHOR='dependabot[bot]'; FX_TYPE=Bot; FX_PERM='{"permission":"write","role_name":"write"}'
FX_REVIEWS="[$(rv yotamleo APPROVED head111)]"
run_gate; expect "dependabot with an owner approval at head -> pass" pass

reset_fx; FX_OWNERS='* @yotamleo @second'; FX_REVIEWS="[$(rv yotamleo APPROVED head111)]"
run_gate; expect "two owners, only one approved -> fail naming the other" fail "@second"

reset_fx; FX_OWNERS='* @yotamleo @second'; FX_REVIEWS="[$(rv yotamleo APPROVED head111),$(rv second APPROVED head111)]"
run_gate; expect "two owners, both approved -> pass" pass

reset_fx; FX_OWNERS=$'* @yotamleo\n/docs/ @docsowner'; FX_FILES='docs/a.md'
FX_REVIEWS="[$(rv docsowner APPROVED head111)]"
run_gate; expect "last matching rule wins: docs/ owned by @docsowner only -> pass" pass

reset_fx; FX_OWNERS=$'* @yotamleo\n/docs/ @docsowner'; FX_FILES='docs/a.md'
FX_REVIEWS="[$(rv yotamleo APPROVED head111)]"
run_gate; expect "last matching rule wins: the global owner alone does not cover docs/" fail "@docsowner"

reset_fx; FX_OWNERS=$'* @yotamleo\n/docs/ @docsowner'; FX_FILES=$'docs/a.md\nsrc/b.js'
FX_REVIEWS="[$(rv docsowner APPROVED head111)]"
run_gate; expect "a changed file outside docs/ still needs @yotamleo" fail "@yotamleo"

reset_fx; FX_OWNERS=$'* @yotamleo\n*.md @mdowner'; FX_FILES='deep/nested/x.md'
FX_REVIEWS="[$(rv mdowner APPROVED head111)]"
run_gate; expect "*.md matches at any depth" pass

reset_fx; FX_OWNERS=$'* @yotamleo\ndocs/* @docsowner'; FX_FILES='docs/sub/x.md'
FX_REVIEWS="[$(rv docsowner APPROVED head111)]"
run_gate; expect "docs/* does NOT match nested files -> global owner still required" fail "@yotamleo"

reset_fx; FX_OWNERS=$'* @yotamleo\n/scripts/ @scriptowner'; FX_FILES='scripts/ci/x.sh'
FX_REVIEWS="[$(rv scriptowner APPROVED head111)]"
run_gate; expect "/dir/ matches nested files" pass

reset_fx; FX_OWNERS=$'* @yotamleo\n/scripts/ @scriptowner'; FX_FILES='other/scripts/x.sh'
FX_REVIEWS="[$(rv scriptowner APPROVED head111)]"
run_gate; expect "/dir/ is anchored to the root" fail "@yotamleo"

reset_fx; FX_OWNERS=$'# comment line\n\n* @yotamleo # trailing comment'
FX_REVIEWS="[$(rv yotamleo APPROVED head111)]"
run_gate; expect "comments and blank lines are ignored" pass

reset_fx; FX_OWNERS='* @myorg/reviewers'; FX_REVIEWS="[$(rv reviewers APPROVED head111)]"
run_gate; expect "a team owner cannot be verified -> fail closed" fail "@myorg/reviewers"

reset_fx; FX_OWNERS='/nothing-matches/ @yotamleo'
run_gate; expect "no owner covers the changed paths -> fail closed" fail

reset_fx; FX_OWNERS=$'* @yotamleo\n/README.md'; FX_REVIEWS="[$(rv yotamleo APPROVED head111)]"
run_gate; expect "an ownerless later rule un-owns the path -> fail closed (nobody to approve)" fail

reset_fx; FX_FILES=''
run_gate; expect "empty changed-file list -> fail closed" fail

# the base-only CODEOWNERS is an input: swapping it must change the verdict
reset_fx; FX_OWNERS='* @attacker'; FX_REVIEWS="[$(rv attacker APPROVED head111)]"
run_gate; expect "verdict follows the CODEOWNERS it is given (base-ref supplied by the caller)" pass

# usage errors
N=$((N+1)); d="$TMP/fx.$N"; mkdir -p "$d"
OUT=$(node "$GATE" 2>&1); RC=$?
expect "no arguments -> ERROR rc 2" error

OUT=$(node "$GATE" --pr-file "$TMP/does-not-exist.json" --permission-file "$TMP/x" --reviews-file "$TMP/x" --files-file "$TMP/x" --codeowners-file "$TMP/x" 2>&1); RC=$?
expect "unreadable fixture -> ERROR rc 2 (fail closed, not pass)" error

# ---------------------------------------------------------------- part 2
echo "== part 2: live mode (stub gh) =="

mkdir -p "$TMP/bin" "$TMP/stub"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh: logs every call, serves canned data from $STUB_DIR.
printf '%s\n' "$*" >> "$STUB_DIR/calls.log"
case "$*" in
  *"/collaborators/"*)
    if [ -f "$STUB_DIR/perm-404" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    cat "$STUB_DIR/permission.json" ;;
  *"/reviews"*)
    if [ -f "$STUB_DIR/reviews-fail" ]; then echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1; fi
    cat "$STUB_DIR/reviews.ndjson" ;;
  *"/files"*) cat "$STUB_DIR/files.txt" ;;
  *"contents/.github/CODEOWNERS"*) cat "$STUB_DIR/CODEOWNERS" ;;
  *"repos/o/r/pulls/7") cat "$STUB_DIR/pr.json" ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

# live_case <author> <type> <perm-json> [reviews-ndjson]  — sets OUT, RC, CALLS
live_case() {
  local a="$1" t="$2" p="$3" r="${4:-}"
  rm -f "$TMP/stub/perm-404" "$TMP/stub/reviews-fail" "$TMP/stub/calls.log"
  printf '{"user":{"login":"%s","type":"%s"},"head":{"sha":"headsha111"},"changed_files":%s}\n' "$a" "$t" "${LIVE_CHANGED:-1}" > "$TMP/stub/pr.json"
  printf '%s\n' "$p" > "$TMP/stub/permission.json"
  printf '%s\n' "$r" > "$TMP/stub/reviews.ndjson"
  printf '%s\n' "${LIVE_FILES:-\"README.md\"}" > "$TMP/stub/files.txt"
  printf '%b\n' "${LIVE_OWNERS:-* @yotamleo}" > "$TMP/stub/CODEOWNERS"
  OUT=$(STUB_DIR="$TMP/stub" PATH="$TMP/bin:$PATH" node "$GATE" --repo o/r --pr-number 7 --base-sha ba5e999 2>&1)
  RC=$?
  CALLS=$(cat "$TMP/stub/calls.log" 2>/dev/null || true)
}

live_case yotamleo User '{"permission":"admin","role_name":"admin"}'
expect "live: owner author -> pass" pass
if grepq "$CALLS" -F "/reviews"; then fail "live: a permitted author must not trigger a reviews fetch"; else pass "live: a permitted author skips the reviews fetch"; fi

APPROVED_HEAD="$(rv yotamleo APPROVED headsha111)"
live_case outsider User '{"permission":"read","role_name":"read"}' "$APPROVED_HEAD"
expect "live: outsider + owner approval at the head -> pass" pass
if grepq "$CALLS" -F "contents/.github/CODEOWNERS?ref=ba5e999"; then pass "live: CODEOWNERS is read at the BASE sha"; else fail "live: CODEOWNERS not read at ref=ba5e999: $CALLS"; fi
if grepq "$CALLS" -F "headsha111"; then fail "live: the head sha must never be used as a ref: $CALLS"; else pass "live: no call uses the head sha as a ref"; fi

live_case 'dependabot[bot]' Bot '{"permission":"write","role_name":"write"}'
expect "live: a bot author is outside without a review -> fail" fail "@yotamleo"
if grepq "$CALLS" -F "/collaborators/"; then fail "live: a bot must not consult the collaborator-permission API"; else pass "live: a bot skips the collaborator-permission API"; fi

live_case outsider User '{"permission":"read","role_name":"read"}'
touch "$TMP/stub/perm-404"
OUT=$(STUB_DIR="$TMP/stub" PATH="$TMP/bin:$PATH" node "$GATE" --repo o/r --pr-number 7 --base-sha ba5e999 2>&1); RC=$?
expect "live: permission 404 (not a collaborator) is outside -> fail" fail "@yotamleo"

live_case outsider User '{"permission":"read","role_name":"read"}'
touch "$TMP/stub/reviews-fail"
OUT=$(STUB_DIR="$TMP/stub" PATH="$TMP/bin:$PATH" node "$GATE" --repo o/r --pr-number 7 --base-sha ba5e999 2>&1); RC=$?
expect "live: a non-404 gh failure -> ERROR rc 2 (never a pass)" error

# A PR at the API's 3000-file listing cap has an incomplete file list: never a pass.
LIVE_CHANGED=3000 live_case outsider User '{"permission":"read","role_name":"read"}' "$APPROVED_HEAD"
expect "live: a PR at the 3000-file listing cap -> ERROR (fail closed)" error
LIVE_CHANGED=2999 live_case outsider User '{"permission":"read","role_name":"read"}' "$APPROVED_HEAD"
expect "live: a PR just under the cap is still judged -> pass" pass

# Filenames travel as JSON: trailing whitespace must not be trimmed into a
# different CODEOWNERS match ("pad.md " is NOT /pad.md, so the global @other applies).
LIVE_FILES='"pad.md "' LIVE_OWNERS='* @other\n/pad.md @yotamleo' live_case outsider User '{"permission":"read","role_name":"read"}' "$APPROVED_HEAD"
expect "live: a filename with trailing whitespace is matched byte-exact -> fail" fail "@other"
LIVE_FILES='"pad.md"' LIVE_OWNERS='* @other\n/pad.md @yotamleo' live_case outsider User '{"permission":"read","role_name":"read"}' "$APPROVED_HEAD"
expect "live: the same name without the space matches /pad.md -> pass" pass

# ---------------------------------------------------------------- part 3
echo "== part 3: workflow static assertions =="

# wf_violations <yaml> — one line per violation, nothing when clean.
# Comments are stripped first so prose explaining a rule never trips the rule.
wf_violations() {
  local f="$1" s
  s="$TMP/stripped.yml"
  sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' "$f" > "$s"

  grep -qE 'pull_request_target' "$s" && echo "uses pull_request_target"
  grep -qE 'workflow_run' "$s" && echo "uses workflow_run"
  grep -qE 'actions/checkout' "$s" && echo "uses actions/checkout"
  grep -qE 'github\.head_ref|head\.ref|head\.sha' "$s" && echo "references the PR head ref/sha"
  grep -qE 'base\.sha' "$s" || echo "never reads the base sha"

  # every `uses:` pinned by a full 40-hex commit sha
  unpinned=$(grep -E '^[[:space:]]*-?[[:space:]]*uses:' "$s" | grep -Ev '@[0-9a-f]{40}([[:space:]]|$)' || true)
  [ -z "$unpinned" ] || echo "an action is not pinned by full commit sha"

  # top-level permissions block is exactly contents: read + pull-requests: read
  local perms
  perms=$(awk '/^permissions:/{p=1;next} p&&/^[^[:space:]]/{p=0} p&&NF{gsub(/^[[:space:]]+|[[:space:]]+$/,"");print}' "$s" | sort | tr '\n' '|')
  [ "$perms" = "contents: read|pull-requests: read|" ] || echo "permissions block is not exactly contents+pull-requests read (got: $perms)"
  grep -qE 'write' "$s" && echo "mentions write (permission or otherwise)"

  # no ${{ }} inside any run: block
  awk '
    { match($0,/^ */); ind=RLENGTH }
    inrun && ($0 ~ /^ *$/ || ind > runind) { if ($0 ~ /\$\{\{/) print "expression interpolated in run: " $0; next }
    { inrun=0 }
    $0 ~ /^ *(- )?run:/ {
      runind = ind + (($0 ~ /^ *- /) ? 2 : 0)
      if ($0 ~ /\$\{\{/) print "expression interpolated in run: " $0
      if ($0 ~ /run: *[|>]/) inrun=1
    }
  ' "$s"

  # triggers and job name
  grep -qE '^  pull_request:' "$s" || echo "no pull_request trigger"
  grep -qE '^  pull_request_review:' "$s" || echo "no pull_request_review trigger"
  # `edited` covers a retarget: the new base carries its own CODEOWNERS and base sha.
  grep -qE 'types: *\[opened, synchronize, reopened, ready_for_review, edited\]' "$s" || echo "pull_request types wrong"
  grep -qE 'types: *\[submitted, dismissed, edited\]' "$s" || echo "pull_request_review types wrong"
  # A missing script may only pass as the bootstrap on the default branch.
  # shellcheck disable=SC2016  # the literal `$BASE_REF` text is the pattern
  unconfined=$(grep -F 'HTTP 404' "$s" | grep -vF '"$BASE_REF" = "$DEFAULT_BRANCH"' || true)
  [ -z "$unconfined" ] || echo "404 bootstrap is not confined to the default branch"
  grep -qE '^    name: codeowner-review-gate$' "$s" || echo "job name is not codeowner-review-gate"
  return 0
}

if [ -f "$WF" ]; then
  V=$(wf_violations "$WF")
  if [ -z "$V" ]; then pass "real workflow: zero static violations"; else fail "real workflow violations: $V"; fi
else
  fail "real workflow: cannot check, file absent"
fi

# Negative controls: a known-good skeleton passes; each single mutation is caught.
GOOD="$TMP/good.yml"
cat > "$GOOD" <<'YAML'
name: codeowner-review-gate
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review, edited]
  pull_request_review:
    types: [submitted, dismissed, edited]
permissions:
  contents: read
  pull-requests: read
jobs:
  gate:
    name: codeowner-review-gate
    runs-on: ubuntu-latest
    steps:
      - name: Fetch
        env:
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
        run: |
          echo "$BASE_SHA"
YAML
V=$(wf_violations "$GOOD")
if [ -z "$V" ]; then pass "control: known-good skeleton has zero violations"; else fail "control: known-good skeleton flagged: $V"; fi

mutate() { # <label> <expected-substring> <sed-expr>
  sed -e "$3" "$GOOD" > "$TMP/bad.yml"
  local v; v=$(wf_violations "$TMP/bad.yml")
  if grepq "$v" -F -- "$2"; then pass "control: $1 is caught"; else fail "control: $1 NOT caught (got: ${v:-nothing})"; fi
}
mutate "pull_request_target trigger" "pull_request_target" 's/^  pull_request:/  pull_request_target:/'
mutate "workflow_run trigger"        "workflow_run"        's/^  pull_request_review:/  workflow_run:/'
mutate "an unpinned action"          "not pinned"          's|^    steps:|    steps:\n      - uses: some/action@v1|'
mutate "a tag-pinned checkout"       "actions/checkout"    's|^    steps:|    steps:\n      - uses: actions/checkout@v7|'
mutate "a sha-pinned checkout"       "actions/checkout"    's|^    steps:|    steps:\n      - uses: actions/checkout@0123456789abcdef0123456789abcdef01234567|'
mutate "head sha as a ref"           "head ref/sha"        's|base\.sha|head.sha|'
mutate "an extra write permission"   "permissions block"   's/^  contents: read/  contents: write/'
mutate "a widened permission block"  "permissions block"   's/^  pull-requests: read/  pull-requests: read\n  issues: read/'
# shellcheck disable=SC2016  # single quotes intentional: the ${{ }} must reach sed literally
mutate "expression in a run block"   "interpolated in run" 's|echo "\$BASE_SHA"|echo "${{ github.event.pull_request.title }}"|'
# shellcheck disable=SC2016  # as above
mutate "expression in a one-line run" "interpolated in run" 's|^        run: \|$|        run: echo ${{ github.head_ref }}|'
mutate "a wrong job name"            "job name"            's/^    name: codeowner-review-gate$/    name: gate/'
mutate "a missing review trigger"    "pull_request_review" 's/^  pull_request_review:/  issue_comment:/'
mutate "a dropped edited trigger"    "pull_request types"  '/ready_for_review/s/, edited\]$/]/'
mutate "an unconfined 404 bootstrap" "404 bootstrap"       's|^    steps:|    steps:\n      - run: grep -q "HTTP 404" err|'

echo
if [ "$failures" -eq 0 ]; then
  echo "test-codeowner-review-gate: all passed"
  exit 0
fi
echo "test-codeowner-review-gate: $failures FAILED"
exit 1
