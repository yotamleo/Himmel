// scripts/alibaba/create-monitoring-key.ts (HIMMEL-729)
// One-shot bootstrap: derive a SCOPED, read-only monitoring key from the
// operator's MASTER Alibaba AK/SK, so the quota-gauge poller never holds
// account-level credentials (operator directive 2026-07-06: masters stay
// parked in 1Password; automation reads .env only — interactive 1Password
// auth would hang unattended runs).
//
// What it does (idempotent, run with: bun scripts/alibaba/create-monitoring-key.ts):
//   1. Reads the MASTER pair from ALIBABA_QUOTA_AK / ALIBABA_QUOTA_SK
//      (process.env first, then repo-root .env — same resolution style as
//      glm-env.ts readZaiKey).
//   2. RAM API (ram.aliyuncs.com, version 2015-05-01, ACS3-HMAC-SHA256):
//      GetUser claude-monitoring -> CreateUser if absent;
//      AttachPolicyToUser System/CloudMonitorReadOnlyAccess (tolerates
//      EntityAlreadyExists.User.Policy); ListAccessKeys -> refuses a second
//      key unless --rotate (deletes inactive/oldest first is NOT done —
//      rotation deletes ALL existing keys for the user, it is a scoped user
//      with no other consumers); CreateAccessKey.
//   3. Rewrites repo-root .env in place: ALIBABA_QUOTA_AK/SK now carry the
//      SCOPED pair. The master values are NOT printed, NOT backed up to disk
//      (they remain recorded in 1Password).
//
// SECURITY: this script never prints a secret. Output is limited to masked
// key ids (first3...last3), API error codes, and progress lines.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { createHash, createHmac, randomUUID } from "node:crypto";

const RAM_HOST = "ram.aliyuncs.com";
const RAM_VERSION = "2015-05-01";
const USER_NAME = "claude-monitoring";
const POLICY = "AliyunCloudMonitorReadOnlyAccess";

// --- .env resolution (readZaiKey style: process.env, then repo .env, then the
// MAIN checkout's .env when running from a worktree — worktree .env is absent).
function repoRoot(): string {
  // walk up from this file: scripts/alibaba/ -> repo root
  return resolve(join(dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1")), "..", ".."));
}

function mainCheckoutRoot(root: string): string | undefined {
  try {
    const r = Bun.spawnSync(["git", "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir"], { stdout: "pipe", stderr: "pipe" });
    if (r.exitCode !== 0) return undefined;
    const commonDir = r.stdout.toString().trim();
    if (!commonDir) return undefined;
    const parent = dirname(commonDir);
    return resolve(parent) !== resolve(root) ? parent : undefined;
  } catch { return undefined; }
}

function parseEnvFile(path: string): Record<string, string> {
  const out: Record<string, string> = {};
  if (!existsSync(path)) return out;
  for (const raw of readFileSync(path, "utf8").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    const k = line.slice(0, eq).trim();
    let v = line.slice(eq + 1).trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    out[k] = v;
  }
  return out;
}

function mask(id: string): string {
  return id.length <= 6 ? "***" : `${id.slice(0, 3)}...${id.slice(-3)}`;
}

// --- ACS3-HMAC-SHA256 signing (RPC style, GET, empty payload) ---------------
function pctEncode(s: string): string {
  return encodeURIComponent(s)
    .replace(/\!/g, "%21").replace(/\'/g, "%27")
    .replace(/\(/g, "%28").replace(/\)/g, "%29").replace(/\*/g, "%2A");
}

async function ramCall(
  ak: string, sk: string, action: string, params: Record<string, string>,
): Promise<{ ok: boolean; status: number; code?: string; body: any }> {
  const query: Record<string, string> = { ...params };
  const sortedKeys = Object.keys(query).sort();
  const canonicalQuery = sortedKeys.map((k) => `${pctEncode(k)}=${pctEncode(query[k])}`).join("&");
  const payloadHash = createHash("sha256").update("").digest("hex");
  const headers: Record<string, string> = {
    host: RAM_HOST,
    "x-acs-action": action,
    "x-acs-content-sha256": payloadHash,
    "x-acs-date": new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    "x-acs-signature-nonce": randomUUID(),
    "x-acs-version": RAM_VERSION,
  };
  const signedHeaderNames = Object.keys(headers).sort();
  const canonicalHeaders = signedHeaderNames.map((k) => `${k}:${headers[k].trim()}`).join("\n") + "\n";
  const signedHeaders = signedHeaderNames.join(";");
  const canonicalRequest = ["GET", "/", canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].join("\n");
  const stringToSign = "ACS3-HMAC-SHA256\n" + createHash("sha256").update(canonicalRequest).digest("hex");
  const signature = createHmac("sha256", sk).update(stringToSign).digest("hex");
  const auth = `ACS3-HMAC-SHA256 Credential=${ak},SignedHeaders=${signedHeaders},Signature=${signature}`;
  const res = await fetch(`https://${RAM_HOST}/?${canonicalQuery}`, {
    method: "GET",
    headers: { ...headers, Authorization: auth },
  });
  let body: any = null;
  try { body = await res.json(); } catch { body = null; }
  return { ok: res.ok, status: res.status, code: body?.Code, body };
}

// --- main --------------------------------------------------------------------
async function main() {
  const rotate = process.argv.includes("--rotate");
  const root = repoRoot();
  let envPath = join(root, ".env");
  let fileEnv = parseEnvFile(envPath);
  if (!fileEnv.ALIBABA_QUOTA_AK || !fileEnv.ALIBABA_QUOTA_SK) {
    const mainRoot = mainCheckoutRoot(root);
    if (mainRoot) {
      const mainEnv = join(mainRoot, ".env");
      const parsed = parseEnvFile(mainEnv);
      if (parsed.ALIBABA_QUOTA_AK && parsed.ALIBABA_QUOTA_SK) { envPath = mainEnv; fileEnv = parsed; }
    }
  }
  const ak = process.env.ALIBABA_QUOTA_AK?.trim() || fileEnv.ALIBABA_QUOTA_AK;
  const sk = process.env.ALIBABA_QUOTA_SK?.trim() || fileEnv.ALIBABA_QUOTA_SK;
  if (!ak || !sk) {
    console.error(`create-monitoring-key: ALIBABA_QUOTA_AK / ALIBABA_QUOTA_SK not found in process.env, ${join(root, ".env")}, or the main checkout .env`);
    console.error("Add the MASTER pair to the main checkout .env first (it will be REPLACED there by the scoped key; masters stay in 1Password).");
    process.exit(2);
  }
  console.log(`master key: ${mask(ak)} (from ${process.env.ALIBABA_QUOTA_AK ? "process.env" : envPath})`);

  // 1. ensure user
  const get = await ramCall(ak, sk, "GetUser", { UserName: USER_NAME });
  if (get.ok) {
    console.log(`RAM user ${USER_NAME}: exists`);
  } else if (get.code === "EntityNotExist.User" || get.status === 404) {
    const create = await ramCall(ak, sk, "CreateUser", {
      UserName: USER_NAME,
      DisplayName: USER_NAME,
      Comments: "himmel quota-gauge read-only monitoring (HIMMEL-729); scoped key, no console login",
    });
    if (!create.ok) {
      console.error(`create-monitoring-key: CreateUser failed (${create.status} ${create.code ?? "?"}): ${create.body?.Message ?? ""}`);
      process.exit(1);
    }
    console.log(`RAM user ${USER_NAME}: created`);
  } else {
    console.error(`create-monitoring-key: GetUser failed (${get.status} ${get.code ?? "?"}): ${get.body?.Message ?? ""}`);
    process.exit(1);
  }

  // 2. attach read-only policy (idempotent)
  const attach = await ramCall(ak, sk, "AttachPolicyToUser", {
    PolicyType: "System", PolicyName: POLICY, UserName: USER_NAME,
  });
  if (attach.ok || attach.code === "EntityAlreadyExists.User.Policy") {
    console.log(`policy ${POLICY}: attached`);
  } else {
    console.error(`create-monitoring-key: AttachPolicyToUser failed (${attach.status} ${attach.code ?? "?"}): ${attach.body?.Message ?? ""}`);
    process.exit(1);
  }

  // 3. access key (refuse a silent second key; --rotate deletes existing first)
  // Persistence preflight FIRST: creating a key we cannot persist orphans a
  // live credential (the secret is shown once) — check .env before minting.
  if (!existsSync(envPath)) {
    console.error(`create-monitoring-key: ${envPath} missing — refusing to mint a key that cannot be persisted; create the .env first.`);
    process.exit(1);
  }
  const list = await ramCall(ak, sk, "ListAccessKeys", { UserName: USER_NAME });
  if (!list.ok) {
    // Fail CLOSED: an API error here is NOT an empty key list — proceeding
    // could silently mint a second key past the refuse-second-key contract.
    console.error(`create-monitoring-key: ListAccessKeys failed (${list.status} ${list.code ?? "?"}): ${list.body?.Message ?? ""}`);
    process.exit(1);
  }
  const existing: Array<{ AccessKeyId: string }> = list.body?.AccessKeys?.AccessKey ?? [];
  if (existing.length > 0 && !rotate) {
    console.error(`create-monitoring-key: ${USER_NAME} already has ${existing.length} access key(s) (${existing.map((k) => mask(k.AccessKeyId)).join(", ")}).`);
    console.error("If the secret is lost, re-run with --rotate (deletes ALL existing keys for this user, then creates a fresh one).");
    process.exit(3);
  }
  // Zero-gap rotation where the RAM 2-key cap allows: with ONE existing key,
  // mint the replacement FIRST and delete the old key after — a CreateAccessKey
  // failure then leaves the existing key intact. With 2 existing keys the cap
  // forces delete-first (gap risk unavoidable; recovery = re-run, which mints
  // fresh into the emptied slots).
  const doDelete = async (keyId: string): Promise<void> => {
    const del = await ramCall(ak, sk, "DeleteAccessKey", { UserName: USER_NAME, UserAccessKeyId: keyId });
    if (!del.ok) {
      console.error(`create-monitoring-key: DeleteAccessKey ${mask(keyId)} failed (${del.status} ${del.code ?? "?"})`);
      process.exit(1);
    }
    console.log(`rotated away old key ${mask(keyId)}`);
  };
  const doCreate = async (): Promise<{ id: string; secret: string }> => {
    const created = await ramCall(ak, sk, "CreateAccessKey", { UserName: USER_NAME });
    const id: string | undefined = created.body?.AccessKey?.AccessKeyId;
    const secret: string | undefined = created.body?.AccessKey?.AccessKeySecret;
    if (!created.ok || !id || !secret) {
      console.error(`create-monitoring-key: CreateAccessKey failed (${created.status} ${created.code ?? "?"}): ${created.body?.Message ?? ""}`);
      process.exit(1);
    }
    return { id, secret };
  };
  let minted: { id: string; secret: string };
  if (rotate && existing.length === 1) {
    minted = await doCreate();
    await doDelete(existing[0].AccessKeyId);
  } else {
    if (rotate) for (const k of existing) await doDelete(k.AccessKeyId);
    minted = await doCreate();
  }
  const newAk = minted.id;
  const newSk = minted.secret;
  console.log(`scoped key created: ${mask(newAk)}`);

  // 4. swap the scoped pair into .env (values never printed; existence was
  // preflighted before the key was minted).
  const lines = readFileSync(envPath, "utf8").split(/\r?\n/);
  const replaced = { ak: false, sk: false };
  const next = lines.map((line) => {
    if (/^\s*ALIBABA_QUOTA_AK\s*=/.test(line)) { replaced.ak = true; return `ALIBABA_QUOTA_AK=${newAk}`; }
    if (/^\s*ALIBABA_QUOTA_SK\s*=/.test(line)) { replaced.sk = true; return `ALIBABA_QUOTA_SK=${newSk}`; }
    return line;
  });
  if (!replaced.ak) next.push(`ALIBABA_QUOTA_AK=${newAk}`);
  if (!replaced.sk) next.push(`ALIBABA_QUOTA_SK=${newSk}`);
  writeFileSync(envPath, next.join("\n"), "utf8");
  console.log(`.env updated: ALIBABA_QUOTA_AK/SK now carry the SCOPED ${USER_NAME} key (${replaced.ak ? "replaced" : "appended"}).`);
  console.log("Masters remain recorded in 1Password only. Done.");
}

main().catch((e) => {
  console.error(`create-monitoring-key: ${String(e?.message ?? e)}`);
  process.exit(1);
});
