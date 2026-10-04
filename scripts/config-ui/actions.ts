// HIMMEL-4254 P4: the closed action table (spec §5.2). Every argv is built
// from constants here plus a target validated against a frozen list and, for
// config.*, a value from {on, off}. No feed text ever reaches an argv.
import { execFileSync } from "node:child_process";

export type Consent = { kind: "typed" | "plain"; expect: string | null };
export type Resolved = {
  action: string; target: string; value: string | null;
  argv: string[]; dryArgv: string[]; consent: Consent; cwd: string; timeoutMs: number;
  effect: string; bank: string; rowIds: string[];
};
export type Ctx = { root: string; cadenceRoot: string; himmelctl: string; platform: string; plugins: readonly string[]; lanes: readonly string[] };
type Spec = {
  targets: readonly string[];
  argv: (t: string, v: string | null) => string[];
  consent: "typed" | "plain";
  cwd: string; timeoutMs: number; effect: string;
  bank: (t: string) => string;
  needsValue: boolean;
  rowIds: (t: string) => string[];
};
export type Table = ReadonlyMap<string, Readonly<Spec>>;

export class ActionError extends Error {}

const CADENCE_TIMEOUT_MS = 120_000;
const HIMMELCTL_TIMEOUT_MS = 60_000;
const ID_RE = /^[a-z0-9@._-]+$/;
const VALUES: readonly string[] = Object.freeze(["on", "off"]);
// The plugins plugin-profile.sh refuses to disable (critic G11): never a target.
export const FLOOR: readonly string[] = Object.freeze(["handover@himmel", "himmel-ops@himmel", "qmd@himmel"]);
// merge and public are guard-class (critic F4): shown, never toggled here.
const INITIATIVE: readonly string[] = Object.freeze(["execute", "prcheck", "pr", "ticket", "handover"]);
const CADENCE_PATH: Readonly<Record<string, string>> = Object.freeze({
  pipeline: "scripts/luna/pipeline-cadence.sh",
  graphmap: "scripts/luna/graphmap-cadence.sh",
  qmd: "scripts/luna/qmd-cadence.sh",
  "codex-sweep": "scripts/cleanup/codex-sweep-cadence.sh",
  doctor: "scripts/doctor-cadence.sh",
});
// Shown in the consent text (critic F3); mirrors config-feed.js CADENCES[].cost.
const CADENCE_BANK: Readonly<Record<string, string>> = Object.freeze({
  pipeline: "runs Claude-backed harvest/synthesize and draws the subscription bank",
  graphmap: "weekly claude-cli extraction; draws the subscription bank",
  qmd: "none (local qmd reindex)",
  "codex-sweep": "none",
  doctor: "none",
});

export const validId = (s: unknown): s is string => typeof s === "string" && s.length <= 64 && ID_RE.test(s) && !s.startsWith("-");

// D1: plugin and lane targets come from the git-TRACKED registries at HEAD, so
// a dirty working-tree edit cannot widen them, and never from *.local.json.
// Any git failure fails closed to no plugin or lane targets.
function gitJson(root: string, path: string): any {
  try { return JSON.parse(execFileSync("git", ["-C", root, "show", `HEAD:${path}`], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 10_000 })); }
  catch { return null; }
}
export function loadRegistries(root: string): { plugins: string[]; lanes: string[] } {
  const tmpl = gitJson(root, "docs/setup/settings-template.json");
  const lanesReg = gitJson(root, "scripts/lanes/lanes.json");
  const plugins = Object.keys((tmpl && typeof tmpl.onDemandPlugins === "object" && tmpl.onDemandPlugins) || {})
    .filter((p) => validId(p) && !FLOOR.includes(p));
  const lanes = (lanesReg && Array.isArray(lanesReg.lanes) ? lanesReg.lanes : [])
    .map((l: { id?: unknown }) => l && l.id).filter(validId);
  return { plugins, lanes };
}

export function buildTable(ctx: Ctx): Table {
  const h = (...a: string[]) => ["node", ctx.himmelctl, ...a];
  const cadences = Object.keys(CADENCE_PATH).filter((c) => c !== "codex-sweep" || ctx.platform === "win32");
  const none = () => "none";
  const cadence = (verb: string): Spec => ({
    targets: cadences, argv: (t) => ["bash", `${ctx.cadenceRoot}/${CADENCE_PATH[t]}`, verb], consent: "typed",
    cwd: ctx.root, timeoutMs: CADENCE_TIMEOUT_MS, effect: "at the next scheduled fire", bank: (t) => CADENCE_BANK[t],
    needsValue: false, rowIds: (t) => [`${t}-cadence`],
  });
  const plugin = (verb: string): Spec => ({
    targets: ctx.plugins, argv: (t) => h("profile", verb, t), consent: "plain",
    cwd: ctx.root, timeoutMs: HIMMELCTL_TIMEOUT_MS, effect: "next Claude launch", bank: none,
    needsValue: false, rowIds: (t) => [`plugin:${t}`],
  });
  const config = (ns: string, targets: readonly string[], row: string): Spec => ({
    targets, argv: (t, v) => h("config", "set", `${ns}.${t}`, v as string), consent: "plain",
    cwd: ctx.root, timeoutMs: HIMMELCTL_TIMEOUT_MS, effect: ns === "lanes" ? "next dispatch" : "next Claude launch", bank: none,
    needsValue: true, rowIds: (t) => [`${row}:${t}`],
  });
  const specs: [string, Spec][] = [
    ["cadence.arm", cadence("arm")],
    ["cadence.disarm", cadence("disarm")],
    ["plugin.enable", plugin("enable")],
    ["plugin.disable", plugin("disable")],
    ["profile.set", {
      targets: ["lean", "full"], argv: (t) => h("profile", t), consent: "typed",
      cwd: ctx.root, timeoutMs: HIMMELCTL_TIMEOUT_MS, effect: "next Claude launch", bank: none,
      needsValue: false, rowIds: () => ctx.plugins.map((p) => `plugin:${p}`),
    }],
    ["config.lanes", config("lanes", ctx.lanes, "lane")],
    ["config.initiative", config("initiative", INITIATIVE, "initiative")],
  ];
  for (const [, s] of specs) { Object.freeze(s.targets); Object.freeze(s); }
  const m = new Map(specs);
  // A frozen Map still has set/delete; shadow them so the table cannot change.
  for (const k of ["set", "delete", "clear"] as const) Object.defineProperty(m, k, { value: () => { throw new TypeError("action table is frozen"); } });
  return Object.freeze(m);
}

export function resolveAction(table: Table, action: unknown, target: unknown, value?: unknown): Resolved {
  if (typeof action !== "string" || !table.has(action)) throw new ActionError("unknown action");
  const s = table.get(action)!;
  if (!validId(target) || !s.targets.includes(target)) throw new ActionError("target not offered for this action");
  let v: string | null = null;
  if (s.needsValue) {
    if (typeof value !== "string" || !VALUES.includes(value)) throw new ActionError("value must be on or off");
    v = value;
  } else if (value !== undefined && value !== null) throw new ActionError("this action takes no value");
  const argv = s.argv(target, v);
  return {
    action, target, value: v, argv, dryArgv: [...argv, "--dry-run"],
    consent: { kind: s.consent, expect: s.consent === "typed" ? target : null },
    cwd: s.cwd, timeoutMs: s.timeoutMs, effect: s.effect, bank: s.bank(target), rowIds: s.rowIds(target),
  };
}
