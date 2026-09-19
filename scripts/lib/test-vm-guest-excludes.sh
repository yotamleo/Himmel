#!/usr/bin/env bash
# Platform guard (gitbash-only): POSIX bash 3.2+ suite; no .ps1 twin.
# test-vm-guest-excludes.sh — hermetic coverage for scripts/lib/vm-guest-excludes.sh
# (HIMMEL-2540): the host->guest copy must never carry the gitignored-but-present
# secret set (.env, .env.*, *.local.json incl. .claude/settings.local.json), and
# the guest must be ASSERTED clean. No VM, no network, no live .env: every case
# runs on a throwaway fixture tree holding STUB secrets, with ssh/rsync stubbed
# on PATH where a caller script is exercised.
#
# T1 is the RED control: it copies the fixture through the PRE-FIX path (an
# exclude-free tar) and proves the scanner sees the leak — a control that cannot
# fail is not evidence.
#
# Platform: linux/macOS bash (tar, find, rsync optional). Usage:
#   bash scripts/lib/test-vm-guest-excludes.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/vm-guest-excludes.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-vm-guest-excludes.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

FAILED=0
pass() { echo "PASS $1"; }
fail_case() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

if [ ! -f "$LIB" ]; then
  fail_case "T0 $LIB missing (RED: helper not implemented)"
  echo "RESULT: $FAILED failure(s)"; exit 1
fi
# shellcheck source=scripts/lib/vm-guest-excludes.sh
. "$LIB"

# Fixture: a host checkout with STUB secrets only (values are the word STUB).
FIX="$WORK/host"
mkdir -p "$FIX/.claude" "$FIX/sub/deep" "$FIX/.git/hooks" "$FIX/scripts"
for f in .env .env.local sub/.env sub/deep/.env.production .claude/settings.local.json \
         sub/thing.local.json; do
  echo "SECRET=STUB" > "$FIX/$f"
done
echo "KEY=placeholder" > "$FIX/.env.example"
echo keep > "$FIX/keep.txt"
echo keep > "$FIX/scripts/run.sh"

# --- T1 RED control: the pre-fix (exclude-free) copy leaks; the scanner sees it
PRE="$WORK/guest-prefix"; mkdir -p "$PRE"
tar -C "$FIX" -cf - . | tar -C "$PRE" -xf -
out=$(vm_guest_scan "$PRE" full 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q '/\.env$' <<< "$out" && grep -q 'settings\.local\.json' <<< "$out"; then
  pass "T1 RED control: exclude-free copy leaks .env + settings.local.json and the scan flags it"
else
  fail_case "T1 control could not fail (rc=$rc): $out"
fi

# --- T2 tar with the shared excludes carries no secret, keeps the rest
TARX=(); while IFS= read -r _x; do TARX+=("$_x"); done < <(vm_guest_tar_excludes)
GT="$WORK/guest-tar"; mkdir -p "$GT"
tar -C "$FIX" "${TARX[@]}" -cf - . | tar -C "$GT" -xf -
if vm_guest_scan "$GT" full >/dev/null 2>&1 && [ -f "$GT/keep.txt" ] && [ -f "$GT/scripts/run.sh" ]; then
  pass "T2 tar + shared excludes: full-profile scan clean, non-secret files kept"
else
  fail_case "T2 tar+excludes left a secret or dropped a file: $(vm_guest_scan "$GT" full 2>&1)"
fi
for f in .env .env.local sub/.env sub/deep/.env.production .claude/settings.local.json sub/thing.local.json; do
  [ -e "$GT/$f" ] && fail_case "T2 $f crossed the boundary via tar"
done

# --- T3 rsync with the shared excludes (skipped loudly when rsync is absent)
if command -v rsync >/dev/null 2>&1; then
  RSX=(); while IFS= read -r _x; do RSX+=("$_x"); done < <(vm_guest_rsync_excludes)
  GR="$WORK/guest-rsync"; mkdir -p "$GR"
  rsync -a "${RSX[@]}" "$FIX/" "$GR/"
  if vm_guest_scan "$GR" full >/dev/null 2>&1 && [ -f "$GR/keep.txt" ] && [ -f "$GR/.env.example" ]; then
    pass "T3 rsync + shared excludes: full-profile scan clean, public .env.example kept"
  else
    fail_case "T3 rsync+excludes left a secret: $(vm_guest_scan "$GR" full 2>&1)"
  fi
  # a top-level FILE source argument is filtered too (the symmetry script's shape)
  GR2="$WORK/guest-rsync2"; mkdir -p "$GR2"
  rsync -a "${RSX[@]}" "$FIX/.env" "$FIX/keep.txt" "$GR2/"
  if [ ! -e "$GR2/.env" ] && [ -f "$GR2/keep.txt" ]; then
    pass "T3b rsync excludes also filter a named top-level file source"
  else
    fail_case "T3b named .env source crossed via rsync"
  fi
else
  echo "SKIP T3 rsync absent"
fi

# --- T4 profiles: env profile ignores *.local.json, full flags it; .env.example exempt
ONLY="$WORK/only-local"; mkdir -p "$ONLY/.claude"
echo x > "$ONLY/.claude/settings.local.json"; echo x > "$ONLY/.env.example"
if vm_guest_scan "$ONLY" env >/dev/null 2>&1 && ! vm_guest_scan "$ONLY" full >/dev/null 2>&1; then
  pass "T4 env profile passes a guest-created *.local.json; full flags it; .env.example exempt"
else
  fail_case "T4 profile split wrong"
fi
ENVD="$WORK/env-dirty"; mkdir -p "$ENVD/home"; echo x > "$ENVD/home/.env"
if ! vm_guest_scan "$ENVD" env >/dev/null 2>&1; then
  pass "T4b env profile flags a nested .env"
else
  fail_case "T4b env profile missed a nested .env"
fi

# --- T5 fail closed: missing root, unsafe root text, unknown profile
if ! vm_guest_scan "$WORK/does-not-exist" env >/dev/null 2>&1; then
  pass "T5 scan of a missing root fails closed"
else fail_case "T5 missing root passed the scan"; fi
if ! vm_guest_scan_cmd 'a b;rm -rf x' env >/dev/null 2>&1; then
  pass "T5b unsafe root text refused"
else fail_case "T5b unsafe root accepted"; fi
if ! vm_guest_scan "$GT" bogus >/dev/null 2>&1; then
  pass "T5c unknown profile refused"
else fail_case "T5c unknown profile accepted"; fi

# --- T6 vm_guest_assert_clean via a runner (the guest stand-in is a local bash)
# shellcheck disable=SC2317,SC2329  # invoked indirectly by vm_guest_assert_clean
local_runner() { bash -c "$1"; }
if vm_guest_assert_clean local_runner "$GT" full >/dev/null 2>&1; then
  pass "T6 assert_clean: clean tree -> rc 0"
else fail_case "T6 clean tree refused"; fi
if ! vm_guest_assert_clean local_runner "$PRE" full >"$WORK/t6.out" 2>&1 && grep -q 'REFUSING' "$WORK/t6.out"; then
  pass "T6b assert_clean: leaked tree -> REFUSING, rc != 0"
else fail_case "T6b leaked tree not refused: $(cat "$WORK/t6.out")"; fi
# shellcheck disable=SC2317,SC2329  # invoked indirectly by vm_guest_assert_clean
dead_runner() { return 255; }
if ! vm_guest_assert_clean dead_runner "$GT" full >/dev/null 2>&1; then
  pass "T6c assert_clean: unreachable guest (runner rc 255) fails closed"
else fail_case "T6c unreachable guest treated as clean"; fi

# --- T7 the tracked callers use the shared boundary (RED before wiring)
# Stub ssh + rsync on PATH; run the caller against the REAL repo and inspect
# what it would have transferred. ssh is the guest stand-in: it logs the command
# and, for the scan command, emits STUB_LEAK when asked.
STUB="$WORK/stubbin"; mkdir -p "$STUB"
cat > "$STUB/ssh" <<'EOS'
#!/usr/bin/env bash
printf 'SSH %s\n' "$*" >> "$STUB_LOG"
cat > /dev/null 2>&1 < /dev/stdin || true
case "$*" in
  *"command -v rsync"*) [ -n "${STUB_NO_GUEST_RSYNC:-}" ] && exit 1; exit 0 ;;
  *"find "*) [ -n "${STUB_LEAK:-}" ] && echo "$STUB_LEAK"; exit 0 ;;
esac
exit 0
EOS
cat > "$STUB/rsync" <<'EOS'
#!/usr/bin/env bash
printf 'RSYNC %s\n' "$*" >> "$STUB_LOG"
exit 0
EOS
cat > "$STUB/scp" <<'EOS'
#!/usr/bin/env bash
printf 'SCP %s\n' "$*" >> "$STUB_LOG"
exit 0
EOS
chmod +x "$STUB"/ssh "$STUB"/rsync "$STUB"/scp

run_caller() { # $1=script $2=leak-or-empty ; args after: the script's args
  local script="$1" leak="$2"; shift 2
  : > "$WORK/stub.log"
  # Fresh $HOME so nothing real is read; stubs win on PATH.
  PATH="$STUB:$PATH" STUB_LOG="$WORK/stub.log" STUB_LEAK="$leak" STUB_NO_GUEST_RSYNC="${STUB_NO_GUEST_RSYNC:-}" HOME="$WORK/home" \
    timeout 60 bash "$REPO_ROOT/$script" "$@" </dev/null >"$WORK/caller.out" 2>&1
  echo $?
}
mkdir -p "$WORK/home/.ssh"

rc=$(run_caller scripts/test-install-symmetry-vm.sh "")
if grep -qE '^RSYNC .*--exclude[= ]\.env( |$)' "$WORK/stub.log" \
   && grep -qE '^RSYNC .*--exclude[= ]\*\.local\.json( |$)' "$WORK/stub.log"; then
  pass "T7 test-install-symmetry-vm.sh rsync carries the shared secret excludes"
else
  fail_case "T7 symmetry rsync lacks secret excludes: $(grep '^RSYNC' "$WORK/stub.log")"
fi
if grep -q '^SCP .* -r ' "$WORK/stub.log"; then
  fail_case "T7b symmetry script still uses an exclude-free scp -r"
else pass "T7b symmetry script no longer uses scp -r"; fi
rc=$(run_caller scripts/test-install-symmetry-vm.sh "/tmp/himmel-symmetry-vm/scripts/.env")
if [ "$rc" -ne 0 ] && grep -q 'REFUSING' "$WORK/caller.out"; then
  pass "T7c symmetry script refuses (rc=$rc) when the guest scan finds a secret"
else
  fail_case "T7c symmetry script ran on a leaked guest (rc=$rc)"
fi

# scp fallback (guest without rsync): must be a filtered tar pipe, not scp -r
STUB_NO_GUEST_RSYNC=1; rc=$(run_caller scripts/test-install-symmetry-vm.sh ""); STUB_NO_GUEST_RSYNC=
if ! grep -q '^SCP .* -r ' "$WORK/stub.log" && grep -qE '^SSH .*tar .*-xf -' "$WORK/stub.log"; then
  pass "T7f no-rsync guest: symmetry script stages via tar pipe, not scp -r"
else
  fail_case "T7f no-rsync fallback still unfiltered: $(grep -E '^(SCP|SSH .*tar)' "$WORK/stub.log")"
fi

# luna-upgrade: run against the real template dir (it exists in-repo)
TMPL_ARGS=()
rc=$(run_caller scripts/test-luna-upgrade-vm.sh "" "${TMPL_ARGS[@]+"${TMPL_ARGS[@]}"}")
if grep -qE '^RSYNC .*--exclude[= ]\.env( |$)' "$WORK/stub.log"; then
  pass "T7d test-luna-upgrade-vm.sh rsync carries the shared secret excludes"
else
  fail_case "T7d luna-upgrade rsync lacks secret excludes: $(head -3 "$WORK/caller.out"); $(grep '^RSYNC' "$WORK/stub.log")"
fi
rc=$(run_caller scripts/test-luna-upgrade-vm.sh "/tmp/himmel-luna-upgrade-vm/luna-second-brain/.env")
if [ "$rc" -ne 0 ] && grep -q 'REFUSING' "$WORK/caller.out"; then
  pass "T7e luna-upgrade script refuses (rc=$rc) when the guest scan finds a secret"
else
  fail_case "T7e luna-upgrade script ran on a leaked guest (rc=$rc)"
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "RESULT: all passed"; exit 0; fi
echo "RESULT: $FAILED failure(s)"; exit 1
