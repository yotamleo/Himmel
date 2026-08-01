#!/usr/bin/env bash
# scripts/upstreams/test-resync-fork.sh — hermetic suite for the fork-resync
# auditor (HIMMEL-1323 follow-up).
#
# Fully offline: every case builds TWO real local git repos under a temp dir
# (a fake "upstream" and a clone of it standing in for the himmel "fork"),
# points a synthetic scripts/upstreams.json at them via local filesystem
# paths (git treats a local path as an ordinary remote — clone/fetch/push all
# work with zero network), and lets the script exercise genuine git rebase
# behaviour against them. No gh, no real qmd/tobi repos, no writes to any
# remote the operator owns.
#
# bash 3.2-safe (macOS ships 3.2): no mapfile, no associative arrays.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RESYNC="$SCRIPT_DIR/resync-fork.sh"

fails=0
pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; fails=$((fails + 1)); }

# assert_rc <expected-rc> <label> -- <command...>
assert_rc() {
  local want="$1" label="$2"; shift 3
  local out rc
  out=$("$@" 2>&1)
  rc=$?
  if [ "$rc" -eq "$want" ]; then
    pass "$label (rc=$rc)"
  else
    fail "$label — expected rc=$want got rc=$rc; output: $out"
  fi
}

assert_contains() {
  local hay="$1" needle="$2" label="$3"
  case "$hay" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label — '$needle' not found in: $hay" ;;
  esac
}

# ---------------------------------------------------------------------------
# fixture builders
# ---------------------------------------------------------------------------

# De-hook a repo: a machine-wide core.hooksPath (e.g. tokensave's own
# init/sync hooks, wired into EVERY repo on this box) would otherwise fire on
# every checkout/commit these throwaway fixtures make — each spawning a real
# background process, which is slow and leaves locked .tokensave files behind
# that then fail this script's own `rm -rf` cleanup. Pointing hooksPath back
# at the repo's actual .git/hooks (a fresh `git init`/`git clone` populates it
# with only inert *.sample files) restores git's real default. Called BEFORE
# the first checkout in a freshly cloned repo (not just alongside git_id)
# because post-checkout is exactly one of the hooks in question.
de_hook() {
  git -C "$1" config core.hooksPath .git/hooks
}

git_id() {
  git -C "$1" config user.email "test@example.com"
  git -C "$1" config user.name "Test"
  # Local-only, never global: a machine with commit.gpgsign=true (SSH signing
  # through an agent, e.g. 1Password) would otherwise block every fixture
  # commit below on an interactive signing prompt — exactly the kind of
  # dependency a hermetic test must not have.
  git -C "$1" config commit.gpgsign false
  de_hook "$1"
}

# clone_fork <upstream-dir> <fork-dir>
#   De-hooks the clone BEFORE the checkout that follows it (see de_hook) —
#   plain git_id (called after checkout in the original, pre-fix version of
#   this fixture) was too late: post-checkout had already fired.
clone_fork() {
  git clone --quiet "$1" "$2" >/dev/null 2>&1
  de_hook "$2"
}

# make_repos <case> <root>
#   Builds $root/upstream and $root/fork as real git repos. upstream always
#   carries a base commit tagged 1.0.0. $root/fork is checked out AT 1.0.0
#   and then diverges per <case>. Prints the fork's tip SHA (the "pinned
#   commit" the fixture registry will point at).
#
#   additive  — upstream advances an UNRELATED file (OTHER.md), tags 1.1.0;
#               fork adds a brand-new file (EXTRA.md). Clean rebase, additive.
#   modify    — upstream advances OTHER.md, tags 1.1.0; fork EDITS README.md
#               (a file that already existed at the base). Clean rebase
#               (upstream never touched README.md), but NOT additive.
#   conflict  — upstream ADDS NEWFILE.md with content X, tags 1.1.0; fork
#               (branched before that commit) ALSO adds NEWFILE.md, with
#               different content. The fork's own delta is pure addition
#               (additive by this script's definition — a property of the
#               delta against ITS OWN base, not the rebase target), but
#               replaying it onto 1.1.0 is a genuine add/add conflict.
#   none      — upstream has only tag 1.0.0 (never advances); fork == base,
#               no fork-only commits at all. Used for the "nothing to do"
#               case.
make_repos() {
  local case="$1" root="$2" upstream fork
  upstream="$root/upstream"
  fork="$root/fork"

  git init --quiet "$upstream"
  git_id "$upstream"
  printf 'line one\n' > "$upstream/README.md"
  printf 'other v1\n' > "$upstream/OTHER.md"
  git -C "$upstream" add README.md OTHER.md
  git -C "$upstream" commit --quiet -m base
  git -C "$upstream" tag 1.0.0

  case "$case" in
    none)
      clone_fork "$upstream" "$fork"
      git -C "$fork" checkout --quiet 1.0.0
      git_id "$fork"
      ;;
    additive)
      printf 'other v2\n' > "$upstream/OTHER.md"
      git -C "$upstream" add OTHER.md
      git -C "$upstream" commit --quiet -m "upstream: advance OTHER.md"
      git -C "$upstream" tag 1.1.0
      clone_fork "$upstream" "$fork"
      git -C "$fork" checkout --quiet 1.0.0
      git_id "$fork"
      printf 'fork addition\n' > "$fork/EXTRA.md"
      git -C "$fork" add EXTRA.md
      git -C "$fork" commit --quiet -m "fork: add EXTRA.md"
      ;;
    modify)
      printf 'other v2\n' > "$upstream/OTHER.md"
      git -C "$upstream" add OTHER.md
      git -C "$upstream" commit --quiet -m "upstream: advance OTHER.md"
      git -C "$upstream" tag 1.1.0
      clone_fork "$upstream" "$fork"
      git -C "$fork" checkout --quiet 1.0.0
      git_id "$fork"
      printf 'line one\nfork edited this upstream file\n' > "$fork/README.md"
      git -C "$fork" add README.md
      git -C "$fork" commit --quiet -m "fork: edit README.md (an upstream file)"
      ;;
    conflict)
      printf 'upstream NEWFILE contents\n' > "$upstream/NEWFILE.md"
      git -C "$upstream" add NEWFILE.md
      git -C "$upstream" commit --quiet -m "upstream: also add NEWFILE.md"
      git -C "$upstream" tag 1.1.0
      clone_fork "$upstream" "$fork"
      git -C "$fork" checkout --quiet 1.0.0
      git_id "$fork"
      printf 'fork NEWFILE contents (diverging)\n' > "$fork/NEWFILE.md"
      git -C "$fork" add NEWFILE.md
      git -C "$fork" commit --quiet -m "fork: add NEWFILE.md"
      ;;
    *)
      echo "make_repos: unknown case '$case'" >&2
      return 1
      ;;
  esac
}

# make_registry <root> <pin-sha-or-empty> [synced_base] [pin-file-mode]
#   Writes $root/scripts/lib/fakefork-bin.sh + $root/scripts/upstreams.json,
#   the latter pointing fork_repo/upstream_repo at $root/fork and
#   $root/upstream (local paths — git handles these as ordinary remotes) and
#   work_dir at ${RESYNC_TEST_WORKROOT} (expanded via the env var set by the
#   caller), exercising the same $VAR-expansion path a real machine uses.
#   pin-file-mode: "single" (default, one SHA occurrence), "ref" (an
#   installable tag in marketplace.json via pin_ref_template), "missing" (no
#   occurrence), "double" (two occurrences), "no-fork" (entry with no fork
#   block at all).
make_registry() {
  local root="$1" pin_sha="${2:-}" synced_base="${3:-1.0.0}" pin_mode="${4:-single}"
  mkdir -p "$root/scripts/lib" "$root/marketplace/.claude-plugin"

  case "$pin_mode" in
    single)
      # shellcheck disable=SC2016
      # Single-quoted on purpose: ${FAKEFORK_REF:-...} must land in the
      # fixture FILE literally (the pin literal resync-fork.sh regexes for),
      # not be expanded by this shell — the %s from printf's arg is what
      # supplies the SHA.
      printf '_fakefork_ref() { printf "%%s\\n" "${FAKEFORK_REF:-%s}"; }\n' "$pin_sha" \
        > "$root/scripts/lib/fakefork-bin.sh"
      ;;
    ref)
      printf '{"plugins":[{"name":"fakefork","source":{"ref":"%s"}}]}\n' "$pin_sha" \
        > "$root/marketplace/.claude-plugin/marketplace.json"
      ;;
    missing)
      printf '_fakefork_ref() { printf "%%s\\n" "no pin literal here"; }\n' \
        > "$root/scripts/lib/fakefork-bin.sh"
      ;;
    double)
      {
        # shellcheck disable=SC2016
        printf '_fakefork_ref() { printf "%%s\\n" "${FAKEFORK_REF:-%s}"; }\n' "$pin_sha"
        # shellcheck disable=SC2016
        printf '_fakefork_ref_again() { printf "%%s\\n" "${FAKEFORK_REF:-%s}"; }\n' "$pin_sha"
      } > "$root/scripts/lib/fakefork-bin.sh"
      ;;
  esac

  python3 - "$root" "$synced_base" "$pin_mode" <<'PY'
import json, os, sys
root, synced_base, pin_mode = sys.argv[1], sys.argv[2], sys.argv[3]
entry = {
    "name": "fakefork",
    "kind": "tag_release",
    "mode": "base",
    "tracked_repo": "acme/fakefork",
    "synced_base": synced_base,
    "tier": "B",
    "note": "fixture entry",
}
if pin_mode != "no-fork":
    fork = {
        "fork_repo": os.path.join(root, "fork").replace("\\", "/"),
        "upstream_repo": os.path.join(root, "upstream").replace("\\", "/"),
        "work_dir": "${RESYNC_TEST_WORKROOT}",
    }
    if pin_mode == "ref":
        fork.update({
            "pin_file": "marketplace/.claude-plugin/marketplace.json",
            "pin_ref_template": '"ref":"{ref}"',
        })
    else:
        fork.update({
            "pin_file": "scripts/lib/fakefork-bin.sh",
            "pin_template": "FAKEFORK_REF:-{sha}",
        })
    entry["fork"] = fork
reg = {"_comment": "fixture", "entries": [entry]}
json.dump(reg, open(os.path.join(root, "scripts", "upstreams.json"), "w"), indent=2)
PY
}

run_resync() {
  local root="$1"; shift
  RESYNC_TEST_WORKROOT="$root/scratch" \
    DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" \
    bash "$RESYNC" "$@"
}

# ---------------------------------------------------------------------------

echo "[test-resync-fork] usage + arg validation"
assert_rc 2 "no args is a usage error" -- bash "$RESYNC"
root=$(mktemp -d)
assert_rc 2 "--target with no value is a usage error" -- \
  env RESYNC_TEST_WORKROOT="$root/scratch" DRIFT_REPO_ROOT="$root" \
  DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$RESYNC" fakefork --target
assert_rc 2 "unknown flag rejected" -- \
  env RESYNC_TEST_WORKROOT="$root/scratch" DRIFT_REPO_ROOT="$root" \
  DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$RESYNC" fakefork --nope
rm -rf "$root"

echo "[test-resync-fork] missing registry"
assert_rc 2 "absent registry is rc=2" -- \
  env DRIFT_REPO_ROOT=/nonexistent DRIFT_REGISTRY=/nonexistent/upstreams.json \
  bash "$RESYNC" fakefork

echo "[test-resync-fork] unknown entry name"
root=$(mktemp -d)
make_repos additive "$root"
sha=$(git -C "$root/fork" rev-parse HEAD)
make_registry "$root" "$sha"
assert_rc 2 "unknown entry name is rc=2" -- \
  env RESYNC_TEST_WORKROOT="$root/scratch" DRIFT_REPO_ROOT="$root" \
  DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$RESYNC" nosuch
rm -rf "$root"

echo "[test-resync-fork] no fork block declared -> SKIP (rc=3)"
root=$(mktemp -d)
make_repos additive "$root"
make_registry "$root" "" "1.0.0" "no-fork"
out=$(run_resync "$root" fakefork 2>&1)
rc=$?
if [ "$rc" -eq 3 ]; then pass "no fork block is rc=3 (SKIP)"; else fail "no fork block — expected rc=3 got $rc: $out"; fi
assert_contains "$out" "SKIP fakefork" "prints a SKIP line naming the entry"
rm -rf "$root"

echo "[test-resync-fork] wrong kind/mode is rc=2"
root=$(mktemp -d)
make_repos additive "$root"
sha=$(git -C "$root/fork" rev-parse HEAD)
make_registry "$root" "$sha"
python3 - "$root" <<'PY'
import json, sys
p = sys.argv[1] + "/scripts/upstreams.json"
d = json.load(open(p))
d["entries"][0]["kind"] = "commit_head"
d["entries"][0]["mode"] = "pin"
json.dump(d, open(p, "w"), indent=2)
PY
assert_rc 2 "wrong kind+mode with a fork block is rc=2" -- \
  env RESYNC_TEST_WORKROOT="$root/scratch" DRIFT_REPO_ROOT="$root" \
  DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$RESYNC" fakefork
rm -rf "$root"

echo "[test-resync-fork] unresolved work_dir env var is refused, never mkdir/rm -rf'd (CR)"
root=$(mktemp -d)
make_repos additive "$root"
sha=$(git -C "$root/fork" rev-parse HEAD)
make_registry "$root" "$sha"
# RESYNC_TEST_WORKROOT deliberately left UNSET: the registry's work_dir
# template is "${RESYNC_TEST_WORKROOT}", so an unresolved var collapses to ''
# via expand() -- the exact HOME-unset scenario the guard exists for.
out=$( (unset RESYNC_TEST_WORKROOT; DRIFT_REPO_ROOT="$root" \
  DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$RESYNC" fakefork) 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "unresolved work_dir is rc=2"; else fail "unresolved work_dir — expected rc=2 got $rc: $out"; fi
assert_contains "$out" "did not fully resolve" "explains the refusal"
if [ ! -e "$root/scratch" ]; then pass "no scratch dir was created for the unresolved work_dir"; else fail "a scratch dir was created despite the unresolved work_dir"; fi
rm -rf "$root"

echo "[test-resync-fork] pin_template not found in pin_file -> rc=4"
root=$(mktemp -d)
make_repos additive "$root"
sha=$(git -C "$root/fork" rev-parse HEAD)
make_registry "$root" "$sha" "1.0.0" "missing"
out=$(run_resync "$root" fakefork 2>&1)
rc=$?
if [ "$rc" -eq 4 ]; then pass "missing pin literal is rc=4"; else fail "missing pin literal — expected rc=4 got $rc: $out"; fi
rm -rf "$root"

echo "[test-resync-fork] pin_template matches twice -> rc=4"
root=$(mktemp -d)
make_repos additive "$root"
sha=$(git -C "$root/fork" rev-parse HEAD)
make_registry "$root" "$sha" "1.0.0" "double"
out=$(run_resync "$root" fakefork 2>&1)
rc=$?
if [ "$rc" -eq 4 ]; then pass "ambiguous pin literal is rc=4"; else fail "ambiguous pin literal — expected rc=4 got $rc: $out"; fi
assert_contains "$out" "occurs 2 time(s)" "reports the match count"
rm -rf "$root"

echo "[test-resync-fork] already on target -> rc=1"
root=$(mktemp -d)
make_repos none "$root"
sha=$(git -C "$root/fork" rev-parse HEAD)
make_registry "$root" "$sha"
out=$(run_resync "$root" fakefork 2>&1)
rc=$?
if [ "$rc" -eq 1 ]; then pass "no upstream advance is rc=1 (nothing to do)"; else fail "already-on-target — expected rc=1 got $rc: $out"; fi
assert_contains "$out" "already on the target base" "explains why there is nothing to do"
rm -rf "$root"

echo "[test-resync-fork] clean additive rebase -> rc=0, prints the new SHA"
root=$(mktemp -d)
make_repos additive "$root"
sha=$(git -C "$root/fork" rev-parse HEAD)
make_registry "$root" "$sha"
out=$(run_resync "$root" fakefork 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then pass "clean additive rebase exits 0"; else fail "clean additive rebase — expected rc=0 got $rc: $out"; fi
assert_contains "$out" "rebase:         CLEAN onto 1.1.0" "reports a clean rebase onto the auto-picked latest tag"
assert_contains "$out" "additive:       YES" "reports the delta as additive"
assert_contains "$out" "new SHA:" "prints the new SHA line"
assert_contains "$out" "never edits" "reminds the operator the pin file is not touched"
if [ -f "$root/scripts/lib/fakefork-bin.sh" ]; then
  if grep -qF "FAKEFORK_REF:-$sha" "$root/scripts/lib/fakefork-bin.sh"; then
    pass "pin_file itself was never edited"
  else
    fail "pin_file content changed unexpectedly"
  fi
else
  fail "pin_file disappeared"
fi
# The scratch clone should exist (work_dir expansion via ${RESYNC_TEST_WORKROOT}).
if [ -d "$root/scratch/fakefork/.git" ]; then
  pass "work_dir \${VAR} expansion produced a real scratch clone"
else
  fail "expected scratch clone at $root/scratch/fakefork"
fi
rm -rf "$root"

echo "[test-resync-fork] installable fork-tag pin resolves to its commit and stays unchanged"
root=$(mktemp -d)
make_repos additive "$root"
sha=$(git -C "$root/fork" rev-parse HEAD)
tag="v1.0.0-himmel.1"
git -C "$root/fork" tag "$tag" "$sha"
make_registry "$root" "$tag" "1.0.0" "ref"
out=$(run_resync "$root" fakefork 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then pass "tag-pinned clean additive rebase exits 0"; else fail "tag-pinned rebase — expected rc=0 got rc=$rc: $out"; fi
assert_contains "$out" "pinned tag:     $tag -> $sha" "reports the immutable tag and resolved commit"
assert_contains "$out" "cut and push a NEW immutable fork tag" "tag pin guidance requires a new installable tag, never a bare SHA"
if grep -qF "\"ref\":\"$tag\"" "$root/marketplace/.claude-plugin/marketplace.json"; then
  pass "marketplace tag pin itself was never edited"
else
  fail "marketplace tag pin changed unexpectedly"
fi
rm -rf "$root"

echo "[test-resync-fork] --target overrides the auto-picked latest tag"
root=$(mktemp -d)
make_repos additive "$root"
sha=$(git -C "$root/fork" rev-parse HEAD)
make_registry "$root" "$sha"
out=$(run_resync "$root" fakefork --target 1.0.0 2>&1)
rc=$?
if [ "$rc" -eq 1 ]; then pass "--target pinned to the current base is rc=1"; else fail "--target 1.0.0 — expected rc=1 got $rc: $out"; fi
rm -rf "$root"

echo "[test-resync-fork] --target OLDER than synced_base is refused, never rebased backwards (CR)"
root=$(mktemp -d)
make_repos additive "$root"
sha=$(git -C "$root/fork" rev-parse HEAD)
# synced_base=1.1.0 (the newer tag the "additive" fixture also creates);
# --target 1.0.0 asks to resync onto an OLDER upstream tag than that.
make_registry "$root" "$sha" "1.1.0"
out=$(run_resync "$root" fakefork --target 1.0.0 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "--target older than synced_base is rc=2"; else fail "--target 1.0.0 (older than synced_base 1.1.0) — expected rc=2 got $rc: $out"; fi
assert_contains "$out" "refusing to resync" "explains the refusal"
assert_contains "$out" "BACKWARDS" "names it as a backwards resync"
if ! git -C "$root/scratch/fakefork" rev-parse --verify resync-tmp >/dev/null 2>&1; then
  pass "no resync-tmp branch was created for the refused downgrade"
else
  fail "a resync-tmp branch was created despite the refused downgrade"
fi
rm -rf "$root"

echo "[test-resync-fork] fork commit MODIFIES an upstream file -> non-additive (rc=4)"
root=$(mktemp -d)
make_repos modify "$root"
sha=$(git -C "$root/fork" rev-parse HEAD)
make_registry "$root" "$sha"
out=$(run_resync "$root" fakefork 2>&1)
rc=$?
if [ "$rc" -eq 4 ]; then pass "modifying an upstream file is rc=4"; else fail "modify case — expected rc=4 got $rc: $out"; fi
assert_contains "$out" "additive:       NO" "reports the delta as non-additive"
assert_contains "$out" "README.md" "names the modified upstream file"
assert_contains "$out" "rebase:         CLEAN" "the rebase itself still applies cleanly (upstream never touched README.md)"
rm -rf "$root"

echo "[test-resync-fork] genuine rebase conflict -> rc=4, names the conflicting path"
root=$(mktemp -d)
make_repos conflict "$root"
sha=$(git -C "$root/fork" rev-parse HEAD)
make_registry "$root" "$sha"
out=$(run_resync "$root" fakefork 2>&1)
rc=$?
if [ "$rc" -eq 4 ]; then pass "genuine conflict is rc=4"; else fail "conflict case — expected rc=4 got $rc: $out"; fi
assert_contains "$out" "CONFLICTED" "reports the rebase as conflicted"
assert_contains "$out" "NEWFILE.md" "names the conflicting path"
rm -rf "$root"

echo "[test-resync-fork] --dry-run writes nothing and pushes nothing"
root=$(mktemp -d)
make_repos additive "$root"
sha=$(git -C "$root/fork" rev-parse HEAD)
make_registry "$root" "$sha"
out=$(run_resync "$root" fakefork --dry-run --push 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then pass "dry-run + push on a clean case still reports rc=0 (audit rc, not push rc)"; else fail "dry-run+push — expected rc=0 got $rc: $out"; fi
assert_contains "$out" "DRY resync-fork" "prints a DRY-prefixed line for the skipped push"
if git -C "$root/fork" show-ref --verify --quiet refs/heads/himmel-resync/fakefork; then
  fail "--dry-run pushed a branch to fork_repo anyway"
else
  pass "--dry-run left fork_repo with no himmel-resync branch"
fi
rm -rf "$root"

echo "[test-resync-fork] --push refused when the rebase conflicted"
root=$(mktemp -d)
make_repos conflict "$root"
sha=$(git -C "$root/fork" rev-parse HEAD)
make_registry "$root" "$sha"
out=$(run_resync "$root" fakefork --push 2>&1)
rc=$?
if [ "$rc" -eq 4 ]; then pass "--push on a conflicted result stays rc=4"; else fail "expected rc=4 got $rc: $out"; fi
assert_contains "$out" "refused" "explicitly refuses the push"
if git -C "$root/fork" show-ref --verify --quiet refs/heads/himmel-resync/fakefork; then
  fail "a conflicted rebase was pushed to fork_repo anyway"
else
  pass "conflicted rebase left fork_repo with no himmel-resync branch"
fi
rm -rf "$root"

echo "[test-resync-fork] --push actually pushes on a clean additive result"
root=$(mktemp -d)
make_repos additive "$root"
sha=$(git -C "$root/fork" rev-parse HEAD)
make_registry "$root" "$sha"
out=$(run_resync "$root" fakefork --push 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then pass "--push on a clean additive result stays rc=0"; else fail "expected rc=0 got $rc: $out"; fi
new_sha=$(git -C "$root/fork" rev-parse refs/heads/himmel-resync/fakefork 2>/dev/null || true)
if [ -n "$new_sha" ]; then
  pass "--push landed refs/heads/himmel-resync/fakefork on fork_repo ($new_sha)"
else
  fail "--push did not create refs/heads/himmel-resync/fakefork on fork_repo"
fi
rm -rf "$root"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "[test-resync-fork] all checks passed"
  exit 0
fi
echo "[test-resync-fork] $fails check(s) FAILED"
exit 1
