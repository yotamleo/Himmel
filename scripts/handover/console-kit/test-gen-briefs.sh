#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-brief-lint.sh
# test-gen-briefs.sh — HIMMEL-4959. Exercises gen-briefs.py on a fixture legs
# JSON: the briefs it writes pass brief-lint.sh (the arming-time check
# headed-arm-leg runs), the launcher carries the hook-integrity bypass export
# only for hook=true, bad input is refused, nothing is overwritten. The worktree
# step is stubbed (GEN_BRIEFS_WORKTREE_CMD) and every path is a fixture: no real
# bucket, worktree or launch. GEN_BRIEFS overrides the script under test (the
# RED control: a missing script fails every row). bash 3.2-safe.
#
# Run: bash scripts/handover/console-kit/test-gen-briefs.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${GEN_BRIEFS:-$HERE/gen-briefs.py}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gen-briefs-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
BUCKET="$WORK/bucket"; REPO="$WORK/repo"; mkdir -p "$REPO"

cat > "$WORK/wt.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$WT_LOG"
[ "$1" = "fix/fail-me" ] && exit 1
echo "created worktree $1"
EOF
chmod +x "$WORK/wt.sh"
export WT_LOG="$WORK/wt.log" GEN_BRIEFS_WORKTREE_CMD="$WORK/wt.sh"

cat > "$WORK/legs.json" <<'EOF'
[
 {"label":"N901","keys":["HIMMEL-9001"],"slug":"plain-fix","branch":"fix/himmel-9001-plain-fix","title":"a plain fix","desc":"fix the plain thing","why":"it is broken","prior":"HIMMEL-9000 (the earlier fix). Source: `git log -3 -- scripts/x`.","scope":"`scripts/x/`","scope_short":"scripts/x","commit":"fix(x): [HIMMEL-9001] fix the plain thing"},
 {"label":"N902","keys":["HIMMEL-9002","HIMMEL-9003"],"slug":"hook-fix","branch":"fix/himmel-9002-hook-fix","title":"a hook fix","desc":"fix the hook thing","why":"the hook is broken","prior":"none found (qmd jira-himmel hook thing)","scope":"`scripts/hooks/h.sh`","scope_short":"h.sh","hook":true,"judge":true,"commit":"fix(hooks): [HIMMEL-9002] fix the hook","extra":"GREEN controls stay."}
]
EOF

run() { python3 "$SUT" "$WORK/legs.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --console HIMMEL-nextleg-2026-10-08BZ-roadmap-console --bucket "$BUCKET" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/w" --deadline 1791475000 "$@"; }

out="$(run --manifest "$WORK/fleet.json" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "a valid legs file generates (rc 0)" || fail "rc=$rc: $out"
D1="$BUCKET/HIMMEL-9001-N901-plain-fix-2026-10-08.md"
D2="$BUCKET/HIMMEL-9002-N902-hook-fix-2026-10-08.md"
[ -f "$D1" ] && [ -f "$D2" ] && pass "one brief per leg, named <KEY>-<label>-<slug>-<date>.md" || fail "briefs missing in $BUCKET"
bash "$HERE/brief-lint.sh" "$D1" 2>"$WORK/lint1.err"; rc=$?
[ "$rc" = 0 ] && pass "brief 1 passes brief-lint.sh" || fail "brief 1 brief-lint rc=$rc: $(cat "$WORK/lint1.err")"
bash "$HERE/brief-lint.sh" "$D2" 2>"$WORK/lint2.err"; rc=$?
[ "$rc" = 0 ] && pass "brief 2 (none found (<query>) prior art) passes brief-lint.sh" || fail "brief 2 brief-lint rc=$rc: $(cat "$WORK/lint2.err")"

b1="$(cat "$D1" 2>/dev/null)"; b2="$(cat "$D2" 2>/dev/null)"
has "the brief names the console" "$b1" "HIMMEL-nextleg-2026-10-08BZ-roadmap-console"
has "the brief carries a nonce in the console letter's shape" "$b1" "BZ-N901-"
has "the brief names the base sha" "$b1" "4ccb59dd6de2eba962c75f136096cd7b721ae312"
has "the brief names the worktree under the repo" "$b1" "$REPO/.claude/worktrees/fix+himmel-9001-plain-fix"
has "the brief carries the handover root" "$b1" "$WORK/handovers"
has "a two-key leg's Why lists both tickets' get commands" "$b2" "get HIMMEL-9003"
has "a hook leg's brief says it is launched with the bypass" "$b2" "hook-integrity bypass flag"
lacks "a plain leg's brief does not" "$b1" "hook-integrity bypass flag"
has "a judge leg's brief announces the opus judge" "$b2" "console runs an opus judge"
has "the other leg's scope is listed under 'other live legs'" "$b1" "N902 (h.sh)"

l1="$(cat "$BUCKET/launch-N901.sh" 2>/dev/null)"; l2="$(cat "$BUCKET/launch-N902.sh" 2>/dev/null)"
lacks "a plain leg's launcher has NO bypass export" "$l1" "HIMMEL_HOOK_INTEGRITY_BYPASS_OK"
has "a hook leg's launcher exports the bypass" "$l2" "export HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1"
has "the launcher calls headed-arm-leg.sh under the repo" "$l1" "$REPO/scripts/handover/console-kit/headed-arm-leg.sh --profile leg-impl --console HIMMEL-nextleg-2026-10-08BZ-roadmap-console"
has "the launcher passes the deadline and model" "$l1" "1791475000"
has "the launcher is syntactically valid bash" "$(bash -n "$BUCKET/launch-N901.sh" 2>&1 && echo ok)" "ok"
[ -x "$BUCKET/launch-N901.sh" ] && pass "launchers are executable" || fail "launcher not executable"
has "it prints one manifest add per leg" "$out" "fleet-manifest.sh add $WORK/fleet.json $D2"
# HIMMEL-5089: the printed add line carries --lane, so the manifest never stores lane unknown.
has "the add line for a default leg carries --lane native" "$out" "fleet-manifest.sh add $WORK/fleet.json $D1 --lane native"
has "and so does the second leg's" "$out" "fleet-manifest.sh add $WORK/fleet.json $D2 --lane native"
# The printed lines, run as printed from the repo root, build a manifest relay-batch resolves.
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
printf '%s\n' "$out" | grep '^bash scripts/handover/console-kit/fleet-manifest.sh add ' > "$WORK/adds.txt"
while IFS= read -r addline; do (cd "$REPO_ROOT" && eval "$addline" >/dev/null 2>&1); done < "$WORK/adds.txt"
cp "$WORK/fleet.json" "$WORK/console.fleet.json" 2>/dev/null
# shellcheck disable=SC2016  # the backticks are literal markers in the Live state
printf '## Live state\nlegs: `N901:tok1:lock:1` `N902:tok2:lock:2`\n' > "$WORK/console.md"
cat > "$WORK/census.sh" <<'EOC'
#!/usr/bin/env bash
printf '1\tHIMMEL-9001-N901-plain-fix-2026-10-08\tm\t0\n2\tHIMMEL-9002-N902-hook-fix-2026-10-08\tm\t0\n'
EOC
rb="$(RELAY_BATCH_CENSUS="$WORK/census.sh" bash "$HERE/relay-batch.sh" "$WORK/console.md" --successor X-console 2>&1)"
lacks "relay-batch on a gen-briefs-built manifest prints no UNRESOLVED-LANE" "$rb" "UNRESOLVED-LANE"
has "and relays both legs" "$rb" "SENDMESSAGE to=HIMMEL-9002-N902-hook-fix-2026-10-08"
# HIMMEL-5047: the sidecar Telegram /launch-leg checks is written with the launcher.
side="$(cat "$WORK/fleet.launchers.sha256" 2>/dev/null)"
# hashlib, not sha256sum: macOS ships shasum only.
sha_of() { python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
has "the sha256 sidecar records launcher 1 at write time" "$side" "$(sha_of "$BUCKET/launch-N901.sh")  $BUCKET/launch-N901.sh"
has "and launcher 2" "$side" "$(sha_of "$BUCKET/launch-N902.sh")  $BUCKET/launch-N902.sh"
has "it created both worktrees via the seam" "$(paste -sd, "$WORK/wt.log")" "fix/himmel-9001-plain-fix,fix/himmel-9002-hook-fix"
[ -f "$WORK/legs.json.out" ] && pass "the .out file records the nonces" || fail "no .out file"
has "nothing was launched (no signal files)" "$(ls "$WORK/w" 2>&1)" "No such file"

# --- refusals ---------------------------------------------------------------
run >/dev/null 2>"$WORK/again.err"; rc=$?
[ "$rc" = 1 ] && pass "re-running over existing briefs refuses (rc 1)" || fail "overwrite rc=$rc"

rm -rf "$BUCKET"
sed 's/"prior":"HIMMEL-9000[^"]*"/"prior":"none"/' "$WORK/legs.json" > "$WORK/bare.json"
python3 "$SUT" "$WORK/bare.json" --base 4ccb59d --console BZ --bucket "$BUCKET" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/bare.err"; rc=$?
[ "$rc" = 1 ] && pass "a bare 'none' prior art is refused (rc 1)" || fail "bare none rc=$rc"
[ ! -e "$BUCKET/launch-N901.sh" ] && pass "and nothing is written for it" || fail "wrote files for an invalid leg"

printf '[{"label":"N903","keys":["HIMMEL-1"]}]\n' > "$WORK/short.json"
python3 "$SUT" "$WORK/short.json" --base 4ccb59d --console BZ --bucket "$BUCKET" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/short.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'missing' "$WORK/short.err" && pass "a leg missing required keys is refused" || fail "missing keys rc=$rc"

sed 's#fix/himmel-9001-plain-fix#fix/fail-me#' "$WORK/legs.json" > "$WORK/wtfail.json"
python3 "$SUT" "$WORK/wtfail.json" --base 4ccb59d --console BZ --bucket "$WORK/b2" --repo "$REPO" --handover-root /h >/dev/null 2>"$WORK/wtfail.err"; rc=$?
[ "$rc" = 1 ] && [ ! -e "$WORK/b2/launch-N901.sh" ] && pass "a failed worktree writes no brief for that leg" || fail "worktree failure rc=$rc"

mkdir -p "$WORK/b3"; : > "$WORK/b3/launch-N901.sh"
python3 "$SUT" "$WORK/legs.json" --base 4ccb59d --console BZ --bucket "$WORK/b3" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/coll.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'launch-N901.sh already exists' "$WORK/coll.err" && [ ! -s "$WORK/b3/launch-N901.sh" ] && ! ls "$WORK/b3"/*.md >/dev/null 2>&1 && pass "an existing launcher is refused before anything is written" || fail "launcher collision rc=$rc"

python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); d=dict(l[0]); d["label"]="N999"; d["keys"]=["HIMMEL-9999"]; l.append(d); json.dump(l,open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/dupbr.json"
python3 "$SUT" "$WORK/dupbr.json" --base 4ccb59d --console BZ --bucket "$WORK/b4" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/dupbr.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'duplicate leg branches' "$WORK/dupbr.err" && pass "two legs sharing a branch are refused" || fail "dup branch rc=$rc"

# A per-leg lane key is carried through and validated.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/lane-ok.json"
lout="$(python3 "$SUT" "$WORK/lane-ok.json" --base 4ccb59d --console BZ --bucket "$WORK/b5" --repo "$REPO" --handover-root /h --no-worktree --manifest "$WORK/f5.json" 2>&1)"
has "a leg's lane key is printed as --lane" "$lout" "--lane claudex"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="Bad Lane"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/lane-bad.json"
python3 "$SUT" "$WORK/lane-bad.json" --base 4ccb59d --console BZ --bucket "$WORK/b6" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/lane-bad.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'lane' "$WORK/lane-bad.err" && [ ! -e "$WORK/b6/launch-N901.sh" ] && pass "an invalid lane is refused before anything is written" || fail "bad lane rc=$rc"

python3 "$SUT" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "no arguments is a usage error (rc 2)" || fail "usage rc=$rc"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
