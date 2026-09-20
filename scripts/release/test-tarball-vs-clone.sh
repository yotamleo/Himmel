#!/usr/bin/env bash
# test-tarball-vs-clone.sh -- HIMMEL-3059 slice 1, prerequisite P4. Hermetic (no
# network, no VM, no live HOME): drives the fresh-guest acceptance BODY
# (tarball-vs-clone.sh + converge-check.sh) against a fixture repo whose
# `himmelctl` is a STUB that wires a fake HOME deterministically.
#
# What this proves: the convergence assertion is real -- it passes when the two
# installs end identically and FAILS when they differ, when a path leaks, when an
# install fails, when the checksum control is neutered, and when the snapshot is
# vacuous. What it does NOT prove: that the REAL `himmelctl install` converges on
# a bare guest -- that is the guest run (scripts/test-tarball-install-vm.sh),
# deferred and gated on HIMMEL-3252.
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom (pass/fail echo, always rc 0)
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/scripts/release/build-tarball.sh"
BODY="$ROOT/scripts/release/tarball-vs-clone.sh"
CONV="$ROOT/scripts/release/converge-check.sh"
DRIVER="$ROOT/scripts/test-tarball-install-vm.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $1"; }
bad() { fail=$((fail+1)); echo "FAIL  $1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
tmp="$(mktemp -d "${TMPDIR:-/tmp}/himmel-tvc-test.XXXXXX")" || { echo "cannot create a scratch dir" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# --- fixture: a source repo with a STUB himmelctl ------------------------------
# The stub's end state depends only on its own prefix + HOME + the target repo, so
# two installs converge iff they differ only by location. STUB_MODE forces the
# failure shapes the RED controls need.
fx="$tmp/fx"
mkdir -p "$fx/scripts/himmelctl" "$fx/scripts/hooks"
echo "9.9.9" > "$fx/VERSION"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fx/scripts/hooks/guard.sh"
cat > "$fx/scripts/himmelctl/bin.js" <<'EOF'
#!/usr/bin/env node
// STUB himmelctl for test-tarball-vs-clone.sh -- not the real installer.
const fs = require('fs'), path = require('path');
const prefix = path.resolve(__dirname, '..', '..');
const mode = process.env.STUB_MODE || '';
const [cmd, flag, scope] = process.argv.slice(2);
if (cmd !== 'install' || flag !== '--scope') { console.error('stub: usage'); process.exit(2); }
if (mode === 'fail') { console.error('stub: install failed'); process.exit(1); }
const home = process.env.HOME;
const w = (f, s, m) => { fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, s, m ? { mode: m } : undefined); };
if (scope === 'user') {
  // "diverge-git": a stub whose behaviour depends on HOW the tree got here (.git present) --
  // the exact clone-vs-tarball drift the assertion exists to catch.
  const cloned = fs.existsSync(path.join(prefix, '.git'));
  const hooks = { PreToolUse: [{ matcher: 'Bash', hooks: [{ type: 'command', command: `bash ${prefix}/scripts/hooks/guard.sh` }] }] };
  if (mode === 'diverge-git' && cloned) hooks.PostToolUse = [{ hooks: [{ type: 'command', command: 'true' }] }];
  const repo = mode === 'leak' ? path.join(path.dirname(prefix), 'leaked-' + path.basename(prefix)) : prefix;
  w(path.join(home, '.claude', 'settings.json'),
    JSON.stringify({ env: { HIMMEL_REPO: repo }, statusLine: { type: 'command', command: `bash ${prefix}/scripts/statusline.sh` }, hooks }, null, 2));
  w(path.join(home, '.local', 'bin', 'himmelctl'), `#!/bin/sh\nexec node ${prefix}/scripts/himmelctl/bin.js "$@"\n`, 0o755);
} else if (scope === 'project') {
  const hooksDir = path.join(process.cwd(), '.git', 'hooks');
  w(path.join(hooksDir, 'pre-commit'), `#!/bin/sh\nexec bash ${prefix}/scripts/hooks/guard.sh\n`, 0o755);
  if (mode === 'no-hook-on-tarball' && !fs.existsSync(path.join(prefix, '.git'))) fs.rmSync(path.join(hooksDir, 'pre-commit'));
} else { process.exit(2); }
EOF
git -C "$fx" init -q .
git -C "$fx" add -A
git -C "$fx" -c user.name=t -c user.email=t@e.co commit -q -m fixture
git -C "$fx" rev-parse HEAD >/dev/null 2>&1 || { echo "FAIL  fixture repo could not be created"; exit 1; }

# One tarball (+ .sha256) and one bundle of the SAME commit, reused by every run.
art="$tmp/art"
bash "$BUILD" --version 9.9.9 --src "$fx" --out "$art" --no-build >"$tmp/build.log" 2>&1 \
  || { echo "FAIL  fixture tarball build: $(tail -3 "$tmp/build.log")"; exit 1; }
git -C "$fx" bundle create "$art/fx.bundle" HEAD >/dev/null 2>&1 || { echo "FAIL  fixture bundle"; exit 1; }
tgz="$art/himmel-9.9.9-linux.tar.gz"

run_body() { # run_body <label> [ENV=val ...] -- prints nothing; sets $out (log) and $rc
  local label="$1"; shift
  out="$tmp/$label.log"
  env "$@" bash "$BODY" --work "$tmp/w-$label" --tarball "$tgz" --bundle "$art/fx.bundle" >"$out" 2>&1
  rc=$?
}
has() { grep -qE -- "$2" "$1"; }

# --- T1 GREEN: both paths install, states converge -----------------------------
run_body green STUB_MODE=
[ "$rc" -eq 0 ] && ok "T1 tarball path and clone path converge (rc 0)" || bad "T1 converge" "rc=$rc: $(tail -6 "$out" | tr '\n' '|')"
has "$out" 'clone and tarball installs CONVERGED' && ok "T1 the convergence check ran, not just two exits" || bad "T1 CONVERGED line missing"
has "$out" 'PASS  RED: a corrupted tarball fails sha256sum -c and is not extracted' && ok "T1 the corrupted-tarball control ran and held" || bad "T1 corrupted-tarball control line missing"
# Non-vacuity: the converged snapshot really contains the wired hook.
ph="$tmp/w-green/home-tarball/.claude/settings.json"
if [ -f "$ph" ] && jq -e '.hooks.PreToolUse | length > 0' "$ph" >/dev/null 2>&1; then ok "T1 the tarball-side HOME really got hooks wired"; else bad "T1 tarball-side settings.json missing hooks"; fi
[ -x "$tmp/w-green/home-tarball/.local/bin/himmelctl" ] && ok "T1 the launcher was written" || bad "T1 launcher missing"

# --- T2 RED: the installs diverge because of HOW the tree arrived -------------
run_body diverge STUB_MODE=diverge-git
[ "$rc" -ne 0 ] && ok "T2 RED: a clone-vs-tarball behavioural difference FAILS the run" || bad "T2 divergence was accepted" "rc=$rc"
has "$out" 'did not converge \(converge-check rc=1\)' && ok "T2 it failed on convergence, not on an install error" || bad "T2 wrong failure reason" "$(grep -E '^FAIL' "$out" | tr '\n' '|')"
has "$out" 'PostToolUse' && ok "T2 the diff names the divergent hook" || bad "T2 diff does not show the divergence"

# --- T3 RED: a leaked third path is NOT masked by normalization ---------------
run_body leak STUB_MODE=leak
[ "$rc" -ne 0 ] && ok "T3 RED: a leaked non-prefix path FAILS the run" || bad "T3 leak was masked" "rc=$rc"
has "$out" 'leaked-prefix-' && ok "T3 the diff shows the leaked path" || bad "T3 diff lacks the leaked path"

# --- T4 RED: a project-scope gate missing on one side -------------------------
run_body nohook STUB_MODE=no-hook-on-tarball
[ "$rc" -ne 0 ] && ok "T4 RED: a git hook present on one side only FAILS the run" || bad "T4 missing hook accepted" "rc=$rc"
has "$out" 'did not converge' && ok "T4 reported as a convergence failure" || bad "T4 wrong failure reason"

# --- T5 RED: an install that fails is a failure, not a skip -------------------
run_body instfail STUB_MODE=fail
[ "$rc" -ne 0 ] && ok "T5 RED: himmelctl install exiting non-zero FAILS the run" || bad "T5 failed install accepted" "rc=$rc"
has "$out" 'FAIL  (clone|tarball): himmelctl install --scope user' && ok "T5 names the failing install" || bad "T5 failing install not named"

# --- T6 RED: neuter the checksum control -> the body must notice --------------
# A sha256sum that always succeeds makes "a corrupted tarball fails verification"
# false; the body has to report that, or its checksum control is vacuous.
mkdir -p "$tmp/fakebin"
printf '#!/bin/sh\nexit 0\n' > "$tmp/fakebin/sha256sum"; chmod +x "$tmp/fakebin/sha256sum"
run_body fakesum STUB_MODE= "PATH=$tmp/fakebin:$PATH"
[ "$rc" -ne 0 ] && ok "T6 RED: an always-true sha256sum makes the run FAIL" || bad "T6 neutered checksum went unnoticed" "rc=$rc"
has "$out" 'FAIL  RED: a corrupted tarball (passed verification|was extracted)' && ok "T6 it is the corrupted-tarball control that fired" || bad "T6 wrong control fired"

# --- T7 converge-check directly: identical / vacuous / different --------------
mk_side() { # mk_side <dir> <hook-cmd|-> -- a fake HOME with a settings.json
  mkdir -p "$1/home/.claude" "$1/prefix"
  if [ "$2" = "-" ]; then echo '{}' > "$1/home/.claude/settings.json"
  else printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"%s"}]}]}}\n' "$2" > "$1/home/.claude/settings.json"; fi
}
mk_side "$tmp/ca" "bash $tmp/ca/prefix/g.sh"; mk_side "$tmp/cb" "bash $tmp/cb/prefix/g.sh"
bash "$CONV" --a-home "$tmp/ca/home" --a-prefix "$tmp/ca/prefix" --b-home "$tmp/cb/home" --b-prefix "$tmp/cb/prefix" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "T7 two states differing only by prefix are CONVERGED (rc 0)" || bad "T7 location-only difference flagged"
mk_side "$tmp/cc" "bash $tmp/cc/prefix/other.sh"
bash "$CONV" --a-home "$tmp/ca/home" --a-prefix "$tmp/ca/prefix" --b-home "$tmp/cc/home" --b-prefix "$tmp/cc/prefix" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "T7 RED: a differing hook command is DIVERGED (rc 1)" || bad "T7 differing hook accepted"
mk_side "$tmp/ce1" "-"; mk_side "$tmp/ce2" "-"
bash "$CONV" --a-home "$tmp/ce1/home" --a-prefix "$tmp/ce1/prefix" --b-home "$tmp/ce2/home" --b-prefix "$tmp/ce2/prefix" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "T7 RED: two empty installs are VACUOUS (rc 3), not 'identical'" || bad "T7 vacuous snapshot accepted"
bash "$CONV" --a-home "$tmp/ca/home" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "T7 missing arguments is a usage error (rc 2)" || bad "T7 usage rc"
# Identical MALFORMED plugin JSON on both sides (hooks fine) is a broken install, not convergence.
mk_side "$tmp/cm1" "bash $tmp/cm1/prefix/g.sh"; mk_side "$tmp/cm2" "bash $tmp/cm2/prefix/g.sh"
for s in cm1 cm2; do mkdir -p "$tmp/$s/home/.claude/plugins"; echo '{not json' > "$tmp/$s/home/.claude/plugins/installed_plugins.json"; done
bash "$CONV" --a-home "$tmp/cm1/home" --a-prefix "$tmp/cm1/prefix" --b-home "$tmp/cm2/home" --b-prefix "$tmp/cm2/prefix" >"$tmp/cm.log" 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "T7 RED: identical malformed JSON on both sides is UNREADABLE (rc 3), not CONVERGED" || bad "T7 malformed JSON accepted" "rc=$rc"
has "$tmp/cm.log" 'UNREADABLE' && ok "T7 the refusal names the unreadable snapshot" || bad "T7 no UNREADABLE line"
# Same launcher bytes, one executable and one not: an unusable install must DIVERGE.
mk_side "$tmp/cx1" "bash $tmp/cx1/prefix/g.sh"; mk_side "$tmp/cx2" "bash $tmp/cx2/prefix/g.sh"
for s in cx1 cx2; do mkdir -p "$tmp/$s/home/.local/bin"; printf '#!/bin/sh\nexit 0\n' > "$tmp/$s/home/.local/bin/himmelctl"; done
chmod 755 "$tmp/cx1/home/.local/bin/himmelctl"; chmod 644 "$tmp/cx2/home/.local/bin/himmelctl"
bash "$CONV" --a-home "$tmp/cx1/home" --a-prefix "$tmp/cx1/prefix" --b-home "$tmp/cx2/home" --b-prefix "$tmp/cx2/prefix" >"$tmp/cx.log" 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "T7 RED: an executable launcher vs a non-executable one is DIVERGED (rc 1)" || bad "T7 exec-bit difference accepted" "rc=$rc"
has "$tmp/cx.log" 'NOT executable' && ok "T7 the diff names the missing exec bit" || bad "T7 diff lacks the exec-bit line"
# A sibling location that merely STARTS with the prefix (<prefix>-old) is a different place: not masked.
mk_side "$tmp/cs1" "bash $tmp/cs1/prefix-old/g.sh"; mk_side "$tmp/cs2" "bash $tmp/cs2/prefix-old/g.sh"
bash "$CONV" --a-home "$tmp/cs1/home" --a-prefix "$tmp/cs1/prefix" --b-home "$tmp/cs2/home" --b-prefix "$tmp/cs2/prefix" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "T7 RED: a sibling <prefix>-old path is NOT masked as the prefix (rc 1)" || bad "T7 sibling path masked" "rc=$rc"
# Git hooks that are SYMLINKS count: present on one side only -> DIVERGED; dangling -> UNREADABLE.
mk_side "$tmp/cg1" "bash $tmp/cg1/prefix/g.sh"; mk_side "$tmp/cg2" "bash $tmp/cg2/prefix/g.sh"
for s in cg1 cg2; do git init -q "$tmp/$s/repo" 2>/dev/null; done
printf '#!/bin/sh\nexit 0\n' > "$tmp/cg1/real-hook.sh"; chmod 755 "$tmp/cg1/real-hook.sh"
ln -s "$tmp/cg1/real-hook.sh" "$tmp/cg1/repo/.git/hooks/pre-commit"
bash "$CONV" --a-home "$tmp/cg1/home" --a-prefix "$tmp/cg1/prefix" --a-target "$tmp/cg1/repo" \
  --b-home "$tmp/cg2/home" --b-prefix "$tmp/cg2/prefix" --b-target "$tmp/cg2/repo" >"$tmp/cg.log" 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "T7 RED: a symlinked git hook on one side only is DIVERGED (rc 1)" || bad "T7 symlink hook omitted from the snapshot" "rc=$rc"
has "$tmp/cg.log" 'hook: pre-commit' && ok "T7 the diff names the symlinked hook" || bad "T7 diff lacks the symlinked hook"
rm -f "$tmp/cg1/real-hook.sh"
bash "$CONV" --a-home "$tmp/cg1/home" --a-prefix "$tmp/cg1/prefix" --a-target "$tmp/cg1/repo" \
  --b-home "$tmp/cg2/home" --b-prefix "$tmp/cg2/prefix" --b-target "$tmp/cg2/repo" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "T7 RED: a dangling hook symlink is UNREADABLE (rc 3)" || bad "T7 dangling hook symlink accepted" "rc=$rc"

# --- T9 RED: the published pair does not verify -> the body stops, fail closed --
# The README chain never reaches tar on a bad hash; the body must not extract or
# install the rejected tarball either.
mkdir -p "$tmp/art-tamper"
cp "$tgz" "$tmp/art-tamper/"
printf '%064d  %s\n' 0 "himmel-9.9.9-linux.tar.gz" > "$tmp/art-tamper/himmel-9.9.9-linux.tar.gz.sha256"
bash "$BODY" --work "$tmp/w-tamper" --tarball "$tmp/art-tamper/himmel-9.9.9-linux.tar.gz" --bundle "$art/fx.bundle" >"$tmp/tamper.log" 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "T9 RED: a published pair that does not verify FAILS the run" || bad "T9 tampered .sha256 accepted" "rc=$rc"
has "$tmp/tamper.log" 'FAIL  sha256sum -c rejects the published pair' && ok "T9 it failed on the checksum step" || bad "T9 wrong failure reason"
{ [ ! -d "$tmp/w-tamper/prefix-tarball" ] && [ ! -d "$tmp/w-tamper/home-tarball" ]; } && ok "T9 nothing was extracted or installed after the rejection" || bad "T9 the rejected tarball was used"

# --- T10 RED: the corruption fixture cannot be built -> not a passed control --
# A python3 that does nothing (or fails) leaves no corrupted copy; the resulting
# "sha256sum -c fails" is a MISSING FILE, and must not be scored as a held control.
mkdir -p "$tmp/pybin"
printf '#!/bin/sh\nexit 0\n' > "$tmp/pybin/python3"; chmod +x "$tmp/pybin/python3"
run_body nopy STUB_MODE= "PATH=$tmp/pybin:$PATH"
[ "$rc" -ne 0 ] && ok "T10 RED: an unbuilt corruption fixture FAILS the run" || bad "T10 missing fixture scored as a held control" "rc=$rc"
has "$out" 'FAIL  RED control could not build a corrupted copy' && ok "T10 the fixture failure is named" || bad "T10 wrong failure reason"
printf '#!/bin/sh\nexit 7\n' > "$tmp/pybin/python3"
run_body pyfail STUB_MODE= "PATH=$tmp/pybin:$PATH"
has "$out" 'python3 rc=7' && ok "T10 a failing python3 is reported with its rc" || bad "T10 python3 rc not reported"

# --- T8 the VM driver: unreachable guest fails SOFT (rc 3), and is wired ------
bash -n "$DRIVER" && ok "T8 driver parses (bash -n)" || bad "T8 driver syntax"
mkdir -p "$tmp/sshbin"
printf '#!/bin/sh\nexit 255\n' > "$tmp/sshbin/ssh"; chmod +x "$tmp/sshbin/ssh"
PATH="$tmp/sshbin:$PATH" bash "$DRIVER" nobody@nowhere 2 /nonexistent >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "T8 unreachable VM exits 3 (not a code failure)" || bad "T8 unreachable VM rc"
grep -q 'tarball-vs-clone.sh' "$DRIVER" && grep -q 'vm_guest_assert_clean' "$DRIVER" && grep -q 'build-tarball.sh' "$DRIVER" \
  && ok "T8 driver builds the tarball, asserts the guest clean, runs the acceptance body" || bad "T8 driver is missing a step"
grep -q 'sha256sum -c' "$BODY" && grep -q 'converge-check.sh' "$BODY" && ok "T8 the body verifies the checksum and asserts convergence" || bad "T8 body missing sha256sum -c / converge-check"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
