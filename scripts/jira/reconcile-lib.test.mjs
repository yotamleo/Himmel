import { describe, it, expect } from 'vitest';
import {
  ticketKeyPattern,
  hasBracketedTag,
  isRevertSubject,
  isPartialDelivery,
  hasSkipMarker,
  hasHygieneSweepDisposition,
  hasOutcomeAcceptance,
  hasNumberedTaskList,
  findMatches,
  classifyTicket,
  applyDisposition,
  buildEvidenceComment,
  TOOL_EVIDENCE_MARKER,
} from './reconcile-lib.mjs';

// Real HIMMEL-2975 description (fetched 2026-09-17): the ticket the 40 %
// false-positive audit named as the known-positive case for HIMMEL-3128 —
// task T27 of its scope (PR #754) shipped, and subject-match alone would
// CLOSE it while T25/T26/T28 and the remaining design work are still open.
// The description's "Proposal" section is a genuine 2-item numbered list
// ("1. Relay ... 2. Judge ..."), which is the real signal this fixture
// exercises (not a `T\d+`-style marker — the description doesn't use those).
const HIMMEL_2975_DESCRIPTION = `Why (operator hypothesis 2026-09-12 20:4x, quantified by the cost audit)
Over seven days the Fable console accounted for ~24 % of Claude spend (52 session files, 9,568 turns, 2.68B cache-read tokens).
Proposal
Split the console into two roles:
1. Relay — a Sonnet (or Haiku) session under a new console-relay profile in scripts/lanes/plugin-profiles.json. It owns the monitors, the leg-doc polling, inbox-send.sh delivery, tick.sh, the pushes on BLOCKED lane:, RUN-note insertion and relaunches. It never rules.
2. Judge — a Fable session (or an on-demand Fable Agent spawned by the relay) under a console-judge profile invoked only for: verifying a leg FINDING before concurrence, CR dispositions, READY verification + GO, operator rulings. The judge owns the queue lock and issues GO (single-writer invariant); the relay holds no lock.
Acceptance
- One full shift run relay+judge; Fable turns per shift ≤ 40 % of the baseline; no missed READY→GO; no lock held by the relay.`;

// Real HIMMEL-2977 description (fetched 2026-09-17): the second known-positive
// case — the P0 instrumentation commit (#689) is one precondition step of a
// 4-item numbered Scope list, not the ticket's actual deliverable (the
// scorecard re-baseline).
const HIMMEL_2977_DESCRIPTION = `Why (operator 2026-09-12 20:3x)
"We must reduce costs, but we must also have a design on measuring quality so we don't drop quality."
Scope — one design leg, minerva-driven, escalation-only
1. Baseline, before any change. Using only existing meters: scripts/lanes/leg-burn.sh over the last 7 days of transcripts by role and model.
2. minerva grill → spec → plan (himmel-ops:minerva, autonomous mode): the leg answers every frontier question itself.
3. Quality scorecard as part of the spec: metric set, data source and command per metric, baseline value, per-lever acceptance rule.
4. Deliverables in the state repo: specs/cost-program/{baseline-…, spec-…, plan-…}.md, each critic-hardened.
Acceptance
- Baseline file exists with every metric sourced; the bench run's manifest is referenced.`;

// Real HIMMEL-2875 description (fetched 2026-09-16): closed on a merged
// commit that delivered only the leg-owned prep (content audit + Pages
// config); the ticket's acceptance criterion is the live URL, and enabling
// Pages is an operator-only repo setting the description reserves
// explicitly. Reopened after `curl -sI` on the URL came back 404. The
// known-positive fixture for the outcome-acceptance rule.
const HIMMEL_2875_DESCRIPTION = `Operator 2026-09-09 (console 03F): "we can publish the user-facing adoption trail."
What exists
- docs/adoption-trail.html — the user-facing adoption trail page, already in the tree of the (now public) yotamleo/Himmel repo, so its SOURCE is public since the HIMMEL-2705 cutover.
- The same page is published as a private claude.ai artifact ("Himmel Adoption Trail", b13de5c0-...), owned by the operator.
Ask — give it a public URL
Preferred: GitHub Pages from the public repo, source = main / docs/ (or a gh-pages deploy workflow if docs/ must stay a plain folder). Then https://yotamleo.github.io/Himmel/adoption-trail.html is the URL, and every merge to main updates it — no second copy to keep in sync. Enabling Pages is a repo setting = operator action (gh api -X POST repos/yotamleo/Himmel/pages -f build_type=legacy -f source[branch]=main -f source[path]=/docs, or the Settings -> Pages UI); the leg prepares and verifies, the operator flips it.
Verification
curl -sI https://yotamleo.github.io/Himmel/adoption-trail.html -> 200 after the operator enables Pages; the page renders in light/dark; no private-era string survives (git grep the audit list against docs/).`;

function commit(subject, { body = '', sha = 'deadbee', date = '2026-09-01' } = {}) {
  return { sha, date, subject, body };
}

describe('ticketKeyPattern / word-boundary matching', () => {
  it('matches a bare mention with word boundaries', () => {
    expect(ticketKeyPattern('HIMMEL-374').test('fix: HIMMEL-374 thing')).toBe(true);
  });
  it('does not match a longer key sharing a numeric prefix', () => {
    expect(ticketKeyPattern('HIMMEL-374').test('fix: HIMMEL-3745 thing')).toBe(false);
  });
  it('matches inside brackets', () => {
    expect(ticketKeyPattern('HIMMEL-374').test('fix: [HIMMEL-374] thing')).toBe(true);
  });
});

describe('hasBracketedTag', () => {
  it('is true for [KEY] form', () => {
    expect(hasBracketedTag('fix: [HIMMEL-374] thing', 'HIMMEL-374')).toBe(true);
  });
  it('is false for a bare mention with no brackets', () => {
    expect(hasBracketedTag('fix: port HIMMEL-1833 lane figures', 'HIMMEL-1833')).toBe(false);
  });
});

describe('isRevertSubject', () => {
  it('flags a revert: prefix', () => {
    expect(isRevertSubject('revert: [HIMMEL-2148] drop codex plugin fork-pin')).toBe(true);
  });
  it('does not flag a normal fix', () => {
    expect(isRevertSubject('fix: [HIMMEL-374] thing')).toBe(false);
  });
});

describe('isPartialDelivery', () => {
  it.each([
    'fix(upstreams): [HIMMEL-2426] bucket the watch report (PR 1 of 2 — core)',
    'fix(uninstall): [HIMMEL-2854] [5/8] skips repo-hook teardown',
    'docs(externalization): [HIMMEL-2176] Stage-1 PR-D — docs sync',
    'feat(install): [HIMMEL-2326] manifest coverage (manifest half)',
  ])('flags partial-delivery marker in %s', (subject) => {
    expect(isPartialDelivery(subject)).toBe(true);
  });

  it('does not flag a plain complete-looking subject', () => {
    expect(isPartialDelivery('fix: [HIMMEL-374] ship the reconciler')).toBe(false);
  });
});

describe('hasSkipMarker', () => {
  it('detects the hygiene sweep marker', () => {
    expect(hasSkipMarker(['Closed by backlog-hygiene sweep 2026-09-16 — evidence: ...'])).toBe(true);
  });
  it('detects this tool\'s own marker', () => {
    expect(hasSkipMarker([`${TOOL_EVIDENCE_MARKER}\n\nDisposition: CLOSE`])).toBe(true);
  });
  it('is false with unrelated comments', () => {
    expect(hasSkipMarker(['just a normal comment'])).toBe(false);
  });
});

describe('hasHygieneSweepDisposition — the already-adjudicated-without-a-comment gap', () => {
  const hygieneKeys = new Set(['HIMMEL-559', 'HIMMEL-1730', 'HIMMEL-1833', 'HIMMEL-1887', 'HIMMEL-2009', 'HIMMEL-2581']);

  it('is true for a LEFT ALONE / evidence-mismatch key with no Jira comment at all', () => {
    expect(hasHygieneSweepDisposition('HIMMEL-559', hygieneKeys)).toBe(true);
  });
  it('is false for a key the hygiene sweep never touched', () => {
    expect(hasHygieneSweepDisposition('HIMMEL-9999', hygieneKeys)).toBe(false);
  });
  it('is false with no hygiene key set supplied', () => {
    expect(hasHygieneSweepDisposition('HIMMEL-559', undefined)).toBe(false);
  });
});

describe('hasOutcomeAcceptance — a commit proves leg scope, not ticket acceptance', () => {
  it('is true for HIMMEL-2875\'s real description (known-positive: operator-gated Pages URL)', () => {
    expect(hasOutcomeAcceptance(HIMMEL_2875_DESCRIPTION)).toBe(true);
  });

  it('is false for a description that only mentions a URL in passing (known-negative)', () => {
    const description = `See https://github.io/example for background on the format we're adopting.
This ticket is just about renaming the internal config field to match it.`;
    expect(hasOutcomeAcceptance(description)).toBe(false);
  });
});

describe('hasNumberedTaskList — HIMMEL-3128: a multi-task description is not one-commit-done', () => {
  it('is true for the real HIMMEL-2975 description (2-item numbered Proposal)', () => {
    expect(hasNumberedTaskList(HIMMEL_2975_DESCRIPTION)).toBe(true);
  });

  it('is true for the real HIMMEL-2977 description (4-item numbered Scope)', () => {
    expect(hasNumberedTaskList(HIMMEL_2977_DESCRIPTION)).toBe(true);
  });

  it('is true for explicit task-id markers (T25, T26)', () => {
    expect(hasNumberedTaskList('T27 shipped. T25/T26/T28 are still open.')).toBe(true);
  });

  it('is false for a single numbered item (not a decomposition)', () => {
    expect(hasNumberedTaskList('Steps:\n1. Run the migration.\nThat is the whole ticket.')).toBe(false);
  });

  it('is false for a single task-id marker mentioned once', () => {
    expect(hasNumberedTaskList('This lands T27 of the console split.')).toBe(false);
  });

  it('is false when T1 and Task 1 both name the same single task (CodeRabbit #790)', () => {
    expect(hasNumberedTaskList('This lands T1, also known as Task 1, of the console split.')).toBe(false);
  });

  it('is false for plain prose with no list or task markers', () => {
    expect(hasNumberedTaskList('Just fix the bug described above, no external dependency.')).toBe(false);
  });

  it('is false for an empty/undefined description', () => {
    expect(hasNumberedTaskList(undefined)).toBe(false);
  });
});

describe('classifyTicket — outcome-acceptance downgrades CLOSE to RESCOPE, never blocks RESCOPE/LEAVE', () => {
  const base = {
    key: 'HIMMEL-2875',
    issueType: 'Task',
    status: 'In Review',
    targetStatus: 'Done',
    commentBodies: [],
    hygieneKeys: new Set(),
  };

  it('rescopes a clean subject-match when the description gates acceptance on an external outcome', () => {
    const result = classifyTicket({
      ...base,
      subjectCommits: [commit('docs: [HIMMEL-2875] adoption trail — private-era content audit, Pages config and public URL links', { sha: 'e600' })],
      bodyOnlyCommits: [],
      description: HIMMEL_2875_DESCRIPTION,
    });
    expect(result.disposition).toBe('RESCOPE');
    expect(result.reason).toBe('outcome-acceptance');
  });

  it('still closes a clean subject-match when the description does not gate on an external outcome', () => {
    const result = classifyTicket({
      ...base,
      subjectCommits: [commit('fix: [HIMMEL-2875] ship the thing', { sha: 'e601' })],
      bodyOnlyCommits: [],
      description: 'Just fix the bug described above, no external dependency.',
    });
    expect(result.disposition).toBe('CLOSE');
  });

  it('does not override a revert (LEAVE) even with an outcome-acceptance description', () => {
    const result = classifyTicket({
      ...base,
      subjectCommits: [commit('revert: [HIMMEL-2875] drop the thing')],
      bodyOnlyCommits: [],
      description: HIMMEL_2875_DESCRIPTION,
    });
    expect(result.disposition).toBe('LEAVE');
    expect(result.reason).toBe('revert');
  });
});

describe('buildEvidenceComment — outcome-acceptance names the unverified external outcome', () => {
  it('includes the detail line for outcome-acceptance', () => {
    const text = buildEvidenceComment({
      key: 'HIMMEL-2875',
      disposition: 'RESCOPE',
      reason: 'outcome-acceptance',
      evidence: commit('docs: [HIMMEL-2875] adoption trail prep'),
      detail: 'curl -sI https://yotamleo.github.io/Himmel/adoption-trail.html -> 200 after the operator enables Pages',
    });
    expect(text).toContain('Unverified external outcome');
    expect(text).toContain('yotamleo.github.io');
  });
});

describe('findMatches', () => {
  it('separates subject matches from body-only matches, newest first preserved', () => {
    const commits = [
      commit('fix: [HIMMEL-374] ship the reconciler', { sha: 'aaa', date: '2026-09-16' }),
      commit('chore: unrelated', { body: 'touches HIMMEL-374 in passing', sha: 'bbb', date: '2026-09-10' }),
    ];
    const { subjectCommits, bodyOnlyCommits } = findMatches(commits, 'HIMMEL-374');
    expect(subjectCommits.map((c) => c.sha)).toEqual(['aaa']);
    expect(bodyOnlyCommits.map((c) => c.sha)).toEqual(['bbb']);
  });

  it('demotes a cross-reference (bare mention inside a commit bracketed for a different ticket) to body-only', () => {
    const commits = [
      commit('fix: [HIMMEL-1887] roll the CLIProxyAPI pin + port the unmerged HIMMEL-1833 lane figures', {
        sha: 'ccc',
        date: '2026-08-17',
      }),
    ];
    const { subjectCommits, bodyOnlyCommits } = findMatches(commits, 'HIMMEL-1833');
    expect(subjectCommits).toEqual([]);
    expect(bodyOnlyCommits.map((c) => c.sha)).toEqual(['ccc']);
  });

  it('keeps a bracketed-tag match as a full subject match', () => {
    const commits = [commit('fix: [HIMMEL-1887] roll the CLIProxyAPI pin', { sha: 'ddd' })];
    const { subjectCommits } = findMatches(commits, 'HIMMEL-1887');
    expect(subjectCommits.map((c) => c.sha)).toEqual(['ddd']);
  });
});

describe('classifyTicket', () => {
  const base = {
    key: 'HIMMEL-9001',
    issueType: 'Task',
    status: 'Open',
    targetStatus: 'Done',
    commentBodies: [],
    hygieneKeys: new Set(),
    subjectCommits: [],
    bodyOnlyCommits: [],
  };

  it('leaves Epics alone', () => {
    expect(classifyTicket({ ...base, issueType: 'Epic', subjectCommits: [commit('fix: [HIMMEL-9001] x')] }))
      .toMatchObject({ disposition: 'LEAVE', reason: 'epic-or-story' });
  });

  it('leaves Stories alone', () => {
    expect(classifyTicket({ ...base, issueType: 'Story', subjectCommits: [commit('fix: [HIMMEL-9001] x')] }))
      .toMatchObject({ disposition: 'LEAVE', reason: 'epic-or-story' });
  });

  it('is idempotent: already commented by this tool -> no-op', () => {
    expect(
      classifyTicket({
        ...base,
        commentBodies: [TOOL_EVIDENCE_MARKER],
        subjectCommits: [commit('fix: [HIMMEL-9001] x')],
      }),
    ).toMatchObject({ disposition: 'LEAVE', reason: 'already-dispositioned' });
  });

  it('is idempotent: already at target status -> no-op', () => {
    expect(
      classifyTicket({ ...base, status: 'Done', subjectCommits: [commit('fix: [HIMMEL-9001] x')] }),
    ).toMatchObject({ disposition: 'LEAVE', reason: 'already-at-target' });
  });

  it('is idempotent: hygiene-sweep dispositioned with no comment -> no-op (the fixed gap)', () => {
    expect(
      classifyTicket({
        ...base,
        hygieneKeys: new Set(['HIMMEL-9001']),
        subjectCommits: [commit('fix: [HIMMEL-9001] x')],
      }),
    ).toMatchObject({ disposition: 'LEAVE', reason: 'already-dispositioned-by-hygiene-sweep' });
  });

  it('leaves a ticket with no project target status configured, not a failure', () => {
    expect(
      classifyTicket({ ...base, targetStatus: undefined, subjectCommits: [commit('fix: [HIMMEL-9001] x')] }),
    ).toMatchObject({ disposition: 'LEAVE', reason: 'no-project-config' });
  });

  it('leaves a ticket with only a body-only match', () => {
    expect(
      classifyTicket({ ...base, bodyOnlyCommits: [commit('unrelated', { body: 'HIMMEL-9001 mentioned' })] }),
    ).toMatchObject({ disposition: 'LEAVE', reason: 'body-only-match' });
  });

  it('leaves a ticket with no evidence at all', () => {
    expect(classifyTicket({ ...base })).toMatchObject({ disposition: 'LEAVE', reason: 'no-evidence' });
  });

  it('leaves (never closes) when the top subject match is a revert', () => {
    expect(
      classifyTicket({ ...base, subjectCommits: [commit('revert: [HIMMEL-9001] drop the thing')] }),
    ).toMatchObject({ disposition: 'LEAVE', reason: 'revert' });
  });

  it('rescopes (never closes) on a partial-delivery marker', () => {
    expect(
      classifyTicket({ ...base, subjectCommits: [commit('fix: [HIMMEL-9001] thing (PR 1 of 2 — core)')] }),
    ).toMatchObject({ disposition: 'RESCOPE', reason: 'partial-delivery' });
  });

  it('closes on a clean subject match', () => {
    const result = classifyTicket({ ...base, subjectCommits: [commit('fix: [HIMMEL-9001] ship the thing', { sha: 'zzz' })] });
    expect(result.disposition).toBe('CLOSE');
    expect(result.reason).toBe('subject-match');
    expect(result.evidence.sha).toBe('zzz');
  });

  it('most-recent subject commit decides when several match', () => {
    const result = classifyTicket({
      ...base,
      subjectCommits: [
        commit('revert: [HIMMEL-9001] drop the thing', { sha: 'newest', date: '2026-09-15' }),
        commit('fix: [HIMMEL-9001] ship the thing', { sha: 'older', date: '2026-09-01' }),
      ],
    });
    expect(result).toMatchObject({ disposition: 'LEAVE', reason: 'revert' });
    expect(result.evidence.sha).toBe('newest');
  });
});

describe('classifyTicket — HIMMEL-3128: multi-task tickets never CLOSE on their first landed task', () => {
  const base = {
    issueType: 'Task',
    status: 'To Do',
    targetStatus: 'Done',
    commentBodies: [],
    hygieneKeys: new Set(),
    bodyOnlyCommits: [],
  };

  // The RED control this ticket's DONE WHEN names: the PRE-FIX rule (no
  // hasNumberedTaskList check) closed HIMMEL-2975 on this exact subject —
  // see the manual demonstration pasted into the PR body/handover, which
  // instantiates the pre-fix reconcile-lib.mjs against this same fixture.
  // This test is the fixed rule's GREEN: it must not CLOSE here.
  it('downgrades HIMMEL-2975 to RESCOPE on #754s subject, never CLOSE (the known-positive false-close)', () => {
    const result = classifyTicket({
      ...base,
      key: 'HIMMEL-2975',
      subjectCommits: [
        commit('feat(handover): [HIMMEL-2975] console --role judge; relay brief template (#754)', {
          sha: 'd3c69448',
          date: '2026-09-17',
        }),
      ],
      description: HIMMEL_2975_DESCRIPTION,
    });
    expect(result.disposition).toBe('RESCOPE');
    expect(result.reason).toBe('multi-task-ticket');
    expect(result.disposition).not.toBe('CLOSE');
  });

  it('downgrades HIMMEL-2977 to RESCOPE on #689s subject (the P0-instrumentation precondition, not the deliverable)', () => {
    const result = classifyTicket({
      ...base,
      key: 'HIMMEL-2977',
      subjectCommits: [
        commit('feat(bench): [HIMMEL-2977] P0 instrumentation — scorecard recipe, leg-burn line, Tier-return counter', {
          sha: '5202b4c1',
          date: '2026-09-17',
        }),
      ],
      description: HIMMEL_2977_DESCRIPTION,
    });
    expect(result.disposition).toBe('RESCOPE');
    expect(result.reason).toBe('multi-task-ticket');
  });

  it('multiple commits carrying one key: the newest still decides, and a multi-task description still blocks CLOSE', () => {
    const result = classifyTicket({
      ...base,
      key: 'HIMMEL-2975',
      subjectCommits: [
        commit('feat(handover): [HIMMEL-2975] console --role judge; relay brief template (#754)', {
          sha: 'newest',
          date: '2026-09-17',
        }),
        commit('feat(handover): [HIMMEL-2975] relay profile scaffolding (#730)', {
          sha: 'older',
          date: '2026-09-14',
        }),
      ],
      description: HIMMEL_2975_DESCRIPTION,
    });
    expect(result.disposition).toBe('RESCOPE');
    expect(result.reason).toBe('multi-task-ticket');
    expect(result.evidence.sha).toBe('newest');
  });

  // Anti-vacuity, mandatory (this ticket's DONE WHEN): a genuine single-PR
  // ticket — plain prose, no numbered list or task markers — must still
  // classify CLOSE. A fix that stops closing everything is not a fix.
  it('still CLOSEs a genuine single-PR ticket with plain-prose description (anti-vacuity)', () => {
    const result = classifyTicket({
      ...base,
      key: 'HIMMEL-9002',
      subjectCommits: [commit('fix: [HIMMEL-9002] ship the thing', { sha: 'single-pr' })],
      description: 'Just fix the bug described above, no external dependency and no sub-tasks.',
    });
    expect(result.disposition).toBe('CLOSE');
    expect(result.reason).toBe('subject-match');
  });

  it('evidence comment names the multi-task rule and the deciding commit', () => {
    const result = classifyTicket({
      ...base,
      key: 'HIMMEL-2975',
      subjectCommits: [commit('feat(handover): [HIMMEL-2975] console --role judge (#754)', { sha: 'd3c69448' })],
      description: HIMMEL_2975_DESCRIPTION,
    });
    const text = buildEvidenceComment({ key: 'HIMMEL-2975', ...result });
    expect(text).toContain('multi-task-ticket');
    expect(text).toContain('d3c69448');
    expect(text).toContain('Multi-task ticket');
    expect(text).toContain('numbered items');
  });
});

describe('applyDisposition', () => {
  function makeClient() {
    const calls = [];
    return {
      calls,
      client: {
        async comment(key, body) {
          calls.push(['comment', key, body]);
        },
        async transition(key, status) {
          calls.push(['transition', key, status]);
        },
      },
    };
  }

  it('does nothing for LEAVE', async () => {
    const { calls, client } = makeClient();
    const result = await applyDisposition({ key: 'HIMMEL-1', disposition: 'LEAVE', jiraClient: client });
    expect(result).toEqual({ action: 'none' });
    expect(calls).toEqual([]);
  });

  it('comments then transitions for CLOSE, in that order', async () => {
    const { calls, client } = makeClient();
    const result = await applyDisposition({
      key: 'HIMMEL-1',
      disposition: 'CLOSE',
      targetStatus: 'Done',
      commentBody: 'evidence',
      jiraClient: client,
    });
    expect(result).toEqual({ action: 'commented+transitioned' });
    expect(calls).toEqual([
      ['comment', 'HIMMEL-1', 'evidence'],
      ['transition', 'HIMMEL-1', 'Done'],
    ]);
  });

  it('comments only for RESCOPE, never transitions', async () => {
    const { calls, client } = makeClient();
    const result = await applyDisposition({
      key: 'HIMMEL-1',
      disposition: 'RESCOPE',
      commentBody: 'evidence',
      jiraClient: client,
    });
    expect(result).toEqual({ action: 'commented' });
    expect(calls).toEqual([['comment', 'HIMMEL-1', 'evidence']]);
  });
});

describe('buildEvidenceComment', () => {
  it('includes the tool marker, disposition, reason and evidence commit', () => {
    const text = buildEvidenceComment({
      key: 'HIMMEL-1',
      disposition: 'CLOSE',
      reason: 'subject-match',
      evidence: commit('fix: [HIMMEL-1] thing', { sha: 'abc1234', date: '2026-09-16' }),
    });
    expect(text).toContain(TOOL_EVIDENCE_MARKER);
    expect(text).toContain('CLOSE');
    expect(text).toContain('subject-match');
    expect(text).toContain('abc1234');
  });

  it('omits an evidence line when there is none', () => {
    const text = buildEvidenceComment({ key: 'HIMMEL-1', disposition: 'LEAVE', reason: 'no-evidence', evidence: null });
    expect(text).not.toContain('Evidence:');
  });
});
