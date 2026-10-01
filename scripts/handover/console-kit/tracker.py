"""Living roadmap tracker for HIMMEL-3882: one self-contained HTML page, re-run to refresh.

Plan (static) comes from <plan-dir>/stage3/placement|versions|closures|unplaced + meta.json,
the stage1 theme/impact columns and explain files (user impact), stage2 (readiness, effort range)
and the placer's layer caps (tools/stage3/place.py). Status (live) comes from the Jira mirror, never from the plan,
so progress moves as work lands. Related luna notes per placed ticket are cached in the
luna-map file (qmd lexical search + a key grep of the handover tree); only keys missing or
older than 7 days are re-queried, `--refresh-luna` forces all.

USAGE
    node scripts/jira/dist/index.js mirror
    python3 tracker.py --plan-dir <HIMMEL-3882 plan dir> --out <tracker.html> --luna-map <luna-map.json>
        [--mirror-dir DIR] [--luna-root DIR] [--handovers DIR] [--refresh-luna]
    python3 tracker.py ... --emit-fp     print the freshness fingerprint and exit

Writes --out, the sidecar <out>.fp (the fingerprint tick.sh compares for tracker=) and
--luna-map (stdlib only).
"""
import argparse
import ast
import glob
import hashlib
import json
import os
import re
import subprocess
import time
from datetime import datetime, timezone

MIRROR = os.path.expanduser('~/.himmel/state/jira-mirror/HIMMEL')
LUNA = os.path.expanduser('~/Documents/luna')
HANDOVERS = ''
LAYERS = ['bugs', 'enhancements', 'features', 'misc', 'audit']
VER_RE = re.compile(r'^v1\.0\.(\d+)([b-z]?)$')  # a trail '<version>b', 'c', ... takes its parent's overflow
SKIP_RE = re.compile(r'HIMMEL-3882|/dashboard|/artifacts|backlog|\.bak|/graphify-out/')
KEY_RE = re.compile(r'HIMMEL-\d+')
MAX_NOTES, TTL = 5, 7 * 86400
ROOT = OUT = LUNA_MAP = ''
PLAN_FILES = ('meta.json', 'versions.tsv', 'placement.tsv', 'closures.tsv', 'unplaced.tsv')


def read_tsv(path):
    """Header line + rows; '#' lines skipped. Returns (header, rows as dicts, field counts)."""
    lines = [l.rstrip('\n') for l in open(path, encoding='utf-8') if not l.startswith('#')]
    lines = [l for l in lines if l.strip()]
    head = lines[0].split('\t')
    rows, nf = [], []
    for l in lines[1:]:
        f = l.split('\t')
        nf.append(len(f))
        rows.append(dict(zip(head, f)))
    return head, rows, nf


def plan_globs():
    """The stage1/stage2 row-field files and the placer's caps (layer caps, per-version overrides) the page reads."""
    return (sorted(glob.glob(os.path.join(ROOT, 'stage1', 'C??.tsv'))) +
            sorted(glob.glob(os.path.join(ROOT, 'stage1', 'C??.explain.tsv'))) +
            sorted(glob.glob(os.path.join(ROOT, 'stage2', 'C??.tsv'))) +
            [p for p in [os.path.join(ROOT, 'tools', 'stage3', f) for f in ('place.py', 'common.py')]
             if os.path.exists(p)])


# HIMMEL-3990 ask 5: a ticket is in progress when a live leg works it. A leg doc is HIMMEL-<n>-N<k>-*.md in the
# bucket; it is live while its queue lock is held and fresh and its newest marker is not WRAPPED / HALTED.
LEG_RE = re.compile(r'^HIMMEL-(\d+)-(N\d+[a-z]?)-.*\.md$')
MARK_RE = re.compile(r'^- (?:\d{1,2}:\d{2}\s+)?(?:\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE)(?:[^A-Za-z0-9_].*)?$')
PR_RE = re.compile(r'\b(?:PR|READY|GO)\s+#?(\d{3,5})\b')


def held_docs():
    """Realpaths of handover docs whose queue lock is held and fresh (heartbeat within queue-lock.sh's TTL).

    The lock dir is <handover root>/.locks/queue, found walking up from the bucket; none = no legs (read-only, no network)."""
    d, q = HANDOVERS, None
    for _ in range(4):
        if os.path.isdir(os.path.join(d, '.locks', 'queue')):
            q = os.path.join(d, '.locks', 'queue')
            break
        d = os.path.dirname(d)
    if not q:
        return set()
    ttl, now, out = int(os.environ.get('QUEUE_LOCK_TTL_SECONDS') or 21600), time.time(), set()
    for p in glob.glob(os.path.join(q, '*.lock', 'owner.json')):
        try:
            o = json.load(open(p, encoding='utf-8'))
        except (OSError, ValueError):
            continue
        try:
            age = now - datetime.strptime(o.get('heartbeat', ''), '%Y-%m-%dT%H:%M:%SZ').replace(
                tzinfo=timezone.utc).timestamp()
        except (ValueError, TypeError):
            age = 0  # an unparsable heartbeat is fresh, as queue-lock.sh status reads it
        if age <= ttl and o.get('handover'):
            out.add(os.path.realpath(o['handover']))
    return out


def leg_marker(path):
    """(marker, pr) from a leg doc's Results bullets: leg-tail-status.sh's rule, and the newest PR a marker bullet names."""
    try:
        ls = [l.rstrip('\n') for l in open(path, encoding='utf-8', errors='replace')]
    except OSError:
        return None, None
    rs = [i for i, l in enumerate(ls) if l.startswith('## Results')]
    bl = [l for l in ls[rs[-1] + 1 if rs else 0:] if l.startswith('- ')]
    pr = None
    for l in bl:
        if not MARK_RE.match(l):
            continue
        for m in PR_RE.finditer(l):
            pr = int(m.group(1))
    if not bl:
        return 'LIVE', pr
    m = MARK_RE.match(bl[-1])
    if m:
        return m.group(1), pr
    if re.search(r'(^|[^A-Za-z0-9_])WRAPPED([^A-Za-z0-9_]|$)', bl[-1]):
        return 'WRAPPED', pr
    ms = [MARK_RE.match(l) for l in bl]
    ms = [x.group(1) for x in ms if x]
    return (ms[-1] if ms else 'LIVE'), pr


def live_legs():
    """{ticket number: [leg label, marker, pr or None]} for live legs; the newest doc wins per ticket."""
    held, out = held_docs(), {}
    if not held:
        return out
    docs = [p for p in glob.glob(os.path.join(HANDOVERS, 'HIMMEL-*-N*-*.md')) if LEG_RE.match(os.path.basename(p))]
    for p in sorted(docs, key=lambda x: (os.path.getmtime(x), x)):
        if os.path.realpath(p) not in held:
            continue
        mk, pr = leg_marker(p)
        if mk in ('WRAPPED', 'HALTED'):
            continue
        n, lab = LEG_RE.match(os.path.basename(p)).groups()
        out[int(n)] = [lab, mk, pr]
    return out


def fingerprint():
    """16 hex over the mirror's newest `updated:`, the plan + stage1/stage2 files' bytes and the live legs (what the page shows)."""
    upd = ''
    for p in glob.glob(os.path.join(MIRROR, 'HIMMEL-*.md')):
        for l in open(p, encoding='utf-8', errors='replace'):
            if l.startswith('updated:'):
                upd = max(upd, l.split(':', 1)[1].strip().strip('"'))
                break
    h = hashlib.sha256(upd.encode() + b'\n')
    for f in PLAN_FILES:
        p = os.path.join(ROOT, 'stage3', f)
        h.update(open(p, 'rb').read() if os.path.exists(p) else b'-')
    for p in plan_globs():
        h.update(open(p, 'rb').read())
    h.update(json.dumps(sorted(live_legs().items())).encode())
    return h.hexdigest()[:16]


def plan_rules(meta):
    """Capacity rules as the plan records them: meta.json notes + the placer's CAPS. None = not recorded."""
    txt = ' '.join(n for n in meta.get('notes', []) if isinstance(n, str))

    def val(pat):
        m = re.search(pat, txt)
        return float(m.group(1)) if m else None
    sm = re.search(r'S-eq:\s*XS\s*([\d.]+)\s+S\s+([\d.]+)\s+M\s+([\d.]+)\s+L\s+([\d.]+)\s+XL\s+([\d.]+)', txt)
    def lit(f, name):
        """A top-level `name = {...}` literal from the plan tool, single- or multi-line; never executed."""
        try:
            tree = ast.parse(open(os.path.join(ROOT, 'tools', 'stage3', f), encoding='utf-8').read())
            vs = [ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign)
                  and any(isinstance(t, ast.Name) and t.id == name for t in n.targets)]
            v = vs[-1] if vs else None
        except (OSError, ValueError, SyntaxError, TypeError):
            v = None
        return v if isinstance(v, dict) else None
    em = meta.get('effort_model') if isinstance(meta.get('effort_model'), dict) else {}

    def emv(k):
        return em[k] if isinstance(em.get(k), (int, float)) else None
    # Effort model B (HIMMEL-3992) words the caps "a version holds < N" / "total mean load within X" and carries
    # the bank rate as effort_model.bank_per_seq; the older wording still parses.
    return dict(tickets=val(r'(?:ticket count|version holds)\s*<\s*(\d+)'), total=val(r'total (?:mean )?load within\s*([\d.]+)'),
                per=emv('bank_per_seq') if emv('bank_per_seq') is not None else val(r'effort_mid\s*x\s*([\d.]+)'),
                seq=[float(x) for x in sm.groups()] if sm else None,
                layers=lit('place.py', 'CAPS'), over=lit('common.py', 'VERSION_CAP_OVERRIDES') or {},
                p90=emv('p90_cap'), model=bool(em))


def intg(x):
    return int(x) if isinstance(x, float) and x.is_integer() else x


def ver_key(v):
    """Plan order (HIMMEL-3990): v1.0.1 < v1.0.1b < v1.0.2 < v1.0.10; buckets such as v2/v3 follow the train."""
    m = VER_RE.match(v)
    return (0, int(m.group(1)), m.group(2)) if m else (1, 0, '')


def trail_parent(v):
    """The version a trail continues ('v1.0.2b' -> 'v1.0.2'); None for anything else."""
    m = VER_RE.match(v)
    return 'v1.0.' + m.group(1) if m and m.group(2) else None


def vlabel(v):
    """A trail reads as its parent's overflow, not a new release (the page's vname() says the same)."""
    m = VER_RE.match(v)
    if not (m and m.group(2)):
        return v
    k = ord(m.group(2)) - ord('a')
    return 'v1.0.%s · overflow%s' % (m.group(1), '' if k == 1 else ' %d' % k)


def version_caps(r, vers):
    """Per-version caps (HIMMEL-3979): the plan default with its VERSION_CAP_OVERRIDES applied; None = deferred bucket.
    A trail keeps its parent's caps, overrides included, unless the overrides name the trail itself."""
    out = []
    for v in vers:
        if not VER_RE.match(v):
            out.append(None)
            continue
        ov = r['over'].get(v if v in r['over'] else trail_parent(v)) or {}
        out.append(dict(t=intg(ov.get('tickets', r['tickets'])), tot=ov.get('total', r['total']),
                        l=[ov.get(l, (r['layers'] or {}).get(l)) for l in LAYERS], p9=r['p90']))
    return out


def capacity_text(r, deferred, trails=()):
    """Plain-language cap panel lines; a rule the plan does not record says so instead of guessing."""
    nr = 'not recorded in the plan'
    parts = ['at most %d tickets' % r['tickets'] if r['tickets'] is not None else 'a ticket cap ' + nr,
             'at most %g bank of load' % r['total'] if r['total'] is not None else 'a load cap ' + nr]
    out = ['Each v1.0.x version holds ' + ' and '.join(parts) + '; the plan puts every ticket in the earliest version with room.']
    for v in sorted(r['over']):
        ov = r['over'][v] if isinstance(r['over'][v], dict) else {}
        ps = (['at most %d tickets' % ov['tickets']] if 'tickets' in ov else []) + \
             (['at most %g bank of load' % ov['total']] if 'total' in ov else []) + \
             ['a %s cap of %.2f' % (l, ov[l]) for l in LAYERS if l in ov]
        if ps:
            out.append('%s holds %s (a plan override of the default).' % (v, ' and '.join(ps)))
    if trails:
        out.append('A trail version such as %s takes the overflow of %s and keeps its caps, overrides included, '
                   'unless the plan names the trail; later versions are never renumbered.' % (trails[0], trail_parent(trails[0])))
    if r['p90'] is not None:
        out.append('Likely load is the average outcome; cautious load is the level 9 times in 10 stay under (P90). '
                   'Each version keeps its cautious load within %g bank.' % r['p90'])
    lc = r['layers']
    out.append('Layer caps, in bank: ' + ' · '.join('%s %.2f' % (l, lc[l]) for l in LAYERS if l in lc) + '.'
               if lc else 'Layer caps: ' + nr + '.')
    out.append(('Load = the average effort in S-equivalents, overruns included, × %g bank; a plan-first ticket counts only its slice.'
                if r['model'] else 'Load = effort in S-equivalents × %g bank; a plan-first ticket counts only its slice.') % r['per']
               if r['per'] is not None else 'How load is derived from effort: ' + nr + '.')
    out += ['%s is a deferred bucket: no caps apply.' % v for v in deferred]
    return out


def ledger_lines(rows, vers):
    """Header ledger (HIMMEL-3957): the running version, the whole v1.0.x train, and drift/unplanned only when non-zero."""
    train = [i for i, v in enumerate(vers) if VER_RE.match(v)]

    def line(label, sel):
        a = [r for r in rows if r[3] in sel]
        t = [sum(1 for r in a if r[2] == s) for s in (0, 1, 2)]
        return '%s%d of %d done (%d %%), %d in progress, %d to do.' % (
            label, t[2], len(a), int(100.0 * t[2] / len(a) + 0.5) if a else 0, t[1], t[0])
    cur = next((i for i in train if any(r[3] == i and r[2] != 2 for r in rows)), None)
    out = [line('Running now: %s — ' % vlabel(vers[cur]), {cur}) if cur is not None
           else 'Running now: nothing — every v1.0.x ticket is done.', line('Whole v1.0.x train: ', set(train))]
    dr = sum(1 for r in rows if r[3] in train and r[7] == 1)
    un = sum(1 for r in rows if r[3] in train and r[7] == 2 and r[2] != 2)
    att = []
    if dr:
        att.append('%d %s from the plan (Jira names another version)' % (dr, 'ticket drifted' if dr == 1 else 'tickets drifted'))
    if un:
        att.append('%d open %s in a version but not in the plan' % (un, 'ticket sits' if un == 1 else 'tickets sit'))
    if att:
        out.append('Needs attention: ' + '; '.join(att) + '.')
    return out, cur


def num(key):
    return int(key.split('-')[1])


def clip(s, n):
    s = ' '.join(s.split())
    return s if len(s) <= n else s[:n - 1] + '…'


def read_mirror():
    """{key: dict(st, fv, upd, title, type)} from the mirror frontmatter."""
    out = {}
    for p in glob.glob(os.path.join(MIRROR, 'HIMMEL-*.md')):
        txt = open(p, encoding='utf-8', errors='replace').read()
        parts = txt.split('---', 2)
        if len(parts) < 3:
            continue
        fm = {}
        for l in parts[1].splitlines():
            if ':' in l and not l.startswith(' '):
                k, v = l.split(':', 1)
                fm[k.strip()] = v.strip()
        key = fm.get('key', '').strip('"')
        if not key:
            continue
        m = re.search(r'^# [A-Z]+-\d+:\s*(.*)$', parts[2], re.M)
        try:
            fv = json.loads(fm.get('fixVersions', '[]'))
        except ValueError:
            fv = []
        cat = fm.get('statusCategory', '').strip('"')
        out[key] = dict(st=2 if cat == 'Done' else 1 if cat == 'In Progress' else 0, fv=fv,
                        upd=fm.get('updated', '').strip('"'), title=m.group(1) if m else '',
                        type=fm.get('type', '').strip('"'))
    return out


_titles = {}


def note_title(rel):
    if rel not in _titles:
        t = ''
        try:
            for i, l in enumerate(open(os.path.join(LUNA, rel), encoding='utf-8', errors='replace')):
                if l.startswith('# '):
                    t = l[2:].strip()
                    break
                if l.startswith('title:'):
                    t = l[6:].strip().strip('"\'')
                    break
                if i > 40:
                    break
        except OSError:
            pass
        _titles[rel] = clip(t or os.path.basename(rel)[:-3], 56)
    return _titles[rel]


def grep_index():
    """key -> [(rel, nkeys)] over the handover tree; dump-like files (>25 keys) are skipped."""
    idx = {}
    for dp, dn, fn in os.walk(HANDOVERS):
        if SKIP_RE.search(dp + '/'):
            continue
        for f in fn:
            if not f.endswith('.md') or SKIP_RE.search(f):
                continue
            p = os.path.join(dp, f)
            try:
                ks = set(KEY_RE.findall(open(p, encoding='utf-8', errors='replace').read()))
            except OSError:
                continue
            if not ks or len(ks) > 25:
                continue
            rel = os.path.relpath(p, LUNA)
            for k in ks:
                idx.setdefault(k, []).append((rel, len(ks)))
    return idx


def qmd_hits(key):
    try:
        r = subprocess.run(['qmd', 'search', '-c', 'luna', key, '--json', '-n', '10'],
                           capture_output=True, text=True, timeout=30)
        arr = json.loads(r.stdout or '[]')
    except (OSError, ValueError, subprocess.SubprocessError):
        return []
    pat = re.compile(r'(?<![\w-])%s(?!\d)' % re.escape(key))
    out = []
    for h in arr:
        rel = h.get('file', '').replace('qmd://luna/', '', 1)
        if SKIP_RE.search('/' + rel) or not os.path.exists(os.path.join(LUNA, rel)):
            continue
        if pat.search(h.get('snippet', '') + ' ' + h.get('title', '') + ' ' + rel):
            out.append(rel)
    return out


def luna_map(keys, refresh):
    """{key: [{path,title}]} for keys, incremental against the luna-map file (7-day TTL)."""
    path = LUNA_MAP
    try:
        cache = json.load(open(path, encoding='utf-8'))
    except (OSError, ValueError):
        cache = {}
    ent = cache.get('entries', {})
    now = int(time.time())
    need = [k for k in keys if refresh or k not in ent or now - ent[k].get('ts', 0) > TTL]
    if need:
        print('luna-map: querying %d keys (%d cached)' % (len(need), len(keys) - len(need)))
        idx = grep_index()
        for i, k in enumerate(need):
            g = sorted(idx.get(k, []), key=lambda x: (k not in x[0], x[1], x[0]))
            rels = []
            for rel in [x[0] for x in g] + qmd_hits(k):
                if rel not in rels:
                    rels.append(rel)
            ent[k] = dict(ts=now, notes=[dict(path=r, title=note_title(r)) for r in rels[:MAX_NOTES]])
            if i % 100 == 99:
                print('  %d/%d' % (i + 1, len(need)))
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        json.dump(dict(generated=now, entries=ent), open(path, 'w', encoding='utf-8'),
                  ensure_ascii=False, separators=(',', ':'))
    return {k: ent[k]['notes'] for k in keys if k in ent}


def main():
    global MIRROR, LUNA, HANDOVERS, ROOT, OUT, LUNA_MAP
    ap = argparse.ArgumentParser(description='Render the HIMMEL-3882 roadmap tracker page.')
    ap.add_argument('--plan-dir', required=True, help='the HIMMEL-3882 plan dir (holds stage1/ and stage3/)')
    ap.add_argument('--out', required=True, help='tracker.html to write')
    ap.add_argument('--luna-map', required=True, help='luna-map.json cache path')
    ap.add_argument('--mirror-dir', default=MIRROR)
    ap.add_argument('--luna-root', default=LUNA)
    ap.add_argument('--handovers', default=os.environ.get('TRACKER_HANDOVERS_DIR', ''),
                    help='handover tree to grep for notes and live legs (default $TRACKER_HANDOVERS_DIR, '
                         'else <luna-root>/handovers/yotamleo/himmel)')
    ap.add_argument('--refresh-luna', action='store_true')
    ap.add_argument('--emit-fp', action='store_true')
    a = ap.parse_args()
    ROOT, OUT, LUNA_MAP, MIRROR, LUNA = (os.path.abspath(a.plan_dir), os.path.abspath(a.out),
                                         os.path.abspath(a.luna_map), os.path.abspath(a.mirror_dir),
                                         os.path.abspath(a.luna_root))
    HANDOVERS = os.path.abspath(a.handovers) if a.handovers else os.path.join(LUNA, 'handovers', 'yotamleo', 'himmel')
    if a.emit_fp:
        print(fingerprint())
        return
    t0 = time.time()
    fp0 = fingerprint()  # taken before any input is read, so an edit mid-render leaves the page STALE, never falsely ok
    S =os.path.join(ROOT, 'stage3')
    meta = json.load(open(os.path.join(S, 'meta.json'), encoding='utf-8'))
    mir = read_mirror()
    legs = live_legs()
    for n in legs:  # HIMMEL-3990: a live leg puts its ticket in progress, whatever Jira says (Done stays done)
        m = mir.get('HIMMEL-%d' % n)
        if m and m['st'] != 2:
            m['st'] = 1
    vrows = sorted(read_tsv(os.path.join(S, 'versions.tsv'))[1], key=lambda r: ver_key(r['version']))
    vers = [r['version'] for r in vrows]
    vidx = {v: i for i, v in enumerate(vers)}
    vload = [[round(float(r['load_' + l] or 0), 3) for l in
              ('bugs', 'enhancements', 'features', 'misc', 'audit')] +
             [round(float(r['load_total'] or 0), 3), round(float(r['est_legs'] or 0), 1)] for r in vrows]
    theme, impact, uimp, plain, ready, erange = {}, {}, {}, {}, {}, {}
    for p in sorted(glob.glob(os.path.join(ROOT, 'stage1', 'C??.tsv'))):
        for r in read_tsv(p)[1]:
            theme[r['key']] = r.get('theme', '') or '(no theme)'
            if (r.get('impact') or '').isdigit():
                impact[r['key']] = int(r['impact'])
    # HIMMEL-3957 row fields: user-facing impact (stage1 explain), readiness + T-shirt range (stage2).
    for p in sorted(glob.glob(os.path.join(ROOT, 'stage1', 'C??.explain.tsv'))):
        for r in read_tsv(p)[1]:
            uimp[r['key']] = clip(r.get('user_impact') or '', 400)
            plain[r['key']] = clip(r.get('issue_plain') or '', 600)
    for p in sorted(glob.glob(os.path.join(ROOT, 'stage2', 'C??.tsv'))):
        for r in read_tsv(p)[1]:
            if (r.get('readiness') or '').isdigit():
                ready[r['key']] = int(r['readiness'])
            lo, hi = r.get('effort_low') or '', r.get('effort_high') or ''
            if lo or hi:
                erange[r['key']] = lo if lo == hi or not hi else hi if not lo else lo + '–' + hi

    rules = plan_rules(meta)
    seqm = dict(zip(('XS', 'S', 'M', 'L', 'XL'), rules['seq'] or []))

    def fields(k, sl='', mid=0.0):
        # P[14] issue_plain; P[15] the ticket's load in bank: effort_mid x per, or only its slice when planning comes first.
        # Under an effort model the placer's effort_mid already is the slice's mean (overrun included), so it is used as is.
        ld = None if rules['per'] is None else round((seqm.get(sl, 0) if sl and not rules['model'] else mid) * rules['per'], 4)
        return [uimp.get(k, ''), erange.get(k, ''), ready.get(k), impact.get(k), sl, plain.get(k, ''), ld]
    themes = sorted(set(theme.values()) | {'(no theme)', '(unplanned)'})
    tidx = {t: i for i, t in enumerate(themes)}

    placed = read_tsv(os.path.join(S, 'placement.tsv'))[1]
    lmap = luna_map([r['key'] for r in placed], a.refresh_luna)
    dirs, dix, notes, nix = [], {}, [], {}

    def note_id(n):
        if n['path'] not in nix:
            d, f = os.path.split(n['path'])
            if d not in dix:
                dix[d] = len(dirs)
                dirs.append(d)
            nix[n['path']] = len(notes)
            notes.append([dix[d], f, n['title']])
        return nix[n['path']]

    rows, planned = [], set()
    for r in placed:
        k, m = r['key'], mir.get(r['key'])
        planned.add(k)
        lay = r.get('layer') or 'misc'
        fl = 1 if (m and m['fv'] and r['version'] not in m['fv']) else 0  # drift
        rows.append([num(k), clip(m['title'] if m else '(not in mirror)', 62),
                     m['st'] if m else 0, vidx[r['version']], LAYERS.index(lay) if lay in LAYERS else 3,
                     tidx[theme.get(k, '(no theme)')], round(float(r['effort_mid'] or 0), 1), fl,
                     [note_id(n) for n in lmap.get(k, [])]] +
                    fields(k, (r.get('slice_effort') or 'S') if r.get('commit') == 'plan-first' else '',
                           float(r['effort_mid'] or 0)))
    n_plan = len(rows)
    for k, m in mir.items():
        if k in planned:
            continue
        hit = [v for v in m['fv'] if VER_RE.match(v) and v in vidx]
        if hit:
            rows.append([num(k), clip(m['title'], 62), m['st'], vidx[hit[0]],
                         0 if m['type'] == 'Bug' else 3, tidx.get(theme.get(k), tidx['(unplanned)']),
                         0, 2, []] + fields(k)[:-1] + [0])
    unpl = []
    for r in read_tsv(os.path.join(S, 'unplaced.tsv'))[1]:
        m = mir.get(r['key'])
        unpl.append([num(r['key']), clip(m['title'] if m else '', 60), m['st'] if m else 0,
                     clip(r['reason'], 60)])
    # HIMMEL-3954: parked closures stay visible (evidence = the reason); other closure flags are not shown.
    for r in read_tsv(os.path.join(S, 'closures.tsv'))[1]:
        if r['close_flag'] != 'park-ns':
            continue
        m = mir.get(r['key'])
        unpl.append([num(r['key']), clip(m['title'] if m else '', 60), m['st'] if m else 0,
                     clip(r.get('close_evidence', ''), 70)])

    upd = max((m['upd'] for m in mir.values()), default='')
    lg, cur = ledger_lines(rows, vers)
    seq = rules['seq']
    p90 = meta.get('version_p90_fw') if isinstance(meta.get('version_p90_fw'), dict) else {}
    data = dict(gen=datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC'), mir=upd[:16].replace('T', ' '),
                sha=meta.get('main_sha_at_build', '')[:9], V=vers, VL=vload, VC=version_caps(rules, vers),
                LEG={str(n): v for n, v in sorted(legs.items())}, L=LAYERS, T=themes, P=rows,
                U=unpl, DR=dirs, N=notes, LG=lg, CUR=cur,
                CAP=dict(total=rules['total'], layers=[(rules['layers'] or {}).get(l) for l in LAYERS],
                         text=capacity_text(rules, [v for v in vers if not VER_RE.match(v)],
                                            [v for v in vers if trail_parent(v)])),
                VP=[p90.get(v) if isinstance(p90.get(v), (int, float)) else None for v in vers],
                PIN=sorted(num(r['key']) for r in placed if re.search(r'\bpinned to ' + re.escape(r['version']) + r'\b', r.get('reason') or '')),
                EQ=' · '.join('%s %g' % x for x in zip(('XS', 'S', 'M', 'L', 'XL'), seq)) + ' S-equivalents'
                if seq else 'not recorded in the plan')
    blob = json.dumps(data, separators=(',', ':'), ensure_ascii=False).replace('<', '\\u003c')
    html = TEMPLATE.replace('__DATA__', blob)
    outp = OUT
    os.makedirs(os.path.dirname(outp), exist_ok=True)
    open(outp, 'w', encoding='utf-8').write(html)
    open(outp + '.fp', 'w', encoding='utf-8').write(fp0 + '\n')
    unp = sum(1 for r in rows if r[7] == 2 and r[2] != 2)  # open only
    drift = sum(1 for r in rows if r[7] == 1)
    cov = sum(1 for r in rows[:n_plan] if r[8])
    print('wrote %s (%.1f KB): %d planned, %d unplanned, %d drift, %d unplaced; mirror %d issues'
          % (outp, os.path.getsize(outp) / 1024, n_plan, unp, drift, len(unpl), len(mir)))
    for l in lg:
        print('ledger: ' + l)
    print('luna-map coverage: %d/%d placed keys with >=1 note; %d distinct notes; %.1fs'
          % (cov, n_plan, len(notes), time.time() - t0))


TEMPLATE = r'''<title>Himmel Roadmap</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Newsreader:opsz,wght@6..72,500&family=Geist:wght@400;500;600&family=Geist+Mono&display=swap">
<style>
/* HIMMEL-3990 design: "the release desk" — a release manager's dashboard. Four tiles say where the release stands; the unit
   of the page is the decision: every risk is one card with its levers, each lever shows what it would change (before → after,
   caps met or over) and the line to send the console — the page never acts. The versions strip reads every cap at a glance;
   tickets live in drawers. Warm paper and ink; the only chroma is meaning (done / live / to-do / over cap); --ldn is the
   neutral no-cap swatch (HIMMEL-3979). Serif only for what users gained; mono for keys and instructions. */
:root{--bg:#f5f4ef;--surface:#fff;--ink:#1a1a17;--muted:#6e6c64;--line:#e2e0d8;--accent:#1f4fd8;--done:#2e7d4f;--live:#b45f06;
--todo:#b9b7ae;--warn:#c2410c;--ldn:#d8d6ce;--bar:#4b4a44;--scrim:rgba(26,26,23,.28);
--f-serif:"Newsreader","Iowan Old Style","Charter",Georgia,serif;--f-sans:"Geist",system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;--f-mono:"Geist Mono",ui-monospace,"SFMono-Regular",Menlo,Consolas,monospace}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#121311;--surface:#1b1c19;--ink:#eceae2;--muted:#9a988f;--line:#2b2c28;--accent:#7b9cff;
--done:#5cbf85;--live:#f5b14d;--todo:#4a4b46;--warn:#f08a5b;--ldn:#34352f;--bar:#c9c7be;--scrim:rgba(0,0,0,.5);color-scheme:dark}}
:root[data-theme="dark"]{--bg:#121311;--surface:#1b1c19;--ink:#eceae2;--muted:#9a988f;--line:#2b2c28;--accent:#7b9cff;
--done:#5cbf85;--live:#f5b14d;--todo:#4a4b46;--warn:#f08a5b;--ldn:#34352f;--bar:#c9c7be;--scrim:rgba(0,0,0,.5);color-scheme:dark}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 var(--f-sans);font-variant-numeric:tabular-nums}
::selection{background:var(--accent);color:var(--bg)}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:2px}
code,.key{font-family:var(--f-mono);font-size:12.5px}
button{font:inherit;color:inherit}
.mast{position:sticky;top:0;z-index:5;background:var(--bg);border-bottom:1px solid var(--line)}
.mast .in{max-width:1200px;margin-inline:auto;padding:10px 16px;display:flex;flex-wrap:wrap;gap:6px 16px;align-items:center}
.mast b{font-weight:600}
.mast .stamp{color:var(--muted);font-size:12.5px;flex:1 1 200px;min-width:0}
.sw{display:inline-flex;gap:8px;align-items:center;font-size:13.5px;cursor:pointer;user-select:none}
.sw input{appearance:none;-webkit-appearance:none;margin:0;width:32px;height:18px;border-radius:9px;background:var(--todo);position:relative;cursor:pointer;flex:none}
.sw input::after{content:"";position:absolute;top:2px;left:2px;width:14px;height:14px;border-radius:50%;background:var(--surface)}
.sw input:checked{background:var(--ink)}.sw input:checked::after{left:16px}
.tbtn{border:1px solid var(--line);background:none;border-radius:4px;padding:3px 9px;font-size:12.5px;color:var(--muted);cursor:pointer}
main{max-width:1200px;margin-inline:auto;padding:20px 24px 64px}
h2.sec{font:500 13px var(--f-sans);color:var(--muted);margin:40px 0 0;padding-bottom:8px;border-bottom:1px solid var(--line)}
.sum{font:500 18px/1.4 var(--f-serif);margin:12px 0 20px;max-width:62ch}
.head{font:500 22px/1.25 var(--f-serif);margin:0 0 8px}
.tiles{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}
.tile{all:unset;box-sizing:border-box;display:flex;flex-direction:column;gap:4px;padding:14px 16px;background:var(--surface);border:1px solid var(--line);border-radius:6px;cursor:pointer;min-width:0}
.tile:hover{border-color:var(--muted)}.tile:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.tile .lb{font-size:12px;color:var(--muted)}
.tile .fig{font:600 28px/1.15 var(--f-sans);letter-spacing:-.01em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tile .sb{font-size:13px;color:var(--muted)}
.tile.hot{border-color:var(--warn)}.tile.hot .fig{color:var(--warn)}
.tile .chips{display:flex;flex-wrap:wrap;gap:4px;margin-top:2px}
.tile .cap{margin-top:6px}
.desk{display:grid;grid-template-columns:minmax(0,7fr) minmax(0,5fr);gap:32px;align-items:start}
.desk h2.sec{margin-top:32px}
#vers{position:sticky;top:48px}
section:focus{outline:none}
ol.decl{list-style:none;margin:0;padding:0}
.card{border-bottom:1px solid var(--line);padding:14px 0}
.band{display:inline-block;font:600 10.5px var(--f-sans);letter-spacing:.05em;text-transform:uppercase;padding:1px 6px;border-radius:3px;margin-right:8px;vertical-align:2px;border:1px solid var(--line);color:var(--muted)}
.band.b0{color:var(--warn);border-color:var(--warn)}.band.b1{color:var(--ink);border-color:var(--ink)}
.ctl{font-size:15px;font-weight:500;overflow-wrap:anywhere}
.fact{font-size:13px;color:var(--muted);margin-top:3px;overflow-wrap:anywhere}
.levers{display:flex;flex-wrap:wrap;gap:6px;margin-top:10px}
.lv{border:1px solid var(--line);background:var(--surface);border-radius:4px;padding:4px 10px;font-size:13px;cursor:pointer}
.lv:hover{border-color:var(--muted)}
.lv[aria-pressed="true"]{border-color:var(--ink);background:var(--ink);color:var(--bg)}
.wi{margin-top:10px;padding:12px 14px;border:1px solid var(--line);border-radius:6px;background:var(--surface)}
.wi .two{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:16px}
.wi table.ld{margin:0}
.met{color:var(--done)}.ovr{color:var(--warn)}
.wi h4{font:600 12px var(--f-sans);color:var(--muted);margin:14px 0 2px}
.fall{list-style:none;margin:0;padding:0}
.fall li{display:grid;grid-template-columns:5.6em minmax(0,1fr) auto;gap:10px;align-items:baseline;padding:5px 0;border-top:1px solid var(--line);font-size:13px}
.fall label{display:inline-flex;gap:4px;align-items:center;color:var(--muted);font-size:12px;cursor:pointer;white-space:nowrap}
.fall .t{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.copy{display:flex;gap:8px;align-items:flex-start;margin-top:12px}
.copy pre{flex:1;min-width:0;margin:0;padding:8px 10px;background:var(--bg);border:1px solid var(--line);border-radius:4px;font:12.5px/1.55 var(--f-mono);white-space:pre-wrap;overflow-wrap:anywhere}
.vrow{all:unset;box-sizing:border-box;display:grid;grid-template-columns:7.2em minmax(0,1fr) auto;gap:12px;align-items:center;width:100%;padding:9px 0;border-bottom:1px solid var(--line);cursor:pointer;font-size:13px}
.vrow:hover .nm{text-decoration:underline;text-underline-offset:3px}
.vrow:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.vrow.trail .nm{color:var(--muted);padding-left:14px}
.vmore{margin-top:10px}
.vrow .nm{font:500 13px var(--f-mono);white-space:nowrap}
.vrow .fg{color:var(--muted);white-space:nowrap;text-align:right}
.x{color:var(--warn)}
.vrow .cap{margin:0}
.cur-dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--live);margin-right:6px;vertical-align:1px}
.cap .p9{position:absolute;top:50%;width:7px;height:7px;margin:-4.5px 0 0 -4.5px;transform:rotate(45deg);border:1.5px solid var(--ink);border-radius:1px;background:var(--surface)}
.cap .p9.x{background:var(--warn);border-color:var(--warn)}
.gains{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,300px),1fr));gap:12px;margin-top:16px}
.gain{background:var(--surface);border:1px solid var(--line);border-radius:6px;padding:14px 16px;min-width:0}
.gain h3{font:600 14px var(--f-sans);margin:0 0 4px}
.gain .gl{font-size:13px;color:var(--muted);margin:0 0 10px}
.gain ul{list-style:none;margin:0;padding:0;display:grid;gap:10px}
.gain li{font:500 16px/1.4 var(--f-serif);padding-left:16px;position:relative;overflow-wrap:anywhere}
.gain li::before{content:"";position:absolute;left:0;top:.55em;width:7px;height:7px;border-radius:50%;background:var(--done)}
.quotes{list-style:none;margin:-8px 0 24px;padding:0;display:grid;gap:10px;max-width:62ch}
.quotes li{border-left:2px solid var(--line);padding-left:12px;font-size:15px;line-height:1.5}
.quotes b{display:block;font:600 11.5px var(--f-sans);color:var(--muted);letter-spacing:.02em}
.n{all:unset;cursor:pointer;color:inherit;text-decoration:underline dotted 1.5px;text-underline-offset:4px;text-decoration-color:var(--muted)}
.n:hover{text-decoration-color:var(--ink)}
.n:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.strip{display:flex;height:8px;border-radius:2px;overflow:hidden;background:var(--todo)}
.strip i{display:block;height:100%}
.strip .d{background:var(--done)}.strip .l{background:var(--live)}.strip .s{background:color-mix(in srgb,var(--live) 45%,var(--todo))}
.cap{position:relative;height:8px;border-radius:2px;background:var(--line);margin-top:4px}
.cap i{position:absolute;top:0;bottom:0;left:0;background:var(--bar);border-radius:2px 0 0 2px}
.cap i.o{background:var(--warn);border-radius:0 2px 2px 0}
.cap b{position:absolute;top:-3px;bottom:-3px;width:1px;background:var(--ink)}
.cap.none{background:repeating-linear-gradient(45deg,var(--ldn) 0 3px,transparent 3px 7px)}
.cap-line{display:flex;flex-wrap:wrap;gap:4px 12px;font-size:13px;color:var(--muted);margin:8px 0 20px}
.cap-line .n{color:var(--ink)}.cap-line .x{color:var(--warn)}
.bars{display:grid;gap:10px;margin:0 0 4px}
.work{margin:0 0 24px;padding:0;list-style:none}
.work li{display:flex;gap:10px;align-items:baseline;padding:6px 0;font-size:14px;min-width:0}
.work li span:last-child{min-width:0;overflow-wrap:anywhere}
h3.grp{font:600 12.5px var(--f-sans);color:var(--muted);margin:24px 0 4px;display:flex;justify-content:space-between;gap:12px}
h3.grp span{font-weight:400}
.tk{border-top:1px solid var(--line)}
.tk>summary{list-style:none;display:grid;grid-template-columns:14px minmax(0,1fr) auto;gap:4px 12px;align-items:start;padding:12px 0;cursor:pointer}
.tk>summary::-webkit-details-marker{display:none}
.tk>summary:hover .ui{text-decoration:underline;text-decoration-color:var(--line);text-underline-offset:3px}
.tx{min-width:0;display:grid;gap:2px}
.ui{font-size:16px;line-height:1.45;overflow-wrap:anywhere}
.int{font-variant:small-caps;letter-spacing:.04em;color:var(--muted);font-size:14px}
.sub{font-size:13px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tg{display:flex;gap:8px;align-items:center;font-size:12px;color:var(--muted);padding-top:3px;justify-content:flex-end;flex-wrap:wrap}
.mk{width:10px;height:10px;border-radius:50%;margin-top:7px;border:1.5px solid var(--todo);display:block}
.mk.done{background:var(--done);border-color:var(--done)}
.mk.live{background:var(--live);border-color:var(--live)}
.mk.started{border-color:var(--live);background:linear-gradient(90deg,var(--live) 50%,transparent 50%)}
@media (prefers-reduced-motion:no-preference){.mk.live{animation:pulse 2s ease-in-out infinite}}
@keyframes pulse{50%{box-shadow:0 0 0 4px color-mix(in srgb,var(--live) 25%,transparent)}}
.chip{font:500 11.5px var(--f-mono);padding:1px 6px;border-radius:3px;border:1px solid var(--live);color:var(--ink);white-space:nowrap}
.chip.READY{border-color:var(--done)}.chip.BLOCKED,.chip.FINDING{border-color:var(--warn);background:color-mix(in srgb,var(--warn) 14%,transparent)}
.sz{font:500 11.5px var(--f-mono)}
.dots{display:inline-flex;gap:2px}.dots i{width:4px;height:4px;border-radius:50%;background:var(--line)}.dots i.f{background:var(--muted)}
.more{padding:0 0 14px 26px;font-size:14px;color:var(--muted);max-width:66ch}
.more p{margin:0 0 8px;color:var(--ink)}
.more ul{margin:0;padding-left:18px}.more li{margin:2px 0}
.more a{color:var(--accent)}
details.done-grp,details.fold{border-top:1px solid var(--line)}
details.done-grp>summary,details.fold>summary{cursor:pointer;padding:12px 0;font-size:14px;color:var(--muted)}
.up{display:grid;grid-template-columns:auto minmax(0,1fr);gap:4px 12px;padding:8px 0;border-top:1px solid var(--line);font-size:14px}
.up span:last-child{grid-column:2;color:var(--muted);font-size:13px}
.up .t{min-width:0;overflow-wrap:anywhere}
footer{margin-top:64px;font-size:13px;color:var(--muted)}
.terms{display:grid;grid-template-columns:minmax(0,9em) minmax(0,1fr);gap:8px 16px;margin:8px 0 16px}
.terms dt{color:var(--ink);font-weight:500}.terms dd{margin:0}
.terms .mk,.terms .cap{display:inline-block;vertical-align:middle;margin:0 4px 0 0}
.terms .cap{width:40px}
.rules p{margin:4px 0}
#scrim{position:fixed;inset:0;background:var(--scrim);z-index:9}
#drawer{position:fixed;z-index:10;top:0;right:0;bottom:0;width:min(440px,100%);background:var(--surface);border-left:1px solid var(--line);display:flex;flex-direction:column}
#drawer[hidden],#scrim[hidden]{display:none}
.dhd{display:flex;gap:12px;align-items:flex-start;justify-content:space-between;padding:20px 20px 12px;border-bottom:1px solid var(--line)}
.dhd h2{font:500 20px/1.3 var(--f-serif);margin:0}.dhd h2:focus{outline:none}
.dhd button{border:0;background:none;font-size:22px;line-height:1;cursor:pointer;color:var(--muted);padding:2px 6px;border-radius:4px}
#db{overflow:auto;padding:4px 20px 32px;overscroll-behavior:contain}
#db .note{font-size:13px;color:var(--muted);margin:12px 0}
#db .tk>summary{grid-template-columns:14px minmax(0,1fr)}
#db .tk .tg{grid-column:2;justify-content:flex-start;padding-top:0}
table.ld{width:100%;border-collapse:collapse;font-size:13.5px;margin:12px 0}
table.ld th,table.ld td{text-align:right;padding:6px 0 6px 8px;border-bottom:1px solid var(--line)}
table.ld th:first-child,table.ld td:first-child{text-align:left;padding-left:0}
table.ld th{font-weight:500;color:var(--muted);font-size:12px}
table.ld tr.x td{color:var(--warn)}
ol.ct{list-style:none;margin:0 0 8px;padding:0}
ol.ct li{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:2px 12px;padding:6px 0;border-top:1px solid var(--line);font-size:13.5px}
ol.ct li .t{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
ol.ct li .v{font-family:var(--f-mono);font-size:12px;color:var(--muted)}
@media (max-width:900px){
 .tiles{grid-template-columns:minmax(0,1fr) minmax(0,1fr)}
 .desk{grid-template-columns:minmax(0,1fr);gap:0}#vers{position:static}
}
@media (max-width:560px){
 main{padding:16px 16px 48px}.mast .in{padding:8px 16px}
 .tiles{gap:8px}.tile{padding:10px 12px}.tile .fig{font-size:22px}.tile .chips{display:none}
 .sum{font-size:17px}
 .wi{padding:10px}.wi .two{grid-template-columns:minmax(0,1fr)}
 .fall li{grid-template-columns:auto minmax(0,1fr);row-gap:2px}.fall li>:last-child{text-align:right}.fall .t{grid-column:1/-1;order:3}
 .vrow{grid-template-columns:6.4em minmax(0,1fr);row-gap:4px}.vrow .fg{grid-column:1/-1;text-align:left}
 .tk>summary{grid-template-columns:14px minmax(0,1fr)}.tg{grid-column:2;justify-content:flex-start;padding-top:0}
 #drawer{top:auto;left:0;width:100%;height:85vh;border-left:0;border-top:1px solid var(--line);border-radius:12px 12px 0 0}
 .dhd::before{content:"";position:absolute;left:50%;top:6px;width:36px;height:4px;margin-left:-18px;border-radius:2px;background:var(--line)}
 .terms{grid-template-columns:minmax(0,1fr)}
}
</style>
<header class="mast"><div class="in"><b>Himmel roadmap</b><span class="stamp" id="stamp"></span>
<label class="sw" title="Hides done tickets from counts, bars and lists. Decisions and levers always weigh the full planned load."><input type="checkbox" role="switch" id="rem"> Remaining only</label>
<button class="tbtn" id="theme" type="button">Theme</button></div></header>
<main id="main">
<section class="tiles" id="tiles" aria-label="Where the release stands"></section>
<div class="desk">
<div><section id="dec" tabindex="-1" aria-labelledby="dech"><h2 class="sec" id="dech">Needs your input</h2><ol class="decl" id="decl"></ol></section>
<section id="steer" aria-labelledby="steerh"><h2 class="sec" id="steerh">Steer</h2><div id="steerb"></div></section></div>
<section id="vers" aria-labelledby="versh"><h2 class="sec" id="versh">Versions</h2><div id="vlist"></div></section>
</div>
<section id="gain" tabindex="-1" aria-labelledby="gainh"><h2 class="sec" id="gainh">What users gained</h2><div class="gains" id="gains"></div></section>
<footer>
<details class="fold"><summary>Terms</summary>
<dl class="terms" id="terms"></dl></details>
<details class="fold" id="pvj"><summary id="pvjs">Plan vs Jira</summary><div id="pvjb"></div></details>
<details class="fold"><summary>Budget rules</summary><div class="rules" id="rules"></div></details>
<p id="prov"></p>
</footer>
</main>
<div id="scrim" hidden></div>
<aside id="drawer" role="dialog" aria-modal="true" aria-labelledby="dh" hidden><div class="dhd"><h2 id="dh" tabindex="-1"></h2><button type="button" id="dx" aria-label="Close">×</button></div><div id="db"></div></aside>
<script type="application/json" id="data">__DATA__</script>
<script>
(function(){
var D=JSON.parse(document.getElementById("data").textContent);
/*MODEL*/
// Pure model (HIMMEL-3990): every figure on the page and every drill-down list comes from here; test-tracker.sh runs it under node.
function model(D){
 var V=D.V,P=D.P,T=D.T,LEG=D.LEG||{};
 var KIND=["bugs","improvements","features","other","audits"];
 var READY=["no plan yet","problem stated","fix named, not yet checked","plan audited","spec ready"];
 function train(i){return /^v1\.0\.\d+[b-z]?$/.test(V[i])}
 // vname(i): a trail (v1.0.2b, c, ...) reads as its parent's overflow, not a new release.
 function vname(i){var m=/^(v1\.0\.\d+)([b-z])$/.exec(V[i]);return m?m[1]+" · overflow"+(m[2]=="b"?"":" "+(m[2].charCodeAt(0)-97)):V[i]}
 function keep(rem){return function(p){return !rem||p[2]!=2}}
 function inV(i,rem){return P.filter(function(p){return p[3]==i}).filter(keep(rem))}
 function inT(t,rem){return P.filter(function(p){return p[5]==t&&train(p[3])}).filter(keep(rem))}
 function inTrain(rem){return P.filter(function(p){return train(p[3])}).filter(keep(rem))}
 function leg(p){return p[2]!=2&&LEG[String(p[0])]||null}
 function tally(a){var r={n:a.length,done:0,prog:0,todo:0,live:0};
  a.forEach(function(p){if(p[2]==2)r.done++;else if(p[2]==1)r.prog++;else r.todo++;if(leg(p))r.live++});r.left=r.n-r.done;return r}
 function r4(x){return Math.round(x*10000)/10000}
 function ld(p){return p[7]==2?0:(p[15]||0)}
 function rank(p){return p[2]==2?3:leg(p)?0:p[2]==1?1:2}
 function order(a){return a.slice().sort(function(x,y){return rank(x)-rank(y)||(y[12]||0)-(x[12]||0)||x[0]-y[0]})}
 // load(i): the version's budget by kind of work, each kind with its tickets (heaviest first); caps are the version's own (VC).
 function load(i,rem){
  var a=inV(i,rem),c=D.VC[i],tot=0;
  var kinds=KIND.map(function(k,j){var t=a.filter(function(p){return p[4]==j&&ld(p)>0}).sort(function(x,y){return ld(y)-ld(x)||x[0]-y[0]}),u=0;
   t.forEach(function(p){u+=ld(p)});tot+=u;var cap=c?c.l[j]:null;
   return {kind:k,used:r4(u),cap:cap,head:cap==null?null:r4(cap-u),over:cap!=null&&u>cap+1e-9,tickets:t}});
  var planned=a.filter(function(p){return p[7]!=2}).length;
  // p90: the plan's cautious load for the whole version (effort model P90), next to its cap; null when not recorded.
  var p9=D.VP&&D.VP[i]!=null?D.VP[i]:null;
  return {used:r4(tot),cap:c?c.tot:null,planned:planned,tcap:c?c.t:null,kinds:kinds,deferred:!c,p90:p9,p90cap:c&&c.p9!=null?c.p9:null}}
 function isInt(p){return /^internal\b/i.test(p[9]||"")}
 function isUser(p){return !!p[9]&&!isInt(p)}
 function best(a){return a.slice().sort(function(x,y){return (y[12]||0)-(x[12]||0)||(x[6]||0)-(y[6]||0)||x[0]-y[0]})[0]}
 function pl(n,one,many){return n+" "+(n==1?one:many)}
 // summary(a, by): deterministic words from the tickets' user impact. by "theme" for a version, "version" for a theme.
 function summary(a,by){
  var u=a.filter(isUser),i=a.filter(isInt).length,g={},col=by=="theme"?5:3;
  function name(k){return by=="theme"?T[k]:vname(k)}
  u.forEach(function(p){var k=p[col];g[k]=g[k]||{k:k,n:0,s:0,a:[]};g[k].n++;g[k].s+=p[12]||0;g[k].a.push(p)});
  var gs=Object.keys(g).map(function(k){return g[k]}).sort(function(x,y){return y.s-x.s||y.n-x.n||String(name(x.k)).localeCompare(String(name(y.k)))});
  var s;
  if(!a.length)s="Nothing left here.";
  else if(!u.length&&i)s="Housekeeping only: "+pl(i,"internal change","internal changes")+".";
  else if(!u.length)s=pl(a.length,"ticket","tickets")+", none described in the plan yet.";
  else{s="Ships "+pl(u.length,"change","changes")+" for users"+(i?" and "+pl(i,"internal one","internal ones"):"");
   if(by=="theme"){var nm=gs.filter(function(x){return !/^\(/.test(T[x.k])}).slice(0,2);
    if(nm.length)s+="; mostly "+nm.map(function(x){return T[x.k]+" ("+x.n+")"}).join(" and ")}
   else{var vs=a.map(function(p){return p[3]}).sort(function(x,y){return x-y});s+=", from "+vname(vs[0])+(vs[vs.length-1]!=vs[0]?" to "+vname(vs[vs.length-1]):"")}
   s+="."}
  return {lead:s,quotes:gs.slice(0,3).map(function(x){var p=best(x.a);return {p:p,text:p[9]}})}}
 // drill(kind, scope): the tickets behind one figure; scope {v:i} or {t:i} or {train:1}.
 function drill(kind,scope,rem){
  var a=scope.v!=null?inV(scope.v,rem):scope.t!=null?inT(scope.t,rem):inTrain(rem);
  var f={all:function(){return true},done:function(p){return p[2]==2},left:function(p){return p[2]!=2},
   live:function(p){return !!leg(p)},prog:function(p){return p[2]==1&&!leg(p)},todo:function(p){return p[2]==0}}[kind];
  return order(a.filter(f))}
 function current(rem){for(var i=0;i<V.length;i++)if(train(i)&&inV(i).some(function(p){return p[2]!=2}))return i;return null}
 // Steering (the release desk). The page cannot act: it computes what a lever would change and words the instruction.
 function pinned(p){return (D.PIN||[]).indexOf(p[0])>=0}
 function planned(p){return p[7]!=2}
 function roi(p){return (p[12]||0)/Math.max(p[6]||0,.1)}
 // trail(i): the overflow version that takes i's work: v1.0.2 → v1.0.2b, v1.0.2b → v1.0.2c; i -1 when it does not exist yet.
 function trail(i){var m=/^(v1\.0\.\d+)([b-z]?)$/.exec(V[i]);if(!m)return null;
  var n=m[1]+(m[2]?String.fromCharCode(m[2].charCodeAt(0)+1):"b");return {i:V.indexOf(n),name:n}}
 function parent(i){var m=/^(v1\.0\.\d+)[b-z]$/.exec(V[i]);return m?V.indexOf(m[1]):-1}
 function base(i){var m=0;inV(i).forEach(function(p){if(planned(p))m+=ld(p)});return m}
 // ratio(i): P90 per unit of mean in version i, so a what-if can move the P90 with the mean.
 // ponytail: the P90 after a move is scaled from the plan's own P90 by mean (≈), not re-simulated; re-run the placer to confirm.
 function ratio(i){var b=base(i),v=D.VP&&D.VP[i];return v!=null&&b>0?v/b:null}
 // stats(i, a, r): a ticket set's load in version i (i -1: a trail not yet made): planned count, mean, per kind, and P90 (≈).
 function stats(i,a,r){var k=[0,0,0,0,0],m=0,n=0;a.forEach(function(p){if(!planned(p))return;n++;m+=ld(p);k[p[4]]+=ld(p)});
  var v=i>=0&&D.VP?D.VP[i]:null,b=i>=0?base(i):0,q=i>=0?ratio(i):null,p9=null;
  if(v!=null)p9=v+(m-b)*(q!=null?q:r||0);else if(r!=null&&m>0)p9=m*r;
  return {n:n,m:r4(m),k:k.map(r4),p9:p9==null?null:r4(Math.max(p9,0))}}
 function capsOf(i,from){return i>=0?D.VC[i]:D.VC[from]}
 // breaches(i, st, c): every cap the stats break: mean, tickets, P90, then each kind.
 function breaches(i,st,c){c=c||D.VC[i];if(!c)return [];var b=[],e=1e-9;
  if(c.tot!=null&&st.m>c.tot+e)b.push({what:"mean",used:st.m,cap:c.tot});
  if(c.t!=null&&st.n>c.t)b.push({what:"tickets",used:st.n,cap:c.t});
  if(c.p9!=null&&st.p9!=null&&st.p9>c.p9+e)b.push({what:"P90",used:st.p9,cap:c.p9});
  KIND.forEach(function(k,j){if(c.l&&c.l[j]!=null&&st.k[j]>c.l[j]+e)b.push({what:k,used:st.k[j],cap:c.l[j]})});return b}
 // peel(i, {keep, unpin}): take the open, leg-free, unpinned tickets by lowest return (impact per size) until every cap holds;
 // each step takes the first candidate that eases a cap still broken. keep: tickets the viewer pins here; unpin: plan pins released.
 function peel(i,o){o=o||{};var keep=o.keep||[],un=o.unpin||[],a=inV(i).filter(planned),cur=a.slice(),out=[];
  var cand=a.filter(function(p){return p[2]!=2&&!leg(p)&&keep.indexOf(p[0])<0&&(!pinned(p)||un.indexOf(p[0])>=0)})
   .sort(function(x,y){return roi(x)-roi(y)||(y[6]||0)-(x[6]||0)||x[0]-y[0]});
  for(;;){var b=breaches(i,stats(i,cur));if(!b.length)break;
   var w=b.map(function(x){return x.what}),j=-1;
   for(var q=0;q<cand.length&&j<0;q++){var p=cand[q];
    if(w.indexOf("tickets")>=0||(ld(p)>0&&(w.indexOf("mean")>=0||w.indexOf("P90")>=0||w.indexOf(KIND[p[4]])>=0)))j=q}
   if(j<0)break;out.push(cand[j]);cur.splice(cur.indexOf(cand[j]),1);cand.splice(j,1)}
  return {moved:out,left:breaches(i,stats(i,cur)),held:a.filter(function(p){return pinned(p)&&p[2]!=2&&un.indexOf(p[0])<0})}}
 // whatIf(i, moved, to): both versions before and after moving the tickets from i to `to` (-1: the trail not yet made).
 function whatIf(i,moved,to){var a=inV(i),r=ratio(i),ta=to>=0?inV(to):[],c=capsOf(to,i);
  var fa=a.filter(function(p){return moved.indexOf(p)<0}),f0=stats(i,a),f1=stats(i,fa),t0=stats(to,ta,r),t1=stats(to,ta.concat(moved),r);
  f0.b=breaches(i,f0);f1.b=breaches(i,f1);t0.b=breaches(to,t0,c);t1.b=breaches(to,t1,c);
  return {from:{i:i,before:f0,after:f1},to:{i:to,before:t0,after:t1,caps:c}}}
 // fold(i): the trail's open tickets, best return first, that its parent can take back without breaking a cap.
 function fold(i){var pr=parent(i);if(pr<0)return [];var cur=inV(pr).slice(),out=[];
  if(breaches(pr,stats(pr,cur)).length)return [];
  inV(i).filter(function(p){return p[2]!=2&&planned(p)&&!leg(p)}).sort(function(x,y){return roi(y)-roi(x)||x[0]-y[0]}).forEach(function(p){
   if(!breaches(pr,stats(pr,cur.concat([p]))).length){cur.push(p);out.push(p)}});return out}
 // decisions(): what needs input, ordered. Band 0 stops now (a BLOCKED or FINDING leg); band 1 blocks the release (the running
 // version and the next: caps, drift); band 2 queue health (later caps, drift, the unplaced, a trail its parent can take back).
 function decisions(){var cur=D.CUR,nx=cur!=null&&cur+1<V.length&&train(cur+1)?cur+1:-1,out=[];
  function near(i){return i==cur||i==nx}
  P.forEach(function(p){var lg=leg(p);if(lg&&(lg[1]=="BLOCKED"||lg[1]=="FINDING"))out.push({band:0,type:"leg",i:p[3],p:p,s:lg[1]=="BLOCKED"?0:1})});
  V.forEach(function(_,i){var b=breaches(i,stats(i,inV(i)));if(b.length)out.push({band:near(i)?1:2,type:"cap",i:i,b:b})});
  P.forEach(function(p){if(p[7]&&p[2]!=2&&train(p[3]))out.push({band:near(p[3])?1:2,type:"drift",i:p[3],p:p})});
  V.forEach(function(_,i){var f=fold(i);if(f.length)out.push({band:2,type:"fold",i:i,f:f})});
  var u=(D.U||[]).filter(function(x){return x[2]!=2});if(u.length)out.push({band:2,type:"unplaced",i:u.length,u:u,last:1});
  var TR={leg:0,cap:1,drift:2,fold:3,unplaced:4};
  return out.sort(function(x,y){return x.band-y.band||(x.last||0)-(y.last||0)||x.i-y.i||TR[x.type]-TR[y.type]||(x.s||0)-(y.s||0)||(x.p?x.p[0]:0)-(y.p?y.p[0]:0)})}
 // gains(): done work per train version, newest first: what users got.
 function gains(){var g=[];for(var i=V.length-1;i>=0;i--){if(!train(i))continue;var d=order(inV(i).filter(function(p){return p[2]==2}));
  if(d.length)g.push({i:i,done:d,n:inV(i).length,s:summary(d,"theme")})}return g}
 return {KIND:KIND,READY:READY,train:train,vname:vname,inV:inV,inT:inT,inTrain:inTrain,leg:leg,tally:tally,load:load,summary:summary,
  drill:drill,order:order,isUser:isUser,current:current,ld:ld,pinned:pinned,roi:roi,trail:trail,parent:parent,stats:stats,breaches:breaches,
  peel:peel,whatIf:whatIf,fold:fold,decisions:decisions,gains:gains}}
/*END MODEL*/
var M=model(D),V=D.V.map(function(_,i){return M.vname(i)}),T=D.T,REM=false,opener=null;
function $(i){return document.getElementById(i)}
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!=null)e.textContent=x;return e}
function txt(s){return document.createTextNode(s)}
function add(p){for(var i=1;i<arguments.length;i++){var c=arguments[i];if(c==null)continue;p.appendChild(typeof c=="string"?txt(c):c)}return p}
function pl(n,one,many){return n+" "+(n==1?one:many)}
function f2(x){return x==null?"–":x.toFixed(2)}
function pct(n,d){return d?Math.round(100*n/d):0}
function nb(label,kind,scope,title){var b=el("button","n",label);b.type="button";
 b.addEventListener("click",function(e){e.preventDefault();e.stopPropagation();openDrill(kind,scope,title,b)});return b}
function keyOf(p){return "HIMMEL-"+p[0]}
function dots(n){var d=el("span","dots");d.setAttribute("role","img");d.setAttribute("aria-label","impact "+n+" of 5");d.title="impact "+n+" of 5";
 for(var i=1;i<=5;i++)d.appendChild(el("i",i<=n?"f":null));return d}
function chip(lg){var t=lg[0]+" · "+(lg[1]=="LIVE"&&lg[2]?"PR #"+lg[2]:lg[1]);var c=el("span","chip "+lg[1],t);c.title="leg "+lg[0]+", last marker "+lg[1]+(lg[2]?", PR "+lg[2]:"");return c}
function mark(p){var lg=M.leg(p),c=p[2]==2?"done":lg?"live":p[2]==1?"started":"todo",
 w={done:"done",live:"a leg is on it",started:"started in Jira, no leg",todo:"to do"}[c];var m=el("span","mk "+c);m.setAttribute("role","img");m.setAttribute("aria-label",w);m.title=w;return m}
function impactText(p,host){
 if(!p[9]){host.textContent=p[1];return host}
 var m=/^internal:\s*/i.exec(p[9]);if(m){add(host,el("span","int","Internal")," "+p[9].slice(m[0].length))}else host.textContent=p[9];return host}
function ticket(p){
 var d=el("details","tk"),s=el("summary"),tx=el("span","tx"),sub=el("span","sub"),tg=el("span","tg"),lg=M.leg(p);
 add(sub,el("code",null,keyOf(p)),p[9]?" · "+p[1]:null);sub.title=p[1];
 add(tx,impactText(p,el("span","ui")),sub);
 if(lg)tg.appendChild(chip(lg));if(p[10])add(tg,el("span","sz",p[10]));if(p[12]!=null)tg.appendChild(dots(p[12]));
 add(s,mark(p),tx,tg);d.appendChild(s);
 d.addEventListener("toggle",function(){if(d.open&&!d.dataset.f){d.dataset.f="1";d.appendChild(more(p))}});return d}
function more(p){
 var m=el("div","more"),u=el("ul");if(p[14])m.appendChild(el("p",null,p[14]));
 if(p[11]!=null)u.appendChild(el("li",null,"Ready to build: "+M.READY[p[11]]+" ("+p[11]+" of 4)."));
 if(p[10])u.appendChild(el("li",null,"Size "+p[10]+(p[6]?", about "+p[6]+" S-equivalents":"")+(p[15]?"; uses "+p[15].toFixed(3)+" of "+V[p[3]]+"'s budget":"")+"."));
 if(p[13])u.appendChild(el("li",null,"Planning slice only ("+p[13]+"): not ready enough to build, so "+V[p[3]]+" schedules the plan, not the fix."));
 u.appendChild(el("li",null,"Theme: "+T[p[5]]+" · kind: "+M.KIND[p[4]]+" · "+V[p[3]]+"."));
 if(p[7]==1)u.appendChild(el("li",null,"Jira names a different version than the plan."));
 if(p[7]==2)u.appendChild(el("li",null,"Not in the plan: Jira puts it in "+V[p[3]]+"."));
 var lg=M.leg(p);if(lg)u.appendChild(el("li",null,"Leg "+lg[0]+" is on it; its last marker is "+lg[1]+(lg[2]?", PR "+lg[2]:"")+"."));
 m.appendChild(u);
 if(p[8]&&p[8].length){var n=el("ul");p[8].forEach(function(i){var x=D.N[i],pa=D.DR[x[0]]+"/"+x[1],a=el("a",null,x[2]);
  a.href="obsidian://open?vault=luna&file="+encodeURIComponent(pa.replace(/\.md$/,""));a.title=pa;n.appendChild(add(el("li"),a))});
  add(m,el("p",null,"Vault notes that mention it:"),n)}
 return m}
function strip(t){var s=el("div","strip");s.setAttribute("role","img");
 s.setAttribute("aria-label",t.done+" done, "+t.live+" with a leg, "+(t.prog-t.live)+" started, "+t.todo+" to do");
 [["d",REM?0:t.done],["l",t.live],["s",t.prog-t.live]].forEach(function(x){if(x[1]>0){var i=el("i",x[0]);i.style.width=(100*x[1]/(t.n||1))+"%";s.appendChild(i)}});return s}
function capBar(ld){var c=el("div","cap");c.setAttribute("role","img");
 if(ld.deferred||ld.cap==null){c.className="cap none";c.setAttribute("aria-label","no cap");return c}
 // the P90 diamond sits where the cautious load falls against its own cap, drawn on the mean's scale.
 var q=ld.p90!=null&&ld.p90cap?ld.cap*ld.p90/ld.p90cap:null,sc=Math.max(ld.cap,ld.used,q||0)||1,f=el("i");f.style.width=(100*Math.min(ld.used,ld.cap)/sc)+"%";c.appendChild(f);
 if(ld.used>ld.cap){var o=el("i","o");o.style.left=(100*ld.cap/sc)+"%";o.style.width=(100*(ld.used-ld.cap)/sc)+"%";c.appendChild(o)}
 var k=el("b");k.style.left=(100*ld.cap/sc)+"%";c.appendChild(k);
 if(q!=null){var d=el("i",ld.p90>ld.p90cap+1e-9?"p9 x":"p9");d.style.left=(100*q/sc)+"%";c.appendChild(d)}
 c.setAttribute("aria-label","budget "+f2(ld.used)+" of "+f2(ld.cap)+(q!=null?", cautious "+f2(ld.p90)+" of "+f2(ld.p90cap):""));return c}
function capLine(i,ld){var l=el("div","cap-line");
 if(ld.deferred){add(l,"Deferred bucket: no cap. ",nb(f2(ld.used)+" budget","load",{v:i},V[i]+": budget by kind")," parked here.");return l}
 var over=ld.kinds.filter(function(k){return k.over});
 add(l,el("span",null,"Budget used "),nb(f2(ld.used)+(ld.cap!=null?" of "+f2(ld.cap):""),"load",{v:i},V[i]+": budget by kind"),
  el("span",null,pl(ld.planned,"planned ticket","planned tickets")+(ld.tcap!=null?" of a "+ld.tcap+" cap":"")));
 if(over.length)l.appendChild(el("span","x",over.map(function(k){return k.kind}).join(", ")+" over cap"));return l}
function headline(i,t){var h=el("h2","head");add(h,el("span","v",V[i])," — ");
 if(!t.left&&t.n){add(h,"shipped, ",nb(pl(t.n,"ticket","tickets"),"all",{v:i},V[i]+": every ticket"),".");return h}
 if(REM)add(h,nb(t.left+" left","left",{v:i},V[i]+": what is left"));
 else add(h,nb(t.left+" of "+t.n,"left",{v:i},V[i]+": what is left")," left");
 if(t.live)add(h,", ",nb(pl(t.live,"leg","legs"),"live",{v:i},V[i]+": legs on it now")," on it now");
 return add(h,".")}
// sumPara: the lead sentence, then each top group's best ticket quoted verbatim under its group's name.
function sumPara(sm,by){var f=document.createDocumentFragment(),u=el("ul","quotes");f.appendChild(el("p","sum",sm.lead));
 sm.quotes.forEach(function(q){if(q.text)u.appendChild(add(el("li"),el("b",null,by=="version"?V[q.p[3]]:T[q.p[5]]),q.text))});
 if(u.firstChild)f.appendChild(u);return f}
function counts(i,t){var l=el("div","cap-line");
 if(!REM&&t.done)l.appendChild(nb(t.done+" done ("+pct(t.done,t.n)+" %)","done",{v:i},V[i]+": done"));
 if(t.live)l.appendChild(nb(pl(t.live,"leg","legs")+" working","live",{v:i},V[i]+": legs on it now"));
 if(t.prog-t.live)l.appendChild(nb((t.prog-t.live)+" started, no leg","prog",{v:i},V[i]+": in progress"));
 l.appendChild(nb(t.todo+" to do","todo",{v:i},V[i]+": to do"));return l}
function ticketList(host,a,groupCol,groupName,cmp){
 var open=M.order(a.filter(function(p){return p[2]!=2})),done=M.order(a.filter(function(p){return p[2]==2})),g={},ks=[];
 open.forEach(function(p){var k=p[groupCol];if(!g[k]){g[k]=[];ks.push(k)}g[k].push(p)});
 ks.sort(cmp||function(x,y){return g[y].length-g[x].length||String(groupName(x)).localeCompare(String(groupName(y)))});
 ks.forEach(function(k){host.appendChild(add(el("h3","grp"),groupName(k),el("span",null,g[k].length+" left")));g[k].forEach(function(p){host.appendChild(ticket(p))})});
 if(done.length){var d=el("details","done-grp");d.appendChild(el("summary",null,done.length+" done ›"));
  d.addEventListener("toggle",function(){if(d.open&&!d.dataset.f){d.dataset.f="1";done.forEach(function(p){d.appendChild(ticket(p))})}});host.appendChild(d)}}
function versionBody(i,host){
 var a=M.inV(i,REM),t=M.tally(a),ld=M.load(i,REM);
 host.appendChild(sumPara(M.summary(a,"theme"),"theme"));
 var b=el("div","bars");add(b,strip(t),counts(i,t),capBar(ld),capLine(i,ld));host.appendChild(b);
 var w=a.filter(function(p){return M.leg(p)});
 if(w.length){host.appendChild(add(el("h3","grp"),"Working now",el("span",null,pl(w.length,"leg","legs"))));
  var ul=el("ul","work");w.forEach(function(p){ul.appendChild(add(el("li"),chip(M.leg(p)),impactText(p,el("span"))))});host.appendChild(ul)}
 ticketList(host,a,5,function(k){return T[k]})}
// The release desk: tiles, the decisions queue with its levers, the versions strip, what users gained.
var WI={},ALL=false,BAND=["Stops now","Blocks release","Queue health"];
function num(x){return x==null?"–":x===Math.round(x)?String(x):f2(x)}
function bw(b){return b.what+" "+num(b.used)+" of "+num(b.cap)}
function tile(lb,fig,sb,on,hot){var b=el("button",hot?"tile hot":"tile");b.type="button";add(b,el("span","lb",lb),el("span","fig",fig));
 if(sb!=null)b.appendChild(typeof sb=="string"?el("span","sb",sb):sb);b.addEventListener("click",function(){on(b)});return b}
function jump(id){var s=$(id);s.scrollIntoView({block:"start"});s.focus({preventScroll:true})}
function renderTiles(ds){var h=$("tiles"),cur=D.CUR;h.textContent="";
 if(cur!=null){var t=M.tally(M.inV(cur)),ld=M.load(cur),r=tile("Running",D.V[cur],t.done+" of "+t.n+" done · "+(ld.cap!=null?f2(ld.used)+" of "+f2(ld.cap)+" budget":"no cap"),
  function(b){openDrill("version",{v:cur},V[cur],b)});r.appendChild(capBar(ld));h.appendChild(r)}
 else h.appendChild(tile("Running","–","Every v1.0.x ticket is done.",function(){jump("gain")}));
 var lv=D.P.filter(function(p){return M.leg(p)}),ch=el("span","chips");
 lv.slice(0,3).forEach(function(p){ch.appendChild(chip(M.leg(p)))});if(lv.length>3)ch.appendChild(el("span","sb","+"+(lv.length-3)));
 var mv=tile("Moving now",pl(lv.length,"leg","legs"),lv.length?null:"No leg is on a ticket.",function(b){openDrill("live",{train:1},"Legs working now",b)});
 if(lv.length)mv.appendChild(ch);h.appendChild(mv);
 var tr=M.tally(M.inTrain());
 h.appendChild(tile("Gained",tr.done+" shipped",pct(tr.done,tr.n)+" % of the v1.0.x train",function(){jump("gain")}));
 var c=[0,0,0];ds.forEach(function(d){c[d.band]++});
 h.appendChild(tile("Needs your input",pl(ds.length,"decision","decisions"),BAND.map(function(n,j){return c[j]?c[j]+" "+n.toLowerCase():null}).filter(Boolean).join(" · ")||"Nothing waits on you.",
  function(){jump("dec")},c[0]+c[1]>0))}
// copyLine: the instruction to paste to the console. The page never acts on it.
function copyLine(lines){var w=el("div","copy"),pre=el("pre",null,lines.join("\n")),b=el("button","lv","Copy");b.type="button";
 b.addEventListener("click",function(){function sel(){var r=document.createRange();r.selectNodeContents(pre);var s=getSelection();s.removeAllRanges();s.addRange(r);b.textContent="Selected, press copy"}
  try{navigator.clipboard.writeText(pre.textContent).then(function(){b.textContent="Copied"},sel)}catch(e){sel()}});
 return add(w,pre,b)}
function wiTable(name,x,c){var tb=el("table","ld"),hr=el("tr");[name,"Now","After","Cap"].forEach(function(h){hr.appendChild(el("th",null,h))});tb.appendChild(hr);
 function row(lab,b,a,cap){var r=el("tr");add(r,el("td",null,lab),el("td",null,num(b)),el("td",cap==null||a==null?null:a>cap+1e-9?"ovr":"met",num(a)),el("td",null,cap==null?"no cap":num(cap)));tb.appendChild(r)}
 row("Planned",x.before.n,x.after.n,c?c.t:null);row("Mean",x.before.m,x.after.m,c?c.tot:null);row("P90 ≈",x.before.p9,x.after.p9,c?c.p9:null);return tb}
function verdict(name,b){return b.length?name+" still over: "+b.map(bw).join(", ")+".":name+": every cap met."}
function wiBox(w,fromName,toName){var box=el("div","wi"),two=el("div","two");
 add(two,wiTable(fromName,w.from,D.VC[w.from.i]),wiTable(toName,w.to,w.to.caps));box.appendChild(two);
 box.appendChild(el("p","fact",verdict(fromName,w.from.after.b)+" "+verdict(toName,w.to.after.b)));return box}
function lever(label,on,pressed,f){var b=el("button","lv",label);b.type="button";b.setAttribute("aria-pressed",pressed?"true":"false");b.dataset.f=f;b.addEventListener("click",on);return b}
function tline(p){return add(el("span","t"),el("code",null,keyOf(p))," ",p[9]?p[9].replace(/^internal:\s*/i,""):p[1])}
function toggle(a,k){var j=a.indexOf(k);if(j<0)a.push(k);else a.splice(j,1)}
// capCard: peel the lowest-return tickets to the trail or to v2/v3; each ticket's box keeps it here (pin) or releases a plan pin.
function capBody(d,li,id,paint){var i=d.i,st=WI[id]||(WI[id]={lv:null,keep:[],unpin:[]}),tr=M.trail(i),cut=D.V.indexOf("v2/v3");
 add(li,el("div","ctl",D.V[i]+" is over its cap"),el("div","fact",d.b.map(bw).join(" · ")));
 var lv=el("div","levers");function pick(k){return function(){st.lv=st.lv==k?null:k;paint("lv-"+k)}}
 if(tr)lv.appendChild(lever("Move to "+tr.name,pick("trail"),st.lv=="trail","lv-trail"));
 if(cut>=0&&cut!=i)lv.appendChild(lever("Cut to v2/v3",pick("cut"),st.lv=="cut","lv-cut"));
 lv.appendChild(lever("Open "+D.V[i],function(){openDrill("version",{v:i},V[i],this)},false,"lv-open"));li.appendChild(lv);
 if(!st.lv)return;
 var to=st.lv=="trail"?tr.i:cut,toName=st.lv=="trail"?tr.name:"v2/v3",pe=M.peel(i,{keep:st.keep,unpin:st.unpin}),box=wiBox(M.whatIf(i,pe.moved,to),D.V[i],toName);
 var seen={},rows=[];pe.moved.concat(M.inV(i).filter(function(p){return st.keep.indexOf(p[0])>=0||st.unpin.indexOf(p[0])>=0}),pe.held).forEach(function(p){if(!seen[p[0]]){seen[p[0]]=1;rows.push(p)}});
 if(rows.length){box.appendChild(el("h4",null,"What moves, lowest return first"));var ul=el("ul","fall");
  rows.forEach(function(p){var pin=M.pinned(p),cb=el("input"),lb=el("label"),f="cb-"+p[0],mv=pe.moved.indexOf(p)>=0;cb.type="checkbox";cb.dataset.f=f;
   cb.checked=pin?st.unpin.indexOf(p[0])<0:st.keep.indexOf(p[0])>=0;
   cb.addEventListener("change",function(){toggle(pin?st.unpin:st.keep,p[0]);paint(f)});add(lb,cb,pin?"pinned":"keep here");
   ul.appendChild(add(el("li"),lb,tline(p),el("span",mv?"ovr":"met",mv?"→ "+toName:"stays")))});box.appendChild(ul)}
 var lines=[];if(pe.moved.length&&to<0)lines.push("open trail "+toName);
 pe.moved.forEach(function(p){lines.push((st.lv=="cut"?"defer ":"move ")+keyOf(p)+" "+D.V[i]+" → "+toName)});
 st.keep.forEach(function(k){lines.push("pin HIMMEL-"+k+" "+D.V[i])});st.unpin.forEach(function(k){lines.push("unpin HIMMEL-"+k+" "+D.V[i])});
 if(!pe.moved.length)box.appendChild(el("p","fact","Nothing can move: every open ticket here is pinned, has a leg, or eases no broken cap."));
 if(lines.length)box.appendChild(copyLine(lines));li.appendChild(box)}
function one(p,li,f,label){li.appendChild(el("div","levers")).appendChild(lever(label||"Open the ticket",function(){openDrill("one",{k:p[0]},keyOf(p),this)},false,f))}
function body(d,li,id,paint){li.appendChild(el("span","band b"+d.band,BAND[d.band]));
 if(d.type=="cap")return capBody(d,li,id,paint);
 var st=WI[id]||(WI[id]={lv:null});function pick(k){return function(){st.lv=st.lv==k?null:k;paint("lv-"+k)}}
 if(d.type=="leg"){var lg=M.leg(d.p);add(li,el("div","ctl","Leg "+lg[0]+" is "+lg[1]+" on "+keyOf(d.p)),impactText(d.p,el("div","fact")));
  li.appendChild(el("p","fact","The leg waits on its console; its ruling unblocks "+D.V[d.p[3]]+"."));one(d.p,li,"lv-one");return}
 if(d.type=="drift"){var p=d.p,v=D.V[p[3]],lv=el("div","levers"),k=keyOf(p);
  add(li,el("div","ctl",p[7]==1?k+": the plan and Jira name different versions":k+": in Jira's "+v+", not in the plan"),impactText(p,el("div","fact")));
  var opts=p[7]==1?[["plan","Adopt plan","set-fixversion "+k+" "+v],["jira","Adopt Jira","place "+k]]:[["jira","Place in "+v,"place "+k+" "+v],["plan","Adopt plan","set-fixversion "+k+" none"]];
  opts.forEach(function(o){lv.appendChild(lever(o[1],pick(o[0]),st.lv==o[0],"lv-"+o[0]))});li.appendChild(lv);
  opts.forEach(function(o){if(st.lv==o[0])li.appendChild(add(el("div","wi"),el("p","fact",o[0]=="plan"?"Jira follows the plan; no budget moves.":"The plan follows Jira; the placer re-weighs "+v+"."),copyLine([o[2]])))});return}
 if(d.type=="fold"){var pr=M.parent(d.i),w=M.whatIf(d.i,d.f,pr);
  add(li,el("div","ctl",D.V[pr]+" can take back "+pl(d.f.length,"ticket","tickets")+" from "+D.V[d.i]),el("div","fact","Its caps hold with them; the best return comes first."));
  var fl=el("div","levers");fl.appendChild(lever("Fold back",pick("fold"),st.lv=="fold","lv-fold"));li.appendChild(fl);
  if(st.lv=="fold"){var bx=wiBox(w,D.V[d.i],D.V[pr]),ul=el("ul","fall");d.f.forEach(function(p){ul.appendChild(add(el("li"),el("span"),tline(p),el("span","met","→ "+D.V[pr])))});
   add(bx,ul,copyLine(d.f.map(function(p){return "move "+keyOf(p)+" "+D.V[d.i]+" → "+D.V[pr]})));li.appendChild(bx)}return}
 if(d.type=="unplaced"){add(li,el("div","ctl",pl(d.u.length,"open ticket has","open tickets have")+" no version"),el("div","fact","Parked or never placed: none of them counts against a cap."));
  var ul2=el("div","levers");ul2.appendChild(lever("Place",pick("place"),st.lv=="place","lv-place"));li.appendChild(ul2);
  if(st.lv=="place"){var b2=el("div","wi"),l2=el("ul","fall");d.u.forEach(function(x){l2.appendChild(add(el("li"),el("span"),add(el("span","t"),el("code",null,"HIMMEL-"+x[0])," ",x[1]),el("span","fact",x[3])))});
   add(b2,l2,copyLine(d.u.map(function(x){return "place HIMMEL-"+x[0]})));li.appendChild(b2)}}}
function card(d,id){var li=el("li","card");function paint(f){li.textContent="";body(d,li,id,paint);if(f){var x=li.querySelector('[data-f="'+f+'"]');if(x)x.focus()}}paint();return li}
function renderDecisions(ds){var ol=$("decl");ol.textContent="";$("dech").textContent="Needs your input · "+ds.length;
 if(!ds.length){ol.appendChild(el("li","card fact","Nothing needs a decision: every cap holds, no leg waits, Jira and the plan agree."));return}
 var id={};(ALL?ds:ds.slice(0,40)).forEach(function(d){var k=d.type+":"+d.i+":"+(d.p?d.p[0]:"");id[k]=(id[k]||0)+1;ol.appendChild(card(d,k+":"+id[k]))});
 if(!ALL&&ds.length>40){var b=el("button","lv","+"+(ds.length-40)+" more");b.type="button";b.addEventListener("click",function(){ALL=true;renderDecisions(ds)});ol.appendChild(add(el("li","card"),b))}}
// renderSteer: the running version's levers when no cap forces one. Tick tickets (lowest return first) to see what moving
// them to the trail or cutting them to v2/v3 would change, and the line that asks the console to do it.
var STEER={to:"trail",sel:[],all:false};
function renderSteer(f){var h=$("steerb"),i=D.CUR;h.textContent="";if(i==null){$("steer").hidden=true;return}
 var tr=M.trail(i),cut=D.V.indexOf("v2/v3"),lv=el("div","levers"),to=STEER.to=="cut"&&cut>=0?cut:tr?tr.i:-1,toName=STEER.to=="cut"&&cut>=0?"v2/v3":tr?tr.name:"";
 $("steerh").textContent="Steer "+D.V[i];
 function pick(k){return function(){STEER.to=k;renderSteer("lv-"+k)}}
 if(tr)lv.appendChild(lever("Move to "+tr.name,pick("trail"),STEER.to=="trail","lv-trail"));
 if(cut>=0&&cut!=i)lv.appendChild(lever("Cut to v2/v3",pick("cut"),STEER.to=="cut","lv-cut"));
 add(h,el("p","fact","Take work out of "+D.V[i]+" to ship it sooner. Lowest return (impact per size) first; tickets with a leg on them stay."),lv);
 var c=M.inV(i).filter(function(p){return p[2]!=2&&p[7]!=2&&!M.leg(p)}).sort(function(x,y){return M.roi(x)-M.roi(y)||(y[6]||0)-(x[6]||0)||x[0]-y[0]}),
  sel=c.filter(function(p){return STEER.sel.indexOf(p[0])>=0}),ul=el("ul","fall");
 (STEER.all?c:c.slice(0,8)).forEach(function(p){var cb=el("input"),lb=el("label"),k="st-"+p[0],on=STEER.sel.indexOf(p[0])>=0;cb.type="checkbox";cb.dataset.f=k;cb.checked=on;
  cb.addEventListener("change",function(){toggle(STEER.sel,p[0]);renderSteer(k)});add(lb,cb,"move");
  ul.appendChild(add(el("li"),lb,tline(p),el("span",on?"ovr":"fact",on?"→ "+toName:(M.pinned(p)?"pinned · ":"")+(p[10]||""))))});h.appendChild(ul);
 if(!STEER.all&&c.length>8){var m=lever("+"+(c.length-8)+" more",function(){STEER.all=true;renderSteer("lv-more")},false,"lv-more");h.appendChild(add(el("div","levers"),m))}
 if(!sel.length){h.appendChild(el("p","fact","Tick a ticket to see what the move would change."))}
 else{var box=wiBox(M.whatIf(i,sel,to),D.V[i],toName),lines=[];if(to<0)lines.push("open trail "+toName);
  sel.forEach(function(p){if(M.pinned(p))lines.push("unpin "+keyOf(p)+" "+D.V[i]);lines.push((STEER.to=="cut"?"defer ":"move ")+keyOf(p)+" "+D.V[i]+" → "+toName)});
  box.appendChild(copyLine(lines));h.appendChild(box)}
 if(f){var x=h.querySelector('[data-f="'+f+'"]');if(x)x.focus()}}
// renderVers: the first 12 rows from the running version on, plus any version over a cap; the rest behind one button.
var VALL=false;
function renderVers(){var h=$("vlist"),shown=0,hid=0;h.textContent="";
 V.forEach(function(_,i){var a=M.inV(i,REM),t=M.tally(a),ld=M.load(i,REM),tr=M.parent(i)>=0;if(!a.length&&REM)return;
  var bx=M.breaches(i,M.stats(i,M.inV(i)));if(!VALL&&shown>=12&&!bx.length){hid++;return}shown++;
  var b=el("button",tr?"vrow trail":"vrow"),nm=el("span","nm"),fg=el("span","fg");b.type="button";
  if(i===D.CUR){var cd=el("span","cur-dot");cd.title="running";nm.appendChild(cd)}add(nm,(tr?"↳ ":"")+D.V[i]);
  add(fg,t.left?t.left+" left":"shipped");if(t.live)add(fg," · "+pl(t.live,"leg","legs"));if(bx.length)add(fg," · ",el("span","x",bx.map(function(x){return x.what}).join(", ")+" over"));
  add(b,nm,capBar(ld),fg);b.addEventListener("click",function(){openDrill("version",{v:i},V[i],b)});h.appendChild(b)});
 if(hid){var m=el("button","lv vmore","Show "+pl(hid,"later version","later versions"));m.type="button";m.addEventListener("click",function(){VALL=true;renderVers()});h.appendChild(m)}}
function renderGains(){var h=$("gains");h.textContent="";
 var g=M.gains().sort(function(x,y){return y.done.filter(M.isUser).length-x.done.filter(M.isUser).length||y.done.length-x.done.length||x.i-y.i}).slice(0,4);
 if(!g.length){h.appendChild(el("p","fact","Nothing has shipped on the v1.0.x train yet."));return}
 g.forEach(function(x){var c=el("article","gain"),u=el("ul");
  add(c,el("h3",null,D.V[x.i]),add(el("p","gl"),nb(x.done.length+" of "+x.n+" done","done",{v:x.i},V[x.i]+": done"),". "+x.s.lead));
  x.done.filter(M.isUser).slice(0,3).forEach(function(p){u.appendChild(el("li",null,p[9]))});if(u.firstChild)c.appendChild(u);h.appendChild(c)})}
function renderPvj(){var a=M.inTrain(REM),dr=a.filter(function(p){return p[7]==1}),off=a.filter(function(p){return p[7]==2&&p[2]!=2}),b=$("pvjb");
 $("pvjs").textContent="Plan vs Jira: "+(dr.length+off.length?(dr.length+off.length)+" differ ›":"they agree");b.textContent="";
 if(dr.length){b.appendChild(el("p",null,pl(dr.length,"ticket is","tickets are")+" planned for one version while Jira names another."));M.order(dr).forEach(function(p){b.appendChild(ticket(p))})}
 if(off.length){b.appendChild(el("p",null,pl(off.length,"open ticket sits","open tickets sit")+" in a version in Jira but not in the plan."));M.order(off).forEach(function(p){b.appendChild(ticket(p))})}}
function render(){var ds=M.decisions();renderTiles(ds);renderDecisions(ds);renderSteer();renderVers();renderGains();renderPvj()}
// drawer: numbers open it; focus moves in, Tab is trapped, Esc closes and focus returns to the number that opened it.
function openDrill(kind,scope,title,from){
 var db=$("db");db.textContent="";$("dh").textContent=title;if($("drawer").hidden)opener=from;
 if(kind=="load")loadView(scope.v,db);
 else if(kind=="version"){db.appendChild(headline(scope.v,M.tally(M.inV(scope.v,REM))));versionBody(scope.v,db)}
 else if(kind=="one")D.P.filter(function(p){return p[0]==scope.k}).forEach(function(p){var t=ticket(p);t.open=true;db.appendChild(t)});
 else{var a=M.drill(kind,scope,REM);
  db.appendChild(el("p","note",pl(a.length,"ticket","tickets")+(REM?", done ones hidden":"")+"."));a.forEach(function(p){db.appendChild(ticket(p))})}
 $("scrim").hidden=false;$("drawer").hidden=false;$("main").inert=true;document.querySelector(".mast").inert=true;$("dh").focus()}
function closeDrill(){if($("drawer").hidden)return;$("drawer").hidden=true;$("scrim").hidden=true;$("main").inert=false;document.querySelector(".mast").inert=false;
 if(opener&&document.contains(opener))opener.focus();opener=null}
function loadView(i,db){var ld=M.load(i,REM),tb=el("table","ld"),hr=el("tr");
 ["Kind","Used","Cap","Headroom"].forEach(function(x){hr.appendChild(el("th",null,x))});tb.appendChild(hr);
 ld.kinds.forEach(function(k){var r=el("tr",k.over?"x":null);[k.kind,f2(k.used),k.cap==null?"no cap":f2(k.cap),k.head==null?"–":f2(k.head)].forEach(function(x){r.appendChild(el("td",null,x))});tb.appendChild(r)});
 var tr=el("tr");[ "total",f2(ld.used),ld.cap==null?"no cap":f2(ld.cap),ld.cap==null?"–":f2(ld.cap-ld.used)].forEach(function(x){tr.appendChild(el("td",null,x))});tb.appendChild(tr);
 add(db,el("p","note",(ld.deferred?"Deferred bucket: no caps apply. ":"Caps are "+V[i]+"'s own, overrides included. ")+pl(ld.planned,"planned ticket","planned tickets")+(ld.tcap!=null?" of a "+ld.tcap+"-ticket cap":"")+(REM?"; done tickets left out.":".")),tb);
 if(ld.p90!=null)add(db,add(el("p","note"),el("b",null,"Likely load "),f2(ld.used)+(ld.cap!=null?" of "+f2(ld.cap):"")+": the average outcome. ",
  el("b",null,"Cautious load "),f2(ld.p90)+(ld.p90cap!=null?" of "+f2(ld.p90cap):"")+": 9 times in 10 the work lands at or under this"+(REM?" (as planned, done tickets included).":".")));
 ld.kinds.forEach(function(k){if(!k.tickets.length)return;var d=el("details","fold");d.open=k.over;
  d.appendChild(el("summary",null,k.kind+": "+pl(k.tickets.length,"ticket","tickets")+", "+f2(k.used)+(k.cap!=null?" of "+f2(k.cap):"")+" ›"));
  var ol=el("ol","ct");k.tickets.forEach(function(p){var li=el("li"),t=el("span","t");add(t,el("code",null,keyOf(p))," ",p[9]?p[9].replace(/^internal:\s*/i,""):p[1]);t.title=p[9]||p[1];
   add(li,t,el("span","v",M.ld(p).toFixed(3)+" · "+pct(M.ld(p),ld.used)+" %"));ol.appendChild(li)});d.appendChild(ol);db.appendChild(d)})}
document.addEventListener("keydown",function(e){if($("drawer").hidden)return;
 if(e.key=="Escape"){e.preventDefault();closeDrill();return}
 if(e.key!="Tab")return;var f=[].slice.call($("drawer").querySelectorAll("button,summary,a[href],[tabindex]")).filter(function(x){return x.offsetParent!==null||x===$("dh")});
 if(!f.length)return;var i=f.indexOf(document.activeElement);
 if(e.shiftKey&&i<=0){e.preventDefault();f[f.length-1].focus()}else if(!e.shiftKey&&i==f.length-1){e.preventDefault();f[0].focus()}});
$("dx").addEventListener("click",closeDrill);$("scrim").addEventListener("click",closeDrill);
$("rem").addEventListener("change",function(){REM=this.checked;render()});
var TK="hrt-theme";function applyTheme(m){if(m)document.documentElement.setAttribute("data-theme",m);else document.documentElement.removeAttribute("data-theme")}
try{applyTheme(localStorage.getItem(TK))}catch(e){}
$("theme").addEventListener("click",function(){var dk=getComputedStyle(document.documentElement).colorScheme=="dark",m=dk?"light":"dark";applyTheme(m);try{localStorage.setItem(TK,m)}catch(e){}});
$("stamp").textContent="Rendered "+D.gen+" · Jira "+D.mir+" · plan @"+D.sha;
$("prov").textContent="Status is read from the Jira mirror, and a leg with a held queue lock counts its ticket as in progress. Impact text, sizes, readiness and budgets come from the roadmap plan.";
(function(){var t=$("terms"),mk=function(c){return el("span","mk "+c)};
 [["Status",[mk("done"),"done · ",mk("live"),"a leg is on it · ",mk("started"),"started in Jira, no leg · ",mk("todo"),"to do"]],
  ["Leg chip",["N123 · LIVE: the leg's label and its last marker (or its PR number while it is live)."]],
  ["Size",["The plan's T-shirt estimate, low–high. In S-equivalents: "+D.EQ+"."]],
  ["Impact",[dots(4)," how much it hurts today, 1 cosmetic to 5 blocks a release. A secondary tag: the sentence is the impact."]],
  ["Ready to build",["0 no plan yet · 1 problem stated · 2 fix named, not yet checked · 3 plan audited · 4 spec ready. Below 3 a version schedules only a planning slice."]],
  ["Budget",[capBar({used:.45,cap:.6,kinds:[]})," used of the version's cap; the tick is the cap, orange is over it."]],
  ["No cap",[capBar({deferred:true})," ","no cap — deferred bucket"]],
  ["Remaining only",["Hides done tickets everywhere; every count, budget and summary is recomputed from what is left."]]
 ].forEach(function(x){t.appendChild(el("dt",null,x[0]));var d=el("dd");x[1].forEach(function(c){add(d,c)});t.appendChild(d)})})();
D.CAP.text.forEach(function(x){$("rules").appendChild(el("p",null,x))});
render();
})();
</script>
'''

if __name__ == '__main__':
    main()
