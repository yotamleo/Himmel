#!/usr/bin/env bash
# claude-floor-review.sh — the CONTEXT-FREE Claude floor review (HIMMEL-3107).
#
# When CR_REQUIRE_CROSS_MODEL=1 + CR_FLOOR_FALLBACK=claude-only and every
# non-Claude lane is exhausted, clear-cr-marker.sh accepts a Claude-only floor
# — but only THIS script's review, never a row the authoring session records
# about its own work. It runs the review plugin's reviewer
# (pr-review-toolkit-himmel:code-reviewer, its agent body read from the plugin
# at runtime, never a paraphrase) in a FRESH headless claude session whose only
# inputs are the diff and a snapshot of every tracked file at the head:
#   - cwd = the snapshot (no .git, so no history, no ledger, no handovers);
#   - --isolated = --safe-mode --strict-mcp-config --no-session-persistence
#     (no CLAUDE.md, auto-memory, skills, plugins, hooks or MCP servers);
#   - --tools Read,Grep,Glob,Write — no Bash, no web, no sub-agents;
#   - no --resume/--continue: a new session every time.
# It then writes <git-common-dir>/cr-floor/<head>.json (head, base, diff hash,
# headless session id, the dispatch id of its registry row, findings — the
# provenance the gate checks), signed with the floor signing key only after
# that registry row reads completed/is_error=false (HIMMEL-3220; the trust
# boundary is documented in scripts/cr/claude-floor.mjs), and writes
# the findings (verdict empty: the session adjudicates them, gate 4b) plus one
# `avail --model claude-floor --status ok` row recording same-model +
# context-free + the lanes whose exhaustion unlocked it.
#
# WHAT THIS IS NOT: cross-model review. The reviewer is the same model family
# as the author. A fresh context removes the shared CONTEXT (the author's
# reasoning, its brief, its conclusions) but not the shared-model blind spot:
# a class of bug this model does not see, it does not see from a clean start
# either. The gate never counts claude-floor as cross-model evidence.
#
# It refuses to spend (exit 3) unless the operator opted in (the primary's
# .env or the process env sets CR_REQUIRE_CROSS_MODEL truthy AND
# CR_FLOOR_FALLBACK=claude-only) and the ledger shows the floor can actually
# unlock: no non-Claude ok row at this head, and every non-Claude lane that
# recorded a row is exhausted (quota/rate-limit, or a vacuous CodeRabbit pass)
# — or critics.json lists an empty panel and no lane recorded anything — and
# the floor signing key is provisioned (operator, once:
# `node scripts/cr/claude-floor.mjs init-key`).
# An auth/404/config/timeout lane refuses here exactly as it does in the gate.
#
# usage: claude-floor-review.sh --branch <branch> --base <ref> [--head <sha>]
# exit: 0 reviewed + recorded; 2 usage; 3 not eligible (nothing spent);
#       1 the review ran but failed (dispatch refused, is_error, bad output) —
#       recorded as `avail claude-floor unavailable` with a reason.
# Env: CR_LEDGER (ledger path, default <git-common-dir>/cr-critic-scores.jsonl;
#      the gate itself reads only the default), HIMMEL_CLAUDE_BIN and the
#      CADENCE_BANK_* / HIMMEL_REGISTRY_DIR knobs pass through to
#      scripts/lib/claude-headless.sh (tests inject a fake claude there).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_MD="$REPO_ROOT/marketplace/plugins/pr-review-toolkit-himmel/agents/code-reviewer.md"

die() { echo "claude-floor-review: $*" >&2; exit "${2:-2}"; }

branch="" base="" head=""
while [ $# -gt 0 ]; do
    case "$1" in
        --branch) [ $# -ge 2 ] || die "--branch needs a value"; branch="$2"; shift 2 ;;
        --base) [ $# -ge 2 ] || die "--base needs a value"; base="$2"; shift 2 ;;
        --head) [ $# -ge 2 ] || die "--head needs a value"; head="$2"; shift 2 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done
[ -n "$branch" ] || die "--branch is required"
[ -n "$base" ] || die "--base is required"
head=$(git rev-parse --verify "${head:-HEAD}^{commit}" 2>/dev/null) || die "cannot resolve --head"
base=$(git rev-parse --verify "$base^{commit}" 2>/dev/null) || die "cannot resolve --base"
[ "$base" != "$head" ] || die "--base equals --head: there is no diff to review"
# Twin of clear-cr-marker.sh floor_provenance_ok: the gate refuses an artifact
# whose base is off the remote default branch (a partial range), so never spend one.
# shellcheck source=scripts/lib/cr-default-base.sh
. "$REPO_ROOT/scripts/lib/cr-default-base.sh" || die "cannot load scripts/lib/cr-default-base.sh" 1
default_ref=$(cr_default_base_ref) || die "not eligible: no remote default branch (origin/HEAD or origin/main) to bind --base to. Nothing spent." 3
git merge-base --is-ancestor "$base" "$default_ref" 2>/dev/null ||
    die "not eligible: --base ${base:0:8} is not on the default branch ($default_ref), so the review would cover only part of the branch. Nothing spent." 3
[ -r "$AGENT_MD" ] || die "reviewer agent definition not readable: $AGENT_MD"
git_dir=$(git rev-parse --git-common-dir 2>/dev/null) || die "not in a git repository"
ledger="${CR_LEDGER:-$git_dir/cr-critic-scores.jsonl}"

# --- 1. eligibility: never spend a review the gate could not accept ---------
# The operator opt-in first, read exactly as clear-cr-marker.sh reads it (the
# primary's .env; a non-empty process value wins): without BOTH knobs the gate
# never accepts a claude-floor row, so the review would be spent for nothing.
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/load-dotenv.sh" || die "cannot load scripts/lib/load-dotenv.sh" 1
load_dotenv --root "$(_load_dotenv_primary_for "$REPO_ROOT")" CR_REQUIRE_CROSS_MODEL CR_FLOOR_FALLBACK \
    || die "could not read CR_REQUIRE_CROSS_MODEL/CR_FLOOR_FALLBACK from .env" 3
norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
case "$(norm "${CR_REQUIRE_CROSS_MODEL:-}")" in
    1|true|on|yes) ;;
    *) die "not eligible: CR_REQUIRE_CROSS_MODEL is not set, so the gate needs no floor. Nothing spent." 3 ;;
esac
[ "$(norm "${CR_FLOOR_FALLBACK:-}")" = claude-only ] \
    || die "not eligible: CR_FLOOR_FALLBACK is not claude-only, so the gate would refuse a floor row. Nothing spent." 3

# Twin of clear-cr-marker.sh's isExhausted()/emptyPanel — keep the two in step.
# shellcheck disable=SC2016  # JS inside single quotes
unlocked=$(LEDGER="$ledger" FULL_SHA="$head" CRITICS="$SCRIPT_DIR/critics.json" node -e '
  const fs = require("fs"), e = process.env;
  const lines = fs.existsSync(e.LEDGER) ? fs.readFileSync(e.LEDGER, "utf8").split("\n").filter(Boolean) : [];
  const lanes = new Map(); let crossOk = false;
  for (const l of lines) {
      let o; try { o = JSON.parse(l); } catch (_) { continue; }
      if (o.kind !== "avail" || typeof o.head !== "string" || o.head.length < 7 || !e.FULL_SHA.startsWith(o.head)) continue;
      const m = (typeof o.model === "string" ? o.model : "").trim().toLowerCase();
      if (!m || m === "claude" || m === "claude-floor") continue;
      const st = (typeof o.status === "string" ? o.status : "").trim().toLowerCase();
      if (st === "ok") crossOk = true;
      lanes.set(m, { st, r: (typeof o.reason === "string" ? o.reason : "").trim().toLowerCase() });
  }
  if (crossOk) { console.log("NOT-NEEDED a non-Claude critic already responded at this head"); process.exit(0); }
  const EX = new Set(["quota", "quota-5h", "quota-long", "rate-limit"]);
  const out = [], bad = [];
  for (const [m, r] of lanes) {
      if (r.st === "unavailable" && (EX.has(r.r) || (m === "coderabbit" && r.r === "vacuous"))) out.push(m + "(reason=" + r.r + ")");
      else bad.push(m + "(status=" + (r.st || "?") + ",reason=" + (r.r || "none") + ")");
  }
  if (bad.length) { console.log("REFUSE lane(s) not exhausted: " + bad.join(" ")); process.exit(0); }
  if (!lanes.size) {
      let empty = false;
      try { const p = JSON.parse(fs.readFileSync(e.CRITICS, "utf8")).panel; empty = Array.isArray(p) && p.length === 0; } catch (_) {}
      if (!empty) { console.log("REFUSE no non-Claude lane recorded a row at this head (silence is not exhaustion)"); process.exit(0); }
      out.push("empty-panel");
  }
  console.log("OK " + out.join(" "));
' 2>/dev/null)
case "$unlocked" in
    OK\ *) unlocked="${unlocked#OK }" ;;
    *) echo "claude-floor-review: not eligible at ${head:0:8} — ${unlocked:-could not read the ledger at $ledger}. Nothing spent." >&2; exit 3 ;;
esac
# HIMMEL-3220: the gate accepts only a STAMPED artifact, so without a
# provisioned signing key the review would be spent for nothing.
key_err=$(node "$SCRIPT_DIR/claude-floor.mjs" key-check 2>&1) ||
    die "not eligible: ${key_err#claude-floor: } Nothing spent." 3

# --- 2. the reviewer's inputs: a snapshot of the head + the diff, nothing else ---
work=$(mktemp -d "${TMPDIR:-/tmp}/cr-floor.XXXXXX") || die "mktemp failed" 1
trap 'rm -rf "$work"' EXIT
snap="$work/snap"
mkdir -p "$snap" || die "mkdir failed" 1
# Every tracked file at the head, from its RAW blob (HIMMEL-3229): checkout-index
# would apply smudge filters and eol conversion, and `git archive` would also
# honour export-ignore — either way the reviewer would read bytes the diff
# hash does not cover.
node "$SCRIPT_DIR/claude-floor.mjs" snapshot "$head" "$snap" || die "snapshot of ${head:0:8} failed" 1
git diff --no-color --no-ext-diff "$base...$head" > "$work/diff.patch" || die "git diff failed" 1
[ -s "$work/diff.patch" ] || die "the diff $base...${head:0:8} is empty — nothing to review" 3
diff_hash=$(git hash-object --stdin < "$work/diff.patch") || die "hashing the diff failed" 1
out_json="$snap/.cr-floor-review.json"
# A tracked file of that name must never stand in for the review.
rm -f "$out_json" || die "cannot clear $out_json" 1

# The plugin's own reviewer, verbatim (frontmatter stripped), plus the output
# contract this script parses. Its model: line picks the model.
awk 'NR==1 && $0=="---" {fm=1; next} fm && $0=="---" {fm=0; next} !fm' "$AGENT_MD" > "$work/system.md"
model=$(awk 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit} /^model:/ {sub(/^model:[[:space:]]*/, ""); print; exit}' "$AGENT_MD")
cat >> "$work/system.md" <<'EOF'

## Floor-review output contract (HIMMEL-3107)

You are running headless with no conversation history. Your working directory
is a snapshot of the repository at the reviewed commit (read any file you need;
CLAUDE.md files are in it). The diff under review is in the user message.
When done, use the Write tool to create `.cr-floor-review.json` in the working
directory containing ONLY this JSON (no prose, no code fences):
{"findings":[{"severity":"crit|imp|sug","file":"<path>","line":<int or 0>,"text":"<finding + fix>"}]}
Map your groups: Critical -> crit, Important -> imp, Suggestion -> sug.
Zero findings -> {"findings":[]}. Do not modify any other file.
EOF
{
    printf 'Review this diff (%s...%s). It is the ONLY change under review.\n\n' "$base" "$head"
    cat "$work/diff.patch"
} > "$work/prompt.md"

ticket=$(printf '%s' "$branch" | grep -oiE '[a-z][a-z0-9]*-[0-9]+' | head -1 | tr '[:lower:]' '[:upper:]')

# record_failure <reason> <detail> — the review was attempted and failed.
record_failure() {
    bash "$SCRIPT_DIR/ledger-append.sh" avail --branch "$branch" --head "$head" --model claude-floor \
        --status unavailable --reason "$1" --detail "$2" >/dev/null 2>&1 || true
    echo "claude-floor-review: the floor review FAILED at ${head:0:8} ($1): $2" >&2
    exit 1
}

# --- 3. the headless review ---------------------------------------------------
# headless-claude-ok: HIMMEL-3107 context-free CR floor reviewer — runs only when
# every non-Claude critic is exhausted and the operator opted in via
# CR_FLOOR_FALLBACK=claude-only; claude-headless.sh pins native auth (native-auth-pin.sh native_auth_pin_env), does the mandatory bank
# preflight (refuses on a non-PROCEED verdict), the explicit acceptEdits
# permission mode (never bypassPermissions) and the --output-format json parse.
bash "$REPO_ROOT/scripts/lib/claude-headless.sh" --role cr-floor --ticket "${ticket:-UNKNOWN-0}" \
    --worktree "$snap" --cwd "$snap" --artifact "$out_json" --permission-mode acceptEdits \
    --prompt-file "$work/prompt.md" --system-prompt-file "$work/system.md" \
    --tools "Read,Grep,Glob,Write" --isolated --max-turns 40 ${model:+--model "$model"} \
    2> "$work/headless.err"
headless_rc=$?
row=$(sed -n 's/^claude-headless\.sh: id=.* registry=//p' "$work/headless.err" | tail -1)
if [ -z "$row" ] || [ ! -r "$row" ]; then
    record_failure "dispatch-refused" "$(tr '\n' ' ' < "$work/headless.err" | cut -c1-180)"
fi
# is_error / session id come from the parsed --output-format json envelope.
# Unit-separator delimited: tab is IFS whitespace, so an empty session id
# would collapse and the dispatch id would shift into its place.
IFS=$'\x1f' read -r h_status h_error session_id dispatch_id <<<"$(jq -r '[.status, (.outcome.is_error|tostring), (.outcome.session_id // ""), .id] | join("\u001f")' "$row" 2>/dev/null)"
[ "$h_error" = "false" ] || record_failure "empty-response" "headless envelope is_error=$h_error (rc=$headless_rc)"
if [ "$h_status" != "completed" ] || [ "$headless_rc" -ne 0 ]; then
    record_failure "empty-response" "dispatch status=$h_status rc=$headless_rc: no review artifact"
fi
[ -n "$session_id" ] || record_failure "malformed-output" "headless envelope carries no session_id"

# --- 4. validate the findings -------------------------------------------------
# shellcheck disable=SC2016  # JS inside single quotes
findings=$(OUT="$out_json" node -e '
  try {
      const f = JSON.parse(require("fs").readFileSync(process.env.OUT, "utf8")).findings;
      if (!Array.isArray(f)) throw 0;
      for (const x of f) {
          if (!["crit", "imp", "sug"].includes(x.severity) || typeof x.file !== "string" || typeof x.text !== "string" || x.text.trim() === "") throw 0;
          if (!(Number.isInteger(x.line) && x.line >= 0)) throw 0;
      }
      console.log(JSON.stringify(f));
  } catch (_) { process.exit(1); }' 2>/dev/null) || record_failure "malformed-output" "the reviewer did not write a valid .cr-floor-review.json"

# --- 5. ledger rows, then the provenance stamp (what the gate checks) ---------
# The artifact is published LAST: if recording a repeat review fails, the
# previous artifact stays paired with the findings the ledger actually holds.
n=$(printf '%s' "$findings" | jq 'length')
if [ "$n" -gt 0 ]; then
    printf '%s' "$findings" | jq -c --arg b "$branch" --arg h "$head" \
        'to_entries[] | {branch:$b, head:$h, model:"claude-floor", id:("claude-floor-" + ((.key + 1)|tostring)),
                         severity:.value.severity, file:.value.file, line:.value.line, verdict:"", text:.value.text}' \
        > "$work/batch.jsonl"
    bash "$SCRIPT_DIR/ledger-append.sh" finding --batch-file "$work/batch.jsonl" >/dev/null \
        || die "recording the floor findings failed" 1
fi
bash "$SCRIPT_DIR/ledger-append.sh" avail --branch "$branch" --head "$head" --model claude-floor --status ok \
    --detail "same-model context-free session=$session_id unlocked_by=$unlocked" >/dev/null \
    || die "recording the floor avail row failed" 1

mkdir -p "$git_dir/cr-floor" || die "cannot create $git_dir/cr-floor" 1
if ! jq -n --arg head "$head" --arg base "$base" --arg diff_hash "$diff_hash" --arg session_id "$session_id" \
    --arg dispatch_id "$dispatch_id" --arg unlocked "$unlocked" --argjson findings "$findings" \
    '{schema:2, head:$head, base:$base, diff_hash:$diff_hash, session_id:$session_id, dispatch_id:$dispatch_id,
      model:"claude-floor", reviewer:"pr-review-toolkit-himmel:code-reviewer", same_model:true, context_free:true,
      unlocked_by:($unlocked | split(" ")), findings:$findings}' > "$work/artifact.json" \
    || ! node "$SCRIPT_DIR/claude-floor.mjs" sign "$work/artifact.json" > "$git_dir/cr-floor/$head.json.tmp" \
    || ! mv "$git_dir/cr-floor/$head.json.tmp" "$git_dir/cr-floor/$head.json"; then
    die "cannot write the floor artifact" 1
fi

echo "claude-floor-review: reviewed ${head:0:8} ($n finding(s), session $session_id). Unlocked by: $unlocked."
echo "  COVERED: pr-review-toolkit-himmel:code-reviewer in a fresh headless claude session over the diff + a snapshot of this head only (no session context)."
echo "  NOT COVERED: cross-model review. Same model family as the author — the shared-model blind spot remains."
[ "$n" -eq 0 ] || echo "  Adjudicate the claude-floor-N findings (ledger-append.sh finding ... --verdict) before clearing."
