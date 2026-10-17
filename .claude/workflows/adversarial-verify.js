export const meta = {
  name: 'adversarial-verify',
  description: 'Review a diff across dimensions, adversarially verify each finding, sort the verified findings into act / consider / noted / dismissed with an agreement map',
  whenToUse: 'CR-shaped fan-out: findings must survive independent refutation',
  phases: [{ title: 'Review' }, { title: 'Verify' }, { title: 'Judge' }],
}
// The four-bucket lead judgment, the agreement weighting and the reviewer rubric
// are adapted, in our own wording, from pstack /interrogate (cursor/plugins at
// 99743e9c151c8537cbbf1f98bb38f34ef3368453, MIT, Lauren Tan). Not taken: the
// per-model reviewer lookup and model slugs. Reviewers here differ by dimension.
const FINDINGS = {
  type: 'object', required: ['findings'],
  properties: { findings: { type: 'array', items: { type: 'object',
    required: ['title', 'file', 'line', 'severity'],
    properties: { title: {type:'string'}, file: {type:'string'},
      line: {type:'number'}, severity: {enum:['critical','important','minor']},
      evidence: {type:'string'} } } } }
}
const VERDICT = { type: 'object', required: ['refuted'],
  properties: { refuted: {type:'boolean'}, reason: {type:'string'} } }
const JUDGMENTS = { type: 'object', required: ['judgments'],
  properties: { judgments: { type: 'array', items: { type: 'object',
    required: ['key', 'bucket', 'rationale', 'sameDefect'],
    properties: { key: {type:'string'}, bucket: {enum:['act','consider','noted','dismissed']},
      rationale: {type:'string'}, sameDefect: {type:'boolean'} } } } } }

const REVIEW_RUBRIC = [
  'Review the current branch diff vs main as an adversarial reviewer. Find real problems; do not praise the code. Assume the goal of the change is right and challenge how it is carried out.',
  'Lenses, use the ones that apply and skip the rest:',
  '- correctness: empty and boundary inputs, error paths that are caught or swallowed, a rerun after a half-finished run, shared mutable state touched by more than one actor;',
  '- root cause: a guard masking a broken invariant, a retry hiding a broken contract, a fix in the wrong layer, a "don\'t do X" comment where a check would make X impossible;',
  '- structure: validation at the boundary rather than scattered, new coupling, a new path added while the old one stays alive;',
  '- verification: would a test fail without this change, and is the real thing checked rather than a proxy such as an mtime or a self-report;',
  '- complexity: dead code, an abstraction with one caller, options for cases that do not exist;',
  '- security: trace untrusted input to the sink and show the path.',
  'A finding names the file and line, traces the concrete path that breaks, and says why it matters in the evidence field. Keep "this is broken" apart from "I would do it differently". Read the callers before flagging a hypothetical. Return no findings when there are none: an empty review is a valid result.',
].join('\n')
const DIMENSIONS = [
  { key: 'correctness', prompt: `${REVIEW_RUBRIC}\nYour dimension: correctness bugs. Return findings.` },
  { key: 'silent-failure', prompt: `${REVIEW_RUBRIC}\nYour dimension: swallowed errors and silent wrong-state paths. Return findings.` },
]
const SEVERITY_RANK = { critical: 0, important: 1, minor: 2 }

const results = await pipeline(
  DIMENSIONS,
  d => agent(d.prompt, { label: `review:${d.key}`, phase: 'Review', model: 'sonnet', schema: FINDINGS }),
  (review, d) => parallel((review?.findings ?? []).map(f => () =>
    agent(`Try to refute this finding with cited evidence from the file at ${f.file}:${f.line}: ${f.title}. Check whether a caller can actually reach the path: a hypothetical no caller reaches is refuted. Default to refuted=true if uncertain.`,
      { label: `verify:${f.file}`, phase: 'Verify', model: 'sonnet', schema: VERDICT })
      .then(v => ({ dim: d.key, finding: { ...f, verdict: v } }))))
)
const raw = results.flat().filter(Boolean)
const confirmed = raw.map(r => r.finding).filter(f => f.verdict && !f.verdict.refuted)

const buckets = { act: [], consider: [], noted: [], dismissed: [] }
const entry = (m, rationale, agreed = false) => ({ key: m.key, title: m.title, file: m.file, line: m.line, severity: m.severity, raisedBy: m.raisedBy, agreed, reports: m.reports, rationale })

// Reports sharing a file:line are grouped, but a refuted or verdict-less report is dismissed on its
// own and never counts as a raiser, so it cannot lend agreement to, or retitle, a confirmed one.
// Every confirmed report keeps its own title and severity.
const groups = new Map()
for (const { dim, finding: f } of raw) {
  const key = `${f.file}:${f.line}`
  const report = { dim, title: f.title, severity: f.severity }
  if (!f.verdict || f.verdict.refuted) {
    const reason = f.verdict?.reason
    buckets.dismissed.push(entry({ key, title: f.title, file: f.file, line: f.line, severity: f.severity, raisedBy: [dim], reports: [report] },
      reason ? `refuted: ${reason}` : 'refuted: verifier returned no verdict'))
    continue
  }
  const m = groups.get(key) ?? { key, file: f.file, line: f.line, severity: f.severity, raisedBy: [], reports: [] }
  m.reports.push({ ...report, reason: f.verdict.reason })
  if (!m.raisedBy.includes(dim)) m.raisedBy.push(dim)
  if (SEVERITY_RANK[f.severity] < SEVERITY_RANK[m.severity]) m.severity = f.severity
  groups.set(key, m)
}
const toJudge = [...groups.values()]
for (const m of toJudge) m.title = [...new Set(m.reports.map(r => r.title))].join(' / ')

if (toJudge.length) {
  const list = toJudge.map(m => [
    `- ${m.key} [${m.severity}], raised by ${m.raisedBy.join(', ')}:`,
    ...m.reports.map(r => `    - ${r.dim} [${r.severity}]: ${r.title} (verifier: ${r.reason ?? 'could not refute'})`),
  ].join('\n')).join('\n')
  const judged = await agent(
    [
      'You are the lead reviewer, a pragmatic senior engineer, not a neutral aggregator. Each finding below survived an independent refutation attempt. Put every one in exactly one bucket and give a one-line rationale; echo each key exactly.',
      '- act: a real issue for correctness, security or maintainability given the actual goal; it would block a real PR.',
      '- consider: legitimate, but unclear it outweighs the cost of fixing it now; worth the author\'s attention.',
      '- noted: technically valid, not actionable now (context-dependent, premature, low impact).',
      '- dismissed: wrong, a nitpick, or missing context; say which.',
      'Filters: reviewers inflate nits to fill the space, so a pile of nits means the code is probably fine. A hypothetical is a finding only if a caller can reach it, so trace the call site. Suggesting an abstraction is premature unless the code must change a second way. "I would do it differently" is not a defect without a concrete problem. A finding about code the author did not touch, or about a pattern the rest of the codebase shares, is missing context.',
      'Keep findings that name a concrete execution path, that two reviewers raised independently (the strongest signal), or that expose a gap in your own model of the code. Be slow to dismiss security and correctness findings even from one reviewer.',
      'Reports listed under one key share a file and line but may describe different defects. Set sameDefect on every key: true only when all reports under it describe one defect (a key with one report is true), false when they describe different defects. Two reviewers agree only on a sameDefect of true.',
      `Read the code at each location before judging.\n${list}`,
    ].join('\n'),
    { label: 'judge', phase: 'Judge', model: 'opus', effort: 'high', schema: JUDGMENTS })
  const byKey = new Map((judged?.judgments ?? []).map(j => [j.key, j]))
  for (const m of toJudge) {
    const j = byKey.get(m.key)
    const agreed = m.raisedBy.length >= 2 && j?.sameDefect === true
    let bucket = j?.bucket ?? 'consider'
    let rationale = j?.rationale ?? 'not judged; defaulted to consider'
    // A finding no second reviewer agreed on never reaches act, whatever its severity.
    if (bucket === 'act' && !agreed) {
      bucket = 'consider'
      rationale = `${rationale} (no second reviewer agreed: capped at consider)`
    }
    buckets[bucket].push(entry(m, rationale, agreed))
  }
}

for (const list of Object.values(buckets))
  list.sort((a, b) => Number(b.agreed) - Number(a.agreed) || SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity])

// Listed in bucket order, act first, agreed findings ahead of the rest.
const agreement = {}
const bucketOrder = ['act', 'consider', 'noted']
for (const name of bucketOrder)
  for (const e of buckets[name])
    if (e.agreed) agreement[e.key] = { title: e.title, raisedBy: e.raisedBy }

return { confirmed, buckets, agreement }
