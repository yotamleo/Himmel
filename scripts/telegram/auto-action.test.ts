import { expect, test } from "bun:test";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  OPS, KNOWN_OPS, parseEnabledOps, isExecutableAutoCommand,
  dispatchAutoAction, formatAuditLine, appendAuditLine, type AuditFields,
} from "./auto-action";
import type { Route } from "./router";

const armRoute = (over: Partial<{ arg: string; time: string }> = {}): Route =>
  ({ kind: "auto", op: "arm-resume", arg: over.arg ?? "HIMMEL-389", time: over.time ?? "smart" });

test("OPS table seeds the closed op allow-list", () => {
  expect([...KNOWN_OPS]).toEqual(["arm-resume"]);
  expect(OPS["arm-resume"].script).toBe("arm-resume");
});

test("parseEnabledOps mirrors the initiative-mode grammar (fail toward inert)", () => {
  const k = KNOWN_OPS;
  // off / inert
  for (const v of [undefined, "", "0", "off", "no", "false", "  ", "bogus", "prchek"])
    expect([...parseEnabledOps(v, k)]).toEqual([]);
  // whole-value enable-all aliases
  for (const v of ["1", "all", "on", "yes", "true", "ALL"])
    expect([...parseEnabledOps(v, k)]).toEqual(["arm-resume"]);
  // explicit op token, case-insensitive + whitespace-stripped
  expect([...parseEnabledOps("arm-resume", k)]).toEqual(["arm-resume"]);
  expect([...parseEnabledOps("ARM-RESUME", k)]).toEqual(["arm-resume"]);
  expect([...parseEnabledOps("  arm-resume  ", k)]).toEqual(["arm-resume"]);
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

test("dispatchAutoAction re-asserts the op against KNOWN_OPS (defense-in-depth)", async () => {
  let called = false;
  const res = await dispatchAutoAction(
    { runScript: async () => { called = true; return { code: 0, stdout: "", stderr: "" }; } },
    { kind: "auto", op: "run-named-skill" as any, arg: "x", time: "smart" } as Route,
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
