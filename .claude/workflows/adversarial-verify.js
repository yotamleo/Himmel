export const meta = {
  name: 'adversarial-verify',
  description: 'Review a diff across dimensions, adversarially verify each finding',
  whenToUse: 'CR-shaped fan-out: findings must survive independent refutation',
  phases: [{ title: 'Review' }, { title: 'Verify' }],
}
const FINDINGS = {
  type: 'object', required: ['findings'],
  properties: { findings: { type: 'array', items: { type: 'object',
    required: ['title', 'file', 'line', 'severity'],
    properties: { title: {type:'string'}, file: {type:'string'},
      line: {type:'number'}, severity: {enum:['critical','important','minor']} } } } }
}
const VERDICT = { type: 'object', required: ['refuted'],
  properties: { refuted: {type:'boolean'}, reason: {type:'string'} } }
const DIMENSIONS = [
  { key: 'correctness', prompt: 'Review the current branch diff vs main for correctness bugs. Return findings.' },
  { key: 'silent-failure', prompt: 'Review the current branch diff vs main for swallowed errors and silent wrong-state paths. Return findings.' },
]
const results = await pipeline(
  DIMENSIONS,
  d => agent(d.prompt, { label: `review:${d.key}`, phase: 'Review', schema: FINDINGS }),
  review => parallel((review?.findings ?? []).map(f => () =>
    agent(`Try to refute this finding with cited evidence from the file at ${f.file}:${f.line}: ${f.title}. Default to refuted=true if uncertain.`,
      { label: `verify:${f.file}`, phase: 'Verify', schema: VERDICT })
      .then(v => ({ ...f, verdict: v }))))
)
const confirmed = results.flat().filter(Boolean).filter(f => f.verdict && !f.verdict.refuted)
return { confirmed }
