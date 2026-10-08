#!/usr/bin/env python3
"""HIMMEL-4926 friction measurement: every leg refusal by source, class and cost.

Reads (never writes) session transcripts of both lanes and the leg handover docs,
classifies each refusal into source x class x verdict, and aggregates per class:
count, distinct legs (sessions), median recovery minutes, console turns,
operator interrupts.  Output: JSON (machine) and Markdown (ranked table).

usage: friction.py [--days N] [--now ISO] [--projects DIR]... [--docs DIR]
                   [--json OUT] [--md OUT]
Transcript text is reduced to a normalised <=140 char snippet with token-shaped
strings masked; raw tool output is never written out.
"""
import argparse
import collections
import datetime as dt
import glob
import json
import os
import re
import statistics
import sys

HOME = os.path.expanduser('~')
DEFAULT_PROJECTS = [HOME + '/.claude/projects', HOME + '/.claude-codex/projects']
DEFAULT_DOCS = os.environ.get('HANDOVER_DIR', HOME + '/Documents/luna/handovers') + '/' + os.environ.get('USER_SLUG', 'yotamleo') + '/himmel'
RECOVERY_CAP_S = 1800

# (regex on reason text, class slug, verdict, evidence) per hook; first match wins.
HOOK_CLASSES = {
    'guard-pr-check-literal': [
        (r'does not resolve to this root', 'text-mentions-gate-path', 'over-deny',
         'fires on text that merely mentions a gate script (heredoc, message, glob in a regex)'),
        (r'not one simple command', 'pipe-or-chain-beside-gate', 'true-positive',
         'leg appended a pipe/redirect/chain to a gate script (preface forbids it)'),
        (r'differs from the HIMMEL_REPO anchor', 'worktree-copy-differs-from-anchor', 'over-deny',
         'a leg that edits a policy script cannot then run it relatively (HIMMEL-4916)'),
        (r'names a guarded script and can writ', 'redirect-beside-gate-script', 'true-positive',
         'output redirect beside a guarded script'),
        (r'--from-file path', 'from-file-path-outside-scratch', 'unclear', 'scratch path rule for --from-file'),
        (r'.', 'gate-literal-other', 'unclear', 'other guard-pr-check-literal denial'),
    ],
    'block-chokepoint-env-prefix': [
        (r'obfuscated', 'seam-var-beside-obfuscated-path', 'over-deny',
         'sort/grep/pipe beside a scripts/ path read as a seam write'),
        (r'.', 'env-prefix-chokepoint', 'true-positive', 'VAR= prefix on a chokepoint command'),
    ],
    'block-write-into-main-checkout': [
        (r'could not be resolved', 'unresolved-cd-target', 'over-deny',
         'cd into a $VAR or not-yet-created dir fails closed on every later write in the command'),
        (r'on main/master', 'write-shaped-command-on-main', 'unclear',
         'git merge/fetch against the primary; true for a leg, over-deny for the console'),
        (r'.', 'main-checkout-other', 'unclear', 'other main-checkout denial'),
    ],
    'run-hook-with-bash': [(r'budget=', 'hook-budget-timeout', 'over-deny',
                            'a must-run guard exceeded its budget under load and failed closed')],
    'read-clamp': [(r'.', 'duplicate-read', 'true-positive', 'token-saving re-read clamp')],
    'block-read-secrets': [(r'.', 'read-secrets', 'true-positive', 'secret-shaped path read')],
    'block-unresolved-cr-merge': [(r'single plain command', 'gh-merge-shape', 'true-positive',
                                   'merge must be one plain command')],
    'require-quiet-run': [(r'.', 'suite-not-wrapped', 'true-positive', 'suite run outside quiet-run')],
    'block-tail-pipe-on-gates': [(r'.', 'pipe-beside-gate', 'true-positive', 'pipe into/after a gate script')],
    'block-jira-compound-write': [(r'.', 'jira-compound-write', 'true-positive', 'compound Jira write')],
    'block-bank-lift-writes': [(r'.', 'bank-lift-write', 'true-positive', 'write to bank-lift state')],
    'block-destructive-commands': [(r'.', 'destructive-command', 'unclear', 'rm/reset style command')],
    'block-bare-qmd-query': [(r'.', 'bare-qmd-query', 'true-positive', 'qmd query without -c scope')],
    'block-edit-live-settings': [(r'.', 'edit-live-settings', 'unclear', 'live settings path in command or text')],
}

# ordered rules over the whole tool_result text: (regex, source, class, verdict, evidence)
TEXT_RULES = [
    (r'leg context checkpoint', 'hook:guard-leg-context-handoff', 'context-guard-lock', 'true-positive',
     'by design at the fill threshold; cost is the unlock ritual'),
    (r'Permission for this action was denied by the Claude Code auto mode classifier\. Reason: \[([^\]]+)\]',
     'classifier', None, 'unclear', 'auto-mode classifier verdict'),
    (r'This command requires approval', 'permission-prompt', 'approval-prompt', 'unclear',
     'command fell through to a permission prompt'),
    (r'ERR suite-semaphore: all \d+ suite slot', 'lane-rule', 'suite-slot-busy', 'true-positive',
     'fleet suite semaphore (HIMMEL-1818) is a deliberate cap; cost is the wait'),
    (r"ERR quiet-run: label 'suite' requires a tracked", 'gate:quiet-run', 'suite-label-untracked-path',
     'true-positive', 'label contract; wrong invocation by the leg'),
    (r'check-ci: watch cap reached', 'ci-wait', 'check-ci-watch-cap', 'unclear',
     'CI still pending at the watch cap; cost is a re-poll turn'),
    (r'clear-cr-marker[^\n]*no class-sweep record|clear-cr-marker: agreed-and-fixed', 'gate:clear-cr-marker',
     'missing-class-sweep', 'true-positive', 'gate requires SWEEP line; grammar is the friction'),
    (r'clear-cr-marker: no critic responded', 'gate:clear-cr-marker', 'no-critic-signal', 'true-positive',
     'missing review signal'),
    (r'clear-cr-marker: merged amend', 'gate:clear-cr-marker', 'merged-amend-open', 'unclear',
     'amend evaluation refusal'),
    (r'No such tool available: Grep', 'lane-rule', 'no-grep-tool', 'true-positive',
     'documented leg profile; costs one retry turn'),
    (r'WITHHELD:', 'gate:wrap-subtree-check', 'wrap-subtree-withheld', 'true-positive',
     'live child processes at wrap'),
    (r'context-fill: STALE', 'gate:context-fill', 'context-fill-stale', 'over-deny',
     'HUD snapshot lag makes the probe refuse'),
    (r'judge write-deny', 'hook:judge-write-deny', 'judge-write-outside', 'true-positive', 'judge scope'),
    (r'Exit code 4\n\[FAIL\] \d+\. head=', 'gate:ready-check', 'ready-check-fail', 'true-positive',
     'readiness item failed'),
]

HOOK_RE = re.compile(r'hook error: (?:\[.*?\]: )?(?:\S+ )?([A-Za-z0-9_.-]+): (.*)', re.S)
TOKEN_RE = re.compile(r'[A-Za-z0-9_\-]{28,}')


def mask(s):
    s = TOKEN_RE.sub('<tok>', s)
    s = re.sub(r'/home/[^/\s]+', '~', s)
    return re.sub(r'\s+', ' ', s)[:140]


def classify(text, denial_kind=None):
    """Return (source, class, verdict, evidence) or None when text is no refusal."""
    for rx, src, cls, verdict, ev in TEXT_RULES:
        m = re.search(rx, text)
        if m:
            if cls is None:
                cls = 'classifier-' + re.sub(r'[^a-z0-9]+', '-', m.group(1).lower()).strip('-')
            return src, cls, verdict, ev
    m = HOOK_RE.search(text)
    if m and ('hook error' in text):
        name, reason = m.group(1), m.group(2)
        for rx, cls, verdict, ev in HOOK_CLASSES.get(name, [(r'.', 'other-' + re.sub(r'[^a-z]+', '-', reason[:40].lower()).strip('-'),
                                                 'unclear', 'unmapped hook denial')]):
            if re.search(rx, reason):
                return 'hook:' + name, cls, verdict, ev
    if denial_kind in ('permission-rule', 'automode-blocked'):
        return 'permission-rule', 'unmapped-' + mask(text)[:40].lower().replace(' ', '-'), 'unclear', 'unmapped denial'
    return None


def parse_ts(s):
    try:
        return dt.datetime.fromisoformat(s.replace('Z', '+00:00'))
    except Exception:
        return None


def block_text(b):
    t = b.get('content')
    if isinstance(t, list):
        t = ' '.join(x.get('text', '') for x in t if isinstance(x, dict))
    return str(t)


def scan_transcript(path, lane, since, until=None):
    rows = []
    pending = []  # (row, ts) pairs awaiting the next non-denied tool_result for recovery time
    try:
        fh = open(path, errors='replace')
    except OSError:
        return rows
    with fh:
        for line in fh:
            if 'tool_result' not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            ct = (o.get('message') or {}).get('content')
            ts = parse_ts(o.get('timestamp') or '')
            if not isinstance(ct, list) or ts is None:
                continue
            for b in ct:
                if not (isinstance(b, dict) and b.get('type') == 'tool_result'):
                    continue
                refused = None
                if b.get('is_error') or o.get('toolDenialKind'):
                    refused = classify(block_text(b), o.get('toolDenialKind'))
                if refused is None:
                    if pending and not b.get('is_error'):
                        for prow, pts in pending:
                            prow['recovery_s'] = min(RECOVERY_CAP_S, (ts - pts).total_seconds())
                        pending = []
                    continue
                if ts < since or (until is not None and ts >= until):
                    continue
                src, cls, verdict, ev = refused
                row = {'source': src, 'class': cls, 'verdict': verdict, 'evidence': ev,
                       'session': o.get('sessionId') or os.path.basename(path), 'lane': lane,
                       'ts': ts.isoformat(), 'snippet': mask(block_text(b)[:300]), 'recovery_s': None}
                rows.append(row)
                pending.append((row, ts))
    return rows


def known_names(repo):
    names = {}
    for kind, pat in (('hook', 'scripts/hooks/*.sh'), ('gate', 'scripts/cr/*.sh'),
                      ('gate', 'scripts/handover/*.sh'), ('gate', 'scripts/handover/console-kit/*.sh')):
        for p in glob.glob(os.path.join(repo, pat)):
            n = os.path.basename(p)[:-3]
            if len(n) > 6 and not n.startswith('test-'):
                names[n] = kind
    return names


BULLET_RE = re.compile(r'^- (\d{2}):(\d{2}) ([A-Z][A-Za-z-]*)\b[^\n]*', re.M)
CLOSERS = {'RESOLVED', 'LIVE', 'READY', 'WRAPPED', 'RESUMED'}
REFUSAL_RE = re.compile(r'classifier|denied|refus|Instruction Poisoning|Auto-Mode|guard|hook|permission|gate|prompt', re.I)


CONTINUATION_RE = re.compile(
    r'own-inbox|inbox (hold|window)|hold window \d|window ?\d+ ?(/|of) ?\d|expired normally|benign (hook|tool)|'
    r'SUCCESSION accepted|RESUME written|context handoff|ruling received|hold Monitor stopped', re.I)
CLASSIFIER_TAGS = [
    ('instruction-poisoning', r'Instruction Poisoning'), ('auto-mode-bypass', r'Auto-Mode Bypass'),
    ('irreversible-local-destruction', r'Irreversible|rm -rf'), ('out-of-place-publication', r'Out-of-Place Publication'),
    ('merge-without-review', r'Merge Without Review'), ('external-system-writes', r'External System Writes'),
    ('security-weaken', r'Security Weaken'), ('ci-bypass', r'CI Bypass'), ('unverifiable', r'Unverifiable'),
    ('interfere-with-workloads', r'Interfere With Workloads'), ('code-from-external', r'Code from External'),
]
DOC_RULES = [
    (r'SKIPPED-BANK|bank-preflight|bank lane', 'gate:bank-preflight', 'bank-lane-mismatch'),
    (r'context guard|context-checkpoint|checkpoint guard|context handoff', 'hook:guard-leg-context-handoff',
     'context-guard-lock'),
    (r'missing-class-sweep|class-sweep', 'gate:clear-cr-marker', 'missing-class-sweep'),
    (r'runner queue|QUEUED|check-ci|DEADLINE|CI (red|wait)', 'ci-wait', 'ci-wait'),
    (r'push failed|upstream name mismatch|rc=128', 'lane-rule', 'push-failed'),
    (r'publication|no second push|console (pushes|publishes)|push(ed)? by the console', 'lane-rule', 'one-push-per-session'),
    (r'pre-commit|shellcheck|commit gate|first commit rejected', 'gate:pre-commit', 'commit-gate-reject'),
    (r'ruling|asked (the )?console|awaiting (the )?console|console (to|decision)', 'leg-question',
     'console-ruling-question'),
]


CLASSIFIER_DENIAL_RE = re.compile(
    r'(denied|refused|stopped|blocked)[^.;]{0,60}classifier|classifier[^.;]{0,40}(denied|denial|refus|stopp|objects)|'
    r'safety classifier|Instruction Poisoning|\[Code from External\]', re.I)
BRACKET_TAG_RE = re.compile(r'\[([A-Z][A-Za-z]+(?:[ -][A-Za-z]+){0,3})\]')


def classify_bullet(text, names):
    """Return (source, class) or None for a continuation / pure-status bullet that is no new refusal."""
    t = text
    tag = BRACKET_TAG_RE.search(t)
    if CONTINUATION_RE.search(t) and not (tag and re.search(r'denied|refused', t, re.I)):
        return None
    if CLASSIFIER_DENIAL_RE.search(t):
        if tag:
            return 'classifier', 'classifier-' + re.sub(r'[^a-z0-9]+', '-', tag.group(1).lower()).strip('-')
        for slug, rx in CLASSIFIER_TAGS:
            if re.search(rx, t):
                return 'classifier', 'classifier-' + slug
        if re.search(r'stopped (my|a)', t):
            return 'classifier', 'classifier-stopped-turn'
        return 'classifier', 'classifier-untagged'
    for rx, src, cls in DOC_RULES[:3]:
        if re.search(rx, t):
            return src, cls
    for n in sorted(names, key=len, reverse=True):
        if n in t:
            return names[n] + ':' + n, 'doc-' + n
    for rx, src, cls in DOC_RULES[3:]:
        if re.search(rx, t):
            return src, cls
    return 'unclassified', 'doc-unclassified'


def scan_docs(docs_dir, since, names):
    rows = []
    cutoff = since.timestamp()
    for path in glob.glob(os.path.join(docs_dir, 'HIMMEL-*-N*.md')):
        if os.path.getmtime(path) < cutoff:
            continue
        leg = os.path.basename(path)
        try:
            body = open(path, errors='replace').read()
        except OSError:
            continue
        bullets = [(int(m.group(1)) * 60 + int(m.group(2)), m.group(3), m.group(0)) for m in BULLET_RE.finditer(body)]
        for i, (mins, marker, text) in enumerate(bullets):
            if marker not in ('BLOCKED', 'FINDING') or not REFUSAL_RE.search(text):
                continue
            if marker == 'FINDING' and not re.search(r'denied|refus|classifier|guard|hook', text, re.I):
                continue
            kind = classify_bullet(text, names)
            if kind is None:
                continue
            src, cls = kind
            hold = None
            for m2, mk2, _ in bullets[i + 1:]:
                if mk2 in CLOSERS:
                    hold = (m2 - mins) % 1440
                    break
            if hold is not None and hold > 720:
                hold = None
            rows.append({'source': src, 'class': cls, 'leg': leg, 'marker': marker, 'hold_min': hold,
                         'operator': bool(re.search(r'operator', text, re.I)), 'snippet': mask(text[8:])})
    return rows


def _med(xs):
    return None if not xs else round(statistics.median(xs), 1)


def aggregate(tx_rows, doc_rows):
    """Per (source, class) from transcripts; per source from leg docs (docs carry no class granularity)."""
    classes = {}
    for r in tx_rows:
        a = classes.setdefault((r['source'], r['class']), {
            'source': r['source'], 'class': r['class'], 'count': 0, 'sessions': set(), 'recovery': [],
            'verdicts': collections.Counter(), 'evidence': r['evidence'], 'lanes': collections.Counter()})
        a['count'] += 1
        a['sessions'].add(r['session'])
        a['verdicts'][r['verdict']] += 1
        a['lanes'][r['lane']] += 1
        if r['recovery_s'] is not None:
            a['recovery'].append(r['recovery_s'] / 60.0)
    by_class = []
    for a in classes.values():
        by_class.append({'source': a['source'], 'class': a['class'], 'count': a['count'],
                         'distinct_sessions': len(a['sessions']), 'retries_per_session':
                         round(a['count'] / max(1, len(a['sessions'])), 2),
                         'median_recovery_min': _med(a['recovery']), 'verdicts': dict(a['verdicts']),
                         'lanes': dict(a['lanes']), 'evidence': a['evidence']})
    by_class.sort(key=lambda r: (-r['count'], r['class']))
    sources = {}
    for r in doc_rows:
        a = sources.setdefault(r['source'], {'blocks': 0, 'legs': set(), 'holds': [], 'operator': 0,
                                             'classes': collections.Counter()})
        a['blocks'] += 1
        a['legs'].add(r['leg'])
        a['operator'] += 1 if r['operator'] else 0
        a['classes'][r['class']] += 1
        if r['hold_min'] is not None:
            a['holds'].append(r['hold_min'])
    by_source = []
    for src, a in sources.items():
        tx_n = sum(c['count'] for c in by_class if c['source'] == src)
        by_source.append({'source': src, 'doc_blocks': a['blocks'], 'distinct_legs': len(a['legs']),
                          'median_hold_min': _med(a['holds']), 'total_hold_min': round(sum(a['holds']), 1),
                          'console_turns': a['blocks'], 'operator_interrupts': a['operator'],
                          'transcript_refusals': tx_n,
                          'score': round(sum(a['holds']) + 5 * a['blocks'] + 15 * a['operator'], 1)})
    by_source.sort(key=lambda r: (-r['score'], r['source']))
    dc = {}
    for r in doc_rows:
        a = dc.setdefault((r['source'], r['class']), {'n': 0, 'legs': set(), 'holds': [], 'op': 0})
        a['n'] += 1
        a['legs'].add(r['leg'])
        a['op'] += 1 if r['operator'] else 0
        if r['hold_min'] is not None:
            a['holds'].append(r['hold_min'])
    doc_classes = [{'source': k[0], 'class': k[1], 'doc_blocks': a['n'], 'distinct_legs': len(a['legs']),
                    'median_hold_min': _med(a['holds']), 'total_hold_min': round(sum(a['holds']), 1),
                    'operator_interrupts': a['op']} for k, a in dc.items()]
    doc_classes.sort(key=lambda r: (-(r['total_hold_min'] + 5 * r['doc_blocks'] + 15 * r['operator_interrupts']),
                                    r['class']))
    return {'by_class': by_class, 'by_source': by_source, 'doc_classes': doc_classes}


def render_md(agg, meta):
    lines = ['# Friction measurement (last %s days)' % meta['days'], '',
             '%d transcript refusals, %d leg-doc BLOCKED/FINDING bullets.' % (meta['tx_rows'], meta['doc_rows']), '',
             '## A. Escalations to the console, by source (leg docs)', '',
             'score = total hold min + 5 x console turns + 15 x operator interrupts.', '',
             '| # | source | doc blocks | legs | median hold min | total hold min | console turns | operator | '
             'transcript refusals | score |', '|---|---|---|---|---|---|---|---|---|---|']
    for i, r in enumerate(agg['by_source'], 1):
        lines.append('| %d | %s | %d | %d | %s | %s | %d | %d | %d | %s |' % (
            i, r['source'], r['doc_blocks'], r['distinct_legs'],
            '-' if r['median_hold_min'] is None else r['median_hold_min'], r['total_hold_min'],
            r['console_turns'], r['operator_interrupts'], r['transcript_refusals'], r['score']))
    lines += ['', '## A2. Escalations by source x class (leg docs)', '',
              '| # | source | class | doc blocks | legs | median hold min | total hold min | operator |',
              '|---|---|---|---|---|---|---|---|']
    for i, r in enumerate(agg['doc_classes'], 1):
        lines.append('| %d | %s | %s | %d | %d | %s | %s | %d |' % (
            i, r['source'], r['class'], r['doc_blocks'], r['distinct_legs'],
            '-' if r['median_hold_min'] is None else r['median_hold_min'], r['total_hold_min'],
            r['operator_interrupts']))
    lines += ['', '## B. Refusals seen in transcripts, by source x class', '',
              '| # | source | class | n | sessions | per session | median recovery min | verdict | lanes |',
              '|---|---|---|---|---|---|---|---|---|']
    for i, r in enumerate(agg['by_class'], 1):
        v = ', '.join('%s %d' % kv for kv in sorted(r['verdicts'].items(), key=lambda kv: -kv[1]))
        ln = ', '.join('%s %d' % kv for kv in sorted(r['lanes'].items()))
        lines.append('| %d | %s | %s | %d | %d | %s | %s | %s | %s |' % (
            i, r['source'], r['class'], r['count'], r['distinct_sessions'], r['retries_per_session'],
            '-' if r['median_recovery_min'] is None else r['median_recovery_min'], v, ln))
    return '\n'.join(lines) + '\n'


def scan_all(projects, since, until=None):
    rows = []
    for pdir in projects:
        lane = 'claudex' if 'codex' in pdir else 'native'
        for path in glob.glob(os.path.join(pdir, '*', '*.jsonl')):
            if os.path.getmtime(path) < since.timestamp():
                continue
            rows.extend(scan_transcript(path, lane, since, until))
    return rows


def render_section(tx, prior_tx, docs, days, top=5):
    """The digest subsection: top classes by refusals with the trend against the prior window, and the
    top escalations by hold. Docs carry only HH:MM stamps, so their window is the file mtime and they
    have no prior-window trend."""
    prior = collections.Counter((r['source'], r['class']) for r in prior_tx)
    now_n = collections.Counter((r['source'], r['class']) for r in tx)
    verdict = {(r['source'], r['class']): r['verdict'] for r in tx}
    out = ['### Friction (last %d days)' % days, '']
    if not now_n:
        out.append('- no refusals in the window')
    for (src, cls), n in sorted(now_n.items(), key=lambda kv: (-kv[1], kv[0]))[:top]:
        p = prior.get((src, cls), 0)
        out.append('- %s / %s: %d refusals (%s, prior %d, %s)' % (
            src, cls, n, verdict[(src, cls)], p, 'new' if not p else '%+d' % (n - p)))
    esc = {}
    for r in docs:
        e = esc.setdefault((r['source'], r['class']), {'n': 0, 'hold': 0})
        e['n'] += 1
        e['hold'] += r['hold_min'] or 0
    out += ['', 'Escalations to the console, by total hold:', '']
    for (src, cls), e in sorted(esc.items(), key=lambda kv: (-kv[1]['hold'], kv[0]))[:top]:
        out.append('- %s / %s: %d blocks, %d hold min' % (src, cls, e['n'], e['hold']))
    if not esc:
        out.append('- none')
    return '\n'.join(out) + '\n'


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--section', action='store_true', help='print only the compact digest subsection')
    ap.add_argument('--days', type=int, default=7)
    ap.add_argument('--now', default=None)
    ap.add_argument('--projects', action='append')
    ap.add_argument('--docs', default=DEFAULT_DOCS)
    ap.add_argument('--repo', default=os.getcwd())
    ap.add_argument('--json')
    ap.add_argument('--md')
    a = ap.parse_args(argv)
    now = parse_ts(a.now) if a.now else dt.datetime.now(dt.timezone.utc)
    if now is None:
        ap.error('--now is not an ISO timestamp: %s' % a.now)
    if now.tzinfo is None:
        now = now.replace(tzinfo=dt.timezone.utc)
    since = now - dt.timedelta(days=a.days)
    names = known_names(a.repo)
    projects = a.projects or DEFAULT_PROJECTS
    tx = scan_all(projects, since, now)
    docs = scan_docs(a.docs, since, names)
    if a.section:
        prior = scan_all(projects, since - dt.timedelta(days=a.days), since)
        sys.stdout.write(render_section(tx, prior, docs, a.days))
        return 0
    table = aggregate(tx, docs)
    meta = {'days': a.days, 'since': since.isoformat(), 'tx_rows': len(tx), 'doc_rows': len(docs)}
    if a.json:
        with open(a.json, 'w') as f:
            json.dump({'meta': meta, **table}, f, indent=1)
    md = render_md(table, meta)
    if a.md:
        with open(a.md, 'w') as f:
            f.write(md)
    else:
        sys.stdout.write(md)
    return 0


if __name__ == '__main__':
    sys.exit(main())
