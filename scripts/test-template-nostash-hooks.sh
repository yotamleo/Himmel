#!/usr/bin/env bash
# test-template-nostash-hooks.sh -- HIMMEL-2223.
#
# 1. Mechanism: on a stashing `pre-commit install` hook, a tracked file
#    rewritten by another process DURING the hook (Obsidian autosave, in
#    production) makes the stash reapply fail and silently discards the
#    committing session's own unstaged edit. The stash-free wrapper
#    (`pre-commit run --files <staged>`) never stashes, so it cannot lose it.
#    This exercises the REAL `pre-commit` binary and the REAL
#    install-nostash-hooks.sh output -- not a hand-rolled stand-in for
#    either -- so a regression in either one is actually caught.
#
#    Caveat that both RED and GREEN below demonstrate: pre-commit's own
#    whole-tree `_get_diff()` check in pre_commit/commands/run.py reports
#    "files were modified by this hook" and fails the commit whenever ANY
#    tracked file changes during the hook's run, independent of the
#    stash/no-stash mechanism. So the wrapper does not make the race-losing
#    commit succeed -- it only stops the STASH from destroying the
#    concurrent writer's edit. The adopter-facing behaviour is: the write
#    survives, but the commit attempt fails and must be retried.
#
# 2. Wiring: a vault freshly scaffolded from templates/luna-second-brain/
#    must install the wrapper for pre-commit/commit-msg, not the stashing
#    `pre-commit install`.
#
# Usage: bash scripts/test-template-nostash-hooks.sh
# Exit 0 if all cases pass, 1 otherwise.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/luna-second-brain"
INSTALLER="$TEMPLATE/scripts/hooks/install-nostash-hooks.sh"
fails=0
check() {
  if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi
}

# shellcheck source=lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/lib/fixture-tempdir.sh"

if ! command -v pre-commit >/dev/null 2>&1; then
  echo "SKIP - the pre-commit COMMAND is not on PATH (a python3 -c 'import pre_commit' pass is not enough: this test invokes bare \`pre-commit\`); cannot exercise the real stash/no-stash hooks"
  exit 0
fi

# installer_copy_into <dir> -- places a real copy of install-nostash-hooks.sh
# at the SAME relative path a scaffolded vault ships it at
# (scripts/hooks/install-nostash-hooks.sh). Required since HIMMEL-2223 F6:
# the installer derives its target repo from its OWN script location
# ($(dirname "$0")/../..), not the caller's cwd -- invoking the real
# checked-out template copy directly against a fixture dir would resolve to
# the wrong root. Still the real, unmodified script content: not a
# hand-rolled stand-in.
installer_copy_into() {
  local dir="$1"
  mkdir -p "$dir/scripts/hooks"
  cp "$INSTALLER" "$dir/scripts/hooks/install-nostash-hooks.sh"
  chmod +x "$dir/scripts/hooks/install-nostash-hooks.sh"
}

# mk_seed_repo <dir> -- a git repo with a real pre-commit local hook (`hold`,
# just sleeps) wired via .pre-commit-config.yaml, one commit in.
mk_seed_repo() {
  local dir="$1"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  touch "$dir/.single-writer"
  printf '{"pristine":true}\n' > "$dir/data.json"
  printf 'pristine\n' > "$dir/commit-file.txt"
  mkdir -p "$dir/.git-hook-hold"
  cat > "$dir/.git-hook-hold/hold.sh" <<'HOLD'
#!/usr/bin/env bash
touch "$(dirname "$0")/started"
sleep 1.5
HOLD
  chmod +x "$dir/.git-hook-hold/hold.sh"
  cat > "$dir/.pre-commit-config.yaml" <<'CFG'
repos:
  - repo: local
    hooks:
      - id: hold
        name: hold
        entry: bash .git-hook-hold/hold.sh
        language: system
        pass_filenames: false
        always_run: true
CFG
  git -C "$dir" add data.json commit-file.txt .git-hook-hold/hold.sh .pre-commit-config.yaml
  git -C "$dir" commit -qm seed
  installer_copy_into "$dir"
}

# assert_toplevel_is <dir> -- confirms git resolves <dir> itself as the repo
# toplevel before an installer is allowed to touch it (HIMMEL-2223 incident:
# install-nostash-hooks.sh infers its target from cwd via
# `git rev-parse --show-toplevel`, with no target argument -- a stray cd
# elsewhere silently installs into the WRONG repo's shared .git/hooks/).
assert_toplevel_is() {
  local dir="$1" top
  top=$(cd "$dir" && git rev-parse --show-toplevel 2>/dev/null)
  [ "$top" = "$dir" ]
}

# run_race <repo> -- stage ONLY commit-file.txt, leave data.json dirty and
# UNSTAGED, fire a background writer that waits for hold.sh to actually
# START (its own "started" marker, not a fixed timer -- a slow hook
# startup must not be able to put the write outside the hold window) and
# then clobbers data.json partway into the 1.5s hold, commit through
# whatever hook is installed. Prints data.json's final content and the
# tail of the commit's output.
run_race() {
  local repo="$1"
  local marker="$repo/.git-hook-hold/started" waited=0
  rm -f "$marker"
  printf '{"pending-edit":true}\n' > "$repo/data.json"
  printf 'staged-change\n' > "$repo/commit-file.txt"
  git -C "$repo" add commit-file.txt >/dev/null 2>&1
  (
    while [ ! -e "$marker" ] && [ "$waited" -lt 100 ]; do
      sleep 0.05
      waited=$((waited + 1))
    done
    if [ -e "$marker" ]; then
      sleep 0.5
      printf '{"external-write":true}\n' > "$repo/data.json"
    else
      echo "run_race: hold.sh never started within 5s; skipping the write (result is not a valid race)" >&2
    fi
  ) & disown
  git -C "$repo" commit -qm race > "$repo/.race-commit.log" 2>&1
  wait 2>/dev/null
  cat "$repo/data.json"
}

# ---------------------------------------------------------------------------
# RED: stock `pre-commit install` (the stash/rollback installer) reverts a
# concurrent writer's edit to an UNRELATED unstaged tracked file.
# ---------------------------------------------------------------------------
R=$(fixture_mktemp_dir) || { echo "FAIL - could not allocate RED fixture dir"; fails=$((fails+1)); }
if [ -n "${R:-}" ]; then
  mk_seed_repo "$R"
  if ! assert_toplevel_is "$R"; then
    echo "FAIL - RED fixture toplevel is not [$R]; refusing to install into it"
    fails=$((fails+1))
  else
    (cd "$R" && pre-commit install >/dev/null) || { echo "FAIL - stock pre-commit install failed"; fails=$((fails+1)); }
    red_result=$(run_race "$R")
    red_output=$(cat "$R/.race-commit.log" 2>/dev/null)
    check "RED: stock pre-commit stash/rollback reverts the concurrent writer's edit" "$red_result" '{"pending-edit":true}'
    red_msg=$(git -C "$R" log -1 --format=%s)
    check "RED: commit did not land" "$red_msg" "seed"
    case "$red_output" in
      *"files were modified by this hook"*) check "RED: pre-commit reports files were modified by this hook" yes yes ;;
      *) check "RED: pre-commit reports files were modified by this hook" no yes ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# GREEN: the real install-nostash-hooks.sh wrapper (--files, no stash) never
# touches data.json, so the concurrent writer's edit survives. The commit
# STILL does not land -- pre-commit's own whole-tree modified-files check
# fires regardless of the stash mechanism -- but nothing is lost.
# ---------------------------------------------------------------------------
G=$(fixture_mktemp_dir) || { echo "FAIL - could not allocate GREEN fixture dir"; fails=$((fails+1)); }
if [ -n "${G:-}" ]; then
  mk_seed_repo "$G"
  if ! assert_toplevel_is "$G"; then
    echo "FAIL - GREEN fixture toplevel is not [$G]; refusing to install into it"
    fails=$((fails+1))
  else
    (cd "$G" && bash "$G/scripts/hooks/install-nostash-hooks.sh" >/dev/null) || { echo "FAIL - install-nostash-hooks.sh failed"; fails=$((fails+1)); }
    green_result=$(run_race "$G")
    green_output=$(cat "$G/.race-commit.log" 2>/dev/null)
    check "GREEN: the real no-stash wrapper never touches data.json, concurrent write survives" "$green_result" '{"external-write":true}'
    green_msg=$(git -C "$G" log -1 --format=%s)
    check "GREEN: commit did not land (pre-commit's own modified-files check, unrelated to stash)" "$green_msg" "seed"
    case "$green_output" in
      *"files were modified by this hook"*) check "GREEN: pre-commit reports files were modified by this hook" yes yes ;;
      *) check "GREEN: pre-commit reports files were modified by this hook" no yes ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# F1 (judge J1255O finding 1): a global core.hooksPath must make the
# installer refuse -- not write into that shared location -- and must leave
# the global hooks dir and any pre-existing global hook byte-unchanged.
# Scratch HOME + GIT_CONFIG_NOSYSTEM=1 so this never touches the operator's
# real ~/.gitconfig or global hooks.
# ---------------------------------------------------------------------------
F1_HOME=$(fixture_mktemp_dir) || { echo "FAIL - could not allocate F1 scratch HOME"; fails=$((fails+1)); }
if [ -n "${F1_HOME:-}" ]; then
  F1_GLOBAL_HOOKS="$F1_HOME/global-hooks"
  mkdir -p "$F1_GLOBAL_HOOKS"
  printf '#!/bin/sh\necho pre-existing global hook\n' > "$F1_GLOBAL_HOOKS/pre-commit"
  chmod +x "$F1_GLOBAL_HOOKS/pre-commit"
  # shellcheck disable=SC2030,SC2031 # each ( ) below deliberately re-exports
  # its own HOME/GIT_CONFIG_NOSYSTEM into its own subshell; nothing here
  # expects the export to survive past the subshell that set it.
  ( export HOME="$F1_HOME" GIT_CONFIG_NOSYSTEM=1
    git config --global core.hooksPath "$F1_GLOBAL_HOOKS"
    git config --global user.email t@t
    git config --global user.name t )
  # git hash-object, not sha256sum: sha256sum is not on stock macOS, and a
  # missing binary would make BOTH hashes empty and pass the byte-integrity
  # check vacuously; a failed hash command must fail the test instead.
  if ! f1_before_sha=$(git hash-object --no-filters "$F1_GLOBAL_HOOKS/pre-commit"); then
    echo "FAIL - could not hash F1 pre-existing global hook"; fails=$((fails+1)); f1_before_sha="hash-error-before"
  fi
  f1_before_listing=$(ls -A "$F1_GLOBAL_HOOKS")
  F1_V="$F1_HOME/vault"
  mkdir -p "$F1_V"
  # shellcheck disable=SC2030,SC2031
  ( export HOME="$F1_HOME" GIT_CONFIG_NOSYSTEM=1; cd "$F1_V" && git init -q -b main )
  installer_copy_into "$F1_V"
  # shellcheck disable=SC2030,SC2031
  f1_out=$( ( export HOME="$F1_HOME" GIT_CONFIG_NOSYSTEM=1
    cd "$F1_V" && bash "$F1_V/scripts/hooks/install-nostash-hooks.sh" ) 2>&1 )
  f1_rc=$?
  if [ "$f1_rc" -ne 0 ]; then check "F1: installer refuses when core.hooksPath is set" refused refused; else check "F1: installer refuses when core.hooksPath is set" "rc=0" refused; fi
  case "$f1_out" in
    *core.hooksPath*) check "F1: refusal message names core.hooksPath" yes yes ;;
    *) check "F1: refusal message names core.hooksPath" no yes ;;
  esac
  if ! f1_after_sha=$(git hash-object --no-filters "$F1_GLOBAL_HOOKS/pre-commit"); then
    echo "FAIL - could not hash F1 global hook after install attempt"; fails=$((fails+1)); f1_after_sha="hash-error-after"
  fi
  f1_after_listing=$(ls -A "$F1_GLOBAL_HOOKS")
  check "F1: global hook file byte-unchanged" "$f1_after_sha" "$f1_before_sha"
  check "F1: global hooks dir listing unchanged" "$f1_after_listing" "$f1_before_listing"
fi

# ---------------------------------------------------------------------------
# F3 (judge finding 3): the generated pre-commit hook must not rely on
# `mapfile` (bash >=4.4 only). Simulate stock macOS bash 3.2 by disabling the
# builtin via BASH_ENV, the same technique the judge used.
# ---------------------------------------------------------------------------
F3=$(fixture_mktemp_dir) || { echo "FAIL - could not allocate F3 fixture dir"; fails=$((fails+1)); }
if [ -n "${F3:-}" ]; then
  mk_seed_repo "$F3"
  if ! assert_toplevel_is "$F3"; then
    echo "FAIL - F3 fixture toplevel is not [$F3]; refusing to install into it"
    fails=$((fails+1))
  else
    (cd "$F3" && bash "$F3/scripts/hooks/install-nostash-hooks.sh" >/dev/null) || { echo "FAIL - F3 install-nostash-hooks.sh failed"; fails=$((fails+1)); }
    f3_bashenv=$(mktemp "${TMPDIR:-/tmp}/himmel-f3-bashenv.XXXXXX") || { echo "FAIL - could not allocate F3 BASH_ENV file"; fails=$((fails+1)); }
    # "mapfile" here is a string literal disabling the builtin via BASH_ENV
    # (the bash-3.2 simulation) -- not an actual mapfile call in this script.
    printf 'enable -n mapfile\n' > "$f3_bashenv"
    printf 'staged-change\n' > "$F3/commit-file.txt"
    git -C "$F3" add commit-file.txt
    f3_out=$(cd "$F3" && BASH_ENV="$f3_bashenv" git commit -qm "feat: bash-3.2 sim" 2>&1)
    f3_rc=$?
    check "F3: commit through the generated hook succeeds with mapfile disabled (bash-3.2 sim)" "$f3_rc" "0"
    [ "$f3_rc" -ne 0 ] && echo "  F3 output: $f3_out"
    rm -f "$f3_bashenv"
  fi
fi

# ---------------------------------------------------------------------------
# F4 (judge finding 4): pre-commit resolved from PATH at commit time breaks
# under a minimal PATH (GUI/Obsidian-Git commits). Install with the full
# PATH, then commit with pre-commit AND a working `pre_commit` module both
# off the PATH -- the baked-at-install-time interpreter must still work.
# ---------------------------------------------------------------------------
F4=$(fixture_mktemp_dir) || { echo "FAIL - could not allocate F4 fixture dir"; fails=$((fails+1)); }
if [ -n "${F4:-}" ]; then
  mk_seed_repo "$F4"
  if ! assert_toplevel_is "$F4"; then
    echo "FAIL - F4 fixture toplevel is not [$F4]; refusing to install into it"
    fails=$((fails+1))
  else
    (cd "$F4" && bash "$F4/scripts/hooks/install-nostash-hooks.sh" >/dev/null) || { echo "FAIL - F4 install-nostash-hooks.sh failed"; fails=$((fails+1)); }
    f4_minbin=$(mktemp -d "${TMPDIR:-/tmp}/himmel-f4-minbin.XXXXXX") || { echo "FAIL - could not allocate F4 minbin"; fails=$((fails+1)); }
    # ssh-keygen: not part of what's under test (pre-commit resolution), but
    # this host signs commits (commit.gpgsign=true, gpg.format=ssh) and git
    # itself needs it on PATH for ANY commit, restricted or not.
    for b in git bash env sh cat sleep mkdir dirname touch rm ls true sed grep awk ssh-keygen; do
      bin_path=$(command -v "$b" 2>/dev/null) && ln -sf "$bin_path" "$f4_minbin/$b"
    done
    # python3/python present but WITHOUT a working pre_commit module (-S
    # isolates from site-packages), matching the judge's E3 simulation -- so
    # the OLD runtime PATH-resolution fallback cannot succeed either; only a
    # baked-at-install-time absolute path can.
    real_python3=$(command -v python3)
    printf '#!/bin/sh\nexec %s -S "$@"\n' "$real_python3" > "$f4_minbin/python3"
    cp "$f4_minbin/python3" "$f4_minbin/python"
    chmod +x "$f4_minbin/python3" "$f4_minbin/python"
    printf 'staged-change\n' > "$F4/commit-file.txt"
    git -C "$F4" add commit-file.txt
    f4_out=$(cd "$F4" && PATH="$f4_minbin" git commit -qm "feat: restricted PATH" 2>&1)
    f4_rc=$?
    check "F4: commit through the generated hook succeeds when pre-commit is off the commit-time PATH" "$f4_rc" "0"
    [ "$f4_rc" -ne 0 ] && echo "  F4 output: $f4_out"
  fi
fi

# ---------------------------------------------------------------------------
# C1 (judge J1255R finding 1): on an empty ACMR-staged-files list, the
# e9abfdf9 --all-files branch runs every fixer over the WHOLE vault --
# rewriting an unstaged tracked file and re-triggering the very stash-loss
# failure mode this wrapper exists to avoid. Stock pre-commit on an empty
# diff only runs always_run hooks; file-pattern hooks see nothing. Fixtures
# use the REAL template config (as the judge's own exp-e8.sh did), not the
# synthetic mk_seed_repo above, so a regression in the template's actual
# fixer hooks (trailing-whitespace, end-of-file-fixer, check-json) is caught.
# ---------------------------------------------------------------------------
mk_c1_repo() {
  local dir="$1"
  cp -a "$TEMPLATE"/. "$dir"/
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  touch "$dir/.single-writer"
  mkdir -p "$dir/20-Areas" "$dir/00-Inbox" "$dir/40-Archive"
  printf '{"k": 1}\n' > "$dir/20-Areas/settings.json"
  printf 'note to delete\n' > "$dir/00-Inbox/gone.md"
  git -C "$dir" add -A >/dev/null
  git -C "$dir" commit -qm "chore: scaffold" --no-verify >/dev/null
  (cd "$dir" && bash "$dir/scripts/hooks/install-nostash-hooks.sh" >/dev/null 2>&1)
}

# E8a: --allow-empty commit with an UNSTAGED edit to a tracked .json.
C1A=$(fixture_mktemp_dir) || { echo "FAIL - could not allocate C1a fixture dir"; fails=$((fails+1)); }
if [ -n "${C1A:-}" ]; then
  mk_c1_repo "$C1A"
  printf '{"k": 2}   ' > "$C1A/20-Areas/settings.json"
  c1a_before=$(git -C "$C1A" hash-object --no-filters "$C1A/20-Areas/settings.json")
  c1a_out=$(cd "$C1A" && git commit --allow-empty -m "chore: empty" 2>&1)
  c1a_rc=$?
  c1a_after=$(git -C "$C1A" hash-object --no-filters "$C1A/20-Areas/settings.json")
  check "C1a: --allow-empty commit with an unstaged dirty tracked file succeeds" "$c1a_rc" "0"
  check "C1a: unstaged tracked file stays byte-unchanged (not widened to --all-files)" "$c1a_after" "$c1a_before"
  c1a_msg=$(git -C "$C1A" log -1 --format=%s)
  check "C1a: --allow-empty commit landed" "$c1a_msg" "chore: empty"
  [ "$c1a_rc" -ne 0 ] && echo "  C1a output: $c1a_out"
fi

# E8b: deletion-only commit next to an UNRELATED tracked file with a
# pre-existing (already-committed) JSON violation.
C1B=$(fixture_mktemp_dir) || { echo "FAIL - could not allocate C1b fixture dir"; fails=$((fails+1)); }
if [ -n "${C1B:-}" ]; then
  mk_c1_repo "$C1B"
  printf '{not json\n' > "$C1B/40-Archive/legacy.json"
  git -C "$C1B" add 40-Archive/legacy.json
  git -C "$C1B" commit -qm "chore: legacy attachment" --no-verify
  git -C "$C1B" rm -q 00-Inbox/gone.md
  c1b_out=$(cd "$C1B" && git commit -m "chore: delete a note" 2>&1)
  c1b_rc=$?
  check "C1b: deletion-only commit succeeds next to an unrelated pre-existing bad JSON" "$c1b_rc" "0"
  c1b_msg=$(git -C "$C1B" log -1 --format=%s)
  check "C1b: deletion-only commit landed" "$c1b_msg" "chore: delete a note"
  [ "$c1b_rc" -ne 0 ] && echo "  C1b output: $c1b_out"

  # E8c: message-only amend (nothing staged), same repo, chained on E8b's
  # commit -- also next to the same unrelated pre-existing bad JSON.
  c1c_out=$(cd "$C1B" && git commit --amend -m "chore: reworded" 2>&1)
  c1c_rc=$?
  check "C1c: message-only amend (nothing staged) succeeds despite the unrelated bad JSON" "$c1c_rc" "0"
  c1c_msg=$(git -C "$C1B" log -1 --format=%s)
  check "C1c: reworded commit landed" "$c1c_msg" "chore: reworded"
  [ "$c1c_rc" -ne 0 ] && echo "  C1c output: $c1c_out"
fi

# ---------------------------------------------------------------------------
# C2 (judge J1255R finding 2): installer:37 compared a `pwd -P` path against
# `git rev-parse --show-toplevel`'s own output as strings -- on Git-Bash
# these spell the identical directory differently (`/c/...` vs `C:/...`),
# so the comparison falsely refuses a legitimate install. There is no
# Windows host here, so a stubbed `git` simulates the mismatch: it leaves
# every real git operation alone except `rev-parse --show-toplevel`, whose
# output it re-spells with a `C:` prefix, exactly like Git-Bash would.
# ---------------------------------------------------------------------------
C2=$(fixture_mktemp_dir) || { echo "FAIL - could not allocate C2 fixture dir"; fails=$((fails+1)); }
if [ -n "${C2:-}" ]; then
  mk_seed_repo "$C2"
  real_git=$(command -v git)
  c2_stub_bin="$C2.stubbin"
  mkdir -p "$c2_stub_bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'for a in "$@"; do\n'
    # shellcheck disable=SC2016  # writing the stub's own literal source; the stub's shell expands this, not this one
    printf '  if [ "$a" = --show-toplevel ]; then\n'
    # shellcheck disable=SC2016  # same: literal source for the generated stub
    printf '    out=$(%q "$@") || exit $?\n' "$real_git"
    # shellcheck disable=SC2016  # same: literal source for the generated stub
    printf '    printf '"'"'C:%%s\\n'"'"' "$out"\n'
    printf '    exit 0\n'
    printf '  fi\n'
    printf 'done\n'
    printf 'exec %q "$@"\n' "$real_git"
  } > "$c2_stub_bin/git"
  chmod +x "$c2_stub_bin/git"
  c2_out=$(PATH="$c2_stub_bin:$PATH" bash "$C2/scripts/hooks/install-nostash-hooks.sh" 2>&1)
  c2_rc=$?
  check "C2: installer succeeds under a stubbed git that re-spells --show-toplevel (C:/... vs pwd -P's /...)" "$c2_rc" "0"
  [ "$c2_rc" -ne 0 ] && echo "  C2 output: $c2_out"
  # Prove the hooks actually landed where git will look for them, and work:
  # a real commit through the generated hook must run it, not silently skip.
  printf 'staged-change\n' > "$C2/commit-file.txt"
  git -C "$C2" add commit-file.txt
  c2_commit_out=$(cd "$C2" && git commit -qm "feat: stubbed-git commit" 2>&1)
  c2_commit_rc=$?
  check "C2: a real commit through the installed hook succeeds" "$c2_commit_rc" "0"
  [ "$c2_commit_rc" -ne 0 ] && echo "  C2 commit output: $c2_commit_out"
  if [ -e "$C2/.git-hook-hold/started" ]; then
    check "C2: the always_run local hook actually ran" ran ran
  else
    check "C2: the always_run local hook actually ran" "did not run" ran
  fi
fi

# ---------------------------------------------------------------------------
# I1 (judge J1255R finding 3, important): installer:137 passed every staged
# path on ONE argv. A large commit (Windows' ~32K command-line limit; Linux
# ARG_MAX is bigger but still finite) must not overflow it.
# ---------------------------------------------------------------------------
mk_argv_repo() {
  local dir="$1"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  touch "$dir/.single-writer"
  printf 'repos:\n  - repo: local\n    hooks:\n      - id: nope\n        name: nope\n        entry: DO-NOT-COMMIT\n        language: pygrep\n' > "$dir/.pre-commit-config.yaml"
  installer_copy_into "$dir"
  git -C "$dir" add -A
  git -C "$dir" commit -qm seed --no-verify
  (cd "$dir" && bash "$dir/scripts/hooks/install-nostash-hooks.sh" >/dev/null 2>&1)
}
I1=$(fixture_mktemp_dir) || { echo "FAIL - could not allocate I1 fixture dir"; fails=$((fails+1)); }
if [ -n "${I1:-}" ]; then
  mk_argv_repo "$I1"
  i1_dir="$I1/30-Resources/a-reasonably-long-folder-name-for-bulk-imported-web-clippings-2026"
  mkdir -p "$i1_dir"
  i=0
  while [ "$i" -lt 14000 ]; do
    printf 'x\n' > "$i1_dir/clipping-$i-some-long-descriptive-article-title-as-obsidian-web-clipper-names-it.md"
    i=$((i + 1))
  done
  git -C "$I1" add -A
  i1_out=$(cd "$I1" && git commit -qm "feat: bulk clip import" 2>&1)
  i1_rc=$?
  check "I1: a 14000-file commit does not overflow the hook's argv" "$i1_rc" "0"
  case "$i1_out" in
    *"Argument list too long"*) check "I1: no E2BIG in hook output" "argument-list-too-long" "clean" ;;
    *) check "I1: no E2BIG in hook output" "clean" "clean" ;;
  esac
  i1_msg=$(git -C "$I1" log -1 --format=%s)
  check "I1: bulk-import commit landed" "$i1_msg" "feat: bulk clip import"
  [ "$i1_rc" -ne 0 ] && echo "  I1 output (truncated): $(printf '%s' "$i1_out" | head -c 300)"
fi

# ---------------------------------------------------------------------------
# 2. Wiring: a fresh scaffold from the template must get the wrapper.
# ---------------------------------------------------------------------------
if [ -x "$INSTALLER" ]; then
  check "template ships install-nostash-hooks.sh (executable)" yes yes
else
  check "template ships install-nostash-hooks.sh (executable)" "no" yes
fi

for twin in scripts/setup.sh scripts/setup.ps1; do
  f="$TEMPLATE/$twin"
  if grep -q "install-nostash-hooks.sh" "$f" 2>/dev/null; then
    check "$twin wires install-nostash-hooks.sh" yes yes
  else
    check "$twin wires install-nostash-hooks.sh" no yes
  fi
  # The stashing installer must not still be used for pre-commit/commit-msg
  # (pre-push staying on the framework installer is correct and expected).
  # Captured into a variable rather than piped into a terminal `grep -q`:
  # under `pipefail`, `grep -q`'s early exit on first match can SIGPIPE an
  # upstream grep stage and flip the pipeline's exit status (HIMMEL-1430).
  stashing_calls=$(grep -vE '^[[:space:]]*#' "$f" 2>/dev/null \
      | grep -E "(pre_commit|pre-commit) install( |$)" \
      | grep -v -- "--hook-type pre-push")
  if [ -n "$stashing_calls" ]; then
    check "$twin does not call the stashing installer for pre-commit/commit-msg" "still present" "removed"
  else
    check "$twin does not call the stashing installer for pre-commit/commit-msg" "removed" "removed"
  fi
done

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
