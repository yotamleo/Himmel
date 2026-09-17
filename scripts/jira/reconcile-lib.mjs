// scripts/jira/reconcile-lib.mjs — HIMMEL-374/378 pure-code backlog reconciler.
//
// Pure classification + evidence matching. No network, no subprocess, no
// filesystem here — reconcile-backlog.mjs owns all I/O (git log, the jira CLI)
// and hands parsed data structures into these functions. That split is what
// makes the evidence rule unit-testable against fixtures instead of the live
// backlog.

const HYGIENE_SWEEP_MARKERS = [
  'Closed by backlog-hygiene sweep 2026-09-16',
  'Backlog-hygiene sweep 2026-09-16',
];
export const TOOL_EVIDENCE_MARKER = 'Auto-reconciled by scripts/jira/reconcile-backlog.mjs';

const NEVER_TOUCH_TYPES = new Set(['Epic', 'Story']);

// A partial-delivery signal in a commit subject/PR title: "PR 1 of 2",
// "[5/8]", "phase 1", "stage-1"/"stage 1", "manifest half", or a trailing
// "... core)" qualifier. Any of these means the matched commit is ONE SLICE
// of the ticket's full scope, not the whole thing — RESCOPE, never CLOSE.
const PARTIAL_DELIVERY_RE =
  /\bPR\s+\d+\s+of\s+\d+\b|\[\d+\/\d+\]|\bphase\s+\d+\b|\bstage[- ]?1\b|\bmanifest half\b|\bcore\)/i;

const REVERT_RE = /^revert(:|\b|\s*")/i;

// A merged commit proves the LEG's slice of work landed. It does not prove
// the TICKET is done when the ticket's own acceptance criterion is an
// outcome outside the repository — a flipped repo setting, a served URL,
// a published package/release, a DNS/dashboard change, an enabled
// third-party integration. HIMMEL-2875 is the known-positive case: the
// merged commit delivered a content audit + Pages config prep, but the
// ticket's acceptance was the live URL (`curl -sI ... -> 200`), and
// enabling Pages is an operator-only repo setting the description reserves
// explicitly ("the leg prepares and verifies, the operator flips it"). It
// was closed, then reopened when the URL 404'd. This check runs against the
// ticket's own DESCRIPTION text (never the commit) and can only ever
// downgrade a would-be CLOSE to RESCOPE — never used to justify closing.
// Deliberately excludes a bare `github.io` (or any URL) mention: a ticket
// that just links to something in passing must still be CLOSE-eligible.
// Every alternative here names a verification/operator-gating ACTION, not
// merely a URL.
const OUTCOME_ACCEPTANCE_RE =
  /curl\s+-\w*[iI]\b|gh api repos\/\S+\/pages|Settings\s*(?:→|->)\s*Pages|operator (?:flips|enables)|\brepo setting\b|publish the release/i;
const LEG_OPERATOR_SPLIT_RE = /\bthe leg (?:prepares|scopes|verifies)\b[^.]*\bthe operator\b|\boperator-only\b/i;

export function hasOutcomeAcceptance(descriptionText) {
  const text = descriptionText ?? '';
  return OUTCOME_ACCEPTANCE_RE.test(text) || LEG_OPERATOR_SPLIT_RE.test(text);
}

// The matched snippet (trimmed to one line of context), for naming the
// specific unverified external outcome in the evidence comment rather than
// just citing the rule's name.
export function describeOutcome(descriptionText) {
  const text = descriptionText ?? '';
  const m = OUTCOME_ACCEPTANCE_RE.exec(text) ?? LEG_OPERATOR_SPLIT_RE.exec(text);
  if (!m) return null;
  const lineStart = text.lastIndexOf('\n', m.index) + 1;
  const lineEnd = text.indexOf('\n', m.index);
  return text.slice(lineStart, lineEnd === -1 ? text.length : lineEnd).trim();
}

// HIMMEL-3128: a bare `[KEY]` on a commit subject only proves ONE commit
// landed for this ticket, not that the ticket's own scope is finished — and
// himmel's commit convention puts the ticket key in every commit subject, so
// subject-match alone has near-zero evidential value for a ticket that ships
// across several PRs (HIMMEL-2975's "1. Relay / 2. Judge" Proposal section,
// HIMMEL-2977's "Scope ... 1. Baseline / 2. minerva grill / 3. Quality
// scorecard / 4. Deliverables"). A description declaring ≥2 numbered items,
// or ≥2 distinct task-id markers (`T25`, `Task 9`), is multi-task by
// construction; a SINGLE numbered item (most descriptions have one somewhere)
// is not a decomposition and must not trigger this, or nearly every CLOSE
// candidate downgrades and the rule becomes vacuous.
const NUMBERED_LIST_ITEM_RE = /^\s*\d+[.)]\s+\S/gm;
const TASK_ID_MARKER_RE = /\bT\d{1,3}\b|\bTask\s+\d+\b/gi;

// `T1` and `Task 1` name the same task under two spellings — normalize to
// the numeric id so they count as one marker, not two, or a ticket that
// mentions one task both ways falsely looks like it declares two.
function taskMarkerIds(text) {
  return new Set((text.match(TASK_ID_MARKER_RE) ?? []).map((s) => s.match(/\d+/)[0]));
}

export function hasNumberedTaskList(descriptionText) {
  const text = descriptionText ?? '';
  const listItems = text.match(NUMBERED_LIST_ITEM_RE) ?? [];
  if (listItems.length >= 2) return true;
  return taskMarkerIds(text).size >= 2;
}

// The specifics for the evidence comment: how many numbered items, or which
// task-id markers, decided it — so a wrong disposition is auditable.
export function describeNumberedTaskList(descriptionText) {
  const text = descriptionText ?? '';
  const listItems = text.match(NUMBERED_LIST_ITEM_RE) ?? [];
  if (listItems.length >= 2) return `${listItems.length} numbered items in the ticket description`;
  const taskMarkers = [...taskMarkerIds(text)].map((id) => `T${id}`);
  return `task markers ${taskMarkers.join(', ')} in the ticket description`;
}

export function ticketKeyPattern(key) {
  const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`(^|[^0-9A-Za-z-])${escaped}([^0-9A-Za-z]|$)`);
}

// The bracketed-tag form `[KEY]` is the strong signal: a commit deliberately
// filed under that ticket. A bare word-boundary mention (no brackets) is
// weaker — often a cross-reference to related work filed under a DIFFERENT
// ticket's brackets (e.g. HIMMEL-1833 mentioned inside a commit tagged
// [HIMMEL-1887]). Callers use this to avoid promoting a cross-reference to
// a full subject match.
export function hasBracketedTag(subject, key) {
  const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`\\[${escaped}\\]`).test(subject);
}

export function isRevertSubject(subject) {
  return REVERT_RE.test(subject.trim());
}

export function isPartialDelivery(subject) {
  return PARTIAL_DELIVERY_RE.test(subject);
}

export function hasSkipMarker(commentBodies) {
  return commentBodies.some(
    (c) => HYGIENE_SWEEP_MARKERS.some((m) => c.includes(m)) || c.includes(TOOL_EVIDENCE_MARKER),
  );
}

/**
 * Second authoritative "already adjudicated" source, per the HIMMEL-374
 * resume doc's SCOPE-gap fix (2026-09-16): the concurrent hygiene sweep
 * dispositioned some tickets (its LEFT ALONE table, "evidence mismatch"
 * rows especially) WITHOUT ever posting a Jira comment. Those keys are just
 * as final as commented ones — checking hasSkipMarker() alone would let the
 * reconciler re-close a ticket a human already reviewed and correctly left
 * alone. `hygieneKeys` is every key named under ANY table (CLOSED, RESCOPED,
 * STALE-PREMISE, LEFT ALONE) of that report, parsed once by the caller.
 */
export function hasHygieneSweepDisposition(key, hygieneKeys) {
  return (hygieneKeys ?? new Set()).has(key);
}

/**
 * Split a commit corpus into subject-matches and body-only-matches for one
 * ticket key. `commits` must already be sorted newest-first — the caller
 * (reconcile-backlog.mjs) sorts the merged public+private corpus once, and
 * every downstream consumer relies on that order to mean "most recent decides".
 *
 * A subject match with no bracketed [KEY] tag AND where the subject carries
 * a *different* bracketed ticket tag is a cross-reference, not a delivery of
 * this ticket — demoted to bodyOnlyCommits (weaker evidence), matching the
 * HIMMEL-1833-inside-an-[HIMMEL-1887]-commit case.
 */
export function findMatches(commits, key) {
  const re = ticketKeyPattern(key);
  const otherBracketRe = /\[([A-Za-z]+-\d+)\]/;
  const subjectCommits = [];
  const bodyOnlyCommits = [];
  for (const c of commits) {
    if (re.test(c.subject)) {
      const bracketed = hasBracketedTag(c.subject, key);
      const otherMatch = c.subject.match(otherBracketRe);
      const isCrossReference = !bracketed && otherMatch && otherMatch[1] !== key;
      if (isCrossReference) {
        bodyOnlyCommits.push(c);
      } else {
        subjectCommits.push(c);
      }
      continue;
    }
    const full = `${c.subject}\n${c.body ?? ''}`;
    if (re.test(full)) bodyOnlyCommits.push(c);
  }
  return { subjectCommits, bodyOnlyCommits };
}

/**
 * The evidence rule. Every input is already resolved by the caller (no I/O):
 *   key             ticket key, e.g. "HIMMEL-374"
 *   issueType       "Epic" | "Story" | "Task" | "Bug" | ...
 *   status          current Jira status name
 *   targetStatus    configured target for this project, or undefined/null if unconfigured
 *   commentBodies   every comment body already on the ticket (plain text/markdown)
 *   hygieneKeys     Set of keys named anywhere in the 2026-09-16 hygiene-sweep report
 *   subjectCommits  commits matching findMatches().subjectCommits, newest-first
 *   bodyOnlyCommits commits matching findMatches().bodyOnlyCommits, newest-first
 *
 * Returns { disposition: 'CLOSE'|'RESCOPE'|'STALE-PREMISE'|'LEAVE', reason, evidence }.
 * `evidence` is the deciding commit ({sha,date,subject}) or null.
 *
 * STALE-PREMISE has no automated trigger in this rule (HIMMEL-374 SCOPE note,
 * BLOCKED section of the 2026-09-16 resume doc): inventing a heuristic for
 * "this ticket's premise no longer exists" would be guessing at semantics the
 * commit corpus cannot prove. The disposition exists in the type for schema
 * completeness; nothing below emits it.
 */
export function classifyTicket({
  key,
  issueType,
  status,
  targetStatus,
  commentBodies,
  hygieneKeys,
  subjectCommits,
  bodyOnlyCommits,
  description,
}) {
  if (NEVER_TOUCH_TYPES.has(issueType)) {
    return { disposition: 'LEAVE', reason: 'epic-or-story', evidence: null };
  }
  if (hasSkipMarker(commentBodies ?? [])) {
    return { disposition: 'LEAVE', reason: 'already-dispositioned', evidence: null };
  }
  if (hasHygieneSweepDisposition(key, hygieneKeys)) {
    return { disposition: 'LEAVE', reason: 'already-dispositioned-by-hygiene-sweep', evidence: null };
  }
  if (!targetStatus) {
    return { disposition: 'LEAVE', reason: 'no-project-config', evidence: null };
  }
  if (status === targetStatus) {
    return { disposition: 'LEAVE', reason: 'already-at-target', evidence: null };
  }
  if (!subjectCommits || subjectCommits.length === 0) {
    if (bodyOnlyCommits && bodyOnlyCommits.length > 0) {
      return { disposition: 'LEAVE', reason: 'body-only-match', evidence: bodyOnlyCommits[0] };
    }
    return { disposition: 'LEAVE', reason: 'no-evidence', evidence: null };
  }
  const top = subjectCommits[0];
  if (isRevertSubject(top.subject)) {
    return { disposition: 'LEAVE', reason: 'revert', evidence: top };
  }
  if (isPartialDelivery(top.subject)) {
    return { disposition: 'RESCOPE', reason: 'partial-delivery', evidence: top };
  }
  if (hasOutcomeAcceptance(description)) {
    return {
      disposition: 'RESCOPE',
      reason: 'outcome-acceptance',
      evidence: top,
      detail: describeOutcome(description),
    };
  }
  if (hasNumberedTaskList(description)) {
    return {
      disposition: 'RESCOPE',
      reason: 'multi-task-ticket',
      evidence: top,
      detail: describeNumberedTaskList(description),
    };
  }
  return { disposition: 'CLOSE', reason: 'subject-match', evidence: top };
}

/**
 * Comment-before-transition, enforced structurally: this is the only place
 * that sequences the two mutating calls, and it always comments first — so a
 * transition failure (a missing transition-screen field, HIMMEL-373's scope)
 * still leaves the evidence behind. `jiraClient` is injected ({comment,
 * transition} async functions) so this is testable without a subprocess.
 */
export async function applyDisposition({ key, disposition, targetStatus, commentBody, jiraClient }) {
  if (disposition === 'LEAVE') {
    return { action: 'none' };
  }
  await jiraClient.comment(key, commentBody);
  if (disposition === 'CLOSE') {
    await jiraClient.transition(key, targetStatus);
    return { action: 'commented+transitioned' };
  }
  // RESCOPE / STALE-PREMISE: comment only, never transition.
  return { action: 'commented' };
}

export function buildEvidenceComment({ key, disposition, reason, evidence, detail }) {
  const lines = [TOOL_EVIDENCE_MARKER, ''];
  lines.push(`Disposition: **${disposition}** (reason: ${reason})`);
  if (evidence) {
    lines.push('');
    lines.push(`Evidence: \`${evidence.sha ?? '<no-sha>'}\` — ${evidence.date ?? '?'} — "${evidence.subject}"`);
  }
  if (reason === 'outcome-acceptance' && detail) {
    lines.push('');
    lines.push(`Unverified external outcome (from the ticket's own description): ${detail}`);
    lines.push('A merged commit proves the leg\'s slice landed, not that this outcome occurred — left open pending that check.');
  }
  if (reason === 'multi-task-ticket' && detail) {
    lines.push('');
    lines.push(`Multi-task ticket (from the ticket's own description): ${detail}`);
    lines.push('A merged commit proves one task landed, not that every declared task did — confirm the remaining tasks before closing.');
  }
  return lines.join('\n');
}
