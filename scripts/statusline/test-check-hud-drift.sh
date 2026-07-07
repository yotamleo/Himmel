#!/usr/bin/env bash
# Smoke test for scripts/statusline/check-hud-drift.sh (HIMMEL-718 Task 1.2).
#
# Builds throwaway git repos with a fixture vendored tree, exercises each rc
# case, asserts exact rc (and offending-path output where the contract says so).
# Usage: bash scripts/statusline/test-check-hud-drift.sh
#
# Exit 0 if all cases pass, 1 otherwise.
#
# shellcheck disable=SC2034  # SCRIPT/R used inside eval'd test body strings
# shellcheck disable=SC2016  # single-quoted test body strings intentionally contain $
# shellcheck disable=SC2317  # fixture fns called indirectly via eval inside run_test
# shellcheck disable=SC2329  # same as SC2317 (alias in newer shellcheck versions)
set -uo pipefail

STATUSLINE="$(cd "$(dirname "$0")" && pwd)"
# Run the script IN PLACE from the real tree (mirrors test-doc-guard.sh): it
# resolves ../guardrails/lib.sh via its own SCRIPT_DIR, and keys the vendored
# dir + marker off `git rev-parse --show-toplevel` of PWD — so `cd "$R"` is all
# a fixture needs.
SCRIPT="$STATUSLINE/check-hud-drift.sh"

HUD_REL="marketplace/plugins/claude-hud"

# setup_repo: temp git repo WITH .himmel-dev + a small fixture vendored tree.
# Upstream-derived files deliberately include ordering/boundary hazards: a
# spaced path, mixed-case names (Zebra vs apple — ordinal vs locale sort), a
# root-level config.js (must NOT be swallowed by the config/ exclude), and a
# VENDORED.mdx (must NOT be swallowed by the VENDORED.md exclude). himmel-owned:
# VENDORED.md, .gitignore, config/himmel-config.json.
setup_repo() {
  R=$(mktemp -d); git -C "$R" init -q
  git -C "$R" config user.email t@t; git -C "$R" config user.name t
  : > "$R/.himmel-dev"
  mkdir -p "$R/$HUD_REL/dist" "$R/$HUD_REL/config"
  echo 'console.log(1)' > "$R/$HUD_REL/dist/index.js"
  echo 'spaced' > "$R/$HUD_REL/dist/my file.js"
  echo '# upstream readme' > "$R/$HUD_REL/README.md"
  echo 'zebra' > "$R/$HUD_REL/Zebra.js"
  echo 'apple' > "$R/$HUD_REL/apple.js"
  echo 'root-config' > "$R/$HUD_REL/config.js"
  echo 'mdx' > "$R/$HUD_REL/VENDORED.mdx"
  echo '!dist/' > "$R/$HUD_REL/.gitignore"
  echo '{}' > "$R/$HUD_REL/config/himmel-config.json"
  printf 'pinned_commit:        deadbeef\nvendored_tree_hash:   __SET_BY_check-hud-drift.sh__\n' \
    > "$R/$HUD_REL/VENDORED.md"
  git -C "$R" add -f "$HUD_REL"
  git -C "$R" commit -qm seed
}

# setup_pinned_repo: setup_repo + `--write` + commit, so verify starts clean.
setup_pinned_repo() {
  setup_repo
  ( cd "$R" && bash "$SCRIPT" --write >/dev/null 2>&1 ) || return 1
  git -C "$R" add -f "$HUD_REL"; git -C "$R" commit -qm pin
}

expect_rc() { local want=$1; shift; local rc=0; "$@" >/dev/null 2>&1 || rc=$?; [ "$rc" -eq "$want" ]; }

_failures=0
_skips=0

# A test body may `exit 77` to declare itself SKIPPED (e.g. a cross-twin case on
# a pwsh-less runner). A distinct skip tally keeps an unchecked contract visible
# instead of silently counting as PASS.
run_test() {
  local name="$1" body="$2"
  local rc=0
  ( eval "$body" ) 2>/dev/null || rc=$?
  if [ "$rc" -eq 77 ]; then
    printf '  SKIP  %s\n' "$name"
    _skips=$((_skips + 1))
  elif [ "$rc" -eq 0 ]; then
    printf '  PASS  %s\n' "$name"
  else
    printf '  FAIL  %s (subshell rc=%s)\n' "$name" "$rc"
    _failures=$((_failures + 1))
  fi
}

# --- rc cases -----------------------------------------------------------------

run_test "(a) clean tree + matching pin -> rc=0" '
  setup_pinned_repo; cd "$R";
  expect_rc 0 bash "$SCRIPT"
'

run_test "--write sets vendored_tree_hash + writes VENDORED.manifest" '
  setup_pinned_repo; cd "$R";
  grep -q "__SET_BY_check-hud-drift.sh__" "$HUD_REL/VENDORED.md" && exit 1;
  grep -qE "^vendored_tree_hash:[[:space:]]+[0-9a-f]{64}" "$HUD_REL/VENDORED.md" || exit 1;
  [ -s "$HUD_REL/VENDORED.manifest" ]
'

run_test "placeholder pin (never written) -> rc=1" '
  setup_repo; cd "$R";
  expect_rc 1 bash "$SCRIPT"
'

run_test "(b) mutated upstream file w/o pin bump -> rc=1 + ONLY that path offending" '
  setup_pinned_repo; cd "$R";
  echo tampered >> "$HUD_REL/dist/index.js";
  out=$(bash "$SCRIPT" 2>&1); rc=$?;
  [ "$rc" -eq 1 ] || exit 1;
  printf "%s" "$out" | grep -q "dist/index.js" || exit 1;
  # precision: untouched files must NOT be reported (caught a real bug where
  # re-sorting the stored manifest by hash made diff flag every line)
  ! printf "%s" "$out" | grep -q "README.md"
'

run_test "(b2) deleted upstream file -> rc=1 + offending path in output" '
  setup_pinned_repo; cd "$R";
  rm "$HUD_REL/README.md";
  out=$(bash "$SCRIPT" 2>&1); rc=$?;
  [ "$rc" -eq 1 ] || exit 1;
  printf "%s" "$out" | grep -q "README.md"
'

run_test "(c) --write after mutation (pin bump) -> verify rc=0" '
  setup_pinned_repo; cd "$R";
  echo tampered >> "$HUD_REL/dist/index.js";
  bash "$SCRIPT" --write >/dev/null 2>&1 || exit 1;
  expect_rc 0 bash "$SCRIPT"
'

run_test "(d) himmel-owned edits (VENDORED.md/.gitignore/config) NOT tripped -> rc=0" '
  setup_pinned_repo; cd "$R";
  echo "note" >> "$HUD_REL/VENDORED.md";
  echo "!dist/**" >> "$HUD_REL/.gitignore";
  echo "{\"a\":1}" > "$HUD_REL/config/himmel-config.json";
  expect_rc 0 bash "$SCRIPT"
'

run_test "no-op without .himmel-dev marker -> rc=0" '
  setup_pinned_repo; cd "$R"; rm -f .himmel-dev;
  echo tampered >> "$HUD_REL/dist/index.js";
  expect_rc 0 bash "$SCRIPT"
'

run_test "HUD_DRIFT_OK=1 bypasses -> rc=0" '
  setup_pinned_repo; cd "$R";
  echo tampered >> "$HUD_REL/dist/index.js";
  expect_rc 0 env HUD_DRIFT_OK=1 bash "$SCRIPT"
'

run_test "outside a git repo -> rc=2 (fail-closed)" '
  cd "$(mktemp -d)";
  expect_rc 2 bash "$SCRIPT"
'

run_test "vendored dir missing in a marked repo -> rc=2 (fail-closed)" '
  setup_repo; cd "$R"; rm -rf "$HUD_REL";
  expect_rc 2 bash "$SCRIPT"
'

run_test "VENDORED.md missing (dir present) -> rc=2 (fail-closed)" '
  setup_repo; cd "$R"; rm "$HUD_REL/VENDORED.md";
  expect_rc 2 bash "$SCRIPT"
'

run_test "vendored_tree_hash line absent -> verify rc=2, --write rc=2 (no silent no-op)" '
  setup_pinned_repo; cd "$R";
  printf "pinned_commit:        deadbeef\n" > "$HUD_REL/VENDORED.md";
  expect_rc 2 bash "$SCRIPT" || exit 1;
  expect_rc 2 bash "$SCRIPT" --write
'

run_test "all-owned tree (no upstream-derived files) -> rc=2 (fail-closed)" '
  setup_repo; cd "$R";
  git rm -q -f "$HUD_REL/dist/index.js" "$HUD_REL/dist/my file.js" "$HUD_REL/README.md" \
    "$HUD_REL/Zebra.js" "$HUD_REL/apple.js" "$HUD_REL/config.js" "$HUD_REL/VENDORED.mdx";
  git -C "$R" commit -qm strip;
  expect_rc 2 bash "$SCRIPT"
'

run_test "--write refuses on missing tracked file -> rc=1 + MISSING path" '
  setup_pinned_repo; cd "$R";
  rm "$HUD_REL/README.md";
  out=$(bash "$SCRIPT" --write 2>&1); rc=$?;
  [ "$rc" -eq 1 ] || exit 1;
  printf "%s" "$out" | grep -q "MISSING" || exit 1;
  printf "%s" "$out" | grep -q "README.md"
'

run_test "exclude-regex boundaries: root config.js + VENDORED.mdx ARE in scope -> rc=1" '
  setup_pinned_repo; cd "$R";
  echo tampered >> "$HUD_REL/config.js";
  echo tampered >> "$HUD_REL/VENDORED.mdx";
  out=$(bash "$SCRIPT" 2>&1); rc=$?;
  [ "$rc" -eq 1 ] || exit 1;
  printf "%s" "$out" | grep -q "config.js" || exit 1;
  printf "%s" "$out" | grep -q "VENDORED.mdx"
'

run_test "spaced path survives offending-path report intact" '
  setup_pinned_repo; cd "$R";
  echo tampered >> "$HUD_REL/dist/my file.js";
  out=$(bash "$SCRIPT" 2>&1); rc=$?;
  [ "$rc" -eq 1 ] || exit 1;
  printf "%s" "$out" | grep -q "dist/my file.js"
'

run_test "autocrlf stability: CRLF worktree and LF worktree record the SAME pin" '
  # Repo A: autocrlf=true, CRLF file content. Repo B: default, LF content.
  # git hash-object applies the clean filter -> identical recorded hash.
  setup_repo; RA="$R";
  git -C "$RA" config core.autocrlf true;
  printf "console.log(1)\r\n" > "$RA/$HUD_REL/dist/index.js";
  git -C "$RA" add -f "$HUD_REL";
  # commit is a no-op when the clean filter maps CRLF to the identical blob —
  # which is exactly the stability this case proves; silence it.
  git -C "$RA" commit -qm crlf >/dev/null 2>&1 || true;
  ( cd "$RA" && bash "$SCRIPT" --write >/dev/null 2>&1 ) || exit 1;
  setup_repo; RB="$R";
  ( cd "$RB" && bash "$SCRIPT" --write >/dev/null 2>&1 ) || exit 1;
  ha=$(grep "^vendored_tree_hash:" "$RA/$HUD_REL/VENDORED.md");
  hb=$(grep "^vendored_tree_hash:" "$RB/$HUD_REL/VENDORED.md");
  [ -n "$ha" ] && [ "$ha" = "$hb" ]
'

run_test "cross-twin parity: .sh --write verifies clean under .ps1 and vice versa" '
  command -v pwsh >/dev/null 2>&1 || exit 77;   # 77 => SKIP tally, not a silent PASS
  PS1_SCRIPT="$STATUSLINE/check-hud-drift.ps1";
  setup_pinned_repo; cd "$R";
  ( pwsh -NoProfile -NonInteractive -File "$PS1_SCRIPT" ) >/dev/null 2>&1 || exit 1;
  echo tampered >> "$HUD_REL/dist/index.js";
  ( pwsh -NoProfile -NonInteractive -File "$PS1_SCRIPT" -Write ) >/dev/null 2>&1 || exit 1;
  expect_rc 0 bash "$SCRIPT"
'

if [ "$_failures" -eq 0 ]; then
  if [ "$_skips" -gt 0 ]; then
    echo "OK: all cases passed ($_skips skipped)"
  else
    echo "OK: all cases passed"
  fi
  exit 0
else
  echo "FAIL: $_failures case(s) failed"
  exit 1
fi
