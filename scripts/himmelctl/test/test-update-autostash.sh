#!/usr/bin/env bash
# test-update-autostash.sh — HIMMEL_UPDATE_AUTOSTASH opt-in for himmel-update.sh
# (HIMMEL-1197).
#
# himmel-update.sh resolves its own repo root via BASH_SOURCE/.. and cd's there,
# so we test it by COPYING it (+ the libs it sources) into throwaway mock clones
# and either running it as a subprocess (T1/T1b, the top-level dirty pre-check)
# or sourcing it via the HIMMEL_UPDATE_LIB=1 seam and calling update_pull
# directly (T2/T3, the autostash pull mechanics) — the same two patterns
# scripts/test-himmel-update.sh already uses. Hermetic: local bare upstreams
# only, no network.
#
# Covers:
#   T1  default (env unset) + dirty tree → refuses (exit 1) before the chain.
#   T1b HIMMEL_UPDATE_AUTOSTASH=1 + dirty tree → takes the autostash fall-through
#       (advisory printed, no refusal).
#   T2  autostash, non-conflicting upstream → pull succeeds, local diff restored.
#   T3  autostash, conflicting upstream → reports failed, stash + conflict
#       markers preserved (guards the verified git quirk: --autostash returns 0
#       on a reapply conflict).
#
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/himmel-update.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found" >&2
    exit 1
fi
SRC_SCRIPTS="$(dirname "$SCRIPT")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
assert_pass() { pass=$((pass + 1)); echo "  PASS: $1"; }
assert_fail() { fail=$((fail + 1)); echo "  FAIL: $1"; }
assert_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if printf '%s' "$actual" | grep -q "$pattern"; then assert_pass "$desc"
    else assert_fail "$desc — expected '$pattern', got: $actual"; fi
}
assert_not_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if printf '%s' "$actual" | grep -q "$pattern"; then
        assert_fail "$desc — did NOT expect '$pattern', got: $actual"
    else assert_pass "$desc"; fi
}
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then assert_pass "$desc"
    else assert_fail "$desc — expected '$expected', got '$actual'"; fi
}

_counter=0

# build_scenario <upstream_file> [<dirty_file> <dirty_content>]
# Bare upstream + clone one commit behind (upstream modifies <upstream_file>).
# The clone tracks two files (f.txt, other.txt) and, if <dirty_file> is given,
# its working tree is left with an uncommitted change to it. Drops the script
# under test + its sourced libs into the clone so BASH_SOURCE/.. == clone root.
# Sets CLONE.
build_scenario() {
    local up_file="$1" dirty_file="${2:-}" dirty_content="${3:-}"
    _counter=$((_counter + 1))
    local base="$TMP/s${_counter}"
    local bare="$base/upstream.git" clone="$base/checkout" work="$base/work"
    mkdir -p "$bare" "$clone"
    git init --bare --quiet -b main "$bare"

    # -c core.autocrlf=false at checkout time: a global autocrlf=true would smudge
    # files to CRLF on clone, and a per-repo config set afterward comes too late —
    # git would then see every tracked file as CRLF-vs-LF "modified" and a
    # `commit -am` would spuriously re-commit them, producing bogus autostash
    # conflicts. Pin it at init/clone so the mocks are line-ending-neutral.
    git -c core.autocrlf=false init --quiet -b main "$clone"
    git -C "$clone" config user.email t@t.t
    git -C "$clone" config user.name T
    git -C "$clone" config core.autocrlf false
    git -C "$clone" remote add origin "$bare"
    printf 'f-init\n'     > "$clone/f.txt"
    printf 'other-init\n' > "$clone/other.txt"
    git -C "$clone" add f.txt other.txt
    git -C "$clone" commit --quiet -m init
    git -C "$clone" push --quiet -u origin main 2>/dev/null

    # Upstream advances by one commit touching <up_file>.
    git -c core.autocrlf=false clone --quiet "$bare" "$work" 2>/dev/null
    git -C "$work" config user.email t@t.t
    git -C "$work" config user.name T
    git -C "$work" config core.autocrlf false
    printf 'UPSTREAM-CHANGE\n' > "$work/$up_file"
    git -C "$work" commit --quiet -am "upstream touches $up_file"
    git -C "$work" push --quiet origin main 2>/dev/null
    git -C "$clone" fetch --quiet 2>/dev/null

    if [ -n "$dirty_file" ]; then
        printf '%s\n' "$dirty_content" > "$clone/$dirty_file"
    fi

    # Script + its sourced libs, so the copy resolves the clone as ROOT.
    mkdir -p "$clone/scripts/guardrails" "$clone/scripts/lib" \
             "$clone/scripts/himmelctl/test"
    cp "$SCRIPT" "$clone/scripts/himmel-update.sh"
    cp "$SRC_SCRIPTS/guardrails/lib.sh"          "$clone/scripts/guardrails/lib.sh"
    cp "$SRC_SCRIPTS/lib/cadence-format.sh"      "$clone/scripts/lib/cadence-format.sh"
    cp "$SRC_SCRIPTS/lib/resolve-hermes-py.sh"   "$clone/scripts/lib/resolve-hermes-py.sh"
    CLONE="$clone"
}

# Source the (copied) script as a lib and run update_pull in the clone; echo a
# machine-parseable result line. Mirrors scripts/test-himmel-update.sh's
# run_update_codex isolation.
run_update_pull() {   # <clone> ; caller sets HIMMEL_UPDATE_AUTOSTASH in env
    local clone="$1"
    (
        cd "$clone"
        # shellcheck disable=SC1091
        HIMMEL_UPDATE_LIB=1 . "$clone/scripts/himmel-update.sh"
        set +e   # update_pull may return 1; capture it instead of aborting
        update_pull >/dev/null 2>&1
        local rc=$?
        # STATUS_pull is a global set by the sourced himmel-update.sh (update_pull
        # assigns it); shellcheck can't see across the source boundary.
        # shellcheck disable=SC2154
        printf 'rc=%s status=%s unmerged=%s stashes=%s\n' \
            "$rc" "$STATUS_pull" \
            "$(git ls-files --unmerged | awk '{print $4}' | sort -u | wc -l | tr -d ' ')" \
            "$(git stash list | wc -l | tr -d ' ')"
    )
}

# ─── T1: default (env unset) + dirty → refuses ───────────────────────────────
echo "T1: dirty tree, env unset → refuses to pull"
build_scenario f.txt other.txt other-local
rc=0
out=$(cd "$CLONE" && bash "$CLONE/scripts/himmel-update.sh" 2>&1) || rc=$?
assert_eq "T1: exit 1" "1" "$rc"
assert_contains "T1: refusal message" "refusing to pull into a dirty tree" "$out"
assert_contains "T1: env-var hint" "HIMMEL_UPDATE_AUTOSTASH=1" "$out"

# ─── T1b: opt-in + dirty → autostash fall-through (advisory, no refusal) ──────
echo "T1b: dirty tree, HIMMEL_UPDATE_AUTOSTASH=1 → autostash advisory, no refusal"
build_scenario f.txt other.txt other-local
out=$(cd "$CLONE" && HIMMEL_UPDATE_AUTOSTASH=1 HIMMEL_UPDATE_CLAUDE_BIN=/nonexistent \
        bash "$CLONE/scripts/himmel-update.sh" 2>&1) || true
assert_contains "T1b: autostash advisory printed" "autostashing local changes" "$out"
assert_not_contains "T1b: no refusal" "refusing to pull into a dirty tree" "$out"

# ─── T2: autostash, non-conflicting upstream → success + diff restored ───────
echo "T2: autostash, upstream touches f.txt while local dirties other.txt → success"
build_scenario f.txt other.txt other-local
res=$(HIMMEL_UPDATE_AUTOSTASH=1 run_update_pull "$CLONE")
echo "    $res"
assert_contains "T2: rc 0"            "rc=0"          "$res"
assert_contains "T2: status updated"  "status=updated" "$res"
assert_contains "T2: no unmerged"     "unmerged=0"    "$res"
assert_eq "T2: local change restored" "other-local" "$(cat "$CLONE/other.txt")"
assert_eq "T2: HEAD advanced to upstream" \
    "$(git -C "$CLONE" rev-parse origin/main)" "$(git -C "$CLONE" rev-parse HEAD)"

# ─── T3: autostash, conflicting upstream → failed + stash/markers preserved ──
echo "T3: autostash, upstream + local both touch f.txt → reports failed, stash kept"
build_scenario f.txt f.txt f-local
res=$(HIMMEL_UPDATE_AUTOSTASH=1 run_update_pull "$CLONE")
echo "    $res"
assert_contains "T3: rc non-zero (1)" "rc=1"          "$res"
assert_contains "T3: status failed"   "status=failed" "$res"
assert_contains "T3: unmerged present" "unmerged=1"   "$res"
assert_contains "T3: stash preserved" "stashes=1"     "$res"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
