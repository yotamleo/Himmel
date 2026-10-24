#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-brief-lint.sh
# test-gen-briefs.sh — Exercises gen-briefs.py on a fixture legs
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
# No bus identity, so relay-batch never reaches the real himmel-bus store.
unset HIMMEL_BUS_NAME

cat > "$WORK/wt.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$WT_LOG"
[ "$1" = "fix/fail-me" ] && exit 1
echo "created worktree $1"
EOF
chmod +x "$WORK/wt.sh"
export WT_LOG="$WORK/wt.log" GEN_BRIEFS_WORKTREE_CMD="$WORK/wt.sh"
export GEN_BRIEFS_NO_WT_CHECK=1  # the older rows use a fixture --repo with no real worktrees; the bucket and worktree-guard rows unset it

cat > "$WORK/legs.json" <<'EOF'
[
 {"label":"N901","keys":["HIMMEL-9001"],"slug":"plain-fix","branch":"fix/himmel-9001-plain-fix","title":"a plain fix","desc":"fix the plain thing","why":"it is broken","prior":"HIMMEL-9000 (the earlier fix). Source: `git log -3 -- scripts/x`.","scope":"`scripts/x/`","scope_short":"scripts/x","commit":"fix(x): [HIMMEL-9001] fix the plain thing"},
 {"label":"N902","keys":["HIMMEL-9002","HIMMEL-9003"],"slug":"hook-fix","branch":"fix/himmel-9002-hook-fix","title":"a hook fix","desc":"fix the hook thing","why":"the hook is broken","prior":"none found (qmd jira-himmel hook thing)","scope":"`scripts/hooks/h.sh`","scope_short":"h.sh","hook":true,"judge":true,"env":true,"commit":"fix(hooks): [HIMMEL-9002] fix the hook","extra":"GREEN controls stay."}
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

# every brief pre-authorizes a new suite's own tier + duration row
has "brief 1 pre-authorizes the new suite's own tier and duration rows" "$(tr '\n' ' ' < "$D1" | tr -s ' ')" "A new test suite may add exactly one row for itself to scripts/ci/suite-tiers.tsv and scripts/ci/suite-durations.tsv"
has "brief 2 pre-authorizes the new suite's own tier and duration rows" "$(tr '\n' ' ' < "$D2" | tr -s ' ')" "name the rows in READY"

# contract item 3: a leg runs locally only the RED rows it builds; every other impacted suite is CI-gated
B1="$(tr '\n' ' ' < "$D1" | tr -s ' ')"
lacks "brief 1 no longer tells the leg to run the full suite of every touched file" "$B1" "the full suite of every file you touched"
has "brief 1 lists non-RED impacted suites as SKIP CI-gated per decision 101" "$B1" "SKIP CI-gated per decision 101 (GitHub CI is the gate)"
has "brief 1 routes VM-only checks through the VM queue" "$B1" "VM queue"
has "brief 1 forbids run-shell-tests.sh full or sharded locally" "$B1" "never run run-shell-tests.sh full or sharded locally"
has "brief 1 limits local runs to the RED rows of the item built" "$B1" "Locally run only the RED rows of the item you build"

# the three most-refused shapes are taught where the leg first meets them (7370, 7371, 7372)
has "brief 1 teaches the exact quiet-run RED command, nothing inside the backticks after the suite" "$B1" "run it as \`bash scripts/quiet-run.sh suite -- bash <test-*.sh>\` with nothing appended"
has "brief 1 names the quiet-run log path to Read" "$B1" "Read the log path its ERR line prints"
has "brief 1 teaches the Edit tool / python3 -I <file> shape" "$B1" "run as \`python3 -I <file>\`"
has "brief 1 teaches the SWEEP record grammar and its write command" "$B1" "write its \`SWEEP [<id>@<head>] class=… :: sites=…\` line (a one-site finding: \`:: single-site search=git grep …\`) with \`bash scripts/cr/write-verdicts.sh sweep --branch <b> --from-file <f>\`"
has "brief 1 teaches the single-site search form for a one-site finding" "$B1" ":: single-site search=git grep"

# the wrap step checks the queue lock: the brief's wrap command carries --queue-doc with THIS leg's doc
has "brief 1 wrap command passes --queue-doc with its own doc" "$(cat "$D1")" "wrap-subtree-check.sh --queue-doc $D1"
has "brief 2 wrap command passes --queue-doc with its own doc" "$(cat "$D2")" "wrap-subtree-check.sh --queue-doc $D2"
has "the leg preface's HALT/WRAP step passes --queue-doc" "$(tr '\n' ' ' < "$HERE/../../../docs/handover/leg-preface.md" | tr -s ' ')" "wrap-subtree-check.sh --queue-doc <doc>"

# the arming gate lints every brief, so a generated brief must also
# arm through the launcher itself (dry-run reaches the gate before it exits).
# (a copy without resume_cwd: the worktree check is a later gate and the copy leaves D1 alone)
printf '%s\n' '#!/usr/bin/env bash' 'echo PROCEED' > "$WORK/preflight.sh"
mkdir -p "$WORK/arm"; grep -v '^resume_cwd:' "$D1" > "$WORK/arm/HIMMEL-9001-N901-copy.md"
rc=0; arm_out="$(HEADED_ARM_WORKER_PREFLIGHT="$WORK/preflight.sh" WORKER_SESSION_REPO="$WORK" bash "$HERE/headed-arm-leg.sh" --dry-run --profile leg-impl HIMMEL-9001-N901 "$WORK/arm/HIMMEL-9001-N901-copy.md" "$WORK/arm/signal" 9999999999 "$WORK/arm/log" claude-sonnet-5-5 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "a generated brief arms through headed-arm-leg.sh (brief-lint gate)" || fail "generated brief refused by headed-arm-leg.sh rc=$rc: $arm_out"

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
# a leg flagged for CI, infra or the environment gets a RED-first line requiring a real-environment fixture.
has "a flagged leg's brief requires a fixture copied from the real environment" "$b2" "copied from the real environment"
lacks "an unflagged leg's brief does not" "$b1" "copied from the real environment"

l1="$(cat "$BUCKET/launch-N901.sh" 2>/dev/null)"; l2="$(cat "$BUCKET/launch-N902.sh" 2>/dev/null)"
lacks "a plain leg's launcher has NO bypass export" "$l1" "HIMMEL_HOOK_INTEGRITY_BYPASS_OK"
has "a hook leg's launcher exports the bypass" "$l2" "export HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1"
has "the launcher calls headed-arm-leg.sh under the repo" "$l1" "$REPO/scripts/handover/console-kit/headed-arm-leg.sh --profile leg-impl --console HIMMEL-nextleg-2026-10-08BZ-roadmap-console"
has "the launcher passes the deadline and model" "$l1" "1791475000"
has "the launcher is syntactically valid bash" "$(bash -n "$BUCKET/launch-N901.sh" 2>&1 && echo ok)" "ok"
[ -x "$BUCKET/launch-N901.sh" ] && pass "launchers are executable" || fail "launcher not executable"
has "it prints one manifest add per leg" "$out" "fleet-manifest.sh add $WORK/fleet.json $D2"
# the printed add line carries --lane, so the manifest never stores lane unknown.
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
has "relays the first leg" "$rb" "SENDMESSAGE to=HIMMEL-9001-N901-plain-fix-2026-10-08"
has "and relays the second leg" "$rb" "SENDMESSAGE to=HIMMEL-9002-N902-hook-fix-2026-10-08"
# the sidecar Telegram /launch-leg checks is written with the launcher.
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

# The nonce <letter>-<label>-<hex> must stay inside the vault token grammar (1-3 upper-case letters, label N + 1-5 digits).
tok() { # <name> <stderr fragment> <gen-briefs args...>: refused, rc 1, nothing written
    local n="$1" frag="$2"; shift 2
    rm -rf "$WORK/bt-tok"
    python3 "$SUT" "$WORK/legs.json" --base 4ccb59d --bucket "$WORK/bt-tok" --repo "$REPO" --handover-root /h --no-worktree "$@" >/dev/null 2>"$WORK/tok.err"; rc=$?
    if [ "$rc" = 1 ] && grep -q "$frag" "$WORK/tok.err" && ! ls "$WORK/bt-tok"/* >/dev/null 2>&1; then pass "$n"; else fail "$n (rc=$rc, err: $(cat "$WORK/tok.err"))"; fi
}
tok "a 4-letter --letter is refused" "letter" --console BZ --letter ABCD
tok "a lower-case --letter is refused" "letter" --console BZ --letter bz
tok "an explicitly empty --letter is refused" "letter" --console HIMMEL-nextleg-2026-10-08BZ-roadmap-console --letter ""
tok "a letter derived from the console name that is 4 letters long is refused" "letter" --console HIMMEL-nextleg-2026-10-08ABCD-roadmap-console
python3 "$SUT" "$WORK/legs.json" --base 4ccb59d --console BZ --letter ABC --bucket "$WORK/bt-ok" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'ABC-N901-' "$WORK/bt-ok"/HIMMEL-9001-N901-*.md && pass "a 3-letter --letter is accepted and minted" || fail "3-letter letter rc=$rc"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["label"]="N123456"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/lbl6.json"
python3 "$SUT" "$WORK/lbl6.json" --base 4ccb59d --console BZ --bucket "$WORK/bt-lbl" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/lbl6.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'label' "$WORK/lbl6.err" && pass "a 6-digit leg label is refused" || fail "6-digit label rc=$rc"

# A per-leg lane key is carried through and validated.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/lane-ok.json"
lout="$(python3 "$SUT" "$WORK/lane-ok.json" --base 4ccb59d --console BZ --bucket "$WORK/b5" --repo "$REPO" --handover-root /h --no-worktree --manifest "$WORK/f5.json" 2>&1)"
has "a leg's lane key is printed as --lane" "$lout" "--lane claudex"
# The launcher itself carries the lane, so a claudex leg needs no hand edit that breaks the sidecar sha.
has "a claudex leg's launcher passes --lane claudex" "$(cat "$WORK/b5/launch-N901.sh")" "--lane claudex "
has "and its sidecar sha matches the launcher bytes" "$(cat "$WORK/f5.launchers.sha256" 2>/dev/null)" "$(sha_of "$WORK/b5/launch-N901.sh")  $WORK/b5/launch-N901.sh"
python3 "$SUT" "$WORK/legs.json" --base 4ccb59d --console BZ --bucket "$WORK/b5n" --repo "$REPO" --handover-root /h --no-worktree --manifest "$WORK/f5n.json" >/dev/null 2>&1
lacks "a native leg's launcher has no --lane" "$(cat "$WORK/b5n/launch-N901.sh")" "--lane"
has "and its sidecar sha matches the launcher bytes" "$(cat "$WORK/f5n.launchers.sha256" 2>/dev/null)" "$(sha_of "$WORK/b5n/launch-N901.sh")  $WORK/b5n/launch-N901.sh"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="Bad Lane"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/lane-bad.json"
python3 "$SUT" "$WORK/lane-bad.json" --base 4ccb59d --console BZ --bucket "$WORK/b6" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/lane-bad.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'lane' "$WORK/lane-bad.err" && [ ! -e "$WORK/b6/launch-N901.sh" ] && pass "an invalid lane is refused before anything is written" || fail "bad lane rc=$rc"
# A non-string lane (a JSON number) is refused too, not a TypeError after the artifacts are written.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]=123; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/lane-num.json"
python3 "$SUT" "$WORK/lane-num.json" --base 4ccb59d --console BZ --bucket "$WORK/b7" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/lane-num.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'lane' "$WORK/lane-num.err" && [ ! -e "$WORK/b7/launch-N901.sh" ] && pass "a numeric lane is refused before anything is written" || fail "numeric lane rc=$rc"
# A trailing newline is not a lowercase word: the whole value must match.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="native\n"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/lane-nl.json"
python3 "$SUT" "$WORK/lane-nl.json" --base 4ccb59d --console BZ --bucket "$WORK/b8" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/lane-nl.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'lane' "$WORK/lane-nl.err" && [ ! -e "$WORK/b8/launch-N901.sh" ] && pass "a lane with a trailing newline is refused" || fail "newline lane rc=$rc"

# an ab_arm key writes the brief ruling line, exports WORKER_SESSION_AUTOCOMPACT_AB in the launcher
# and passes --arm on the printed manifest add line; a bad value is refused; no key changes nothing.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["ab_arm"]="400k"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/ab-ok.json"
about="$(python3 "$SUT" "$WORK/ab-ok.json" --base 4ccb59d --console BZ --bucket "$WORK/b9" --repo "$REPO" --handover-root /h --no-worktree --manifest "$WORK/f9.json" 2>&1)"
abdoc="$(cat "$WORK/b9/HIMMEL-9001-N901-plain-fix-"*.md 2>/dev/null)"
has "ab_arm 400k: the brief carries the ruling line" "$abdoc" "> **Context:** ab-400k — operator-ruling: HIMMEL-5193"
has "ab_arm 400k: the launcher exports WORKER_SESSION_AUTOCOMPACT_AB=400000" "$(cat "$WORK/b9/launch-N901.sh" 2>/dev/null)" "export WORKER_SESSION_AUTOCOMPACT_AB=400000"
has "ab_arm 400k: the manifest add line passes --arm 400k" "$about" "--arm 400k"
bash "$HERE/brief-lint.sh" "$WORK/b9/HIMMEL-9001-N901-plain-fix-"*.md 2>"$WORK/lint-ab.err"; rc=$?
[ "$rc" = 0 ] && pass "ab_arm brief passes brief-lint.sh" || fail "ab_arm brief-lint rc=$rc: $(cat "$WORK/lint-ab.err")"
lacks "no ab_arm: the plain brief has no Context line" "$b1" "operator-ruling: HIMMEL-5193"
lacks "no ab_arm: the plain launcher exports no arm" "$l1" "WORKER_SESSION_AUTOCOMPACT_AB"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["ab_arm"]="500k"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/ab-bad.json"
python3 "$SUT" "$WORK/ab-bad.json" --base 4ccb59d --console BZ --bucket "$WORK/b10" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ab-bad.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'ab_arm' "$WORK/ab-bad.err" && [ ! -e "$WORK/b10/launch-N901.sh" ] && pass "an invalid ab_arm is refused before anything is written" || fail "bad ab_arm rc=$rc"

# an opus (or fable) leg needs a tier {category, reason}; without it nothing is
# written (exit 1), with it the brief carries the Tier line headed-arm-leg.sh's own gate accepts.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["model"]="claude-opus-5-5"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/opus-no.json"
python3 "$SUT" "$WORK/opus-no.json" --base 4ccb59d --console BZ --bucket "$WORK/b11" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/opus-no.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'tier' "$WORK/opus-no.err" && [ ! -e "$WORK/b11/launch-N901.sh" ] && ! ls "$WORK/b11"/*.md >/dev/null 2>&1 && pass "an opus leg without a tier is refused and nothing is written" || fail "opus without tier rc=$rc"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["model"]="claude-opus-5-5"; l[0]["tier"]={"category":"design","reason":"multi-step design: the gate shape is open"}; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/opus-ok.json"
python3 "$SUT" "$WORK/opus-ok.json" --base 4ccb59d --console BZ --bucket "$WORK/b12" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/opus-ok.err"; rc=$?
[ "$rc" = 0 ] && pass "an opus leg with a tier generates (rc 0)" || fail "opus with tier rc=$rc: $(cat "$WORK/opus-ok.err")"
TD="$(find "$WORK/b12" -name 'HIMMEL-9001-N901-plain-fix-*.md' 2>/dev/null | head -n 1)"
has "the opus brief carries the Tier line" "$(cat "$TD" 2>/dev/null)" "> **Tier:** opus — design: multi-step design: the gate shape is open"
# the launcher's own gate is the check: a copy without resume_cwd (as in the arming row above) arms, not refused.
mkdir -p "$WORK/tier-arm"; grep -v '^resume_cwd:' "$TD" > "$WORK/tier-arm/HIMMEL-9001-N901-copy.md"
rc=0; tier_out="$(HEADED_ARM_WORKER_PREFLIGHT="$WORK/preflight.sh" WORKER_SESSION_REPO="$WORK" bash "$HERE/headed-arm-leg.sh" --dry-run --profile leg-impl HIMMEL-9001-N901 "$WORK/tier-arm/HIMMEL-9001-N901-copy.md" "$WORK/tier-arm/signal" 9999999999 "$WORK/tier-arm/log" claude-opus-5-5 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "headed-arm-leg.sh's Tier gate accepts the generated opus brief" || fail "opus brief refused by headed-arm-leg.sh rc=$rc: $tier_out"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["model"]="claude-opus-5-5"; l[0]["tier"]={"category":"cheap","reason":"x"}; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/tier-badcat.json"
python3 "$SUT" "$WORK/tier-badcat.json" --base 4ccb59d --console BZ --bucket "$WORK/b13" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/tier-badcat.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'tier.category' "$WORK/tier-badcat.err" && pass "a tier category outside the four tags is refused" || fail "bad tier category rc=$rc"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["model"]="claude-opus-5-5"; l[0]["tier"]={"category":"design","reason":"  "}; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/tier-blank.json"
python3 "$SUT" "$WORK/tier-blank.json" --base 4ccb59d --console BZ --bucket "$WORK/b14" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/tier-blank.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'tier.reason' "$WORK/tier-blank.err" && pass "a blank tier reason is refused" || fail "blank tier reason rc=$rc"
lacks "a sonnet leg's brief has no Tier line" "$b1" "**Tier:**"

# A lane worker (lane other than native or claudex) cannot read the state repo, so a leg whose
# text points at a path under the handover root is refused and nothing is written; a native or claudex leg may.
SPEC="$WORK/handovers/yotamleo/himmel/specs/plan/2026-08-10-plan.md"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="openrouter"; l[0]["model"]="claude-sonnet-5-5"; l[0]["why"]="Read this first - it is the spec: "+sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/lane-spec.json" "$SPEC"
python3 "$SUT" "$WORK/lane-spec.json" --base 4ccb59d --console BZ --bucket "$WORK/b15" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/lane-spec.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'handover root' "$WORK/lane-spec.err" && [ ! -e "$WORK/b15/launch-N901.sh" ] && ! ls "$WORK/b15"/*.md >/dev/null 2>&1 && pass "a lane-worker leg pointing at a handover-root path is refused and nothing is written" || fail "lane worker spec path rc=$rc"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="openrouter"; l[0]["model"]="claude-sonnet-5-5"; l[0]["tier"]={"category":"design","reason":"spec at "+sys.argv[3]}; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/lane-tier.json" "$SPEC"
python3 "$SUT" "$WORK/lane-tier.json" --base 4ccb59d --console BZ --bucket "$WORK/b18" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/lane-tier.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'tier.reason' "$WORK/lane-tier.err" && pass "a lane-worker tier.reason naming a handover-root path is refused" || fail "lane worker tier reason rc=$rc"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["why"]="Read this first - it is the spec: "+sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/native-spec.json" "$SPEC"
python3 "$SUT" "$WORK/native-spec.json" --base 4ccb59d --console BZ --bucket "$WORK/b16" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/native-spec.err"; rc=$?
[ "$rc" = 0 ] && pass "a native leg may point at a handover-root path (rc 0)" || fail "native spec path rc=$rc: $(cat "$WORK/native-spec.err")"
# A claudex leg runs with the native leg-impl settings, the project's additionalDirectories and the qmd MCP config, so it reads the handover root too.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; l[0]["why"]="Read this first - it is the spec: "+sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/claudex-spec.json" "$SPEC"
python3 "$SUT" "$WORK/claudex-spec.json" --base 4ccb59d --console BZ --bucket "$WORK/b19" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/claudex-spec.err"; rc=$?
[ "$rc" = 0 ] && grep -q -- "$SPEC" "$WORK/b19"/*.md 2>/dev/null && pass "a claudex leg may point at a handover-root path (rc 0, path kept in the brief)" || fail "claudex spec path rc=$rc: $(cat "$WORK/claudex-spec.err")"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/lane-ok.json"
python3 "$SUT" "$WORK/lane-ok.json" --base 4ccb59d --console BZ --bucket "$WORK/b17" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/lane-ok.err"; rc=$?
[ "$rc" = 0 ] && pass "a lane-worker leg with no handover-root path generates (rc 0)" || fail "lane worker clean rc=$rc: $(cat "$WORK/lane-ok.err")"
# A non-native leg with no model key takes the lane's model: no native model argument in the launcher, the lane model in the brief header.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/lane-nomodel.json"
python3 "$SUT" "$WORK/lane-nomodel.json" --base 4ccb59d --console BZ --bucket "$WORK/b20" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>&1
lacks "a claudex leg with no model key passes no native model argument" "$(cat "$WORK/b20/launch-N901.sh")" "claude-sonnet-5-5"
lacks "a claudex leg with no model key leaves the lane default to headed-arm-leg" "$(cat "$WORK/b20/launch-N901.sh")" "gpt-6.1-sol"
has "its brief header names the lane model and the lane" "$(cat "$WORK/b20"/HIMMEL-9001-N901-*.md)" "gpt-6.1-sol, claudex"
# A claudex leg's named model is the launcher's trailing model argument, and headed-arm-leg.sh hands it to
# scripts/claude-codex as CODEX_MODEL: the launcher's own arguments, run as a dry run.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; l[0]["model"]="gpt-6-astra"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/lane-astra.json"
python3 "$SUT" "$WORK/lane-astra.json" --base 4ccb59d --console BZ --bucket "$WORK/b20a" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>&1
has "a claudex leg with a model key passes it as the launcher's model argument" "$(grep -F headed-arm-leg.sh "$WORK/b20a/launch-N901.sh")" '.log" gpt-6-astra >'
mkdir -p "$WORK/astra-arm"; grep -v '^resume_cwd:' "$(find "$WORK/b20a" -name 'HIMMEL-9001-N901-*.md' | head -n 1)" > "$WORK/astra-arm/HIMMEL-9001-N901-copy.md"
rc=0; astra_out="$(HEADED_ARM_WORKER_PREFLIGHT="$WORK/preflight.sh" WORKER_SESSION_REPO="$WORK" bash "$HERE/headed-arm-leg.sh" --dry-run --lane claudex --profile leg-impl HIMMEL-9001-N901 "$WORK/astra-arm/HIMMEL-9001-N901-copy.md" "$WORK/astra-arm/signal" 9999999999 "$WORK/astra-arm/log" gpt-6-astra 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "the generated claudex brief arms with the named model" || fail "claudex brief refused by headed-arm-leg.sh rc=$rc: $astra_out"
has "and the named model reaches the leg as CODEX_MODEL" "$astra_out" "CODEX_MODEL=gpt-6-astra"
# An effort key exports WORKER_SESSION_EFFORT in the launcher.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; l[0]["effort"]="high"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/lane-effort.json"
python3 "$SUT" "$WORK/lane-effort.json" --base 4ccb59d --console BZ --bucket "$WORK/b21" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>&1
has "an effort key exports WORKER_SESSION_EFFORT in the launcher" "$(cat "$WORK/b21/launch-N901.sh")" "export WORKER_SESSION_EFFORT=high"
# An opus model on a non-native lane is refused before anything is written.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; l[0]["model"]="claude-opus-5-5"; l[0]["tier"]={"category":"design","reason":"multi-step design"}; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/lane-opus.json"
python3 "$SUT" "$WORK/lane-opus.json" --base 4ccb59d --console BZ --bucket "$WORK/b22" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/lane-opus.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'lane' "$WORK/lane-opus.err" && [ ! -e "$WORK/b22/launch-N901.sh" ] && pass "an opus model on a non-native lane is refused before anything is written" || fail "opus on claudex rc=$rc"

# The scope's LAST completes-ticket value becomes one dedicated machine-readable
# line (merge-on-green.sh reads it from the leg doc); a scope stating neither writes no line.
ct_brief() { # <scope text> <bucket>
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["scope"]=sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/ct.json" "$1"
    python3 "$SUT" "$WORK/ct.json" --base 4ccb59d --console BZ --bucket "$2" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ct.err" || fail "completes-ticket scope generation rc=$?: $(cat "$WORK/ct.err")"
    cat "$2"/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null
}
ct_count() { printf '%s\n' "$1" | grep -c '^> \*\*Completes ticket:\*\* '; }
ct_no="$(ct_brief 'one PR. completes-ticket: no' "$WORK/ct1")"
has "scope ending completes-ticket: no writes the no line" "$ct_no" "> **Completes ticket:** no"
[ "$(ct_count "$ct_no")" = 1 ] && pass "exactly one Completes ticket line (no)" || fail "Completes ticket line count (no) = $(ct_count "$ct_no")"
ct_yes="$(ct_brief 'one PR. completes-ticket: yes' "$WORK/ct2")"
has "scope ending completes-ticket: yes writes the yes line" "$ct_yes" "> **Completes ticket:** yes"
[ "$(ct_count "$ct_yes")" = 1 ] && pass "exactly one Completes ticket line (yes)" || fail "Completes ticket line count (yes) = $(ct_count "$ct_yes")"
ct_last="$(ct_brief 'completes-ticket: yes in the middle, but later completes-ticket: no' "$WORK/ct3")"
has "the LAST completes-ticket value wins" "$ct_last" "> **Completes ticket:** no"
lacks "an earlier, overridden value writes no yes line" "$ct_last" "> **Completes ticket:** yes"
ct_none="$(ct_brief 'one PR, nothing stated' "$WORK/ct4")"
[ "$(ct_count "$ct_none")" = 0 ] && pass "a scope stating neither writes no Completes ticket line" || fail "Completes ticket line written without a stated value"
# The Ship step states the same value and the matching merge command (one value per brief).
lacks "a completes-ticket: no brief states no 'completes-ticket: yes' anywhere" "$ct_no" "completes-ticket: yes"
ship_no="$(printf '%s\n' "$ct_no" | grep '^> 4\. Ship:')"
lacks "a completes-ticket: no Ship step has no --jira-transition" "$ship_no" "--jira-transition"
has "a completes-ticket: no Ship step merges bare" "$ship_no" 'merge-on-green.sh`'
has "a completes-ticket: no Ship step leaves the ticket In Progress" "$ship_no" "In Progress"
ship_yes="$(printf '%s\n' "$ct_yes" | grep '^> 4\. Ship:')"
has "a completes-ticket: yes Ship step keeps --jira-transition" "$ship_yes" "merge-on-green.sh --jira-transition"
has "a completes-ticket: yes Ship step states yes" "$ship_yes" "completes-ticket: yes"
ship_last="$(printf '%s\n' "$ct_last" | grep '^> 4\. Ship:')"
lacks "the LAST value (no) also drives the Ship step" "$ship_last" "--jira-transition"
has "the LAST value (no) writes the bare-merge Ship wording" "$ship_last" "completes-ticket: no (leave the ticket In Progress after MERGED)"
ship_none="$(printf '%s\n' "$ct_none" | grep '^> 4\. Ship:')"
has "a scope stating neither keeps the yes Ship step" "$ship_none" "merge-on-green.sh --jira-transition"
# shellcheck disable=SC2016 # literal backticks in the expected brief text
has "the yes Ship step names the relative merge spelling" "$ship_yes" '`bash scripts/handover/merge-on-green.sh --jira-transition`'
# shellcheck disable=SC2016 # literal backticks in the expected brief text
has "the no Ship step names the relative merge spelling" "$ship_no" '`bash scripts/handover/merge-on-green.sh`'
# shellcheck disable=SC2016 # literal backticks in the expected brief text
has "the yes Ship step ends the merge with the --go GO file" "$ship_yes" 'then `--go <the GO file'
# shellcheck disable=SC2016 # literal backticks in the expected brief text
has "the no Ship step ends the merge with the --go GO file" "$ship_no" 'then `--go <the GO file'
# A claudex leg's classifier refuses merge-path actions, so its Ship step ends at READY: no
# merge command anywhere in the brief, the console is named as the merger, and the leg waits
# for MERGED. A native leg of the same scope keeps the merge step (asserted above).
cx_brief() { # <completes value> <bucket>
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; l[0]["scope"]="one PR. completes-ticket: "+sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/cx.json" "$1"
    python3 "$SUT" "$WORK/cx.json" --base 4ccb59d --console BZ --bucket "$2" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/cx.err" || fail "claudex ship generation rc=$?: $(cat "$WORK/cx.err")"
    cat "$2"/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null
}
cx_no="$(cx_brief no "$WORK/cx1")"
ship_cx="$(printf '%s\n' "$cx_no" | grep '^> 4\. Ship:')"
lacks "a claudex Ship step has no merge-on-green.sh" "$ship_cx" "merge-on-green.sh"
lacks "a claudex Ship step has no merge-on-GO clause" "$ship_cx" "Merge only on GO"
has "a claudex Ship step names the console as the merger" "$ship_cx" "the console merges"
has "a claudex Ship step waits for MERGED" "$ship_cx" "MERGED #<pr>"
has "a claudex Ship step still ends at READY" "$ship_cx" 'READY <pr> <full-40-hex-head> GREEN'
has "a claudex completes-ticket: no Ship step keeps the clause" "$ship_cx" "completes-ticket: no"
lacks "the claudex brief carries no merge-on-green.sh anywhere" "$cx_no" "merge-on-green.sh"
cx_yes="$(cx_brief yes "$WORK/cx2")"
ship_cxy="$(printf '%s\n' "$cx_yes" | grep '^> 4\. Ship:')"
lacks "a claudex completes-ticket: yes Ship step has no merge-on-green.sh" "$ship_cxy" "merge-on-green.sh"
has "a claudex completes-ticket: yes Ship step keeps the clause" "$ship_cxy" "completes-ticket: yes"
bash "$HERE/brief-lint.sh" "$WORK"/cx1/HIMMEL-9001-N901-plain-fix-*.md 2>"$WORK/lint-cx.err"; rc=$?
[ "$rc" = 0 ] && pass "a claudex brief with the console-merges Ship step passes brief-lint.sh" || fail "claudex brief-lint rc=$rc: $(cat "$WORK/lint-cx.err")"
bash "$HERE/brief-lint.sh" "$WORK"/ct1/HIMMEL-9001-N901-plain-fix-*.md 2>"$WORK/lint-ct.err"; rc=$?
[ "$rc" = 0 ] && pass "a brief with the Completes ticket line passes brief-lint.sh" || fail "Completes ticket brief-lint rc=$rc: $(cat "$WORK/lint-ct.err")"

# A completes-ticket value other than yes or no is refused (it used to fall through to the closing
# merge): nothing is written, and the message names the leg label and the value. Case is ignored.
# shellcheck disable=SC2016  # the backticks are literal characters in the value under test
for bad in partial maybe yess '"no"' '`yes`'; do
    rm -rf "$WORK/ctb-out"
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["scope"]="one PR. completes-ticket: "+sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/ctb.json" "$bad"
    python3 "$SUT" "$WORK/ctb.json" --base 4ccb59d --console BZ --bucket "$WORK/ctb-out" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ctb.err"; rc=$?
    [ "$rc" = 1 ] && grep -q "N901" "$WORK/ctb.err" && grep -qF -- "$bad" "$WORK/ctb.err" && pass "completes-ticket: $bad is refused naming the leg and the value" || fail "completes-ticket: $bad rc=$rc: $(cat "$WORK/ctb.err")"
    [ ! -e "$WORK/ctb-out/launch-N901.sh" ] && ! ls "$WORK/ctb-out"/*.md >/dev/null 2>&1 && pass "and nothing is written for $bad" || fail "files written for completes-ticket: $bad"
done
ct_mixed="$(ct_brief 'one PR. completes-ticket: YES' "$WORK/ct5")"
has "an upper-case YES still writes the yes line" "$ct_mixed" "> **Completes ticket:** yes"
ct_mixed="$(ct_brief 'one PR. completes-ticket: No' "$WORK/ct6")"
has "a mixed-case No still writes the no line" "$ct_mixed" "> **Completes ticket:** no"
ct_nl="$(ct_brief "one PR. completes-ticket:
no" "$WORK/ct7")"
has "a value on the next line is read, not refused as empty" "$ct_nl" "> **Completes ticket:** no"
# A bad value earlier in the scope is refused even when a good one comes last.
rm -rf "$WORK/ctb-early"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["scope"]="completes-ticket: partial, later completes-ticket: no"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/ctb.json"
python3 "$SUT" "$WORK/ctb.json" --base 4ccb59d --console BZ --bucket "$WORK/ctb-early" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ctb.err"; rc=$?
[ "$rc" = 1 ] && pass "an earlier bad value is refused even when the last value is no" || fail "early bad value rc=$rc"

# Windows and WSL are dropped: a leg whose title, desc, why or scope names them is refused (rc 1,
# nothing written) unless it sets platform_removal AND its title says it removes something.
# pl_gen <title> <field> <value> [platform_removal]: one leg with <field> set to <value>.
pl_gen() {
    rm -rf "$WORK/pl-out"
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0][sys.argv[3]]=sys.argv[4]
if len(sys.argv)>5: l[0]["platform_removal"]=True if sys.argv[5]=="yes" else sys.argv[5]
json.dump(l,open(sys.argv[2],"w"))' "$WORK/legs.json" "$WORK/pl.json" "$@"
    python3 "$SUT" "$WORK/pl.json" --base 4ccb59d --console BZ --bucket "$WORK/pl-out" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/pl.err"
}
pl_written() { [ -n "$(find "$WORK/pl-out" -type f -print -quit 2>/dev/null)" ]; }
pl_complete() { ls "$WORK/pl-out"/*.md >/dev/null 2>&1 && ls "$WORK/pl-out"/launch-*.sh >/dev/null 2>&1; }
pl_gen title 'AG-UI session name handles Windows cwd separators'; rc=$?
[ "$rc" = 1 ] && grep -q "N901" "$WORK/pl.err" && grep -qi "windows" "$WORK/pl.err" && ! pl_written && pass "a leg titled with Windows is refused, naming the leg, nothing written" || fail "windows title rc=$rc: $(cat "$WORK/pl.err")"
pl_gen desc 'run the WSL codex lane'; rc=$?
[ "$rc" = 1 ] && ! pl_written && pass "a desc naming WSL is refused" || fail "wsl desc rc=$rc"
pl_gen scope 'the .ps1 twin'; rc=$?
[ "$rc" = 1 ] && ! pl_written && pass "a scope naming a .ps1 file is refused" || fail "ps1 scope rc=$rc"
pl_gen why 'it breaks under Git Bash'; rc=$?
[ "$rc" = 1 ] && ! pl_written && pass "a why naming Git Bash is refused" || fail "git bash why rc=$rc"
pl_gen title 'Remove Windows leftovers' yes; rc=$?
[ "$rc" = 0 ] && pl_complete && pass "a Windows removal leg with platform_removal true is accepted" || fail "removal leg rc=$rc: $(cat "$WORK/pl.err")"
pl_gen title 'Fix Windows leftovers' yes; rc=$?
[ "$rc" = 1 ] && grep -q "platform_removal" "$WORK/pl.err" && ! pl_written && pass "platform_removal true on a non-removal title is refused" || fail "non-removal platform_removal rc=$rc: $(cat "$WORK/pl.err")"
for bad in false yes 1; do
    pl_gen title 'Remove Windows leftovers' "$bad"; rc=$?
    case "$bad" in yes) want=0 ;; *) want=1 ;; esac
    [ "$rc" = "$want" ] && pass "platform_removal $bad on a removal title exits $want (only boolean true is the exemption)" || fail "platform_removal $bad rc=$rc"
done
for bad in 'Fix Windows dropdown rendering' 'Fix the Windows cleanroom'; do
    pl_gen title "$bad" yes; rc=$?
    [ "$rc" = 1 ] && ! pl_written && pass "platform_removal true on '$bad' is refused (no removal verb)" || fail "'$bad' with platform_removal rc=$rc"
done
for good in 'Drop Windows support' 'Sweep Windows leftovers' 'Retire the WSL lane' 'Delete the .ps1 twins' 'Clean up Windows paths' 'Removing Windows code'; do
    pl_gen title "$good" yes; rc=$?
    [ "$rc" = 0 ] && pl_complete && pass "platform_removal true on '$good' is accepted" || fail "'$good' with platform_removal rc=$rc: $(cat "$WORK/pl.err")"
done
for ok in 'Close WRAPPED console windows' 'Stop leg windows piling up' 'Spread work over 5-hour windows' 'Trim the context-windows report'; do
    pl_gen title "$ok"; rc=$?
    [ "$rc" = 0 ] && pl_complete && pass "'$ok' is console wording, not the OS" || fail "'$ok' refused rc=$rc: $(cat "$WORK/pl.err")"
done
# Fail closed: with the pattern file gone the script exits 2 rather than briefing unfiltered.
NF="$WORK/nopat"; mkdir -p "$NF"; cp "$SUT" "$NF/gen-briefs.py"
python3 "$NF/gen-briefs.py" "$WORK/legs.json" --base 4ccb59d --console BZ --bucket "$NF/out" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "a missing pattern file exits 2" || fail "missing pattern file rc=$rc"
pl_gen title 'Remove runtime Windows compatibility'; rc=$?
[ "$rc" = 1 ] && ! pl_written && pass "'runtime Windows' is not excused by the time-window qualifier" || fail "runtime Windows rc=$rc"
for ok in 'cap the context window' 'widen the time window' 'Windowed rate limit' 'the context windows budget'; do
    pl_gen title "$ok"; rc=$?
    [ "$rc" = 0 ] && pl_complete && pass "'$ok' is not a platform mention" || fail "'$ok' refused rc=$rc: $(cat "$WORK/pl.err")"
done

# Every leg and console pays these two files on every turn: keep the always-on core small
# (rarely-read rules live in docs/handover/leg-sections/ and console-sections/).
HANDOVER_DOCS="${HANDOVER_DOCS:-$HERE/../../../docs/handover}"
for budget in "leg-preface.md:12352" "console-template.md:16384"; do
    f="${budget%%:*}"; max="${budget##*:}"
    size="$(wc -c < "$HANDOVER_DOCS/$f" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$size" ] && [ "$size" -le "$max" ] && pass "$f is within its byte budget ($size <= $max)" || fail "$f is over its byte budget (${size:-missing} > $max)"
done

tr '\n' ' ' < "$HANDOVER_DOCS/leg-preface.md" | grep -Eq 'ONE +turn.*text-only turn' \
    && pass "leg-preface.md tells a leg to batch tool calls into ONE turn and skip text-only turns" \
    || fail "leg-preface.md lacks the batch-tool-calls / no text-only turn rule"

# --- bare --bucket resolves under the handover root; --no-worktree needs a real worktree ---
# (the rows above stub the worktree step, so they skip the existing-worktree check)
mkdir -p "$WORK/hr/tester" "$WORK/gitcwd"
git -C "$WORK/gitcwd" init -q 2>/dev/null
rc=0; (cd "$WORK/gitcwd" && USER_SLUG=tester python3 "$SUT" "$WORK/legs.json" --base 4ccb59d --console BZ --bucket himmel --repo "$REPO" --handover-root "$WORK/hr" --no-worktree --manifest "$WORK/fb.json" >"$WORK/bb.out" 2>"$WORK/bb.err") || rc=$?
[ "$rc" = 0 ] && [ -f "$WORK/hr/tester/himmel/launch-N901.sh" ] && pass "a bare --bucket resolves to <handover-root>/<user>/<bucket>" || fail "bare bucket rc=$rc: $(cat "$WORK/bb.err")"
[ ! -e "$WORK/gitcwd/himmel" ] && pass "and writes no stray dir under the cwd" || fail "stray himmel/ dir under the cwd"
grep -q -- "$WORK/hr/tester/himmel/HIMMEL-9001-N901" "$WORK/hr/tester/himmel/launch-N901.sh" 2>/dev/null && pass "the launcher passes an absolute doc path" || fail "launcher doc path not absolute"
rc=0; (cd "$WORK" && python3 "$SUT" "$WORK/legs.json" --base 4ccb59d --console BZ --bucket ./gitcwd/rel --repo "$REPO" --handover-root "$WORK/hr" --no-worktree >"$WORK/rel.out" 2>"$WORK/rel.err") || rc=$?
[ "$rc" = 1 ] && grep -q 'inside a git checkout' "$WORK/rel.err" && [ ! -e "$WORK/gitcwd/rel" ] && pass "a path --bucket inside a git checkout (outside the handover root) is refused" || fail "git-checkout bucket rc=$rc: $(cat "$WORK/rel.err")"
ln -s "$WORK/gitcwd" "$WORK/hr/tester/link"
rc=0; python3 "$SUT" "$WORK/legs.json" --base 4ccb59d --console BZ --bucket "$WORK/hr/tester/link/sub" --repo "$REPO" --handover-root "$WORK/hr" --no-worktree >/dev/null 2>"$WORK/lnk.err" || rc=$?
[ "$rc" = 1 ] && grep -q 'inside a git checkout' "$WORK/lnk.err" && [ ! -e "$WORK/gitcwd/sub" ] && pass "a bucket under a handover-root symlink into a git checkout is refused" || fail "symlink bucket rc=$rc: $(cat "$WORK/lnk.err")"
rc=0; python3 "$SUT" "$WORK/legs.json" --base 4ccb59d --console BZ --bucket "$WORK/hr/tester/abs" --repo "$REPO" --handover-root "$WORK/hr" --no-worktree >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && pass "RED control: an absolute --bucket works unchanged" || fail "absolute bucket rc=$rc"
rc=0; (unset GEN_BRIEFS_NO_WT_CHECK; python3 "$SUT" "$WORK/legs.json" --base 4ccb59d --console BZ --bucket "$WORK/nw" --repo "$REPO" --handover-root "$WORK/hr" --no-worktree >"$WORK/nw.out" 2>"$WORK/nw.err") || rc=$?
[ "$rc" = 1 ] && [ ! -e "$WORK/nw/launch-N901.sh" ] && pass "--no-worktree with a missing worktree exits 1 and writes nothing" || fail "no-worktree rc=$rc"
has "and prints the exact worktree.sh line" "$(cat "$WORK/nw.err")" "bash scripts/worktree.sh new fix/himmel-9001-plain-fix --no-prune"
NWREPO="$WORK/nwrepo"; git init -q "$NWREPO" && git -C "$NWREPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$NWREPO" worktree add -q "$NWREPO/.claude/worktrees/fix+himmel-9001-plain-fix" -b fix/himmel-9001-plain-fix 2>/dev/null
git -C "$NWREPO" worktree add -q "$NWREPO/.claude/worktrees/fix+himmel-9002-hook-fix" -b fix/himmel-9002-hook-fix 2>/dev/null
rc=0; (unset GEN_BRIEFS_NO_WT_CHECK; python3 "$SUT" "$WORK/legs.json" --base 4ccb59d --console BZ --bucket "$WORK/hr/tester/nw2" --repo "$NWREPO" --handover-root "$WORK/hr" --no-worktree >/dev/null 2>"$WORK/nw2.err") || rc=$?
[ "$rc" = 0 ] && pass "RED control: --no-worktree with existing worktrees works unchanged" || fail "existing worktrees rc=$rc: $(cat "$WORK/nw2.err")"

# --- the rm kind: a release-manager brief filled from docs/handover/rm-brief-template.md ---
cat > "$WORK/rm.json" <<EOF
[
 {"kind":"rm","label":"N910","keys":["HIMMEL-9010"],"slug":"rm","release":"R1","versions":"v1 + v2, current v1","epoch":3,"state_dir":"$WORK/hr/tester/himmel/release/R1","mode":"observe"}
]
EOF
: > "$WT_LOG"
rmout="$(python3 "$SUT" "$WORK/rm.json" --base 4ccb59d --console HIMMEL-nextleg-2026-10-08BZ-roadmap-console --bucket "$WORK/rmb" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/hr" --work-dir "$WORK/w" --deadline 1791475000 --manifest "$WORK/rmf.json" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "an rm leg generates (rc 0)" || fail "rm rc=$rc: $rmout"
RMD="$WORK/rmb/HIMMEL-9010-N910-rm-R1-2026-10-08.md"
[ -f "$RMD" ] && [ -f "$WORK/rmb/launch-N910.sh" ] && pass "an rm leg writes <KEY>-<label>-rm-<R>-<date>.md and its launcher" || fail "rm files missing in $WORK/rmb"
[ ! -s "$WT_LOG" ] && pass "an rm leg creates no worktree" || fail "worktree stub called: $(cat "$WT_LOG")"
RMB="$(sed 's/^> *//' "$RMD" 2>/dev/null | tr '\n' ' ' | tr -s ' ')"
has "the rm brief carries the release and its versions" "$RMB" 'Release manager for R1 (v1 + v2, current v1)'
has "the rm brief names the lease epoch to acquire" "$RMB" '--expect-epoch 3'
has "the rm brief names the state directory" "$RMB" "State directory \`$WORK/hr/tester/himmel/release/R1\`"
has "the rm brief carries a minted token in the RM shape" "$RMB" 'BZ-RM-R1-'
has "the rm brief carries the opus tier line" "$RMB" '**Tier:** opus'
has "the rm brief resumes in the release scratch dir" "$(head -3 "$RMD" 2>/dev/null)" "/.cache/himmel/rm/R1/scratch"
if sed 's/REQ <id>/REQ/' "$RMD" 2>/dev/null | grep -Eq '<[A-Za-z$]'; then fail "the rm brief keeps an unfilled placeholder: $(sed 's/REQ <id>/REQ/' "$RMD" | grep -E '<[A-Za-z$]' | head -2)"; else pass "the rm brief keeps no unfilled placeholder"; fi
RML="$(cat "$WORK/rmb/launch-N910.sh" 2>/dev/null)"
has "the rm launcher arms the release-manager profile for its release" "$RML" '--profile release-manager --rm-release R1'
has "the rm launcher skips the prior-art lint an rm brief has no field for" "$RML" '--no-prior-art-check'
has "the printed manifest line is native" "$rmout" "--lane native"
rmbad() { # <name> <python edit> <stderr fragment>: refused, rc 1, nothing written
    local n="$1" edit="$2" frag="$3"
    rm -rf "$WORK/rmbad"
    python3 -I -c "import json,sys; l=json.load(open(sys.argv[1])); d=l[0]; $edit; json.dump(l,open(sys.argv[2],'w'))" "$WORK/rm.json" "$WORK/rmbad.json"
    python3 "$SUT" "$WORK/rmbad.json" --base 4ccb59d --console BZ --bucket "$WORK/rmbad" --repo "$REPO" --handover-root /h >/dev/null 2>"$WORK/rmbad.err"; rc=$?
    if [ "$rc" = 1 ] && grep -q "$frag" "$WORK/rmbad.err" && ! ls "$WORK/rmbad"/* >/dev/null 2>&1; then pass "$n"; else fail "$n (rc=$rc, err: $(cat "$WORK/rmbad.err"))"; fi
}
rmbad "an rm leg with a release holding a slash is refused" 'd["release"]="a/b"' "release"
rmbad "an rm leg with a non-integer epoch is refused" 'd["epoch"]="three"' "epoch"
rmbad "an rm leg with a negative epoch is refused" 'd["epoch"]=-1' "epoch"
rmbad "an rm leg with a mode other than observe or live is refused" 'd["mode"]="dry"' "mode"
rmbad "an rm leg missing its state_dir is refused" 'del d["state_dir"]' "state_dir"
rmbad "an rm leg on a non-native lane is refused" 'd["lane"]="claudex"' "lane"
rmbad "an rm leg whose state_dir names another release is refused" 'd["state_dir"]="/h/tester/himmel/release/R2"' "must end in release/R1"
rmbad "an rm leg whose state_dir is not under a release directory is refused" 'd["state_dir"]="/h/tester/himmel/R1"' "must end in release/R1"
rmbad "an rm leg on a non-opus model is refused" 'd["model"]="claude-sonnet-5-5"' "opus"

# --- a brief naming VM work carries the guest-exec line; one that does not stays without it ---
python3 -I -c "import json,sys; l=json.load(open(sys.argv[1])); l[0]['why']='the install must be proven on a test VM first'; json.dump(l,open(sys.argv[2],'w'))" "$WORK/legs.json" "$WORK/vmlegs.json"
rc=0; python3 "$SUT" "$WORK/vmlegs.json" --base 4ccb59d --console BZ --bucket "$WORK/vmb" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/hr" --work-dir "$WORK/w" --deadline 1791475000 >"$WORK/vm.out" 2>&1 || rc=$?
[ "$rc" = 0 ] && pass "a legs file naming VM work generates (rc 0)" || fail "vm legs rc=$rc: $(cat "$WORK/vm.out")"
VMB1="$(tr '\n' ' ' < "$WORK/vmb/HIMMEL-9001-N901-plain-fix-2026-10-08.md" 2>/dev/null | tr -s ' ')"
VMB2="$(tr '\n' ' ' < "$WORK/vmb/HIMMEL-9002-N902-hook-fix-2026-10-08.md" 2>/dev/null | tr -s ' ')"
has "a brief naming VM work says to drive the guest only through guest-exec.sh" "$VMB1" "drive the guest only through guest-exec.sh"
lacks "a brief that names no VM work does not carry the guest-exec line" "$VMB2" "guest-exec.sh"
bash "$HERE/brief-lint.sh" "$WORK/vmb/HIMMEL-9001-N901-plain-fix-2026-10-08.md" 2>"$WORK/vmlint.err"; rc=$?
[ "$rc" = 0 ] && pass "the VM brief passes brief-lint.sh" || fail "vm brief brief-lint rc=$rc: $(cat "$WORK/vmlint.err")"

python3 "$SUT" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "no arguments is a usage error (rc 2)" || fail "usage rc=$rc"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
