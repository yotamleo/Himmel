import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join } from 'node:path';
import {
  appendChain, contentSha, loadKey, mintKey, readChain, readSigned, withLock, withLockAsync, writeSigned, type Chain,
} from './ledger.js';
import { SECTOR_OPT_OUT, sectorField } from '../commands/sector.js';
import { appendAdmission, assertAdmissionsWritable, readAdmissions } from '../commands/admissions-ledger.js';
import { baselineId, effectOn, reduce, recordOf, scopeOk, terminalOf, unknownState, type ReleaseState } from './reducer.js';
import type {
  Authority, Baseline, Declaration, EventRow, IssueSnap, Lease, Op, OperatorRow, PlacementClass, RequestRow, RulingRow, Verb,
} from './types.js';

// The release engine's I/O (design §5): the only writer of the authority files
// under release/<R>/. Every caller reads `jira release state --json`.

export interface JiraPort {
  fixVersions(key: string): Promise<string[]>;
  setFixVersion(key: string, op: 'add' | 'remove', version: string): Promise<void>;
  findComment(key: string, marker: string): Promise<string | null>;
  addComment(key: string, markdown: string): Promise<string>;
  // The live snapshot of one issue, for a claimed key the mirror lacks or holds without a sector.
  issue?(key: string): Promise<IssueSnap | null>;
}

export interface Ctx {
  release: string;
  dir: string;
  keyPath: string;
  env: Record<string, string | undefined>;
  now: () => Date;
  jira: JiraPort;
  mirrorRoot: string | null;
}

const OUTCOMES: Record<Verb, Record<string, Op['kind'][]>> = {
  INTAKE: { ADMIT: ['add', 'move'], BACKLOG: ['remove', 'move', 'none'], 'AD-HOC': ['none'] },
  REVERSION: { MOVE: ['move', 'remove'], KEEP: ['keep'] },
  DISCHARGE: { ACCEPT: ['discharge'], REJECT: ['none'] },
};

const f = (ctx: Ctx, name: string) => join(ctx.dir, name);
const ts = (ctx: Ctx) => ctx.now().toISOString();
const seq = (prefix: string, ids: Iterable<string>) => {
  const re = new RegExp(`^${prefix}-(\\d+)$`);
  const n = Math.max(0, ...[...ids].map((id) => Number(re.exec(id)?.[1] ?? 0)));
  return `${prefix}-${String(n + 1).padStart(4, '0')}`;
};

function operatorFence(ctx: Ctx): void {
  if (ctx.env.HIMMEL_CONSOLE_LEG === '1' || ctx.env.HIMMEL_RELEASE_MANAGER === '1') {
    throw new Error('release operator: a console act on an operator decision; refused inside a console-spawned leg');
  }
}

function key(ctx: Ctx): Buffer {
  return loadKey(ctx.keyPath);
}

interface Loaded {
  k: Buffer;
  decl: Declaration;
  baselines: Baseline[];
  rulings: Chain<RulingRow>;
  operator: Chain<OperatorRow>;
  events: Chain<EventRow>;
  requests: Chain<RequestRow>;
}

// Verifies the declaration and every baseline against their signed O- rows;
// any failure is UNKNOWN for the whole release (design §2).
function load(ctx: Ctx): Loaded | { unknown: string } {
  let k: Buffer;
  try {
    k = key(ctx);
  } catch (e) {
    return { unknown: (e as Error).message };
  }
  const operator = readChain<OperatorRow>(f(ctx, 'operator.jsonl'), k);
  const decl = readSigned<Declaration>(f(ctx, 'release.json'), k);
  const declRow = operator.verified.find((o) => o.kind === 'declare');
  if (!decl.ok || !decl.value || !declRow || declRow.sha !== contentSha(decl.value) || decl.value.release !== ctx.release) {
    return { unknown: `release.json for ${ctx.release} is missing or does not verify` };
  }
  const baselines: Baseline[] = [];
  for (const o of operator.verified.filter((x) => x.kind === 'freeze')) {
    const b = readSigned<Baseline>(f(ctx, o.file ?? ''), k);
    if (!b.ok || !b.value || o.sha !== contentSha(b.value)) return { unknown: `${o.file} does not verify against ${o.id}` };
    const prior = baselines.findIndex((x) => x.version === b.value?.version);
    if (prior >= 0) baselines.splice(prior, 1);
    baselines.push(b.value);
  }
  return {
    k, decl: decl.value, baselines, operator,
    rulings: readChain<RulingRow>(f(ctx, 'rulings.jsonl'), k),
    events: readChain<EventRow>(f(ctx, 'events.jsonl'), k),
    requests: readChain<RequestRow>(f(ctx, 'requests.jsonl'), k),
  };
}

function loadOrThrow(ctx: Ctx): Loaded {
  const l = load(ctx);
  if ('unknown' in l) throw new Error(`release ${ctx.release} is UNKNOWN: ${l.unknown}`);
  return l;
}

// Every writer decides on the state it reads under the lock. The load before
// the lock only turns a release that is not declared into a clear error.
function locked<T>(ctx: Ctx, fn: (l: Loaded) => T): T {
  loadOrThrow(ctx);
  return withLock(ctx.dir, () => fn(loadOrThrow(ctx)));
}

function lockedAsync<T>(ctx: Ctx, fn: (l: Loaded) => Promise<T>): Promise<T> {
  loadOrThrow(ctx);
  return withLockAsync(ctx.dir, () => fn(loadOrThrow(ctx)));
}

function frontmatter(text: string): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  const lines = text.split('\n');
  if (lines[0] !== '---') return out;
  for (const line of lines.slice(1)) {
    if (line === '---') break;
    const m = /^(\w+): (.+)$/.exec(line);
    if (!m) continue;
    try {
      out[m[1]] = JSON.parse(m[2]);
    } catch { /* a nested YAML block (links:) is not needed here */ }
  }
  return out;
}

export function readMirror(root: string | null): { issues: Map<string, IssueSnap> | null; sync: string | null } {
  if (!root || !existsSync(join(root, '.cursor.json'))) return { issues: null, sync: null };
  let sync: string;
  try {
    sync = (JSON.parse(readFileSync(join(root, '.cursor.json'), 'utf8')) as { lastSync: string }).lastSync;
    if (Number.isNaN(Date.parse(sync))) return { issues: null, sync: null };
  } catch {
    return { issues: null, sync: null };
  }
  const issues = new Map<string, IssueSnap>();
  for (const name of readdirSync(root)) {
    if (!name.endsWith('.md')) continue;
    const fm = frontmatter(readFileSync(join(root, name), 'utf8'));
    if (typeof fm.key !== 'string') continue;
    issues.set(fm.key, {
      key: fm.key, status: String(fm.status ?? ''), statusCategory: typeof fm.statusCategory === 'string' ? fm.statusCategory : null,
      type: String(fm.type ?? ''), priority: String(fm.priority ?? ''),
      fixVersions: Array.isArray(fm.fixVersions) ? fm.fixVersions.map(String) : [],
      resolution: typeof fm.resolution === 'string' ? fm.resolution : null,
      sector: typeof fm.sector === 'string' && fm.sector ? fm.sector : null,
    });
  }
  return { issues, sync };
}

function reduceLoaded(l: Loaded, mirror: ReturnType<typeof readMirror>): ReleaseState {
  return reduce({
    decl: l.decl, baselines: l.baselines, rulings: l.rulings, operator: l.operator, events: l.events,
    issues: mirror.issues, mirrorSync: mirror.sync,
  });
}

function readLease(ctx: Ctx, k: Buffer): Lease {
  const p = f(ctx, 'lease.json');
  if (!existsSync(p)) {
    return { release: ctx.release, epoch: 0, owner_session: null, owner_doc: null, acquired: null, released: true, prev_epoch: null };
  }
  const l = readSigned<Lease>(p, k);
  if (!l.ok || !l.value) throw new Error(`release ${ctx.release} is UNKNOWN: lease.json does not verify`);
  return l.value;
}

function latestRequests(requests: Chain<RequestRow>): Map<string, RequestRow> {
  if (requests.bad.length) throw new Error(`release: requests.jsonl does not verify (${requests.bad[0]})`);
  const m = new Map<string, RequestRow>();
  for (const r of requests.verified) m.set(r.req, r);
  return m;
}

// --- operator acts (the console, on an operator decision) ---------------------

function appendOperator(ctx: Ctx, k: Buffer, row: Omit<OperatorRow, 'id' | 'ts'> & { id?: string }): OperatorRow {
  const chain = readChain<OperatorRow>(f(ctx, 'operator.jsonl'), k);
  const id = row.id ?? seq(`O-${ctx.release}`, chain.rows.map((o) => o.id));
  return appendChain<OperatorRow>(f(ctx, 'operator.jsonl'), k, { ...row, id, ts: ts(ctx) });
}

export function declare(ctx: Ctx, o: { project: string; versions: string[]; decision: string; verbatim: string; mode: Declaration['mode'] }): Declaration {
  operatorFence(ctx);
  if (!/^[A-Za-z0-9._-]+$/.test(ctx.release)) throw new Error(`release: bad release name '${ctx.release}'`);
  if (!o.versions.length) throw new Error('release operator declare: --versions needs at least one version');
  if (o.mode === 'live') throw new Error('release operator declare: a release is declared observe; live waits for the signed activation barrier');
  if (existsSync(f(ctx, 'release.json'))) throw new Error(`release ${ctx.release} is already declared`);
  mkdirSync(ctx.dir, { recursive: true });
  const k = mintKey(ctx.keyPath);
  return withLock(ctx.dir, () => {
    const decl: Declaration = {
      project: o.project, release: ctx.release, versions: o.versions, current: o.versions[0], mode: o.mode,
      decision: o.decision, ts: ts(ctx),
    };
    writeSigned(f(ctx, 'release.json'), k, decl);
    appendOperator(ctx, k, { kind: 'declare', decision: o.decision, verbatim: o.verbatim, file: 'release.json', sha: contentSha(decl) });
    appendOperator(ctx, k, {
      id: `O-${ctx.release}-emergency`, kind: 'emergency', decision: '109',
      verbatim: 'standing record: an evidenced emergency (Highest or Blocker, a red main run, or a regression of a merged PR) is placed in the current version',
    });
    return decl;
  });
}

export function freeze(ctx: Ctx, o: { version: string; keys: string[]; decision: string; verbatim: string }): Baseline {
  operatorFence(ctx);
  return locked(ctx, (l) => {
    if (!l.decl.versions.includes(o.version)) throw new Error(`release operator freeze: ${o.version} is not a version of ${ctx.release}`);
    const gen = 1 + l.operator.verified.filter((x) => x.kind === 'freeze' && x.file?.startsWith(`baseline-${o.version}-g`)).length;
    const b: Baseline = { release: ctx.release, version: o.version, gen, keys: [...new Set(o.keys)].sort(), decision: o.decision, ts: ts(ctx) };
    const resolved = new Set(l.rulings.verified.filter((r) => r.phase !== 'intent').map((r) => r.id));
    const pending = l.rulings.verified.find((r) => r.phase === 'intent' && !resolved.has(r.id)
      && b.keys.includes(r.key) && effectOn(r.op, o.version));
    if (pending) throw new Error(`release operator freeze: ${pending.id} is a pending intent on ${pending.key}@${o.version}; apply or void it first`);
    const file = `${baselineId(b)}.json`;
    if (existsSync(f(ctx, file))) throw new Error(`release: ${file} exists; a baseline is immutable`);
    writeSigned(f(ctx, file), l.k, b);
    appendOperator(ctx, l.k, { kind: 'freeze', decision: o.decision, verbatim: o.verbatim, file, sha: contentSha(b) });
    return b;
  });
}

export function operatorDecision(ctx: Ctx, o: { decision: string; keys: string[]; op: string; from_v: string | null; to_v: string | null; verbatim: string }): OperatorRow {
  operatorFence(ctx);
  if (!o.keys.length) throw new Error('release operator decision: --keys names the exact keys it covers');
  return locked(ctx, (l) => appendOperator(ctx, l.k, {
    kind: 'decision', decision: o.decision, keys: o.keys, op: o.op, from_v: o.from_v, to_v: o.to_v, verbatim: o.verbatim,
  }));
}

export function takeover(ctx: Ctx, o: { epoch: number; doc: string }): OperatorRow {
  operatorFence(ctx);
  if (!isAbsolute(o.doc)) throw new Error('release operator takeover: the successor doc must be an absolute path');
  return locked(ctx, (l) => appendOperator(ctx, l.k, { kind: 'takeover', decision: null, epoch: o.epoch, doc: o.doc }));
}

// --- fold: a finished ticket recorded as delivered in a version (the console) ---------

export interface FoldItem { key: string; pr: number }
export interface FoldSkip { key: string; terminal: string; resolution: string }
export interface FoldOut { folded: EventRow[]; already: string[]; skipped: FoldSkip[] }

const ISSUE_KEY = /^[A-Z][A-Z0-9]*-\d+$/;

const lastBookkeeping = (events: EventRow[], key: string) =>
  [...events].reverse().find((e) => e.key === key && (e.kind === 'fold' || e.kind === 'reopen'));

function foldVersion(ctx: Ctx, l: Loaded, v: string): void {
  if (!l.decl.versions.includes(v)) throw new Error(`release: ${v} is not a version of ${ctx.release}`);
  if (l.events.bad.length) throw new Error(`release: events.jsonl does not verify (${l.events.bad[0]})`);
}

// One signed events row per key. Only a key the mirror reads as terminal Done folds;
// every other key is returned in `skipped` with its terminal and resolution, and stays
// a leak until a ruling moves it out of the version. A key already folded to this
// version under this PR is skipped silently, so a batch can be re-run.
export function fold(ctx: Ctx, o: { to: string; items: FoldItem[] }): FoldOut {
  operatorFence(ctx);
  for (const it of o.items) {
    if (!ISSUE_KEY.test(it.key)) throw new Error(`release fold: '${it.key}' is not an issue key`);
    if (!Number.isSafeInteger(it.pr) || it.pr <= 0) throw new Error(`release fold: ${it.key} needs a positive PR number`);
  }
  return locked(ctx, (l) => {
    foldVersion(ctx, l, o.to);
    const { issues } = readMirror(ctx.mirrorRoot);
    if (!issues) throw new Error('release fold: the Jira mirror is unreadable; sync it first');
    const eventsPath = f(ctx, 'events.jsonl');
    const seen = [...l.events.verified];
    const out: FoldOut = { folded: [], already: [], skipped: [] };
    for (const { key: k, pr } of o.items) {
      const issue = issues.get(k);
      const terminal = terminalOf(issue);
      if (terminal !== 'Done') {
        out.skipped.push({ key: k, terminal: terminal ?? (issue ? 'open' : 'not-in-mirror'), resolution: issue?.resolution ?? 'none' });
        continue;
      }
      const last = lastBookkeeping(seen, k);
      if (last?.kind === 'fold' && last.to === o.to && last.pr === pr) {
        out.already.push(k);
        continue;
      }
      const row = appendChain<EventRow>(eventsPath, l.k, { ts: ts(ctx), kind: 'fold', key: k, from: null, to: o.to, pr });
      seen.push(row);
      out.folded.push(row);
    }
    return out;
  });
}

// The twin of fold: the newest bookkeeping row of the key must be a fold into `from`.
export function reopen(ctx: Ctx, o: { key: string; from: string }): EventRow {
  operatorFence(ctx);
  if (!ISSUE_KEY.test(o.key)) throw new Error(`release reopen: '${o.key}' is not an issue key`);
  return locked(ctx, (l) => {
    foldVersion(ctx, l, o.from);
    const last = lastBookkeeping(l.events.verified, o.key);
    if (last?.kind !== 'fold' || last.to !== o.from) throw new Error(`release reopen: ${o.key} has no fold into ${o.from} to reverse`);
    return appendChain<EventRow>(f(ctx, 'events.jsonl'), l.k, { ts: ts(ctx), kind: 'reopen', key: o.key, from: o.from, to: null });
  });
}

// --- the request queue (the console writes, the RM claims) ---------------------

export function request(ctx: Ctx, o: Omit<RequestRow, 'req' | 'ts' | 'state'>): RequestRow {
  if (ctx.env.HIMMEL_RELEASE_MANAGER === '1') throw new Error('release request: the console writes requests; the RM claims them');
  return locked(ctx, (l) => {
    const latest = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k));
    const dup = [...latest.values()].find((r) => !r.state.startsWith('ruled:') && r.key === o.key && r.verb === o.verb
      && r.from_v === o.from_v && r.to_v === o.to_v);
    if (dup) return dup;
    const req = seq(`Q-${ctx.release}`, latest.keys());
    return appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...o, req, ts: ts(ctx), state: 'open' });
  });
}

// --- the lease (§5.8) ------------------------------------------------------------

function rmFence(ctx: Ctx, l: Loaded): Lease {
  if (ctx.env.HIMMEL_RELEASE_MANAGER !== '1') throw new Error('release: only the release-manager session (HIMMEL_RELEASE_MANAGER=1) may do this');
  if (ctx.env.HIMMEL_RM_RELEASE && ctx.env.HIMMEL_RM_RELEASE !== ctx.release) {
    throw new Error(`release: this session is bound to ${ctx.env.HIMMEL_RM_RELEASE}, not ${ctx.release}`);
  }
  const lease = readLease(ctx, l.k);
  if (!lease.owner_doc || lease.released) throw new Error(`release ${ctx.release}: no lease owner; run release lease acquire first`);
  if (ctx.env.HIMMEL_RM_DOC !== lease.owner_doc) {
    throw new Error(`release ${ctx.release}: ${ctx.env.HIMMEL_RM_DOC ?? '(no HIMMEL_RM_DOC)'} is not the lease owner (${lease.owner_doc}, epoch ${lease.epoch})`);
  }
  return lease;
}

export function leaseAcquire(ctx: Ctx, o: { expectEpoch: number; doc: string; session: string }): Lease {
  if (ctx.env.HIMMEL_RELEASE_MANAGER !== '1') throw new Error('release lease: only the release-manager session (HIMMEL_RELEASE_MANAGER=1) holds the lease');
  if (!isAbsolute(o.doc) || ctx.env.HIMMEL_RM_DOC !== o.doc) throw new Error('release lease acquire: --doc must be this session\'s absolute HIMMEL_RM_DOC');
  return locked(ctx, (l) => {
    const cur = readLease(ctx, l.k);
    if (cur.epoch !== o.expectEpoch) throw new Error(`release lease: epoch is ${cur.epoch}, expected ${o.expectEpoch}`);
    const takeoverRow = readChain<OperatorRow>(f(ctx, 'operator.jsonl'), l.k).verified
      .some((x) => x.kind === 'takeover' && x.epoch === cur.epoch && x.doc === o.doc);
    if (cur.owner_doc && !cur.released && !takeoverRow) {
      throw new Error(`release lease: held by ${cur.owner_doc} at epoch ${cur.epoch}; it needs a release or a console takeover row`);
    }
    const next: Lease = {
      release: ctx.release, epoch: cur.epoch + 1, owner_session: o.session, owner_doc: o.doc, acquired: ts(ctx),
      released: false, prev_epoch: cur.epoch,
    };
    writeSigned(f(ctx, 'lease.json'), l.k, next);
    return next;
  });
}

export function leaseRelease(ctx: Ctx): Lease {
  return locked(ctx, (l) => {
    const lease = rmFence(ctx, l);
    const next = { ...lease, released: true };
    writeSigned(f(ctx, 'lease.json'), l.k, next);
    return next;
  });
}

// --- claim, rule, apply (§5.6, §5.7) ------------------------------------------------

export function claim(ctx: Ctx): RequestRow[] {
  return locked(ctx, (l) => {
    const lease = rmFence(ctx, l);
    const latest = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k));
    const mine = `claimed:${lease.epoch}`;
    const out: RequestRow[] = [];
    for (const r of latest.values()) {
      const claimedEpoch = /^claimed:(\d+)$/.exec(r.state)?.[1];
      if (r.state === mine) out.push(r);
      else if (r.state === 'open' || (claimedEpoch !== undefined && Number(claimedEpoch) < lease.epoch)) {
        const { prev: _p, mac: _m, ...rest } = r;
        out.push(appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, ts: ts(ctx), state: mine }));
      }
    }
    return out;
  });
}

function classOf(decl: Declaration, op: Op): PlacementClass {
  const target = op.kind === 'keep' || op.kind === 'discharge' ? op.from_v : op.kind === 'remove' || op.kind === 'none' ? null : op.to_v;
  if (target === decl.current) return 'current';
  return target && decl.versions.includes(target) ? 'next' : 'backlog';
}

function checkOp(decl: Declaration, op: Op): void {
  const inR = (v: string | null) => v !== null && decl.versions.includes(v);
  const ok = {
    add: inR(op.to_v),
    remove: inR(op.from_v) && op.to_v === null,
    move: op.from_v !== op.to_v && (inR(op.from_v) || inR(op.to_v)),
    keep: inR(op.from_v) && op.to_v === op.from_v,
    discharge: inR(op.from_v) && op.to_v === op.from_v,
    none: true,
  }[op.kind];
  if (!ok) throw new Error(`release rule: ${op.kind} ${op.from_v ?? 'backlog'}→${op.to_v ?? 'backlog'} is not a valid operation on ${decl.release}`);
}

export interface RuleOptions {
  req: string;
  outcome: string;
  op: Op;
  sector: string;
  ground: string;
  reason: string;
  supersedes: string[];
  authority: Authority;
}

export function rule(ctx: Ctx, o: RuleOptions): RulingRow {
  return locked(ctx, (l) => {
    const lease = rmFence(ctx, l);
    const latest = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k));
    const req = latest.get(o.req);
    if (!req) throw new Error(`release rule: no request ${o.req}`);
    if (req.state !== `claimed:${lease.epoch}`) throw new Error(`release rule: ${o.req} is ${req.state}, not claimed:${lease.epoch}`);
    const kinds = OUTCOMES[req.verb][o.outcome];
    if (!kinds) throw new Error(`release rule: ${req.verb} outcomes are ${Object.keys(OUTCOMES[req.verb]).join(', ')}`);
    if (!kinds.includes(o.op.kind)) throw new Error(`release rule: ${o.outcome} takes --op ${kinds.join('|')}`);
    checkOp(l.decl, o.op);
    const sector = o.sector.trim() || (sectorField() ? '' : SECTOR_OPT_OUT);
    if (!sector) throw new Error('release rule: a ruling without a sector refuses; ask the console to set it');
    if (!o.ground.trim() || !o.reason.trim()) throw new Error('release rule: --ground and --reason are required');

    const s = reduceLoaded(l, { issues: null, sync: null });
    if (s.status !== 'OK') throw new Error(`release ${ctx.release} is UNKNOWN: ${s.integrity[0]}`);
    const rulings = l.rulings.verified;
    const applied = new Map(rulings.filter((r) => r.phase === 'applied' || r.phase === 'receipted').map((r) => [r.id, r]));
    const baselineIds = new Set(l.baselines.map(baselineId));
    for (const id of o.supersedes) {
      if (!applied.has(id) && !baselineIds.has(id)) throw new Error(`release rule: supersedes names ${id}, which is not an effective ruling`);
    }
    if (o.op.kind === 'none' && o.supersedes.length) throw new Error('release rule: a ruling that changes nothing supersedes nothing');
    for (const v of l.decl.versions) {
      if (!effectOn(o.op, v) && !(o.op.kind === 'none' && (o.op.from_v === v || o.op.to_v === v))) continue;
      const rec = recordOf(s, req.key, v);
      if (rec?.placement === 'unknown') throw new Error(`release rule: ${req.key}@${v} is UNKNOWN`);
      if (rec?.placement === 'pending') throw new Error(`release rule: ${req.key}@${v} has a pending intent; apply or void it first`);
      if (o.op.kind === 'none') continue;
      if (rec?.ruling && !o.supersedes.includes(rec.ruling)) throw new Error(`release rule: supersedes must name ${rec.ruling} (in effect for ${req.key}@${v})`);
      const prior = rec?.ruling ? applied.get(rec.ruling) : undefined;
      if (prior?.authority.kind === 'operator' && o.authority.kind !== 'operator') {
        throw new Error(`release rule: ${prior.id} carries operator authority; only an operator record supersedes it`);
      }
    }
    if (o.authority.kind === 'operator') {
      const ops = new Map(l.operator.verified.map((x) => [x.id, x]));
      if (!scopeOk({ authority: o.authority, key: req.key, op: o.op }, ops, l.decl.current)) throw new Error(`release rule: ${o.authority.ref ?? '(no ref)'} does not cover ${req.key} ${o.op.kind} ${o.op.from_v}→${o.op.to_v}`);
    }
    if (o.authority.kind === 'import' && !o.authority.ref) throw new Error('release rule: an import names its source in --ref');

    const id = seq(`R-${ctx.release}`, l.rulings.rows.map((r) => r.id));
    const row = appendChain<RulingRow>(f(ctx, 'rulings.jsonl'), l.k, {
      id, epoch: lease.epoch, req: req.req, ts: ts(ctx), verb: req.verb, key: req.key, op: o.op, outcome: o.outcome,
      class: classOf(l.decl, o.op), sector, ground: o.ground, reason: o.reason, supersedes: o.supersedes,
      authority: o.authority, phase: 'intent',
    });
    const { prev: _p, mac: _m, ...rest } = req;
    appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, ts: ts(ctx), state: `ruled:${id}` });
    return row;
  });
}

const vName = (v: string | null) => v ?? 'backlog';

export const rulingLine = (r: RulingRow): string =>
  `RULING ${r.id} ${r.req} ${r.verb} ${r.key} ${r.op.kind} ${vName(r.op.from_v)}→${vName(r.op.to_v)} ${r.outcome} ${r.class} sector=${r.sector} — ${r.ground}: ${r.reason}`;

function landed(op: Op, cur: string[]): boolean {
  const has = (v: string | null) => v !== null && cur.includes(v);
  switch (op.kind) {
    case 'add': return has(op.to_v);
    case 'remove': return !has(op.from_v);
    case 'move': return (op.to_v === null || has(op.to_v)) && !has(op.from_v);
    case 'keep':
    case 'discharge': return has(op.from_v);
    default: return true;
  }
}

// Jira still shows the state from before the ruling's write.
function untouched(op: Op, cur: string[]): boolean {
  const has = (v: string | null) => v !== null && cur.includes(v);
  return op.kind !== 'move' || ((op.from_v === null || has(op.from_v)) && !has(op.to_v));
}

function phaseRow(ctx: Ctx, r: RulingRow, phase: RulingRow['phase'], extra: Partial<RulingRow>): Omit<RulingRow, 'prev' | 'mac'> {
  const { prev: _p, mac: _m, ...rest } = r;
  return { ...rest, ...extra, phase, ts: ts(ctx) };
}

// Runs a ruling from its newest phase to receipted. Idempotent: the comment id
// in the receipted row is the idempotency key, and a replay finds the comment
// by its marker before it would post another.
export async function apply(ctx: Ctx, id: string): Promise<{ phase: RulingRow['phase']; line: string }> {
  return lockedAsync(ctx, async (l) => {
    const lease = rmFence(ctx, l);
    const rows = readChain<RulingRow>(f(ctx, 'rulings.jsonl'), l.k);
    if (rows.bad.length) throw new Error(`release: rulings.jsonl does not verify (${rows.bad[0]})`);
    const mine = rows.verified.filter((r) => r.id === id);
    if (!mine.length) throw new Error(`release apply: no ruling ${id}`);
    let last = mine[mine.length - 1];
    if (last.phase === 'void') return { phase: 'void', line: `VOID ${id}` };
    const rulingsPath = f(ctx, 'rulings.jsonl');
    const membership = ['add', 'remove', 'move'].includes(last.op.kind);
    const event = (readback: 'ok' | 'mismatch') => {
      if (!membership) return;
      // The applied row lands before its event, so a retry re-creates a missing one.
      const eventsPath = f(ctx, 'events.jsonl');
      if (readback === 'ok' && readChain<EventRow>(eventsPath, l.k).verified.some((e) => e.kind === 'ruled' && e.ruling === id && e.readback === 'ok')) return;
      appendChain<EventRow>(eventsPath, l.k, {
        ts: ts(ctx), kind: 'ruled', key: last.key, from: last.op.from_v, to: last.op.to_v, ruling: id, readback,
      });
    };

    if (last.phase === 'intent' && last.epoch !== lease.epoch) {
      // An older epoch's intent: resolve by readback, never by re-writing Jira.
      const cur = await ctx.jira.fixVersions(last.key);
      if (!landed(last.op, cur)) {
        if (!untouched(last.op, cur)) {
          event('mismatch');
          throw new Error(`release apply: ${id} is partly applied in Jira; ${last.key} needs a hand fix before it is re-ruled`);
        }
        appendChain<RulingRow>(rulingsPath, l.k, phaseRow(ctx, last, 'void', { epoch: lease.epoch }));
        const latest = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k));
        const req = latest.get(last.req);
        if (req) {
          const { prev: _p, mac: _m, ...rest } = req;
          appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, ts: ts(ctx), state: 'open' });
        }
        return { phase: 'void', line: `VOID ${id} (epoch ${last.epoch} intent never reached Jira; ${last.req} reopened)` };
      }
      last = appendChain<RulingRow>(rulingsPath, l.k, phaseRow(ctx, last, 'applied', { epoch: lease.epoch, readback: 'ok' }));
    } else if (last.phase === 'intent') {
      const { op, key: k } = last;
      if ((last.verb === 'INTAKE' && last.outcome === 'ADMIT') || ((op.kind === 'remove' || op.kind === 'move') && op.from_v)) assertAdmissionsWritable();
      const cur = await ctx.jira.fixVersions(k);
      if ((op.kind === 'remove' || op.kind === 'move') && op.from_v && cur.includes(op.from_v)) await ctx.jira.setFixVersion(k, 'remove', op.from_v);
      if ((op.kind === 'add' || op.kind === 'move') && op.to_v && !cur.includes(op.to_v)) await ctx.jira.setFixVersion(k, 'add', op.to_v);
      if (!landed(op, await ctx.jira.fixVersions(k))) {
        event('mismatch');
        throw new Error(`release apply: ${id} readback does not match ${op.kind} ${vName(op.from_v)}→${vName(op.to_v)}`);
      }
      last = appendChain<RulingRow>(rulingsPath, l.k, phaseRow(ctx, last, 'applied', { readback: 'ok' }));
    }

    if (last.phase === 'applied') {
      event('ok');
      // A later applied ruling that supersedes this one owns the ledger now; a replay must not write after it.
      const phaseOf = new Map(rows.verified.map((r) => [r.id, r.phase]));
      const superseded = rows.verified.some((s) => s.supersedes.includes(id) && ['applied', 'receipted'].includes(phaseOf.get(s.id) ?? ''));
      // An RM admission is a ledger row like the console's, so the board counts it; a replay finds the row first.
      // A REVERSION move into a version is an admission there too; readers ignore the row for an unfrozen version.
      const admitted = last.verb === 'INTAKE' && last.outcome === 'ADMIT'
        || last.verb === 'REVERSION' && last.op.kind === 'move';
      if (!superseded && admitted && last.op.to_v) {
        const version = last.op.to_v;
        const key = last.key;
        if (!readAdmissions(version).some((r) => r.kind === 'rm-admit' && r.key === key && r.ruling === id)) {
          appendAdmission({ version, key, kind: 'rm-admit', reason: `${last.ground}: ${last.reason}`, by: lease.owner_session ?? 'rm', ruling: id });
        }
      }
      // A removal is a ledger row too, so a later reader sees the ruling-in withdrawn.
      if (!superseded && (last.op.kind === 'remove' || last.op.kind === 'move') && last.op.from_v) {
        const version = last.op.from_v;
        const key = last.key;
        if (!readAdmissions(version).some((r) => r.kind === 'rm-remove' && r.key === key && r.ruling === id)) {
          appendAdmission({ version, key, kind: 'rm-remove', reason: `${last.ground}: ${last.reason}`, by: lease.owner_session ?? 'rm', ruling: id });
        }
      }
      const marker = `[release-ruling ${id}]`;
      const authority = last.authority.kind === 'rm' ? 'rm' : `${last.authority.kind} ${last.authority.ref}`;
      const commentId = await ctx.jira.findComment(last.key, marker)
        ?? await ctx.jira.addComment(last.key, `${marker} ${rulingLine(last)}\n\nAuthority: ${authority}. Audit copy; the release ledger is the record.`);
      last = appendChain<RulingRow>(rulingsPath, l.k, phaseRow(ctx, last, 'receipted', { comment_id: commentId }));
    }
    return { phase: last.phase, line: rulingLine(last) };
  });
}

// --- state ---------------------------------------------------------------------------

export interface StateOut extends ReleaseState {
  /** Per version: the keys of today's (UTC) operator decisions that add or move into it. */
  admissions_today: Record<string, number>;
  lease: Omit<Lease, 'mac'> | null;
  requests: { open: string[]; claimed: string[] };
  heads: { rulings: string; operator: string; events: string; requests: string; mirror: string | null };
}

function admissionsToday(ctx: Ctx, l: Loaded): Record<string, number> {
  const today = ts(ctx).slice(0, 10);
  const counts: Record<string, number> = Object.fromEntries(l.decl.versions.map((v) => [v, 0]));
  for (const o of l.operator.verified) {
    if (o.kind !== 'decision' || (o.op !== 'add' && o.op !== 'move') || !o.to_v || !(o.to_v in counts) || !o.ts.startsWith(today)) continue;
    counts[o.to_v] += o.keys?.length ?? 0;
  }
  return counts;
}

export function state(ctx: Ctx): StateOut {
  const l = load(ctx);
  const empty = { admissions_today: {}, lease: null, requests: { open: [], claimed: [] }, heads: { rulings: '', operator: '', events: '', requests: '', mirror: null } };
  if ('unknown' in l) return { ...unknownState(ctx.release, l.unknown), ...empty };
  const mirror = readMirror(ctx.mirrorRoot);
  const s = reduceLoaded(l, mirror);
  let lease: Lease | null = null;
  try {
    lease = readLease(ctx, l.k);
  } catch (e) {
    s.integrity.push((e as Error).message);
  }
  const open: string[] = [];
  const claimed: string[] = [];
  if (l.requests.bad.length) s.integrity.push(...l.requests.bad.map((b) => `requests.jsonl ${b}`));
  for (const r of latestOrEmpty(l.requests).values()) {
    if (r.state === 'open') open.push(r.req);
    else if (r.state.startsWith('claimed:')) claimed.push(r.req);
  }
  const { mac: _m, ...leaseOut } = lease ?? ({} as Lease);
  return {
    ...s,
    status: lease ? s.status : 'UNKNOWN',
    admissions_today: admissionsToday(ctx, l),
    lease: lease ? leaseOut : null,
    requests: { open, claimed },
    heads: { rulings: l.rulings.head, operator: l.operator.head, events: l.events.head, requests: l.requests.head, mirror: mirror.sync },
  };
}

function latestOrEmpty(requests: Chain<RequestRow>): Map<string, RequestRow> {
  const m = new Map<string, RequestRow>();
  for (const r of requests.verified) m.set(r.req, r);
  return m;
}

// --- rm-run: the release manager as one on-demand batch -------------------------------

// The judge cannot rule the request: only req and reason count, nothing is ruled and the request stays claimed.
export interface HoldDecision {
  req: string;
  outcome: 'HOLD';
  reason: string;
}

export interface RuledDecision {
  req: string;
  outcome: string;
  op: Op['kind'];
  from: string | null;
  to: string | null;
  sector: string | null;
  ground: string;
  reason: string;
  supersedes?: string[];
  authority?: Authority['kind'];
  ref?: string | null;
}

export type Decision = HoldDecision | RuledDecision;

const isHold = (d: Decision): d is HoldDecision => d.outcome === 'HOLD';

// Everything a ruling weighs, read from disk: a standing session kept nothing else that counts.
export interface JudgeInput {
  release: string;
  current: string;
  versions: string[];
  requests: RequestRow[];
  records: ReleaseState['records'];
  operator: OperatorRow[];
  rulings: RulingRow[];
  issues: IssueSnap[];
}

export type Judge = (input: JudgeInput) => Promise<Decision[]>;

// A judge reply the decision check refused; raw is kept so the run doc can show what the model said.
export class JudgeReplyError extends Error {
  constructor(message: string, readonly raw: string) {
    super(message);
    this.name = 'JudgeReplyError';
  }
}

function unfinishedRulings(rulings: Chain<RulingRow>): string[] {
  const last = new Map<string, RulingRow>();
  for (const r of rulings.verified) last.set(r.id, r);
  return [...last.values()].filter((r) => r.phase === 'intent' || r.phase === 'applied').map((r) => r.id);
}

// The mirror row when it names a sector; else the live snapshot (a ticket filed since the last mirror sync),
// else whatever the mirror holds. A Jira that cannot answer, or not within LIVE_LOOKUP_MS, leaves the mirror's view.
export const LIVE_LOOKUP_MS = 15_000;
async function issueFor(ctx: Ctx, key: string, mirrored: IssueSnap | undefined): Promise<IssueSnap | undefined> {
  if (mirrored?.sector || !ctx.jira.issue) return mirrored;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const deadline = new Promise<null>((resolve) => { timer = setTimeout(() => resolve(null), LIVE_LOOKUP_MS); });
    return (await Promise.race([ctx.jira.issue(key), deadline])) ?? mirrored;
  } catch {
    return mirrored;
  } finally {
    clearTimeout(timer);
  }
}

// Takes the lease, finishes older unreceipted rulings, claims, asks the judge once, rules and
// applies through the engine, and releases the lease. Decisions come only from
// the judge, never from the caller.
export async function rmRun(ctx: Ctx, judge: Judge, o: { doc?: string; session?: string } = {}): Promise<string[]> {
  const l = loadOrThrow(ctx);
  const pending = [...latestRequests(l.requests).values()].filter((r) => r.state === 'open' || r.state.startsWith('claimed:'));
  if (!pending.length && !unfinishedRulings(l.rulings).length) return [`RM-RUN ${ctx.release}: nothing pending`];

  const doc = o.doc ?? join(ctx.dir, 'rm-runs', `run-${ts(ctx).replace(/[:.]/g, '-')}.md`);
  const rctx: Ctx = { ...ctx, env: { ...ctx.env, HIMMEL_RELEASE_MANAGER: '1', HIMMEL_RM_DOC: doc, HIMMEL_RM_RELEASE: ctx.release } };
  const lease = leaseAcquire(rctx, { expectEpoch: readLease(ctx, l.k).epoch, doc, session: o.session ?? 'rm-run' });
  const lines: string[] = [];
  let refused: JudgeReplyError | undefined;
  try {
    for (const id of unfinishedRulings(loadOrThrow(ctx).rulings)) {
      try {
        lines.push((await apply(rctx, id)).line);
      } catch (e) {
        lines.push(`PENDING ${id}: ${(e as Error).message}`);
      }
    }
    const claimed = claim(rctx);
    if (claimed.length) {
      const now = loadOrThrow(ctx);
      const keys = new Set(claimed.map((r) => r.key));
      const mirror = readMirror(ctx.mirrorRoot);
      const receipted = now.rulings.verified.filter((r) => r.phase === 'receipted');
      let decisions: Decision[];
      try {
        decisions = await judge({
          release: ctx.release, current: now.decl.current, versions: now.decl.versions, requests: claimed,
          records: reduceLoaded(now, mirror).records.filter((r) => keys.has(r.key)),
          operator: now.operator.verified,
          rulings: [...new Set([...receipted.filter((r) => keys.has(r.key)), ...receipted.slice(-40)])],
          issues: (await Promise.all([...keys].map((k) => issueFor(ctx, k, mirror.issues?.get(k))))).flatMap((i) => i ?? []),
        });
      } catch (e) {
        if (e instanceof JudgeReplyError) {
          refused = e;
          lines.push(`JUDGE-REFUSED: ${e.message}`);
        }
        throw e;
      }
      for (const q of claimed) {
        let id: string;
        try {
          const d = decisions.find((x) => x?.req === q.req);
          if (!d) throw new Error('the judge returned no decision');
          if (isHold(d)) {
            lines.push(`HELD ${q.req}: ${d.reason}`);
            continue;
          }
          id = rule(rctx, {
            req: q.req, outcome: d.outcome, op: { kind: d.op, from_v: d.from ?? null, to_v: d.to ?? null }, sector: d.sector ?? '',
            ground: d.ground ?? '', reason: d.reason ?? '', supersedes: d.supersedes ?? [],
            authority: { kind: d.authority ?? 'rm', ref: d.ref ?? null },
          }).id;
        } catch (e) {
          lines.push(`REFUSED ${q.req}: ${(e as Error).message}`);
          continue;
        }
        try {
          lines.push((await apply(rctx, id)).line);
        } catch (e) {
          lines.push(`PENDING ${id}: ${(e as Error).message}`);
        }
      }
    }
  } finally {
    // Cleanup never hides the rulings already made or the error that ended the run.
    try {
      leaseRelease(rctx);
    } catch (e) {
      lines.push(`PENDING lease: ${(e as Error).message}`);
    }
    try {
      mkdirSync(dirname(doc), { recursive: true });
      const raw = refused ? `\n## Raw judge reply\n\n~~~~\n${refused.raw}\n~~~~\n` : '';
      writeFileSync(doc, `# rm-run ${ctx.release} epoch ${lease.epoch}\n\n${lines.map((x) => `- ${x}`).join('\n')}\n${raw}`);
    } catch (e) {
      lines.push(`PENDING run record: ${(e as Error).message}`);
    }
  }
  return lines;
}
