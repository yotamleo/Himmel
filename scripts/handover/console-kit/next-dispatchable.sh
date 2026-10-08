#!/usr/bin/env bash
# next-dispatchable.sh — HIMMEL-4959. Ranked, collision-checked list of the next
# tickets a console can dispatch. READ-ONLY: it prints, it never launches,
# creates a worktree or writes the mirror. console-wait.sh prints it with the
# `WAKE underfilled` block; a console can also run it by hand. It absorbs the
# spare-capacity suggestion of HIMMEL-4431.
#
#   next-dispatchable.sh [--top N] [--mirror DIR] [--legs-from MANIFEST]
#                        [--held FILE] [--no-classify]
#
# Source: the Jira mirror (`jira ... mirror`, one <KEY>.md per issue). A
# candidate is a To Do issue that is not an Epic/Story/Sub-task, carries none of
# the operator-decision / blocked labels (EXCLUDE_LABELS) and has no unresolved
# blocked_by link. Rank: earliest unreleased fixVersion (HIMMEL.versions.tsv,
# natural order; none last), then priority, then key.
#
# Collision (one writer per file): the files a candidate names in its
# description are checked against (a) the files in the live legs' docs (the
# manifest's `legs[].doc`, scope lines), (b) the diff of every open PR (gh), and
# (c) --held FILE (one path per line). A path equal to, or under/over, a held
# path collides. When gh fails the list is printed with an `open PRs unknown`
# header rather than silently trusting an empty set.
#
# Classification: the survivors go through scripts/lanes/cloud-route.mjs
# --classify-only (the same gates as /cloud-route). CLOUD-OK prints CLOUD;
# LOCAL-NATIVE prints LOCAL; HOOK-BYPASS prints LOCAL with `hook` (the leg needs
# the hook-integrity bypass launch); BLOCKED is dropped. --no-classify prints
# every survivor as LOCAL? (no Jira or gh read for the class).
#
# Output, one line per ticket, tab-separated:
#   <LOCAL|CLOUD> <KEY> <priority> <fixVersion|-> <title> files=<a,b|->  [hook]
#
# Env (tests): NEXT_DISPATCH_MIRROR, NEXT_DISPATCH_GH_CMD (replaces `gh`),
# NEXT_DISPATCH_CLASSIFY_CMD (replaces cloud-route.mjs; called with the keys),
# NEXT_DISPATCH_EXCLUDE_LABELS (comma list, replaces the default).
#
# Exit: 0 printed (possibly nothing); 2 usage.
# PLATFORM GUARD: no .ps1 twin, by design — the console kit is Linux-only.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

top=8; mirror="${NEXT_DISPATCH_MIRROR:-${HOME:-/tmp}/.himmel/state/jira-mirror/HIMMEL}"
legs_from="${LEGS_FROM:-}"; held=""; classify=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --top) top="${2:-}"; shift 2 || exit 2 ;;
        --mirror) mirror="${2:-}"; shift 2 || exit 2 ;;
        --legs-from) legs_from="${2:-}"; shift 2 || exit 2 ;;
        --held) held="${2:-}"; shift 2 || exit 2 ;;
        --no-classify) classify=0; shift ;;
        *) echo "usage: next-dispatchable.sh [--top N] [--mirror DIR] [--legs-from MANIFEST] [--held FILE] [--no-classify]" >&2; exit 2 ;;
    esac
done
case "$top" in ''|*[!0-9]*) echo "next-dispatchable: --top needs a number" >&2; exit 2 ;; esac

export ND_TOP="$top" ND_MIRROR="$mirror" ND_LEGS_FROM="$legs_from" ND_HELD="$held" ND_CLASSIFY="$classify" ND_REPO="$REPO"
exec python3 -I - <<'PY'
import json, os, re, subprocess, sys

top = int(os.environ['ND_TOP']); mirror = os.environ['ND_MIRROR']
repo = os.environ['ND_REPO']
excl = set(filter(None, os.environ.get('NEXT_DISPATCH_EXCLUDE_LABELS',
    'operator-decision,operator,operator-present,blocked,decision,windows-parked,design-deferred,placeholder').split(',')))
FILE_RE = re.compile(r"(?<![\w./-])((?:scripts|docs|marketplace|templates|tools|\.claude|\.github|\.codex)/[\w.+@-]+(?:/[\w.+@-]+)*/?|CLAUDE\.md|AGENTS\.md|\.pre-commit-config\.yaml)")
PRIO = {'Highest': 0, 'Blocker': 0, 'Critical': 0, 'High': 1, 'Medium': 2, 'Low': 3, 'Lowest': 4}

def files_in(text):
    out = []
    for m in FILE_RE.finditer(text):
        f = re.sub(r'[.,;:)\]-]+$', '', m.group(1))
        if f and f not in out:
            out.append(f)
    return out

def collides(a, b):
    a, b = a.rstrip('/'), b.rstrip('/')
    return a == b or a.startswith(b + '/') or b.startswith(a + '/')

def fm_val(fm, name):
    m = re.search(r'^%s: (.*)$' % re.escape(name), fm, re.M)
    return m.group(1).strip() if m else ''

def unq(v):
    return v.strip().strip('"')

issues = {}
try:
    names = sorted(n for n in os.listdir(mirror) if re.match(r'^[A-Z]+-\d+\.md$', n))
except OSError as e:
    print('# next-dispatchable: mirror unreadable (%s)' % e, file=sys.stderr); sys.exit(0)
for n in names:
    txt = open(os.path.join(mirror, n), encoding='utf-8', errors='replace').read()
    m = re.match(r'^---\n(.*?)\n---\n(.*)$', txt, re.S)
    if not m:
        continue
    fm, body = m.groups()
    key = unq(fm_val(fm, 'key'))
    t = re.search(r'^# [A-Z]+-\d+: (.*)$', body, re.M)
    issues[key] = {
        'key': key, 'type': unq(fm_val(fm, 'type')), 'status': unq(fm_val(fm, 'status')),
        'prio': unq(fm_val(fm, 'priority')), 'labels': set(re.findall(r'"([^"]+)"', fm_val(fm, 'labels'))),
        'ver': re.findall(r'"([^"]+)"', fm_val(fm, 'fixVersions')),
        'blocked_by': re.findall(r'[A-Z]+-\d+', re.search(r'blocked_by: (.*)', fm).group(1)) if re.search(r'blocked_by: (.*)', fm) else [],
        'title': t.group(1).strip() if t else '', 'files': files_in(body),
    }

# unreleased versions in natural order
vorder = {}
vf = mirror.rstrip('/') + '.versions.tsv'
if os.path.exists(vf):
    def nat(v): return [int(x) if x.isdigit() else x for x in re.split(r'(\d+)', v)]
    vs = []
    for line in open(vf, encoding='utf-8', errors='replace'):
        p = line.rstrip('\n').split('\t')
        if len(p) >= 2 and p[1].strip() == 'false' and not p[0].startswith('zz-'):
            vs.append(p[0])
    for i, v in enumerate(sorted(vs, key=nat)):
        vorder[v] = i

def rank(i):
    vers = [vorder[v] for v in i['ver'] if v in vorder]
    return (min(vers) if vers else 10**6, PRIO.get(i['prio'], 5), int(i['key'].split('-')[1]))

cands = []
for i in issues.values():
    if i['status'] != 'To Do' or i['type'] in ('Epic', 'Story', 'Sub-task'):
        continue
    if i['labels'] & excl:
        continue
    if any(issues.get(b, {}).get('status') != 'Done' for b in i['blocked_by'] if b in issues):
        continue
    cands.append(i)
cands.sort(key=rank)

# held files: live legs, open PRs, --held
held = []
legs_from = os.environ.get('ND_LEGS_FROM', '')
if legs_from and os.path.isfile(legs_from):
    try:
        for leg in json.load(open(legs_from)).get('legs', []):
            doc = leg.get('doc', '')
            try:
                for line in open(doc, encoding='utf-8', errors='replace'):
                    if line.startswith('> **Scope / do not:**') or 'writes confined to' in line:
                        held += [(f, 'live leg %s' % leg.get('label', '?')) for f in files_in(line)]
            except OSError:
                pass
    except (OSError, ValueError):
        pass
hf = os.environ.get('ND_HELD', '')
if hf and os.path.isfile(hf):
    held += [(l.strip(), 'held list') for l in open(hf) if l.strip()]
pr_unknown = False
gh = os.environ.get('NEXT_DISPATCH_GH_CMD', 'gh')
try:
    nums = subprocess.run([gh, 'pr', 'list', '--repo', 'yotamleo/Himmel', '--state', 'open', '--limit', '200', '--json', 'number', '--jq', '.[].number'],
                          capture_output=True, text=True, timeout=60, check=True).stdout.split()
    for num in nums:
        d = subprocess.run([gh, 'pr', 'diff', num, '--repo', 'yotamleo/Himmel', '--name-only'], capture_output=True, text=True, timeout=60, check=True).stdout.split()
        held += [(f, 'open PR %s' % num) for f in d]
except (OSError, subprocess.SubprocessError):
    pr_unknown = True

free = []
for i in cands:
    if any(collides(f, h) for f in i['files'] for h, _ in held):
        continue
    free.append(i)

batch = free[:max(top * 3, top)]
cls = {}
if os.environ.get('ND_CLASSIFY') == '1' and batch:
    cmd = os.environ.get('NEXT_DISPATCH_CLASSIFY_CMD')
    argv = [cmd] if cmd else ['node', os.path.join(repo, 'scripts/lanes/cloud-route.mjs'), '--classify-only']
    hfile = None
    if held:
        import tempfile
        t = tempfile.NamedTemporaryFile('w', suffix='.held', delete=False)
        t.write('\n'.join(h for h, _ in held) + '\n'); t.close(); hfile = t.name
        if not cmd:
            argv += ['--held', hfile]
    try:
        r = subprocess.run(argv + [i['key'] for i in batch], capture_output=True, text=True, timeout=300)
        for line in r.stdout.splitlines():
            p = line.split('\t')
            if len(p) >= 2 and re.match(r'^[A-Z]+-\d+$', p[0]):
                cls[p[0]] = p[1]
    except (OSError, subprocess.SubprocessError):
        pass
    if hfile:
        os.unlink(hfile)

print('# next-dispatchable: %d To Do candidate(s), %d collision-free%s' % (len(cands), len(free), ', open PRs unknown (gh failed)' if pr_unknown else ''))
n = 0
for i in batch:
    c = cls.get(i['key'])
    if os.environ.get('ND_CLASSIFY') == '1':
        if c is None or c == 'BLOCKED':
            continue
        lane = 'CLOUD' if c == 'CLOUD-OK' else 'LOCAL'
    else:
        lane, c = 'LOCAL?', ''
    print('\t'.join([lane, i['key'], i['prio'] or '-', ','.join(i['ver']) or '-', i['title'], 'files=' + (','.join(i['files']) or '-')] + (['hook'] if c == 'HOOK-BYPASS' else [])))
    n += 1
    if n >= top:
        break
PY
