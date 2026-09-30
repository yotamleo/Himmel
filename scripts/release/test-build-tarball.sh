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
# A missing/failing python3 leaves no copy, and "sha256sum -c fails" would then be a
# MISSING FILE, not a hash mismatch -- require a real, different, same-size copy first.
check "the flipped-byte copy exists, differs and keeps its size" \
  bash -c "[ -s '$bad_dir/himmel-1.2.3-linux.tar.gz' ] && ! cmp -s '$tgz' '$bad_dir/himmel-1.2.3-linux.tar.gz' && [ \"\$(stat -c %s '$tgz' 2>/dev/null || stat -f %z '$tgz')\" = \"\$(stat -c %s '$bad_dir/himmel-1.2.3-linux.tar.gz' 2>/dev/null || stat -f %z '$bad_dir/himmel-1.2.3-linux.tar.gz')\" ]"
check_not "RED: a tarball with one flipped byte FAILS sha256sum -c" \
  bash -c "cd '$bad_dir' && sha256sum -c himmel-1.2.3-linux.tar.gz.sha256"
# (b) intact tarball, but a hash for different bytes.
wrong_dir="$tmp/wronghash"; mkdir -p "$wrong_dir"
cp "$tgz" "$wrong_dir/"
printf '%s  himmel-1.2.3-linux.tar.gz\n' "$(printf 'not this file' | sha256sum | cut -d' ' -f1)" \
  > "$wrong_dir/himmel-1.2.3-linux.tar.gz.sha256"
check "the wrong-hash case holds the intact tarball" cmp -s "$tgz" "$wrong_dir/himmel-1.2.3-linux.tar.gz"
check_not "RED: an intact tarball vs a wrong published hash FAILS sha256sum -c" \
  bash -c "cd '$wrong_dir' && sha256sum -c himmel-1.2.3-linux.tar.gz.sha256"
# (c) truncated download.
trunc_dir="$tmp/trunc"; mkdir -p "$trunc_dir"
cp "$sum" "$trunc_dir/"
head -c 100 "$tgz" > "$trunc_dir/himmel-1.2.3-linux.tar.gz"
check "the truncated copy exists and differs from the original" \
  bash -c "[ -s '$trunc_dir/himmel-1.2.3-linux.tar.gz' ] && ! cmp -s '$tgz' '$trunc_dir/himmel-1.2.3-linux.tar.gz'"
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

# --- T7: HIMMEL-3059 S2 -- the release attests build provenance --------------
# attest_ok <file> -- 0 iff the job attests the built tarball, holds the two
# extra OIDC/attestation permissions, and verifies its own attestation.
attest_ok() {
  local f="$1" jobperms
  grep -Fq 'actions/attest-build-provenance@v4' "$f" || return 1
  jobperms="$(awk '/^    permissions:/{p=1;next} p&&/^    [a-z]/{next} p&&/^      /{print;next} p{exit}' "$f")"
  grep -Fq 'id-token: write' <<< "$jobperms" || return 1
  grep -Fq 'attestations: write' <<< "$jobperms" || return 1
  grep -Fq 'gh attestation verify' "$f" || return 1
  return 0
}
check "workflow: attests build provenance, scoped permissions, verifies itself" attest_ok "$WORKFLOW"

# RED controls -- mutate the workflow so the cause varies.
grep -v 'actions/attest-build-provenance' "$WORKFLOW" > "$mut/no-attest.yml"
check_not "RED: a workflow with no attest step is rejected" attest_ok "$mut/no-attest.yml"
grep -v 'id-token: write' "$WORKFLOW" > "$mut/no-id-token.yml"
check_not "RED: a workflow missing id-token: write is rejected" attest_ok "$mut/no-id-token.yml"
grep -v 'attestations: write' "$WORKFLOW" > "$mut/no-attestations-perm.yml"
check_not "RED: a workflow missing attestations: write is rejected" attest_ok "$mut/no-attestations-perm.yml"
grep -v 'gh attestation verify' "$WORKFLOW" > "$mut/no-attest-verify.yml"
check_not "RED: a workflow that never verifies its attestation is rejected" attest_ok "$mut/no-attest-verify.yml"
# the two extra permissions must land on the JOB, not just anywhere in the file.
sed '/^      id-token: write/d; /^      attestations: write/d; /^permissions:/a\
id-token: write\
attestations: write' "$WORKFLOW" > "$mut/toplevel-perms.yml"
check_not "RED: id-token/attestations at the top level (not the job) is rejected" attest_ok "$mut/toplevel-perms.yml"

# --- T8: HIMMEL-3920 -- release notes are the curated file, or bounded generated ---
# notes_ok <file> -- 0 iff "Ensure the release exists" (a) skips when the release
# exists, (b) validates the tag shape BEFORE building the notes path, (c) uses the
# curated docs/release/<TAG>-notes.md via --notes-file, (d) bounds generated notes
# with --notes-start-tag, and (e) never runs a bare --generate-notes as the only path
# when a predecessor exists.
# shellcheck disable=SC2016  # the single quotes are deliberate: literal $VAR text to grep for in the workflow
notes_ok() {
  local f="$1" step
  step="$(awk '/- name: Ensure the release exists/{on=1;next} on&&/- name:/{on=0} on' "$f")"
  [ -n "$step" ] || return 1
  grep -Fq 'gh release view "$TAG"' <<< "$step" || return 1
  grep -Fq 'already exists' <<< "$step" || return 1
  grep -Fq -- '--notes-file "$notes"' <<< "$step" || return 1
  grep -Fq 'notes="docs/release/${TAG}-notes.md"' <<< "$step" || return 1
  grep -Fq -- '--notes-start-tag "$prev"' <<< "$step" || return 1
  # the tag-shape gate must come BEFORE the path is built from the tag
  local gate_line path_line
  gate_line="$(grep -n "grep -Eq '\^v\[0-9\]" <<< "$step" | head -1 | cut -d: -f1)"
  path_line="$(grep -n 'notes="docs/release/' <<< "$step" | head -1 | cut -d: -f1)"
  [ -n "$gate_line" ] && [ -n "$path_line" ] && [ "$gate_line" -lt "$path_line" ] || return 1
  # no ${{ }} expansion inside the run: block (env: only)
  ! grep -Fq '${{' <<< "$step" || return 1
  return 0
}
check "workflow: curated notes file, bounded generated notes, tag-shape gate" notes_ok "$WORKFLOW"

# RED: the pre-HIMMEL-3920 step (bare --generate-notes) must be rejected.
cat > "$mut/old-step.yml" <<'EOF'
      - name: Ensure the release exists
        run: |
          flags=()
          case "$TAG" in *-*) flags+=(--prerelease) ;; esac
          gh release view "$TAG" >/dev/null 2>&1 \
            || gh release create "$TAG" --verify-tag --title "$TAG" --generate-notes "${flags[@]}"

      - name: Upload both assets
EOF
check_not "RED: the old bare --generate-notes step is rejected" notes_ok "$mut/old-step.yml"
grep -v -- '--notes-file' "$WORKFLOW" > "$mut/no-notes-file.yml"
check_not "RED: a step with no --notes-file path is rejected" notes_ok "$mut/no-notes-file.yml"
grep -v -- '--notes-start-tag' "$WORKFLOW" > "$mut/no-start-tag.yml"
check_not "RED: a step whose generated notes are not bounded is rejected" notes_ok "$mut/no-start-tag.yml"
grep -v 'already exists' "$WORKFLOW" > "$mut/no-skip.yml"
check_not "RED: a step that lost the release-exists skip is rejected" notes_ok "$mut/no-skip.yml"
grep -v "grep -Eq '^v\[0-9\]" "$WORKFLOW" > "$mut/no-tag-gate.yml"
check_not "RED: a step with no tag-shape gate before the notes path is rejected" notes_ok "$mut/no-tag-gate.yml"

# Behavioural half (HIMMEL-3920 CR round 1): EXECUTE the step's shell with stubbed
# gh/git, so control flow -- not just token presence -- is asserted.
# run_notes_step <workflow> <tag> <have-notes:0|1> <exists:0|1> <tags-newline-list> -- prints the
# `gh release create` argv the step issued (empty when it issued none); rc = the step's rc.
run_notes_step() {
  local wf="$1" tag="$2" have_notes="$3" exists="$4" tags="$5" d
  d="$(mktemp -d "$tmp/step.XXXXXX")"
  mkdir -p "$d/bin" "$d/docs/release"
  awk '/- name: Ensure the release exists/{on=1;next} on&&/^ +run: \|/{r=1;next} on&&/- name:/{exit} on&&r{sub(/^          /,"");print}' "$wf" > "$d/step.sh"
  [ "$have_notes" = 1 ] && echo "notes" > "$d/docs/release/${tag}-notes.md"
  cat > "$d/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "release view" ]; then exit "${STUB_VIEW_RC:-1}"; fi
if [ "$1 $2" = "release create" ]; then echo "$*" >> "$STUB_LOG"; exit 0; fi
exit 0
EOF
  cat > "$d/bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" tag "*) printf '%s\n' "$STUB_TAGS" ;; *) : ;; esac
EOF
  chmod +x "$d/bin/gh" "$d/bin/git"
  ( cd "$d" && TAG="$tag" STUB_LOG="$d/log" STUB_VIEW_RC="$([ "$exists" = 1 ] && echo 0 || echo 1)" \
      STUB_TAGS="$tags" PATH="$d/bin:$PATH" bash -e -o pipefail step.sh >/dev/null 2>&1 )
  local rc=$?
  [ -f "$d/log" ] && cat "$d/log"
  return "$rc"
}
tags_list=$'v1.0.0\nv1.0.0-pre.1\nv0.9.0'
out="$(run_notes_step "$WORKFLOW" v1.0.0 1 0 "$tags_list")"
[[ "$out" == *"--notes-file docs/release/v1.0.0-notes.md"* && "$out" != *"--generate-notes"* ]] \
  && ok "step: curated notes file present -> --notes-file, never --generate-notes" || bad "step: notes-file branch" "got: $out"
out="$(run_notes_step "$WORKFLOW" v1.0.0 0 0 "$tags_list")"
[[ "$out" == *"--generate-notes --notes-start-tag v1.0.0-pre.1"* ]] \
  && ok "step: no notes file -> generated notes bounded to the previous tag" || bad "step: bounded branch" "got: $out"
out="$(run_notes_step "$WORKFLOW" v0.9.0 0 0 "$tags_list")"
[[ "$out" == *"--generate-notes"* && "$out" != *"--notes-start-tag"* ]] \
  && ok "step: first tag (no predecessor) -> generated notes, no start tag" || bad "step: first-tag branch" "got: $out"
out="$(run_notes_step "$WORKFLOW" v1.0.0 1 1 "$tags_list")"
[ -z "$out" ] && ok "step: release already exists -> no create" || bad "step: exists skip" "got: $out"
if run_notes_step "$WORKFLOW" 'v1/../x' 1 0 "$tags_list" >/dev/null; then bad "step: malformed tag accepted"; else ok "step: a malformed tag is refused"; fi
# RED controls: mutants that keep every token but break the flow must fail these rows.
sed '/skipping create/{n;s/exit 0/true/}' "$WORKFLOW" > "$mut/no-exit.yml"
out="$(run_notes_step "$mut/no-exit.yml" v1.0.0 1 1 "$tags_list")"
[ -n "$out" ] && ok "RED: dropping the exists-skip 'exit 0' is caught (create still issued)" || bad "RED: no-exit mutant not caught"
# shellcheck disable=SC2016  # literal $notes in the sed pattern
sed 's/^\( *\)if \[ -s "\$notes" \]; then/\1if false; then/'"$WORKFLOW" > "$mut/no-notes-branch.yml"
out="$(run_notes_step "$mut/no-notes-branch.yml" v1.0.0 1 0 "$tags_list")"
[[ "$out" != *"--notes-file"* ]] && ok "RED: a dead notes-file branch is caught" || bad "RED: dead-notes mutant not caught"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
