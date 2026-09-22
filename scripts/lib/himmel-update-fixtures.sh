#!/usr/bin/env bash
# scripts/lib/himmel-update-fixtures.sh — shared mock-repo fixtures for
# scripts/test-himmel-update-check.sh (hermetic) and scripts/test-himmel-update.sh
# (the one residual non-hermetic case), split by HIMMEL-3450 so the two
# suites don't copy-paste the channel-tag fixture machinery between them.
#
# Sourced, never executed directly. The caller must already have `TMP` (its
# own scratch dir) and `SCRIPT` (path to the real himmel-update.sh under
# test) set before sourcing this file.
#
# Bash 3.2 compatible.

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

pass=0
fail=0
assert_pass() { pass=$((pass + 1)); echo "  PASS: $1"; }
assert_fail() { fail=$((fail + 1)); echo "  FAIL: $1"; }
assert_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if grepq "$actual" "$pattern"; then
        assert_pass "$desc"
    else
        assert_fail "$desc — expected pattern '$pattern', got: $actual"
    fi
}
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        assert_pass "$desc"
    else
        assert_fail "$desc — expected '$expected', got '$actual'"
    fi
}

# ─── channel-seam fixtures (HIMMEL-2705) ─────────────────────────────────────
# Same shape as make_repo_behind (each caller's own — not shared here), but
# the caller drives commits/tags itself via channel_commit/channel_tag_here —
# channel resolution is tag-based, not a fixed N-commits-behind count. Shares
# _repo_counter with any caller-local make_repo_behind so directory names
# never collide.
_repo_counter=0
make_repo_channel() {
    _repo_counter=$((_repo_counter + 1))
    local base="$TMP/chan_${_repo_counter}"
    local bare="$base/upstream.git"
    local clone="$base/checkout"
    mkdir -p "$bare" "$clone"

    git init --bare --quiet "$bare"
    git init --quiet "$clone"
    git -C "$clone" config user.email "test@test.test"
    git -C "$clone" config user.name "Test"
    git -C "$clone" remote add origin "$bare"
    printf 'init\n' > "$clone/file.txt"
    git -C "$clone" add file.txt
    git -C "$clone" commit --quiet -m "init"
    git -C "$clone" push --quiet -u origin HEAD:main 2>/dev/null

    mkdir -p "$clone/scripts/guardrails" "$clone/scripts/lib"
    cp "$SCRIPT" "$clone/scripts/himmel-update.sh"
    local src_scripts; src_scripts="$(dirname "$SCRIPT")"
    cp "$src_scripts/guardrails/lib.sh"        "$clone/scripts/guardrails/lib.sh"
    cp "$src_scripts/lib/cadence-format.sh"    "$clone/scripts/lib/cadence-format.sh"
    cp "$src_scripts/lib/resolve-hermes-py.sh" "$clone/scripts/lib/resolve-hermes-py.sh"
    cp "$src_scripts/lib/load-dotenv.sh"       "$clone/scripts/lib/load-dotenv.sh"
    # Overlaid, not committed — excluded from git status so is_dirty() (which
    # channel apply-mode's dirty-tree refusal relies on) never sees the test
    # harness's own script drop as a local edit.
    # HIMMEL-3450: run-shell-tests.sh pins init.templateDir to an empty
    # directory (scripts/lib/git-test-env.sh, perf) — under that pin this
    # box's git (2.55.0) does not create .git/info/ at all, only under an
    # unpinned/default template. mkdir -p makes the append hermetic to that
    # pin either way (verified: 8/8 bare `git init` under the pin lack
    # .git/info; solo quiet-run never applies the pin, which is why this only
    # ever showed up under run-shell-tests.sh's batch runner).
    mkdir -p "$clone/.git/info"
    printf 'scripts/\n' >> "$clone/.git/info/exclude"
    CHECKOUT_DIR="$clone"
    # HIMMEL-2705 codex-3: git init's local default branch name depends on
    # the machine's init.defaultBranch config, not a fixed literal — capture
    # the real name so callers assert against it instead of a hardcoded guess.
    # shellcheck disable=SC2034 # used by scripts/test-himmel-update-check.sh, not this file
    CHECKOUT_ORIG_BRANCH="$(git -C "$clone" symbolic-ref --short HEAD)"
}

channel_tag_here() {
    git -C "$CHECKOUT_DIR" tag "$1"
    git -C "$CHECKOUT_DIR" push --quiet origin "$1" 2>/dev/null
}

# An ANNOTATED tag (CR round 6, codex-2) — its ref points at a tag OBJECT,
# not the commit directly, which is what exposed the peeled-`^{}` gap a
# lightweight channel_tag_here() tag can never exercise.
channel_annotated_tag_here() {
    git -C "$CHECKOUT_DIR" tag -a "$1" -m "$1"
    git -C "$CHECKOUT_DIR" push --quiet origin "$1" 2>/dev/null
}

channel_commit() {
    printf '%s\n' "$1" >> "$CHECKOUT_DIR/file.txt"
    git -C "$CHECKOUT_DIR" add file.txt
    git -C "$CHECKOUT_DIR" commit --quiet -m "$1"
    git -C "$CHECKOUT_DIR" push --quiet origin HEAD:main 2>/dev/null
}

run_channel_lib() {   # eval'd bash snippet, sourced with the lib seam
    (
        set -euo pipefail
        cd "$CHECKOUT_DIR"
        # shellcheck disable=SC1090
        HIMMEL_UPDATE_LIB=1 . "$CHECKOUT_DIR/scripts/himmel-update.sh"
        eval "$1"
    )
}
