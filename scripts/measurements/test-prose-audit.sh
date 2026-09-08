#!/usr/bin/env bash
# Fixture-based tests for scripts/measurements/prose-audit.sh (HIMMEL-1939).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/measurements/prose-audit.sh"
passes=0
fails=0

ok() { echo "ok - $1"; passes=$((passes + 1)); }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }
grepq() { local text="$1"; shift; grep -q "$@" <<< "$text"; }

TMP="$(mktemp -d)" || { echo "FAIL - mktemp -d failed (rc=$?)" >&2; exit 1; }
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  echo "FAIL - mktemp -d returned no usable directory" >&2
  exit 1
fi
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/repo"
mkdir -p \
  "$FIXTURE/scripts/measurements" \
  "$FIXTURE/.claude/commands" \
  "$FIXTURE/marketplace/plugins/fence/skills/fence" \
  "$FIXTURE/marketplace/plugins/bigcmd/commands" \
  "$FIXTURE/.agents/skills/rationale" \
  "$FIXTURE/.claude/worktrees/copy/.claude/commands" \
  "$FIXTURE/templates/vendored/skills/copied" \
  "$FIXTURE/plugins/himmel-test/commands" \
  "$FIXTURE/plugins/himmel-test/skills/widget"
cp "$SCRIPT" "$FIXTURE/scripts/measurements/prose-audit.sh"
AUDIT="$FIXTURE/scripts/measurements/prose-audit.sh"

repeat_char() {
  awk -v count="$1" -v char="$2" 'BEGIN { for (i = 0; i < count; i++) printf "%s", char }'
}

LEAN="$FIXTURE/.claude/commands/lean.md"
printf '%s\n' '# Lean command' 'One judgment-bearing sentence.' >"$LEAN"

FENCE="$FIXTURE/marketplace/plugins/fence/skills/fence/SKILL.md"
{
  printf '%s\n' '# Fence-heavy skill' '```bash'
  repeat_char 7000 x
  printf '\n%s\n' '```'
} >"$FENCE"

RATIONALE="$FIXTURE/.agents/skills/rationale/SKILL.md"
{
  printf '%s\n' '# Rationale-heavy skill'
  repeat_char 7000 r
  printf '\n'
} >"$RATIONALE"

CMDFILE="$FIXTURE/marketplace/plugins/bigcmd/commands/big.md"
{
  printf '%s\n' '# Big marketplace plugin command' '```bash'
  repeat_char 7000 c
  printf '\n%s\n' '```'
} >"$CMDFILE"

PLUGINCMD="$FIXTURE/plugins/himmel-test/commands/big.md"
{
  printf '%s\n' '# Big first-party plugin command' '```bash'
  repeat_char 7000 d
  printf '\n%s\n' '```'
} >"$PLUGINCMD"

PLUGINSKILL="$FIXTURE/plugins/himmel-test/skills/widget/SKILL.md"
{
  printf '%s\n' '# Big first-party plugin skill' '```bash'
  repeat_char 7000 e
  printf '\n%s\n' '```'
} >"$PLUGINSKILL"

SNIPPETS="$FIXTURE/.claude/commands/snippets.md"
{
  printf '%s\n' '# Repeated script snippets'
  repeat_char 6500 p
  printf '\n'
  printf '%s\n' \
    'bash scripts/one.sh' \
    'bash scripts/two.sh' \
    'bash scripts/three.sh' \
    'bash scripts/four.sh'
} >"$SNIPPETS"

{
  repeat_char 9000 w
  printf '\n%s\n%s\n%s\n' '```bash' 'bash scripts/copied.sh' '```'
} >"$FIXTURE/.claude/worktrees/copy/.claude/commands/copied.md"
{
  repeat_char 9000 t
  printf '\n%s\n%s\n%s\n' '```bash' 'bash scripts/template.sh' '```'
} >"$FIXTURE/templates/vendored/skills/copied/SKILL.md"

if bash -n "$AUDIT"; then ok "syntax (bash -n)"; else bad "syntax (bash -n)"; fi

default_out="$(bash "$AUDIT" 2>&1)"; default_rc=$?
if [ "$default_rc" -eq 0 ]; then ok "findings remain report-only (default exits 0)"; else bad "default exited $default_rc: $default_out"; fi

json_out="$(bash "$AUDIT" --json 2>&1)"; json_rc=$?
if [ "$json_rc" -ne 0 ]; then
  bad "--json exited $json_rc: $json_out"
fi

if node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
const row = d.rows.find((item) => item.file === ".claude/commands/lean.md");
process.exit(row && row.bytes < 6144 && row.flagged === false ? 0 : 1);
' <<< "$json_out"; then ok "small lean file is not flagged"; else bad "small lean file was missing or flagged"; fi

if node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
const row = d.rows.find((item) => item.file.includes("marketplace/plugins/fence/"));
process.exit(row && row.bytes > 6144 && row.fence_ratio_pct > 15 && row.flagged ? 0 : 1);
' <<< "$json_out"; then ok "large fence-heavy file is flagged"; else bad "large fence-heavy file was not flagged"; fi

if node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
const row = d.rows.find((item) => item.file === "marketplace/plugins/bigcmd/commands/big.md");
process.exit(row && row.bytes > 6144 && row.flagged ? 0 : 1);
' <<< "$json_out"; then ok "marketplace plugin commands/*.md file is scanned and flagged (HIMMEL-1939 finding 1)"; else bad "marketplace plugin commands/*.md file was missing from rows"; fi

if node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
const row = d.rows.find((item) => item.file === "plugins/himmel-test/commands/big.md");
process.exit(row && row.bytes > 6144 && row.flagged ? 0 : 1);
' <<< "$json_out"; then ok "top-level plugins/*/commands/*.md file is scanned and flagged (HIMMEL-1939 finding 1)"; else bad "top-level plugins/*/commands/*.md file was missing from rows"; fi

if node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
const row = d.rows.find((item) => item.file === "plugins/himmel-test/skills/widget/SKILL.md");
process.exit(row && row.bytes > 6144 && row.flagged ? 0 : 1);
' <<< "$json_out"; then ok "top-level plugins/*/skills/**/SKILL.md file is scanned and flagged (HIMMEL-1939 finding 1)"; else bad "top-level plugins/*/skills/**/SKILL.md file was missing from rows"; fi

if node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
const row = d.rows.find((item) => item.file === ".agents/skills/rationale/SKILL.md");
process.exit(row && row.bytes > 6144 && row.fence_ratio_pct === 0 && row.flagged === false ? 0 : 1);
' <<< "$json_out"; then ok "large rationale-only file is not flagged"; else bad "large rationale-only file was flagged"; fi

if node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
const row = d.rows.find((item) => item.file === ".claude/commands/snippets.md");
process.exit(row && row.fence_ratio_pct === 0 && row.script_snippets === 4 && row.backing_script && row.flagged ? 0 : 1);
' <<< "$json_out"; then ok ">3 literal bash scripts snippets flag independently of fence ratio"; else bad "script-snippet criterion did not flag the fixture"; fi

expected_bytes=$(( $(wc -c <"$LEAN") + $(wc -c <"$FENCE") + $(wc -c <"$RATIONALE") + $(wc -c <"$SNIPPETS") + $(wc -c <"$CMDFILE") + $(wc -c <"$PLUGINCMD") + $(wc -c <"$PLUGINSKILL") ))
if node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
const expected = Number(process.argv[1]);
const excluded = d.rows.some((item) => item.file.includes(".claude/worktrees/") || item.file.startsWith("templates/"));
process.exit(d.summary.files === 7 && d.summary.bytes === expected && !excluded ? 0 : 1);
' "$expected_bytes" <<< "$json_out"; then ok "worktree and template copies contribute nothing to rows or totals (wider corpus incl. marketplace + top-level plugin commands/skills)"; else bad "excluded fixture changed rows or totals"; fi

flagged_out="$(bash "$AUDIT" --flagged-only 2>&1)"; flagged_rc=$?
if [ "$flagged_rc" -eq 0 ] \
  && grepq "$flagged_out" 'marketplace/plugins/fence/' \
  && grepq "$flagged_out" '.claude/commands/snippets.md' \
  && grepq "$flagged_out" 'marketplace/plugins/bigcmd/commands/big.md' \
  && grepq "$flagged_out" 'plugins/himmel-test/commands/big.md' \
  && grepq "$flagged_out" 'plugins/himmel-test/skills/widget/SKILL.md' \
  && ! grepq "$flagged_out" '.claude/commands/lean.md' \
  && ! grepq "$flagged_out" '.agents/skills/rationale/SKILL.md' \
  && grepq "$default_out" '.claude/commands/lean.md'; then
  ok "--flagged-only is a strict subset of the default table"
else
  bad "--flagged-only did not contain exactly the flagged subset"
fi

if bash "$AUDIT" --json | node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
if (!Array.isArray(d.rows) || typeof d.rows[0].fenced_bytes !== "number") process.exit(1);
'; then ok "--json is parseable and exposes numeric row fields"; else bad "--json was not parseable with expected fields"; fi

min_override="$(PROSE_AUDIT_MIN_BYTES=999999 bash "$AUDIT" --json)"
if node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(d.summary.flagged===0 ? 0 : 1)' <<< "$min_override"; then
  ok "PROSE_AUDIT_MIN_BYTES override moves the size threshold"
else
  bad "PROSE_AUDIT_MIN_BYTES override did not move the threshold"
fi

ratio_override="$(PROSE_AUDIT_FENCE_RATIO=100 bash "$AUDIT" --json)"
if node -e '
const d=JSON.parse(require("fs").readFileSync(0,"utf8"));
const fence=d.rows.find((x)=>x.file.includes("marketplace/plugins/fence/"));
const snippets=d.rows.find((x)=>x.file===".claude/commands/snippets.md");
process.exit(fence && !fence.flagged && snippets && snippets.flagged ? 0 : 1);
' <<< "$ratio_override"; then
  ok "PROSE_AUDIT_FENCE_RATIO override moves only the fence threshold"
else
  bad "PROSE_AUDIT_FENCE_RATIO override did not move the fence threshold"
fi

snippet_override="$(PROSE_AUDIT_MAX_SNIPPETS=4 bash "$AUDIT" --json)"
if node -e '
const d=JSON.parse(require("fs").readFileSync(0,"utf8"));
const fence=d.rows.find((x)=>x.file.includes("marketplace/plugins/fence/"));
const snippets=d.rows.find((x)=>x.file===".claude/commands/snippets.md");
process.exit(fence && fence.flagged && snippets && !snippets.flagged ? 0 : 1);
' <<< "$snippet_override"; then
  ok "PROSE_AUDIT_MAX_SNIPPETS override moves only the snippet threshold"
else
  bad "PROSE_AUDIT_MAX_SNIPPETS override did not move the snippet threshold"
fi

if node -e '
const d=JSON.parse(require("fs").readFileSync(0,"utf8"));
const lean=d.rows.find((x)=>x.file===".claude/commands/lean.md");
process.exit(lean && lean.fenced_bytes===0 && lean.fence_ratio_pct===0 ? 0 : 1);
' <<< "$json_out"; then ok "file with no fences reports zero without division error"; else bad "no-fence file ratio was not zero"; fi

bad_flag_out="$(bash "$AUDIT" --not-a-flag 2>&1)"; bad_flag_rc=$?
if [ "$bad_flag_rc" -ne 0 ] && grepq "$bad_flag_out" 'unknown flag'; then ok "bad flag returns non-zero"; else bad "bad flag did not return a reporter error"; fi

if grep -Eq '\bmapfile\b|\breadarray\b|shopt -s globstar' "$AUDIT"; then
  bad "script still uses a bash-4-only construct (mapfile/readarray/globstar) — bash 3.2 hosts would silently degrade (HIMMEL-1939 finding 2)"
else
  ok "no bash-4-only discovery/sort construct (mapfile/readarray/globstar) remains"
fi

if node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
process.exit(Array.isArray(d.rows) && d.rows.length > 0 ? 0 : 1);
' <<< "$json_out"; then ok "rows are non-empty on a real fixture corpus (not a silent empty report)"; else bad "rows were empty against a non-empty fixture corpus"; fi

# HIMMEL-1939 finding 2: a discovery `find` that fails partway through a tree
# must fail the whole reporter closed, not silently emit a partial-but-clean
# report. A genuine unreadable-directory fixture isn't reliably reproducible
# on Windows Git Bash (NTFS/Git-Bash chmod doesn't dependably deny `find`
# traversal), so this injects the failure directly: a `find` double on PATH
# that emits a partial file list for the marketplace/plugins tree, then exits
# non-zero — the exact shape a real permission/I-O failure below a readable
# top-level directory produces.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
REAL_FIND="$(command -v find)"
cat > "$FAKEBIN/find" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"$FIXTURE/marketplace/plugins"*)
    echo "$FIXTURE/marketplace/plugins/fence/skills/fence/SKILL.md"
    echo "fake-find: simulated permission denied below marketplace/plugins" >&2
    exit 1
    ;;
  *)
    exec "$REAL_FIND" "\$@"
    ;;
esac
EOF
chmod +x "$FAKEBIN/find"

fail_out="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" 2>&1)"; fail_rc=$?
if [ "$fail_rc" -ne 0 ] && ! grepq "$fail_out" '^summary:'; then
  ok "discovery failure below a readable tree fails the reporter closed, non-zero, no summary line (HIMMEL-1939 finding 2)"
else
  bad "discovery failure did not fail closed (rc=$fail_rc): $fail_out"
fi

# HIMMEL-1939 round 3 finding 1 [codex-adv-2]: the sort pipeline used to run
# inside process substitution, so its exit status was never observed — a
# failing sort could leave `sorted` empty/partial while the script still
# printed a clean summary and exited 0. Shadow `sort` via PATH with a stub
# that emits partial output and exits non-zero (same technique the `find`
# failure test above uses), and assert the reporter fails closed instead.
SORTBIN="$TMP/sortbin"
mkdir -p "$SORTBIN"
cat > "$SORTBIN/sort" <<'EOF'
#!/usr/bin/env bash
head -n 1
echo "fake-sort: simulated partial output" >&2
exit 1
EOF
chmod +x "$SORTBIN/sort"

sort_fail_out="$(PATH="$SORTBIN:$PATH" bash "$AUDIT" 2>&1)"; sort_fail_rc=$?
if [ "$sort_fail_rc" -ne 0 ] && ! grepq "$sort_fail_out" '^summary:'; then
  ok "sort failure fails the reporter closed, non-zero, no summary line (HIMMEL-1939 round 3 finding 1)"
else
  bad "sort failure did not fail closed (rc=$sort_fail_rc): $sort_fail_out"
fi

# HIMMEL-1939 round 3 finding 2 [codex-adv-3]: an unchecked `mktemp -d`
# failure would make FIXTURE fall back to `/repo`, and this suite runs
# without errexit so nothing would stop the subsequent mkdir/cp/redirects
# from writing there. Shadow `mktemp` via PATH with a stub that always fails
# and re-invoke this suite as a fresh process; it must abort at the TMP guard
# before any fixture write, not fall through to `/repo`.
MKTEMPBIN="$TMP/mktempbin"
mkdir -p "$MKTEMPBIN"
cat > "$MKTEMPBIN/mktemp" <<'EOF'
#!/usr/bin/env bash
echo "fake-mktemp: simulated failure" >&2
exit 1
EOF
chmod +x "$MKTEMPBIN/mktemp"

mktemp_fail_out="$(PATH="$MKTEMPBIN:$PATH" bash "$0" 2>&1)"; mktemp_fail_rc=$?
if [ "$mktemp_fail_rc" -ne 0 ] && grepq "$mktemp_fail_out" 'mktemp'; then
  ok "unchecked mktemp -d failure aborts before any fixture write (HIMMEL-1939 round 3 finding 2)"
else
  bad "mktemp -d failure did not abort cleanly (rc=$mktemp_fail_rc): $mktemp_fail_out"
fi

# HIMMEL-1939 round 4 finding 1 [codex-adv-1]: the fence-ratio threshold `awk`
# call used a bash `if awk ...; then ... elif ...` shape that treats ANY
# non-zero awk exit (a genuine "ratio <= limit", but also a broken/exhausted
# awk) as the same false branch — a measurement failure was silently recorded
# as an unflagged file and the reporter still exited 0. Shadow `awk` via PATH
# with a stub that fails only the threshold-comparison call (matched by its
# distinctive `-v limit=` argument, so the unrelated fenced-bytes/snippet/
# ratio awk calls still run for real), same technique as the find/sort
# failure tests above, and assert the reporter fails closed instead.
FAKEAWKBIN="$TMP/fakeawkbin"
mkdir -p "$FAKEAWKBIN"
REAL_AWK="$(command -v awk)"
cat > "$FAKEAWKBIN/awk" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"-v limit="*)
    echo "fake-awk: simulated awk failure on fence-ratio threshold check" >&2
    exit 2
    ;;
  *)
    exec "$REAL_AWK" "\$@"
    ;;
esac
EOF
chmod +x "$FAKEAWKBIN/awk"

awk_fail_out="$(PATH="$FAKEAWKBIN:$PATH" bash "$AUDIT" 2>&1)"; awk_fail_rc=$?
if [ "$awk_fail_rc" -ne 0 ] && ! grepq "$awk_fail_out" '^summary:'; then
  ok "awk failure on the fence-ratio threshold check fails the reporter closed, non-zero, no summary line (HIMMEL-1939 round 4 finding 1)"
else
  bad "awk threshold-check failure did not fail closed (rc=$awk_fail_rc): $awk_fail_out"
fi

echo ""
echo "$passes passed; $fails failed."
if [ "$fails" -ne 0 ]; then exit 1; fi
exit 0
