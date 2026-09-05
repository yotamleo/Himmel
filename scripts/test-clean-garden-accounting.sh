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

echo "RUN E: HIMMEL-1692 dirty merged worktree is never pruned + is checkpointed"

# --- E fixtures --------------------------------------------------------------
# RUN A..D mutate the repo (RUN A prunes wt-merged etc.) and RUN D's tail
# already calls clear_checkpoints, so this section starts from a clean
# checkpoint namespace and adds its own worktrees rather than reusing any
# from A-D.
#
# (a) feat/staged-wip: STAGED (git add, uncommitted) + UNSTAGED (tracked,
#     modified) work in a worktree whose branch tip nonetheless has a merged
#     PR — the exact 3,089-line staged-but-uncommitted loss shape HIMMEL-1692
#     documents. Only the dirty guard stands between this and deletion.
WT_STAGED=$(mk_wt_commit wt-staged feat/staged-wip)
STAGED_TIP=$(git -C "$WT_STAGED" rev-parse HEAD)
STAGED_NEW_CONTENT="staged-new-file-$$"
printf '%s\n' "$STAGED_NEW_CONTENT" > "$WT_STAGED/new-staged-file.txt"
git -C "$WT_STAGED" add new-staged-file.txt
STAGED_DIRTY_CONTENT="unstaged-dirty-mod-$$"
printf '%s\n' "$STAGED_DIRTY_CONTENT" > "$WT_STAGED/wt-staged.txt"

# (b) feat/untracked-wip: merged row, tip matches, plus one untracked
#     non-allowlisted file — the case `git stash create` alone cannot capture.
WT_UNTRACKED=$(mk_wt_commit wt-untracked feat/untracked-wip)
UNTRACKED_TIP=$(git -C "$WT_UNTRACKED" rev-parse HEAD)
UNTRACKED_CONTENT="forgotten-file-content-$$"
printf '%s\n' "$UNTRACKED_CONTENT" > "$WT_UNTRACKED/forgotten-notes.txt"

# Both branches are prune-ELIGIBLE by the merged-PR predicate (tip == recorded
# head), so ONLY the dirty guard stands between them and deletion.
{
    printf 'owner/repo\tfeat/staged-wip\tmerged\t%s\n' "$STAGED_TIP"
    printf 'owner/repo\tfeat/untracked-wip\tmerged\t%s\n' "$UNTRACKED_TIP"
} >> "$GH_ROWS_ORIGIN"

STAGED_STATUS_BEFORE=$(git -C "$WT_STAGED" status --porcelain)

e_out=$(run_clean)

if [ -d "$WT_STAGED" ]; then
    pass "E1: dirty merged worktree (staged+unstaged) survives the prune"
else
    fail "E1: wt-staged directory was deleted" "$e_out"
fi

staged_on_disk=$(cat "$WT_STAGED/new-staged-file.txt" 2>/dev/null)
if [ "$staged_on_disk" = "$STAGED_NEW_CONTENT" ]; then
    pass "E2: staged file content survives on disk, byte-exact"
else
    fail "E2: staged file content mismatch: got '$staged_on_disk'" "$e_out"
fi

if grepq "$e_out" -F "feat/staged-wip has uncommitted changes — skipped"; then
    pass "E3: dirty-guard WARN still fires for feat/staged-wip"
else
    fail "E3: expected the uncommitted-changes WARN for feat/staged-wip" "$e_out"
fi

if ckpt_exists refs/checkpoints/wt-staged-autosave; then
    pass "E4: refs/checkpoints/wt-staged-autosave now exists"
else
    fail "E4: expected refs/checkpoints/wt-staged-autosave to exist" "$e_out"
fi

ckpt_staged_new=$(git -C "$REPO" show refs/checkpoints/wt-staged-autosave:new-staged-file.txt 2>/dev/null)
if [ "$ckpt_staged_new" = "$STAGED_NEW_CONTENT" ]; then
    pass "E5: checkpoint tree captures the STAGED-but-uncommitted file"
else
    fail "E5: checkpoint tree missing/wrong staged file: got '$ckpt_staged_new'" "$e_out"
fi

ckpt_staged_mod=$(git -C "$REPO" show refs/checkpoints/wt-staged-autosave:wt-staged.txt 2>/dev/null)
if [ "$ckpt_staged_mod" = "$STAGED_DIRTY_CONTENT" ]; then
    pass "E6: checkpoint tree captures the UNSTAGED modification (not HEAD's content)"
else
    fail "E6: checkpoint tree has wrong content for wt-staged.txt: got '$ckpt_staged_mod'" "$e_out"
fi

ckpt_untracked=$(git -C "$REPO" show refs/checkpoints/wt-untracked-autosave:forgotten-notes.txt 2>/dev/null)
if [ -d "$WT_UNTRACKED" ] && [ "$ckpt_untracked" = "$UNTRACKED_CONTENT" ]; then
    pass "E7: wt-untracked survives and its checkpoint captures the untracked file (git stash create cannot do this)"
else
    fail "E7: wt-untracked survival or checkpoint content wrong: got '$ckpt_untracked'" "$e_out"
fi

STAGED_STATUS_AFTER=$(git -C "$WT_STAGED" status --porcelain)
if [ "$STAGED_STATUS_AFTER" = "$STAGED_STATUS_BEFORE" ]; then
    pass "E8: checkpointing did not mutate wt-staged (status --porcelain byte-identical)"
else
    fail "E8: worktree status changed by checkpointing (before='$STAGED_STATUS_BEFORE' after='$STAGED_STATUS_AFTER')" "$e_out"
fi

OLD_STAGED_CKPT=$(git -C "$REPO" rev-parse refs/checkpoints/wt-staged-autosave)
run_clean >/dev/null
NEW_PARENTS=$(git -C "$REPO" rev-list --parents -n 1 refs/checkpoints/wt-staged-autosave)
case " $NEW_PARENTS " in
    *" $OLD_STAGED_CKPT "*) pass "E9: re-run's checkpoint carries the previous checkpoint oid as a parent (lossless)" ;;
    *) fail "E9: previous checkpoint oid $OLD_STAGED_CKPT not among parents" "$NEW_PARENTS" ;;
esac

clear_checkpoints
dry_out=$(run_clean --dry-run)
any_ckpt=$(git -C "$REPO" for-each-ref --format='%(refname)' refs/checkpoints/ 2>/dev/null)
if [ -z "$any_ckpt" ] && grepq "$dry_out" -F "DRY clean-garden: would checkpoint"; then
    pass "E10: --dry-run prints the would-checkpoint line and writes no ref"
else
    fail "E10: dry-run left refs='$any_ckpt' or missing the DRY line" "$dry_out"
fi
clear_checkpoints

# --- E11: tool-generated churn is NOT user work -----------------------------
# The dirty guard must refuse genuine WIP without also jamming on churn that
# no human wrote. .tokensave/ is the live case on this box: a tokensave watcher
# chained off the GLOBAL git hookspath mints a SQLite DB inside a worktree
# seconds after `git worktree add`, so without the is_ignorable_stray entry
# EVERY merged worktree would classify "forgotten" and never prune again —
# a guard that refuses everything is as useless as one that refuses nothing.
# Note this fixture repo has NO .gitignore yet (RUN F writes the first one), so
# .tokensave/ here really is unignored-untracked: this exercises the allowlist
# itself, which is the adopter-checkout shape where .gitignore lacks the entry.
WT_CHURN=$(mk_wt_commit wt-churn feat/tool-churn)
CHURN_TIP=$(git -C "$WT_CHURN" rev-parse HEAD)
mkdir -p "$WT_CHURN/.tokensave"
printf 'fake-sqlite\n' > "$WT_CHURN/.tokensave/tokensave.db"
printf '{}\n'          > "$WT_CHURN/.tokensave/config.json"
printf 'owner/repo\tfeat/tool-churn\tmerged\t%s\n' "$CHURN_TIP" >> "$GH_ROWS_ORIGIN"

e11_out=$(run_clean)
if [ ! -d "$WT_CHURN" ]; then
    pass "E11: merged worktree whose only untracked content is .tokensave/ IS pruned"
else
    fail "E11: wt-churn survived — tool churn wrongly read as user work" "$e11_out"
fi
if ! ckpt_exists refs/checkpoints/wt-churn-autosave; then
    pass "E11: no autosave checkpoint minted for pure tool churn"
else
    fail "E11: unexpected refs/checkpoints/wt-churn-autosave for tool churn" "$e11_out"
fi
clear_checkpoints

# --- E12: a STAGED version superseded on disk is not lost --------------------
# `add -A` records only the WORKING-TREE content, so a file staged with one
# content and then edited again keeps just the on-disk version — the staged
# snapshot in between would vanish (codex CR round 1). One tree cannot hold
# both, so the index is captured as its own commit and hung off the checkpoint
# as an extra parent. Assert BOTH survive: the checkpoint tree carries the
# worktree version (what `git restore --source` should yield), and some parent
# carries the staged version.
WT_IDX=$(mk_wt_commit wt-idx feat/idx-split)
IDX_TIP=$(git -C "$WT_IDX" rev-parse HEAD)
IDX_STAGED="staged-version-$$"
IDX_WORKTREE="worktree-version-$$"
printf '%s\n' "$IDX_STAGED" > "$WT_IDX/wt-idx.txt"
git -C "$WT_IDX" add wt-idx.txt
printf '%s\n' "$IDX_WORKTREE" > "$WT_IDX/wt-idx.txt"
printf 'owner/repo\tfeat/idx-split\tmerged\t%s\n' "$IDX_TIP" >> "$GH_ROWS_ORIGIN"

e12_out=$(run_clean)

ckpt_idx_tree=$(git -C "$REPO" show refs/checkpoints/wt-idx-autosave:wt-idx.txt 2>/dev/null)
if [ "$ckpt_idx_tree" = "$IDX_WORKTREE" ]; then
    pass "E12: checkpoint tree carries the WORKTREE version (what restore --source yields)"
else
    fail "E12: checkpoint tree should hold the worktree version, got '$ckpt_idx_tree'" "$e12_out"
fi

idx_found=0
for _p in $(git -C "$REPO" rev-list --parents -n 1 refs/checkpoints/wt-idx-autosave 2>/dev/null | cut -d' ' -f2-); do
    if [ "$(git -C "$REPO" show "$_p:wt-idx.txt" 2>/dev/null)" = "$IDX_STAGED" ]; then
        idx_found=1
        break
    fi
done
if [ "$idx_found" -eq 1 ]; then
    pass "E12: the superseded STAGED version survives as a checkpoint parent"
else
    fail "E12: no checkpoint parent carries the staged version '$IDX_STAGED'" "$e12_out"
fi
clear_checkpoints

# --- E13: staged-only work, reverted on disk, is still checkpointed ---------
# The complementary case to E12, and the sharper one: stage X, then put the
# file back to HEAD's content on disk. `status --porcelain` still reports the
# worktree dirty (a staged modification), so the prune refuses and calls
# checkpoint_worktree — but the WORKTREE tree now collapses back to HEAD's own
# tree. A nothing-to-save early-return placed before the index capture exits 0
# there and silently discards X (codex CR round 3, Critical). The staged
# snapshot is the only work that exists, so it must become the checkpoint's own
# tree, not a parent nobody restores.
WT_SONLY=$(mk_wt_commit wt-sonly feat/staged-only)
SONLY_TIP=$(git -C "$WT_SONLY" rev-parse HEAD)
SONLY_STAGED="staged-only-version-$$"
printf '%s\n' "$SONLY_STAGED" > "$WT_SONLY/wt-sonly.txt"
git -C "$WT_SONLY" add wt-sonly.txt
# Restore HEAD's blob BYTE-EXACTLY. `$(cat file)` strips the trailing newline,
# so writing it back with printf leaves a one-byte difference — the worktree
# tree then does NOT equal head_tree and this test silently exercises E12's
# path instead of the staged-only one it exists for.
git -C "$WT_SONLY" show "HEAD:wt-sonly.txt" > "$WT_SONLY/wt-sonly.txt"
# Assert the fixture really is the staged-only shape, or this test passes for
# the wrong reason. NOTE the two diffs are different questions: plain
# `git diff` is WORKTREE-vs-INDEX (non-empty here BY DESIGN — that is the
# staged delta), so it is the wrong guard. `git diff HEAD` is WORKTREE-vs-HEAD,
# which is the invariant that makes the temporary tree collapse to head_tree.
if [ -n "$(git -C "$WT_SONLY" diff HEAD --name-only)" ]; then
    fail "E13 fixture: worktree still differs from HEAD — the staged-only case is not being exercised"
fi
if [ -z "$(git -C "$WT_SONLY" diff --cached --name-only)" ]; then
    fail "E13 fixture: nothing staged — the staged-only case is not being exercised"
fi
printf 'owner/repo\tfeat/staged-only\tmerged\t%s\n' "$SONLY_TIP" >> "$GH_ROWS_ORIGIN"

e13_out=$(run_clean)

if [ -d "$WT_SONLY" ]; then
    pass "E13: staged-only worktree survives the prune"
else
    fail "E13: wt-sonly was pruned despite a staged modification" "$e13_out"
fi
ckpt_sonly=$(git -C "$REPO" show refs/checkpoints/wt-sonly-autosave:wt-sonly.txt 2>/dev/null)
if [ "$ckpt_sonly" = "$SONLY_STAGED" ]; then
    pass "E13: the checkpoint restores TO the staged-only content (not silently dropped)"
else
    fail "E13: checkpoint should carry the staged-only content, got '$ckpt_sonly'" "$e13_out"
fi
clear_checkpoints

echo "RUN F: HIMMEL-1692 stray-husk sweep is fail-closed on unsaved work"

# --- F fixtures --------------------------------------------------------------
# The stray sweep only looks under $PRIMARY_WORKTREE/.claude/worktrees, and
# in this suite PRIMARY_WORKTREE == $REPO (git-common-dir of a non-worktree
# checkout). The real himmel repo gitignores /.claude/worktrees (see its
# .gitignore) — that matters here: a plain leftover directory placed there
# has no `.git` of its own, so `classify_worktree` resolves it by walking up
# to $REPO's OWN repo boundary; without the gitignore its junk files would
# show up as $REPO's own untracked files (verdict "forgotten", wrongly
# refused). Replicate the real gitignore so F6 exercises the actual
# production shape rather than an artifact of this fixture's repo missing it.
printf '/.claude/worktrees\n' > "$REPO/.gitignore"
git -C "$REPO" add .gitignore
git -C "$REPO" commit -q -m "gitignore worktrees (RUN F fixture)"

STRAY_HOME_F="$REPO/.claude/worktrees"
mkdir -p "$STRAY_HOME_F"

# mk_husk <name> <branch> — a HAND-BUILT worktree admin record under
# .claude/worktrees, wired up WITHOUT ever calling `git worktree add`. It
# produces the same end state the old "real worktree add, then corrupt the
# back-reference" approach did: an admin dir at $REPO/.git/worktrees/<name>/
# whose "gitdir" file (what `git worktree list` reads to report the
# worktree's path) is bogus from birth, so the husk is invisible to
# clean-garden's registered_worktree_path() lookup and reads as an
# unregistered stray — while REMAINING a fully live git worktree: `git -C
# <husk> ...` still resolves HEAD/index/status normally, because those
# commands consult the husk's OWN .git file + the admin dir's HEAD/commondir,
# never the "gitdir" back-reference. This is the shape a partially-failed
# `git worktree remove` leaves behind when the working directory survives (a
# locked file, say) but the admin record is already gone — see
# mk_broken_husk below for what happens once the ENTIRE admin dir (not just
# this one file) is gone.
#
# .tokensave note (measured, not guessed — HIMMEL-1692 RUN F post-mortem):
# this machine chains a tokensave.exe watcher off the GLOBAL git hookspath
# (core.hookspath) — post-checkout fires `tokensave.exe init &` whenever the
# old-SHA arg is all-zeros (i.e. on any real `git worktree add` or `git
# clone`), and post-commit fires `tokensave.exe sync &` on EVERY commit,
# unconditionally. A real `git worktree add` here attracted a live
# .tokensave/ (config.json + a WAL-mode SQLite db) within 1-2s, and every
# subsequent commit inside that worktree re-attracted it within 0-1s — even
# right after deleting it, and the delete could itself fail with "Device or
# resource busy" while tokensave's own process still held the db file open.
# That race made RUN F's assertions pass/fail for the WRONG reason: the
# stray-sweep's freshness gate (`find -mmin -1440`) saw the husk as
# touched-in-the-last-24h and skipped it before the HIMMEL-1692 guard this
# suite exists to test ever ran. Building the admin record BY HAND never
# fires post-checkout at all (no `git worktree add` ⇒ no "old SHA is
# all-zeros" event) — measured across a hand-built create + a real
# `git -C husk commit`, polled for 20s: .tokensave never appeared either
# time. Do not "simplify" this back to `git worktree add` + stale_husk; that
# reintroduces the race this comment documents.
mk_husk() {
    local name="$1" branch="$2" wt admin head_sha
    wt="$STRAY_HOME_F/$name"
    admin="$REPO/.git/worktrees/$name"
    head_sha=$(git -C "$REPO" rev-parse HEAD)
    mkdir -p "$wt" "$admin"
    git -C "$REPO" update-ref "refs/heads/$branch" "$head_sha"
    printf 'ref: refs/heads/%s\n' "$branch" > "$admin/HEAD"
    printf '../..\n' > "$admin/commondir"
    # bogus from birth — same end state the old corrupt-after-the-fact
    # version produced, so this is an unregistered stray immediately.
    printf 'bogus-unregistered-path-for-%s\n' "$name" > "$admin/gitdir"
    printf 'gitdir: %s\n' "$admin" > "$wt/.git"
    git -C "$wt" read-tree HEAD >/dev/null 2>&1
    git -C "$wt" checkout-index -a -f >/dev/null 2>&1
    printf '%s\n' "$branch" > "$wt/committed.txt"
    git -C "$wt" add committed.txt
    git -C "$wt" commit -q -m "$branch"
    printf '%s\n' "$wt"
}

# mk_broken_husk <name> — NOT a real worktree: a plain directory whose own
# `.git` is a FILE with a gitdir: line pointing at a path that does not
# exist — the real broken-admin-record shape (the WHOLE
# $REPO/.git/worktrees/<name> admin dir is gone, not just one file inside
# it). git cannot resolve HEAD from here at all ("fatal: not a git
# repository"), so classify_worktree reports scanfail.
mk_broken_husk() {
    local name="$1" wt
    wt="$STRAY_HOME_F/$name"
    mkdir -p "$wt"
    printf 'gitdir: %s/nonexistent-admin-dir/.git\n' "$TMP_ROOT_UNIX" > "$wt/.git"
    printf 'leftover content\n' > "$wt/somefile.txt"
    printf '%s\n' "$wt"
}

# mk_plain_leftover <name> — no `.git` anywhere: an ordinary directory that
# is simply not a worktree at all.
mk_plain_leftover() {
    local name="$1" wt
    wt="$STRAY_HOME_F/$name"
    mkdir -p "$wt"
    printf 'leftover\n' > "$wt/leftover.txt"
    printf '%s\n' "$wt"
}

# stale_husk <dir> — back-date every entry inside <dir> (including <dir>
# itself) to 3 days ago, then VERIFY the freshness gate (`find -mmin -1440`,
# which the sweep also uses) actually sees it as stale. The sweep skips
# anything with an entry touched in the last 24h, so an unverified back-date
# would make later assertions pass or fail for the wrong reason.
stale_husk() {
    local dir="$1"
    find "$dir" -exec touch -d "3 days ago" {} + 2>/dev/null
    if [ -n "$(find "$dir" -mmin -1440 -print 2>/dev/null)" ]; then
        echo "FIXTURE ERROR: $dir did not back-date to stale" >&2
        return 1
    fi
    return 0
}

# norm_path <dir> — resolve <dir> the way clean-garden.sh's OWN bash session
# will report it, not the cygpath -m form this suite built $wt from. MSYS
# normalizes cwd-relative paths under TEMP to its /tmp mount regardless of
# which path form you cd'd in with (the "MSYS mangling" trap) — so the
# stray-sweep's WARN/DRY lines echo $stray_dir in that mounted form, which
# can differ textually (though not physically) from $HUSK_*. Any assertion
# that literal-matches clean-garden's echoed text must compare against THIS
# form.
norm_path() {
    ( cd "$1" 2>/dev/null && pwd ) || printf '%s' "$1"
}

# verify_unregistered <dir> — sanity-check the mk_husk corruption actually
# worked before trusting assertions built on top of it.
verify_unregistered() {
    local wt="$1" wt_norm wt_list
    wt_norm=$(cd "$wt" 2>/dev/null && pwd || echo "$wt")
    wt_list=$(git -C "$REPO" worktree list --porcelain)
    if grepq "$wt_list" -F "worktree $wt_norm"; then
        echo "FIXTURE ERROR: $wt is still registered in git worktree list" >&2
        return 1
    fi
    return 0
}

clear_checkpoints

# --- F1/F2/F3: tracked uncommitted work survives + is checkpointed ----------
HUSK_TRACKED=$(mk_husk husk-tracked exp/husk-tracked)
printf 'MODIFIED after commit\n' > "$HUSK_TRACKED/committed.txt"
HUSK_TRACKED_CONTENT=$(cat "$HUSK_TRACKED/committed.txt")
verify_unregistered "$HUSK_TRACKED"
stale_husk "$HUSK_TRACKED" || fail "F-fixture: stale_husk failed for husk-tracked"

# --- F4: untracked non-stray file survives + is checkpointed ----------------
HUSK_UNTRACKED=$(mk_husk husk-untracked exp/husk-untracked)
HUSK_UNTRACKED_CONTENT="forgotten-husk-content-$$"
printf '%s\n' "$HUSK_UNTRACKED_CONTENT" > "$HUSK_UNTRACKED/forgotten.txt"
verify_unregistered "$HUSK_UNTRACKED"
stale_husk "$HUSK_UNTRACKED" || fail "F-fixture: stale_husk failed for husk-untracked"

# --- F5: clean worktree husk — positive control, still swept ----------------
HUSK_CLEAN=$(mk_husk husk-clean exp/husk-clean)
verify_unregistered "$HUSK_CLEAN"
stale_husk "$HUSK_CLEAN" || fail "F-fixture: stale_husk failed for husk-clean"

# --- F6: plain non-git leftover directory — still swept ---------------------
LEFTOVER_PLAIN=$(mk_plain_leftover leftover-plain)
stale_husk "$LEFTOVER_PLAIN" || fail "F-fixture: stale_husk failed for leftover-plain"

# --- F7: broken/unreadable .git — scanfail, fail-closed ---------------------
HUSK_BROKEN=$(mk_broken_husk husk-broken)
stale_husk "$HUSK_BROKEN" || fail "F-fixture: stale_husk failed for husk-broken"

f_out=$(run_clean)

if [ -d "$HUSK_TRACKED" ]; then
    pass "F1: husk with tracked uncommitted changes survives the sweep"
else
    fail "F1: husk-tracked directory was swept" "$f_out"
fi
tracked_on_disk=$(cat "$HUSK_TRACKED/committed.txt" 2>/dev/null)
if [ "$tracked_on_disk" = "$HUSK_TRACKED_CONTENT" ]; then
    pass "F1: husk-tracked content is still readable byte-exact"
else
    fail "F1: husk-tracked content mismatch: got '$tracked_on_disk'" "$f_out"
fi

if grepq "$f_out" -F "refusing to sweep $(norm_path "$HUSK_TRACKED")"; then
    pass "F2: refusal WARN names the husk-tracked path"
else
    fail "F2: expected a refusal WARN naming $HUSK_TRACKED" "$f_out"
fi

ckpt_tracked=$(git -C "$REPO" show refs/checkpoints/husk-tracked-autosave:committed.txt 2>/dev/null)
if [ "$ckpt_tracked" = "$HUSK_TRACKED_CONTENT" ]; then
    pass "F3: husk-tracked content was checkpointed"
else
    fail "F3: checkpoint missing/wrong for husk-tracked: got '$ckpt_tracked'" "$f_out"
fi

if [ -d "$HUSK_UNTRACKED" ]; then
    pass "F4: husk with untracked non-stray file survives the sweep"
else
    fail "F4: husk-untracked directory was swept" "$f_out"
fi
ckpt_untracked=$(git -C "$REPO" show refs/checkpoints/husk-untracked-autosave:forgotten.txt 2>/dev/null)
if [ "$ckpt_untracked" = "$HUSK_UNTRACKED_CONTENT" ]; then
    pass "F4: husk-untracked content was checkpointed"
else
    fail "F4: checkpoint missing/wrong for husk-untracked: got '$ckpt_untracked'" "$f_out"
fi

if [ ! -d "$HUSK_CLEAN" ]; then
    pass "F5: clean worktree husk IS still swept (positive control)"
else
    fail "F5: clean husk-clean survived — sweep wrongly disabled" "$f_out"
fi

if [ ! -d "$LEFTOVER_PLAIN" ]; then
    pass "F6: plain non-git leftover directory IS still swept"
else
    fail "F6: leftover-plain survived — sweep wrongly disabled" "$f_out"
fi

if [ -d "$HUSK_BROKEN" ]; then
    pass "F7: husk with broken/unreadable .git survives the sweep"
else
    fail "F7: husk-broken directory was swept" "$f_out"
fi
if grepq "$f_out" -F "refusing to sweep $(norm_path "$HUSK_BROKEN")" && grepq "$f_out" -F "could not inspect"; then
    pass "F7: warning says the contents could not be inspected"
else
    fail "F7: expected a 'could not inspect' WARN for $HUSK_BROKEN" "$f_out"
fi

if grepq "$f_out" -F "clean-garden: stray-sweep" && grepq "$f_out" -F "3 refused"; then
    pass "F8: stray-sweep summary line reports the refusal count"
else
    fail "F8: expected the stray-sweep summary to report '3 refused'" "$f_out"
fi

# --- F9: --dry-run neither sweeps nor refuses destructively -----------------
HUSK_DRY=$(mk_husk husk-dry exp/husk-dry)
verify_unregistered "$HUSK_DRY"
stale_husk "$HUSK_DRY" || fail "F-fixture: stale_husk failed for husk-dry"
dry_f_out=$(run_clean --dry-run)
if grepq "$dry_f_out" -F "DRY clean-garden: would sweep stray husk $(norm_path "$HUSK_DRY")"; then
    pass "F9: --dry-run reports the clean husk as would-sweep"
else
    fail "F9: expected a would-sweep DRY line for $HUSK_DRY" "$dry_f_out"
fi
if [ -d "$HUSK_DRY" ]; then
    pass "F9: --dry-run leaves the clean husk on disk"
else
    fail "F9: --dry-run deleted $HUSK_DRY" "$dry_f_out"
fi

clear_checkpoints

# --- RUN G: HIMMEL-1970 stale remote-tracking refs are not phantom orphans ---
# refs/remotes/origin/* is a local CACHE. With deleteBranchOnMerge=true (and
# merge-on-green no longer running `gh pr merge --delete-branch`, HIMMEL-1679)
# a merged branch disappears server-side without touching that cache, so the
# ref lingered and was re-reported MERGED-CLEAN forever — the "19 MERGED-CLEAN,
# 0 pruned" report that read as a broken pruner. Needs a REACHABLE origin, so
# this fixture uses a local bare repo + FORGE=github (the documented test
# override) instead of the unreachable https URL the fixture above uses.
echo "RUN G: HIMMEL-1970 stale remote-tracking refs"
G_BARE="$TMP_ROOT/g-origin.git"
git init -q --bare "$G_BARE" 2>/dev/null || git init -q --bare "$G_BARE"
G_REPO="$TMP_ROOT/g-repo"
git init -q --initial-branch=main "$G_REPO" 2>/dev/null || {
    git init -q "$G_REPO"
    git -C "$G_REPO" symbolic-ref HEAD refs/heads/main || true
}
git -C "$G_REPO" config user.email t@test.com
git -C "$G_REPO" config user.name t
printf 'g base\n' > "$G_REPO/README"
git -C "$G_REPO" add README
git -C "$G_REPO" commit -q -m "g base"
git -C "$G_REPO" branch -m main 2>/dev/null || true
git -C "$G_REPO" remote add origin "$G_BARE"
git -C "$G_REPO" push -q origin main
# A merged branch that origin STILL has — the row that must survive.
git -C "$G_REPO" checkout -q -b chore/g-live
printf 'g live\n' > "$G_REPO/live.txt"
git -C "$G_REPO" add live.txt
git -C "$G_REPO" commit -q -m "g live"
git -C "$G_REPO" push -q origin chore/g-live
G_LIVE_SHA=$(git -C "$G_REPO" rev-parse chore/g-live)
git -C "$G_REPO" checkout -q main
git -C "$G_REPO" fetch -q origin
# A merged branch origin already deleted server-side: only the stale
# remote-tracking ref remains locally (never pushed).
G_TREE=$(git -C "$G_REPO" rev-parse "main^{tree}")
G_GONE_SHA=$(printf 'g gone\n' | git -C "$G_REPO" commit-tree "$G_TREE" -p "$(git -C "$G_REPO" rev-parse main)")
git -C "$G_REPO" update-ref refs/remotes/origin/chore/g-gone "$G_GONE_SHA"
G_ROWS="$TMP_ROOT_UNIX/g-origin.tsv"
{
    printf 'owner/repo\tchore/g-live\tmerged\t%s\n' "$G_LIVE_SHA"
    printf 'owner/repo\tchore/g-gone\tmerged\t%s\n' "$G_GONE_SHA"
} > "$G_ROWS"

run_clean_g() {
    (
        # shellcheck disable=SC2031  # subshell modification intentional in this test harness
        export PATH="${STUB_DIR}:${PATH}"
        # shellcheck disable=SC2030  # subshell modification intentional in this test harness
        export GH_ROWS_ORIGIN="$G_ROWS" GH_ROWS_PUBLIC GH_CALLS
        export FORGE=github   # origin is a local path, not a github URL
        cd "$G_REPO" || exit 1
        bash "$CLEAN_GARDEN" --prune-only "$@" 2>&1
    )
}
g_ref_exists() { git -C "$G_REPO" rev-parse --quiet --verify refs/remotes/origin/chore/g-gone >/dev/null 2>&1; }

# G1 — --dry-run classifies identically but touches no ref.
g_dry=$(run_clean_g --dry-run)
if grepq "$g_dry" -F "branch=chore/g-gone"; then
    fail "G1: --dry-run still reported the stale remote-tracking ref as an orphan" "$g_dry"
else
    pass "G1: --dry-run skips a branch that is no longer on origin"
fi
if g_ref_exists; then
    pass "G1: --dry-run leaves refs/remotes/origin/chore/g-gone in place"
else
    fail "G1: --dry-run deleted a remote-tracking ref" "$g_dry"
fi

# G2 — the real run skips it AND drops the dead ref, so the count stops lying.
g_out=$(run_clean_g)
if grepq "$g_out" -F "branch=chore/g-gone"; then
    fail "G2: stale remote-tracking ref was still classified" "$g_out"
else
    pass "G2: stale remote-tracking ref is not reported as a remote orphan"
fi
if g_ref_exists; then
    fail "G2: stale refs/remotes/origin/chore/g-gone was not pruned" "$g_out"
else
    pass "G2: stale remote-tracking ref is pruned"
fi
assert_line "G2: a branch still on origin is still MERGED-CLEAN" "$g_out" \
    "remote=origin branch=chore/g-live" "category=MERGED-CLEAN"
if grepq "$g_out" -F "accounting summary" && grepq "$g_out" -F "remote branches: 1 MERGED-CLEAN"; then
    pass "G2: summary names the remote-branch population and counts only the live one"
else
    fail "G2: expected 'remote branches: 1 MERGED-CLEAN' in the accounting summary" "$g_out"
fi

# G3 — unreachable remote: fail OPEN (classify as before) and say so in the
# DEFAULT (non-verbose) output, so a stale remote-branch count is never silent.
git -C "$G_REPO" remote set-url origin "$TMP_ROOT/g-nonexistent.git"
g_off=$(run_clean_g)
if grepq "$g_off" -F "remote-tracking refresh skipped (origin unreachable)"; then
    pass "G3: unreachable remote prints the staleness notice without --verbose"
else
    fail "G3: expected an unconditional refresh-skipped notice" "$g_off"
fi
assert_line "G3: unreachable remote still classifies as before" "$g_off" \
    "remote=origin branch=chore/g-live" "category=MERGED-CLEAN"

echo "RUN H: HIMMEL-2227 in-use worktree probe before remove"
# A plain `git worktree remove` is NOT atomic on Windows (see
# scripts/lib/worktree-inuse.sh's own header for the measured repro): with a
# native process holding a directory inside the tree, git deletes the
# CONTENTS, deregisters the admin entry, and only then fails the final
# rmdir. clean-garden's prune loop now probes BEFORE the remove (gating both
# the plain and the --force/strays paths) so an in-use tree is skipped WHOLE
# instead of gutted.

h_wt_list_has() {
    local path="$1" path_pwd line wt wt_pwd
    path_pwd=$(cd "$path" 2>/dev/null && pwd) || path_pwd="$path"
    while IFS= read -r line; do
        case "$line" in
            "worktree "*)
                wt="${line#worktree }"
                wt_pwd=$(cd "$wt" 2>/dev/null && pwd) || wt_pwd="$wt"
                [ "$wt_pwd" = "$path_pwd" ] && return 0
                ;;
        esac
    done < <(git -C "$REPO" worktree list --porcelain 2>/dev/null)
    return 1
}
h_branch_gone() { ! git -C "$REPO" rev-parse --quiet --verify "refs/heads/$1" >/dev/null 2>&1; }

# H1 — NEGATIVE CONTROL, the probe must not block a legitimate prune: already
# proven by RUN A's very first assertion ("exact merged PR head is pruned",
# above) — a merged, clean, NOT-held worktree with no holder involved at all
# is pruned normally there, under this same (post-fix) clean-garden.sh.

# H2 — NEGATIVE CONTROL: a merged worktree with uncommitted (staged) work is
# still refused and left INTACT — not merely `[ -d ]` (a GUTTED tree also
# satisfies that, the exact blind spot HIMMEL-2227 closes), but with its
# .git, its `git worktree list` admin row, and its tracked file's content all
# surviving.
WT_H2=$(mk_wt_commit wt-h2-dirty feat/h2-dirty)
H2_SHA=$(git -C "$WT_H2" rev-parse HEAD)
printf 'dirty work\n' >> "$WT_H2/wt-h2-dirty.txt"
git -C "$WT_H2" add wt-h2-dirty.txt
# shellcheck disable=SC2031  # GH_ROWS_ORIGIN modified in subshell intentionally in this test harness
printf 'owner/repo\tfeat/h2-dirty\tmerged\t%s\n' "$H2_SHA" >> "$GH_ROWS_ORIGIN"
h2_out=$(run_clean)
if [ -d "$WT_H2" ] && [ -e "$WT_H2/.git" ]; then
    pass "H2: dirty merged worktree survives WHOLE (dir + .git)"
else
    fail "H2: dirty merged worktree is missing its dir or .git" "$h2_out"
fi
if h_wt_list_has "$WT_H2"; then
    pass "H2: dirty merged worktree's admin row survives"
else
    fail "H2: dirty merged worktree's admin row is gone" "$h2_out"
fi
if [ -f "$WT_H2/wt-h2-dirty.txt" ] && grep -qF "dirty work" "$WT_H2/wt-h2-dirty.txt"; then
    pass "H2: dirty merged worktree's staged content survives"
else
    fail "H2: dirty merged worktree's staged content is gone" "$h2_out"
fi
if h_branch_gone feat/h2-dirty; then
    fail "H2: branch deleted despite a dirty (kept) worktree" "$h2_out"
else
    pass "H2: branch NOT deleted for the kept dirty worktree"
fi
clear_checkpoints

# H3 — POSITIVE CONTROL (fails before this change / passes after): a merged,
# CLEAN worktree held open by a real native pwsh process is SKIPPED and
# survives WHOLE. Windows-gated: a native process holding a directory is the
# only thing MEASURED to block the rename probe (worktree-inuse.sh's own
# repro table) — an MSYS bash holder does not — so this case is not
# constructible on other platforms.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        PWSH=$(command -v pwsh || command -v powershell || true)
        if [ -z "$PWSH" ]; then
            echo "  SKIP: H3 — no pwsh/powershell on PATH — HIMMEL-2227 in-use-worktree case needs a native Windows holder"
        else
            WT_H3=$(mk_wt_commit wt-h3-held feat/h3-held)
            H3_SHA=$(git -C "$WT_H3" rev-parse HEAD)
            # shellcheck disable=SC2031  # GH_ROWS_ORIGIN modified in subshell intentionally in this test harness
            printf 'owner/repo\tfeat/h3-held\tmerged\t%s\n' "$H3_SHA" >> "$GH_ROWS_ORIGIN"
            # Ready marker lives OUTSIDE the worktree (a sibling path), not
            # inside it: an extra untracked file INSIDE the tree perturbs the
            # very git-worktree-remove behaviour under test. cygpath -m (not a
            # bare argv pass) so a native pwsh.exe gets the real Windows path,
            # not MSYS's naive /tmp -> C:\tmp argv mangling (a different,
            # wrong root from /tmp's actual mount).
            ready="$WT_H3.test-ready"
            ready_win=$(cygpath -m "$ready" 2>/dev/null || printf '%s' "$ready")
            rm -f "$ready"
            ( cd "$WT_H3" && "$PWSH" -NoProfile -Command "New-Item -ItemType File '$ready_win' | Out-Null; Start-Sleep 30" ) &
            HOLDER=$!
            tries=0
            while [ ! -f "$ready" ] && [ "$tries" -lt 100 ]; do
                sleep 0.1
                tries=$((tries + 1))
            done
            if [ ! -f "$ready" ]; then
                fail "H3: the pwsh holder never signaled ready — cannot exercise the in-use case"
            else
                h3_out=$(run_clean)
                if [ -d "$WT_H3" ] && [ -e "$WT_H3/.git" ]; then
                    pass "H3: held worktree survives WHOLE (dir + .git)"
                else
                    fail "H3: held worktree is missing its dir or .git (gutted)" "$h3_out"
                fi
                if h_wt_list_has "$WT_H3"; then
                    pass "H3: held worktree's admin row survives"
                else
                    fail "H3: held worktree's admin row is gone" "$h3_out"
                fi
                if [ -f "$WT_H3/wt-h3-held.txt" ] && grep -qF "feat/h3-held" "$WT_H3/wt-h3-held.txt"; then
                    pass "H3: held worktree's tracked content survives"
                else
                    fail "H3: held worktree's tracked content is gone (the pre-fix HIMMEL-2227 wreck)" "$h3_out"
                fi
                if h_branch_gone feat/h3-held; then
                    fail "H3: branch deleted despite an in-use worktree" "$h3_out"
                else
                    pass "H3: branch NOT deleted for the in-use worktree"
                fi
                if grepq "$h3_out" -F "in use by a live process" && grepq "$h3_out" -F "skipped"; then
                    pass "H3: WARN names the worktree as in-use/skipped"
                else
                    fail "H3: expected a WARN naming the worktree in-use/skipped" "$h3_out"
                fi
            fi
            # ALWAYS kill the holder, pass or fail, or the suite leaves an
            # orphan pwsh process behind.
            kill "$HOLDER" 2>/dev/null
            wait "$HOLDER" 2>/dev/null
        fi
        ;;
    *)
        echo "  SKIP: H3 — not Windows; a held cwd blocks neither rename nor rmdir on POSIX (HIMMEL-2227)"
        ;;
esac
clear_checkpoints

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
