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
# shellcheck source=scripts/lib/timeout-bin.sh
. "$REPO_ROOT/scripts/lib/timeout-bin.sh"

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

# --- T2b the emitter must not change the caller's noglob state (either way)
( set -f; vm_guest_tar_excludes >/dev/null; case $- in *f*) exit 0 ;; *) exit 1 ;; esac )
r_on=$?
( set +f; vm_guest_tar_excludes >/dev/null; case $- in *f*) exit 1 ;; *) exit 0 ;; esac )
r_off=$?
if [ "$r_on" -eq 0 ] && [ "$r_off" -eq 0 ]; then
  pass "T2b tar-excludes emitter preserves the caller's noglob setting"
else fail_case "T2b emitter clobbered noglob (kept-on rc=$r_on, kept-off rc=$r_off)"; fi

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

# --- T4c a SYMLINKED scan root must be followed (find without -H lists only the link)
LNK_TGT="$WORK/link-target"; mkdir -p "$LNK_TGT/sub"; echo x > "$LNK_TGT/sub/.env"
ln -s "$LNK_TGT" "$WORK/link-root"
if ! vm_guest_scan "$WORK/link-root" env >/dev/null 2>&1; then
  pass "T4c a symlinked scan root is followed and its .env is flagged"
else
  fail_case "T4c a symlinked scan root passed as clean (secret hidden behind the link)"
fi

# shellcheck disable=SC2317,SC2329  # invoked indirectly by vm_guest_assert_clean
local_runner_early() { bash -c "$1"; }
# --- T4d a root containing a SPACE is quoted, scanned, and still flags a leak (HIMMEL-3228)
SPD="$WORK/sp ace/tree"; mkdir -p "$SPD/sub"; echo x > "$SPD/sub/.env"
SPC="$WORK/sp ace/clean"; mkdir -p "$SPC"; echo keep > "$SPC/keep.txt"
if ! vm_guest_scan "$SPD" env >/dev/null 2>&1 && vm_guest_scan "$SPC" env >/dev/null 2>&1; then
  pass "T4d a spaced scan root is scanned: leak flagged, clean tree passes"
else fail_case "T4d spaced root refused or mis-scanned: $(vm_guest_scan "$SPD" env 2>&1 | head -2)"; fi
if vm_guest_assert_clean local_runner_early "$SPC" full >/dev/null 2>&1 \
   && ! vm_guest_assert_clean local_runner_early "$SPD" full >/dev/null 2>&1; then
  pass "T4d2 assert_clean works through a runner on a spaced root"
else fail_case "T4d2 assert_clean on a spaced root wrong"; fi

# --- T4e nested DIRECTORY symlinks are followed (HIMMEL-3236). NB: the fixtures live
# under $WORK, so a TMPDIR inside a skipped system tree (/var, /usr, ...) would
# legitimately be bounded out and fail here.
NST_T="$WORK/nest-target"; mkdir -p "$NST_T/proj"; echo x > "$NST_T/proj/.env"
NST_R="$WORK/nest-root"; mkdir -p "$NST_R/home"; ln -s "$NST_T" "$NST_R/home/checkout"
out=$(vm_guest_scan "$NST_R" env 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q '/proj/\.env$' <<< "$out"; then
  pass "T4e a .env behind a nested directory symlink is flagged"
else fail_case "T4e nested symlinked dir passed as clean (rc=$rc): $out"; fi

# --- T4f two hops: root -> a -> b, the secret sits behind the SECOND link
HOP_B="$WORK/hop-b"; mkdir -p "$HOP_B"; echo x > "$HOP_B/.env.prod"
HOP_A="$WORK/hop-a"; mkdir -p "$HOP_A"; ln -s "$HOP_B" "$HOP_A/next"
HOP_R="$WORK/hop-root"; mkdir -p "$HOP_R"; ln -s "$HOP_A" "$HOP_R/first"
if ! vm_guest_scan "$HOP_R" env >/dev/null 2>&1; then
  pass "T4f a .env two symlink hops away is flagged"
else fail_case "T4f a two-hop symlinked secret passed as clean"; fi

# --- T4g loops terminate: a link to an ancestor, and two dirs linking each other
LP="$WORK/loop-root"; mkdir -p "$LP/a" "$LP/b"; echo keep > "$LP/a/keep.txt"
ln -s "$LP" "$LP/a/up"; ln -s "$LP/b" "$LP/a/to-b"; ln -s "$LP/a" "$LP/b/to-a"
# shellcheck disable=SC2016  # the -c script is meant to expand in the child
lp_out=$(${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 30} bash -c '. "$1"; vm_guest_scan "$2" env' _ "$LIB" "$LP" 2>&1); lp_rc=$?
if [ "$lp_rc" -eq 0 ] && [ -z "$lp_out" ]; then
  pass "T4g symlink loops (ancestor link, mutual links) terminate clean"
else fail_case "T4g loop scan did not finish clean (rc=$lp_rc): $lp_out"; fi

# --- T4h file links and dangling links are not directories: nothing to follow
FL="$WORK/filelink-root"; mkdir -p "$FL"; echo keep > "$FL/plain.txt"
ln -s "$FL/plain.txt" "$FL/flink"; ln -s "$WORK/no-such-target" "$FL/dangling"
if vm_guest_scan "$FL" env >/dev/null 2>&1; then
  pass "T4h file symlinks and dangling symlinks do not fail or flag the scan"
else fail_case "T4h file/dangling symlink broke the scan: $(vm_guest_scan "$FL" env 2>&1)"; fi

# --- T4i the bound: a link into a system tree is NOT followed (never scan /usr, /proc, ...)
# find is wrapped on PATH to log every start dir; the OK link is the positive control.
FSTUB="$WORK/findstub"; mkdir -p "$FSTUB"
REAL_FIND=$(command -v find)
cat > "$FSTUB/find" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >> "\$FIND_LOG"
exec "$REAL_FIND" "\$@"
EOS
chmod +x "$FSTUB/find"
BND_OK="$WORK/bound-ok"; mkdir -p "$BND_OK"; echo keep > "$BND_OK/keep.txt"
BND_R="$WORK/bound-root"; mkdir -p "$BND_R"
ln -s /usr "$BND_R/sys-link"; ln -s /proc "$BND_R/proc-link"; ln -s / "$BND_R/slash-link"; ln -s "$BND_OK" "$BND_R/ok-link"
: > "$WORK/find.log"
# shellcheck disable=SC2016  # the -c script is meant to expand in the child
bnd_out=$(PATH="$FSTUB:$PATH" FIND_LOG="$WORK/find.log" ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 30} bash -c '. "$1"; vm_guest_scan "$2" env' _ "$LIB" "$BND_R" 2>&1); bnd_rc=$?
if [ "$bnd_rc" -eq 0 ] && grep -q -- "^-H $(cd -P "$BND_OK" && pwd -P) " "$WORK/find.log" \
   && ! grep -qE -- '^-H (/|/usr|/proc)( |$)' "$WORK/find.log"; then
  pass "T4i links into /usr, /proc and / are not followed; a normal link target is scanned"
else fail_case "T4i bound wrong (rc=$bnd_rc): $bnd_out; log: $(head -8 "$WORK/find.log")"; fi

# --- T4j an unreadable link target fails CLOSED (never a silent clean)
if [ "$(id -u)" -ne 0 ]; then
  DN_T="$WORK/deny-target"; mkdir -p "$DN_T/locked"; chmod 000 "$DN_T/locked"
  DN_R="$WORK/deny-root"; mkdir -p "$DN_R"; ln -s "$DN_T" "$DN_R/link"
  dn_out=$(vm_guest_scan "$DN_R" env 2>&1); dn_rc=$?
  chmod 755 "$DN_T/locked"
  if [ "$dn_rc" -ne 0 ] && grep -q 'failed (find rc' <<< "$dn_out"; then
    pass "T4j an unreadable symlink target refuses (rc=$dn_rc) instead of scanning clean"
  else fail_case "T4j unreadable symlink target did not fail closed (rc=$dn_rc): $dn_out"; fi
else echo "SKIP T4j running as root (chmod 000 does not deny)"; fi

# --- T4k a skipped nested link is VISIBLE (read-only `scan-skipped:` note, counted), never a refusal
sk_cmd=$(vm_guest_scan_cmd "$FL" env)
sk_raw=$(sh -c "$sk_cmd" 2>&1 >/dev/null); sk_rc=$?
sk_std=$(sh -c "$sk_cmd" 2>/dev/null)
if [ "$sk_rc" -eq 0 ] && [ -z "$sk_std" ] && [ "$(grep -c '^scan-skipped: ' <<< "$sk_raw")" -eq 2 ]; then
  pass "T4k file and dangling links print one scan-skipped note each on stderr, stdout stays empty"
else fail_case "T4k skip notes wrong (rc=$sk_rc): std=[$sk_std] err=[$sk_raw]"; fi
sk_err=$(vm_guest_scan "$FL" env 2>&1 >/dev/null); sk_rc=$?
if [ "$sk_rc" -eq 0 ] && grep -q 'did not follow 2 nested link(s)' <<< "$sk_err"; then
  pass "T4k2 vm_guest_scan stays clean and reports the skipped-link count"
else fail_case "T4k2 skipped-link count not reported (rc=$sk_rc): $sk_err"; fi
sk_err=$(vm_guest_scan "$BND_R" env 2>&1 >/dev/null)
if grep -q 'did not follow 3 nested link(s)' <<< "$sk_err"; then
  pass "T4k3 system-tree links (/usr, /proc, /) are counted as skipped"
else fail_case "T4k3 system-tree skips not counted: $sk_err"; fi
SKH="$WORK/skip-hit"; mkdir -p "$SKH"; : > "$SKH/.env"; ln -s "$WORK/no-such-target" "$SKH/dangling"
sk_out=$(vm_guest_scan "$SKH" env 2>/dev/null); sk_rc=$?
if [ "$sk_rc" -eq 1 ] && [ "$sk_out" = "$(cd -P "$SKH" && pwd -P)/.env" ]; then
  pass "T4k4 a real hit still refuses beside skip notes, and the notes are not hits"
else fail_case "T4k4 hit beside skip notes wrong (rc=$sk_rc): $sk_out"; fi
if vm_guest_assert_clean local_runner_early "$FL" env >/dev/null 2>&1; then
  pass "T4k5 assert_clean is not refused by skip notes alone"
else fail_case "T4k5 assert_clean refused a tree with only skipped links"; fi

# --- T4l (HIMMEL-3238) a link whose target sits behind an UNSEARCHABLE ancestor cannot be
# inspected: it is reported `scan-unscanned:` and the scan REFUSES (fail closed), while a
# plain dangling link beside the same fixture still does not refuse (T4l2, the control)
if [ "$(id -u)" -ne 0 ]; then
  UNS="$WORK/unsearchable"; UNL="$WORK/unsearch-root"; mkdir -p "$UNS/inner" "$UNL"; : > "$UNS/inner/.env"
  ln -s "$UNS/inner" "$UNL/behind"; ln -s "$WORK/no-such-target" "$UNL/dangling"
  UND="$WORK/dangle-only-root"; mkdir -p "$UND"; ln -s "$WORK/no-such-target" "$UND/dangling"
  chmod 000 "$UNS"
  un_raw=$(sh -c "$(vm_guest_scan_cmd "$UNL" env)" 2>&1); un_rc=$?
  un_err=$(vm_guest_scan "$UNL" env 2>&1 >/dev/null); un_src=$?
  ud_raw=$(sh -c "$(vm_guest_scan_cmd "$UND" env)" 2>&1); ud_rc=$?
  chmod 755 "$UNS"
  if [ "$un_rc" -ne 0 ] && [ "$un_src" -ne 0 ] && grep -q '^scan-unscanned: .*/behind$' <<< "$un_raw" \
     && grep -q 'failed (find rc' <<< "$un_err"; then
    pass "T4l link behind an unsearchable ancestor is reported scan-unscanned and REFUSES (rc=$un_rc)"
  else fail_case "T4l unsearchable-ancestor link not refused (rc=$un_rc/$un_src): raw=[$un_raw] err=[$un_err]"; fi
  if [ "$ud_rc" -eq 0 ] && grep -q '^scan-skipped: .*/dangling$' <<< "$ud_raw" && ! grep -q 'scan-unscanned' <<< "$ud_raw"; then
    pass "T4l2 a plain dangling link still does NOT refuse (skip note only)"
  else fail_case "T4l2 a plain dangling link refused or went unreported (rc=$ud_rc): $ud_raw"; fi
else echo "SKIP T4l running as root (chmod 000 does not deny)"; fi

# --- T4m (HIMMEL-3239) an inherited CDPATH must not redirect a RELATIVE root: cd would
# resolve 'a b' through CDPATH and print the dir, so d became two lines (or the wrong dir)
CDB="$WORK/cdpath/base"; CDO="$WORK/cdpath/other"; mkdir -p "$CDB/a b" "$CDO/a b" "$CDB/c d" "$CDO/c d"
: > "$CDB/a b/.env"; : > "$CDO/c d/.env"
cd_hit=$(cd "$CDB" && CDPATH="$CDO" sh -c "$(vm_guest_scan_cmd 'a b' env)" 2>&1); cd_hrc=$?
cd_cln=$(cd "$CDB" && CDPATH="$CDO" sh -c "$(vm_guest_scan_cmd 'c d' env)" 2>&1); cd_crc=$?
if [ "$cd_hrc" -eq 0 ] && [ "$cd_hit" = "$(cd -P "$CDB/a b" && pwd -P)/.env" ] && [ "$cd_crc" -eq 0 ] && [ -z "$cd_cln" ]; then
  pass "T4m a relative root is resolved against the cwd, never through CDPATH"
else fail_case "T4m CDPATH redirected a relative root: hit(rc=$cd_hrc)=[$cd_hit] clean(rc=$cd_crc)=[$cd_cln]"; fi

# --- T4n (HIMMEL-3239) shared link targets are scanned ONCE: layers k=1..10, each holding
# two directory links to the next, scanned the innermost layer 2^10 times (a hang)
LAY="$WORK/layers"; mkdir -p "$LAY/L10"; : > "$LAY/L10/keep.txt"
for k in 9 8 7 6 5 4 3 2 1 0; do
  mkdir -p "$LAY/L$k"; ln -s "$LAY/L$((k + 1))" "$LAY/L$k/a"; ln -s "$LAY/L$((k + 1))" "$LAY/L$k/b"
done
: > "$WORK/find.log"
# shellcheck disable=SC2016  # the -c script is meant to expand in the child
lay_out=$(PATH="$FSTUB:$PATH" FIND_LOG="$WORK/find.log" ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 60} bash -c '. "$1"; vm_guest_scan "$2" env' _ "$LIB" "$LAY/L0" 2>&1); lay_rc=$?
lay_n=$(grep -c -- "^-H $(cd -P "$LAY/L10" && pwd -P) -xdev ( " "$WORK/find.log")
if [ "$lay_rc" -eq 0 ] && [ -z "$lay_out" ] && [ "$lay_n" -eq 1 ]; then
  pass "T4n a 10-layer shared-target fixture scans the innermost layer once (not 2^10)"
else fail_case "T4n shared targets rescanned: innermost scanned $lay_n time(s) (rc=$lay_rc): $(printf '%s' "$lay_out" | head -3)"; fi

# --- T5 fail closed: missing root, unsafe root text, unknown profile
if ! vm_guest_scan "$WORK/does-not-exist" env >/dev/null 2>&1; then
  pass "T5 scan of a missing root fails closed"
else fail_case "T5 missing root passed the scan"; fi
unsafe_ok=1
# shellcheck disable=SC2016  # literal metacharacters are the point
for r in 'a b;rm -rf x' "a b'c" 'a b$x' 'a b`x`' ' lead' '-a b' '~user a b' 'a b|c'; do
  vm_guest_scan_cmd "$r" env >/dev/null 2>&1 && { unsafe_ok=0; echo "  accepted: $r"; }
done
if [ "$unsafe_ok" -eq 1 ]; then pass "T5b unsafe root text refused (spaces alone are not unsafe)"
else fail_case "T5b an unsafe root was accepted"; fi
if ! vm_guest_scan "$GT" bogus >/dev/null 2>&1; then
  pass "T5c unknown profile refused"
else fail_case "T5c unknown profile accepted"; fi
# A leading-hyphen root becomes a find EXPRESSION (-quit scans nothing, -delete deletes).
hy_ok=1
for r in -quit -delete -H; do vm_guest_scan_cmd "$r" env >/dev/null 2>&1 && hy_ok=0; done
if [ "$hy_ok" -eq 1 ]; then pass "T5d leading-hyphen scan roots refused"
else fail_case "T5d a leading-hyphen scan root was accepted (find option injection)"; fi

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
  *"tar -C"*) if [ -n "${STUB_FAIL_FIRST_TAR:-}" ] && [ ! -e "$STUB_LOG.tarfail" ]; then : > "$STUB_LOG.tarfail"; exit 1; fi; exit 0 ;;
  *"command -v rsync"*) [ -n "${STUB_NO_GUEST_RSYNC:-}" ] && exit 1; exit 0 ;;
  *"find "*) [ -n "${STUB_LEAK:-}" ] && echo "$STUB_LEAK"; exit 0 ;;
esac
exit 0
EOS
cat > "$STUB/rsync" <<'EOS'
#!/usr/bin/env bash
printf 'RSYNC %s\n' "$*" >> "$STUB_LOG"
exit "${STUB_RSYNC_RC:-0}"
EOS
cat > "$STUB/scp" <<'EOS'
#!/usr/bin/env bash
printf 'SCP %s\n' "$*" >> "$STUB_LOG"
exit 0
EOS
chmod +x "$STUB"/ssh "$STUB"/rsync "$STUB"/scp

run_caller() { # $1=script $2=leak-or-empty ; args after: the script's args
  local script="$1" leak="$2"; shift 2
  : > "$WORK/stub.log"; rm -f "$WORK/stub.log.tarfail"
  # Fresh $HOME so nothing real is read; stubs win on PATH.
  PATH="$STUB:$PATH" STUB_LOG="$WORK/stub.log" STUB_LEAK="$leak" STUB_NO_GUEST_RSYNC="${STUB_NO_GUEST_RSYNC:-}" STUB_FAIL_FIRST_TAR="${STUB_FAIL_FIRST_TAR:-}" STUB_RSYNC_RC="${STUB_RSYNC_RC:-0}" HOME="$WORK/home" \
    ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 60} bash "${CALLER_ROOT:-$REPO_ROOT}/$script" "$@" </dev/null >"$WORK/caller.out" 2>&1
  echo $?
}
mkdir -p "$WORK/home/.ssh"

rc=$(run_caller scripts/test-install-symmetry-vm.sh "")
if [ "$rc" -eq 0 ]; then pass "T7g clean symmetry run completes rc=0"
else fail_case "T7g clean symmetry run failed rc=$rc: $(tail -3 "$WORK/caller.out")"; fi
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
if [ "$rc" -eq 0 ] && ! grep -q '^SCP .* -r ' "$WORK/stub.log" && grep -qE '^SSH .*tar .*-xf -' "$WORK/stub.log"; then
  pass "T7f no-rsync guest: symmetry script stages via tar pipe, not scp -r"
else
  fail_case "T7f no-rsync fallback failed or still unfiltered (rc=$rc): $(grep -E '^(SCP|SSH .*tar)' "$WORK/stub.log")"
fi

# luna-upgrade: run against the real template dir (it exists in-repo)
TMPL_ARGS=()
rc=$(run_caller scripts/test-luna-upgrade-vm.sh "" "${TMPL_ARGS[@]+"${TMPL_ARGS[@]}"}")
# The stub guest cannot run the upgrade body, so the script ends on its own
# vacuity floor (rc=1). Reaching that floor proves the run got PAST staging and
# the clean-guest scan; an early failure or a REFUSING would not print it.
if grep -q 'assertions ran (floor' "$WORK/caller.out" && ! grep -q 'REFUSING' "$WORK/caller.out"; then
  pass "T7h clean luna-upgrade run passes staging + scan (ends only on the stub guest's vacuity floor)"
else
  fail_case "T7h clean luna-upgrade run did not reach the post-stage phase (rc=$rc): $(tail -3 "$WORK/caller.out")"
fi
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

# A failed stage transfer must STOP the run (set -uo pipefail has no errexit, and
# a later succeeding pipeline used to mask an earlier failed one).
for script in scripts/test-install-symmetry-vm.sh scripts/test-luna-upgrade-vm.sh; do
  short=${script##*/}
  STUB_NO_GUEST_RSYNC=1 STUB_FAIL_FIRST_TAR=1; rc=$(run_caller "$script" ""); STUB_NO_GUEST_RSYNC='' STUB_FAIL_FIRST_TAR=''
  if [ "$rc" -ne 0 ] && grep -q 'STAGE FAILED' "$WORK/caller.out"; then
    pass "T7i $short stops (rc=$rc) when a tar stage transfer fails"
  else fail_case "T7i $short ran on past a failed tar transfer (rc=$rc): $(tail -2 "$WORK/caller.out")"; fi
  STUB_RSYNC_RC=1; rc=$(run_caller "$script" ""); STUB_RSYNC_RC=''
  if [ "$rc" -ne 0 ] && grep -q 'STAGE FAILED' "$WORK/caller.out"; then
    pass "T7k $short stops (rc=$rc) when the rsync stage fails"
  else fail_case "T7k $short ran on past a failed rsync (rc=$rc): $(tail -2 "$WORK/caller.out")"; fi
done

# The exclusion list itself must be in force BEFORE any copy: a missing/unreadable
# helper, or one that yields an empty list, must stop the caller with nothing copied
# (with empty excludes the secrets would already be in the guest when the post-copy
# assert fires). CALLER_ROOT points the caller at a private tree it derives its
# REPO from, so the helper can be removed or blanked without touching the real one.
for script in scripts/test-install-symmetry-vm.sh scripts/test-luna-upgrade-vm.sh; do
  short=${script##*/}
  for variant in missing empty; do
    nh="$WORK/nohelper-$variant"; mkdir -p "$nh/scripts/lib"
    cp "$REPO_ROOT/$script" "$nh/$script"
    # luna-upgrade exits early without its template; give the private tree one so
    # the run reaches the staging code (otherwise this control is vacuous).
    mkdir -p "$nh/templates/luna-second-brain/scripts"; : > "$nh/templates/luna-second-brain/scripts/upgrade.sh"
    if [ "$variant" = empty ]; then
      printf 'vm_guest_rsync_excludes() { :; }\nvm_guest_tar_excludes() { :; }\nvm_guest_assert_clean() { return 0; }\n' > "$nh/scripts/lib/vm-guest-excludes.sh"
    fi
    CALLER_ROOT="$nh"; rc=$(run_caller "$script" ""); CALLER_ROOT=''
    if [ "$rc" -ne 0 ] && ! grep -qE '^RSYNC |tar -C' "$WORK/stub.log"; then
      pass "T7m $short stops before any copy when the exclude helper is $variant (rc=$rc)"
    else fail_case "T7m $short copied / ran on with a $variant exclude helper (rc=$rc): $(grep -E '^RSYNC |tar -C' "$WORK/stub.log" | head -2)"; fi
  done
done

echo
if [ "$FAILED" -eq 0 ]; then echo "RESULT: all passed"; exit 0; fi
echo "RESULT: $FAILED failure(s)"; exit 1
