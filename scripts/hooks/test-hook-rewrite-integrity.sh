#!/usr/bin/env bash
# E2E coverage for the HIMMEL-1666 rewrite-vector fix: a dispatched worker with
# Edit(<worktree>) can rewrite a project-local guard's ON-DISK content (not
# just delete it — the vector HIMMEL-1649 already closed). This proves
# run-hook-with-bash.js denies the tampered file instead of running it, once
# record-hook-integrity.sh has pinned the worktree at SessionStart — the
# worker-shaped session HIMMEL-1666 asks for.
#
# HIMMEL-2528 extends it with the RE-PIN path: a mismatch is no longer always
# tampering — a worktree brought up to date holds hook bytes the session-start
# pin never saw. Rows 1-28 below drive scripts/hooks/hook-integrity.js's
# three-check verification (tip / monotonic anchor / pinned blob on the anchor
# line), its record locking, and its fail-closed persistence, against real git
# fixtures with a real `origin` remote. The v2 records these rows use are built
# HERE with jq rather than by record-hook-integrity.sh, so the launcher's
# behaviour is under test independently of the recorder; only row 15 (the
# bootstrap exception) drives the real recorder.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
RECORDER="$HOOKS_DIR/record-hook-integrity.sh"
LAUNCHER="$HOOKS_DIR/run-hook-with-bash.js"
PLUGIN_LAUNCHER="$REPO_ROOT/marketplace/plugins/himmel-ops/hooks/run-hook-with-bash.js"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 0; }

T="$(mktemp -d "${TMPDIR:-/tmp}/himmel-hook-rewrite-integrity.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PROJECT="$T/project"
OUT_DIR="$T/out"
mkdir -p "$PROJECT/scripts/hooks"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

GUARD="$PROJECT/scripts/hooks/fake-guard.sh"
cat > "$GUARD" <<'GUARD_EOF'
#!/usr/bin/env bash
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
exit 0
GUARD_EOF
chmod +x "$GUARD"
git -C "$PROJECT" init -q
git -C "$PROJECT" -c user.email=t@t -c user.name=t add -A
git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -q -m init

PAYLOAD='{"session_id":"worker-session-1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf harmless"}}'

# SessionStart pin, as it would happen before the worker's first tool call.
printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$OUT_DIR" bash "$RECORDER" >/dev/null

run_launcher() {
  printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$OUT_DIR" \
    node "$LAUNCHER" --optional "$GUARD"
}

run_launcher >"$T/before.out" 2>"$T/before.err"
rc_before=$?
if [ "$rc_before" -eq 0 ] && grep -q 'permissionDecision' "$T/before.out"; then
  ok "unmodified guard runs normally before any tampering"
else
  bad "unmodified guard: rc=$rc_before out=$(cat "$T/before.out") err=$(cat "$T/before.err")"
fi

# The rewrite vector: a worker with Edit(<worktree>) overwrites the guard's
# content in place (not a delete — HIMMEL-1649 already covers that) to always
# allow.
cat > "$GUARD" <<'TAMPER_EOF'
#!/usr/bin/env bash
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
exit 0
# tampered: this guard used to deny; now it never does.
TAMPER_EOF

run_launcher >"$T/after.out" 2>"$T/after.err"
rc_after=$?
if [ "$rc_after" -eq 2 ] && grep -qi 'DENY' "$T/after.err"; then
  ok "tampered guard is denied at the launcher, before its content ever runs"
else
  bad "tampered guard: expected rc=2 with a DENY message, got rc=$rc_after err=$(cat "$T/after.err")"
fi

# The documented single-run bypass still lets a legitimate mid-session edit
# through.
BYPASS_OUT="$T/bypass.out"
BYPASS_ERR="$T/bypass.err"
printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$OUT_DIR" HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 \
  node "$LAUNCHER" --optional "$GUARD" >"$BYPASS_OUT" 2>"$BYPASS_ERR"
rc_bypass=$?
if [ "$rc_bypass" -eq 0 ]; then
  ok "HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 lets the tampered guard run"
else
  bad "bypass: expected rc=0, got rc=$rc_bypass err=$(cat "$BYPASS_ERR")"
fi

# A session with no pin file at all (e.g. record-hook-integrity.sh never ran,
# or predates this checkout) must not regress to blocking every tool call.
printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$T/no-such-dir" \
  node "$LAUNCHER" --optional "$GUARD" >"$T/nopins.out" 2>"$T/nopins.err"
rc_nopins=$?
if [ "$rc_nopins" -eq 0 ]; then
  ok "no pin file for the session fails open (no blast radius on unpinned sessions)"
else
  bad "no pin file: expected rc=0 (fail open), got rc=$rc_nopins err=$(cat "$T/nopins.err")"
fi

# ===========================================================================
# HIMMEL-2528 — re-pin on a legitimately advanced checkout
# ===========================================================================

REL='scripts/hooks/g.sh'
REL2='scripts/hooks/sibling.sh'

# --- fixture helpers -------------------------------------------------------
# Each fixture is a real project repo with a real `origin` remote (a second,
# bare repo), so refs/remotes/origin/<branch> is a genuine remote-tracking ref
# rather than a hand-written one.
fixture() {   # <name> [branch]
  FX="$T/$1"
  FX_PROJ="$FX/project"
  FX_OUT="$FX/out"
  FX_BR="${2:-main}"
  FX_REF="refs/remotes/origin/$FX_BR"
  mkdir -p "$FX_PROJ/scripts/hooks" "$FX_OUT"
  git -C "$FX_PROJ" init -q -b "$FX_BR"
  git -C "$FX_PROJ" config user.email t@t
  git -C "$FX_PROJ" config user.name t
  git init -q --bare -b "$FX_BR" "$FX/origin.git"
  git -C "$FX_PROJ" remote add origin "$FX/origin.git"
  FX_GIT="$(git -C "$FX_PROJ" rev-parse --absolute-git-dir)"
}

guard_write() {   # <path> <marker>
  printf '#!/usr/bin/env bash\nexit 0\n# %s\n' "$2" > "$1"
  chmod +x "$1"
}

fx_commit() {   # <marker> <msg> -> prints the new commit sha
  guard_write "$FX_PROJ/$REL" "$1"
  git -C "$FX_PROJ" add -A
  git -C "$FX_PROJ" commit -q -m "$2"
  git -C "$FX_PROJ" rev-parse HEAD
}

fx_publish() {   # <committish> — advance (or rewind) origin, then refresh the tracking ref
  git -C "$FX_PROJ" push -q -f origin "$1:refs/heads/$FX_BR"
  git -C "$FX_PROJ" fetch -q --force origin
}

fx_blob() { git -C "$FX_PROJ" hash-object "$FX_PROJ/${1:-$REL}"; }

# write_record <outdir> <sid> <anchor|-> <ref|-> <gitdir|-> <rel> <blob> [<rel> <blob> ...]
# A "-" for anchor/ref/gitdir omits that field, producing a LEGACY record.
write_record() {
  local dir="$1" sid="$2" anchor="$3" ref="$4" gd="$5"
  shift 5
  local pins='{}'
  while [ "$#" -ge 2 ]; do
    pins="$(printf '%s' "$pins" | jq --arg k "$1" --arg v "$2" '. + {($k): $v}')"
    shift 2
  done
  mkdir -p "$dir"
  local out="$dir/$sid.json"
  chmod 600 "$out" 2>/dev/null || true
  jq -n --arg sid "$sid" --argjson pins "$pins" \
        --arg anchor "$anchor" --arg ref "$ref" --arg gd "$gd" \
    '{session_id:$sid, recorded_at:"2026-09-05T00:00:00Z", pins:$pins}
     + (if $ref    == "-" then {} else {anchor_ref:$ref} end)
     + (if $anchor == "-" then {} else {anchor:$anchor}  end)
     + (if $gd     == "-" then {} else {git_dir:$gd}     end)' > "$out"
  # Mode 0400 is what record-hook-integrity.sh publishes, so the re-pin's
  # chmod/rename dance is exercised for real.
  chmod 400 "$out"
}

record_pin()    { jq -r --arg k "$2" '.pins[$k] // ""' "$1"; }
record_anchor() { jq -r '.anchor // ""' "$1"; }

LAST_RC=0
# launch <projectdir> <recorddir> <session> <launcher> <args...>
launch() {
  local proj="$1" rec="$2" sid="$3" launcher="$4"
  shift 4
  printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf harmless"}}' "$sid" \
    | CLAUDE_PROJECT_DIR="$proj" HIMMEL_HOOK_INTEGRITY_DIR="$rec" \
      node "$launcher" "$@" >"$T/last.out" 2>"$T/last.err"
  LAST_RC=$?
}

expect_allow() {   # <label>
  if [ "$LAST_RC" -eq 0 ] && ! grep -q 'DENY' "$T/last.err"; then
    ok "$1"
  else
    bad "$1 — expected allow, got rc=$LAST_RC err=$(cat "$T/last.err")"
  fi
}

expect_deny() {   # <label> [reason substring]
  if [ "$LAST_RC" -ne 2 ] || ! grep -q 'DENY' "$T/last.err"; then
    bad "$1 — expected rc=2 + DENY, got rc=$LAST_RC err=$(cat "$T/last.err")"
    return
  fi
  if [ "$#" -ge 2 ] && ! grep -qF "$2" "$T/last.err"; then
    bad "$1 — DENY did not name '$2': $(cat "$T/last.err")"
    return
  fi
  ok "$1"
}

expect_pin() {   # <recordfile> <rel> <blob> <label>
  local got; got="$(record_pin "$1" "$2")"
  if [ "$got" = "$3" ]; then ok "$4"; else bad "$4 — pin is '$got', expected '$3'"; fi
}

expect_anchor() {   # <recordfile> <sha> <label>
  local got; got="$(record_anchor "$1")"
  if [ "$got" = "$2" ]; then ok "$3"; else bad "$3 — anchor is '$got', expected '$2'"; fi
}

# --- rows 1-3: advance, refuse garbage, refuse a rollback ------------------
fixture r1
A1="$(fx_commit A c1)"; fx_publish "$A1"; BLOB_A1="$(fx_blob)"
B1="$(fx_commit B c2)"; fx_publish "$B1"; BLOB_B1="$(fx_blob)"
R1="$FX_OUT/s1.json"
write_record "$FX_OUT" s1 "$A1" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A1"
launch "$FX_PROJ" "$FX_OUT" s1 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 1: a behind pin whose disk bytes are the anchor tip is allowed"
expect_pin "$R1" "$REL" "$BLOB_B1" "row 1: the pin was advanced on disk"
expect_anchor "$R1" "$B1" "row 1: the anchor was advanced on disk"

printf 'not a hook at all\n' > "$FX_PROJ/$REL"
write_record "$FX_OUT" s2 "$A1" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A1"
launch "$FX_PROJ" "$FX_OUT" s2 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 2: arbitrary on-disk bytes are denied" 'not the anchor tip'

guard_write "$FX_PROJ/$REL" A
launch "$FX_PROJ" "$FX_OUT" s1 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 3: after the advancement, the OLD content is denied" 'not the anchor tip'

# --- rows 4-5: the anchor line is monotonic --------------------------------
fixture r4
A4="$(fx_commit A c1)"; fx_publish "$A4"
B4="$(fx_commit B c2)"; fx_publish "$B4"; BLOB_B4="$(fx_blob)"
fx_publish "$A4"                      # origin force-rewound to an ancestor
guard_write "$FX_PROJ/$REL" A         # disk matches the rewound tip, so (a) passes
write_record "$FX_OUT" s4 "$B4" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_B4"
launch "$FX_PROJ" "$FX_OUT" s4 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 4: an origin rewound below the anchor is denied" 'anchor rewind'

fixture r5
A5="$(fx_commit A c1)"; fx_publish "$A5"
B5="$(fx_commit B c2)"; fx_publish "$B5"
C5="$(fx_commit C c3)"; fx_publish "$C5"; BLOB_C5="$(fx_blob)"
fx_publish "$B5"
guard_write "$FX_PROJ/$REL" B
write_record "$FX_OUT" s5 "$C5" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_C5"
launch "$FX_PROJ" "$FX_OUT" s5 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 5: A-B-C then a rewind to B is denied" 'anchor rewind'

# --- row 6: a plainly behind pin -------------------------------------------
fixture r6
fx_commit X c0 >/dev/null; fx_publish HEAD
A6="$(fx_commit A c1)"; fx_publish "$A6"; BLOB_A6="$(fx_blob)"
B6="$(fx_commit B c2)"; fx_publish "$B6"; BLOB_B6="$(fx_blob)"
R6="$FX_OUT/s6.json"
write_record "$FX_OUT" s6 "$A6" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A6"
launch "$FX_PROJ" "$FX_OUT" s6 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 6: a feature-behind pin on a linear history is allowed"
expect_pin "$R6" "$REL" "$BLOB_B6" "row 6: the behind pin was advanced"

# --- row 7: behind pin under a --no-ff merge TREESAME to the feature parent -
# This is the shape --full-history exists for: default history simplification
# follows only the TREESAME parent (the feature side) and prunes the main-line
# parent that actually introduced the pinned blob.
fixture r7
C07="$(fx_commit X c0)"; fx_publish "$C07"
C17="$(fx_commit A c1)"; BLOB_A7="$(fx_blob)"
git -C "$FX_PROJ" checkout -q -b feat "$C07"
guard_write "$FX_PROJ/$REL" B
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m f1
git -C "$FX_PROJ" checkout -q "$FX_BR"
git -C "$FX_PROJ" merge -q --no-ff -X theirs feat -m 'merge feat' >/dev/null 2>&1
M7="$(git -C "$FX_PROJ" rev-parse HEAD)"
fx_publish "$M7"
BLOB_B7="$(fx_blob)"
R7="$FX_OUT/s7.json"
write_record "$FX_OUT" s7 "$C17" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A7"
launch "$FX_PROJ" "$FX_OUT" s7 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 7: a behind pin under a --no-ff TREESAME merge is allowed"
expect_pin "$R7" "$REL" "$BLOB_B7" "row 7: the pin was advanced across the merge"

# --- rows 8-9: an AHEAD pin never advances ---------------------------------
# Row 8 is the local/unmerged EDIT: origin moved on without touching the hook,
# so the on-disk bytes are not the tip's bytes — check (a) refuses.
fixture r8
A8="$(fx_commit A c1)"; fx_publish "$A8"; BLOB_A8="$(fx_blob)"
printf 'unrelated\n' > "$FX_PROJ/other.txt"
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m d1
D8="$(git -C "$FX_PROJ" rev-parse HEAD)"; fx_publish "$D8"
guard_write "$FX_PROJ/$REL" F
R8="$FX_OUT/s8.json"
write_record "$FX_OUT" s8 "$A8" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A8"
launch "$FX_PROJ" "$FX_OUT" s8 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 8: an unmerged change F on this branch is denied" 'not the anchor tip'
expect_pin "$R8" "$REL" "$BLOB_A8" "row 8: the record is unchanged after the deny"
expect_anchor "$R8" "$A8" "row 8: the anchor is unchanged after the deny"

# Row 9 is the AHEAD pin proper: the session pinned an unmerged blob F, and the
# checkout is then rolled back to the tip's bytes. (a) and (b) both pass; only
# (c) — the pinned blob is nowhere in the anchor line — refuses.
fixture r9
A9="$(fx_commit A c1)"; fx_publish "$A9"
git -C "$FX_PROJ" checkout -q -b feat
guard_write "$FX_PROJ/$REL" F
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m f1
BLOB_F9="$(fx_blob)"
git -C "$FX_PROJ" checkout -q "$FX_BR"
printf 'unrelated\n' > "$FX_PROJ/other.txt"
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m d1
D9="$(git -C "$FX_PROJ" rev-parse HEAD)"; fx_publish "$D9"
guard_write "$FX_PROJ/$REL" A
R9="$FX_OUT/s9.json"
write_record "$FX_OUT" s9 "$A9" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_F9"
launch "$FX_PROJ" "$FX_OUT" s9 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 9: an ahead pin restored to older bytes is denied" 'pinned blob is not on the anchor line'
expect_pin "$R9" "$REL" "$BLOB_F9" "row 9: the ahead pin is not advanced"

# --- row 10: refs/replace must not be able to forge the tip ----------------
fixture r10
guard_write "$FX_PROJ/$REL" A
printf 'x\n' > "$FX_PROJ/other.txt"
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m c0
printf 'y\n' > "$FX_PROJ/other.txt"
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m c1
C110="$(git -C "$FX_PROJ" rev-parse HEAD)"; fx_publish "$C110"
BLOB_A10="$(fx_blob)"
TREE10="$(git -C "$FX_PROJ" rev-parse "$C110^{tree}")"
git -C "$FX_PROJ" checkout -q -b tamper
guard_write "$FX_PROJ/$REL" TAMPERED
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m ct
TREE10T="$(git -C "$FX_PROJ" rev-parse "HEAD^{tree}")"
BLOB_T10="$(fx_blob)"
git -C "$FX_PROJ" checkout -q "$FX_BR"
guard_write "$FX_PROJ/$REL" TAMPERED     # the tampered bytes on disk
git -C "$FX_PROJ" replace "$TREE10" "$TREE10T"
# Positive control: without the env var, git resolves the FORGED tree, so all
# three checks would pass and the tampered file would be allowed.
forged="$(cd /tmp && git --git-dir="$FX_GIT" rev-parse --verify --quiet "$C110:$REL")"
fenced="$(cd /tmp && GIT_NO_REPLACE_OBJECTS=1 git --git-dir="$FX_GIT" rev-parse --verify --quiet "$C110:$REL")"
if [ "$forged" = "$BLOB_T10" ] && [ "$fenced" = "$BLOB_A10" ]; then
  ok "row 10: control — refs/replace really would forge the tip without the fence"
else
  bad "row 10: control — replace fixture is not exercising the fence (forged=$forged fenced=$fenced)"
fi
write_record "$FX_OUT" s10 "$C110" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A10"
launch "$FX_PROJ" "$FX_OUT" s10 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 10: a refs/replace-forged tip is denied (GIT_NO_REPLACE_OBJECTS=1)" 'not the anchor tip'

# --- row 11: the record's git_dir wins over the project's .git pointer -----
# A worktree's .git is a one-line pointer FILE, writable by the same Edit grant
# this whole check exists to survive. Verification must never follow it.
R11D="$T/r11"
mkdir -p "$R11D/real/scripts/hooks" "$R11D/project/scripts/hooks" "$R11D/out"
git -C "$R11D/real" init -q -b main
git -C "$R11D/real" config user.email t@t
git -C "$R11D/real" config user.name t
guard_write "$R11D/real/$REL" A
git -C "$R11D/real" add -A
git -C "$R11D/real" commit -q -m c1
A11="$(git -C "$R11D/real" rev-parse HEAD)"
BLOB_A11="$(git -C "$R11D/real" hash-object "$R11D/real/$REL")"
git -C "$R11D/real" update-ref refs/remotes/origin/main "$A11"
REAL_GIT="$(git -C "$R11D/real" rev-parse --absolute-git-dir)"
# The decoy: a clone whose origin/main tip DOES contain the tampered blob, with
# the real anchor as an ancestor — i.e. a repo that would satisfy all three
# checks if verification followed the pointer file.
git clone -q "$R11D/real" "$R11D/decoy"
git -C "$R11D/decoy" config user.email t@t
git -C "$R11D/decoy" config user.name t
guard_write "$R11D/decoy/$REL" TAMPERED
git -C "$R11D/decoy" add -A
git -C "$R11D/decoy" commit -q -m tampered
DECOY_TIP="$(git -C "$R11D/decoy" rev-parse HEAD)"
git -C "$R11D/decoy" update-ref refs/remotes/origin/main "$DECOY_TIP"
DECOY_GIT="$(git -C "$R11D/decoy" rev-parse --absolute-git-dir)"
guard_write "$R11D/project/$REL" TAMPERED
printf 'gitdir: %s\n' "$DECOY_GIT" > "$R11D/project/.git"
write_record "$R11D/out" s11 "$A11" refs/remotes/origin/main "$REAL_GIT" "$REL" "$BLOB_A11"
launch "$R11D/project" "$R11D/out" s11 "$LAUNCHER" --optional "$R11D/project/$REL"
expect_deny "row 11: a rewritten .git pointer cannot redirect verification" 'not the anchor tip'
write_record "$R11D/out" s11c "$A11" refs/remotes/origin/main "$DECOY_GIT" "$REL" "$BLOB_A11"
launch "$R11D/project" "$R11D/out" s11c "$LAUNCHER" --optional "$R11D/project/$REL"
expect_allow "row 11: control — the decoy repo really would have allowed the tampered blob"

# --- rows 12-13: records this path cannot use ------------------------------
fixture r12
A12="$(fx_commit A c1)"; fx_publish "$A12"; BLOB_A12="$(fx_blob)"
fx_commit B c2 >/dev/null; fx_publish HEAD
R12="$FX_OUT/s12.json"
write_record "$FX_OUT" s12 - - - "$REL" "$BLOB_A12"
launch "$FX_PROJ" "$FX_OUT" s12 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 12: a legacy record still denies an ordinary mismatched hook"
if grep -qE '^[[:space:]]+at |node:internal' "$T/last.err"; then
  bad "row 12: a stack trace leaked to stderr: $(cat "$T/last.err")"
else
  ok "row 12: the legacy deny carries no stack trace"
fi
expect_pin "$R12" "$REL" "$BLOB_A12" "row 12: the legacy record is unchanged"

write_record "$FX_OUT" s13 "$A12" refs/remotes/origin/nope "$FX_GIT" "$REL" "$BLOB_A12"
launch "$FX_PROJ" "$FX_OUT" s13 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 13: an unresolvable anchor_ref is denied" 'could not be resolved'

# --- row 14: an unwritable pin directory must deny, never allow ------------
if [ "$(id -u)" = 0 ]; then
  ok "row 14: SKIP (running as root — a read-only directory does not stop a write)"
else
  fixture r14
  A14="$(fx_commit A c1)"; fx_publish "$A14"; BLOB_A14="$(fx_blob)"
  B14="$(fx_commit B c2)"; fx_publish "$B14"
  R14="$FX_OUT/s14.json"
  write_record "$FX_OUT" s14 "$A14" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A14"
  before14="$(cat "$R14")"
  chmod 500 "$FX_OUT"
  launch "$FX_PROJ" "$FX_OUT" s14 "$LAUNCHER" --optional "$FX_PROJ/$REL"
  # Either fail-closed reason is correct here: the same read-only directory that
  # would refuse the re-pin's rename also refuses the lock's mkdir, and which
  # one is reached first is an implementation detail. What must never happen is
  # an allow on an advancement that was never persisted.
  expect_deny "row 14: an unwritable pin directory denies rather than allowing"
  if grep -qE 'could not persist the re-pin under|could not take the record lock at' "$T/last.err"; then
    ok "row 14: the deny names the pin directory or the lock it could not take"
  else
    bad "row 14: the deny named neither the pin dir nor the lock: $(cat "$T/last.err")"
  fi
  chmod 700 "$FX_OUT"
  if [ "$before14" = "$(cat "$R14")" ]; then
    ok "row 14: the record content is unchanged"
  else
    bad "row 14: the record was modified despite the deny"
  fi
fi

# --- rows 15-16: the bounded bootstrap exception (HIMMEL-2528 §4) ----------
# record-hook-integrity.sh pins ITSELF and the plugin's SessionStart chain runs
# it through this launcher, so a live session holding a LEGACY record would deny
# the changed recorder before it could ever write a v2 record. The exception is
# tip-equality on the recorder's own path only.
fixture r15
cp "$RECORDER" "$FX_PROJ/scripts/hooks/record-hook-integrity.sh"
chmod +x "$FX_PROJ/scripts/hooks/record-hook-integrity.sh"
# The recorder verifies-then-sources <its own dir>/hook-integrity-lock.sh, and
# the copy under test is the one in the FIXTURE, so the fixture has to carry
# that lib or the recorder publishes on its degraded lock-free path instead of
# the locked one these rows are meant to exercise. That is now the only thing it
# needs: the recorder no longer sources $CLAUDE_PROJECT_DIR/scripts/guardrails/
# lib.sh for default_branch — it carries an inlined resolve_default_branch(),
# precisely so the hook that ESTABLISHES the pins never executes project-local
# code before any pin exists to vouch for it.
# Unconditional, deliberately: this used to be guarded by a `[ -f <src> ]` test,
# which turned into a silent no-op the moment the lib moved out of scripts/lib/
# and quietly downgraded the fixture instead of failing.
cp "$REPO_ROOT/scripts/hooks/hook-integrity-lock.sh" "$FX_PROJ/scripts/hooks/hook-integrity-lock.sh" \
  || bad "row 15 fixture: could not stage the lock lib the recorder verifies-then-sources"
guard_write "$FX_PROJ/$REL" A
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m c1
A15="$(git -C "$FX_PROJ" rev-parse HEAD)"; fx_publish "$A15"
REC_REL='scripts/hooks/record-hook-integrity.sh'
STALE='0000000000000000000000000000000000000000'
R15="$FX_OUT/s15.json"
write_record "$FX_OUT" s15 - - - "$REC_REL" "$STALE"
launch "$FX_PROJ" "$FX_OUT" s15 "$LAUNCHER" --optional "$FX_PROJ/$REC_REL"
expect_allow "row 15a: bootstrap — a legacy record lets the tip-matching recorder run"
if jq -e 'has("anchor_ref") and has("anchor") and has("git_dir")' "$R15" >/dev/null 2>&1; then
  ok "row 15b: the recorder replaced the legacy record with a v2 one"
else
  bad "row 15b: the published record is still legacy (expected until record-hook-integrity.sh emits schema v2): $(cat "$R15")"
fi
# The staged lock lib is load-bearing but was invisible in the pass/fail signal:
# the recorder still PUBLISHES without it, on its degraded lock-free path, and
# only stamps lock_unverified to say so. Assert the healthy shape, so a fixture
# that silently loses the lib (as the `[ -f ]`-guarded cp above once did) shows
# up here instead of being absorbed.
if jq -e '(.lock_unverified // false) | not' "$R15" >/dev/null 2>&1; then
  ok "row 15c: the recorder vouched for the fixture's lock lib and published under the lock"
else
  bad "row 15c: the recorder fell back to its lock-free path — the fixture lost the lock lib: $(cat "$R15")"
fi

printf '\n# locally modified, never committed\n' >> "$FX_PROJ/$REC_REL"
write_record "$FX_OUT" s16 - - - "$REC_REL" "$STALE"
launch "$FX_PROJ" "$FX_OUT" s16 "$LAUNCHER" --optional "$FX_PROJ/$REC_REL"
expect_deny "row 16: bootstrap is tip-equality, not a blanket pass for the recorder"

# --- rows 17-18: the fast path spawns nothing; the slow path needs git -----
fixture r17
A17="$(fx_commit A c1)"; fx_publish "$A17"; BLOB_A17="$(fx_blob)"
STUB="$T/stub-bin"
MARKER="$T/git-was-called"
mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 1\n' "$MARKER" > "$STUB/git"
chmod +x "$STUB/git"
write_record "$FX_OUT" s17 "$A17" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A17"
printf '{"session_id":"s17","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf harmless"}}' \
  | CLAUDE_PROJECT_DIR="$FX_PROJ" HIMMEL_HOOK_INTEGRITY_DIR="$FX_OUT" PATH="$STUB:$PATH" \
    node "$LAUNCHER" --optional "$FX_PROJ/$REL" >"$T/last.out" 2>"$T/last.err"
LAST_RC=$?
expect_allow "row 17: a correctly-pinned guard runs with a failing git stub first on PATH"
if [ -e "$MARKER" ]; then
  bad "row 17: the fast path spawned git: $(cat "$MARKER")"
else
  ok "row 17: the fast path spawned no git at all (stub marker never written)"
fi

fixture r18
A18="$(fx_commit A c1)"; fx_publish "$A18"; BLOB_A18="$(fx_blob)"
fx_commit B c2 >/dev/null; fx_publish HEAD
EMPTY_BIN="$T/empty-bin"
mkdir -p "$EMPTY_BIN"
# node by ABSOLUTE path, because the point of this row is a PATH with no git on
# it at all — the launcher's own interpreter must survive that.
NODE_BIN="$(command -v node)"
write_record "$FX_OUT" s18 "$A18" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A18"
printf '{"session_id":"s18","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf harmless"}}' \
  | CLAUDE_PROJECT_DIR="$FX_PROJ" HIMMEL_HOOK_INTEGRITY_DIR="$FX_OUT" PATH="$EMPTY_BIN" \
    "$NODE_BIN" "$LAUNCHER" --optional "$FX_PROJ/$REL" >"$T/last.out" 2>"$T/last.err"
LAST_RC=$?
expect_deny "row 18: git absent on the mismatch path denies without crashing" 'git is unavailable'

# --- row 19: a master-default project -------------------------------------
fixture r19 master
A19="$(fx_commit A c1)"; fx_publish "$A19"; BLOB_A19="$(fx_blob)"
B19="$(fx_commit B c2)"; fx_publish "$B19"; BLOB_B19="$(fx_blob)"
R19="$FX_OUT/s19.json"
write_record "$FX_OUT" s19 "$A19" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A19"
launch "$FX_PROJ" "$FX_OUT" s19 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 19: a master-default project advances the same way"
expect_pin "$R19" "$REL" "$BLOB_B19" "row 19: the master-default pin was advanced"

# --- rows 20-22: the chain paths re-pin too -------------------------------
fixture r20
A20="$(fx_commit A c1)"; fx_publish "$A20"; BLOB_A20="$(fx_blob)"
B20="$(fx_commit B c2)"; fx_publish "$B20"; BLOB_B20="$(fx_blob)"
R20="$FX_OUT/s20.json"
write_record "$FX_OUT" s20 "$A20" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A20"
launch "$FX_PROJ" "$FX_OUT" s20 "$LAUNCHER" --chain --lifecycle "$FX_PROJ/$REL"
expect_pin "$R20" "$REL" "$BLOB_B20" "row 20: the --lifecycle chain re-pins synchronously"
expect_anchor "$R20" "$B20" "row 20: the --lifecycle chain advanced the anchor"

fixture r21
guard_write "$FX_PROJ/$REL" A
guard_write "$FX_PROJ/$REL2" A
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m c1
A21="$(git -C "$FX_PROJ" rev-parse HEAD)"; fx_publish "$A21"
BLOB1_A21="$(fx_blob "$REL")"; BLOB2_A21="$(fx_blob "$REL2")"
guard_write "$FX_PROJ/$REL" B
guard_write "$FX_PROJ/$REL2" B
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m c2
B21="$(git -C "$FX_PROJ" rev-parse HEAD)"; fx_publish "$B21"
BLOB1_B21="$(fx_blob "$REL")"; BLOB2_B21="$(fx_blob "$REL2")"
R21="$FX_OUT/s21.json"
write_record "$FX_OUT" s21 "$A21" "$FX_REF" "$FX_GIT" "$REL" "$BLOB1_A21" "$REL2" "$BLOB2_A21"
launch "$FX_PROJ" "$FX_OUT" s21 "$LAUNCHER" --chain "$FX_PROJ/$REL" "$FX_PROJ/$REL2"
expect_allow "row 21: a chain advances every pinned member it runs"
expect_pin "$R21" "$REL"  "$BLOB1_B21" "row 21: the first chain member's pin advanced"
expect_pin "$R21" "$REL2" "$BLOB2_B21" "row 21: the second chain member's pin advanced"
expect_anchor "$R21" "$B21" "row 21: the anchor settled on the tip"
if jq -e . "$R21" >/dev/null 2>&1; then
  ok "row 21: the record is still valid JSON after two advancements"
else
  bad "row 21: the record is not valid JSON after two advancements"
fi

fixture r22
A22="$(fx_commit A c1)"; fx_publish "$A22"; BLOB_A22="$(fx_blob)"
B22="$(fx_commit B c2)"; fx_publish "$B22"; BLOB_B22="$(fx_blob)"
SIBLING='1111111111111111111111111111111111111111'
R22="$FX_OUT/s22.json"
write_record "$FX_OUT" s22 "$A22" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A22" "$REL2" "$SIBLING"
launch "$FX_PROJ" "$FX_OUT" s22 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 22: advancing one pin with a sibling pin present"
expect_pin "$R22" "$REL"  "$BLOB_B22" "row 22: our pin advanced"
expect_pin "$R22" "$REL2" "$SIBLING"  "row 22: the sibling pin survived the merge"

# --- rows 23-26: the record lock ------------------------------------------
# Field 22 of /proc/<pid>/stat (starttime). comm can contain spaces and parens,
# so everything up to the last ") " goes first; field 3 is then field 1.
proc_start() { awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$1/stat" 2>/dev/null; }

# A pid that is definitively gone: started and reaped right here.
dead_pid() {
  local p
  bash -c 'exit 0' &
  p=$!
  wait "$p" 2>/dev/null
  printf '%s' "$p"
}

fixture r23
A23="$(fx_commit A c1)"; fx_publish "$A23"; BLOB_A23="$(fx_blob)"
fx_commit B c2 >/dev/null; fx_publish HEAD
R23="$FX_OUT/s23.json"
write_record "$FX_OUT" s23 "$A23" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A23"
before23="$(cat "$R23")"
LOCK23="$R23.lock"
mkdir -p "$LOCK23"
printf 'pid=%s\npid_namespace=posix\nstart_time=%s\n' "$$" "$(proc_start $$)" > "$LOCK23/owner"
touch -d '2020-01-01' "$LOCK23" 2>/dev/null || true
launch "$FX_PROJ" "$FX_OUT" s23 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 23: a LIVE lock owner is never reclaimed, however old the lock" "could not take the record lock at $LOCK23"
if [ "$before23" = "$(cat "$R23")" ]; then
  ok "row 23: the record is unchanged while another owner holds the lock"
else
  bad "row 23: the record changed under a held lock"
fi
rm -rf "$LOCK23"

fixture r24
A24="$(fx_commit A c1)"; fx_publish "$A24"; BLOB_A24="$(fx_blob)"
fx_commit B c2 >/dev/null; fx_publish HEAD
R24="$FX_OUT/s24.json"
write_record "$FX_OUT" s24 "$A24" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A24"
LOCK24="$R24.lock"
mkdir -p "$LOCK24"
# An MSYS pid from a Git-Bash sibling: a different pid namespace, so its number
# means nothing here. The pid is one that IS dead in OUR namespace, so the
# namespace check is the only thing standing between this lock and a reclaim.
printf 'pid=%s\npid_namespace=msys\nstart_time=\n' "$(dead_pid)" > "$LOCK24/owner"
launch "$FX_PROJ" "$FX_OUT" s24 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 24: a foreign pid_namespace lock is denied, not reclaimed" 'could not take the record lock at'
if [ -d "$LOCK24" ]; then
  ok "row 24: the foreign-namespace lock is still held"
else
  bad "row 24: the foreign-namespace lock was reclaimed"
fi
rm -rf "$LOCK24"

# pid 1 exists but belongs to another user, so process.kill(pid, 0) throws
# EPERM rather than ESRCH — "exists under another user" is LIVE, not dead.
mkdir -p "$LOCK24"
printf 'pid=1\npid_namespace=posix\nstart_time=\n' > "$LOCK24/owner"
launch "$FX_PROJ" "$FX_OUT" s24 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 24b: a lock owned by another user's live pid is not reclaimed" 'could not take the record lock at'
if [ -d "$LOCK24" ]; then
  ok "row 24b: the EPERM lock is still held"
else
  bad "row 24b: the EPERM lock was reclaimed"
fi
rm -rf "$LOCK24"

fixture r25
A25="$(fx_commit A c1)"; fx_publish "$A25"; BLOB_A25="$(fx_blob)"
B25="$(fx_commit B c2)"; fx_publish "$B25"; BLOB_B25="$(fx_blob)"
R25="$FX_OUT/s25.json"
write_record "$FX_OUT" s25 "$A25" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A25"
DEAD_PID="$(dead_pid)"
LOCK25="$R25.lock"
mkdir -p "$LOCK25"
printf 'pid=%s\npid_namespace=posix\nstart_time=\n' "$DEAD_PID" > "$LOCK25/owner"
launch "$FX_PROJ" "$FX_OUT" s25 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 25: a lock whose owner is provably dead is reclaimed"
expect_pin "$R25" "$REL" "$BLOB_B25" "row 25: the advancement completed after the reclaim"

fixture r26
A26="$(fx_commit A c1)"; fx_publish "$A26"; BLOB_A26="$(fx_blob)"
B26="$(fx_commit B c2)"; fx_publish "$B26"; BLOB_B26="$(fx_blob)"
R26="$FX_OUT/s26.json"
write_record "$FX_OUT" s26 "$A26" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A26"
LOCK26="$R26.lock"
mkdir -p "$LOCK26"
printf 'pid=%s\npid_namespace=posix\nstart_time=%s\n' "$$" "$(proc_start $$)" > "$LOCK26/owner"
# The sibling that holds the lock publishes the very advancement we want, inside
# our bounded 200 ms wait: the launcher must re-read and take the fast path
# rather than deny.
R26_OUT="$FX_OUT" R26_ANCHOR="$B26" R26_REF="$FX_REF" R26_GIT="$FX_GIT" R26_BLOB="$BLOB_B26" \
  bash -c 'sleep 0.1; chmod 600 "$R26_OUT/s26.json"; jq --arg k "'"$REL"'" --arg v "$R26_BLOB" --arg a "$R26_ANCHOR" ".pins[\$k]=\$v | .anchor=\$a" "$R26_OUT/s26.json" > "$R26_OUT/s26.next" && mv -f "$R26_OUT/s26.next" "$R26_OUT/s26.json"' &
SIBLING_PID=$!
launch "$FX_PROJ" "$FX_OUT" s26 "$LAUNCHER" --optional "$FX_PROJ/$REL"
wait "$SIBLING_PID" 2>/dev/null
expect_allow "row 26: a lock timeout re-reads and honours a sibling's published advancement"
rm -rf "$LOCK26"

# --- row 27: the HIMMEL-2526 must-run entry -------------------------------
if node -e 'const m = require(process.argv[1]); process.exit(m.MUST_RUN_CHAIN_MEMBERS.has("block-write-into-main-checkout.sh") ? 0 : 1);' "$LAUNCHER"; then
  ok "row 27: MUST_RUN_CHAIN_MEMBERS carries block-write-into-main-checkout.sh"
else
  bad "row 27: MUST_RUN_CHAIN_MEMBERS is missing block-write-into-main-checkout.sh"
fi

# --- row 28: the vendored plugin launcher behaves identically -------------
fixture r28
A28="$(fx_commit A c1)"; fx_publish "$A28"; BLOB_A28="$(fx_blob)"
B28="$(fx_commit B c2)"; fx_publish "$B28"; BLOB_B28="$(fx_blob)"
R28="$FX_OUT/s28.json"
write_record "$FX_OUT" s28 "$A28" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A28"
launch "$FX_PROJ" "$FX_OUT" s28 "$PLUGIN_LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 28: the vendored plugin launcher performs the same advancement"
expect_pin "$R28" "$REL" "$BLOB_B28" "row 28: the plugin launcher advanced the pin"

# --- row 29: the dead-owner steal picks exactly one winner ----------------
# Two launchers can read the SAME dead owner and both conclude "reclaim", so the
# steal has to pick a winner. This row drives the LOSER against a winner spliced
# into its timeline at the point the race actually happens: after the loser has
# inspected the dead owner, before its own steal. In-process because that is the
# only place the interleaving can be staged — the loser has to be interrupted
# between reading the owner and renaming the directory.
#
# The splice performs a real reclaim and NOTHING ELSE; the loser's rename is its
# own, executed for real against whatever the winner left at the path. An
# earlier version of this row threw a synthetic ENOENT there instead, which
# manufactured the refusal it claimed to pin: in the interleaving it named, the
# loser's rename SUCCEEDS against the lock the winner has re-taken, and the old
# stub hid exactly that.
#
# Two winner timings, both real:
#   gone      — the winner has stolen and deleted the dead lock but not yet
#               re-taken the path, so the loser's rename hits a genuinely absent
#               directory and fails on its own;
#   recreated — the winner has already re-taken the lock under its own LIVE pid,
#               so the loser's rename succeeds and must be UNDONE rather than
#               followed by a delete.
R29D="$T/r29"
mkdir -p "$R29D"
cat > "$R29D/drive.js" <<'DRV29'
const fs = require('node:fs');
const path = require('node:path');
const mod = require(process.argv[2]);
const lockDir = process.argv[3];
const deadPid = process.argv[4];
const mode = process.argv[5];   // 'gone' | 'recreated'
const liveOwner = `pid=${process.pid}\npid_namespace=posix\nstart_time=\n`;

fs.mkdirSync(lockDir);
fs.writeFileSync(path.join(lockDir, 'owner'), `pid=${deadPid}\npid_namespace=posix\nstart_time=\n`);

const realRename = fs.renameSync;
let raced = false;
fs.renameSync = (from, to) => {
  if (!raced && String(from) === lockDir) {
    raced = true;
    // The concurrent WINNER's full steal, and in 'recreated' mode its re-take.
    const won = `${lockDir}.winner-graveyard`;
    realRename(from, won);
    fs.rmSync(won, { recursive: true, force: true });
    if (mode === 'recreated') {
      fs.mkdirSync(lockDir);
      fs.writeFileSync(path.join(lockDir, 'owner'), liveOwner);
    }
  }
  // The LOSER's own rename. Not stubbed, not short-circuited.
  return realRename(from, to);
};

const reclaimed = mod.reclaimIfDead(lockDir);
fs.renameSync = realRename;
let owner = '';
try {
  owner = fs.readFileSync(path.join(lockDir, 'owner'), 'utf8');
} catch (_e) { /* nothing at the lock path */ }
console.log(JSON.stringify({
  reclaimed,
  raced,                                   // proof the splice ran at all
  lockPresent: fs.existsSync(lockDir),
  winnerLockIntact: owner === liveOwner,   // only the winner ever writes this pid
}));
DRV29
OUT29G="$(node "$R29D/drive.js" "$HOOKS_DIR/hook-integrity.js" "$R29D/gone.json.lock" "$(dead_pid)" gone)"
if [ "$(printf '%s' "$OUT29G" | jq -r '.raced')" = "true" ]; then
  ok "row 29a: the winner really was spliced into the loser's steal (gone)"
else
  bad "row 29a: the splice never fired, so nothing was raced: $OUT29G"
fi
if [ "$(printf '%s' "$OUT29G" | jq -r '.reclaimed')" = "false" ] \
  && [ "$(printf '%s' "$OUT29G" | jq -r '.lockPresent')" = "false" ]; then
  ok "row 29a: a loser whose rename genuinely fails refuses and resurrects nothing"
else
  bad "row 29a: the losing reclaimer did not refuse cleanly: $OUT29G"
fi

OUT29R="$(node "$R29D/drive.js" "$HOOKS_DIR/hook-integrity.js" "$R29D/recreated.json.lock" "$(dead_pid)" recreated)"
if [ "$(printf '%s' "$OUT29R" | jq -r '.raced')" = "true" ]; then
  ok "row 29b: the winner really was spliced in and re-took the lock"
else
  bad "row 29b: the splice never fired, so nothing was raced: $OUT29R"
fi
if [ "$(printf '%s' "$OUT29R" | jq -r '.reclaimed')" = "false" ]; then
  ok "row 29b: a loser whose rename SUCCEEDS against the re-taken lock still refuses"
else
  bad "row 29b: the loser claimed a lock it stole from the live winner: $OUT29R"
fi
if [ "$(printf '%s' "$OUT29R" | jq -r '.winnerLockIntact')" = "true" ]; then
  ok "row 29b: the winner's live lock is put back, not carted off to the graveyard"
else
  bad "row 29b: the loser destroyed the winner's live lock: $OUT29R"
fi

# --- row 30: an owner file that will not write leaves no lock behind -------
# mkdir can succeed and the owner write fail on its own (a full disk, a
# directory that turned unwritable between the two). An owner-LESS lock is the
# worst residue there is: reclaimIfDead refuses an unreadable owner forever, so
# the directory would wedge the re-pin path for every future session.
R30D="$T/r30"
mkdir -p "$R30D"
cat > "$R30D/drive.js" <<'DRV30'
const fs = require('node:fs');
const path = require('node:path');
const mod = require(process.argv[2]);
const recordPath = process.argv[3];
const lockDir = `${recordPath}.lock`;

const realWrite = fs.writeFileSync;
fs.writeFileSync = (file, ...rest) => {
  if (String(file) === path.join(lockDir, 'owner')) {
    const err = new Error('ENOSPC: no space left on device');
    err.code = 'ENOSPC';
    throw err;
  }
  return realWrite(file, ...rest);
};
const first = mod.acquireRecordLock(recordPath);
fs.writeFileSync = realWrite;
const leftover = fs.existsSync(lockDir);
// The harm an owner-less lock does is permanent, so the recovery is the real
// assertion: the very next acquire, with nothing wrong any more, must work.
const second = mod.acquireRecordLock(recordPath);
if (second) mod.releaseRecordLock(second);
console.log(JSON.stringify({ acquired: first !== null, leftover, recovered: second !== null }));
DRV30
OUT30="$(node "$R30D/drive.js" "$HOOKS_DIR/hook-integrity.js" "$R30D/rec.json")"
if [ "$(printf '%s' "$OUT30" | jq -r '.acquired')" = "false" ] && [ "$(printf '%s' "$OUT30" | jq -r '.leftover')" = "false" ]; then
  ok "row 30: an owner-write failure reports failure and leaves no lock directory"
else
  bad "row 30: the failed acquire did not clean up: $OUT30"
fi
if [ "$(printf '%s' "$OUT30" | jq -r '.recovered')" = "true" ]; then
  ok "row 30: the next acquire is not wedged by the failed one"
else
  bad "row 30: the record lock is permanently wedged after an owner-write failure: $OUT30"
fi

# --- row 31: a failed win32 publish never leaves the record absent ---------
# On win32 the rename over an existing record can fail, and the fallback used to
# unlink the incumbent first. Lock-free fast-path readers fail OPEN on a missing
# record, so a second rename that also fails disabled verification for the rest
# of the session. Both the platform and the failing rename are supplied here;
# the assertion is that the record survives.
R31D="$T/r31"
mkdir -p "$R31D"
printf '{"pins":{},"anchor":"before"}\n' > "$R31D/rec.json"
chmod 400 "$R31D/rec.json"
cat > "$R31D/drive.js" <<'DRV31'
const fs = require('node:fs');
const mod = require(process.argv[2]);
const recordPath = process.argv[3];
Object.defineProperty(process, 'platform', { value: 'win32' });
const original = fs.readFileSync(recordPath, 'utf8');

// Every rename of the temp file ONTO the record fails; renames of the record
// aside are left alone, so the fallback runs and then fails its second rename.
const realRename = fs.renameSync;
fs.renameSync = (from, to) => {
  if (String(to) === recordPath && String(from).indexOf(`${recordPath}.tmp-`) === 0) {
    const err = new Error('EPERM: operation not permitted');
    err.code = 'EPERM';
    throw err;
  }
  return realRename(from, to);
};
let threw = false;
try {
  mod.persistIntegrityRecord(recordPath, { pins: { 'scripts/hooks/g.sh': 'deadbeef' }, anchor: 'after' });
} catch (_e) {
  threw = true;
}
fs.renameSync = realRename;
const exists = fs.existsSync(recordPath);
console.log(JSON.stringify({
  threw,
  exists,
  unchanged: exists && fs.readFileSync(recordPath, 'utf8') === original,
}));
DRV31
OUT31="$(node "$R31D/drive.js" "$HOOKS_DIR/hook-integrity.js" "$R31D/rec.json")"
if [ "$(printf '%s' "$OUT31" | jq -r '.threw')" = "true" ] && [ "$(printf '%s' "$OUT31" | jq -r '.exists')" = "true" ]; then
  ok "row 31: a failed win32 publish still leaves a record on disk"
else
  bad "row 31: the win32 publish left no record (readers would fail open): $OUT31"
fi
if [ "$(printf '%s' "$OUT31" | jq -r '.unchanged')" = "true" ]; then
  ok "row 31: the restored record is the incumbent one, byte for byte"
else
  bad "row 31: the record on disk is not the incumbent: $OUT31"
fi

# --- row 32: a hung git is a bounded deny, not a wedged lock ---------------
# The mismatch path shells out to git while HOLDING the record lock, so a git
# that never returns (a .git on a dead mount) would wedge every other launcher
# in the session. The budget is env-overridable so this row can use 400 ms
# instead of the 5 s production bound; the stub hangs for 30 s, so an unbounded
# git is unmistakable.
fixture r32
A32="$(fx_commit A c1)"; fx_publish "$A32"; BLOB_A32="$(fx_blob)"
fx_commit B c2 >/dev/null; fx_publish HEAD
SLOW_BIN="$T/slow-bin"
mkdir -p "$SLOW_BIN"
printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$SLOW_BIN/git"
chmod +x "$SLOW_BIN/git"
write_record "$FX_OUT" s32 "$A32" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A32"
start32="$(date +%s)"
printf '{"session_id":"s32","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf harmless"}}' \
  | CLAUDE_PROJECT_DIR="$FX_PROJ" HIMMEL_HOOK_INTEGRITY_DIR="$FX_OUT" PATH="$SLOW_BIN:$PATH" \
    HIMMEL_HOOK_INTEGRITY_GIT_TIMEOUT_MS=400 \
    node "$LAUNCHER" --optional "$FX_PROJ/$REL" >"$T/last.out" 2>"$T/last.err"
LAST_RC=$?
elapsed32=$(( $(date +%s) - start32 ))
expect_deny "row 32: a git that hangs denies and names the budget it blew" '400 ms verification budget'
if [ "$elapsed32" -le 10 ]; then
  ok "row 32: the deny arrived in ${elapsed32}s, nowhere near the stub's 30 s hang"
else
  bad "row 32: the hung git was not bounded (${elapsed32}s)"
fi
if [ -e "$FX_OUT/s32.json.lock" ]; then
  bad "row 32: the record lock was left held after the timeout"
else
  ok "row 32: the record lock is released after the timeout"
fi

# --- rows 33-36: reading across the win32 publish window -------------------
# persistIntegrityRecord's win32 fallback has no atomic replace: it moves the
# incumbent ASIDE and renames the replacement in, and between the two there is
# no record on disk. Readers take the fast path WITHOUT the lock and an absent
# record reads as "no opinion" → allow, so a reader in that window skipped
# verification entirely — permanently, if the publisher was killed inside it.
# These rows stage the on-disk state that window leaves (record gone, an
# `<record>.old-…` aside beside it, the lock held) and drive the real launcher.
ASIDE_SUFFIX='.old-4242-a1b2c3'

fixture r33
A33="$(fx_commit A c1)"; fx_publish "$A33"; BLOB_A33="$(fx_blob)"
R33="$FX_OUT/s33.json"
write_record "$FX_OUT" s33 "$A33" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A33"
# The pin MATCHES the disk, so a reader that finds the record allows on the fast
# path and a reader that fails open allows too — only a reader that notices the
# publication in flight behaves differently.
LOCK33="$R33.lock"
mkdir -p "$LOCK33"
printf 'pid=%s\npid_namespace=posix\nstart_time=%s\n' "$$" "$(proc_start $$)" > "$LOCK33/owner"
chmod 600 "$R33"
mv "$R33" "$R33$ASIDE_SUFFIX"
launch "$FX_PROJ" "$FX_OUT" s33 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 33: a reader inside a LIVE publisher's window does not fail open" 'is still in flight'
if [ -f "$R33$ASIDE_SUFFIX" ] && [ ! -f "$R33" ]; then
  ok "row 33: a live publisher's window is waited out, never stolen"
else
  bad "row 33: the reader touched a live publisher's aside"
fi
rm -rf "$LOCK33"

fixture r34
A34="$(fx_commit A c1)"; fx_publish "$A34"
R34="$FX_OUT/s34.json"
# LEGACY record pinning a blob the disk does not carry: once the reader gets the
# record back it must DENY. Failing open (the pre-fix behaviour) allows, so the
# two outcomes are not merely different reasons for the same verdict.
write_record "$FX_OUT" s34 - - - "$REL" "$STALE"
LOCK34="$R34.lock"
mkdir -p "$LOCK34"
printf 'pid=%s\npid_namespace=posix\nstart_time=%s\n' "$$" "$(proc_start $$)" > "$LOCK34/owner"
chmod 600 "$R34"
mv "$R34" "$R34$ASIDE_SUFFIX"
# The publisher finishes inside the reader's bounded wait, exactly as a healthy
# win32 publish does — one rename later the record is back.
R34_SRC="$R34$ASIDE_SUFFIX" R34_DST="$R34" R34_LOCK="$LOCK34" \
  bash -c 'sleep 0.05; mv -f "$R34_SRC" "$R34_DST"; rm -rf "$R34_LOCK"' &
PUB34=$!
launch "$FX_PROJ" "$FX_OUT" s34 "$LAUNCHER" --optional "$FX_PROJ/$REL"
wait "$PUB34" 2>/dev/null
expect_deny "row 34: the reader waits the window out and verifies against the record that lands"
if grep -q 'in flight' "$T/last.err"; then
  bad "row 34: the deny came from the in-flight branch, not from the landed record: $(cat "$T/last.err")"
else
  ok "row 34: the deny is the landed record's verdict, not the in-flight refusal"
fi
rm -rf "$LOCK34"

fixture r35
A35="$(fx_commit A c1)"; fx_publish "$A35"
R35="$FX_OUT/s35.json"
write_record "$FX_OUT" s35 - - - "$REL" "$STALE"
INCUMBENT35="$(cat "$R35")"
LOCK35="$R35.lock"
mkdir -p "$LOCK35"
printf 'pid=%s\npid_namespace=posix\nstart_time=\n' "$(dead_pid)" > "$LOCK35/owner"
chmod 600 "$R35"
mv "$R35" "$R35$ASIDE_SUFFIX"
launch "$FX_PROJ" "$FX_OUT" s35 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 35: a publisher killed mid-window does not leave verification silently off"
if [ -f "$R35" ] && [ "$(cat "$R35")" = "$INCUMBENT35" ]; then
  ok "row 35: the incumbent record is put back, so the deny is not a wedge either"
else
  bad "row 35: the incumbent was not restored — the session stays without a record"
fi
if [ -e "$LOCK35" ]; then
  bad "row 35: the dead publisher's lock is still held"
else
  ok "row 35: the dead publisher's stale lock was reclaimed on the way through"
fi

# The control that keeps the discriminator honest. record-hook-integrity.sh
# holds this same lock while it builds a session's FIRST record, and there is
# legitimately no record on disk then — so the LOCK alone must never mean
# "publication in flight". Without an aside beside it, this stays fail-open.
fixture r36
guard_write "$FX_PROJ/$REL" A
LOCK36="$FX_OUT/s36.json.lock"
mkdir -p "$LOCK36"
printf 'pid=%s\npid_namespace=posix\nstart_time=%s\n' "$$" "$(proc_start $$)" > "$LOCK36/owner"
launch "$FX_PROJ" "$FX_OUT" s36 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 36: a held lock with no aside (the recorder's first record) still fails open"
rm -rf "$LOCK36"

# --- rows 37a/37b: the publisher finishes WHILE the reader inspects --------
# The two markers rows 33-36 rely on are the DEBRIS of a publication in flight,
# and a publisher that finishes takes them away. So "no lock" and "no aside" are
# also exactly what a publication that completed one instant ago looks like, and
# both used to return fail-open WITHOUT re-reading the now-published record —
# the function gave up in the very window it exists to close.
#
# Determinism comes from WHERE the publisher's last two acts are scheduled, not
# from faking their effect: the driver hooks the syscall the reader uses to
# inspect each marker, performs the real completion (rename the aside back,
# drop the lock) and then calls through to the real syscall. The module reads a
# real filesystem and returns its own verdict; the assertions are that the
# trigger fired and that the verdict is the RESTORED record's.
R37D="$T/r37"
mkdir -p "$R37D"
cat > "$R37D/drive.js" <<'DRV37'
const fs = require('node:fs');
const path = require('node:path');
const mod = require(process.argv[2]);
const recordPath = process.argv[3];
const aside = process.argv[4];
const trigger = process.argv[5];
const scriptPath = process.argv[6];
const sessionId = process.argv[7];
const lockDir = `${recordPath}.lock`;

let finished = false;
const finish = (dropLock) => {
  if (finished) return;
  finished = true;
  fs.renameSync(aside, recordPath);          // the publish lands
  if (dropLock) fs.rmSync(lockDir, { recursive: true, force: true });
};

const realExists = fs.existsSync;
const realReaddir = fs.readdirSync;
if (trigger === 'lock') {
  // The publisher is entirely done by the time the reader looks for the lock.
  fs.existsSync = (p) => {
    if (String(p) === lockDir) finish(true);
    return realExists(p);
  };
} else {
  // persistIntegrityRecord unlinks the aside before its caller releases the
  // lock, so the aside can be gone while the lock is still held.
  fs.readdirSync = (p, ...rest) => {
    if (String(p) === path.dirname(recordPath)) finish(false);
    return realReaddir(p, ...rest);
  };
}
let result;
try {
  result = mod.verifyProjectHookIntegrity(scriptPath, sessionId);
} finally {
  fs.existsSync = realExists;
  fs.readdirSync = realReaddir;
}
console.log(JSON.stringify({
  finished,
  ok: result.ok === true,
  reason: result.reason || '',
  recordBack: realExists(recordPath),
}));
DRV37

# <session> <trigger> <label>
drive_r37() {
  fixture "r37$2"
  fx_commit A c1 >/dev/null; fx_publish HEAD
  # A LEGACY record pinning a blob the disk does not carry: honouring it DENIES,
  # while the pre-fix fail-open allows. The two outcomes are opposite verdicts,
  # not two spellings of one.
  write_record "$FX_OUT" "$1" - - - "$REL" "$STALE"
  local rec="$FX_OUT/$1.json"
  mkdir -p "$rec.lock"
  printf 'pid=%s\npid_namespace=posix\nstart_time=%s\n' "$$" "$(proc_start $$)" > "$rec.lock/owner"
  chmod 600 "$rec"
  mv "$rec" "$rec$ASIDE_SUFFIX"
  local out
  out="$(CLAUDE_PROJECT_DIR="$FX_PROJ" HIMMEL_HOOK_INTEGRITY_DIR="$FX_OUT" \
    node "$R37D/drive.js" "$HOOKS_DIR/hook-integrity.js" "$rec" "$rec$ASIDE_SUFFIX" "$2" \
      "$FX_PROJ/$REL" "$1")"
  if [ "$(printf '%s' "$out" | jq -r '.finished')" != "true" ] \
    || [ "$(printf '%s' "$out" | jq -r '.recordBack')" != "true" ]; then
    bad "$3 — the staged publisher never completed, so the row proved nothing: $out"
    return
  fi
  if [ "$(printf '%s' "$out" | jq -r '.ok')" = "false" ]; then
    ok "$3"
  else
    bad "$3 — the reader failed open past a record that was on disk: $out"
  fi
  # Both halves, or the row passes on a fail-open allow (which also carries no
  # reason) and says nothing.
  if [ "$(printf '%s' "$out" | jq -r '.ok')" = "false" ] \
    && [ "$(printf '%s' "$out" | jq -r '.reason')" = "" ]; then
    ok "$3 (the verdict is the restored record's, not an in-flight refusal)"
  else
    bad "$3 — expected the record's own deny, got: $out"
  fi
  rm -rf "$rec.lock"
}
drive_r37 s37a lock  "row 37a: a lock that vanished because the publish LANDED re-reads before failing open"
drive_r37 s37b aside "row 37b: an aside that vanished because the publish LANDED re-reads before failing open"

# --- row 38: an ambiguous window denies; it does not read as absence -------
# publishAsidePath answered null both for "no aside" and for "several", and the
# caller reads null as no evidence → fail open. So ONE leftover aside from an
# earlier failed cleanup put every later window of that session back on the
# fail-open path. Several asides is strictly more evidence than none.
fixture r38
fx_commit A c1 >/dev/null; fx_publish HEAD
R38="$FX_OUT/s38.json"
write_record "$FX_OUT" s38 - - - "$REL" "$STALE"
LOCK38="$R38.lock"
mkdir -p "$LOCK38"
printf 'pid=%s\npid_namespace=posix\nstart_time=%s\n' "$$" "$(proc_start $$)" > "$LOCK38/owner"
chmod 600 "$R38"
mv "$R38" "$R38$ASIDE_SUFFIX"
printf 'an aside an earlier window never cleaned up\n' > "$R38.old-1111-c0ffee"
launch "$FX_PROJ" "$FX_OUT" s38 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 38: a leftover second aside makes the window ambiguous, and ambiguous denies" \
  'more than one unresolved publication aside'
# The deny is part of this assertion too: a fail-open reader also leaves both
# asides in place, so "untouched" alone would be green with the fix reverted.
if [ "$LAST_RC" -eq 2 ] && [ -f "$R38$ASIDE_SUFFIX" ] \
  && [ -f "$R38.old-1111-c0ffee" ] && [ ! -f "$R38" ]; then
  ok "row 38: neither aside is guessed at — the reader refuses instead of restoring one"
else
  bad "row 38: the reader picked an incumbent out of an ambiguous window"
fi
rm -rf "$LOCK38"

# --- row 39: release removes only a lock this process still owns -----------
# reclaimIfDead's restore can fail (its RESIDUAL), leaving a former holder with
# a path string a SUCCESSOR now owns. An unconditional rm -rf on the way out
# deleted that successor's live lock — the bash twin's hil_lock_release has
# always checked the owner first, and this is where the two diverged.
R39D="$T/r39"
mkdir -p "$R39D"
cat > "$R39D/drive.js" <<'DRV39'
const fs = require('node:fs');
const path = require('node:path');
const mod = require(process.argv[2]);
const recordPath = process.argv[3];

const mine = mod.acquireRecordLock(recordPath);
// The residual state, built with the real operations in the real order: a
// reclaimer renames our live lock aside, then a successor mkdirs the vacated
// path and stamps its OWN owner file.
fs.renameSync(mine, `${mine}.dead.stolen`);
fs.mkdirSync(mine);
fs.writeFileSync(path.join(mine, 'owner'), 'pid=1\npid_namespace=posix\nstart_time=\n');
const successor = fs.readFileSync(path.join(mine, 'owner'), 'utf8');
mod.releaseRecordLock(mine);   // our critical section ends; we release what we think we hold
const survived = fs.existsSync(mine)
  && fs.readFileSync(path.join(mine, 'owner'), 'utf8') === successor;

// Control: "never release" would pass the assertion above and wedge every
// future acquire, so a lock we DO own must still come down.
fs.rmSync(mine, { recursive: true, force: true });
const own = mod.acquireRecordLock(recordPath);
if (own) mod.releaseRecordLock(own);
console.log(JSON.stringify({
  acquired: mine !== null,
  survived,
  released: own !== null && !fs.existsSync(mine),
}));
DRV39
OUT39="$(node "$R39D/drive.js" "$HOOKS_DIR/hook-integrity.js" "$R39D/rec.json")"
if [ "$(printf '%s' "$OUT39" | jq -r '.acquired')" != "true" ]; then
  bad "row 39: the driver never took a lock, so the row proved nothing: $OUT39"
elif [ "$(printf '%s' "$OUT39" | jq -r '.survived')" = "true" ]; then
  ok "row 39: releasing a lock a successor now owns is a no-op, not a deletion"
else
  bad "row 39: the release deleted the successor's live lock: $OUT39"
fi
if [ "$(printf '%s' "$OUT39" | jq -r '.released')" = "true" ]; then
  ok "row 39: a lock this process really owns is still released"
else
  bad "row 39: release refused a lock we own — the next acquire is wedged: $OUT39"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
