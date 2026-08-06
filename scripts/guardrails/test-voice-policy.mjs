#!/usr/bin/env node
// test-voice-policy.mjs — invariants for the voice action policy (HIMMEL-1522).
//
// The policy is EXPECTED to change as trust grows, so these tests pin the
// things that must survive a re-tiering, not the current tier of every action.
// A verdict moving from deny to confirm should be a one-line edit here; an
// invariant breaking should be loud.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { evaluate } from "./voice-policy-eval.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const p = JSON.parse(readFileSync(join(here, "voice-policy.json"), "utf8"));

let failures = 0;
function assert(cond, msg) {
  if (!cond) { console.error(`FAIL: ${msg}`); failures++; }
}

// 1. Shape.
assert(p.schema_version === 1, "schema_version must be 1");
assert(Array.isArray(p.rules) && p.rules.length > 0, "rules present");
assert(p.default === "confirm", "default must be confirm — never allow, so an unknown action asks");

const known = Object.keys(p.actions);
for (const [i, r] of p.rules.entries()) {
  assert(r.action === "*" || known.includes(r.action), `rule[${i}] unknown action ${r.action}`);
  assert(["allow", "confirm", "deny"].includes(r.verdict), `rule[${i}] bad verdict ${r.verdict}`);
  assert(typeof r.why === "string" && r.why.length > 0, `rule[${i}] missing why`);
}

// 2. Every action in the catalogue resolves. A documented action with no rule
//    would silently fall to default — safe, but it means the catalogue lied.
for (const a of known) {
  const { verdict } = evaluate(p, a);
  assert(["allow", "confirm", "deny"].includes(verdict), `${a} did not resolve`);
}

// 3. THE invariant: voice cannot widen its own envelope. If this ever passes,
//    every other rule in the file becomes advisory.
{
  const { verdict, rule } = evaluate(p, "policy-edit");
  assert(verdict === "deny", "policy-edit must be denied");
  assert(rule?.hard === true, "policy-edit deny must be hard");
}

// 4. Hard rules are OFF the evolution path — they must not advertise a flip
//    route, or a future editor will follow it.
for (const r of p.rules.filter(r => r.hard)) {
  assert(r.verdict === "deny", `hard rule ${r.action} must be a deny`);
  assert(/^nothing/i.test(r.flip_requires ?? ""),
    `hard rule ${r.action} must not name a real flip path (got: ${r.flip_requires})`);
}

// 5. Every NON-hard deny must document what would unlock it. The operator
//    expects to grant more over time; an undocumented deny becomes folklore.
for (const r of p.rules.filter(r => r.verdict === "deny" && !r.hard)) {
  assert(typeof r.flip_requires === "string" && r.flip_requires.length > 10,
    `deny rule ${r.action} must carry a substantive flip_requires`);
}

// 6. Read-only actions stay frictionless — the whole point of a voice assistant
//    is asking it things. If these ever require confirmation, it is unusable.
for (const a of ["read", "search", "status", "explain"]) {
  assert(evaluate(p, a).verdict === "allow", `${a} must stay allow`);
}

// 7. Nothing that writes, sends, or publishes may be `allow`. This is the line
//    that must hold no matter how the tiers are re-cut later.
for (const a of ["edit", "commit", "install", "message-outbound", "push", "merge", "deploy", "secrets", "salus"]) {
  assert(evaluate(p, a).verdict !== "allow", `${a} must never be allow over voice`);
}

// 8. An unknown action asks rather than acts.
assert(evaluate(p, "some-future-capability").verdict === "confirm",
  "unknown action must fall to confirm");

// 9. The runtime profile must actually implement the read-side HARD rules.
//    The policy denies `secrets` and `salus`, but plan mode only stops WRITES —
//    voice-permissions.json is what stops the reads. Making the pre-commit hook
//    fire on that file (codex-4) is pointless unless something checks it, so
//    assert the denies exist rather than trusting the file's presence.
{
  const profPath = join(here, "..", "voice", "voice-permissions.json");
  let prof = null;
  try { prof = JSON.parse(readFileSync(profPath, "utf8")); } catch { /* reported below */ }
  assert(prof, "voice-permissions.json must exist and parse — it carries the read-side denies");
  if (prof) {
    const deny = (prof.permissions?.deny ?? []).join("\n").toLowerCase();
    assert(deny.includes("salus"), "voice profile must deny reads of salus (policy denies the salus action)");
    assert(deny.includes(".env"), "voice profile must deny reads of .env (policy marks `secrets` HARD)");
    assert(/\.ssh|\.pem|\.key|id_rsa|credential/.test(deny),
      "voice profile must deny reads of key/credential material (policy marks `secrets` HARD)");
    // CR round 6 — the list claimed to enforce the HARD `secrets` rule while
    // omitting the one file that holds this harness's own MCP API keys.
    assert(deny.includes(".claude.json"),
      "voice profile must deny reads of .claude.json — it holds MCP server specs including API keys");
    // Bash is denied outright, not pattern-matched: a deny-list over ways to
    // read a file (cat, head, less, awk, python -c, Get-Content, ...) cannot be
    // completed, so successive review rounds just kept finding the next one.
    assert((prof.permissions?.deny ?? []).some(r => r === "Bash" || r.startsWith("Bash(")),
      "voice profile must deny Bash — pattern-matching read commands is not completable");
    // Both shells, or neither (CR round 9). Denying Bash while leaving
    // PowerShell enabled is incoherent on a Windows-primary machine: plan mode
    // blocks writes, not Invoke-WebRequest, so a full shell remains an egress
    // path on a channel that cannot authenticate its speaker.
    assert((prof.permissions?.deny ?? []).some(r => r === "PowerShell" || r.startsWith("PowerShell(")),
      "voice profile must deny PowerShell as well as Bash — it is a full shell with its own egress verbs");
    // Round 6 gave voice its own session id so it could not --resume the
    // operator's typed session. That closed the resume path; the transcript
    // FILES were still readable, which is the same exposure by another route.
    assert(deny.includes(".claude/projects"),
      "voice profile must deny the session-transcript store — isolating the session does not isolate the JSONL it wrote");

    // PATTERN SHAPE. A rule that matches nothing denies NOTHING while looking
    // like a complete deny list. This assertion previously REQUIRED the absence
    // of a `//` prefix and was exactly wrong — it enforced the inert form.
    //
    // Measured against a live spawn, same rules, only cwd changed: a bare
    // `Read(**/salus/**)` is resolved relative to the project root, so a read
    // of a salus path OUTSIDE the himmel checkout SUCCEEDED. `//` anchors at
    // the filesystem root and refuses it. Everything this profile exists to
    // protect — the salus vault, ~/.ssh, ~/.aws, ~/.env — lives outside the
    // repo, so the relative form covered none of it.
    //
    // Only `Read(...)` rules participate in file-permission checks: a lone
    // `Read(//**/salus/**)` blocks Grep as well, `Glob(...)` rules are rejected
    // with a per-turn warning, and `Grep(...)` rules are SILENTLY inert (a
    // profile carrying only `Grep(//**/salus/**)` let the Grep through). So the
    // per-tool duplicates are not defence in depth, they are decoration — and
    // decoration is what made this control unfalsifiable for five rounds.
    for (const r of prof.permissions?.deny ?? []) {
      assert(/^[A-Z][A-Za-z]*(\(.*\))?$/.test(r), `deny rule ${r} is not a Tool or Tool(pattern) form`);
      const tool = r.split("(")[0];
      // Read(...) for file access, plus the two SHELL tools which are denied
      // wholesale rather than pattern-matched. Everything else is decoration:
      // Glob(...) warns per rule on every turn, Grep(...) fails silently.
      assert(tool === "Read" || tool === "Bash" || tool === "PowerShell",
        `deny rule ${r} uses tool '${tool}' — only Read(...) rules are matched by file permission checks; Glob(...) warns and Grep(...) fails silently`);
      if (r.startsWith("Read(")) {
        assert(r.startsWith("Read(//"),
          `deny rule ${r} lacks the '//' filesystem-root anchor — it would resolve relative to the project root and cover nothing outside the repo`);
      }
    }
  }

  // 10. The runtime files must actually APPLY the profile and the plan floor —
  //     and must FAIL CLOSED without it. Checking for a bare substring was
  //     satisfiable by a COMMENT mentioning the filename, so these assert the
  //     real call shape instead.
  const runtime = [
    ["jarvis.py", /"--settings",\s*settings/, /"--permission-mode",\s*"plan"/, /REFUSED|return\s+"My permission profile is missing/],
    ["voice-loop.ps1", /\$claudeArgs\s*\+=\s*@\('--settings'/, /ValidateSet\('plan'\)/, /throw\s+"voice-permissions\.json missing/],
  ];
  for (const [f, passesProfile, pinsPlan, failsClosed] of runtime) {
    let src = "";
    try { src = readFileSync(join(here, "..", "voice", f), "utf8"); } catch { /* asserted below */ }
    assert(src.length > 0, `${f} must be readable`);
    assert(passesProfile.test(src), `${f} must actually PASS --settings (not merely mention the file)`);
    assert(pinsPlan.test(src), `${f} must pin plan mode in code (not merely mention "plan")`);
    assert(failsClosed.test(src), `${f} must FAIL CLOSED when the profile is missing, not warn and continue`);
  }

  // 11. CR round 6 — three confirmed bypasses that this file's deny rules
  //     structurally CANNOT cover, so they are asserted on the launchers.
  //     Every pattern below matches the real call shape; a mention of the flag
  //     in a comment must not satisfy it (the round-5 lesson).
  const round6 = [
    ["jarvis.py", [
      [/"--strict-mcp-config"/,
        "must pass --strict-mcp-config — an MCP tool is not Read/Bash/Grep, so no deny rule can reach it"],
      [/"--append-system-prompt",\s*VOICE_PROMPT,\s*"--",\s*text/,
        "must pass `--` immediately before the transcript — it shares an argv with the permission floor"],
    ]],
    ["voice-loop.ps1", [
      [/'--strict-mcp-config'/,
        "must pass --strict-mcp-config — an MCP tool is not Read/Bash/Grep, so no deny rule can reach it"],
      [/\$claudeArgs\s*\+=\s*'--'\s*\r?\n\s*\$claudeArgs\s*\+=\s*\$said/,
        "must pass `--` immediately before the transcript — it shares an argv with the permission floor"],
      [/\$claudeArgs\s*\+=\s*@\('--session-id',\s*\$voiceSessionId\)/,
        "must create a voice-OWNED session id"],
      [/\$claudeArgs\s*\+=\s*@\('--resume',\s*\$voiceSessionId\)/,
        "must resume only its own session id"],
    ]],
  ];
  for (const [f, checks] of round6) {
    let src = "";
    try { src = readFileSync(join(here, "..", "voice", f), "utf8"); } catch { /* asserted below */ }
    assert(src.length > 0, `${f} must be readable`);
    for (const [re, why] of checks) assert(re.test(src), `${f} ${why}`);

    // --strict-mcp-config only isolates MCP while NO --mcp-config accompanies
    // it: the flag means "use only the servers from --mcp-config", so supplying
    // one turns the deny back into an allow. The profile's header says exactly
    // this and says nothing in that file can warn you — so the warning lives
    // here. Comment-aware: strip // and # lines first, or the very sentence
    // documenting the hazard would trip the assertion.
    const code = src
      .split(/\r?\n/)
      .filter(l => !/^\s*(#|\/\/)/.test(l))
      .join("\n");
    assert(!/--mcp-config/.test(code),
      `${f} must NOT pass --mcp-config — it re-opens the MCP surface that --strict-mcp-config closes`);
  }

  // Directory-global `--continue` resumes whatever session ran last in the cwd
  // — including the operator's own typed session, whose context could then be
  // spoken aloud with no file read at all. Assert the ARGV shape specifically,
  // so the explanatory comments naming `--continue` do not satisfy it.
  {
    let src = "";
    try { src = readFileSync(join(here, "..", "voice", "voice-loop.ps1"), "utf8"); } catch { /* reported above */ }
    assert(!/\$claudeArgs\s*\+=\s*'--continue'/.test(src),
      "voice-loop.ps1 must NOT pass claude's directory-global --continue — it can resume the operator's own session");
  }
}

if (failures) { console.error(`\nvoice-policy: ${failures} invariant(s) FAILED`); process.exit(1); }
console.log("voice-policy: all invariants pass");
