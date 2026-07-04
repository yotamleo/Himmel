// scripts/telegram/grants.ts
// GLM-worker escalation channel (HIMMEL-654) — shared PURE helpers consumed by
// both `spawn-glm --grant` (pre-seed) and the `adjudicate` CLI. Spec §D4/D7/D9.
// No fs, no spawn, no network: every helper is pure so each refusal branch and
// the shape classifier are unit-testable with no fixtures.
//
// A grant whitelists ONE command shape on ONE deny arm, TTL- and use-bounded.
// The deny hook (block-glm-external-writes.sh) folds valid grant patterns into
// the arm's single-alternation allowed count; this module only AUTHORS lines —
// the hook is the consumer.

export type GrantArm = "git-push" | "git-url" | "gh" | "network";
export type GrantShape = "read" | "write";
export type GrantSpec = { arm: GrantArm; pattern: string; ttlMins: number; maxUses: number };

export type GrantResult = { ok: true; spec: GrantSpec } | { ok: false; error: string };

const ARMS: GrantArm[] = ["git-push", "git-url", "gh", "network"];

// §D4 validity gate — reject (ok:false) anything that could smuggle or over-grant.
// The hook re-checks the anchor before honoring; this gate is the authoring mirror.
export function validateGrantSpec(raw: { arm?: string; pattern?: string; ttlMins?: number; maxUses?: number }): GrantResult {
  const { arm, pattern, ttlMins, maxUses } = raw;
  if (!arm || !(ARMS as string[]).includes(arm)) return { ok: false, error: `unknown arm "${arm}"` };
  if (!pattern || pattern.length === 0) return { ok: false, error: "pattern is empty" };
  // F2: no unbounded .* / .+ at command position (allow-everything).
  if (/^\.[*+]/.test(pattern)) return { ok: false, error: "pattern begins with an unbounded .* /.+ (F2)" };
  // F8: pattern must begin with the arm's DENY-SHAPE anchor.
  const anchorErr = anchorError(arm as GrantArm, pattern);
  if (anchorErr) return { ok: false, error: anchorErr };
  if (typeof ttlMins !== "number" || !Number.isFinite(ttlMins) || ttlMins <= 0) return { ok: false, error: "ttlMins must be a finite number > 0" };
  if (typeof maxUses !== "number" || !Number.isInteger(maxUses) || maxUses <= 0) return { ok: false, error: "maxUses must be a positive integer" };
  return { ok: true, spec: { arm: arm as GrantArm, pattern, ttlMins, maxUses } };
}

// F8 anchor check per arm. The pattern is an ERE fragment in the hook's
// command-position grammar; these mirror the deny-shape each arm counts so
// `arm_allowed ⊆ arm_total` holds (spec §D4).
function anchorError(arm: GrantArm, pattern: string): string | null {
  switch (arm) {
    case "gh":
      // gh family: must begin with `gh` + a space matcher.
      if (!/^gh(\[\[:space:\]\]|\s)/.test(pattern)) return "gh pattern must begin with 'gh' + space matcher (F8)";
      return null;
    case "network":
      // network family: must begin with one of the network-CLI tokens.
      if (!/^(\()?(curl|wget|invoke-webrequest|invoke-restmethod|iwr|irm)/.test(pattern)) return "network pattern must begin with a network CLI token (F8)";
      return null;
    case "git-push":
      // git family SUBSET: begin with `git` AND carry a `push` subcommand token.
      if (!/^git/.test(pattern)) return "git-push pattern must begin with 'git' (F8)";
      if (!/(\[\[:space:\]\]|\s|\)|\+)push/.test(pattern)) return "git-push pattern must contain a 'push' subcommand token (F8)";
      return null;
    case "git-url":
      // git family SUBSET: begin with `git` AND carry a `url` token — the literal
      // `url` appears in both sanctioned shapes (`remote[[:space:]]+set-url` and
      // `config …[^space]*url`) and in no other git subcommand, so it anchors the
      // arm without the brittle preceding-char class that rejected the canonical
      // `[[:space:]]+set-url` (with the `+` quantifier) and `remote.origin.url`.
      if (!/^git/.test(pattern)) return "git-url pattern must begin with 'git' (F8)";
      if (!/url/.test(pattern)) return "git-url pattern must contain a set-url / …url token (F8)";
      return null;
  }
}

// Split '<arm>|<pattern>|<ttl_mins?>|<max_uses?>' (ttl/uses optional; ttl default
// 60, uses default 1). The pattern is an ERE and may itself contain '|' (e.g.
// `([[:space:]]|$)`), so only trailing numeric tokens are peeled as ttl/uses.
export function parseGrantFlag(raw: string): GrantResult {
  const parts = raw.split("|");
  if (parts.length < 2) return { ok: false, error: "grant flag needs <arm>|<pattern>[|<ttl_mins>|<max_uses>]" };
  const arm = parts[0];
  const isPosNum = (s: string) => { const n = Number(s); return Number.isFinite(n) && n > 0; };
  const isPosInt = (s: string) => { const n = Number(s); return Number.isInteger(n) && n > 0; };
  let ttlMins = 60;
  let maxUses = 1;
  let end = parts.length; // exclusive slice end for the pattern tokens
  // Two trailing numeric tokens => uses (int) + ttl (number).
  if (parts.length >= 4 && isPosInt(parts[parts.length - 1]) && isPosNum(parts[parts.length - 2])) {
    maxUses = Number(parts[parts.length - 1]);
    ttlMins = Number(parts[parts.length - 2]);
    end = parts.length - 2;
  } else if (parts.length >= 3 && isPosNum(parts[parts.length - 1])) {
    // One trailing numeric token => ttl only.
    ttlMins = Number(parts[parts.length - 1]);
    end = parts.length - 1;
  }
  const pattern = parts.slice(1, end).join("|");
  return validateGrantSpec({ arm, pattern, ttlMins, maxUses });
}

// §D7 shape classifier. `gh api` with the default method or an explicit GET and
// NO body flag is a read; any other method or any body flag is a write. A few
// genuinely-read gh subcommands the hook denies (release view, repo view) are
// read too. Every non-gh arm is a write (the hook blocks network CLIs precisely
// because it will not parse GET from POST).
export function classifyShape(arm: GrantArm, capability: string): GrantShape {
  if (arm !== "gh") return "write";
  // The pre-seed/adjudicate paths pass a grant PATTERN, which encodes spaces as
  // the bash class token [[:space:]] (with an optional +/* quantifier); a literal
  // command carries no such token. Normalize the token to one space so the shape
  // tests below match both forms — else a `gh[[:space:]]+api` read pattern would
  // miss the `gh api` test and be misclassified write (wrongly refused when auto).
  const c = capability.replace(/\[\[:space:\]\][+*]?/g, " ");
  if (/(^|\s)gh\s+api(\s|$)/.test(c)) {
    // Body flag => write regardless of method.
    if (/(^|\s)-(f|F)(\s|=|$)|(^|\s)--(field|raw-field|input)(\s|=|$)/.test(c)) return "write";
    // -x/-X and --method matched case-INSENSITIVELY: grant patterns target the
    // hook's lowercased command grammar (`-x put`), so a case-sensitive `-X`
    // would miss a method-write pattern and fall through to "read" — letting the
    // autonomous read-only gate auto-author a PUT/DELETE grant (CR-found).
    const m = c.match(/(^|\s)-x\s+(\S+)|(^|\s)--method\s+(\S+)/i);
    if (m) {
      const method = (m[2] ?? m[4]).toUpperCase();
      return method === "GET" ? "read" : "write";
    }
    return "read"; // default method (no -X/--method) is GET
  }
  if (/(^|\s)gh\s+(release|repo)\s+view(\s|$)/.test(c)) return "read";
  return "write";
}

// `g<N>` where N = (existing grant lines) + 1. Feeds the pre-seed loop the
// GROWING line-set so repeated --grant flags get distinct ids (g1, g2, …).
export function nextGrantId(existingLines: string[]): string {
  const n = existingLines.filter((l) => /"type"\s*:\s*"grant"/.test(l)).length;
  return `g${n + 1}`;
}

// One grant JSON line (spec §JSON line shapes). `shape` via classifyShape;
// `expires_at = now + ttlMins`. The capability is a human echo (audit only).
export function composeGrantLine(spec: GrantSpec, o: { capability: string; grantId: string; grantedBy: string; now: Date }): string {
  const shape = classifyShape(spec.arm, o.capability);
  const expires_at = new Date(o.now.getTime() + spec.ttlMins * 60_000).toISOString();
  return JSON.stringify({
    type: "grant",
    grant_id: o.grantId,
    arm: spec.arm,
    pattern: spec.pattern,
    capability: o.capability,
    shape,
    expires_at,
    max_uses: spec.maxUses,
    granted_by: o.grantedBy,
    ts: o.now.toISOString(),
  });
}

// Autonomous authority gate (spec §D7). An autonomous authoring context may emit
// READ-shaped grants only; a write-shaped request is recorded as a pending
// operator escalation (the caller writes the escalation line), not a grant.
export function authorityGate(shape: GrantShape, autonomous: boolean): { action: "grant" } | { action: "pending-escalation" } {
  if (autonomous && shape === "write") return { action: "pending-escalation" };
  return { action: "grant" };
}

// One escalation JSON line for a write-shaped grant the authority gate refused
// (spec §JSON line shapes). The single tested composer for the write-refused →
// escalation-line path (criterion 10 writer side) — callers append it verbatim.
export function composeEscalationForRefusedGrant(o: { capability: string; arm: GrantArm; reason?: string; step?: string; now: Date }): string {
  const obj: { type: string; capability: string; arm: GrantArm; reason?: string; step?: string; ts: string } = {
    type: "escalation",
    capability: o.capability,
    arm: o.arm,
    ts: o.now.toISOString(),
  };
  if (o.reason !== undefined) obj.reason = o.reason;
  if (o.step !== undefined) obj.step = o.step;
  return JSON.stringify(obj);
}

// ── HIMMEL-682: respawn grant carry-forward (Task L1) ────────────────────────
// A capped session's still-valid grants must survive the cap→respawn cycle as
// ABSOLUTE state: the ORIGINAL expires_at (the TTL clock does NOT restart) plus a
// remaining budget (max_uses − consumptions). `carryGrants` reads the surviving
// `grants.jsonl` and returns the survivors; the SEED decision (shape-split
// authorityGate) and grant_id assignment live in `seedCarriedGrants`, so a
// re-gated write leaves no id gap. Reads seed un-gated (F4 preserved); writes
// re-gate — an autonomous respawn re-escalates a carried write for operator
// re-adjudication. This is load-bearing: `--carry-from <dir>` is caller argv and
// `grants.jsonl` has no tamper-evidence, so "the file is trusted" is not a
// boundary; un-gating a carried WRITE would reopen the authorityGate bypass the
// channel exists to prevent. Un-gating reads is safe (no authority beyond the
// autonomous default). Design: specs/design/escalation-channel-l1-carry-syntax.md.
export type CarriedGrant = { readonly arm: GrantArm; readonly pattern: string; readonly capability: string; readonly shape: GrantShape; readonly expiresAt: string; readonly remaining: number; readonly grantedBy: string };

export function carryGrants(lines: string[], now: Date): CarriedGrant[] {
  const consumed = new Map<string, number>();
  const grants: Array<Record<string, unknown>> = [];
  for (const line of lines) {
    let o: Record<string, unknown>;
    try { o = JSON.parse(line); } catch { continue; }        // guarded: skip malformed
    if (o?.type === "consumption" && typeof o.grant_id === "string") {
      consumed.set(o.grant_id, (consumed.get(o.grant_id) ?? 0) + 1);
    } else if (o?.type === "grant") {
      grants.push(o);
    }
  }
  const nowIso = now.toISOString().slice(0, 19);            // UTC, 19-char, matches the deny hook's ${gexp:0:19}
  const out: CarriedGrant[] = [];
  for (const g of grants) {
    const arm = g.arm, pattern = g.pattern, expires_at = g.expires_at, max_uses = g.max_uses, grant_id = g.grant_id;
    // skip any grant missing a required field, unknown arm, or a short/odd expiry
    if (typeof arm !== "string" || !(ARMS as string[]).includes(arm)) continue;
    if (typeof pattern !== "string" || typeof grant_id !== "string") continue;
    if (typeof expires_at !== "string" || expires_at.length < 19) continue;
    if (typeof max_uses !== "number") continue;
    const remaining = max_uses - (consumed.get(grant_id) ?? 0);
    if (remaining <= 0) continue;                            // exhausted → drop
    if (nowIso >= expires_at.slice(0, 19)) continue;         // expired (19-char lexicographic) → drop
    // Funnel through the SAME validity gate as --grant (F2 no-leading-unbounded-
    // .*, F8 arm anchor, positive-int max_uses) so a carried grant is never
    // broader than one --grant would author — a forged --carry-from file cannot
    // seed a pattern the authoring path rejects (CR round 2, codex-6). ttlMins
    // is a positive placeholder; the real absolute expiry was checked above.
    if (!validateGrantSpec({ arm, pattern, ttlMins: 1, maxUses: remaining }).ok) continue;
    out.push({
      arm: arm as GrantArm,
      pattern,
      capability: typeof g.capability === "string" ? g.capability : pattern,
      shape: classifyShape(arm as GrantArm, pattern),        // RE-DERIVE from arm+pattern (anti-spoof; never trust stored shape)
      expiresAt: expires_at,
      remaining,
      grantedBy: typeof g.granted_by === "string" ? g.granted_by : "parent:spawn-glm",
    });
  }
  return out;
}

// One seed line for a carried grant that passed the gate — ABSOLUTE expires_at
// (NOT now + ttl) and max_uses = remaining. `carried:true` is audit metadata the
// deny hook ignores (it reads only arm/pattern/max_uses/grant_id/expires_at).
export function composeCarriedGrantLine(c: CarriedGrant, o: { grantId: string; now: Date }): string {
  return JSON.stringify({
    type: "grant",
    grant_id: o.grantId,
    arm: c.arm,
    pattern: c.pattern,
    capability: c.capability,
    shape: c.shape,
    expires_at: c.expiresAt,
    max_uses: c.remaining,
    granted_by: c.grantedBy,
    ts: o.now.toISOString(),
    carried: true,
  });
}

// Shape-split gate for carried grants (mirrors the --grant pre-seed loop): READ
// → seed line; WRITE under autonomous authority → pending-escalation (re-escalate,
// NOT seeded). `existing` seeds nextGrantId so ids continue past any grants
// already in the session; only gate-passed grants consume an id (refused writes
// leave no gap).
export function seedCarriedGrants(carried: CarriedGrant[], autonomous: boolean, existing: string[], now: Date): { grantLines: string[]; escalationLines: string[] } {
  const grantLines: string[] = [];
  const escalationLines: string[] = [];
  const acc = [...existing];
  for (const c of carried) {
    if (authorityGate(c.shape, autonomous).action === "grant") {
      const line = composeCarriedGrantLine(c, { grantId: nextGrantId(acc), now });
      grantLines.push(line);
      acc.push(line);
    } else {
      escalationLines.push(composeEscalationForRefusedGrant({ capability: c.capability, arm: c.arm, reason: "autonomous refuses carried write grant — operator re-adjudication required", step: "carry", now }));
    }
  }
  return { grantLines, escalationLines };
}
