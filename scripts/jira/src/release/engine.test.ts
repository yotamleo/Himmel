import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { chmodSync, closeSync as closeFd, existsSync, mkdtempSync, mkdirSync, openSync, readdirSync, readFileSync, statSync, unlinkSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  apply, claim, declare, fold, freeze, leaseAcquire, reopen, leaseRelease, operatorDecision, request, rule, state, takeover,
  JudgeReplyError, LIVE_LOOKUP_MS, readMirror, rmRun, type Ctx, type JiraPort, type Judge,
} from './engine.js';
import type { IssueSnap } from './types.js';
import { breakStaleLock, withLockAsync } from './ledger.js';

class FakeJira implements JiraPort {
  fv = new Map<string, string[]>();
  live = new Map<string, IssueSnap>();
  async issue(key: string) { return this.live.get(key) ?? null; }
  comments = new Map<string, Array<{ id: string; body: string }>>();
  posted = 0;
  async fixVersions(key: string) { return [...(this.fv.get(key) ?? [])]; }
  async setFixVersion(key: string, op: 'add' | 'remove', v: string) {
    const cur = this.fv.get(key) ?? [];
    this.fv.set(key, op === 'add' ? [...new Set([...cur, v])] : cur.filter((x) => x !== v));
  }
  async findComment(key: string, marker: string) {
    return this.comments.get(key)?.find((c) => c.body.includes(marker))?.id ?? null;
  }
  async addComment(key: string, body: string) {
    this.posted++;
    const id = String(1000 + this.posted);
    this.comments.set(key, [...(this.comments.get(key) ?? []), { id, body }]);
    return id;
  }
}

let root: string;
let jira: FakeJira;
const DOC = '/abs/rm-doc.md';
const consoleEnv = {};
const rmEnv = { HIMMEL_RELEASE_MANAGER: '1', HIMMEL_CONSOLE_LEG: '1', HIMMEL_RM_DOC: DOC, HIMMEL_RM_RELEASE: 'R1' };

function ctx(env: Record<string, string> = consoleEnv): Ctx {
  return {
    release: 'R1', dir: join(root, 'release', 'R1'), keyPath: join(root, 'keys', 'R1.key'),
    env, now: () => new Date('2026-10-21T10:00:00.000Z'), jira, mirrorRoot: join(root, 'mirror'),
  };
}

function mirror(issues: Array<{ key: string; fixVersions: string[]; status?: string; category?: string; resolution?: string; sector?: string }>, lastSync = '2026-10-21T09:00:00.000Z') {
  const dir = join(root, 'mirror');
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, '.cursor.json'), JSON.stringify({ lastSync, total: issues.length }));
  for (const i of issues) {
    writeFileSync(join(dir, `${i.key}.md`), [
      '---', `key: "${i.key}"`, 'type: "Task"', `status: "${i.status ?? 'To Do'}"`,
      ...(i.category ? [`statusCategory: "${i.category}"`] : []), 'priority: "Medium"',
      ...(i.sector ? [`sector: "${i.sector}"`] : []),
      `fixVersions: ${JSON.stringify(i.fixVersions)}`, `resolution: ${i.resolution ? JSON.stringify(i.resolution) : 'null'}`,
      '---', '', `# ${i.key}`, '',
    ].join('\n'));
  }
}

async function setup() {
  declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
  freeze(ctx(), { version: 'v1', keys: ['K-1'], decision: '104', verbatim: 'frozen at 1' });
  leaseAcquire(ctx(rmEnv), { expectEpoch: 0, doc: DOC, session: 'rm-1' });
}

const admit = (req: string, extra: Partial<Parameters<typeof rule>[1]> = {}) => rule(ctx(rmEnv), {
  req, outcome: 'ADMIT', op: { kind: 'add', from_v: null, to_v: 'v1' }, sector: 'Planning & tracking',
  ground: 'regression', reason: 'breaks the console', supersedes: [], authority: { kind: 'rm', ref: null }, ...extra,
});

// Applies a ruling with Jira failing before the receipt, then replays it from the applied phase.
async function applyThenReplay(id: string) {
  const post = jira.addComment.bind(jira);
  jira.addComment = async () => { throw new Error('jira down before the receipt'); };
  await expect(apply(ctx(rmEnv), id)).rejects.toThrow('jira down');
  jira.addComment = post;
  return apply(ctx(rmEnv), id);
}

const savedLedger = process.env.HIMMEL_ADMISSIONS_LEDGER;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'release-engine-'));
  jira = new FakeJira();
  process.env.HIMMEL_ADMISSIONS_LEDGER = join(root, 'admissions-ledger.jsonl');
});

afterEach(() => {
  vi.unstubAllEnvs();
  if (savedLedger === undefined) delete process.env.HIMMEL_ADMISSIONS_LEDGER;
  else process.env.HIMMEL_ADMISSIONS_LEDGER = savedLedger;
});

describe('release state admissions_today (HIMMEL-7153)', () => {
  const decide = (c: Ctx, decision: string, keys: string[], op: string, from_v: string | null, to_v: string | null) =>
    operatorDecision(c, { decision, keys, op, from_v, to_v, verbatim: 'x' });

  it('counts the keys of today\'s operator decisions that add or move into each version', async () => {
    await setup();
    expect(state(ctx()).admissions_today).toEqual({ v1: 0, v2: 0 });
    decide({ ...ctx(), now: () => new Date('2026-10-20T10:00:00.000Z') }, '100', ['K-7'], 'add', null, 'v1');
    decide(ctx(), '101', ['K-8', 'K-9'], 'add', null, 'v1');
    decide(ctx(), '102', ['K-6'], 'move', 'v1', 'v2');
    decide(ctx(), '103', ['K-5'], 'remove', 'v1', null);
    decide(ctx(), '104', ['K-4'], 'keep', 'v1', 'v1');
    expect(state(ctx()).admissions_today).toEqual({ v1: 2, v2: 1 });
  });

  it('is empty for a release that does not verify', () => {
    expect(state(ctx()).admissions_today).toEqual({});
  });
});

describe('release engine (HIMMEL-6796)', () => {
  it('runs request → claim → rule → apply to a receipted RULING line and an applied membership', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'found work', evidence: {}, from: 'console' });
    expect(q.req).toBe('Q-R1-0001');
    expect(claim(ctx(rmEnv)).map((r) => r.req)).toEqual(['Q-R1-0001']);
    const r = admit(q.req);
    expect(r).toMatchObject({ id: 'R-R1-0001', phase: 'intent', class: 'current' });
    const out = await apply(ctx(rmEnv), r.id);
    expect(out.line).toBe('RULING R-R1-0001 Q-R1-0001 INTAKE K-2 add backlog→v1 ADMIT current sector=Planning & tracking — regression: breaks the console');
    expect(out.phase).toBe('receipted');
    expect(jira.fv.get('K-2')).toEqual(['v1']);

    mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-2', fixVersions: ['v1'] }], '2026-10-21T11:00:00.000Z');
    const s = state(ctx());
    expect(s.records.find((x) => x.key === 'K-2' && x.version === 'v1')).toMatchObject({ placement: 'in', ruling: 'R-R1-0001' });
    expect(s.leaks).toEqual({ unauthorized: [], ruled_in_non_member: [] });
    expect(s.trend['2026-10-21']).toEqual({ ruled: 1 });
  });

  it('an applied INTAKE ADMIT appends one rm-admit ledger row, and a replay adds no second (HIMMEL-6918)', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req);
    await apply(ctx(rmEnv), r.id);
    await apply(ctx(rmEnv), r.id);
    const rows = readFileSync(process.env.HIMMEL_ADMISSIONS_LEDGER!, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    expect(rows).toMatchObject([{ version: 'v1', key: 'K-2', kind: 'rm-admit', reason: 'regression: breaks the console', by: 'rm-1' }]);
  });

  it('a re-admission after a removal appends a second rm-admit row, and its replay adds no third (HIMMEL-6796)', async () => {
    await setup();
    const rows = () => readFileSync(process.env.HIMMEL_ADMISSIONS_LEDGER!, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    const q1 = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r1 = admit(q1.req);
    await apply(ctx(rmEnv), r1.id);
    const q2 = request(ctx(), { verb: 'REVERSION', key: 'K-2', from_v: 'v1', to_v: null, why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r2 = admit(q2.req, { outcome: 'MOVE', op: { kind: 'remove', from_v: 'v1', to_v: null }, supersedes: [r1.id] });
    await apply(ctx(rmEnv), r2.id);
    expect(jira.fv.get('K-2')).toEqual([]);
    const q3 = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r3 = admit(q3.req, { supersedes: [r2.id] });
    await apply(ctx(rmEnv), r3.id);
    await apply(ctx(rmEnv), r3.id);
    await apply(ctx(rmEnv), r2.id);
    expect(rows().map((r) => [r.kind, r.key, r.version, r.ruling])).toEqual([
      ['rm-admit', 'K-2', 'v1', r1.id],
      ['rm-remove', 'K-2', 'v1', r2.id],
      ['rm-admit', 'K-2', 'v1', r3.id],
    ]);
  });

  it.each([
    ['frozen', 'v2', 'v1'],
    ['unfrozen', 'v1', 'v2'],
  ])('a REVERSION MOVE into a %s version appends the destination rm-admit and the source rm-remove, and an applied-phase replay adds none (HIMMEL-7059)', async (_kind, from, to) => {
    await setup();
    const rows = () => readFileSync(process.env.HIMMEL_ADMISSIONS_LEDGER!, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    jira.fv.set('K-2', [from]);
    const q = request(ctx(), { verb: 'REVERSION', key: 'K-2', from_v: from, to_v: to, why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req, { outcome: 'MOVE', op: { kind: 'move', from_v: from, to_v: to } });
    expect((await applyThenReplay(r.id)).phase).toBe('receipted');
    expect(jira.fv.get('K-2')).toEqual([to]);
    expect(rows().map((x) => [x.kind, x.key, x.version, x.ruling])).toEqual([
      ['rm-admit', 'K-2', to, r.id],
      ['rm-remove', 'K-2', from, r.id],
    ]);
  });

  it('an INTAKE ADMIT replayed from the applied phase appends no second rm-admit row (HIMMEL-7059)', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req);
    expect((await applyThenReplay(r.id)).phase).toBe('receipted');
    const rows = readFileSync(process.env.HIMMEL_ADMISSIONS_LEDGER!, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    expect(rows.map((x) => [x.kind, x.key, x.version, x.ruling])).toEqual([['rm-admit', 'K-2', 'v1', r.id]]);
  });

  it('an INTAKE ADMIT with an unwritable ledger refuses before Jira is touched (HIMMEL-6918)', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req);
    writeFileSync(join(root, 'not-a-dir'), 'a file where the ledger directory should be');
    process.env.HIMMEL_ADMISSIONS_LEDGER = join(root, 'not-a-dir', 'ledger.jsonl');
    await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow();
    expect(jira.fv.get('K-2')).toBeUndefined();
    process.env.HIMMEL_ADMISSIONS_LEDGER = join(root, 'admissions-ledger.jsonl');
    expect((await apply(ctx(rmEnv), r.id)).phase).toBe('receipted');
    expect(jira.fv.get('K-2')).toEqual(['v1']);
  });

  it('a REMOVE ruling with an unwritable ledger refuses before Jira is touched', async () => {
    await setup();
    const q1 = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r1 = admit(q1.req);
    await apply(ctx(rmEnv), r1.id);
    const q2 = request(ctx(), { verb: 'REVERSION', key: 'K-2', from_v: 'v1', to_v: null, why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r2 = admit(q2.req, { outcome: 'MOVE', op: { kind: 'remove', from_v: 'v1', to_v: null }, supersedes: [r1.id] });
    writeFileSync(join(root, 'not-a-dir'), 'a file where the ledger directory should be');
    process.env.HIMMEL_ADMISSIONS_LEDGER = join(root, 'not-a-dir', 'ledger.jsonl');
    await expect(apply(ctx(rmEnv), r2.id)).rejects.toThrow();
    expect(jira.fv.get('K-2')).toEqual(['v1']);
  });

  it('replaying an applied ruling that a later applied ruling superseded appends no ledger row', async () => {
    await setup();
    const rows = () => readFileSync(process.env.HIMMEL_ADMISSIONS_LEDGER!, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    const q1 = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r1 = admit(q1.req);
    const post = jira.addComment.bind(jira);
    jira.addComment = async () => { throw new Error('jira down before the receipt'); };
    await expect(apply(ctx(rmEnv), r1.id)).rejects.toThrow('jira down');
    jira.addComment = post;
    unlinkSync(process.env.HIMMEL_ADMISSIONS_LEDGER!);
    const q2 = request(ctx(), { verb: 'REVERSION', key: 'K-2', from_v: 'v1', to_v: null, why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r2 = admit(q2.req, { outcome: 'MOVE', op: { kind: 'remove', from_v: 'v1', to_v: null }, supersedes: [r1.id] });
    await apply(ctx(rmEnv), r2.id);
    expect((await apply(ctx(rmEnv), r1.id)).phase).toBe('receipted');
    expect(rows().map((r) => [r.kind, r.key, r.version, r.ruling])).toEqual([['rm-remove', 'K-2', 'v1', r2.id]]);
  });

  it('a replayed apply never posts a second comment', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req);
    await apply(ctx(rmEnv), r.id);
    await apply(ctx(rmEnv), r.id);
    expect(jira.posted).toBe(1);
  });

  it('refuses a reused request id', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    admit(q.req);
    expect(() => admit(q.req)).toThrow(/Q-R1-0001 is ruled:R-R1-0001/);
  });

  it('collapses a duplicate open request into the open one', async () => {
    await setup();
    const a = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    const b = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'again', evidence: {}, from: 'console' });
    expect(b.req).toBe(a.req);
  });

  it('refuses a ruling with no lease owner', () => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'v', mode: 'observe' });
    expect(() => claim(ctx(rmEnv))).toThrow(/no lease owner/);
  });

  it('refuses a ruling from a session that is not the lease owner', async () => {
    await setup();
    expect(() => claim(ctx({ ...rmEnv, HIMMEL_RM_DOC: '/abs/other.md' }))).toThrow(/not the lease owner/);
    expect(() => claim(ctx({ HIMMEL_RM_DOC: DOC }))).toThrow(/HIMMEL_RELEASE_MANAGER/);
  });

  it('refuses a new ruling on a key while its intent is pending', async () => {
    await setup();
    const a = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    admit(a.req);
    const b = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'again', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    expect(() => admit(b.req)).toThrow(/K-2@v1 has a pending intent/);
  });

  it('refuses to freeze a baseline over a pending intent on a key it lists', async () => {
    await setup();
    const q = request(ctx(), { verb: 'REVERSION', key: 'K-1', from_v: 'v1', to_v: 'v2', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req, { outcome: 'MOVE', op: { kind: 'move', from_v: 'v1', to_v: 'v2' }, supersedes: ['baseline-v1-g1'] });
    const refreeze = () => freeze(ctx(), { version: 'v1', keys: ['K-1'], decision: '107', verbatim: 'refrozen' });
    expect(refreeze).toThrow(/R-R1-0001 is a pending intent on K-1@v1; apply or void it first/);
    expect(() => freeze(ctx(), { version: 'v2', keys: ['K-9'], decision: '107', verbatim: 'other key' })).not.toThrow();
    await apply(ctx(rmEnv), r.id);
    expect(refreeze().gen).toBe(2);
  });

  it('requires supersedes when a ruling is already in effect, baseline included', async () => {
    await setup();
    const q = request(ctx(), { verb: 'REVERSION', key: 'K-1', from_v: 'v1', to_v: 'v2', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const move = { req: q.req, outcome: 'MOVE', op: { kind: 'move' as const, from_v: 'v1', to_v: 'v2' } };
    expect(() => admit(q.req, move)).toThrow(/supersedes must name baseline-v1-g1/);
    expect(admit(q.req, { ...move, supersedes: ['baseline-v1-g1'] }).class).toBe('next');
  });

  it('refuses an operator authority whose record does not cover the key', async () => {
    await setup();
    const o = operatorDecision(ctx(), { decision: '101', keys: ['K-9'], op: 'add', from_v: null, to_v: 'v1', verbatim: 'x' });
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    expect(() => admit(q.req, { authority: { kind: 'operator', ref: o.id } })).toThrow(/does not cover K-2/);
  });

  it('keeps operator acts and requests out of the RM and of console-spawned legs', () => {
    expect(() => declare(ctx({ HIMMEL_CONSOLE_LEG: '1' }), { project: 'HIMMEL', versions: ['v1'], decision: '1', verbatim: 'v', mode: 'observe' }))
      .toThrow(/console-spawned leg/);
    declare(ctx(), { project: 'HIMMEL', versions: ['v1'], decision: '1', verbatim: 'v', mode: 'observe' });
    expect(() => request(ctx(rmEnv), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'rm' }))
      .toThrow(/the console writes requests/);
  });

  it('fences the lease: wrong epoch, held lease and takeover', async () => {
    await setup();
    expect(() => leaseAcquire(ctx({ ...rmEnv, HIMMEL_RM_DOC: '/abs/b.md' }), { expectEpoch: 0, doc: '/abs/b.md', session: 'b' }))
      .toThrow(/epoch is 1, expected 0/);
    expect(() => leaseAcquire(ctx({ ...rmEnv, HIMMEL_RM_DOC: '/abs/b.md' }), { expectEpoch: 1, doc: '/abs/b.md', session: 'b' }))
      .toThrow(/held by \/abs\/rm-doc.md/);
    takeover(ctx(), { epoch: 1, doc: '/abs/b.md' });
    expect(leaseAcquire(ctx({ ...rmEnv, HIMMEL_RM_DOC: '/abs/b.md' }), { expectEpoch: 1, doc: '/abs/b.md', session: 'b' }).epoch).toBe(2);
  });

  it('a successor voids an old-epoch intent Jira never saw and reopens its request', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req);
    leaseRelease(ctx(rmEnv));
    const next = { ...rmEnv, HIMMEL_RM_DOC: '/abs/b.md' };
    leaseAcquire(ctx(next), { expectEpoch: 1, doc: '/abs/b.md', session: 'b' });
    await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow(/not the lease owner/);
    const out = await apply(ctx(next), r.id);
    expect(out.phase).toBe('void');
    expect(jira.fv.get('K-2')).toBeUndefined();
    expect(claim(ctx(next)).map((x) => x.req)).toEqual([q.req]);
  });

  it('a tampered declaration makes the state UNKNOWN and refuses rulings', async () => {
    await setup();
    const p = join(root, 'release', 'R1', 'release.json');
    writeFileSync(p, readFileSync(p, 'utf8').replace('"v2"', '"v9"'));
    expect(state(ctx()).status).toBe('UNKNOWN');
    expect(() => claim(ctx(rmEnv))).toThrow(/UNKNOWN/);
  });

  it('an applied DISCHARGE keeps the fixVersion it discharges', async () => {
    await setup();
    jira.fv.set('K-1', ['v1']);
    const q = request(ctx(), { verb: 'DISCHARGE', key: 'K-1', from_v: 'v1', to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req, { outcome: 'ACCEPT', op: { kind: 'discharge', from_v: 'v1', to_v: 'v1' }, supersedes: ['baseline-v1-g1'] });
    await apply(ctx(rmEnv), r.id);
    expect(jira.fv.get('K-1')).toEqual(['v1']);
  });

  it('a DISCHARGE whose fixVersion is absent from Jira fails its readback', async () => {
    await setup();
    const q = request(ctx(), { verb: 'DISCHARGE', key: 'K-1', from_v: 'v1', to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req, { outcome: 'ACCEPT', op: { kind: 'discharge', from_v: 'v1', to_v: 'v1' }, supersedes: ['baseline-v1-g1'] });
    await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow(/readback does not match/);
  });

  it('a rejected DISCHARGE supersedes nothing and leaves the baseline in', async () => {
    await setup();
    jira.fv.set('K-1', ['v1']);
    mirror([{ key: 'K-1', fixVersions: ['v1'] }]);
    const q = request(ctx(), { verb: 'DISCHARGE', key: 'K-1', from_v: 'v1', to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    expect(() => admit(q.req, { outcome: 'REJECT', op: { kind: 'none', from_v: 'v1', to_v: 'v1' }, supersedes: ['baseline-v1-g1'] }))
      .toThrow(/supersedes nothing/);
    const r = admit(q.req, { outcome: 'REJECT', op: { kind: 'none', from_v: 'v1', to_v: 'v1' } });
    await apply(ctx(rmEnv), r.id);
    const s = state(ctx());
    expect(s.leaks.unauthorized).toEqual([]);
    expect(s.burndown.v1.baseline).toBe(1);
  });

  it('a successor never voids an old-epoch move Jira half applied', async () => {
    await setup();
    jira.fv.set('K-1', ['v1']);
    const q = request(ctx(), { verb: 'REVERSION', key: 'K-1', from_v: 'v1', to_v: 'v2', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req, { outcome: 'MOVE', op: { kind: 'move', from_v: 'v1', to_v: 'v2' }, supersedes: ['baseline-v1-g1'] });
    jira.fv.set('K-1', []);
    leaseRelease(ctx(rmEnv));
    const next = { ...rmEnv, HIMMEL_RM_DOC: '/abs/b.md' };
    leaseAcquire(ctx(next), { expectEpoch: 1, doc: '/abs/b.md', session: 'b' });
    await expect(apply(ctx(next), r.id)).rejects.toThrow(/partly applied/);
    expect(claim(ctx(next))).toEqual([]);
  });

  it('an emergency ruling may cite the standing emergency record', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'red main', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    expect(admit(q.req, { authority: { kind: 'operator', ref: 'O-R1-emergency' } }).id).toBe('R-R1-0001');
  });

  it('declares observe only: live waits for the activation barrier', () => {
    expect(() => declare(ctx(), { project: 'HIMMEL', versions: ['v1'], decision: '1', verbatim: 'v', mode: 'live' }))
      .toThrow(/activation barrier/);
  });

  it('a long async lock holder keeps its lock fresh and never unlinks a successor', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'release-lock-'));
    const lock = join(dir, '.lock');
    await withLockAsync(dir, async () => {
      await new Promise((r) => setTimeout(r, 300));
      expect(Date.now() - statSync(lock).mtimeMs).toBeLessThan(200);
      unlinkSync(lock);
      writeFileSync(lock, 'another writer');
    }, 1000, 200);
    expect(readFileSync(lock, 'utf8')).toBe('another writer');
  });

  it('a second breaker never unlinks the successor\'s fresh lock', () => {
    const dir = mkdtempSync(join(tmpdir(), 'release-lock-'));
    const lock = join(dir, '.lock');
    writeFileSync(lock, 'crashed writer');
    const old = new Date(Date.now() - 120_000);
    utimesSync(lock, old, old);
    let successorIno = 0;
    breakStaleLock(lock, 60_000, () => {
      // another breaker wins the race: it breaks the stale lock and takes a fresh one
      unlinkSync(lock);
      closeFd(openSync(lock, 'wx'));
      successorIno = statSync(lock).ino;
    });
    expect(statSync(lock).ino).toBe(successorIno);
  });

  it('a breaker leaves the lock in place while another breaker holds the break mutex', () => {
    const dir = mkdtempSync(join(tmpdir(), 'release-lock-'));
    const lock = join(dir, '.lock');
    writeFileSync(lock, 'crashed writer');
    const old = new Date(Date.now() - 120_000);
    utimesSync(lock, old, old);
    writeFileSync(`${lock}.break`, 'another breaker');
    const ino = statSync(lock).ino;
    breakStaleLock(lock, 60_000);
    expect(statSync(lock).ino).toBe(ino);
  });

  it('a break removes the stale lock and leaves no mutex or tombstone behind', () => {
    const dir = mkdtempSync(join(tmpdir(), 'release-lock-'));
    const lock = join(dir, '.lock');
    writeFileSync(lock, 'crashed writer');
    const old = new Date(Date.now() - 120_000);
    utimesSync(lock, old, old);
    breakStaleLock(lock, 60_000);
    expect(readdirSync(dir)).toEqual([]);
  });

  it.skipIf(process.getuid?.() === 0)('a crash between the applied row and its event is repaired by the retry', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'found work', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req);
    const events = join(root, 'release', 'R1', 'events.jsonl');
    writeFileSync(events, '', { mode: 0o444 });
    chmodSync(events, 0o444);
    await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow();
    chmodSync(events, 0o644);
    const out = await apply(ctx(rmEnv), r.id);
    expect(out.phase).toBe('receipted');
    const ruled = readFileSync(events, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l))
      .filter((e) => e.kind === 'ruled' && e.ruling === r.id);
    expect(ruled).toHaveLength(1);
  });

  it('a frozen baseline is immutable: editing it breaks verification', async () => {
    await setup();
    mirror([{ key: 'K-1', fixVersions: ['v1'] }]);
    expect(state(ctx()).burndown.v1.baseline).toBe(1);
    const p = join(root, 'release', 'R1', 'baseline-v1-g1.json');
    writeFileSync(p, readFileSync(p, 'utf8').replace('"K-1"', '"K-8"'));
    expect(state(ctx()).status).toBe('UNKNOWN');
  });
});

describe('release fold (HIMMEL-7158)', () => {
  const events = () => readFileSync(join(root, 'release', 'R1', 'events.jsonl'), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const closedDone = { status: 'Closed', category: 'Done', resolution: 'Done' };
  const resync = '2026-10-21T11:00:00.000Z';

  it('reads a Closed key as terminal Done, so it leaves the open burn-down', async () => {
    await setup();
    mirror([{ key: 'K-1', fixVersions: ['v1'], ...closedDone }], resync);
    const s = state(ctx());
    expect(s.records.find((x) => x.key === 'K-1')).toMatchObject({ terminal: 'Done' });
    expect(s.burndown.v1.baseline_open).toBe(0);
  });

  it('writes one verifying events row per key, and a folded Closed key is bookkeeping, not a leak', async () => {
    await setup();
    mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-3', fixVersions: ['v1'], ...closedDone }]);
    expect(state(ctx()).leaks.unauthorized).toEqual(['K-3@v1']);
    const out = fold(ctx(), { to: 'v1', items: [{ key: 'K-3', pr: 12 }] });
    expect(out.skipped).toEqual([]);
    expect(events()).toMatchObject([{ kind: 'fold', key: 'K-3', from: null, to: 'v1', pr: 12 }]);
    mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-3', fixVersions: ['v1'], ...closedDone }], resync);
    const s = state(ctx());
    expect(s.inputs.events).toBe('FRESH');
    expect(s.records.find((x) => x.key === 'K-3')).toMatchObject({ terminal: 'Done', bookkeeping: 'fold:12' });
    expect(s.leaks.unauthorized).toEqual([]);
  });

  it('skips a key that cannot fold and names its terminal and resolution; it stays a leak', async () => {
    await setup();
    const all = [
      { key: 'K-3', fixVersions: ['v1'], ...closedDone },
      { key: 'K-4', fixVersions: ['v1'], status: 'Closed', category: 'Done', resolution: "Won't Do" },
      { key: 'K-5', fixVersions: ['v1'], status: 'Closed', category: 'Done', resolution: 'Cannot Reproduce' },
      { key: 'K-6', fixVersions: ['v1'] },
    ];
    mirror(all);
    const out = fold(ctx(), { to: 'v1', items: ['K-3', 'K-4', 'K-5', 'K-6', 'K-9'].map((key) => ({ key, pr: 7 })) });
    expect(out.folded.map((e) => e.key)).toEqual(['K-3']);
    expect(out.skipped).toEqual([
      { key: 'K-4', terminal: "Won't Do", resolution: "Won't Do" },
      { key: 'K-5', terminal: 'Other', resolution: 'Cannot Reproduce' },
      { key: 'K-6', terminal: 'open', resolution: 'none' },
      { key: 'K-9', terminal: 'not-in-mirror', resolution: 'none' },
    ]);
    expect(events().map((e) => e.key)).toEqual(['K-3']);
    mirror(all, resync);
    expect(state(ctx()).leaks.unauthorized).toEqual(['K-4@v1', 'K-5@v1', 'K-6@v1']);
  });

  it('a re-run folds nothing twice', async () => {
    await setup();
    mirror([{ key: 'K-3', fixVersions: ['v1'], ...closedDone }]);
    fold(ctx(), { to: 'v1', items: [{ key: 'K-3', pr: 12 }] });
    const again = fold(ctx(), { to: 'v1', items: [{ key: 'K-3', pr: 12 }] });
    expect(again).toMatchObject({ folded: [], already: ['K-3'], skipped: [] });
    expect(events()).toHaveLength(1);
  });

  it('reopen reverses a fold and refuses a key with no fold to reverse', async () => {
    await setup();
    const all = [{ key: 'K-3', fixVersions: ['v1'], ...closedDone }];
    mirror(all);
    expect(() => reopen(ctx(), { key: 'K-3', from: 'v1' })).toThrow(/no fold into v1/);
    fold(ctx(), { to: 'v1', items: [{ key: 'K-3', pr: 12 }] });
    expect(reopen(ctx(), { key: 'K-3', from: 'v1' })).toMatchObject({ kind: 'reopen', key: 'K-3', from: 'v1', to: null });
    mirror(all, resync);
    const s = state(ctx());
    expect(s.inputs.events).toBe('FRESH');
    expect(s.leaks.unauthorized).toEqual(['K-3@v1']);
  });

  it('is a console act on a declared version with a real PR number', async () => {
    await setup();
    mirror([{ key: 'K-3', fixVersions: ['v1'], ...closedDone }]);
    expect(() => fold(ctx(rmEnv), { to: 'v1', items: [{ key: 'K-3', pr: 12 }] })).toThrow(/console act/);
    expect(() => fold(ctx(), { to: 'v9', items: [{ key: 'K-3', pr: 12 }] })).toThrow(/not a version/);
    expect(() => fold(ctx(), { to: 'v1', items: [{ key: 'K-3', pr: 0 }] })).toThrow(/positive PR/);
    expect(() => fold(ctx(), { to: 'v1', items: [{ key: 'K-3', pr: 2 ** 60 }] })).toThrow(/positive PR/);
    expect(() => fold(ctx(), { to: 'v1', items: [{ key: 'bad key', pr: 1 }] })).toThrow(/not an issue key/);
    expect(() => fold(ctx(), { to: 'v1', items: [{ key: 'K-3', pr: 12 }] })).not.toThrow();
  });
});

describe('rm-run: the on-demand release manager (HIMMEL-7201)', () => {
  const declared = () => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
  };
  const ask = (k: string) => request(ctx(), { verb: 'INTAKE', key: k, from_v: null, to_v: 'v1', why: 'found work', evidence: {}, from: 'console' });
  const admitAll: Judge = async (input) => input.requests.map((q) => ({
    req: q.req, outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 'Ship loop', ground: 'regression', reason: 'breaks the console',
  }));
  const snapshot = (dir: string): Record<string, string> => Object.fromEntries(
    readdirSync(dir, { recursive: true, withFileTypes: true }).filter((e) => e.isFile())
      .map((e) => { const p = join(e.parentPath, e.name); return [p, readFileSync(p, 'utf8')]; }),
  );

  it('rules a pending request with no standing session and releases the lease', async () => {
    declared();
    ask('K-2');
    const lines = await rmRun(ctx(), admitAll);
    expect(lines).toContain('RULING R-R1-0001 Q-R1-0001 INTAKE K-2 add backlog→v1 ADMIT current sector=Ship loop — regression: breaks the console');
    expect(jira.fv.get('K-2')).toEqual(['v1']);
    const s = state(ctx());
    expect(s.lease).toMatchObject({ epoch: 1, released: true });
    expect(s.requests).toEqual({ open: [], claimed: [] });
  });

  it('refuses a concurrent batch by the lease and rules nothing in it', async () => {
    declared();
    ask('K-2');
    let inner: unknown;
    await rmRun(ctx(), async (input) => {
      inner = await rmRun(ctx(), admitAll).catch((e: Error) => e);
      return admitAll(input);
    });
    expect(String(inner)).toMatch(/release lease: held by/);
    expect(readFileSync(join(ctx().dir, 'rulings.jsonl'), 'utf8').match(/"phase":"intent"/g)).toHaveLength(1);
  });

  it('exits on an empty queue with nothing written and no judge call', async () => {
    declared();
    const before = snapshot(ctx().dir);
    let called = false;
    expect(await rmRun(ctx(), async () => { called = true; return []; })).toEqual(['RM-RUN R1: nothing pending']);
    expect(called).toBe(false);
    expect(snapshot(ctx().dir)).toEqual(before);
  });

  it('a failed judge rules nothing, releases the lease, and the next run reclaims', async () => {
    declared();
    ask('K-2');
    await expect(rmRun(ctx(), async () => { throw new Error('HOLD'); })).rejects.toThrow(/HOLD/);
    expect(state(ctx()).lease).toMatchObject({ epoch: 1, released: true });
    expect(state(ctx()).requests.claimed).toEqual(['Q-R1-0001']);
    expect(await rmRun(ctx(), admitAll)).toContainEqual(expect.stringMatching(/^RULING R-R1-0001 Q-R1-0001 /));
  });

  it('a judge reply the check refused is kept in the run doc with the failing field', async () => {
    declared();
    ask('K-2');
    const doc = join(ctx().dir, 'rm-runs', 'refused.md');
    await expect(rmRun(ctx(), async () => { throw new JudgeReplyError('decision 0 field sector', '[{"req":"x"}]'); }, { doc }))
      .rejects.toThrow(/decision 0 field sector/);
    const text = readFileSync(doc, 'utf8');
    expect(text).toMatch(/decision 0 field sector/);
    expect(text).toContain('[{"req":"x"}]');
  });

  it('the judge sees the sector the mirror holds for a ticket', () => {
    const mirror = join(root, 'mirror-sector');
    mkdirSync(mirror, { recursive: true });
    writeFileSync(join(mirror, '.cursor.json'), JSON.stringify({ lastSync: '2026-10-23T15:00:55.697Z' }));
    writeFileSync(join(mirror, 'K-9.md'), '---\nkey: "K-9"\ntype: "Task"\nstatus: "To Do"\npriority: "Medium"\nfixVersions: []\nresolution: null\nsector: "Ship loop"\n---\n');
    expect(readMirror(mirror).issues?.get('K-9')?.sector).toBe('Ship loop');
  });

  it('a decision the engine refuses is reported and its request stays claimed', async () => {
    vi.stubEnv('JIRA_SECTOR_FIELD', 'customfield_10500');
    declared();
    ask('K-2');
    const lines = await rmRun(ctx(), async (input) => input.requests.map((q) => ({
      req: q.req, outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: '', ground: 'regression', reason: 'x',
    })));
    expect(lines).toEqual([expect.stringMatching(/^REFUSED Q-R1-0001: release rule: a ruling without a sector/)]);
    expect(state(ctx()).requests.claimed).toEqual(['Q-R1-0001']);
  });

  it('with no Sector field configured a ruling without a sector carries sector=none and applies', async () => {
    vi.stubEnv('JIRA_SECTOR_FIELD', 'none');
    declared();
    ask('K-2');
    const lines = await rmRun(ctx(), async (input) => input.requests.map((q) => ({
      req: q.req, outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: '', ground: 'regression', reason: 'x',
    })));
    expect(lines[0]).toMatch(/^RULING R-R1-0001 Q-R1-0001 INTAKE K-2 add backlog→v1 ADMIT current sector=none — regression: x/);
    expect(jira.fv.get('K-2')).toEqual(['v1']);
  });

  it('a HOLD decision is reported as HELD, rules nothing and leaves the request claimed', async () => {
    declared();
    ask('K-2');
    const lines = await rmRun(ctx(), async (input) => input.requests.map((q) => ({
      req: q.req, outcome: 'HOLD', reason: 'no sector for K-2',
    })));
    expect(lines).toEqual(['HELD Q-R1-0001: no sector for K-2']);
    expect(state(ctx()).requests.claimed).toEqual(['Q-R1-0001']);
    expect(existsSync(join(ctx().dir, 'rulings.jsonl'))).toBe(false);
  });

  it('offers the judge the live Jira snapshot of a claimed key the mirror lacks', async () => {
    declared();
    mirror([{ key: 'K-9', fixVersions: [] }]);
    ask('K-2');
    jira.live.set('K-2', { key: 'K-2', status: 'To Do', type: 'Task', priority: 'Medium', fixVersions: [], resolution: null, sector: 'Ship loop' });
    let seen: unknown;
    await rmRun(ctx(), async (input) => { seen = input.issues; return admitAll(input); });
    expect(seen).toEqual([expect.objectContaining({ key: 'K-2', sector: 'Ship loop' })]);
  });

  it('a mirror row without a sector is replaced by the live Jira snapshot', async () => {
    declared();
    mirror([{ key: 'K-2', fixVersions: [] }]);
    ask('K-2');
    jira.live.set('K-2', { key: 'K-2', status: 'To Do', type: 'Task', priority: 'Medium', fixVersions: [], resolution: null, sector: 'Ship loop' });
    let seen: unknown;
    await rmRun(ctx(), async (input) => { seen = input.issues; return admitAll(input); });
    expect(seen).toEqual([expect.objectContaining({ key: 'K-2', sector: 'Ship loop' })]);
  });

  it('a live lookup that never answers falls back to the mirror row once its deadline passes', async () => {
    vi.useFakeTimers();
    try {
      declared();
      mirror([{ key: 'K-2', fixVersions: [] }]);
      ask('K-2');
      jira.issue = () => new Promise<IssueSnap | null>(() => {});
      let seen: unknown;
      const run = rmRun(ctx(), async (input) => { seen = input.issues; return admitAll(input); });
      await vi.advanceTimersByTimeAsync(LIVE_LOOKUP_MS);
      await run;
      expect(seen).toEqual([expect.objectContaining({ key: 'K-2' })]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('a mirror row with a sector is not re-read from Jira', async () => {
    declared();
    mirror([{ key: 'K-2', fixVersions: [], sector: 'Visibility' }]);
    ask('K-2');
    jira.live.set('K-2', { key: 'K-2', status: 'To Do', type: 'Task', priority: 'Medium', fixVersions: [], resolution: null, sector: 'Ship loop' });
    let seen: unknown;
    await rmRun(ctx(), async (input) => { seen = input.issues; return admitAll(input); });
    expect(seen).toEqual([expect.objectContaining({ key: 'K-2', sector: 'Visibility' })]);
  });

  it('a ruling Jira did not take is PENDING, and the next run applies it', async () => {
    declared();
    ask('K-2');
    const post = jira.addComment;
    jira.addComment = async () => { throw new Error('jira down'); };
    expect(await rmRun(ctx(), admitAll)).toEqual(['PENDING R-R1-0001: jira down']);
    jira.addComment = post;
    expect(await rmRun(ctx(), admitAll)).toContainEqual(expect.stringMatching(/^RULING R-R1-0001 Q-R1-0001 /));
  });

  it('writes the run record under a --doc parent that does not exist yet', async () => {
    declared();
    ask('K-2');
    const doc = join(ctx().dir, 'elsewhere', 'run.md');
    expect(await rmRun(ctx(), admitAll, { doc })).toContainEqual(expect.stringMatching(/^RULING R-R1-0001 /));
    expect(readFileSync(doc, 'utf8')).toMatch(/^- RULING R-R1-0001 /m);
  });
});
