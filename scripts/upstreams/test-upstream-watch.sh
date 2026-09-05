#!/usr/bin/env bash
# scripts/upstreams/test-upstream-watch.sh — hermetic suite for the daily
# upstream-watch delta scan (HIMMEL-2367, extended HIMMEL-2426: report
# bucketing and the null-row guard).
#
# Never touches the real gh/state/handover/registry: gh is replaced by a fake
# driven by a $STATE/world.json fixture (UPSTREAM_WATCH_GH), state lands in a
# scratch dir (UPSTREAM_WATCH_STATE_DIR), the report lands in a scratch
# HANDOVER_DIR, the report BUCKET resolves via a scratch registry.json
# (HANDOVER_REGISTRY), and UPSTREAM_WATCH_HIMMEL_ROOT points at an empty dir
# so send_telegram's .env lookup can never reach the real one (it also doubles
# as the checkout path matched against the registry).
#
# bash 3.2-safe: no mapfile, no associative arrays.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WATCH="$SCRIPT_DIR/upstream-watch.sh"

fails=0
pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; fails=$((fails + 1)); }

assert_eq() {
  local want="$1" got="$2" label="$3"
  if [ "$want" = "$got" ]; then pass "$label"
  else fail "$label — expected '$want' got '$got'"; fi
}

assert_has() {
  local hay="$1" needle="$2" label="$3"
  case "$hay" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label — '$needle' not found in: $hay" ;;
  esac
}

assert_not_has() {
  local hay="$1" needle="$2" label="$3"
  case "$hay" in
    *"$needle"*) fail "$label — unexpected '$needle' found in: $hay" ;;
    *) pass "$label" ;;
  esac
}

# assert_no_cr_in_file <file> <label> -- inspects the FILE's actual bytes
# (not a command-substitution-mangled variable) for a literal CR. Pins the
# HIMMEL-2407 root cause directly: `tr -d '\r'` round-trips identically iff
# no \r byte was present.
assert_no_cr_in_file() {
  local file="$1" label="$2"
  # shellcheck disable=SC2094  # read-only, twice: no write touches $file here
  if LC_ALL=C tr -d '\r' < "$file" | cmp -s - "$file"; then
    pass "$label"
  else
    fail "$label — CR byte(s) found in $file"
  fi
}

# --- fake gh, driven by $1/world.json -------------------------------------
make_fake_gh() {
  local state="$1" f="$1/gh"
  cat > "$f" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
state="$(cd "$(dirname "$0")" && pwd)"
world="$state/world.json"
echo "$*" >> "$state/calls"

fail_call() { echo "fake gh: simulated failure for $1" >&2; exit 1; }

if [ "$1" = "api" ] && [ "$2" = "user" ]; then
  [ -f "$state/fail_user" ] && fail_call user
  jq -r '.me' "$world"
  exit 0
fi

if [ "$1" = "search" ]; then
  kind="$2"
  [ -f "$state/fail_search_$kind" ] && fail_call "search $kind"
  jq -c --arg k "$kind" '.[$k] // []' "$world"
  exit 0
fi

if [ "$1" = "api" ]; then
  path=""
  for a in "$@"; do
    case "$a" in
      api|--paginate) ;;
      *) path="$a"; break ;;
    esac
  done
  case "$path" in
    repos/*/commits/*/check-runs)
      rest="${path#repos/}"
      nwo="${rest%%/commits/*}"
      sha="${rest#*/commits/}"; sha="${sha%%/check-runs}"
      key="$nwo@$sha"
      [ -f "$state/fail_checkruns" ] && fail_call checkruns
      jq -c --arg k "$key" '(.check_runs[$k] // [])[]' "$world" 2>/dev/null
      exit 0
      ;;
  esac
  fail_call "unhandled api $path"
fi

# gh pr/issue view takes ONE positional selector plus --repo OWNER/REPO
# (real gh rejects a second positional arg) — mirror that shape here so a
# regression back to the old two-positional-arg form fails this fake
# immediately instead of silently "working" against a fixture that never
# modeled the real CLI contract (HIMMEL-2367 codex-1/codex-2).
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  num="$3"; nwo=""; jsonfields=""; prev=""
  for a in "$@"; do
    if [ "$prev" = "--repo" ]; then nwo="$a"; fi
    if [ "$prev" = "--json" ]; then jsonfields="$a"; fi
    prev="$a"
  done
  if [ -z "$nwo" ]; then fail_call "pr view missing --repo"; fi
  key="$nwo#$num"
  if [ -f "$state/fail_prview_$num" ]; then fail_call "pr view $num"; fi
  case "$jsonfields" in
    *headRefOid*) jq -c --arg k "$key" '.pr_views[$k]' "$world" ;;
    *) jq -c --arg k "$key" '.dispositions[$k]' "$world" ;;
  esac
  exit 0
fi

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  num="$3"; nwo=""; jsonfields=""; prev=""
  for a in "$@"; do
    if [ "$prev" = "--repo" ]; then nwo="$a"; fi
    if [ "$prev" = "--json" ]; then jsonfields="$a"; fi
    prev="$a"
  done
  if [ -z "$nwo" ]; then fail_call "issue view missing --repo"; fi
  key="$nwo#$num"
  case "$jsonfields" in
    *mergedAt*) fail_call "issue view requested invalid field mergedAt" ;;
    *comments*) jq -c --arg k "$key" '.issue_views[$k]' "$world" ;;
    *) jq -c --arg k "$key" '.dispositions[$k]' "$world" ;;
  esac
  exit 0
fi

fail_call "unhandled invocation: $*"
FAKE
  chmod +x "$f"
  printf '%s' "$f"
}

# A baseline world: one open PR (2 comments, success CI, mergeable) plus one
# open issue that stays constant across delta tests — the issue's presence
# keeps total item count > 0 when a vanished-item test drops the PR, so that
# case exercises the vanished path rather than the positive-control refusal.
# Also the ONLY fixture with two authored items sorted alphabetically as
# "acme/other#7" then "acme/widget#12" — that ordering is what reproduced the
# HIMMEL-2407 CRLF defect (see assert_no_cr_in_file below): native Windows jq
# writes CRLF per LINE of a multi-line `jq -r` array dump, and bash's `$(...)`
# strips only the FINAL trailing newline, so every non-last line keeps its \r.
base_world() {
  jq -n '{
    me: "me",
    prs: [ {repository:{nameWithOwner:"acme/widget"}, number:12, title:"fix thing", url:"https://github.com/acme/widget/pull/12", updatedAt:"2026-08-01T00:00:00Z", state:"open"} ],
    issues: [ {repository:{nameWithOwner:"acme/other"}, number:7, title:"steady issue", url:"https://github.com/acme/other/issues/7", updatedAt:"2026-08-01T00:00:00Z", state:"open"} ],
    pr_views: {
      "acme/widget#12": {headRefOid:"deadbeef", mergeable:"MERGEABLE", mergeStateStatus:"CLEAN", state:"OPEN", updatedAt:"2026-08-01T00:00:00Z",
        title:"fix thing", url:"https://github.com/acme/widget/pull/12",
        comments:[{author:{login:"other"}, createdAt:"2026-07-30T00:00:00Z"},{author:{login:"other"}, createdAt:"2026-07-31T00:00:00Z"}],
        reviews:[{author:{login:"other"}}]}
    },
    issue_views: {
      "acme/other#7": {comments:[], state:"OPEN", updatedAt:"2026-08-01T00:00:00Z", closedAt:null, title:"steady issue", url:"https://github.com/acme/other/issues/7"}
    },
    check_runs: { "acme/widget@deadbeef": [ {name:"build", status:"completed", conclusion:"success"} ] },
    dispositions: {}
  }'
}

# seed_baseline <state> -- prime the state file with one successful first run.
# Every caller depends on the snapshot this leaves behind, so a FAILED baseline
# must NOT be swallowed. This used to be `run_watch "$state" >/dev/null 2>&1`,
# and when a loaded box made the baseline exit 2 (state untouched, no report)
# the NEXT run legitimately reported "## New" again -- which surfaced two lines
# later as an inexplicable "report shows +1 comment" failure whose real cause
# had been discarded. Fail here, where the message says what actually happened.
seed_baseline() {
  local out rc=0
  out=$(run_watch "$1" 2>&1) || rc=$?
  [ "$rc" -eq 10 ] && return 0
  fail "baseline run: expected exit 10 (delta on a first run), got $rc — output: $out"
  return 1
}

run_watch() {
  local state="$1"; shift
  UPSTREAM_WATCH_GH="$state/gh" \
    UPSTREAM_WATCH_STATE_DIR="$state/himmel-state" \
    UPSTREAM_WATCH_HIMMEL_ROOT="$state/empty-root" \
    HANDOVER_DIR="$state/handover" \
    HANDOVER_REGISTRY="$state/registry.json" \
    bash "$WATCH" "$@"
}

# report_path <state> -- the report location the fixture registry (user
# "testuser", bucket "himmel") predicts for today's date. Tests assert the
# SCRIPT actually wrote there (not just that some file exists somewhere).
report_path() {
  printf '%s/handover/testuser/himmel/specs/reports/upstream-watch-%s.md' "$1" "$(date -u +%Y-%m-%d)"
}

new_scratch() {
  local state
  state=$(mktemp -d "${TMPDIR:-/tmp}/upstream-watch-test.XXXXXX")
  make_fake_gh "$state" >/dev/null
  mkdir -p "$state/empty-root" "$state/handover"
  jq -n --arg path "$state/empty-root" \
    '{repos: {himmel: {path: $path, user: "testuser", bucket_name: "himmel"}}}' \
    > "$state/registry.json"
  printf '%s' "$state"
}

echo "== test: first-run delta =="
state=$(new_scratch)
base_world > "$state/world.json"
out=$(run_watch "$state" 2>&1); rc=$?
assert_eq 10 "$rc" "first run: delta exit code"
report="$(report_path "$state")"
if [ -f "$report" ]; then pass "first run: report file written"; else fail "first run: report file missing"; fi
found_report=$(find "$state/handover" -name 'upstream-watch-*.md' 2>/dev/null | head -1)
assert_has "$found_report" "/testuser/himmel/specs/reports/" "first run: report lands under <user>/<repo-bucket>/specs/reports (resolved via registry)"
assert_has "$(cat "$report" 2>/dev/null)" "## New" "first run: report has New section"
# Positive control (HIMMEL-2407 regression): the real title/url must render,
# not "(null)" — see base_world's comment on why two sorted authored items
# are required to expose the CRLF defect this pins.
assert_has "$(cat "$report" 2>/dev/null)" "[acme/widget#12](https://github.com/acme/widget/pull/12) — fix thing" "first run: New row carries the real url+title (positive control)"
assert_has "$(cat "$report" 2>/dev/null)" "[acme/other#7](https://github.com/acme/other/issues/7) — steady issue" "first run: New row for the alphabetically-first item also carries its real url+title"
assert_no_cr_in_file "$report" "first run: no CR byte survives into the rendered report"
if [ -f "$state/himmel-state/last_seen.json" ]; then pass "first run: state file written"; else fail "first run: state file missing"; fi

echo "== test: no-delta re-run =="
state=$(new_scratch)
base_world > "$state/world.json"
seed_baseline "$state"
before=$(cat "$state/himmel-state/last_seen.json")
out=$(run_watch "$state" 2>&1); rc=$?
assert_eq 0 "$rc" "no-delta rerun: exit code"
after=$(cat "$state/himmel-state/last_seen.json")
items_before=$(printf '%s' "$before" | jq -c '.items')
items_after=$(printf '%s' "$after" | jq -c '.items')
assert_eq "$items_before" "$items_after" "no-delta rerun: state items unchanged"

echo "== test: comment-count delta =="
state=$(new_scratch)
base_world > "$state/world.json"
seed_baseline "$state"
base_world | jq '.pr_views["acme/widget#12"].comments += [{author:{login:"other"}, createdAt:"2026-08-02T00:00:00Z"}]' > "$state/world.json"
out=$(run_watch "$state" 2>&1); rc=$?
assert_eq 10 "$rc" "comment delta: exit code"
report="$(report_path "$state")"
assert_has "$(cat "$report" 2>/dev/null)" "comments +1" "comment delta: report shows +1 comment"

echo "== test: CI-flip delta =="
state=$(new_scratch)
base_world > "$state/world.json"
seed_baseline "$state"
base_world | jq '.check_runs["acme/widget@deadbeef"] = [{name:"build", status:"completed", conclusion:"failure"}]' > "$state/world.json"
out=$(run_watch "$state" 2>&1); rc=$?
assert_eq 10 "$rc" "CI-flip delta: exit code"
report="$(report_path "$state")"
assert_has "$(cat "$report" 2>/dev/null)" "CI: success -> failure" "CI-flip delta: report shows CI change"

echo "== test: vanished-item delta (merged) =="
state=$(new_scratch)
base_world > "$state/world.json"
seed_baseline "$state"
base_world | jq '.prs = [] | .dispositions["acme/widget#12"] = {state:"MERGED", mergedAt:"2026-08-05T00:00:00Z", closedAt:"2026-08-05T00:00:00Z"}' > "$state/world.json"
out=$(run_watch "$state" 2>&1); rc=$?
assert_eq 10 "$rc" "vanished delta: exit code"
report="$(report_path "$state")"
assert_has "$(cat "$report" 2>/dev/null)" "## Closed / merged" "vanished delta: report has Closed/merged section"
assert_has "$(cat "$report" 2>/dev/null)" "(merged)" "vanished delta: item labeled merged"

echo "== test: positive-control refusal (0 items vs nonzero last-seen) =="
state=$(new_scratch)
base_world > "$state/world.json"
seed_baseline "$state"
before=$(cat "$state/himmel-state/last_seen.json")
jq -n '{me:"me", prs: [], issues: [], pr_views:{}, issue_views:{}, check_runs:{}, dispositions:{}}' > "$state/world.json"
out=$(run_watch "$state" 2>&1); rc=$?
assert_eq 2 "$rc" "positive control: exit code"
assert_has "$out" "instrument failure suspected" "positive control: error names instrument failure"
after=$(cat "$state/himmel-state/last_seen.json")
assert_eq "$before" "$after" "positive control: state file untouched"

echo "== test: gh auth failure =="
state=$(new_scratch)
base_world > "$state/world.json"
touch "$state/fail_user"
out=$(run_watch "$state" 2>&1); rc=$?
assert_eq 2 "$rc" "auth failure: exit code"
assert_has "$out" "could not resolve identity" "auth failure: error names identity resolution"
if [ -f "$state/himmel-state/last_seen.json" ]; then fail "auth failure: state file should not exist"; else pass "auth failure: no state file written"; fi

echo "== test: node dependency guard (HIMMEL-2470, shape from HIMMEL-2426) =="
state=$(new_scratch)
base_world > "$state/world.json"

# A curated allowlist PATH -- a scratch dir holding ONLY forwarding shims for
# the tools the script needs before its own node check (bash itself, dirname
# -- used at SCRIPT_DIR resolution -- jq, tr, git), each resolved from THIS
# host's live PATH rather than a hardcoded /usr/bin, and NO node.
#
# A directory-stripping approach (the prior version of this test) breaks on
# any host where node shares a directory with bash/jq/tr/git -- a stock
# Linux box has all of them in /usr/bin: stripping that directory kills the
# invoking `bash` before it can even reach the script (rc 127, wrong
# failure), or -- if bash is invoked by absolute path to dodge that -- trips
# the jq/tr guard first instead of the node guard (still the wrong failure).
# An allowlist has neither failure mode: node is simply never placed in it.
#
# Each shim is a tiny wrapper script (`exec "$real_path" "$@"`), not a
# symlink/copy of the binary itself -- MSYS/Cygwin binaries (bash, tr,
# dirname under Git for Windows) resolve their sibling runtime DLL relative
# to argv0's invocation path, so a copy or symlink dropped in a foreign
# directory fails to load ("error while loading shared libraries") even
# though the real binary works fine. A wrapper whose shebang points at the
# real absolute bash and whose body execs the real absolute tool path never
# relocates anything, so it has no such failure mode on Windows and works
# identically (if trivially) on Linux/macOS.
node_free_bin="$state/no-node-bin"
mkdir -p "$node_free_bin"
missing_tool=""
real_bash=$(command -v bash 2>/dev/null) || missing_tool="bash"
if [ -n "$real_bash" ]; then
  for tool in jq tr dirname git; do
    tpath=$(command -v "$tool" 2>/dev/null) || { missing_tool="$tool"; break; }
    printf '#!%s\nexec "%s" "$@"\n' "$real_bash" "$tpath" > "$node_free_bin/$tool"
    chmod +x "$node_free_bin/$tool"
  done
fi
cp "$state/gh" "$node_free_bin/gh" 2>/dev/null && chmod +x "$node_free_bin/gh"

if [ -n "$missing_tool" ]; then
  echo "  SKIP — could not resolve '$missing_tool' on this host's PATH to build a node-free PATH"
else
  out=$(UPSTREAM_WATCH_GH="$state/gh" \
      UPSTREAM_WATCH_STATE_DIR="$state/himmel-state" \
      UPSTREAM_WATCH_HIMMEL_ROOT="$state/empty-root" \
      HANDOVER_DIR="$state/handover" \
      HANDOVER_REGISTRY="$state/registry.json" \
      PATH="$node_free_bin" \
      "$real_bash" "$WATCH" 2>&1); rc=$?
  assert_eq 2 "$rc" "node guard: exit code"
  assert_has "$out" "node is required but not on PATH" "node guard: error names node"
  assert_not_has "$out" "no handover registry entry" "node guard: does NOT misreport as an unmatched registry entry"
fi

echo "== test: report-write failure leaves state untouched (retries next run) =="
state=$(new_scratch)
base_world > "$state/world.json"
seed_baseline "$state"
before=$(cat "$state/himmel-state/last_seen.json")
base_world | jq '.pr_views["acme/widget#12"].comments += [{author:{login:"other"}, createdAt:"2026-08-02T00:00:00Z"}]' > "$state/world.json"
out=$(UPSTREAM_WATCH_GH="$state/gh" \
    UPSTREAM_WATCH_STATE_DIR="$state/himmel-state" \
    UPSTREAM_WATCH_HIMMEL_ROOT="$state/empty-root" \
    HANDOVER_DIR="$state/nonexistent-handover-dir" \
    bash "$WATCH" 2>&1); rc=$?
assert_eq 2 "$rc" "report-write failure: exit code"
assert_has "$out" "handover_root failed" "report-write failure: error names handover_root"
after=$(cat "$state/himmel-state/last_seen.json")
assert_eq "$before" "$after" "report-write failure: state file untouched (delta retried next run)"

echo "== test: report bucket unresolvable (registry missing) => fail closed =="
state=$(new_scratch)
base_world > "$state/world.json"
seed_baseline "$state"
before=$(cat "$state/himmel-state/last_seen.json")
base_world | jq '.pr_views["acme/widget#12"].comments += [{author:{login:"other"}, createdAt:"2026-08-02T00:00:00Z"}]' > "$state/world.json"
rm -f "$state/registry.json"
out=$(run_watch "$state" 2>&1); rc=$?
assert_eq 2 "$rc" "bucket unresolvable (missing registry): exit code"
assert_has "$out" "registry not found" "bucket unresolvable (missing registry): error names the registry file"
after=$(cat "$state/himmel-state/last_seen.json")
assert_eq "$before" "$after" "bucket unresolvable (missing registry): state file untouched"

echo "== test: report bucket unresolvable (no matching registry entry) => fail closed =="
state=$(new_scratch)
base_world > "$state/world.json"
seed_baseline "$state"
before=$(cat "$state/himmel-state/last_seen.json")
base_world | jq '.pr_views["acme/widget#12"].comments += [{author:{login:"other"}, createdAt:"2026-08-02T00:00:00Z"}]' > "$state/world.json"
jq -n '{repos: {"other-repo": {path: "/somewhere/else", user: "someone", bucket_name: "other-repo"}}}' > "$state/registry.json"
out=$(run_watch "$state" 2>&1); rc=$?
assert_eq 2 "$rc" "bucket unresolvable (no matching entry): exit code"
assert_has "$out" "no handover registry entry" "bucket unresolvable (no matching entry): error names the mismatch"
after=$(cat "$state/himmel-state/last_seen.json")
assert_eq "$before" "$after" "bucket unresolvable (no matching entry): state file untouched"

echo "== test: registry path matching is case-SENSITIVE off Windows (HIMMEL-2426) =="
# The registry entry's path differs from the checkout ONLY by the case of its
# last segment. Windows must still match it (NTFS is case-insensitive and the
# registry stores these paths lowercased, which is why norm() folds case
# there); Linux/macOS must NOT (two checkouts differing only by case are two
# different checkouts, and matching the wrong one routes the report to another
# repo's bucket). So this asserts the platform-appropriate outcome rather than
# one universal answer. Non-vacuity control: the EXACT-case form of this same
# fixture registry is what "registry user/bucket_name valid still resolves the
# report" above exercises, and it exits 10 -- so a refusal here can only come
# from the case difference.
state=$(new_scratch)
base_world > "$state/world.json"
seed_baseline "$state"
before=$(cat "$state/himmel-state/last_seen.json")
base_world | jq '.pr_views["acme/widget#12"].comments += [{author:{login:"other"}, createdAt:"2026-08-02T00:00:00Z"}]' > "$state/world.json"
jq -n --arg path "$state/EMPTY-ROOT" '{repos: {himmel: {path: $path, user: "testuser", bucket_name: "himmel"}}}' > "$state/registry.json"
out=$(run_watch "$state" 2>&1); rc=$?
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    assert_eq 10 "$rc" "case-only path difference: Windows still matches (case-insensitive FS)" ;;
  *)
    assert_eq 2 "$rc" "case-only path difference: refused off Windows (case-sensitive FS)"
    assert_has "$out" "no handover registry entry" "case-only path difference: names the mismatch"
    after=$(cat "$state/himmel-state/last_seen.json")
    assert_eq "$before" "$after" "case-only path difference: state file untouched" ;;
esac

echo "== test: malformed registry entry (null) is a validation error, NOT a non-match (HIMMEL-2426) =="
state=$(new_scratch)
base_world > "$state/world.json"
seed_baseline "$state"
before=$(cat "$state/himmel-state/last_seen.json")
base_world | jq '.pr_views["acme/widget#12"].comments += [{author:{login:"other"}, createdAt:"2026-08-02T00:00:00Z"}]' > "$state/world.json"
# Structurally valid JSON whose FIRST repo entry is null. Dereferencing it used
# to throw an uncaught TypeError (rc=1), which the caller reported as "no
# handover registry entry matches this checkout" -- malformed structure wearing
# a benign verdict. The GOOD entry that follows it is the non-vacuity control:
# without the null this registry resolves the bucket and the run would exit 10,
# so a rc=2 here can only come from the malformed entry.
jq -n --arg root "$state/empty-root" '{repos: {"aaa-broken": null, "himmel": {path: $root, user: "testuser", bucket_name: "himmel"}}}' > "$state/registry.json"
out=$(run_watch "$state" 2>&1); rc=$?
assert_eq 2 "$rc" "malformed registry entry: exit code"
assert_has "$out" "aaa-broken" "malformed registry entry: error names the offending key"
assert_not_has "$out" "no handover registry entry" "malformed registry entry: NOT misreported as an unmatched registry entry"
after=$(cat "$state/himmel-state/last_seen.json")
assert_eq "$before" "$after" "malformed registry entry: state file untouched"

echo "== test: registry bucket_name '..' is rejected as an unsafe path component (HIMMEL-2426) =="
state=$(new_scratch)
base_world > "$state/world.json"
seed_baseline "$state"
before=$(cat "$state/himmel-state/last_seen.json")
base_world | jq '.pr_views["acme/widget#12"].comments += [{author:{login:"other"}, createdAt:"2026-08-02T00:00:00Z"}]' > "$state/world.json"
jq -n --arg path "$state/empty-root" \
  '{repos: {himmel: {path: $path, user: "testuser", bucket_name: ".."}}}' \
  > "$state/registry.json"
out=$(run_watch "$state" 2>&1); rc=$?
assert_eq 2 "$rc" "bucket_name '..': exit code"
assert_has "$out" "bucket_name" "bucket_name '..': error names the bucket_name field"
assert_has "$out" "'..'" "bucket_name '..': error names the offending value"
after=$(cat "$state/himmel-state/last_seen.json")
assert_eq "$before" "$after" "bucket_name '..': state file untouched"

echo "== test: registry bucket_name containing '/' is rejected as an unsafe path component (HIMMEL-2426) =="
state=$(new_scratch)
base_world > "$state/world.json"
seed_baseline "$state"
before=$(cat "$state/himmel-state/last_seen.json")
base_world | jq '.pr_views["acme/widget#12"].comments += [{author:{login:"other"}, createdAt:"2026-08-02T00:00:00Z"}]' > "$state/world.json"
jq -n --arg path "$state/empty-root" \
  '{repos: {himmel: {path: $path, user: "testuser", bucket_name: "foo/bar"}}}' \
  > "$state/registry.json"
out=$(run_watch "$state" 2>&1); rc=$?
assert_eq 2 "$rc" "bucket_name with '/': exit code"
assert_has "$out" "bucket_name" "bucket_name with '/': error names the bucket_name field"
after=$(cat "$state/himmel-state/last_seen.json")
assert_eq "$before" "$after" "bucket_name with '/': state file untouched"

echo "== test: registry user '..' is rejected as an unsafe path component (HIMMEL-2426) =="
state=$(new_scratch)
base_world > "$state/world.json"
seed_baseline "$state"
before=$(cat "$state/himmel-state/last_seen.json")
base_world | jq '.pr_views["acme/widget#12"].comments += [{author:{login:"other"}, createdAt:"2026-08-02T00:00:00Z"}]' > "$state/world.json"
jq -n --arg path "$state/empty-root" \
  '{repos: {himmel: {path: $path, user: "..", bucket_name: "himmel"}}}' \
  > "$state/registry.json"
out=$(run_watch "$state" 2>&1); rc=$?
assert_eq 2 "$rc" "user '..': exit code"
assert_has "$out" "REPORT_USER" "user '..': error names the REPORT_USER field"
after=$(cat "$state/himmel-state/last_seen.json")
assert_eq "$before" "$after" "user '..': state file untouched"

echo "== test: registry user/bucket_name valid still resolves the report (positive control, HIMMEL-2426) =="
state=$(new_scratch)
base_world > "$state/world.json"
seed_baseline "$state"
base_world | jq '.pr_views["acme/widget#12"].comments += [{author:{login:"other"}, createdAt:"2026-08-02T00:00:00Z"}]' > "$state/world.json"
out=$(run_watch "$state" 2>&1); rc=$?
assert_eq 10 "$rc" "valid user/bucket_name: exit code (positive control)"
report="$(report_path "$state")"
if [ -f "$report" ]; then pass "valid user/bucket_name: report file written"; else fail "valid user/bucket_name: report file missing"; fi

echo "== test: required render field null/empty => refuse, never render (null) =="
state=$(new_scratch)
base_world | jq '.pr_views["acme/widget#12"].title = null' > "$state/world.json"
out=$(run_watch "$state" 2>&1); rc=$?
assert_eq 2 "$rc" "null field: exit code"
assert_has "$out" "required field" "null field: error names the required-field guard"
if [ -f "$state/himmel-state/last_seen.json" ]; then fail "null field: state file should not exist"; else pass "null field: no state file written"; fi
assert_not_has "$out" "(null)" "null field: never renders a literal (null) row"

echo
if [ "$fails" -eq 0 ]; then
  echo "SUMMARY: all tests passed"
  exit 0
else
  echo "SUMMARY: $fails test(s) FAILED"
  exit 1
fi
