#!/usr/bin/env bash
# shellcheck disable=SC2016
# (single quotes are intentional throughout: $-expressions must expand in
# the spawned `bash -c` subshell, not at definition time.)
#
# scripts/lib/test-py-armor.sh — smoke test for the python3 hang armor
# (HIMMEL-249, scripts/lib/py-armor.sh).
#
# Validates:
#   1. py_armor dispatches to python3 with args + exit code intact.
#   2. PY_ARMOR_BIN reroutes to an alternate interpreter.
#   3. py_armor_capture fills PY_ARMOR_OUT (incl. multi-line) + relays rc;
#      empty output yields rc=0 + PY_ARMOR_OUT="" (stale value reset).
#   3b. Degraded mode (no GNU timeout, Windows-ish uname) warns ONCE on
#      stderr — never silently unbounded where the wedge class lives.
#   4. Hang armor half 1: a TERM-ignoring interpreter is SIGKILLed within
#      the (-k) bound instead of wedging forever.
#   5. Hang armor half 2: an orphan child holding stdout does NOT stall
#      py_armor_capture (file redirect, not a $() pipe).
#   6. py_armor_mtime: numeric epoch for a real file, "" for a missing one.
#   7. Consumer integration: the five adopters source the lib, call the
#      armor, and carry no raw `python3 -` invocations.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/py-armor.sh
. "$SCRIPT_DIR/py-armor.sh"

pass=0
fail=0
assert() {
  local desc="$1"; shift
  if "$@"; then
    pass=$((pass+1))
    echo "  ok: $desc"
  else
    fail=$((fail+1))
    echo "  FAIL: $desc"
  fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin"

# Fake python3: prints a marker + args so dispatch is verifiable.
cat > "$tmpdir/bin/python3" <<'EOF'
#!/usr/bin/env bash
echo "FAKEPY3 $*"
exit "${FAKEPY_RC:-0}"
EOF
chmod +x "$tmpdir/bin/python3"
# Fake plain python (PY_ARMOR_BIN target).
cat > "$tmpdir/bin/python" <<'EOF'
#!/usr/bin/env bash
echo "FAKEPY $*"
EOF
chmod +x "$tmpdir/bin/python"

# Run a snippet with the fake interpreters FIRST on PATH, lib freshly
# sourced (detection cache is per-process, so each bash -c re-probes).
run_with_fakes() {  # [VAR=val ...] -- <snippet>
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env "${envs[@]}" PATH="$tmpdir/bin:$PATH" \
    bash -c '. "'"$SCRIPT_DIR"'/py-armor.sh"; '"$1"
}

echo "[test-py-armor] py_armor dispatch + arg passthrough"
out="$(run_with_fakes -- 'py_armor -c "print(1)" "arg with space"')"
assert "dispatches to python3" grep -q '^FAKEPY3 ' <<<"$out"
assert "args intact (incl. spaces)" grep -q -- '-c print(1) arg with space' <<<"$out"

echo "[test-py-armor] py_armor exit-code passthrough"
rc=0
run_with_fakes FAKEPY_RC=42 -- 'py_armor -c "x"' >/dev/null 2>&1 || rc=$?
assert "wrapped rc=42 propagates" test "$rc" -eq 42

echo "[test-py-armor] PY_ARMOR_BIN reroutes the interpreter"
out="$(run_with_fakes -- 'PY_ARMOR_BIN=python py_armor -c "x"')"
assert "plain python used under PY_ARMOR_BIN" grep -q '^FAKEPY ' <<<"$out"

echo "[test-py-armor] py_armor_capture fills PY_ARMOR_OUT + relays rc"
out="$(run_with_fakes -- 'py_armor_capture -c "x" && printf %s "$PY_ARMOR_OUT"')"
assert "PY_ARMOR_OUT holds stdout" grep -q '^FAKEPY3 ' <<<"$out"
rc=0
run_with_fakes FAKEPY_RC=7 -- 'py_armor_capture -c "x"' >/dev/null 2>&1 || rc=$?
assert "capture relays rc=7" test "$rc" -eq 7
out="$(run_with_fakes FAKEPY_RC=7 -- 'py_armor_capture -c "x" || true; printf %s "$PY_ARMOR_OUT"')"
assert "PY_ARMOR_OUT still readable on nonzero rc" grep -q '^FAKEPY3 ' <<<"$out"

echo "[test-py-armor] py_armor_capture preserves multi-line output"
cat > "$tmpdir/bin/python3" <<'EOF'
#!/usr/bin/env bash
printf 'line1\nline2\n'
EOF
chmod +x "$tmpdir/bin/python3"
out="$(run_with_fakes -- 'py_armor_capture -c "x" && printf %s "$PY_ARMOR_OUT"')"
assert "both lines present" bash -c 'grep -q "^line1$" <<<"$1" && grep -q "^line2$" <<<"$1"' _ "$out"

echo "[test-py-armor] py_armor_capture empty output: rc=0 + PY_ARMOR_OUT reset to \"\""
cat > "$tmpdir/bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmpdir/bin/python3"
# Seed a stale value first — capture must RESET it, not leak it through.
out="$(run_with_fakes -- 'PY_ARMOR_OUT=stale-from-last-call; py_armor_capture -c "x"; printf "rc=%s out=[%s]" "$?" "$PY_ARMOR_OUT"')"
assert "rc=0 and PY_ARMOR_OUT empty (stale value cleared)" test "$out" = "rc=0 out=[]"

echo "[test-py-armor] degraded armor warns ONCE on stderr (Windows-ish uname, no GNU timeout)"
cat > "$tmpdir/bin/python3" <<'EOF'
#!/usr/bin/env bash
echo "FAKEPY3 $*"
EOF
chmod +x "$tmpdir/bin/python3"
cat > "$tmpdir/bin/timeout" <<'EOF'
#!/usr/bin/env bash
echo "fake timeout: definitely not the GNU flavor"
EOF
chmod +x "$tmpdir/bin/timeout"
cat > "$tmpdir/bin/uname" <<'EOF'
#!/usr/bin/env bash
echo MINGW64_NT-10.0-fake
EOF
chmod +x "$tmpdir/bin/uname"
run_with_fakes -- 'py_armor -c "x"; py_armor -c "y"' >"$tmpdir/warn.out" 2>"$tmpdir/warn.err"
assert "WARN emitted on stderr" grep -q 'WARN py-armor: GNU timeout unavailable' "$tmpdir/warn.err"
assert "WARN fires once per process (probe cached)" \
  test "$(grep -c 'WARN py-armor' "$tmpdir/warn.err")" -eq 1
assert "stdout contract untouched (no WARN on stdout)" \
  bash -c '! grep -q "WARN py-armor" "$1"' _ "$tmpdir/warn.out"
assert "python still dispatched unbounded" grep -q '^FAKEPY3 ' "$tmpdir/warn.out"
# Remove the fakes — the hang-armor cases below need the REAL GNU timeout.
rm -f "$tmpdir/bin/timeout" "$tmpdir/bin/uname"

if timeout --version 2>/dev/null | grep -qi coreutils; then
  echo "[test-py-armor] hang armor: TERM-ignoring interpreter gets SIGKILLed (bounded)"
  cat > "$tmpdir/bin/python3" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
sleep 30
EOF
  chmod +x "$tmpdir/bin/python3"
  start=$(date +%s)
  rc=0
  run_with_fakes PY_ARMOR_TIMEOUT=1 PY_ARMOR_KILL_AFTER=1 -- 'py_armor_capture -c "x"' >/dev/null 2>&1 || rc=$?
  elapsed=$(( $(date +%s) - start ))
  assert "returns within bound (got ${elapsed}s)" test "$elapsed" -lt 15
  assert "rc signals the kill (124/137, got $rc)" bash -c 'test "$1" -eq 124 -o "$1" -eq 137' _ "$rc"

  echo "[test-py-armor] hang armor: orphan child holding stdout does not stall capture"
  cat > "$tmpdir/bin/python3" <<'EOF'
#!/usr/bin/env bash
( sleep 20 ) &
echo "OUT-BEFORE-ORPHAN"
exit 0
EOF
  chmod +x "$tmpdir/bin/python3"
  start=$(date +%s)
  out="$(run_with_fakes -- 'py_armor_capture -c "x" && printf %s "$PY_ARMOR_OUT"')"
  elapsed=$(( $(date +%s) - start ))
  assert "capture returned without waiting for the orphan (got ${elapsed}s)" test "$elapsed" -lt 10
  assert "output captured despite the orphan" grep -q '^OUT-BEFORE-ORPHAN$' <<<"$out"

  echo "[test-py-armor] hang armor: orphan holding STDERR does not stall a 2>&1 capture (HIMMEL-626)"
  # The T20 shape: an orphan inherits the interpreter's stderr fd, and the
  # caller captures via $(... 2>&1) (a pipe). Pre-fix, python's stderr WAS the
  # caller's pipe, so the orphan held it and the substitution blocked ~20s
  # despite timeout -k. Post-fix, stderr is buffered to a file and replayed,
  # so the orphan only holds a regular-file fd — the capture returns at once
  # and the diagnostic is still relayed.
  cat > "$tmpdir/bin/python3" <<'EOF'
#!/usr/bin/env bash
( sleep 20 ) &
echo "ERR-DIAG" >&2
echo "OUT-LINE"
exit 0
EOF
  chmod +x "$tmpdir/bin/python3"
  start=$(date +%s)
  out="$(run_with_fakes -- 'py_armor_capture -c "x" 2>&1; printf "OUTVAR=%s" "$PY_ARMOR_OUT"')"
  elapsed=$(( $(date +%s) - start ))
  assert "2>&1 capture returned without waiting for the stderr-orphan (got ${elapsed}s)" test "$elapsed" -lt 10
  assert "python stderr replayed through the 2>&1 capture" grep -q '^ERR-DIAG$' <<<"$out"
  assert "stdout still captured into PY_ARMOR_OUT" grep -q 'OUTVAR=OUT-LINE' <<<"$out"
else
  echo "[test-py-armor] SKIP hang-armor cases (no GNU coreutils timeout on this runner)"
fi

echo "[test-py-armor] py_armor_mtime"
echo x > "$tmpdir/stamp"
m="$(py_armor_mtime "$tmpdir/stamp")"
assert "real file yields numeric epoch" bash -c '[[ "$1" =~ ^[0-9]+$ ]]' _ "$m"
m="$(py_armor_mtime "$tmpdir/no-such-file")"
assert "missing file yields empty" test -z "$m"

echo "[test-py-armor] consumer integration — adopters source the lib + call the armor"
repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
for f in \
  scripts/handover/resume-slot.sh \
  scripts/handover/cap-reset-time.sh \
  scripts/handover/arm-resume.sh \
  scripts/hooks/block-edit-on-main.sh \
  scripts/hooks/auto-arm-on-cap.sh
do
  assert "$f sources py-armor.sh" grep -q 'lib/py-armor\.sh' "$repo_root/$f"
  assert "$f calls py_armor" grep -qE 'py_armor(_capture|_mtime)?\b' "$repo_root/$f"
  # No raw `python3 -`/`python -` invocations may remain on code lines —
  # that is the exact shape the armor exists to wrap.
  assert "$f has no raw python invocation" \
    bash -c '! grep -vE "^[[:space:]]*#" "$1" | grep -qE "[^_[:alnum:]]python3? +-"' _ "$repo_root/$f"
done

echo
echo "[test-py-armor] pass=$pass fail=$fail"
test "$fail" -eq 0
