#!/usr/bin/env bash
# test-codex-hook-parity.sh — drift gate for the Codex hook inventory (HIMMEL-1981).
#
# WHY: `.codex/hooks.json` is a hand-maintained re-wiring of himmel's guardrails
# for the Codex lane. It drifts silently: HIMMEL-708 un-wired the no-op
# `improve-on-submit` UserPromptSubmit hook from `.claude/settings.json` and the
# Codex copy stayed, so every Codex prompt paid a pwsh+cmd+bash spawn chain for a
# guaranteed no-op — and showed up as one of the "UserPromptSubmit hook (failed)"
# lines that opened HIMMEL-1981.
#
# The gate: every guardrail `.codex/hooks.json` wires must EITHER also be wired
# for Claude (project `.claude/settings.json` or a himmel plugin `hooks.json`) OR
# be on the CODEX_ONLY allowlist below, with a stated reason. Adding a Codex hook
# that Claude does not carry now costs one line here — which is the point.
#
# This asserts OUR inventory contract only; it does not run any hook.
set -euo pipefail

# cd to the repo root and keep every path RELATIVE from here on. Git Bash pwd
# yields an MSYS path (/c/...), and handing that to native `node` works only
# because MSYS rewrites path-looking argv on the way out — which MSYS_NO_PATHCONV
# / MSYS2_ARG_CONV_EXCL turn off. Inheriting the cwd needs no rewriting at all.
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
fails=0
# assert_empty <label> <offenders> — pass when the offender list is blank; the
# offenders themselves are the failure message, so no case needs a second lookup.
assert_empty() {
  if [ -z "${2//[[:space:]]/}" ]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1: $2"
    fails=$((fails + 1))
  fi
}

# Guardrails Codex wires that Claude deliberately does NOT — each needs a reason.
#   block-terminal-write-fence.sh : Codex writes to the operator's terminal; the
#     fence is a Codex-lane guard with no Claude-side counterpart (HIMMEL-745).
#   end-session-wiki.sh           : ported to Codex's Stop event (HIMMEL-599);
#     on the Claude side the session note is written by the handover flow.
CODEX_ONLY="block-terminal-write-fence.sh end-session-wiki.sh"

# Claude Stop/SessionEnd hooks deliberately not mirrored to Codex Stop/SessionEnd.
CLAUDE_END_ONLY=(
  run-node.sh               # HIMMEL-2047: the node-resolving launcher every Claude
                             # hook command is now sourced through, not a guardrail
                             # script itself — the .sh-basename scan below picks it
                             # up from the command line same as a real guardrail.
  speak-reply.sh            # deliberate: cosmetic TTS, gated off by default, not ported.
  session-run-hook.ts       # deliberate: the session-runs census is Claude-scoped, and the
                            # Codex adapter resolves scripts/hooks/<name>.sh only - a bun .ts
                            # entrypoint has no adapter shape (HIMMEL-2021).
)

echo "== codex hook inventory parity =="

claude_end_only="$(printf '%s\n' "${CLAUDE_END_ONLY[@]}")"

# shellcheck disable=SC2016  # the node script is single-quoted on purpose: $ and
# ` inside it belong to JS/regex, and the shell values it needs arrive via env
# vars and argv, never via interpolation.
report="$(CODEX_ONLY="$CODEX_ONLY" CLAUDE_END_ONLY="$claude_end_only" node -e '
const fs = require("fs"), path = require("path");
const allow = new Set(process.env.CODEX_ONLY.split(/\s+/).filter(Boolean));
const claudeEndAllow = new Set(process.env.CLAUDE_END_ONLY.split(/\s+/).filter(Boolean));

const read = (p) => JSON.parse(fs.readFileSync(p, "utf8"));
const commands = (hooksObj) => {
  const out = [];
  for (const blocks of Object.values(hooksObj.hooks || {}))
    for (const b of blocks)
      for (const h of b.hooks || []) out.push(String(h.command || ""));
  return out;
};
const eventCommands = (hooksObj, events) => {
  const out = [];
  for (const ev of events)
    for (const b of hooksObj.hooks?.[ev] || [])
      for (const h of b.hooks || []) out.push(String(h.command || ""));
  return out;
};
const commandEntries = (hooksObj) => {
  const out = [];
  for (const blocks of Object.values(hooksObj.hooks || {}))
    for (const b of blocks)
      for (const h of b.hooks || []) out.push(h);
  return out;
};
const scriptBasenames = (command) =>
  [...command.matchAll(/([\w.-]+\.(?:sh|ts))/g)].map((m) => m[1]);

// Codex side: command selects the Unix .sh wrapper; commandWindows selects the
// Windows .cmd wrapper. Their arguments must remain identical, and one entry may
// CHAIN several guardrails into a single adapter invocation (HIMMEL-1989).
const codexJson = read(".codex/hooks.json");
const codex = new Set();
const unparsed = [];
const platformMissing = [];
const platformMismatch = [];
const dupes = [];
const commas = [];
for (const h of commandEntries(codexJson)) {
  const c = String(h.command || "");
  const cw = String(h.commandWindows || "");
  if (!c || !cw) {
    platformMissing.push("command=" + c + " commandWindows=" + cw);
    continue;
  }
  // cmd.exe splits arguments on `,`, so a comma chain reaches the adapter
  // truncated to its first element with every later guardrail silently skipped —
  // and nothing downstream can tell. It has to be refused here or nowhere.
  if (c.includes(",") || cw.includes(",")) { commas.push(c + " | " + cw); continue; }
  const m = c.match(/run-hook\.sh\s+(?:--\S+\s+)*((?:[\w.-]+\.sh)(?:\+[\w.-]+\.sh)*)\s*$/);
  const mw = cw.match(/run-hook\.cmd\s+(?:--\S+\s+)*((?:[\w.-]+\.sh)(?:\+[\w.-]+\.sh)*)\s*$/);
  if (!m || !mw) { unparsed.push(c + " | " + cw); continue; }
  const unixArgs = c.slice(c.indexOf(" "));
  const windowsArgs = cw.slice(cw.indexOf(" "));
  if (unixArgs !== windowsArgs) {
    platformMismatch.push(c + " | " + cw);
    continue;
  }
  const members = m[1].split("+");
  // A guardrail listed twice in one chain would run twice per tool call.
  const seen = new Set();
  for (const s of members) {
    if (seen.has(s)) dupes.push(s + " in " + m[1]);
    seen.add(s);
    codex.add(s);
  }
}

// Claude side: project settings + every himmel plugin hooks.json.
const claude = new Set();
const sources = [".claude/settings.json"];
const pdir = "marketplace/plugins";
for (const p of fs.existsSync(pdir) ? fs.readdirSync(pdir) : []) {
  const f = path.join(pdir, p, "hooks/hooks.json");
  if (fs.existsSync(f)) sources.push(f);
}
for (const src of sources)
  for (const c of commands(read(src)))
    for (const m of c.matchAll(/([\w.-]+\.sh)/g)) claude.add(m[1]);

// Codex has no Notification/PostToolUseFailure events; docs/internals/
// harness-compat.md marks them as not Codex events, so this
// reverse inventory is only the end-side events both harnesses can express.
const endEvents = ["Stop", "SessionEnd"];
const claudeEnd = new Set();
for (const src of sources)
  for (const c of eventCommands(read(src), endEvents))
    for (const s of scriptBasenames(c)) claudeEnd.add(s);
const codexEnd = new Set();
for (const c of eventCommands(codexJson, endEvents)) {
  const m = c.match(/run-hook\.sh\s+(?:--\S+\s+)*((?:[\w.-]+\.sh)(?:\+[\w.-]+\.sh)*)\s*$/);
  if (m) {
    for (const s of m[1].split("+")) codexEnd.add(s);
    continue;
  }
  for (const s of scriptBasenames(c)) if (s !== "run-hook.sh") codexEnd.add(s);
}

const lines = [];
lines.push("COUNT " + codex.size);
for (const s of [...codex].sort()) {
  if (!fs.existsSync(path.join("scripts/hooks", s))) lines.push("MISSING " + s);
  else if (!claude.has(s) && !allow.has(s)) lines.push("ORPHAN " + s);
}
for (const s of [...allow].sort()) if (!codex.has(s)) lines.push("STALE-ALLOW " + s);
for (const s of [...claudeEnd].sort()) {
  if (!codexEnd.has(s) && !claudeEndAllow.has(s)) lines.push("CLAUDE-END-MISSING " + s);
}
for (const s of [...claudeEndAllow].sort()) {
  if (!claudeEnd.has(s) || codexEnd.has(s)) lines.push("STALE-CLAUDE-END-ALLOW " + s);
}
// One line per offender, `|`-joined by the shell side, so a command containing
// spaces still reads as one item.
for (const c of unparsed) lines.push("UNPARSED " + c);
for (const c of platformMissing) lines.push("PLATFORM-MISSING " + c);
for (const c of platformMismatch) lines.push("PLATFORM-MISMATCH " + c);
for (const c of commas) lines.push("COMMA " + c);
for (const d of dupes) lines.push("DUPE " + d);

// The point of the dispatcher (HIMMEL-1989) is ONE chained invocation per tool
// event. That only holds while the PreToolUse matchers stay pairwise DISJOINT:
// two matching blocks means two adapter launches again, and the drift would be
// invisible in a diff. `.*` is exempt by design — it carries auto-arm-on-cap,
// which must fire for every tool AND regardless of an earlier deny, so it is the
// one deliberate second invocation.
const TOOLS = new Set(["Bash", "PowerShell", "Read", "Grep", "Edit", "Write", "MultiEdit",
                       "NotebookEdit", "Agent", "WebFetch", "mcp__plugin_atlassian_atlassian__x"]);
const matchers = [];
for (const b of codexJson.hooks.PreToolUse || []) {
  const mt = String(b.matcher || "");
  if (mt === ".*" || mt === "*") continue;
  try { matchers.push([mt, new RegExp("^(?:" + mt + ")$")]); }
  catch (e) { lines.push("BADMATCHER " + mt); }
  // Probing a hard-coded tool list alone would miss an overlap whose only shared
  // tool is one nobody listed. General regex intersection is the wrong size of
  // hammer here, so also probe every LITERAL alternative the matchers themselves
  // name: that is where realistic drift shows up (a matcher widened back to
  // `Bash|PowerShell`, or a new tool named in two blocks).
  for (const alt of mt.split("|")) if (/^[\w.]+$/.test(alt)) TOOLS.add(alt);
}
for (const t of TOOLS) {
  const hit = matchers.filter(([, re]) => re.test(t)).map(([mt]) => mt);
  if (hit.length > 1) lines.push("OVERLAP " + t + "=" + hit.join("/"));
}
console.log(lines.join("\n"));
')"

field() { printf '%s\n' "$report" | sed -n "s/^$1 //p" | tr '\n' "${2:- }"; }

assert_empty "every .codex/hooks.json entry carries both platform commands" "$(field PLATFORM-MISSING '|')"
assert_empty "every .codex/hooks.json entry uses the platform wrapper shapes" "$(field UNPARSED '|')"
assert_empty "Unix and Windows wrapper arguments stay identical" "$(field PLATFORM-MISMATCH '|')"
assert_empty "no guardrail chain uses a comma - cmd.exe would truncate it" "$(field COMMA '|')"
assert_empty "no guardrail appears twice in one chain" "$(field DUPE '|')"
assert_empty "every PreToolUse matcher is a valid regex" "$(field BADMATCHER '|')"
assert_empty "PreToolUse matchers stay disjoint - one chained invocation per tool" "$(field OVERLAP '|')"

# A parse that silently yields nothing would make every case below vacuously
# green, so the count is asserted first.
count="$(field COUNT)"; count="${count% }"
if [ -n "$count" ] && [ "$count" -gt 0 ]; then
  echo "  ok   parsed $count guardrail(s) out of .codex/hooks.json"
else
  echo "  FAIL parsed no guardrail out of .codex/hooks.json"
  fails=$((fails + 1))
fi

assert_empty "every Codex-wired guardrail exists under scripts/hooks/" "$(field MISSING)"
assert_empty "no Codex-only guardrail outside the declared allowlist" "$(field ORPHAN)"
assert_empty "no stale CODEX_ONLY allowlist entry" "$(field STALE-ALLOW)"
assert_empty "every Claude end-side hook is mirrored to Codex or declared exempt" "$(field CLAUDE-END-MISSING)"
assert_empty "no stale CLAUDE_END_ONLY allowlist entry" "$(field STALE-CLAUDE-END-ALLOW)"

# Two invariants:
#   timeout    — on EVERY event (HIMMEL-2023). Codex defaults to 600s on every
#                event but SessionEnd, so an un-budgeted entry can stall a turn
#                ten minutes. HIMMEL-1985 asserted this for the lifecycle
#                events only, which left the six PreToolUse + one PostToolUse
#                permission-gate chains — the ones on every tool call — able to
#                do exactly that.
#   --lifecycle — on the no-permission-gate events (SessionStart/
#                UserPromptSubmit/Stop) only: it tells each platform wrapper
#                there is nothing to deny here, so an adapter failure reports
#                honestly instead of emitting a PreToolUse deny envelope that
#                the event's own output schema rejects.
lifecycle="$(node -e '
const h = require(process.cwd() + "/.codex/hooks.json").hooks;
const out = [];
const nogate = ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"];
for (const ev of Object.keys(h))
  for (const b of h[ev] || [])
    for (const e of b.hooks || []) {
      const flagged = /\s--lifecycle\s/.test(e.command);
      if (typeof e.timeout !== "number") out.push("NOTIMEOUT " + ev + ":" + e.command);
      // The adapter runs a plus-joined chain SERIALLY with no per-member clamp,
      // so the entry timeout is the only bound the whole chain gets. HIMMEL-2003
      // wired the SessionStart chain at 15s — the largest of the four per-hook
      // timeouts it replaced, against the ~50s those four had between them —
      // which let one slow member eat the budget and drop its siblings.
      // (No apostrophes or backticks here: shellcheck reads this block as a
      // single-quoted shell string and SC2016 fires on both.)
      if (/\s[A-Za-z0-9._-]+\.sh\+/.test(e.command) && e.timeout < 60)
        out.push("SHORTCHAIN " + ev + ":" + e.command);
      if (!nogate.includes(ev)) {
        // The inverse matters more than the forward direction: --lifecycle on a
        // permission-gate hook would turn a fail-closed deny into a bare failure,
        // which Codex fails OPEN on.
        if (flagged) out.push("BADFLAG " + ev + ":" + e.command);
        continue;
      }
      if (!flagged) out.push("NOFLAG " + ev + ":" + e.command);
    }
console.log(out.join("\n"));
')"
lc_field() { printf '%s\n' "$lifecycle" | sed -n "s/^$1 //p" | tr '\n' '|'; }
assert_empty "every Codex hook on every event carries an explicit timeout" "$(lc_field NOTIMEOUT)"
assert_empty "every multi-member Codex chain carries at least a 60s timeout" "$(lc_field SHORTCHAIN)"
assert_empty "every Codex lifecycle hook is marked --lifecycle" "$(lc_field NOFLAG)"
assert_empty "no permission-gate Codex hook is marked --lifecycle" "$(lc_field BADFLAG)"

if [ "$fails" -eq 0 ]; then echo "OK: all cases passed"; exit 0; fi
echo "FAIL: $fails case(s) failed"; exit 1
