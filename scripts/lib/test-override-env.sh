#!/usr/bin/env bash
# scripts/lib/test-override-env.sh -- suite for scripts/lib/override-env.sh
# (HIMMEL-3092): the guard-override list, the scrub, the drift gate that keeps
# the list complete, and the runner wiring that applies it to every suite.
#
# Ambient guard overrides leak from a console leg's shell into hook suites and
# turn "override UNSET, guard must fire" cases into vacuous or red ones. This
# suite pins the four invariants: the scrub clears the list, the list cannot
# silently drift behind a new `FOO_OK` read, the runner scrubs every suite it
# launches, and the affected hook suites self-scrub for the launch paths that do
# not go through the runner (quiet-run, direct bash).
#
# Platform guard (gitbash-only): bash + git + grep only; runs unchanged under Git
# Bash on Windows. No .ps1 twin needed.
set -uo pipefail

# shellcheck source=../ci/run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/../ci/run-shell-tests-fixture.sh"

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$LIB_DIR/../.." && pwd)"
LIB="$LIB_DIR/override-env.sh"

# The five vars a console leg leaks (HIMMEL-3092 DONE WHEN) plus the kill switch.
LEAKED="INLINE_IMPL_OK HIMMEL_CONSOLE_LEG CLAUDE_CODE_CHILD_SESSION HIMMEL_HOOK_INTEGRITY_BYPASS_OK IMPL_GUARD_OK IMPL_GUARD_DISABLE"

echo "== Case 1: lib present, defines the API =="
if [ -r "$LIB" ]; then
  # shellcheck source=override-env.sh
  # shellcheck disable=SC1091
  . "$LIB"
  if [ "$(type -t scrub_override_env)" = function ] && [ "$(type -t override_env_undeclared)" = function ]; then
    pass "scrub_override_env and override_env_undeclared defined"
  else
    fail "lib sourced but scrub_override_env / override_env_undeclared missing"
  fi
else
  fail "scripts/lib/override-env.sh missing"
  rst_tally
  exit 1
fi

echo "== Case 2: scrub clears every leaked var, the whole list, and MCP_*_OK =="
out2=$(
  for v in $LEAKED $HIMMEL_OVERRIDE_ENV_OK_VARS MCP_ZZZ_TEST_OK; do export "$v=1"; done
  export HIMMEL_3092_KEEP=keep
  scrub_override_env
  left=""
  for v in $LEAKED $HIMMEL_OVERRIDE_ENV_OK_VARS MCP_ZZZ_TEST_OK; do
    [ -n "${!v-}" ] && left="$left $v"
  done
  printf 'left=[%s] keep=[%s]\n' "$left" "${HIMMEL_3092_KEEP-}"
)
if [ "$out2" = "left=[] keep=[keep]" ]; then
  pass "every override unset, unrelated variable untouched"
else
  fail "scrub left overrides set or clobbered an unrelated var: $out2"
fi

echo "== Case 3: every leaked var is covered by the list =="
missing3=""
for v in $LEAKED; do
  case " $HIMMEL_OVERRIDE_ENV_OK_VARS $HIMMEL_OVERRIDE_ENV_MARKERS " in
    *[[:space:]]"$v"[[:space:]]*) ;;
    *) missing3="$missing3 $v" ;;
  esac
done
if [ -z "$missing3" ]; then
  pass "all six leg-leaked names are in the scrub list"
else
  fail "leaked names absent from the list:$missing3"
fi

echo "== Case 4: drift gate -- no undeclared *_OK read in hooks/guardrails/lib =="
# Every tracked, non-test script on the hook / guardrail / pre-commit / pre-push
# side. `git ls-files` (not find) so an untracked scratch file cannot mask it.
scan_files=$(git -C "$REPO" ls-files -- scripts/hooks scripts/guardrails scripts/lib marketplace/plugins/himmel-ops/hooks \
  | grep -vE '(^|/)test-[^/]*$|\.test\.[a-z]+$|fixture' || true)
if [ -z "$scan_files" ]; then
  fail "drift gate scanned zero files (git ls-files empty) -- vacuous"
else
  n_files=$(printf '%s\n' "$scan_files" | wc -l | tr -d ' ')
  scan_args=()
  while IFS= read -r f; do scan_args+=("$REPO/$f"); done <<EOF
$scan_files
EOF
  undeclared=$(override_env_undeclared "${scan_args[@]}")
  if [ -z "$undeclared" ]; then
    pass "no undeclared *_OK read across $n_files scanned files"
  else
    fail "undeclared override(s) read by a hook/guardrail -- add to scripts/lib/override-env.sh: $(printf '%s' "$undeclared" | tr '\n' ' ')"
  fi
fi

echo "== Case 5: RED control -- a new FOO_BAR_OK read in a scratch hook copy is caught =="
sb5=$(mktemp -d "${TMPDIR:-/tmp}/override-env-c5.XXXXXX") || sb5=""
if [ -z "$sb5" ]; then
  fail "5: mktemp failed"
else
  if ! cp "$REPO/scripts/hooks/block-git-stash.sh" "$sb5/hook-clean.sh" \
     || ! cp "$REPO/scripts/hooks/block-git-stash.sh" "$sb5/hook-drifted.sh"; then
    fail "5: could not copy the scratch hook -- drift control would be vacuous"
  fi
  # shellcheck disable=SC2016  # the literal `${FOO_BAR_OK:-}` IS the fixture text
  printf '\n[ -n "${FOO_BAR_OK:-}" ] && exit 0\n' >> "$sb5/hook-drifted.sh"
  clean5=$(override_env_undeclared "$sb5/hook-clean.sh")
  drift5=$(override_env_undeclared "$sb5/hook-drifted.sh")
  if [ -z "$clean5" ] && [ "$drift5" = "FOO_BAR_OK" ]; then
    pass "unmodified copy -> empty; copy with a new FOO_BAR_OK read -> exactly FOO_BAR_OK"
  else
    fail "drift control wrong: clean=[$clean5] drifted=[$drift5]"
  fi
  # JS shape: process.env.NAME_OK
  printf 'if (process.env.JS_NEW_OK) process.exit(0);\n' > "$sb5/hook-drifted.js"
  jsout=$(override_env_undeclared "$sb5/hook-drifted.js")
  if [ "$jsout" = "JS_NEW_OK" ]; then
    pass "process.env.JS_NEW_OK read caught"
  else
    fail "JS env read not caught: [$jsout]"
  fi
  # JS bracket shapes: process.env["NAME_OK"] / process.env['NAME_OK'] (HIMMEL-3211)
  printf 'if (process.env["JS_BRACKET_OK"]) process.exit(0);\n' > "$sb5/hook-bracket-dq.js"
  printf "if (process.env['JS_BRACKET_SQ_OK']) process.exit(0);\n" > "$sb5/hook-bracket-sq.js"
  dqout=$(override_env_undeclared "$sb5/hook-bracket-dq.js")
  sqout=$(override_env_undeclared "$sb5/hook-bracket-sq.js")
  if [ "$dqout" = "JS_BRACKET_OK" ]; then
    pass "process.env[\"JS_BRACKET_OK\"] read caught"
  else
    fail "double-quoted bracket read not caught: [$dqout]"
  fi
  if [ "$sqout" = "JS_BRACKET_SQ_OK" ]; then
    pass "process.env['JS_BRACKET_SQ_OK'] read caught"
  else
    fail "single-quoted bracket read not caught: [$sqout]"
  fi
  # Whitespace inside the brackets is still a literal read (codex-1 round 1).
  printf 'if (process.env[ "JS_SPACED_OK" ]) process.exit(0);\n' > "$sb5/hook-bracket-ws.js"
  wsout=$(override_env_undeclared "$sb5/hook-bracket-ws.js")
  if [ "$wsout" = "JS_SPACED_OK" ]; then
    pass "process.env[ \"JS_SPACED_OK\" ] (padded brackets) read caught"
  else
    fail "padded bracket read not caught: [$wsout]"
  fi
  # A name that merely STARTS with an _OK token inside the quotes is a different variable (codex-1 round 2).
  printf 'const v = process.env["FEATURE_OK-extra"];\n' > "$sb5/hook-bracket-ext.js"
  extout=$(override_env_undeclared "$sb5/hook-bracket-ext.js")
  if [ -z "$extout" ]; then
    pass "process.env[\"FEATURE_OK-extra\"] not reported as FEATURE_OK"
  else
    fail "bracket read with a trailing suffix wrongly reported: [$extout]"
  fi
  # A concatenated key is a different (computed) name, and an unclosed bracket is not a read (codex-1 round 3).
  printf 'const v = process.env["FEATURE_OK" + "-extra"];\n' > "$sb5/hook-bracket-cat.js"
  printf 'const v = process.env["UNCLOSED_OK"\n' > "$sb5/hook-bracket-open.js"
  catout=$(override_env_undeclared "$sb5/hook-bracket-cat.js")
  openout=$(override_env_undeclared "$sb5/hook-bracket-open.js")
  if [ -z "$catout" ] && [ -z "$openout" ]; then
    pass "concatenated and unclosed bracket keys not reported"
  else
    fail "computed/unclosed bracket key wrongly reported: cat=[$catout] open=[$openout]"
  fi
  # A padded close bracket is still a literal read.
  printf 'if (process.env[ "JS_PADCLOSE_OK" ]) process.exit(0);\n' > "$sb5/hook-bracket-pad2.js"
  pad2out=$(override_env_undeclared "$sb5/hook-bracket-pad2.js")
  if [ "$pad2out" = "JS_PADCLOSE_OK" ]; then
    pass "padded close bracket read caught"
  else
    fail "padded close bracket read not caught: [$pad2out]"
  fi
  # Control: a dynamic read names no literal variable, so nothing to report.
  printf 'const v = process.env[name];\n' > "$sb5/hook-bracket-dyn.js"
  dynout=$(override_env_undeclared "$sb5/hook-bracket-dyn.js")
  if [ -z "$dynout" ]; then
    pass "dynamic process.env[name] read not reported"
  else
    fail "dynamic bracket read wrongly reported: [$dynout]"
  fi
  rm -rf "$sb5"
fi

echo "== Case 6: the runner scrubs every suite it launches =="
sb6=$(mktemp -d "${TMPDIR:-/tmp}/override-env-c6.XXXXXX") || sb6=""
if [ -z "$sb6" ]; then
  fail "6: mktemp failed"
else
  cat > "$sb6/test-sees-overrides.sh" <<'SHEOF'
#!/usr/bin/env bash
# Exit 1, naming them, if any guard override reaches this suite.
set -uo pipefail
# Proof the runner actually ran this suite (rc 0 alone could be a skipped suite).
: > "$(dirname "$0")/ran.marker"
seen=""
for v in INLINE_IMPL_OK HIMMEL_CONSOLE_LEG CLAUDE_CODE_CHILD_SESSION \
         HIMMEL_HOOK_INTEGRITY_BYPASS_OK IMPL_GUARD_OK IMPL_GUARD_DISABLE MCP_ZZZ_TEST_OK; do
  [ -n "${!v-}" ] && seen="$seen $v"
done
[ -z "$seen" ] || { echo "LEAKED:$seen"; exit 1; }
exit 0
SHEOF
  chmod +x "$sb6/test-sees-overrides.sh"
  out6=$(
    for v in $LEAKED MCP_ZZZ_TEST_OK; do export "$v=1"; done
    bash "$RUNNER" "$sb6" 2>&1
  )
  rc6=$?
  if [ "$rc6" -eq 0 ] && [ -f "$sb6/ran.marker" ]; then
    pass "runner ran the fixture suite and it saw none of the seven overrides (rc 0)"
  elif [ "$rc6" -eq 0 ]; then
    fail "runner rc 0 but the fixture suite never ran (no ran.marker) -- vacuous pass"
  else
    fail "runner leaked overrides into a suite: rc=$rc6 $(printf '%s' "$out6" | grep -a 'LEAKED' | head -n 2)"
  fi
  rm -rf "$sb6"
fi

echo "== Case 7: hook suites that read an override self-scrub (quiet-run / direct-bash paths) =="
for s in scripts/hooks/test-orchestrator-inline-guard.sh \
         scripts/hooks/test-hook-rewrite-integrity.sh \
         scripts/hooks/test-block-leg-askuserquestion.sh; do
  if grep -qE '^\. .*override-env\.sh' "$REPO/$s" && grep -qE '^scrub_override_env$' "$REPO/$s"; then
    pass "$s sources the lib and calls scrub_override_env"
  else
    fail "$s does not source scripts/lib/override-env.sh and call scrub_override_env"
  fi
done

rst_tally
