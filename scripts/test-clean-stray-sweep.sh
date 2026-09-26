#!/usr/bin/env bash
# Hermetic test for clean-garden's de-registered worktree husk sweep
# (HIMMEL-970). Temp git repos + direct .claude/worktrees children.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN_GARDEN="$SCRIPT_DIR/clean-garden.sh"
# shellcheck source=lib/canon-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/canon-path.sh"

PASS=0
FAIL=0
TMP_ROOT=""
TMP_ROOT_UNIX=""

# shellcheck disable=SC2317,SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
    if [ -n "$TMP_ROOT_UNIX" ] && [ -d "$TMP_ROOT_UNIX" ]; then
        rm -rf "$TMP_ROOT_UNIX" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

TMP_ROOT=$(mktemp -d)
# git reports a worktree by its physical path (macOS /var -> /private/var), and
# the registered-worktree case greps `git worktree list` for the fixture's own
# spelling: build it from the physical one (HIMMEL-3179).
TMP_ROOT=$(canon_path "$TMP_ROOT")
TMP_ROOT_UNIX="$TMP_ROOT"
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi

make_repo() {
    local name="$1" repo
    repo="$TMP_ROOT/$name"
    git init -q --initial-branch=main "$repo" 2>/dev/null || {
        git init -q "$repo"
        git -C "$repo" symbolic-ref HEAD refs/heads/main || true
    }
    git -C "$repo" config user.email t@test.com
    git -C "$repo" config user.name t
    # HIMMEL-3187: a detached `git maintenance run --auto` (spawned by every
    # commit) prunes admin records whose `gitdir` file is gone — the very state
    # the 2267 fixture below creates on purpose. No async pruner.
    git -C "$repo" config maintenance.auto false
    printf 'base\n' > "$repo/README"
    git -C "$repo" add README
    git -C "$repo" commit -q -m "base"
    git -C "$repo" branch -m main 2>/dev/null || true
    printf '%s\n' "$repo"
}

# Age a husk RECURSIVELY: the sweep's freshness gate treats ANY entry modified
# in the last 24h as in-flight, so fixtures must age the dir and its contents.
touch_old() {
    find "$1" -exec touch -d '2 days ago' {} + 2>/dev/null \
        || find "$1" -exec touch -t 202001010000 {} +
}

run_clean() {
    local repo="$1"; shift
    (
        cd "$repo" || exit 1
        bash "$CLEAN_GARDEN" --prune-only "$@" 2>&1
    )
}

echo "RUN A: old de-registered husk is swept"
REPO_A=$(make_repo repo-a)
HUSK_A="$REPO_A/.claude/worktrees/feat+old-husk"
mkdir -p "$HUSK_A"
printf 'stray\n' > "$HUSK_A/file.txt"
touch_old "$HUSK_A"
out_a=$(run_clean "$REPO_A") || fail "run_clean exited nonzero (repo-a)" "$out_a"
if [ ! -d "$HUSK_A" ]; then
    pass "old husk swept"
else
    fail "old husk still exists" "$out_a"
fi
case "$out_a" in
    *"clean-garden: stray-sweep — 1 swept, 0 failed, 0 refused ("*" reclaimed)"*) pass "old husk summary counts sweep and size" ;;
    *) fail "expected stray-sweep summary for old husk" "$out_a" ;;
esac

echo "RUN B: fresh de-registered husk is skipped"
REPO_B=$(make_repo repo-b)
HUSK_B="$REPO_B/.claude/worktrees/feat+fresh-husk"
mkdir -p "$HUSK_B"
printf 'fresh\n' > "$HUSK_B/file.txt"
out_b=$(run_clean "$REPO_B") || fail "run_clean exited nonzero (repo-b)" "$out_b"
if [ -d "$HUSK_B" ]; then
    pass "fresh husk kept"
else
    fail "fresh husk was swept" "$out_b"
fi
case "$out_b" in
    *"stray-sweep"*) fail "fresh-only run printed stray-sweep summary" "$out_b" ;;
    *) pass "fresh-only run stays quiet" ;;
esac

echo "RUN C: registered worktree under .claude/worktrees is never swept"
REPO_C=$(make_repo repo-c)
mkdir -p "$REPO_C/.claude/worktrees"
WT_C="$REPO_C/.claude/worktrees/feat+registered"
git -C "$REPO_C" worktree add -q "$WT_C" -b feat/registered >/dev/null 2>&1
touch_old "$WT_C"
out_c=$(run_clean "$REPO_C") || fail "run_clean exited nonzero (repo-c)" "$out_c"
if [ -d "$WT_C" ] && git -C "$REPO_C" worktree list --porcelain | grep -Fq "worktree $WT_C"; then
    pass "registered worktree kept"
else
    fail "registered worktree was swept or de-registered" "$out_c"
fi
case "$out_c" in
    *"stray-sweep"*) fail "registered-only run printed stray-sweep summary" "$out_c" ;;
    *) pass "registered-only run stays quiet" ;;
esac

echo "RUN D: dry-run reports would-sweep and removes nothing"
REPO_D=$(make_repo repo-d)
HUSK_D="$REPO_D/.claude/worktrees/feat+dry-husk"
mkdir -p "$HUSK_D"
printf 'dry\n' > "$HUSK_D/file.txt"
touch_old "$HUSK_D"
out_d=$(run_clean "$REPO_D" --dry-run) || fail "run_clean exited nonzero (repo-d)" "$out_d"
# Match by dir basename, not the full $HUSK_D: on Windows the harness path is
# cygpath-mixed (C:/...) while clean-garden prints the POSIX form (/tmp/...).
case "$out_d" in
    *"DRY clean-garden: would sweep stray husk "*"/feat+dry-husk"*) pass "dry-run reports would-sweep" ;;
    *) fail "dry-run did not report would-sweep" "$out_d" ;;
esac
if [ -d "$HUSK_D" ]; then
    pass "dry-run removes nothing"
else
    fail "dry-run removed husk" "$out_d"
fi
case "$out_d" in
    *"clean-garden: stray-sweep — 1 swept, 0 failed, 0 refused ("*" reclaimed)"*) pass "dry-run summary counts would-sweep" ;;
    *) fail "dry-run summary missing" "$out_d" ;;
esac

echo "RUN E: no husks stays quiet"
REPO_E=$(make_repo repo-e)
out_e=$(run_clean "$REPO_E") || fail "run_clean exited nonzero (repo-e)" "$out_e"
case "$out_e" in
    *"stray-sweep"*) fail "no-husk run printed stray-sweep summary" "$out_e" ;;
    *) pass "no-husk run has no stray-sweep summary" ;;
esac

echo "RUN F: old husk dir with a FRESH nested file is skipped (in-flight)"
REPO_F=$(make_repo repo-f)
HUSK_F="$REPO_F/.claude/worktrees/feat+deep-fresh"
mkdir -p "$HUSK_F/nested"
printf 'old\n' > "$HUSK_F/old.txt"
touch_old "$HUSK_F"
printf 'live\n' > "$HUSK_F/nested/live.txt"   # fresh nested write, top dir aged below
touch -d '2 days ago' "$HUSK_F" 2>/dev/null || touch -t 202001010000 "$HUSK_F"
out_f=$(run_clean "$REPO_F") || fail "run_clean exited nonzero (repo-f)" "$out_f"
if [ -d "$HUSK_F" ]; then
    pass "old-dir/fresh-content husk kept"
else
    fail "old-dir/fresh-content husk was swept (freshness gate not recursive)" "$out_f"
fi

echo "RUN G: real dead worktree with uncommitted work is refused, not swept"
REPO_G=$(make_repo repo-g)
# A real `git worktree add` (unlike the plain mkdir'd husks in RUN A-F) runs
# through this machine's global core.hooksPath, which auto-creates/refreshes
# a per-worktree .tokensave/ dir on every git invocation — re-touching files
# inside the fixture DURING clean-garden's own run and defeating touch_old's
# freshness aging. Disable it for this throwaway repo only.
git -C "$REPO_G" config core.hooksPath ""
mkdir -p "$REPO_G/.claude/worktrees"
WT_G="$REPO_G/.claude/worktrees/feat+dead-wt"
git -C "$REPO_G" worktree add -q "$WT_G" -b feat/dead-wt >/dev/null 2>&1
# Stage real uncommitted work BEFORE de-registering: once the admin record's
# gitdir backpointer is gone, `git -C "$WT_G"` can no longer resolve the repo
# at all (fatal: not a git repository) and even staging would fail.
printf 'uncommitted\n' > "$WT_G/dirty.txt"
git -C "$WT_G" add dirty.txt
# De-register the admin record while leaving the worktree dir + its own .git
# FILE in place, so it looks exactly like the husk shape the sweep sees
# (present on disk, invisible to `git worktree list`). Removing the whole
# admin dir (.git/worktrees/feat+dead-wt) breaks the worktree's `.git` file
# pointer outright, so any git command run from inside it — including
# classify_worktree's own status/ls-files calls — fails with "not a git
# repository" (scanfail), not the "tracked" verdict this case needs. Deleting
# only the "gitdir" backpointer file inside the admin dir is what actually
# reproduces "died mid-`git worktree remove`": `git worktree list` no longer
# lists it, while `git -C "$WT_G"` still resolves fine via the worktree's own
# forward-pointing .git file. Do NOT `git worktree prune` — that would also
# clean up other state this test doesn't want to touch.
rm -f "$REPO_G/.git/worktrees/feat+dead-wt/gitdir"
# HIMMEL-2267: `git ... | grep -q` is unsafe under `set -o pipefail` (line 4)
# — grep exits the instant it matches, git gets SIGPIPE, and the PIPELINE's
# exit status goes non-zero even when git's own output DID contain the match.
# That inverts this precondition exactly when it matters: if the worktree is
# still listed (fixture vacuous), the pipeline can still report "no match"
# and this would silently take the wrong branch. Capture then match instead.
wt_list_g=$(git -C "$REPO_G" worktree list --porcelain)
case "$wt_list_g" in
    *"worktree $WT_G"*) fail "2267-precondition: de-register did not remove feat+dead-wt from worktree list (fixture is vacuous)" ;;
    *) pass "2267-precondition: dead worktree is de-registered but still on disk" ;;
esac
touch_old "$WT_G"
out_g=$(run_clean "$REPO_G") || fail "run_clean exited nonzero (repo-g)" "$out_g"
if [ -d "$WT_G" ]; then
    pass "2267-real dead worktree with uncommitted work is refused"
else
    fail "2267-real dead worktree with uncommitted work was swept" "$out_g"
fi
case "$out_g" in
    *"refusing to sweep"*) pass "2267-refusal message printed" ;;
    *) fail "2267-refusal message missing" "$out_g" ;;
esac
# Match by dir basename, not the full $WT_G: on Windows the harness path is
# cygpath-mixed (C:/...) while clean-garden prints the POSIX form (/tmp/...).
case "$out_g" in
    *"refusing to sweep "*"/feat+dead-wt"*) pass "2267-refusal names the dead worktree" ;;
    *) fail "2267-refusal did not name the dead worktree" "$out_g" ;;
esac
case "$out_g" in
    *"clean-garden: stray-sweep — 0 swept, 0 failed, 1 refused ("*" reclaimed)"*) pass "2267-summary reports 1 refused" ;;
    *) fail "2267-summary did not report 1 refused" "$out_g" ;;
esac

echo "RUN H: find failure on the .git presence probe fails CLOSED (refused, not swept)"
# HIMMEL-2267: prove the presence-check distinguishes find FAILING from find
# running and finding nothing. Neither chmod nor icacls can force a real I/O
# failure here portably: icacls is off-limits (himmel's destructive-command
# guardrail refuses permission mutation outright), and chmod is a documented
# no-op under Git-Bash/NTFS, so it can't produce an unreadable directory
# there. Instead this fixture shadows PATH with a `find` wrapper that fails
# ONLY for the exact `-maxdepth 1 -name .git` presence-check call on this husk
# (matched by basename, per the RUN D/RUN G cygpath-mixed-vs-POSIX precedent)
# and delegates every other find call (freshness scan, enumeration, other
# husks) to the real find unchanged — portable because it works identically
# whether or not chmod has real semantics on this platform. Vacuity is
# guarded separately by the `.invoked` marker assertion below, which proves
# the wrapper was actually exercised.
REPO_H=$(make_repo repo-h)
HUSK_H="$REPO_H/.claude/worktrees/feat+find-fail"
mkdir -p "$HUSK_H"
printf 'stray\n' > "$HUSK_H/file.txt"
touch_old "$HUSK_H"

REAL_FIND_H=$(command -v find)
FAKE_BIN_H=$(mktemp -d)
cat > "$FAKE_BIN_H/find" <<EOF
#!/usr/bin/env bash
base="\${1##*/}"
if [ "\$base" = "feat+find-fail" ] && [ "\$2" = "-maxdepth" ] && [ "\$3" = "1" ] && [ "\$4" = "-name" ] && [ "\$5" = ".git" ]; then
    echo x >> "$FAKE_BIN_H/.invoked"
    echo "find: simulated I/O failure (HIMMEL-2267 test fixture)" >&2
    exit 1
fi
exec "$REAL_FIND_H" "\$@"
EOF
chmod +x "$FAKE_BIN_H/find"

out_h=$(PATH="$FAKE_BIN_H:$PATH" run_clean "$REPO_H") || fail "run_clean exited nonzero (repo-h)" "$out_h"
if [ -f "$FAKE_BIN_H/.invoked" ]; then
    invoked_h=1
else
    invoked_h=0
fi
rm -rf "$FAKE_BIN_H" 2>/dev/null || true

if [ "$invoked_h" -eq 1 ]; then
    pass "2267-precondition: find wrapper intercepted the .git presence probe"
else
    fail "2267-precondition: find wrapper never saw the presence-probe call (fixture is vacuous)" "$out_h"
fi

if [ -d "$HUSK_H" ]; then
    pass "2267-husk survives when find itself fails (fail-closed)"
else
    fail "2267-husk was swept despite find failure (fail-open regression)" "$out_h"
fi
case "$out_h" in
    *"presence check could not be completed"*"refusing to sweep"*) pass "2267-refusal took the probefail (presence-check-could-not-complete) arm" ;;
    *) fail "2267-refusal did not take the probefail arm" "$out_h" ;;
esac
# Match by dir basename, not the full $HUSK_H: on Windows the harness path is
# cygpath-mixed (C:/...) while clean-garden prints the POSIX form (/tmp/...).
case "$out_h" in
    *"refusing to sweep "*"/feat+find-fail"*) pass "2267-refusal names the uninspectable husk" ;;
    *) fail "2267-refusal did not name the uninspectable husk" "$out_h" ;;
esac
case "$out_h" in
    *"clean-garden: stray-sweep — 0 swept, 0 failed, 1 refused ("*" reclaimed)"*) pass "2267-summary reports 1 refused" ;;
    *) fail "2267-summary did not report 1 refused" "$out_h" ;;
esac

echo "RUN I: HIMMEL-1738 — husk whose only content is an ignored .env is refused + checkpointed, not swept"
REPO_I=$(make_repo repo-i)
git -C "$REPO_I" config core.hooksPath ""
printf '.env\n' >> "$REPO_I/.gitignore"
git -C "$REPO_I" add .gitignore
git -C "$REPO_I" commit -q -m "gitignore .env"
mkdir -p "$REPO_I/.claude/worktrees"
WT_I="$REPO_I/.claude/worktrees/feat+ignored-env"
git -C "$REPO_I" worktree add -q "$WT_I" -b feat/ignored-env >/dev/null 2>&1
printf 'SECRET=1\n' > "$WT_I/.env"
rm -f "$REPO_I/.git/worktrees/feat+ignored-env/gitdir"
touch_old "$WT_I"
out_i=$(run_clean "$REPO_I") || fail "run_clean exited nonzero (repo-i)" "$out_i"
if [ -d "$WT_I" ] && [ -f "$WT_I/.env" ]; then
    pass "1738-a: husk with ignored .env is refused, not swept"
else
    fail "1738-a: husk with ignored .env was swept (ignored user data lost)" "$out_i"
fi
case "$out_i" in
    *"refusing to sweep "*"/feat+ignored-env"*) pass "1738-a: refusal message names the husk" ;;
    *) fail "1738-a: expected a refusal message naming the husk" "$out_i" ;;
esac

echo "RUN J: HIMMEL-1738 — husk whose only ignored content is tool churn (.tokensave/, node_modules/) is still swept (to quarantine)"
REPO_J=$(make_repo repo-j)
git -C "$REPO_J" config core.hooksPath ""
printf '.tokensave/\nnode_modules/\n' >> "$REPO_J/.gitignore"
git -C "$REPO_J" add .gitignore
git -C "$REPO_J" commit -q -m "gitignore churn"
mkdir -p "$REPO_J/.claude/worktrees"
WT_J="$REPO_J/.claude/worktrees/feat+churn-only"
git -C "$REPO_J" worktree add -q "$WT_J" -b feat/churn-only >/dev/null 2>&1
mkdir -p "$WT_J/.tokensave" "$WT_J/node_modules/pkg"
printf 'db\n' > "$WT_J/.tokensave/db.sqlite"
printf 'x\n' > "$WT_J/node_modules/pkg/index.js"
rm -f "$REPO_J/.git/worktrees/feat+churn-only/gitdir"
touch_old "$WT_J"
out_j=$(run_clean "$REPO_J") || fail "run_clean exited nonzero (repo-j)" "$out_j"
if [ -d "$WT_J" ]; then
    fail "1738-b: churn-only husk was not swept from its original path" "$out_j"
else
    pass "1738-b: churn-only husk swept from its original path"
fi
QDIR_J="$(cd "$REPO_J/.git" && pwd)/stray-quarantine"
QUAR_J=$(find "$QDIR_J" -mindepth 1 -maxdepth 1 -type d -name 'feat+churn-only.*' 2>/dev/null | head -1) || true
if [ -n "$QUAR_J" ] && [ -d "$QUAR_J" ]; then
    pass "1738-b: churn-only husk landed in quarantine, not deleted outright"
else
    fail "1738-b: churn-only husk not found in quarantine (deleted outright, or lost)" "$out_j"
fi

echo "RUN K: HIMMEL-1738 — a write landing after classification but before the quarantine move survives (no data loss)"
REPO_K=$(make_repo repo-k)
git -C "$REPO_K" config core.hooksPath ""
mkdir -p "$REPO_K/.claude/worktrees"
WT_K="$REPO_K/.claude/worktrees/feat+race"
git -C "$REPO_K" worktree add -q "$WT_K" -b feat/race >/dev/null 2>&1
rm -f "$REPO_K/.git/worktrees/feat+race/gitdir"
touch_old "$WT_K"

# `du -sk "$stray_dir"` runs after classification and just before the
# quarantine `mv` — the exact window HIMMEL-1738 #2 closes. Shadow it to
# inject a write into the husk at that instant (same PATH-shadowing pattern
# as RUN H's `find` wrapper), then hand off to the real du unchanged.
REAL_DU_K=$(command -v du)
FAKE_BIN_K=$(mktemp -d "${TMPDIR:-/tmp}/himmel-fake-du.XXXXXX")
cat > "$FAKE_BIN_K/du" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
    if [ "\$a" = "$WT_K" ]; then
        printf 'raced-in\n' > "$WT_K/late-write.txt"
        echo x >> "$FAKE_BIN_K/.invoked"
    fi
done
exec "$REAL_DU_K" "\$@"
EOF
chmod +x "$FAKE_BIN_K/du"
out_k=$(PATH="$FAKE_BIN_K:$PATH" run_clean "$REPO_K") || fail "run_clean exited nonzero (repo-k)" "$out_k"
if [ -f "$FAKE_BIN_K/.invoked" ]; then
    pass "1738-c: du wrapper intercepted the pre-move window"
else
    fail "1738-c: du wrapper never fired (fixture is vacuous)" "$out_k"
fi
rm -rf "$FAKE_BIN_K" 2>/dev/null || true
if [ -d "$WT_K" ]; then
    fail "1738-c: raced husk unexpectedly still at its original path" "$out_k"
fi
QDIR_K="$(cd "$REPO_K/.git" && pwd)/stray-quarantine"
QUAR_K=$(find "$QDIR_K" -mindepth 1 -maxdepth 1 -type d -name 'feat+race.*' 2>/dev/null | head -1) || true
if [ -n "$QUAR_K" ] && [ -f "$QUAR_K/late-write.txt" ]; then
    pass "1738-c: content written in the race window survived in quarantine (no data loss)"
else
    fail "1738-c: raced-in content was lost (destroyed outright, or quarantine missing)" "$out_k"
fi

echo "RUN L: HIMMEL-1738 — a later run reaps an aged, still-clean quarantined husk; keeps one that gained content"
REPO_L=$(make_repo repo-l)
git -C "$REPO_L" config core.hooksPath ""
mkdir -p "$REPO_L/.claude/worktrees"
WT_L1="$REPO_L/.claude/worktrees/feat+reap-clean"
git -C "$REPO_L" worktree add -q "$WT_L1" -b feat/reap-clean >/dev/null 2>&1
rm -f "$REPO_L/.git/worktrees/feat+reap-clean/gitdir"
touch_old "$WT_L1"
WT_L2="$REPO_L/.claude/worktrees/feat+reap-dirty"
git -C "$REPO_L" worktree add -q "$WT_L2" -b feat/reap-dirty >/dev/null 2>&1
rm -f "$REPO_L/.git/worktrees/feat+reap-dirty/gitdir"
touch_old "$WT_L2"

out_l1=$(run_clean "$REPO_L") || fail "run_clean (quarantine pass) exited nonzero (repo-l)" "$out_l1"
QDIR_L="$(cd "$REPO_L/.git" && pwd)/stray-quarantine"
Q_CLEAN=$(find "$QDIR_L" -mindepth 1 -maxdepth 1 -type d -name 'feat+reap-clean.*' 2>/dev/null | head -1) || true
Q_DIRTY=$(find "$QDIR_L" -mindepth 1 -maxdepth 1 -type d -name 'feat+reap-dirty.*' 2>/dev/null | head -1) || true
if [ -n "$Q_CLEAN" ] && [ -n "$Q_DIRTY" ]; then
    pass "1738-d-setup: both husks quarantined"

    # Age both quarantine entries AND their sidecar timestamp files past the
    # freshness window, then write fresh content into the "dirty" one only —
    # simulating a write landing AFTER quarantining (distinct from RUN K's
    # race, which lands BEFORE the move).
    touch_old "$Q_CLEAN"
    touch_old "$Q_DIRTY"
    touch -d '2 days ago' "$Q_CLEAN.himmel-quarantined-at" 2>/dev/null || touch -t 202001010000 "$Q_CLEAN.himmel-quarantined-at"
    touch -d '2 days ago' "$Q_DIRTY.himmel-quarantined-at" 2>/dev/null || touch -t 202001010000 "$Q_DIRTY.himmel-quarantined-at"
    printf 'late\n' > "$Q_DIRTY/after-quarantine.txt"

    out_l2=$(run_clean "$REPO_L") || fail "run_clean (reap pass) exited nonzero (repo-l)" "$out_l2"
    if [ ! -d "$Q_CLEAN" ]; then
        pass "1738-d: aged, untouched quarantined husk was reaped"
    else
        fail "1738-d: aged, untouched quarantined husk was NOT reaped" "$out_l2"
    fi
    if [ -d "$Q_DIRTY" ]; then
        pass "1738-d: quarantined husk that gained content was kept"
    else
        fail "1738-d: quarantined husk that gained content was deleted" "$out_l2"
    fi
else
    fail "1738-d-setup: expected both husks in quarantine" "$out_l1"
    fail "1738-d: skipped (setup did not quarantine both husks)"
    fail "1738-d: skipped (setup did not quarantine both husks)"
fi

echo "RUN M: HIMMEL-3688 — a husk dir name containing a newline is swept as ONE path; a decoy at its first-line fragment (relative to cwd) survives"
REPO_M=$(make_repo repo-m)
mkdir -p "$REPO_M/victim"
printf 'important\n' > "$REPO_M/victim/keep.txt"
touch_old "$REPO_M/victim"
HNAME_M=$'x\nvictim'
mkdir -p "$REPO_M/.claude/worktrees/$HNAME_M"
printf 'stray\n' > "$REPO_M/.claude/worktrees/$HNAME_M/file.txt"
touch_old "$REPO_M/.claude/worktrees/$HNAME_M"
out_m=$(run_clean "$REPO_M") || fail "run_clean exited nonzero (repo-m)" "$out_m"
if [ -f "$REPO_M/victim/keep.txt" ] && [ "$(cat "$REPO_M/victim/keep.txt" 2>/dev/null)" = "important" ]; then
    pass "3688-a: decoy at the husk name's first-line fragment survived untouched"
else
    fail "3688-a: decoy was swept or altered (newline in husk name split the loop)" "$out_m"
fi
if [ -d "$REPO_M/.claude/worktrees/$HNAME_M" ]; then
    fail "3688-a: newline-named husk was not swept" "$out_m"
else
    pass "3688-a: newline-named husk swept from its original path"
fi
QDIR_M="$(cd "$REPO_M/.git" && pwd)/stray-quarantine"
QUAR_M_COUNT=0
QUAR_M_HIT=""
while IFS= read -r -d '' qm; do
    QUAR_M_COUNT=$((QUAR_M_COUNT+1))
    case "$(basename "$qm")" in
        x$'\n'victim.*) QUAR_M_HIT="$qm" ;;
    esac
done < <(find "$QDIR_M" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
if [ "$QUAR_M_COUNT" -eq 1 ] && [ -n "$QUAR_M_HIT" ] && [ -f "$QUAR_M_HIT/file.txt" ]; then
    pass "3688-a: newline-named husk landed in quarantine as ONE intact entry"
else
    fail "3688-a: expected exactly one intact quarantine entry for the newline-named husk (count=$QUAR_M_COUNT)" "$out_m"
fi

echo "RUN N: HIMMEL-3688 — a quarantined no-.git husk holding real content is kept, not reaped blindly; an empty or node_modules-only one is still reaped"
REPO_N=$(make_repo repo-n)
mkdir -p "$REPO_N/.claude/worktrees"

HUSK_N_NOTES="$REPO_N/.claude/worktrees/feat+notes-husk"
mkdir -p "$HUSK_N_NOTES"
printf 'do not lose me\n' > "$HUSK_N_NOTES/notes.txt"
touch_old "$HUSK_N_NOTES"

HUSK_N_EMPTY="$REPO_N/.claude/worktrees/feat+empty-husk"
mkdir -p "$HUSK_N_EMPTY"
touch_old "$HUSK_N_EMPTY"

HUSK_N_CHURN="$REPO_N/.claude/worktrees/feat+churn-husk"
mkdir -p "$HUSK_N_CHURN/node_modules/pkg"
printf 'x\n' > "$HUSK_N_CHURN/node_modules/pkg/index.js"
touch_old "$HUSK_N_CHURN"

out_n1=$(run_clean "$REPO_N") || fail "run_clean (quarantine pass) exited nonzero (repo-n)" "$out_n1"
QDIR_N="$(cd "$REPO_N/.git" && pwd)/stray-quarantine"
QN_NOTES=$(find "$QDIR_N" -mindepth 1 -maxdepth 1 -type d -name 'feat+notes-husk.*' 2>/dev/null | head -1) || true
QN_EMPTY=$(find "$QDIR_N" -mindepth 1 -maxdepth 1 -type d -name 'feat+empty-husk.*' 2>/dev/null | head -1) || true
QN_CHURN=$(find "$QDIR_N" -mindepth 1 -maxdepth 1 -type d -name 'feat+churn-husk.*' 2>/dev/null | head -1) || true
if [ -n "$QN_NOTES" ] && [ -n "$QN_EMPTY" ] && [ -n "$QN_CHURN" ]; then
    pass "3688-b-setup: all three no-.git husks quarantined"

    touch_old "$QN_NOTES"
    touch_old "$QN_EMPTY"
    touch_old "$QN_CHURN"
    touch -d '2 days ago' "$QN_NOTES.himmel-quarantined-at" 2>/dev/null || touch -t 202001010000 "$QN_NOTES.himmel-quarantined-at"
    touch -d '2 days ago' "$QN_EMPTY.himmel-quarantined-at" 2>/dev/null || touch -t 202001010000 "$QN_EMPTY.himmel-quarantined-at"
    touch -d '2 days ago' "$QN_CHURN.himmel-quarantined-at" 2>/dev/null || touch -t 202001010000 "$QN_CHURN.himmel-quarantined-at"

    out_n2=$(run_clean "$REPO_N") || fail "run_clean (reap pass) exited nonzero (repo-n)" "$out_n2"
    if [ -d "$QN_NOTES" ]; then
        pass "3688-b: no-.git husk holding notes.txt was KEPT, not reaped"
    else
        fail "3688-b: no-.git husk holding real content was reaped (data loss)" "$out_n2"
    fi
    if [ ! -d "$QN_EMPTY" ]; then
        pass "3688-b: empty no-.git husk was reaped"
    else
        fail "3688-b: empty no-.git husk was NOT reaped" "$out_n2"
    fi
    if [ ! -d "$QN_CHURN" ]; then
        pass "3688-b: node_modules-only no-.git husk was reaped"
    else
        fail "3688-b: node_modules-only no-.git husk was NOT reaped" "$out_n2"
    fi
else
    fail "3688-b-setup: expected all three no-.git husks in quarantine" "$out_n1"
    fail "3688-b: skipped (setup did not quarantine notes husk)"
    fail "3688-b: skipped (setup did not quarantine empty husk)"
    fail "3688-b: skipped (setup did not quarantine churn husk)"
fi

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
