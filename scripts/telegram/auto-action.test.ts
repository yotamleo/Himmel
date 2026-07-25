import { expect, test } from "bun:test";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  OPS, KNOWN_OPS, EXPLICIT_ONLY_OPS, SELF_EXECUTED_OPS, parseEnabledOps, describeEnabledOps, isExecutableAutoCommand,
  dispatchAutoAction, formatAuditLine, appendAuditLine, type AuditFields,
} from "./auto-action";
import type { Route } from "./router";

// Return the narrowed auto member of Route: assignable BOTH to Route (for
// isExecutableAutoCommand) and to AutoActionRoute {op,arg,time} (for
// dispatchAutoAction) — the wide `Route` union is not, since its control
// variants lack op/arg/time.
const armRoute = (over: Partial<{ arg: string; time: string }> = {}): Extract<Route, { kind: "auto" }> =>
  ({ kind: "auto", op: "arm-resume", arg: over.arg ?? "HIMMEL-389", time: over.time ?? "smart" });
// merge-public's Route variant reuses arm-resume's shape: arg = PR number, time = SHA.
const mergePublicRoute = (over: Partial<{ pr: string; sha: string }> = {}): Extract<Route, { kind: "auto" }> =>
  ({ kind: "auto", op: "merge-public", arg: over.pr ?? "123", time: over.sha ?? "abcdef123456" });

test("OPS table seeds the closed op allow-list", () => {
  expect([...KNOWN_OPS].sort()).toEqual(["arm-resume", "merge-public", "restart"]);
  expect(OPS["arm-resume"].script).toBe("arm-resume");
  expect(OPS["merge-public"].script).toBe("merge-public");
});

test("parseEnabledOps mirrors the initiative-mode grammar (fail toward inert)", () => {
  const k = KNOWN_OPS;
  // off / inert
  for (const v of [undefined, "", "0", "off", "no", "false", "  ", "bogus", "prchek"])
    expect([...parseEnabledOps(v, k)]).toEqual([]);
  // whole-value enable-all aliases enable every NON-privileged known op. merge-public
  // is EXPLICIT_ONLY (HIMMEL-1213 codex CR-2 — a privileged public merge must not ride
  // the blanket alias), so =1/all/on/yes yield ONLY arm-resume, never merge-public.
  for (const v of ["1", "all", "on", "yes", "true", "ALL"])
    expect([...parseEnabledOps(v, k)].sort()).toEqual(["arm-resume", "restart"]);
  // …and the enable-all alias explicitly does NOT include the privileged op
  for (const v of ["1", "all", "on", "yes"])
    expect(parseEnabledOps(v, k).has("merge-public")).toBe(false);
  // explicit op token, case-insensitive + whitespace-stripped
  expect([...parseEnabledOps("arm-resume", k)]).toEqual(["arm-resume"]);
  expect([...parseEnabledOps("ARM-RESUME", k)]).toEqual(["arm-resume"]);
  expect([...parseEnabledOps("  arm-resume  ", k)]).toEqual(["arm-resume"]);
  // merge-public is its OWN opt-in token — enabling arm-resume does NOT also
  // enable merge-public (ship-disabled invariant: each op is independently gated)
  expect([...parseEnabledOps("merge-public", k)]).toEqual(["merge-public"]);
  expect([...parseEnabledOps("MERGE-PUBLIC", k)]).toEqual(["merge-public"]);
  expect([...parseEnabledOps("arm-resume,merge-public", k)].sort()).toEqual(["arm-resume", "merge-public"]);
  // unknown tokens dropped
  expect([...parseEnabledOps("arm-resume,bogus", k)]).toEqual(["arm-resume"]);
  // "all" as a COMMA token is NOT enable-all (only the whole value is) — fix M1
  expect([...parseEnabledOps("all,arm-resume", k)]).toEqual(["arm-resume"]);
});

test("isExecutableAutoCommand: only a typed (caption=false), non-forwarded auto route", () => {
  expect(isExecutableAutoCommand(armRoute(), false, false)).toBe(true);
  // forwarded → refuse (injection)
  expect(isExecutableAutoCommand(armRoute(), true, false)).toBe(false);
  // caption/voice origin → refuse (fix C2)
  expect(isExecutableAutoCommand(armRoute(), false, true)).toBe(false);
  // strict === false: unknown/undefined flags refuse (fix R2#5, no fail-open)
  expect(isExecutableAutoCommand(armRoute(), undefined as any, undefined as any)).toBe(false);
  // non-auto route never executable
  expect(isExecutableAutoCommand({ kind: "chat", text: "hi" }, false, false)).toBe(false);
  // merge-public follows the SAME rule (op-agnostic gate)
  expect(isExecutableAutoCommand(mergePublicRoute(), false, false)).toBe(true);
  expect(isExecutableAutoCommand(mergePublicRoute(), true, false)).toBe(false);
  expect(isExecutableAutoCommand(mergePublicRoute(), false, true)).toBe(false);
});

test("dispatchAutoAction maps the auto-action.sh rc namespace to operator messages", async () => {
  const stub = (code: number, stdout = "", stderr = "") =>
    ({ runScript: async () => ({ code, stdout, stderr }) });

  const armed = await dispatchAutoAction(stub(0, "resolved=2026-06-20-x.md\n"), armRoute());
  expect(armed.ok).toBe(true);
  expect(armed.rc).toBe(0);
  expect(armed.resolved).toBe("2026-06-20-x.md");
  expect(armed.message).toContain("armed");
  expect(armed.message).toContain("2026-06-20-x.md");

  const noHandover = await dispatchAutoAction(stub(3), armRoute({ arg: "HIMMEL-999" }));
  expect(noHandover.ok).toBe(false);
  expect(noHandover.message).toContain("HIMMEL-999");

  const ambiguous = await dispatchAutoAction(stub(4, "", "a.md, b.md"), armRoute());
  expect(ambiguous.ok).toBe(false);
  expect(ambiguous.rc).toBe(4);
  expect(ambiguous.message.toLowerCase()).toContain("ambiguous");

  const already = await dispatchAutoAction(stub(5), armRoute());
  expect(already.ok).toBe(false);
  expect(already.message.toLowerCase()).toContain("already armed");

  const failed = await dispatchAutoAction(stub(6, "", "scheduler boom"), armRoute());
  expect(failed.ok).toBe(false);
  expect(failed.message).toContain("scheduler boom");
});

test("dispatchAutoAction maps merge-public-on-green.sh's passed-through rc to operator messages (HIMMEL-1213)", async () => {
  const stub = (code: number, stdout = "", stderr = "") =>
    ({ runScript: async () => ({ code, stdout, stderr }) });

  const merged = await dispatchAutoAction(stub(0), mergePublicRoute({ pr: "42", sha: "cafe1234beef" }));
  expect(merged.ok).toBe(true);
  expect(merged.rc).toBe(0);
  expect(merged.message).toContain("merged");
  expect(merged.message).toContain("#42");
  expect(merged.message).toContain("cafe1234beef");

  const noOpenPr = await dispatchAutoAction(stub(12, "", "merge-public-on-green: PR #42 is CLOSED"), mergePublicRoute({ pr: "42" }));
  expect(noOpenPr.ok).toBe(false);
  expect(noOpenPr.rc).toBe(12);
  expect(noOpenPr.message.toLowerCase()).toContain("not open");

  const headMoved = await dispatchAutoAction(stub(15), mergePublicRoute({ pr: "42", sha: "cafe1234beef" }));
  expect(headMoved.ok).toBe(false);
  expect(headMoved.rc).toBe(15);
  expect(headMoved.message.toLowerCase()).toContain("head moved");

  const notGreen = await dispatchAutoAction(stub(16), mergePublicRoute({ pr: "42" }));
  expect(notGreen.ok).toBe(false);
  expect(notGreen.rc).toBe(16);
  expect(notGreen.message.toLowerCase()).toContain("green");

  // any other code (bad input, wrong-repo, tool-missing, audit-unwritable,
  // merge-failed, CLAUDECODE self-refusal, ...) falls into the generic error bucket
  const err = await dispatchAutoAction(stub(19, "", "merge-public-on-green: refusing — invoked from inside a Claude Code session"), mergePublicRoute({ pr: "42" }));
  expect(err.ok).toBe(false);
  expect(err.rc).toBe(19);
  expect(err.message).toContain("Claude Code session");
});

test("dispatchAutoAction re-asserts the op against KNOWN_OPS (defense-in-depth)", async () => {
  let called = false;
  const res = await dispatchAutoAction(
    { runScript: async () => { called = true; return { code: 0, stdout: "", stderr: "" }; } },
    { kind: "auto", op: "run-named-skill" as any, arg: "x", time: "smart" } as Extract<Route, { kind: "auto" }>,
  );
  expect(called).toBe(false);     // never reaches the script
  expect(res.ok).toBe(false);
});

test("formatAuditLine emits the exact sanitized field shape", () => {
  const f: AuditFields = {
    chat_id: 5, user: 42, forwarded: true, op: "arm-resume",
    arg: "HIMMEL-1\nINJECTED", resolved: "x.md", time: "smart", rc: 0, result: "refused-forwarded",
  };
  const line = formatAuditLine(f, "2026-06-20T00:00:00.000Z");
  expect(line).toBe(
    "2026-06-20T00:00:00.000Z chat=5 user=42 fwd=1 op=arm-resume arg=HIMMEL-1 INJECTED resolved=x.md time=smart rc=0 result=refused-forwarded",
  );
  expect(line.split("\n").length).toBe(1);   // newline in arg can't forge a 2nd line (fix I4)
});

test("appendAuditLine appends a line and swallows a write failure (best-effort)", async () => {
  const dir = await mkdtemp(join(tmpdir(), "auto-audit-"));
  const audit = appendAuditLine(dir, { now: () => "2026-06-20T00:00:00.000Z" });
  const base: AuditFields = { chat_id: 1, user: 2, forwarded: false, op: "arm-resume", arg: "HIMMEL-9", time: "smart", rc: 0, result: "armed" };
  await audit(base);
  await audit({ ...base, result: "already-armed", rc: 5 });
  const log = await readFile(join(dir, "auto-action-audit.log"), "utf8");
  expect(log.trim().split("\n").length).toBe(2);   // append, not overwrite
  expect(log).toContain("result=armed");
  expect(log).toContain("result=already-armed");

  // injected writer that rejects → swallowed, no throw (best-effort contract)
  const boom = appendAuditLine(dir, { write: async () => { throw new Error("disk full"); } });
  await expect(boom(base)).resolves.toBeUndefined();
});

// --- describeEnabledOps: configured-but-inert must SAY so (HIMMEL-1270) ---

test("describeEnabledOps: a value that enables ops returns no warning", () => {
  expect(describeEnabledOps("arm-resume", KNOWN_OPS)).toEqual({ ops: new Set(["arm-resume"]) });
  expect(describeEnabledOps("arm-resume,merge-public", KNOWN_OPS).warning).toBeUndefined();
  expect(describeEnabledOps("1", KNOWN_OPS).warning).toBeUndefined();
});

test("describeEnabledOps: deliberately-off values are silent, not warnings", () => {
  for (const off of [undefined, "", "  ", "0", "off", "no", "false", "OFF"]) {
    const { ops, warning } = describeEnabledOps(off, KNOWN_OPS);
    expect(ops.size).toBe(0);
    expect(warning).toBeUndefined();
  }
});

test("describeEnabledOps: the shipped .env.example typo warns and names the bad token (HIMMEL-1270)", () => {
  // `arm` is what .env.example taught; KNOWN_OPS has `arm-resume`. It parsed to
  // the empty set and the poller logged NOTHING — indistinguishable from "off",
  // which is why the misconfiguration survived four days.
  const { ops, warning } = describeEnabledOps("arm", KNOWN_OPS);
  expect(ops.size).toBe(0);
  expect(warning).toContain("enables NOTHING");
  expect(warning).toContain("arm");
  expect(warning).toContain("arm-resume");
  expect(warning).toContain("merge-public");
});

test("describeEnabledOps: warns on an all-unknown list and reports every bad token", () => {
  const { ops, warning } = describeEnabledOps("arm, mergepub", KNOWN_OPS);
  expect(ops.size).toBe(0);
  expect(warning).toContain("arm");
  expect(warning).toContain("mergepub");
});

test("describeEnabledOps: a partially-valid list enables what it can AND names the dropped token", () => {
  // glm CR: /arm works, the "auto-actions enabled:" line looks healthy, and
  // /mergepub stays inert with no explanation — this ticket's failure in a quieter costume.
  const { ops, warning } = describeEnabledOps("arm-resume,mergepublic", KNOWN_OPS);
  // An explicit list enables EXACTLY what it names — no alias expansion.
  expect(ops).toEqual(new Set(["arm-resume"]));
  expect(warning).toContain("DROPPED");
  expect(warning).toContain("mergepublic");
});

test("describeEnabledOps: the warning states the EXPLICIT_ONLY rule (merge-public is not covered by =1)", () => {
  // The second half of the 1270 doc defect: `=1` looks like "enable everything"
  // but never turns on merge-public, and nothing said so.
  expect(describeEnabledOps("1", KNOWN_OPS).ops.has("merge-public")).toBe(false);
  expect(describeEnabledOps("arm", KNOWN_OPS).warning).toContain("named explicitly");
});

test("describeEnabledOps: the whole-value enable-all aliases are never treated as op tokens", () => {
  // `1` is not in KNOWN_OPS, but it is an alias, not a typo — warning it would be noise.
  for (const alias of ["1", "all", "on", "yes", "true", "ALL"]) {
    const { ops, warning } = describeEnabledOps(alias, KNOWN_OPS);
    expect(ops).toEqual(new Set(["arm-resume", "restart"]));
    expect(warning).toBeUndefined();
  }
});

// --- restart op (HIMMEL-1272) ---

test("restart is a known op with NO script — it is executed by the poller itself", () => {
  expect(KNOWN_OPS.has("restart")).toBe(true);
  expect(OPS["restart"].script).toBeNull();
  expect(SELF_EXECUTED_OPS.has("restart")).toBe(true);
});

test("restart is NOT explicit-only: =1/all enable it, and it is inert when unset", () => {
  // Materially less privileged than merge-public — no git write, no public repo,
  // no scheduler persistence — so it rides the ordinary enable-all alias.
  expect(EXPLICIT_ONLY_OPS.has("restart")).toBe(false);
  for (const v of ["1", "all", "on", "yes"]) expect(parseEnabledOps(v, KNOWN_OPS).has("restart")).toBe(true);
  expect(parseEnabledOps("restart", KNOWN_OPS)).toEqual(new Set(["restart"]));
  for (const v of [undefined, "", "0", "off"]) expect(parseEnabledOps(v, KNOWN_OPS).has("restart")).toBe(false);
  // …and enabling restart alone does NOT drag in the privileged op
  expect(parseEnabledOps("restart", KNOWN_OPS).has("merge-public")).toBe(false);
});

test("dispatchAutoAction REFUSES restart — a self-executed op must never reach auto-action.sh", async () => {
  let called = false;
  const res = await dispatchAutoAction(
    { runScript: async () => { called = true; return { code: 0, stdout: "", stderr: "" }; } },
    { kind: "auto", op: "restart", arg: "poller", time: "-" } as Extract<Route, { kind: "auto" }>,
  );
  expect(called).toBe(false);
  expect(res.ok).toBe(false);
  expect(res.message).toContain("not script-dispatched");
});

test("isExecutableAutoCommand applies the SAME guards to restart (op-agnostic)", () => {
  const r = { kind: "auto", op: "restart", arg: "poller", time: "-" } as Extract<Route, { kind: "auto" }>;
  expect(isExecutableAutoCommand(r, false, false)).toBe(true);
  expect(isExecutableAutoCommand(r, true, false)).toBe(false);    // forwarded
  expect(isExecutableAutoCommand(r, false, true)).toBe(false);    // caption
});
