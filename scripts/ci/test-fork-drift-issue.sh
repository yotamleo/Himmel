#!/usr/bin/env bash
# Smoke test for scripts/ci/fork-drift-issue.sh. Uses DRY_RUN=1
# so no gh, no auth, no network — asserts the issue-state decisions per guard
# exit code from the emitted DRY: gh command lines.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ci/fork-drift-issue.sh"
fails=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

REP="$(mktemp)"; printf 'graphify: BEHIND (v0.9.16)\n' >"$REP"

# has/hasnt: assert a substring is present / absent in captured output.
has()   { if grepq "$2" "$1"; then ok "$3"; else bad "$3; out: $2"; fi; }
hasnt() { if grepq "$2" "$1"; then bad "$3; out: $2"; else ok "$3"; fi; }

# 1. Syntax.
if bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "syntax"; fi

# 2. Bad args -> usage exit 2.
bash "$SCRIPT" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "no args -> exit 2"; else bad "no args exit=$rc (expected 2)"; fi
bash "$SCRIPT" 2 /no/such/file >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "missing report file -> exit 2"; else bad "missing report exit=$rc (expected 2)"; fi

# 3. rc=2, no existing issue -> create (never edit/close).
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="" bash "$SCRIPT" 2 "$REP" 2>&1)"
has 'DRY: gh issue create' "$out" "rc2/no-issue -> creates"
has 'DRY: gh label create' "$out" "rc2 ensures marker label exists"
hasnt 'gh issue edit' "$out" "rc2/no-issue does not edit"
hasnt 'gh issue close' "$out" "rc2 never closes"

# 4. rc=2, existing issue #42 -> edit + comment, never create.
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="42" bash "$SCRIPT" 2 "$REP" 2>&1)"
has 'DRY: gh issue edit 42' "$out" "rc2/existing -> edits #42 (refresh in place)"
has 'DRY: gh issue comment 42' "$out" "rc2/existing -> adds still-drifting comment"
hasnt 'gh issue create' "$out" "rc2/existing never creates a duplicate"

# 5. rc=0, existing issue #42 -> comment + close.
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="42" bash "$SCRIPT" 0 "$REP" 2>&1)"
has 'DRY: gh issue close 42' "$out" "rc0/existing -> closes #42"
hasnt 'gh issue create' "$out" "rc0 never creates"

# 6. rc=0, no existing issue -> nothing.
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="" bash "$SCRIPT" 0 "$REP" 2>&1)"
hasnt 'DRY: gh issue ' "$out" "rc0/no-issue -> no gh issue mutation"

# 7. rc=3 (incomplete, documented) -> leave state unchanged, exit 0.
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="42" bash "$SCRIPT" 3 "$REP" 2>&1)"; rc=$?
hasnt 'DRY: gh issue ' "$out" "rc3 -> issue state unchanged (proved nothing)"
if [ "$rc" -eq 0 ]; then ok "rc3 -> exit 0 (benign incomplete)"; else bad "rc3 exit=$rc (expected 0)"; fi

# 7b. Any OTHER guard exit (crash/127/usage) is NOT the 0/2/3 contract -> fail
#     (red), never a silent-green no-op that hides a broken guard.
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="42" bash "$SCRIPT" 127 "$REP" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then ok "rc127 (unexpected) -> exit 1 (broken guard is visible)"; else bad "rc127 exit=$rc (expected 1)"; fi
hasnt 'DRY: gh issue ' "$out" "rc127 -> no issue mutation"

# 8. Lookup failure (gh issue list errored) must NOT be treated as "no issue".
#    rc=2 + failed lookup -> bail (exit 1), never create a duplicate.
out="$(DRY_RUN=1 DRY_RUN_LOOKUP_FAIL=1 bash "$SCRIPT" 2 "$REP" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then ok "rc2 + lookup-failure -> exit 1 (bail)"; else bad "rc2 + lookup-failure exit=$rc (expected 1)"; fi
hasnt 'DRY: gh issue create' "$out" "rc2 + lookup-failure never creates (no duplicate)"
#    rc=0 + failed lookup -> propagate (exit 1) for consistency, never close blindly.
out="$(DRY_RUN=1 DRY_RUN_LOOKUP_FAIL=1 bash "$SCRIPT" 0 "$REP" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then ok "rc0 + lookup-failure -> exit 1 (propagate)"; else bad "rc0 + lookup-failure exit=$rc (expected 1)"; fi
hasnt 'DRY: gh issue close' "$out" "rc0 + lookup-failure never closes blindly"

# 9. Report clarity: the issue body leads with a Needs-update
#    table (one row per BEHIND item, exact action), VENDORED rows in their own
#    group, CURRENT rows collapsed, and the per-run comment is a one-line delta.
body_of() { sed -n '/^DRY-BODY-BEGIN$/,/^DRY-BODY-END$/p' <<< "$1"; }
mixed="$(mktemp)" || exit 1
cat >"$mixed" <<'RPT'
== pinned remotes (SHA-pin vs HEAD; fork → true-upstream release) ==
  claude-obsidian: CURRENT  (fork tracks AgriciDaniel/claude-obsidian @ v2.2.0; pin v2.2.0)
  taste-skill-core: BEHIND   (Leonxlnx/taste-skill upstream is 2 commit(s) ahead — pin a60a36d -> f624f37)
  impeccable: BEHIND   (pbakaus/impeccable latest tag skill-v4.6.0; fork synced to skill-v4.5.2 — re-sync fork, bump synced_base + fork tag, then bump marketplace ref)

== carried upstreams (registry + installed marketplaces; HIMMEL-869) ==
  mkt:ui-ux-pro-max-skill: BEHIND   (nextlevelbuilder/ui-ux-pro-max-skill upstream is 1 commit(s) ahead — 7246805 -> 6166631)  [mkt-manual]
  mkt:openai-codex: CURRENT  (openai/codex-plugin-cc @ db52e28)  [mkt-auto]

== pinned tools and packages (npm/bun deps, pre-commit revs, actions, oxlint) ==
  npm:@types/node 26.6.4 (marketplace/plugins/claude-hud): VENDORED (upstream-owned pin; follows upstream — bump via /fork-resync, upstream advance watched by upstreams.json)
  gh:gitleaks/gitleaks v8.30.1 (.github/workflows/ci.yml, .pre-commit-config.yaml): CURRENT  (latest v8.30.1)
  npm:react 19.3.0 (scripts/config-ui/agui-web): BEHIND   (latest 19.3.1 — bump)

DRIFT DETECTED — one or more plugins are behind upstream (see above).
RPT
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="" bash "$SCRIPT" 2 "$mixed" 2>&1)"
b="$(body_of "$out")"
has '^### Needs update (4)' "$b" "mixed: body has 'Needs update (4)'"
has '^| taste-skill-core | upstream pin | a60a36d | f624f37 | bump the marketplace.json sha pin to f624f37 |' "$b" "mixed: plain sha-pin row is an upstream pin with the sha-bump action"
has '^| impeccable | skill fork | skill-v4.5.2 | skill-v4.6.0 | /fork-resync impeccable |' "$b" "mixed: real skill-fork row keeps /fork-resync"
has '^| mkt:ui-ux-pro-max-skill | carried tool | 7246805 | 6166631 | station tool: VM-first upgrade |' "$b" "mixed: carried-tool row"
has '^| npm:react | npm package | 19.3.0 | 19.3.1 | bump scripts/config-ui/agui-web to 19.3.1 plus synced_base in scripts/upstreams.json |' "$b" "mixed: npm row with exact action"
has 'no action unless upstream advances' "$b" "mixed: VENDORED group labelled"
has '^- npm:@types/node 26.6.4' "$b" "mixed: VENDORED row listed in its group"
has '<details>' "$b" "mixed: CURRENT rows collapsed in <details>"
has 'claude-obsidian: CURRENT' "$b" "mixed: CURRENT row kept inside the details block"
first="$(grep -n 'Needs update' <<<"$b" | head -1 | cut -d: -f1)"; det="$(grep -n '<details>' <<<"$b" | head -1 | cut -d: -f1)"
if [ -n "$first" ] && [ -n "$det" ] && [ "$first" -lt "$det" ]; then ok "mixed: table precedes the details block"; else bad "mixed: table must precede details ($first / $det)"; fi
has 'fork-drift-behind: impeccable,mkt:ui-ux-pro-max-skill,npm:react,taste-skill-core' "$b" "mixed: machine marker lists BEHIND names (sorted)"

# 9b. BEHIND only (no VENDORED) -> no VENDORED group.
only="$(mktemp)" || exit 1; printf '== x ==\n  graphify: BEHIND   (a/b upstream is 1 commit(s) ahead — pin aaaaaaa -> bbbbbbb)\n\nDRIFT DETECTED\n' >"$only"
b="$(body_of "$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="" bash "$SCRIPT" 2 "$only" 2>&1)")"
has '^### Needs update (1)' "$b" "behind-only: 'Needs update (1)'"
hasnt 'no action unless upstream advances' "$b" "behind-only: no VENDORED group"

# 9c. VENDORED only -> 'Needs update (0)', VENDORED group present.
ven="$(mktemp)" || exit 1; printf '== x ==\n  npm:c8 11.0.0 (marketplace/plugins/claude-hud): VENDORED (upstream-owned pin; follows upstream)\n' >"$ven"
b="$(body_of "$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="" bash "$SCRIPT" 2 "$ven" 2>&1)")"
has '^### Needs update (0)' "$b" "vendored-only: 'Needs update (0)'"
has 'no action unless upstream advances' "$b" "vendored-only: VENDORED group present"

# 9d. Nothing behind (rc 0) -> the issue closes.
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="42" bash "$SCRIPT" 0 "$ven" 2>&1)"
has 'DRY: gh issue close 42' "$out" "nothing-behind: issue closes"

# 9e. Per-run comment is a one-line delta against the previous body's marker.
old='<!-- fork-drift-behind: npm:react,old-item -->'
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="42" DRY_RUN_OLD_BODY="$old" bash "$SCRIPT" 2 "$mixed" 2>&1)"
has 'Still drifting: 4 items (+impeccable, mkt:ui-ux-pro-max-skill, taste-skill-core; -old-item since last run)' "$out" "comment: count + added/cleared delta"
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="42" DRY_RUN_OLD_BODY="<!-- fork-drift-behind: impeccable,mkt:ui-ux-pro-max-skill,npm:react,taste-skill-core -->" bash "$SCRIPT" 2 "$mixed" 2>&1)"
has 'Still drifting: 4 items (no change since last run)' "$out" "comment: unchanged set"
rm -f "$mixed" "$only" "$ven"

# 9f. The previous body is read BEFORE the issue is edited: after the edit the
#     marker is the new one, so a late read would always report "no change".
fakebin="$(mktemp -d)" || exit 1
glog="$fakebin/calls.log"
cat >"$fakebin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALL_LOG"
case "$1 $2" in
  "issue list") echo 42 ;;
  "issue view") echo '<!-- fork-drift-behind: old-item -->' ;;
esac
exit 0
GH
chmod +x "$fakebin/gh"
GH_CALL_LOG="$glog" PATH="$fakebin:$PATH" bash "$SCRIPT" 2 "$REP" >/dev/null 2>&1
view_n="$(grep -n '^issue view' "$glog" | head -1 | cut -d: -f1)"; edit_n="$(grep -n '^issue edit' "$glog" | head -1 | cut -d: -f1)"
if [ -n "$view_n" ] && [ -n "$edit_n" ] && [ "$view_n" -lt "$edit_n" ]; then ok "previous body read before the edit"; else bad "issue view ($view_n) must precede issue edit ($edit_n)"; fi
rm -rf "$fakebin"

# 9g. A failed read of the previous body is reported as unavailable history,
#     never as an empty marker that lists every item as newly added.
fakebin="$(mktemp -d)" || exit 1
glog="$fakebin/calls.log"
cat >"$fakebin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALL_LOG"
case "$1 $2" in
  "issue list") echo 42 ;;
  "issue view") exit 1 ;;
esac
exit 0
GH
chmod +x "$fakebin/gh"
GH_CALL_LOG="$glog" PATH="$fakebin:$PATH" bash "$SCRIPT" 2 "$REP" >/dev/null 2>&1
if grep '^issue comment' "$glog" | grep -q 'change since last run unavailable'; then ok "failed body read reports unavailable history"; else bad "failed body read must say history unavailable: $(grep '^issue comment' "$glog")"; fi
rm -rf "$fakebin"

# Default-branch and pinned-branch fork drift must keep counts and repair actions
# in the nightly table, rather than falling through as an installed tool.
forks="$(mktemp "${TMPDIR:-/tmp}/fork-drift-report.XXXXXX")" || exit 1
cat > "$forks" <<'RPT'
== fork branches (upstream default-branch comparison) ==
  yotamleo/fast@main: BEHIND   (fork-behind upstream=owner/fast@main behind=5 ahead=0 action=gh repo sync yotamleo/fast --branch main)
  yotamleo/carried@himmel/pin: BEHIND   (fork-behind upstream=owner/carried@main behind=3 ahead=2 action=/fork-resync)
  yotamleo/renamed@main: BEHIND   (fork-behind upstream=owner/renamed@trunk behind=6 ahead=0 action=/fork-resync)
  yotamleo/held@main: HELD (reviewed compatibility hold)
RPT
b="$(body_of "$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="" bash "$SCRIPT" 2 "$forks" 2>&1)")"
has '^| yotamleo/fast@main | fork-behind | behind=5 ahead=0 | owner/fast@main | gh repo sync yotamleo/fast --branch main |' "$b" "fork-behind: zero carried commits keeps gh repo sync action"
has '^| yotamleo/carried@himmel/pin | fork-behind | behind=3 ahead=2 | owner/carried@main | /fork-resync |' "$b" "fork-behind: pinned branch keeps carried-commit repair and both counts"
has '^| yotamleo/renamed@main | fork-behind | behind=6 ahead=0 | owner/renamed@trunk | /fork-resync |' "$b" "fork-behind: differing branch names keep manual repair even without carried commits"
has '^### Needs update (3)' "$b" "fork-behind: held row is not actionable"
rm -f "$forks"

rm -f "$REP"
echo ""
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
