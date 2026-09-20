#!/usr/bin/env bash
# test-build-tarball.sh -- HIMMEL-3059 slice 1. Hermetic (no network, no VM):
# drives scripts/release/build-tarball.sh against a throwaway git fixture and
# asserts .github/workflows/release.yml would publish BOTH assets.
#
# Every behavioural assertion has a control that VARIES THE CAUSE:
#   - the checksum path is fed a matching pair (must pass) AND a tampered
#     tarball / a wrong hash (must fail) -- a matching pair alone proves nothing;
#   - "the tarball is build-complete" is checked against a --no-build tarball of
#     the same tree, which must NOT be;
#   - "the workflow uploads both assets" is checked against a mutated copy of
#     the workflow that drops the .sha256 upload, which must be rejected.
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom (pass/fail echo, always rc 0)
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/scripts/release/build-tarball.sh"
WORKFLOW="$ROOT/.github/workflows/release.yml"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $1"; }
bad() { fail=$((fail+1)); echo "FAIL  $1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
check() { # check <label> <command...> -- passes when the command exits 0
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi
}
check_not() { # check_not <label> <command...> -- passes when the command exits NON-zero
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$label (expected failure, got success)"; else ok "$label"; fi
}

# Fixture must not inherit an outer git context (a leg runs inside a worktree).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
tmp="$(mktemp -d "${TMPDIR:-/tmp}/himmel-buildtb-test.XXXXXX")" || { echo "cannot create a scratch dir" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# --- fixture: a tiny git repo shaped like himmel's build surface -------------
fx="$tmp/fx"
mkdir -p "$fx/scripts/jira" "$fx/scripts/fxdep" "$fx/scripts/lib"
echo "1.2.3" > "$fx/VERSION"
printf '#!/usr/bin/env bash\necho hello\n' > "$fx/scripts/lib/hello.sh"
cat > "$fx/scripts/jira/package.json" <<'EOF'
{
  "name": "fx-jira",
  "version": "0.0.0",
  "dependencies": { "fx-dep": "file:../fxdep" },
  "scripts": { "build": "mkdir -p dist && echo 'console.log(1)' > dist/index.js" }
}
EOF
# A real (offline, file:) runtime dependency, so `npm prune --omit=dev` leaves a
# node_modules/ behind -- a zero-dependency fixture would prune it away and make
# the "node_modules is in the tarball" assertion depend on a shim.
echo '{ "name": "fx-dep", "version": "0.0.0" }' > "$fx/scripts/fxdep/package.json"
printf 'dist/\nnode_modules/\n' > "$fx/.gitignore"
( cd "$fx/scripts/jira" && npm install --package-lock-only --silent ) >/dev/null 2>&1
git -C "$fx" init -q .
git -C "$fx" add -A
git -C "$fx" -c user.name=t -c user.email=t@e.co commit -q -m fixture
git -C "$fx" rev-parse HEAD >/dev/null 2>&1 || { echo "FAIL  fixture repo could not be created"; exit 1; }

export RELEASE_NODE_PKGS="scripts/jira"

# --- T1: a full build emits both assets, and the published-style check passes --
out="$tmp/out"
bash "$BUILD" --version 1.2.3 --src "$fx" --out "$out" >"$tmp/build.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "build exits 0" || bad "build exits 0" "rc=$rc: $(tail -3 "$tmp/build.log")"
tgz="$out/himmel-1.2.3-linux.tar.gz"
sum="$tgz.sha256"
check "emits himmel-<v>-linux.tar.gz"        test -s "$tgz"
check "emits himmel-<v>-linux.tar.gz.sha256" test -s "$sum"
check "asset paths are printed on stdout (both)" \
  bash -c "grep -Fq 'himmel-1.2.3-linux.tar.gz' '$tmp/build.log' && grep -Fq 'himmel-1.2.3-linux.tar.gz.sha256' '$tmp/build.log'"

# The .sha256 names the BARE filename, so the adopter's one-liner works in the download dir.
expect="$(cd "$out" && sha256sum himmel-1.2.3-linux.tar.gz)"
[ "$(cat "$sum")" = "$expect" ] && ok ".sha256 is exactly 'sha256sum <bare filename>'" || bad ".sha256 format" "got: $(cat "$sum")"
check "GREEN: matching pair verifies with the adopter one-liner" bash -c "cd '$out' && sha256sum -c himmel-1.2.3-linux.tar.gz.sha256"

# --- T2: RED controls -- the same one-liner must FAIL when the cause varies ---
bad_dir="$tmp/tampered"; mkdir -p "$bad_dir"
cp "$sum" "$bad_dir/"
# (a) flip one byte in the middle of the tarball, keep the published hash.
python3 - "$tgz" "$bad_dir/himmel-1.2.3-linux.tar.gz" <<'PY'
import sys
b = bytearray(open(sys.argv[1], 'rb').read())
b[len(b) // 2] ^= 0xFF
open(sys.argv[2], 'wb').write(b)
PY
check_not "RED: a tarball with one flipped byte FAILS sha256sum -c" \
  bash -c "cd '$bad_dir' && sha256sum -c himmel-1.2.3-linux.tar.gz.sha256"
# (b) intact tarball, but a hash for different bytes.
wrong_dir="$tmp/wronghash"; mkdir -p "$wrong_dir"
cp "$tgz" "$wrong_dir/"
printf '%s  himmel-1.2.3-linux.tar.gz\n' "$(printf 'not this file' | sha256sum | cut -d' ' -f1)" \
  > "$wrong_dir/himmel-1.2.3-linux.tar.gz.sha256"
check_not "RED: an intact tarball vs a wrong published hash FAILS sha256sum -c" \
  bash -c "cd '$wrong_dir' && sha256sum -c himmel-1.2.3-linux.tar.gz.sha256"
# (c) truncated download.
trunc_dir="$tmp/trunc"; mkdir -p "$trunc_dir"
cp "$sum" "$trunc_dir/"
head -c 100 "$tgz" > "$trunc_dir/himmel-1.2.3-linux.tar.gz"
check_not "RED: a truncated tarball FAILS sha256sum -c" \
  bash -c "cd '$trunc_dir' && sha256sum -c himmel-1.2.3-linux.tar.gz.sha256"
# (d) the README chain must STOP at a failed verify: a `&&` chain never reaches tar.
check_not "RED: verify-then-extract chain stops before tar on a bad hash" \
  bash -c "cd '$bad_dir' && sha256sum -c himmel-1.2.3-linux.tar.gz.sha256 && tar -xzf himmel-1.2.3-linux.tar.gz -C '$bad_dir'"
[ ! -e "$bad_dir/himmel-1.2.3" ] && ok "RED: nothing was extracted after the failed verify" || bad "extraction happened after a failed verify"

# --- T3: content -- pre-built, tracked-only, single top-level dir ------------
list="$tmp/list.txt"
tar -tzf "$tgz" > "$list"
check "tree sits under one top-level himmel-<v>/ dir" bash -c "! grep -v '^himmel-1.2.3/' '$list' | grep -q ."  # pipefail-ok: the child bash -c does not set pipefail, and the listing is a few KiB
check "carries the tracked tree (VERSION, scripts/lib/hello.sh)" \
  bash -c "grep -Fxq 'himmel-1.2.3/VERSION' '$list' && grep -Fxq 'himmel-1.2.3/scripts/lib/hello.sh' '$list'"
check "GREEN: build-complete -- scripts/jira/dist/index.js is IN the tarball" grep -Fxq 'himmel-1.2.3/scripts/jira/dist/index.js' "$list"
check "GREEN: build-complete -- scripts/jira/node_modules/ is IN the tarball" grep -Eq '^himmel-1.2.3/scripts/jira/node_modules/?$' "$list"
check_not "no .git directory in the tarball" grep -Eq '(^|/)\.git(/|$)' "$list"

# RED control for "build-complete": the same tree built with --no-build must LACK dist/.
bash "$BUILD" --version 1.2.3 --src "$fx" --out "$tmp/out-nobuild" --no-build >/dev/null 2>&1 \
  && tar -tzf "$tmp/out-nobuild/himmel-1.2.3-linux.tar.gz" > "$tmp/list-nobuild.txt" 2>/dev/null
# The absence assertion below is only meaningful against a control that really built.
check "the --no-build control built and lists the tracked tree" grep -Fxq 'himmel-1.2.3/VERSION' "$tmp/list-nobuild.txt"
check_not "RED: a --no-build tarball does NOT contain scripts/jira/dist/index.js" \
  grep -Fxq 'himmel-1.2.3/scripts/jira/dist/index.js' "$tmp/list-nobuild.txt"

# --- T4: tracked-only -- a dirty working tree cannot leak into the artifact ---
echo "SECRET=1" > "$fx/leak.env"                      # untracked
echo "tampered" > "$fx/VERSION"                        # modified, uncommitted
bash "$BUILD" --version 1.2.4 --src "$fx" --out "$tmp/out-dirty" >/dev/null 2>&1 \
  && tar -tzf "$tmp/out-dirty/himmel-1.2.4-linux.tar.gz" > "$tmp/list-dirty.txt" 2>/dev/null
check "the dirty-tree build succeeded and lists the tracked tree" grep -Fxq 'himmel-1.2.4/VERSION' "$tmp/list-dirty.txt"
check_not "untracked file is NOT packaged" grep -Fq 'leak.env' "$tmp/list-dirty.txt"
[ "$(tar -xzOf "$tmp/out-dirty/himmel-1.2.4-linux.tar.gz" himmel-1.2.4/VERSION)" = "1.2.3" ] \
  && ok "packages the COMMITTED VERSION, not the dirty working copy" || bad "dirty working copy leaked into the tarball"
git -C "$fx" checkout -q -- VERSION; rm -f "$fx/leak.env"

# --- T5: argument / failure handling -----------------------------------------
check_not "path-traversal version is rejected"  bash "$BUILD" --version ../evil --src "$fx" --out "$tmp/o1"
check_not "empty invocation (no --version) is rejected" bash "$BUILD" --src "$fx" --out "$tmp/o2"
[ ! -e "$tmp/o1/himmel-../evil-linux.tar.gz" ] && ok "rejected version wrote no asset" || bad "rejected version still wrote an asset"
check_not "non-git --src is rejected" bash "$BUILD" --version 1.2.3 --src "$tmp" --out "$tmp/o3"
check_not "a missing RELEASE_NODE_PKGS package fails the build (no silent skip)" \
  env RELEASE_NODE_PKGS="scripts/jira scripts/nope" bash "$BUILD" --version 1.2.3 --src "$fx" --out "$tmp/o4"

# --- T6: the workflow publishes BOTH assets, on a tag, and verifies them -----
# workflow_ok <file> -- 0 iff the release workflow is tag-triggered, runs the
# builder, uploads BOTH assets and verifies the published pair.
workflow_ok() {
  local f="$1" step
  grep -Eq "^[[:space:]]+tags:[[:space:]]*\[[[:space:]]*'v\*'[[:space:]]*\]" "$f" || return 1
  grep -Fq 'scripts/release/build-tarball.sh' "$f" || return 1
  step="$(awk '/- name: Upload both assets/{on=1;next} on&&/- name:/{on=0} on' "$f")"
  grep -Fq 'gh release upload' <<< "$step" || return 1
  grep -Fq -- '-linux.tar.gz"' <<< "$step" || return 1
  grep -Fq -- '-linux.tar.gz.sha256"' <<< "$step" || return 1
  grep -Fq 'sha256sum -c' "$f" || return 1
  return 0
}
check "workflow: tag-triggered, builds, uploads BOTH assets, verifies" workflow_ok "$WORKFLOW"
check "workflow: contents:write is scoped to the job, top level stays read" \
  bash -c "awk '/^permissions:/{getline; print; exit}' '$WORKFLOW' | grep -Fq 'contents: read' && awk '/^    permissions:/{getline; print; exit}' '$WORKFLOW' | grep -Fq 'contents: write'"  # pipefail-ok: the child bash -c does not set pipefail; awk prints one line and exits
check_not "workflow: does not run on pull_request" grep -Eq '^[[:space:]]*pull_request:' "$WORKFLOW"
# shellcheck disable=SC2016  # the single quotes are deliberate: a literal ${{ to grep for
check_not "workflow: no \${{ secrets.* }} interpolation (check-no-secrets rail)" grep -Fq '${{ secrets.' "$WORKFLOW"

# RED controls -- mutate the workflow so the cause varies.
mut="$tmp/mut"; mkdir -p "$mut"
grep -v -- '-linux.tar.gz.sha256"' "$WORKFLOW" > "$mut/no-sha-upload.yml"
check_not "RED: a workflow that uploads only the tarball (no .sha256) is rejected" workflow_ok "$mut/no-sha-upload.yml"
grep -v -- 'gh release upload' "$WORKFLOW" > "$mut/no-upload.yml"
check_not "RED: a workflow with no upload step is rejected" workflow_ok "$mut/no-upload.yml"
sed "s/tags: \['v\*'\]/branches: [main]/" "$WORKFLOW" > "$mut/branch-trigger.yml"
check_not "RED: a workflow triggered on a branch instead of a tag is rejected" workflow_ok "$mut/branch-trigger.yml"
grep -v 'sha256sum -c' "$WORKFLOW" > "$mut/no-verify.yml"
check_not "RED: a workflow that never verifies the published pair is rejected" workflow_ok "$mut/no-verify.yml"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
