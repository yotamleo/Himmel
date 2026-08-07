#!/usr/bin/env bash
# Hermetic coverage for clean-garden full accounting (HIMMEL-1410): every kept
# worktree gets a what+why row, squash-merged tips are compared to the recorded
# PR head, and remote-only branches are classified from one cached PR listing.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN_GARDEN="$SCRIPT_DIR/clean-garden.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2317,SC2329  # invoked indirectly by the EXIT trap
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/himmel-clean-accounting.XXXXXX")
TMP_ROOT_UNIX="$TMP_ROOT"
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi
REPO="$TMP_ROOT/repo"
git init -q --initial-branch=main "$REPO" 2>/dev/null || {
    git init -q "$REPO"
    git -C "$REPO" symbolic-ref HEAD refs/heads/main || true
}
git -C "$REPO" config user.email t@test.com
git -C "$REPO" config user.name t
printf 'base\n' > "$REPO/README"
git -C "$REPO" add README
git -C "$REPO" commit -q -m "base"
git -C "$REPO" branch -m main 2>/dev/null || true
git -C "$REPO" remote add origin https://github.com/owner/repo.git
git -C "$REPO" remote add puborigin https://github.com/public/repo.git
MAIN_SHA=$(git -C "$REPO" rev-parse main)
git -C "$REPO" update-ref refs/remotes/origin/main "$MAIN_SHA"
git -C "$REPO" update-ref refs/remotes/puborigin/main "$MAIN_SHA"

mk_wt_commit() {
    local name="$1" branch="$2" wt
    wt="$TMP_ROOT/$name"
    git -C "$REPO" worktree add -q "$wt" -b "$branch" >/dev/null 2>&1
    printf '%s\n' "$branch" > "$wt/${name}.txt"
    git -C "$wt" add "${name}.txt"
    git -C "$wt" commit -q -m "$branch"
    printf '%s\n' "$wt"
}

WT_OPEN=$(mk_wt_commit wt-open feat/open)
OPEN_SHA=$(git -C "$WT_OPEN" rev-parse HEAD)
WT_MERGED=$(mk_wt_commit wt-merged feat/merged-clean)
MERGED_SHA=$(git -C "$WT_MERGED" rev-parse HEAD)
WT_POST=$(mk_wt_commit wt-post feat/post-merge)
POST_MERGED_SHA=$(git -C "$WT_POST" rev-parse HEAD)
printf 'after merge\n' >> "$WT_POST/wt-post.txt"
git -C "$WT_POST" commit -q -am "post merge work"
WT_PARKED=$(mk_wt_commit wt-parked feat/parked)
PARKED_SHA=$(git -C "$WT_PARKED" rev-parse HEAD)
printf 'untracked work\n' > "$WT_PARKED/notes.txt"
mk_wt_commit wt-none feat/no-pr >/dev/null
WT_DETACHED="$TMP_ROOT/wt-detached"
git -C "$REPO" worktree add -q --detach "$WT_DETACHED" main >/dev/null 2>&1
printf 'detached work\n' > "$WT_DETACHED/detached.txt"
git -C "$WT_DETACHED" add detached.txt
git -C "$WT_DETACHED" commit -q -m "detached work"
DETACHED_SHA=$(git -C "$WT_DETACHED" rev-parse HEAD)

# Remote-only tips. commit-tree avoids creating local branches/worktrees for
# these fixtures while still producing real commits for merge-base checks.
TREE=$(git -C "$REPO" rev-parse "main^{tree}")
REMOTE_MERGED=$(printf 'remote merged\n' | git -C "$REPO" commit-tree "$TREE" -p "$MAIN_SHA")
REMOTE_OLD=$(printf 'remote old\n' | git -C "$REPO" commit-tree "$TREE" -p "$MAIN_SHA")
REMOTE_NEW=$(printf 'remote new\n' | git -C "$REPO" commit-tree "$TREE" -p "$REMOTE_OLD")
REMOTE_CLOSED=$(printf 'remote closed\n' | git -C "$REPO" commit-tree "$TREE" -p "$MAIN_SHA")
REMOTE_NONE=$(printf 'remote none\n' | git -C "$REPO" commit-tree "$TREE" -p "$MAIN_SHA")
REMOTE_OPEN=$(printf 'remote open\n' | git -C "$REPO" commit-tree "$TREE" -p "$MAIN_SHA")
REMOTE_PUBLIC=$(printf 'remote public\n' | git -C "$REPO" commit-tree "$TREE" -p "$MAIN_SHA")
git -C "$REPO" update-ref refs/remotes/origin/chore/merged-clean "$REMOTE_MERGED"
git -C "$REPO" update-ref refs/remotes/origin/chore/post-merge "$REMOTE_NEW"
git -C "$REPO" update-ref refs/remotes/origin/chore/closed "$REMOTE_CLOSED"
git -C "$REPO" update-ref refs/remotes/origin/chore/no-pr "$REMOTE_NONE"
git -C "$REPO" update-ref refs/remotes/origin/chore/open "$REMOTE_OPEN"
git -C "$REPO" update-ref refs/remotes/puborigin/chore/public-no-pr "$REMOTE_PUBLIC"

GH_ROWS_ORIGIN="$TMP_ROOT_UNIX/origin.tsv"
GH_ROWS_PUBLIC="$TMP_ROOT_UNIX/public.tsv"
GH_CALLS="$TMP_ROOT_UNIX/gh-calls"
{
    printf 'owner/repo\tfeat/open\topen\t%s\n' "$OPEN_SHA"
    printf 'owner/repo\tfeat/merged-clean\tmerged\t%s\n' "$MERGED_SHA"
    printf 'owner/repo\tfeat/post-merge\tmerged\t%s\n' "$POST_MERGED_SHA"
    printf 'owner/repo\tfeat/parked\tmerged\t%s\n' "$PARKED_SHA"
    printf 'owner/repo\tchore/merged-clean\tmerged\t%s\n' "$REMOTE_MERGED"
    printf 'owner/repo\tchore/post-merge\tmerged\t%s\n' "$REMOTE_OLD"
    printf 'owner/repo\tchore/closed\tclosed\t%s\n' "$REMOTE_CLOSED"
    printf 'owner/repo\tchore/open\topen\t%s\n' "$REMOTE_OPEN"
} > "$GH_ROWS_ORIGIN"
: > "$GH_ROWS_PUBLIC"
: > "$GH_CALLS"

STUB_DIR="$TMP_ROOT_UNIX/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
if echo "$args" | grep -q "auth status"; then exit 0; fi
if echo "$args" | grep -q "repo view"; then echo "owner/repo"; exit 0; fi
if echo "$args" | grep -q "api --paginate repos/owner/repo/pulls"; then
    printf 'origin\n' >> "$GH_CALLS"
    cat "$GH_ROWS_ORIGIN"
    exit 0
fi
if echo "$args" | grep -q "api --paginate repos/public/repo/pulls"; then
    printf 'puborigin\n' >> "$GH_CALLS"
    cat "$GH_ROWS_PUBLIC"
    exit 0
fi
if echo "$args" | grep -q -- "--state open"; then exit 0; fi
exit 0
STUB
chmod +x "$STUB_DIR/gh"

run_clean() {
    (
        # Subshell-local PATH is the POINT: the gh stub must be visible to this
        # one invocation and to nothing else in the suite. The pre-commit lint
        # runs at INFO, where SC2030/SC2031 flag exactly this deliberate idiom.
        # shellcheck disable=SC2030,SC2031
        export PATH="${STUB_DIR}:${PATH}"
        export GH_ROWS_ORIGIN GH_ROWS_PUBLIC GH_CALLS
        cd "$REPO" || exit 1
        bash "$CLEAN_GARDEN" --prune-only "$@" 2>&1
    )
}

assert_line() {
    local name="$1" output="$2" first="$3" second="${4:-}"
    if printf '%s\n' "$output" | grep -F "$first" | grep -Fq "$second"; then
        pass "$name"
    else
        fail "$name" "$output"
    fi
}

echo "RUN A: origin accounting"
out=$(run_clean)

if [ ! -d "$WT_MERGED" ]; then
    pass "exact merged PR head is pruned"
else
    fail "exact merged PR head was kept" "$out"
fi
if [ -d "$WT_POST" ]; then
    pass "post-merge branch tip is kept"
else
    fail "post-merge branch tip was wrongly pruned" "$out"
fi

assert_line "open worktree is ACTIVE" "$out" "branch=feat/open pr=open" "verdict=ACTIVE"
assert_line "post-merge worktree is UNKNOWN" "$out" "branch=feat/post-merge pr=merged" "verdict=UNKNOWN"
assert_line "post-merge why names tip mismatch" "$out" "branch=feat/post-merge" "why=branch tip differs from merged PR head"
assert_line "dirty merged worktree is PARKED-WIP" "$out" "branch=feat/parked pr=merged" "untracked=1"
assert_line "dirty merged worktree verdict" "$out" "branch=feat/parked pr=merged" "verdict=PARKED-WIP"
assert_line "no-PR worktree is explicit UNKNOWN" "$out" "branch=feat/no-pr pr=none" "verdict=UNKNOWN"
assert_line "detached worktree is accounted" "$out" "branch=(detached:${DETACHED_SHA:0:12})" "verdict=UNKNOWN"

keep_count=$(printf '%s\n' "$out" | grep -c '^KEEP clean-garden:')
if [ "$keep_count" -eq 6 ]; then
    pass "every one of 6 kept worktrees has one accounting row"
else
    fail "expected 6 kept-worktree rows, got $keep_count" "$out"
fi

assert_line "remote merged head is MERGED-CLEAN" "$out" "remote=origin branch=chore/merged-clean" "category=MERGED-CLEAN"
assert_line "remote post-merge tip is TIP-DIFFERS" "$out" "remote=origin branch=chore/post-merge" "category=TIP-DIFFERS"
assert_line "remote closed PR is CLOSED-UNMERGED" "$out" "remote=origin branch=chore/closed" "category=CLOSED-UNMERGED"
assert_line "remote branch without PR is NO-PR" "$out" "remote=origin branch=chore/no-pr" "category=NO-PR"
if grepq "$out" -F "remote=origin branch=chore/open"; then
    fail "open-PR remote branch should not be an orphan row" "$out"
else
    pass "open-PR remote branch is excluded from orphan rows"
fi
assert_line "loud summary counts risk classes" "$out" "ALERT clean-garden: attention required" "TIP-DIFFERS, 1 NO-PR"

origin_calls=$(grep -c '^origin$' "$GH_CALLS")
if [ "$origin_calls" -eq 1 ]; then
    pass "origin PRs fetched once for the whole run"
else
    fail "expected one origin PR API call, got $origin_calls" "$out"
fi
if grepq "$out" -F "remote=puborigin"; then
    fail "puborigin was reported without the opt-in flag" "$out"
else
    pass "puborigin is disabled by default"
fi

echo "RUN B: puborigin opt-in"
pub_out=$(run_clean --include-puborigin)
assert_line "puborigin opt-in reports remote orphan" "$pub_out" "remote=puborigin branch=chore/public-no-pr" "category=NO-PR"
pub_calls=$(grep -c '^puborigin$' "$GH_CALLS")
if [ "$pub_calls" -eq 1 ]; then
    pass "puborigin PRs fetched once when requested"
else
    fail "expected one puborigin PR API call, got $pub_calls" "$pub_out"
fi

# --- HIMMEL-1596 checkpoint reap (F1/F2) --------------------------------------
# prune_checkpoint_refs reads %(committerdate:unix), so a checkpoint's age is
# its COMMIT date; stamp that via env on commit-tree (no host clock-warping).
# days_old>0 = past (stale under a small TTL), 0 = now (fresh).
mk_checkpoint() {
    local slug="$1" days_old="$2" tree ts oid
    ts=$(( $(date +%s) - days_old * 86400 ))
    tree=$(git -C "$REPO" rev-parse "main^{tree}")
    oid=$(GIT_COMMITTER_DATE="@$ts" GIT_AUTHOR_DATE="@$ts" \
          git -C "$REPO" commit-tree "$tree" -m "ckpt $slug")
    git -C "$REPO" update-ref "refs/checkpoints/$slug" "$oid"
    printf '%s' "$oid"
}
clear_checkpoints() {
    git -C "$REPO" for-each-ref --format='%(refname)' refs/checkpoints/ 2>/dev/null \
        | while IFS= read -r r; do [ -n "$r" ] && git -C "$REPO" update-ref -d "$r" 2>/dev/null; done
}
ckpt_exists() { git -C "$REPO" rev-parse --quiet --verify "$1" >/dev/null 2>&1; }
# ckpt_exists returns only an exit code (no stdout), so $(ckpt_exists ...) would
# always be empty — this echoes a status word for diagnostics.
ckpt_status() { ckpt_exists "$1" && printf kept || printf gone; }

# Run clean-garden --prune-only with a given CHECKPOINT_TTL_DAYS (empty arg =
# unset → the script's 14 default). Captures combined output + exit code, with
# the same gh-stub PATH the accounting runs above use.
run_clean_ttl() {
    local ttl="$1"
    (
        # Subshell-local PATH is the POINT: the gh stub must be visible to this
        # one invocation and to nothing else in the suite. The pre-commit lint
        # runs at INFO, where SC2030/SC2031 flag exactly this deliberate idiom.
        # shellcheck disable=SC2030,SC2031
        export PATH="${STUB_DIR}:${PATH}"
        export GH_ROWS_ORIGIN GH_ROWS_PUBLIC GH_CALLS
        if [ -n "$ttl" ]; then export CHECKPOINT_TTL_DAYS="$ttl"; else unset CHECKPOINT_TTL_DAYS; fi
        cd "$REPO" || exit 1
        bash "$CLEAN_GARDEN" --prune-only 2>&1
    )
}

echo "RUN C: HIMMEL-1596 checkpoint TTL validation (F1)"

# Leading-zero 08: all digits, so the fix ACCEPTS it (via 10#) as decimal 8 — no
# warn, no error. Under TTL=8 a 3-day-old ref is kept and a 30-day-old ref is
# reaped. Unfixed, `$(( 08 * 86400 ))` is an invalid octal: clean-garden prints
# "value too great for base" and the reap silently no-ops (the error does not
# propagate out of the function under this shell's `set -e`), so NOTHING is
# reaped and the 30d ref wrongly survives.
clear_checkpoints
mk_checkpoint ttl-octal-keep 3 >/dev/null      # <8d  -> kept under TTL=8
mk_checkpoint ttl-octal-reap 30 >/dev/null     # >8d  -> reaped under TTL=8
out=$(run_clean_ttl 08); rc=$?
if [ "$rc" -eq 0 ] && ckpt_exists refs/checkpoints/ttl-octal-keep \
   && ! ckpt_exists refs/checkpoints/ttl-octal-reap \
   && ! grepq "$out" -F "value too great for base"; then
    pass "F1: leading-zero TTL 08 normalizes to decimal 8 (3d kept, 30d reaped, no octal error)"
else
    fail "F1 octal TTL: rc=$rc keep=$(ckpt_status refs/checkpoints/ttl-octal-keep) reap=$(ckpt_status refs/checkpoints/ttl-octal-reap)" "$out"
fi

# Negative TTL: the fix rejects it (warn + 14 default) so a FRESH ref survives.
# Unfixed, the cutoff swings to a FUTURE time and EVERY checkpoint — including a
# fresh one — reads as stale and is deleted (data loss on a typo).
clear_checkpoints
mk_checkpoint ttl-neg 0 >/dev/null
out=$(run_clean_ttl -5); rc=$?
if [ "$rc" -eq 0 ] && ckpt_exists refs/checkpoints/ttl-neg; then
    pass "F1: negative TTL rejected — fresh ref survives"
else
    fail "F1 negative TTL: rc=$rc kept=$(ckpt_status refs/checkpoints/ttl-neg)" "$out"
fi
if grepq "$out" -F 'CHECKPOINT_TTL_DAYS'; then
    pass "F1: negative TTL warns on stderr and falls back"
else
    fail "F1: expected a CHECKPOINT_TTL_DAYS warning on stderr" "$out"
fi

# Non-numeric: the fix rejects it (warn + 14). Unfixed, bash treats the bare
# word as an unset variable (0), collapsing the cutoff to ~now and reaping a
# 3-day-old ref.
clear_checkpoints
mk_checkpoint ttl-abc 3 >/dev/null
out=$(run_clean_ttl abc); rc=$?
if [ "$rc" -eq 0 ] && ckpt_exists refs/checkpoints/ttl-abc; then
    pass "F1: non-numeric TTL rejected — 3d ref survives"
else
    fail "F1 non-numeric TTL: rc=$rc kept=$(ckpt_status refs/checkpoints/ttl-abc)" "$out"
fi

# Positive control (not a discriminator): the default-14 path still reaps a
# genuinely-stale ref and keeps a fresh one — i.e. the validation did not break
# the happy path, and the F2 oid-threaded delete still fires on a matching ref.
clear_checkpoints
mk_checkpoint ttl-stale 30 >/dev/null
mk_checkpoint ttl-fresh 0 >/dev/null
out=$(run_clean_ttl ""); rc=$?
if [ "$rc" -eq 0 ] && ! ckpt_exists refs/checkpoints/ttl-stale && ckpt_exists refs/checkpoints/ttl-fresh; then
    pass "F1 positive control: default TTL reaps 30d ref, keeps fresh ref"
else
    fail "F1 positive control: rc=$rc stale=$(ckpt_status refs/checkpoints/ttl-stale) fresh=$(ckpt_status refs/checkpoints/ttl-fresh)" "$out"
fi
clear_checkpoints

echo "RUN D: HIMMEL-1596 checkpoint compare-and-swap delete (F2)"

# A `git` proxy that simulates a worker REPLACING one checkpoint ref between
# clean-garden's enumerate and its delete — the live race shared-branch mode
# creates (it reuses the slug). Every other git call passes straight through to
# the real git. RACE_REAL_GIT is resolved BEFORE this wrapper shadows `git` on
# PATH, and the quoted heredoc + env mirrors the gh-stub idiom above.
RACE_REF="refs/checkpoints/race-slug"
RACE_REAL_GIT="$(command -v git)"
RACE_STUB_DIR="$TMP_ROOT_UNIX/race-bin"
mkdir -p "$RACE_STUB_DIR"
clear_checkpoints
mk_checkpoint race-slug 30 >/dev/null          # stale → eligible to reap
RACE_TREE=$(git -C "$REPO" rev-parse "main^{tree}")
RACE_FRESH_OID=$(GIT_COMMITTER_DATE="@$(date +%s)" GIT_AUTHOR_DATE="@$(date +%s)" \
                 git -C "$REPO" commit-tree "$RACE_TREE" -m "fresh worker ckpt")
cat > "$RACE_STUB_DIR/git" <<'STUB'
#!/usr/bin/env bash
# Transparent git proxy (F2 race test). Delegates every call to the real git
# verbatim, EXCEPT it intercepts clean-garden's "update-ref -d refs/checkpoints/race-slug"
# and first REPLACES that checkpoint with a fresh commit — the concurrent-replace
# the compare-and-swap delete exists to survive. Real git then honours the
# expected oid the fixed code passes (refuse -> ref survives + WARN) or, on the
# unfixed code that passes no expected value, deletes the fresh ref blindly.
case " $* " in
  *" update-ref -d refs/checkpoints/race-slug"*)
    "$RACE_REAL_GIT" -C "$RACE_WT" update-ref refs/checkpoints/race-slug "$RACE_FRESH_OID" >/dev/null 2>&1 ;;
esac
exec "$RACE_REAL_GIT" "$@"
STUB
chmod +x "$RACE_STUB_DIR/git"
RACE_WT="$REPO"
export RACE_REAL_GIT RACE_WT RACE_FRESH_OID

run_clean_race() {
    (
        # Subshell-local by design, same as run_clean above (SC2030/SC2031).
        # shellcheck disable=SC2030,SC2031
        export PATH="${RACE_STUB_DIR}:${STUB_DIR}:${PATH}"
        export GH_ROWS_ORIGIN GH_ROWS_PUBLIC GH_CALLS
        export RACE_REAL_GIT RACE_WT RACE_FRESH_OID
        cd "$REPO" || exit 1
        bash "$CLEAN_GARDEN" --prune-only 2>&1
    )
}

out=$(run_clean_race); rc=$?
# Fixed: the stale ref was replaced mid-reap; the CAS delete sees the mismatch
# and refuses, so the (now-fresh) ref SURVIVES with a WARN. Unfixed: a plain
# update-ref -d destroys the fresh ref.
if [ "$rc" -eq 0 ] && ckpt_exists "$RACE_REF"; then
    pass "F2: a ref replaced mid-reap survives (CAS refuses the moved ref)"
else
    fail "F2 CAS: rc=$rc kept=$(ckpt_status "$RACE_REF")" "$out"
fi
if grepq "$out" -F "could not delete stale checkpoint $RACE_REF"; then
    pass "F2: the moved/failed delete is WARNED"
else
    fail "F2: expected a WARN for the moved checkpoint ref" "$out"
fi
# The survivor holds the worker's FRESH commit, not the stale one we judged.
cur=$(git -C "$REPO" rev-parse "$RACE_REF" 2>/dev/null)
if [ "$cur" = "$RACE_FRESH_OID" ]; then
    pass "F2: surviving ref holds the worker's fresh commit"
else
    fail "F2: ref value not fresh (got ${cur:-<gone>})" "$out"
fi
clear_checkpoints

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
