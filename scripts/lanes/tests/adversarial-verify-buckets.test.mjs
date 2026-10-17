// scripts/lanes/tests/adversarial-verify-buckets.test.mjs
// The workflow body uses top-level await and a final `return`, so it is loaded
// as text, the `export const meta` block is cut, and the rest runs inside an
// AsyncFunction fed stub pipeline/agent/parallel.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const SRC = readFileSync(join(here, '../../../.claude/workflows/adversarial-verify.js'), 'utf8');
const BODY = SRC.replace(/^export const meta = \{[\s\S]*?^\}\n/m, '');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const run = new AsyncFunction('pipeline', 'agent', 'parallel', 'args', BODY);

const pipeline = (items, ...stages) => Promise.all(items.map(async (item, i) => {
  try {
    let prev = item;
    for (const stage of stages) prev = await stage(prev, item, i);
    return prev;
  } catch { return null; }
}));
const parallel = thunks => Promise.all(thunks.map(t => t().catch(() => null)));

// reviews: { <dimension key>: [finding] }; verdict(finding, callIndex) -> verdict;
// judge(prompt, opts) -> { judgments: [{ key, bucket, rationale }] }
async function exec({ reviews = {}, verdict = () => ({ refuted: false, reason: 'holds' }), judge = () => ({ judgments: [] }) }) {
  const calls = { judge: [], review: [], verify: [] };
  const seen = {};
  const agent = async (prompt, opts = {}) => {
    const label = opts.label || '';
    if (label.startsWith('review:')) { calls.review.push({ prompt, opts }); return { findings: reviews[label.slice(7)] ?? [] }; }
    if (label.startsWith('verify:')) {
      calls.verify.push({ prompt, opts });
      const n = seen[prompt] = (seen[prompt] ?? 0) + 1;
      return verdict(prompt, n);
    }
    if (label.startsWith('judge')) { calls.judge.push({ prompt, opts }); return judge(prompt, opts); }
    throw new Error(`unexpected agent label: ${label}`);
  };
  return { out: await run(pipeline, agent, parallel, undefined), calls };
}

const F = (file, line, severity = 'important', title = `${file}:${line} problem`) => ({ title, file, line, severity });
const act = key => ({ key, bucket: 'act', rationale: 'real' });

test('(a) a finding two reviewers raised independently is listed first in agreement and lands in act', async () => {
  const shared = F('a.js', 10);
  const { out } = await exec({
    reviews: { correctness: [F('z.js', 1, 'minor'), shared], 'silent-failure': [shared] },
    judge: () => ({ judgments: [{ ...act('a.js:10'), sameDefect: true }, { key: 'z.js:1', bucket: 'noted', rationale: 'minor' }] }),
  });
  assert.deepEqual(Object.keys(out.agreement), ['a.js:10']);
  assert.deepEqual(out.agreement['a.js:10'].raisedBy.sort(), ['correctness', 'silent-failure']);
  assert.equal(out.buckets.act[0].file, 'a.js');
  assert.deepEqual(out.buckets.act[0].raisedBy.sort(), ['correctness', 'silent-failure']);
});

test('(a2) inside a bucket the agreed finding sorts ahead of a lone one', async () => {
  const shared = F('b.js', 2, 'minor');
  const { out } = await exec({
    reviews: { correctness: [F('a.js', 1, 'minor'), shared], 'silent-failure': [shared] },
    judge: () => ({ judgments: [{ key: 'a.js:1', bucket: 'consider', rationale: 'r' }, { key: 'b.js:2', bucket: 'consider', rationale: 'r', sameDefect: true }] }),
  });
  assert.deepEqual(out.buckets.consider.map(f => f.file), ['b.js', 'a.js']);
});

test('(b) a lone, non-critical finding the verifier confirmed is never act even if the judge says act', async () => {
  const { out } = await exec({
    reviews: { correctness: [F('b.js', 5, 'important')] },
    judge: () => ({ judgments: [act('b.js:5')] }),
  });
  assert.equal(out.buckets.act.length, 0);
  assert.equal(out.buckets.consider.length, 1);
  assert.equal(out.buckets.consider[0].file, 'b.js');
  assert.deepEqual(out.agreement, {});
});

test('(b2) a lone finding the judge puts in noted stays in noted', async () => {
  const { out } = await exec({
    reviews: { correctness: [F('b.js', 5, 'minor')] },
    judge: () => ({ judgments: [{ key: 'b.js:5', bucket: 'noted', rationale: 'low impact' }] }),
  });
  assert.equal(out.buckets.noted.length, 1);
  assert.equal(out.buckets.noted[0].rationale, 'low impact');
});

test('(b3) a lone critical finding is still capped at consider', async () => {
  const { out } = await exec({
    reviews: { correctness: [F('c.js', 3, 'critical')] },
    judge: () => ({ judgments: [act('c.js:3')] }),
  });
  assert.equal(out.buckets.act.length, 0);
  assert.equal(out.buckets.consider.length, 1);
  assert.deepEqual(out.agreement, {});
});

test('(c) a refuted finding lands in dismissed with the verifier reason, not dropped', async () => {
  const { out, calls } = await exec({
    reviews: { correctness: [F('d.js', 7)] },
    verdict: () => ({ refuted: true, reason: 'caller validates' }),
  });
  assert.equal(out.buckets.dismissed.length, 1);
  assert.equal(out.buckets.dismissed[0].file, 'd.js');
  assert.match(out.buckets.dismissed[0].rationale, /caller validates/);
  assert.equal(calls.judge.length, 0, 'nothing confirmed, so no judge call');
});

test('(d) confirmed is still returned, element shape unchanged', async () => {
  const f = F('e.js', 9, 'critical', 'bad thing');
  const { out } = await exec({
    reviews: { correctness: [f] },
    verdict: () => ({ refuted: false, reason: 'holds' }),
    judge: () => ({ judgments: [act('e.js:9')] }),
  });
  assert.deepEqual(out.confirmed, [{ ...f, verdict: { refuted: false, reason: 'holds' } }]);
});

test('no findings: four empty buckets, empty agreement, empty confirmed, no judge call', async () => {
  const { out, calls } = await exec({});
  assert.deepEqual(out.buckets, { act: [], consider: [], noted: [], dismissed: [] });
  assert.deepEqual(out.agreement, {});
  assert.deepEqual(out.confirmed, []);
  assert.equal(calls.judge.length, 0);
});

test('a verifier that stays uncertain (refuted:true by default) keeps the default-to-refuted behaviour', async () => {
  const { out } = await exec({
    reviews: { correctness: [F('f.js', 4)] },
    verdict: () => ({ refuted: true, reason: 'uncertain' }),
  });
  assert.deepEqual(out.confirmed, []);
  assert.equal(out.buckets.dismissed.length, 1);
});

test('a verifier that returns no verdict is dismissed, not dropped and not confirmed', async () => {
  const { out } = await exec({
    reviews: { correctness: [F('g.js', 4)] },
    verdict: () => null,
  });
  assert.deepEqual(out.confirmed, []);
  assert.equal(out.buckets.dismissed.length, 1);
});

test('verifiers disagreeing on one report: the refuted raiser is dismissed, the survivor is a lone raiser capped at consider', async () => {
  const shared = F('h.js', 8);
  const { out } = await exec({
    reviews: { correctness: [shared], 'silent-failure': [shared] },
    verdict: (_p, n) => (n === 1 ? { refuted: true, reason: 'no' } : { refuted: false, reason: 'yes' }),
    judge: () => ({ judgments: [act('h.js:8')] }),
  });
  assert.equal(out.buckets.act.length, 0);
  assert.equal(out.buckets.consider.length, 1);
  assert.equal(out.buckets.consider[0].raisedBy.length, 1);
  assert.equal(out.buckets.dismissed.length, 1);
  assert.deepEqual(out.agreement, {});
});

test('two different findings on one line, one refuted and one confirmed critical: no borrowed agreement, each keeps its own title', async () => {
  const refutedOne = F('k.js', 4, 'important', 'swallowed error');
  const critical = F('k.js', 4, 'critical', 'unbounded loop');
  const { out, calls } = await exec({
    reviews: { correctness: [refutedOne], 'silent-failure': [critical] },
    verdict: p => (p.includes('swallowed error') ? { refuted: true, reason: 'caller handles it' } : { refuted: false, reason: 'holds' }),
    judge: () => ({ judgments: [act('k.js:4')] }),
  });
  assert.equal(out.buckets.act.length, 0);
  assert.equal(out.buckets.consider.length, 1);
  assert.equal(out.buckets.consider[0].title, 'unbounded loop');
  assert.deepEqual(out.buckets.consider[0].raisedBy, ['silent-failure']);
  assert.equal(out.buckets.dismissed.length, 1);
  assert.equal(out.buckets.dismissed[0].title, 'swallowed error');
  assert.deepEqual(out.buckets.dismissed[0].raisedBy, ['correctness']);
  assert.deepEqual(out.agreement, {});
  assert.doesNotMatch(calls.judge[0].prompt, /swallowed error/);
});

test('two confirmed reports on one line the judge says are different defects: capped at consider, not in agreement, both titles reach the judge', async () => {
  const { out, calls } = await exec({
    reviews: { correctness: [F('m.js', 2, 'important', 'off by one')], 'silent-failure': [F('m.js', 2, 'important', 'error dropped')] },
    judge: () => ({ judgments: [{ key: 'm.js:2', bucket: 'act', rationale: 'real', sameDefect: false }] }),
  });
  assert.equal(out.buckets.act.length, 0);
  assert.equal(out.buckets.consider.length, 1);
  assert.deepEqual(out.agreement, {});
  assert.match(calls.judge[0].prompt, /off by one/);
  assert.match(calls.judge[0].prompt, /error dropped/);
});

const twoDifferent = { correctness: [F('p.js', 3, 'critical', 'off by one')], 'silent-failure': [F('p.js', 3, 'critical', 'error dropped')] };

test('two different reports on one line, judge says act but omits sameDefect: not act, not agreement', async () => {
  const { out } = await exec({ reviews: twoDifferent, judge: () => ({ judgments: [act('p.js:3')] }) });
  assert.equal(out.buckets.act.length, 0);
  assert.equal(out.buckets.consider.length, 1);
  assert.deepEqual(out.agreement, {});
});

test('two different reports on one line, judge omits the key: consider, not agreement', async () => {
  const { out } = await exec({ reviews: twoDifferent, judge: () => ({ judgments: [] }) });
  assert.equal(out.buckets.act.length, 0);
  assert.equal(out.buckets.consider.length, 1);
  assert.deepEqual(out.agreement, {});
});

test('two different reports on one line, judge returns null: consider, not agreement', async () => {
  const { out } = await exec({ reviews: twoDifferent, judge: () => null });
  assert.equal(out.buckets.act.length, 0);
  assert.equal(out.buckets.consider.length, 1);
  assert.deepEqual(out.agreement, {});
});

test('the judge schema requires sameDefect', async () => {
  const { calls } = await exec({ reviews: twoDifferent, judge: () => ({ judgments: [] }) });
  assert.ok(calls.judge[0].opts.schema.properties.judgments.items.required.includes('sameDefect'));
});

test('review and verify agents name an explicit model', async () => {
  const { calls } = await exec({ reviews: { correctness: [F('n.js', 1)] }, judge: () => ({ judgments: [] }) });
  assert.ok(calls.review.length >= 2 && calls.verify.length >= 1);
  for (const c of [...calls.review, ...calls.verify]) assert.equal(c.opts.model, 'sonnet');
});

test('a confirmed finding the judge leaves out falls to consider, not dropped', async () => {
  const { out } = await exec({
    reviews: { correctness: [F('i.js', 6, 'minor')] },
    judge: () => ({ judgments: [] }),
  });
  assert.equal(out.buckets.consider.length, 1);
});

test('the judge call runs on model opus at effort high', async () => {
  const { calls } = await exec({
    reviews: { correctness: [F('j.js', 1)] },
    judge: () => ({ judgments: [] }),
  });
  assert.equal(calls.judge.length, 1);
  assert.equal(calls.judge[0].opts.model, 'opus');
  assert.equal(calls.judge[0].opts.effort, 'high');
});

test('no Cursor slug, pstack-models lookup or Grok default leaked into the workflow', () => {
  assert.doesNotMatch(SRC, /grok|pstack-models|\.cursor|xhigh-fast/i);
});
