/**
 * Shared Instagram request throttle, node twin of ig_throttle.py (HIMMEL-4306).
 *
 * Reads and writes the SAME state file in the SAME shape as the Python module,
 * so every Instagram caller spends one budget: minimum spacing + jitter, a daily
 * cap (UTC day), exponential backoff after a failure, and a cooldown to the end
 * of the UTC day after a 429 or checkpoint/challenge. Keep the two in step; the
 * rules and the knobs are documented in ig_throttle.py.
 *
 * API:  acquire(env) -> {ok, reason, waited}   before EVERY request
 *       record(env, {httpStatus, text, ok})    after the response
 *       status(env)                            read-only
 * CLI:  node ig-throttle.mjs acquire|record|status   (exit 3 = denied)
 */
import {
  closeSync, mkdirSync, openSync, readFileSync, renameSync, statSync,
  unlinkSync, writeFileSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

const BLOCK_RE = /\b429\b|too many requests|rate.?limit|challenge|checkpoint|automated behavio|temporarily blocked|feedback_required|spam/i;
const MAX_WAIT_S = 900;
const BACKOFF_CAP_S = 3600;
const LOCK_STALE_S = 30;

const num = (env, key, dflt) => {
  const n = Number(env[key] ?? dflt);
  return Number.isFinite(n) ? n : dflt;
};

export function config(env = process.env) {
  const noSleep = Boolean(env.IG_MEDIA_NO_SLEEP);
  return {
    gap: noSleep ? 0 : num(env, "HIMMEL_IG_MIN_GAP_S", 45),
    jitter: noSleep ? 0 : num(env, "HIMMEL_IG_JITTER_S", 30),
    cap: Math.trunc(num(env, "HIMMEL_IG_DAILY_CAP", 30)),
    backoffBase: noSleep ? 0 : num(env, "HIMMEL_IG_BACKOFF_BASE_S", 60),
  };
}

export function statePath(env = process.env) {
  const override = (env.HIMMEL_IG_THROTTLE_STATE || "").trim();
  if (override) return override;
  return join(env.HOME || env.USERPROFILE || homedir(), ".himmel", "state", "instagram-throttle.json");
}

const day = (nowS) => new Date(nowS * 1000).toISOString().slice(0, 10);
const nextMidnight = (nowS) => {
  const d = new Date(nowS * 1000);
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1) / 1000;
};
const sleepMs = (ms) => new Promise((r) => setTimeout(r, ms));
const nowSeconds = () => Date.now() / 1000;

async function withLock(path, fn) {
  mkdirSync(dirname(path), { recursive: true });
  const lock = join(dirname(path), basename(path) + ".lock");
  for (let i = 0; i < 100; i++) {
    try {
      closeSync(openSync(lock, "wx"));
      break;
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
      try {
        if (Date.now() / 1000 - statSync(lock).mtimeMs / 1000 > LOCK_STALE_S) {
          unlinkSync(lock);
          continue;
        }
      } catch { /* lock vanished between the open and the stat */ }
      await sleepMs(100);
    }
  }
  try {
    return await fn();
  } finally {
    try { unlinkSync(lock); } catch { /* already gone */ }
  }
}

function load(path, nowS) {
  let data;
  try {
    data = JSON.parse(readFileSync(path, "utf-8"));
  } catch {
    data = {};
  }
  if (data === null || typeof data !== "object" || Array.isArray(data)) data = {};
  if (data.day !== day(nowS)) {
    data.day = day(nowS);
    data.count = 0;
  }
  for (const k of ["count", "failures"]) if (!Number.isInteger(data[k])) data[k] = 0;
  for (const k of ["last_slot", "backoff_until", "cooldown_until"]) {
    if (typeof data[k] !== "number") data[k] = 0;
  }
  data.version = 1;
  return data;
}

function save(path, data) {
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(Object.fromEntries(Object.entries(data).sort())) + "\n");
  renameSync(tmp, path);
}

export async function acquire(env = process.env, { now = nowSeconds, sleep = sleepMs, rng = Math.random } = {}) {
  const cfg = config(env);
  const path = statePath(env);
  let t;
  let slot;
  const denied = await withLock(path, () => {
    t = now();
    const data = load(path, t);
    if (data.cooldown_until > t) return "cooldown";
    if (data.count >= cfg.cap) return "daily-cap";
    if (data.backoff_until - t > MAX_WAIT_S) return "backoff";
    const spaced = data.last_slot + cfg.gap + (cfg.jitter ? rng() * cfg.jitter : 0);
    slot = Math.max(t, spaced, data.backoff_until);
    data.last_slot = slot;
    data.count += 1;
    save(path, data);
    return null;
  });
  if (denied) return { ok: false, reason: denied, waited: 0 };
  const wait = Math.max(0, slot - t);
  if (wait > 0) await sleep(wait * 1000);
  return { ok: true, reason: "", waited: wait };
}

export async function record(env = process.env, { httpStatus = null, text = "", ok = null, now = nowSeconds } = {}) {
  const cfg = config(env);
  const path = statePath(env);
  await withLock(path, () => {
    const t = now();
    const data = load(path, t);
    if (httpStatus === 429 || BLOCK_RE.test(text || "")) {
      data.cooldown_until = nextMidnight(t);
      data.cooldown_reason = httpStatus === 429 ? "http-429" : "challenge";
    } else if (ok === false || (httpStatus !== null && !(httpStatus >= 200 && httpStatus < 300))) {
      data.failures += 1;
      data.backoff_until = t + Math.min(BACKOFF_CAP_S, cfg.backoffBase * 2 ** (data.failures - 1));
    } else if (ok || httpStatus !== null) {
      data.failures = 0;
      data.backoff_until = 0;
    }
    save(path, data);
  });
}

export function status(env = process.env, { now = nowSeconds } = {}) {
  const cfg = config(env);
  const t = now();
  const data = load(statePath(env), t);
  const out = { state: "ok", count: data.count, cap: cfg.cap };
  if (data.cooldown_until > t) {
    Object.assign(out, { state: "cooldown", until_epoch: data.cooldown_until, reason: data.cooldown_reason || "cooldown" });
  } else if (data.count >= cfg.cap) {
    Object.assign(out, { state: "cooldown", until_epoch: nextMidnight(t), reason: "daily-cap" });
  }
  return out;
}

async function cli(argv) {
  const [op, ...rest] = argv;
  const opt = (name) => {
    const i = rest.indexOf(name);
    return i >= 0 ? rest[i + 1] : undefined;
  };
  if (op === "acquire") {
    const d = await acquire();
    console.log(JSON.stringify(d));
    return d.ok ? 0 : 3;
  }
  if (op === "record") {
    const hs = opt("--http-status");
    const okArg = opt("--ok");
    await record(process.env, {
      httpStatus: hs === undefined ? null : Number(hs),
      text: opt("--text") || "",
      ok: okArg === undefined ? null : okArg === "true",
    });
    return 0;
  }
  if (op === "status") {
    console.log(JSON.stringify(status()));
    return 0;
  }
  console.error("usage: ig-throttle.mjs acquire|record|status [--http-status N] [--text T] [--ok true|false]");
  return 1;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  cli(process.argv.slice(2)).then((code) => process.exit(code));
}
