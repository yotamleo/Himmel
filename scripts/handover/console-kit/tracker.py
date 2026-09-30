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
VER_RE = re.compile(r'^v1\.0\.(\d+)$')
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
    """The stage1/stage2 row-field files and the placer (layer caps) the page reads (HIMMEL-3957)."""
    return (sorted(glob.glob(os.path.join(ROOT, 'stage1', 'C??.tsv'))) +
            sorted(glob.glob(os.path.join(ROOT, 'stage1', 'C??.explain.tsv'))) +
            sorted(glob.glob(os.path.join(ROOT, 'stage2', 'C??.tsv'))) +
            [p for p in [os.path.join(ROOT, 'tools', 'stage3', 'place.py')] if os.path.exists(p)])


def fingerprint():
    """16 hex over the mirror's newest `updated:` and the plan + stage1/stage2 files' bytes (what the page shows)."""
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
    return h.hexdigest()[:16]


def plan_rules(meta):
    """Capacity rules as the plan records them: meta.json notes + the placer's CAPS. None = not recorded."""
    txt = ' '.join(n for n in meta.get('notes', []) if isinstance(n, str))

    def val(pat):
        m = re.search(pat, txt)
        return float(m.group(1)) if m else None
    sm = re.search(r'S-eq:\s*XS\s*([\d.]+)\s+S\s+([\d.]+)\s+M\s+([\d.]+)\s+L\s+([\d.]+)\s+XL\s+([\d.]+)', txt)
    caps = None
    try:
        m = re.search(r'^CAPS\s*=\s*(\{[^}]*\})', open(os.path.join(ROOT, 'tools', 'stage3', 'place.py'),
                                                       encoding='utf-8').read(), re.M)
        caps = ast.literal_eval(m.group(1)) if m else None
    except (OSError, ValueError, SyntaxError):
        pass
    return dict(tickets=val(r'ticket count\s*<\s*(\d+)'), total=val(r'total load within\s*([\d.]+)'),
                per=val(r'effort_mid\s*x\s*([\d.]+)'), seq=[float(x) for x in sm.groups()] if sm else None,
                layers=caps if isinstance(caps, dict) else None)


def capacity_text(r, deferred):
    """Plain-language cap panel lines; a rule the plan does not record says so instead of guessing."""
    nr = 'not recorded in the plan'
    parts = ['at most %d tickets' % r['tickets'] if r['tickets'] is not None else 'a ticket cap ' + nr,
             'at most %g bank of load' % r['total'] if r['total'] is not None else 'a load cap ' + nr]
    out = ['Each v1.0.x version holds ' + ' and '.join(parts) + '; the plan puts every ticket in the earliest version with room.']
    lc = r['layers']
    out.append('Layer caps, in bank: ' + ' · '.join('%s %.2f' % (l, lc[l]) for l in LAYERS if l in lc) + '.'
               if lc else 'Layer caps: ' + nr + '.')
    out.append('Load = effort in S-equivalents × %g bank; a plan-first ticket counts only its slice.' % r['per']
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
    out = [line('Running now: %s — ' % vers[cur], {cur}) if cur is not None
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
    ap.add_argument('--handovers', default='', help='handover tree to grep (default <luna-root>/handovers/yotamleo/himmel)')
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
    vrows = read_tsv(os.path.join(S, 'versions.tsv'))[1]
    vers = [r['version'] for r in vrows]
    vidx = {v: i for i, v in enumerate(vers)}
    vload = [[round(float(r['load_' + l] or 0), 3) for l in
              ('bugs', 'enhancements', 'features', 'misc', 'audit')] +
             [round(float(r['load_total'] or 0), 3), round(float(r['est_legs'] or 0), 1)] for r in vrows]
    theme, impact, uimp, ready, erange = {}, {}, {}, {}, {}
    for p in sorted(glob.glob(os.path.join(ROOT, 'stage1', 'C??.tsv'))):
        for r in read_tsv(p)[1]:
            theme[r['key']] = r.get('theme', '') or '(no theme)'
            if (r.get('impact') or '').isdigit():
                impact[r['key']] = int(r['impact'])
    # HIMMEL-3957 row fields: user-facing impact (stage1 explain), readiness + T-shirt range (stage2).
    for p in sorted(glob.glob(os.path.join(ROOT, 'stage1', 'C??.explain.tsv'))):
        for r in read_tsv(p)[1]:
            uimp[r['key']] = clip(r.get('user_impact') or '', 170)
    for p in sorted(glob.glob(os.path.join(ROOT, 'stage2', 'C??.tsv'))):
        for r in read_tsv(p)[1]:
            if (r.get('readiness') or '').isdigit():
                ready[r['key']] = int(r['readiness'])
            lo, hi = r.get('effort_low') or '', r.get('effort_high') or ''
            if lo or hi:
                erange[r['key']] = lo if lo == hi or not hi else hi if not lo else lo + '–' + hi

    def fields(k, sl=''):
        return [uimp.get(k, ''), erange.get(k, ''), ready.get(k), impact.get(k), sl]
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
                    fields(k, (r.get('slice_effort') or 'S') if r.get('commit') == 'plan-first' else ''))
    n_plan = len(rows)
    for k, m in mir.items():
        if k in planned:
            continue
        hit = [v for v in m['fv'] if VER_RE.match(v) and v in vidx]
        if hit:
            rows.append([num(k), clip(m['title'], 62), m['st'], vidx[hit[0]],
                         0 if m['type'] == 'Bug' else 3, tidx.get(theme.get(k), tidx['(unplanned)']),
                         0, 2, []] + fields(k))
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
    rules = plan_rules(meta)
    lg, cur = ledger_lines(rows, vers)
    seq = rules['seq']
    data = dict(gen=datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC'), mir=upd[:16].replace('T', ' '),
                sha=meta.get('main_sha_at_build', '')[:9], V=vers, VL=vload, L=LAYERS, T=themes, P=rows,
                U=unpl, DR=dirs, N=notes, LG=lg, CUR=cur,
                CAP=dict(total=rules['total'], layers=[(rules['layers'] or {}).get(l) for l in LAYERS],
                         text=capacity_text(rules, [v for v in vers if not VER_RE.match(v)])),
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


TEMPLATE = r'''<title>Himmel Roadmap Tracker</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Barlow+Condensed:wght@500;700&family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans:wght@400;600&display=swap">
<style>
/* design plan: release-train dispatch board. Fonts: display = condensed signage, body = plain sans, mono = keys/paths only.
   Colors: cool paper/ink neutrals + one rail-blue accent; semantic done / in-progress / to-do / drift kept apart from the
   accent; five categorical layer hues (--l*, CVD-validated, no status hue reused) and a separate one-hue slate ramp
   for load vs cap (--ld*). Layout: ledger line and version rail first, tabs per version, facets before board. */
:root{--bg:#eef1f4;--panel:#fff;--ink:#101c28;--mute:#566574;--line:#cfd7de;--accent:#0b5cad;--accent-ink:#fff;
--done:#1f8a4c;--prog:#d98a00;--todo:#aab6c2;--drift:#c2255c;--l1:#e87ba4;--l2:#2a78d6;--l3:#eb6834;--l4:#4a3aa7;--l5:#0e9aa7;--ld1:#7b8da0;--ld2:#4f6377;--ld3:#26384a;
--f-disp:"Barlow Condensed","Arial Narrow","Helvetica Neue",Arial,sans-serif;--f-body:"IBM Plex Sans",system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;--f-mono:"IBM Plex Mono",ui-monospace,"SFMono-Regular",Menlo,Consolas,monospace}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#0d151d;--panel:#152230;--ink:#e6edf3;--mute:#93a3b3;--line:#2a3b4c;--accent:#5aa9f0;--accent-ink:#06121e;
--done:#3fbf76;--prog:#f0a830;--todo:#4a5d70;--drift:#ff6b9a;--l1:#d55181;--l2:#3987e5;--l3:#d95926;--l4:#9085e9;--l5:#1aa3ae;--ld1:#6f8599;--ld2:#9fb3c7;--ld3:#d0dde9;color-scheme:dark}}
:root[data-theme="dark"]{--bg:#0d151d;--panel:#152230;--ink:#e6edf3;--mute:#93a3b3;--line:#2a3b4c;--accent:#5aa9f0;--accent-ink:#06121e;
--done:#3fbf76;--prog:#f0a830;--todo:#4a5d70;--drift:#ff6b9a;--l1:#d55181;--l2:#3987e5;--l3:#d95926;--l4:#9085e9;--l5:#1aa3ae;--ld1:#6f8599;--ld2:#9fb3c7;--ld3:#d0dde9;color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 var(--f-body);padding-inline:16px;padding-block:20px 48px;font-variant-numeric:tabular-nums}
::selection{background:var(--accent);color:var(--accent-ink)}
.wrap{max-width:1180px;margin-inline:auto}
h1,h2,h3{font-family:var(--f-disp);text-transform:uppercase;letter-spacing:.04em;margin:0}
h1{font-size:34px;line-height:1}h2{font-size:21px;margin-block:30px 10px}h3{font-size:16px;margin-block:0 8px}
.key,code{font-family:var(--f-mono)}
.stamp{color:var(--mute);font-size:12.5px;margin-block:6px 14px}
.ledger{margin:0;font-size:16px;max-width:75ch}.ledger b{font-weight:600}
.ledger .d{color:var(--done)}.ledger .p{color:var(--prog)}.ledger .x{color:var(--drift)}
.overall{display:flex;height:12px;margin-block:10px 0;background:var(--todo)}.overall i{display:block}
.seg-d{background:var(--done)}.seg-p{background:var(--prog)}.seg-t{background:var(--todo)}
.filters{display:flex;flex-wrap:wrap;gap:8px;margin-block:16px 0}
select,input[type=search],button{font:inherit;color:var(--ink);background:var(--panel);border:1px solid var(--line);padding:6px 10px;border-radius:2px;min-width:0}
input[type=search]{flex:1 1 180px}
button{cursor:pointer}
:focus-visible{outline:3px solid var(--accent);outline-offset:2px}
.tabs{display:flex;gap:2px;overflow-x:auto;border-bottom:2px solid var(--ink);margin-block:20px 14px;scrollbar-width:thin;scrollbar-color:var(--todo) transparent}
.tabs button{flex:none;border:0;background:none;font:600 16px var(--f-disp);text-transform:uppercase;letter-spacing:.05em;padding:8px 12px 7px;color:var(--mute);position:relative;border-radius:0}
.tabs button[aria-selected=true]{background:var(--ink);color:var(--bg)}
.tabs button .m{position:absolute;left:0;bottom:0;height:3px;background:var(--done)}
.tabs button.cur::after{content:"";position:absolute;right:4px;top:5px;width:6px;height:6px;background:var(--accent)}
.rail{overflow-x:auto;border:1px solid var(--line);background:var(--panel);padding:10px 8px 0}
.train{display:flex;gap:4px;align-items:flex-end;width:max-content;border-bottom:3px solid var(--ink)}
.car{all:unset;box-sizing:border-box;cursor:pointer;width:36px;text-align:center;padding-block:2px 0}
.car:focus-visible{outline:3px solid var(--accent);outline-offset:1px}
.car .bar{display:flex;flex-direction:column-reverse;height:96px}
.car small{display:block;font:11px var(--f-mono);color:var(--mute);padding-block:4px}
.car.cur small{color:var(--accent);font-weight:600}
.legend{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:12.5px;color:var(--mute);margin-block:8px}
.legend i{display:inline-block;width:10px;height:10px;margin-inline-end:5px}
.facets{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:20px;margin-block:16px 22px}
.facets>div{min-width:0}
.board{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}
@media(max-width:760px){.board{grid-template-columns:minmax(0,1fr)}}
.col{min-width:0;background:var(--panel);border:1px solid var(--line);border-top:4px solid var(--todo)}
.col.p{border-top-color:var(--prog)}.col.d{border-top-color:var(--done)}
.col h3{padding:8px 10px 0}
.card{padding:8px 10px;border-top:1px solid var(--line);min-width:0}
.card .t{overflow-wrap:anywhere;font-size:13.5px}
.meta{display:flex;flex-wrap:wrap;gap:4px 8px;align-items:center;font-size:11.5px;color:var(--mute);margin-block-start:3px}
.key{font-size:12px;font-weight:600;color:var(--ink)}
.chip{display:inline-block;padding:0 6px;border-radius:2px;font-size:11px;line-height:17px;border:1px solid currentColor}
.chip.drift{color:var(--drift);font-weight:600}
.chip.l{color:var(--ink);border-color:var(--line)}.chip.l::before{content:"";display:inline-block;width:7px;height:7px;margin-inline-end:4px;background:var(--c)}
.card details{border:0;margin:4px 0 0;padding:0;background:none}
.card summary{font:11px var(--f-mono);text-transform:none;letter-spacing:0;padding:0;display:inline-block;color:var(--accent)}
.nt{margin-block:6px 0;font-size:12px;min-width:0}
.nt code{display:block;font-size:11px;color:var(--mute);overflow-wrap:anywhere;user-select:all}
.nt .ti{overflow-wrap:anywhere}
.more{margin:8px 10px}
.unp{margin-block-start:16px;background:var(--panel);border:1px solid var(--line);padding:6px 10px 10px}
.row{display:flex;flex-wrap:wrap;gap:2px 10px;padding-block:4px;border-top:1px solid var(--line);align-items:baseline;min-width:0}
.row .t{flex:1 1 220px;min-width:0;overflow-wrap:anywhere;font-size:13px}
.st{display:inline-block;width:9px;height:9px;border-radius:50%;flex:none}
.st0{background:var(--todo)}.st1{background:var(--prog)}.st2{background:var(--done)}
.chart{overflow-x:auto;border:1px solid var(--line);background:var(--panel);padding:10px 8px 0}
.lcols{display:flex;gap:4px;align-items:flex-end;width:max-content;position:relative;border-bottom:3px solid var(--ink)}
.lcol{width:36px;text-align:center}.lcol .bar{display:flex;flex-direction:column-reverse;height:110px}
.lcol small{display:block;font:11px var(--f-mono);color:var(--mute);padding-block:4px}
.cap{position:absolute;left:0;right:0;border-top:2px dashed var(--ink);pointer-events:none}
.cap span{position:absolute;right:0;top:-18px;font:11px var(--f-mono);color:var(--ink);background:var(--panel);padding-inline:3px}
.hbar{display:flex;height:20px;margin-block:6px;background:var(--todo)}.hbar i{display:block}
.load{position:relative;height:20px;background:var(--bg);border:1px solid var(--line);margin-block:6px 4px;overflow:visible}
.load i{display:block;position:absolute;top:0;bottom:0}
.load b{position:absolute;top:-4px;bottom:-4px;border-left:2px dashed var(--ink)}
.lrow{display:grid;grid-template-columns:minmax(0,7.5em) minmax(0,1fr) auto;gap:8px;align-items:center;font-size:12px;color:var(--mute)}
.lrow .load{height:10px;margin:3px 0}.lrow b{font-weight:400}
.capbox{background:var(--panel);border:1px solid var(--line);padding:6px 12px;margin-block:0 10px;font-size:13px;max-width:75ch}
.capbox p{margin:4px 0}
.card .ui{font-size:12.5px;color:var(--mute);overflow-wrap:anywhere;margin-block-start:2px}
.fx{font:11px var(--f-mono);color:var(--ink)}
.chip.off{color:var(--mute)}.chip.pf{color:var(--accent)}
.ledger p{margin:0 0 3px}.ledger p:first-child{font-weight:600}.ledger .x{color:var(--drift)}
.lg{display:grid;grid-template-columns:minmax(0,10em) minmax(0,1fr);gap:4px 14px;margin:0 0 10px;font-size:13px}
.lg dt{font-weight:600}.lg dd{margin:0;min-width:0;overflow-wrap:anywhere;color:var(--mute)}
.lg .sw{display:inline-block;width:10px;height:10px;margin-inline:0 4px;vertical-align:baseline}
@media(max-width:600px){.lg{grid-template-columns:minmax(0,1fr)}.lg dd{margin-block-end:6px}}
.heat{overflow-x:auto;border:1px solid var(--line);background:var(--panel)}
.heat table{border-collapse:collapse;font-size:11.5px}
.heat th{font:400 11px var(--f-mono);color:var(--mute);padding:3px 2px}
.heat th.tn{text-align:start;font:600 12px var(--f-body);color:var(--ink);padding:3px 10px;white-space:nowrap;position:sticky;left:0;background:var(--panel)}
.heat td{width:30px;min-width:30px;height:26px;text-align:center;padding:0;border:1px solid var(--bg);cursor:pointer;color:var(--ink)}
.heat td.z{cursor:default}
.plist .r{display:grid;grid-template-columns:minmax(90px,200px) minmax(0,1fr) 62px;gap:10px;align-items:center;padding-block:3px;border-top:1px solid var(--line);font-size:13px}
.plist .r span{min-width:0;overflow-wrap:anywhere}
.plist .b{display:flex;height:10px;background:var(--todo)}.plist .b i{display:block}
.burn{overflow-x:auto;border:1px solid var(--line);background:var(--panel)}
.burn svg{display:block;min-width:600px;width:100%;height:auto}
.burn text{font:11px var(--f-mono);fill:var(--mute)}
details.sec{background:var(--panel);border:1px solid var(--line);margin-block:10px;padding:0 12px}
details.sec>summary{cursor:pointer;padding-block:10px;font:600 17px var(--f-disp);text-transform:uppercase;letter-spacing:.05em}
.flag{font:11px var(--f-mono);color:var(--mute)}
.note{color:var(--mute);font-size:12.5px}
@media(prefers-reduced-motion:no-preference){.car .bar div{transition:height .2s}}
</style>
<div class="wrap">
<h1>Himmel Roadmap Tracker</h1>
<p class="stamp" id="stamp"></p>
<div class="ledger" id="ledger"></div>
<div class="overall" id="overall" role="img"></div>
<details class="sec" open><summary>How to read this page</summary>
<dl class="lg">
<dt>Status</dt><dd><span class="st st2"></span> done · <span class="st st1"></span> in progress · <span class="st st0"></span> to do, read from Jira when the page was generated.</dd>
<dt>Readiness 0–4</dt><dd>How ready the fix is to build: 0 no plan yet · 1 problem stated · 2 fix named, not yet checked · 3 plan audited · 4 audited, with dependencies, risks and acceptance written down. Below 3 only a small planning slice is scheduled.</dd>
<dt>Impact 1–5</dt><dd>How much it hurts today: 1 cosmetic or docs · 2 friction on a rare path · 3 daily friction · 4 a gate or guard reports the wrong thing · 5 blocks a release, loses data or allows an unsafe action.</dd>
<dt>Effort XS–XL</dt><dd>The plan's low–high T-shirt estimate. In S-equivalents: <span id="eqs"></span>.</dd>
<dt>Layers</dt><dd id="lgl"></dd>
<dt>drift</dt><dd>Planned for this version, but Jira's fixVersion names another one.</dd>
<dt>off-plan</dt><dd>In this version in Jira, but not in the roadmap plan. Done off-plan work still counts toward the version.</dd>
<dt>plan first</dt><dd>Readiness below 3: this version schedules only a planning slice (XS or S), not the whole fix.</dd>
<dt>vault notes</dt><dd>Luna vault notes that mention the ticket (cached text match, may miss some). Not a readiness signal.</dd>
</dl></details>
<div class="filters" role="group" aria-label="filters">
<select id="fTheme" aria-label="theme"></select><select id="fLayer" aria-label="layer"></select>
<input type="search" id="fQ" placeholder="search key or title" aria-label="search"><button id="fClr">Clear</button></div>
<div class="tabs" role="tablist" id="tabs" aria-label="versions"></div>
<div id="pane"></div>
<p class="note">Status is read from the Jira mirror at generation time; plan fields (impact, effort, readiness, caps) come from the roadmap plan.</p>
</div>
<script type="application/json" id="data">__DATA__</script>
<script>
(function(){
var D=JSON.parse(document.getElementById("data").textContent);
var V=D.V,L=D.L,T=D.T,P=D.P,LC=["--l1","--l2","--l3","--l4","--l5"],LD=["--ld1","--ld2","--ld3"],CAP=D.CAP.total,LAST=V.length-1;
function ldc(n,c){return "var("+LD[!c?1:n<c*.5?0:n<c*.8?1:2]+")"}
var K="hrt3882",S={tab:"",th:"",ly:"",q:""},cap={0:40,1:40,2:40};
function $(i){return document.getElementById(i)}
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!=null)e.textContent=x;return e}
function svg(t,a){var e=document.createElementNS("http://www.w3.org/2000/svg",t);for(var k in a)e.setAttribute(k,a[k]);return e}
function tid(v){return v.replace("/","-")}
function lab(i){return i==LAST?"v2/3":V[i].replace("v1.0.","")}
try{var s=JSON.parse(localStorage.getItem(K)||"{}");for(var k in s)if(k in S)S[k]=s[k]}catch(e){}
function save(){try{localStorage.setItem(K,JSON.stringify(S))}catch(e){}}
function tally(a){var r=[0,0,0];a.forEach(function(p){r[p[2]]++});return r}
function inV(i){return P.filter(function(p){return p[3]==i})}
var cur=D.CUR,sel=cur==null?LAST:cur;  // cur is null once the whole train is done; sel is only the default tab
function tabIndex(id){if(id==="overview")return -2;for(var i=0;i<V.length;i++)if(tid(V[i])===id)return i;return -1}
var h="";try{h=decodeURIComponent(location.hash.replace(/^#/,""))}catch(e){}
if(tabIndex(h)==-1)h=S.tab;if(tabIndex(h)==-1)h=tid(V[sel]);S.tab=h;
function setTab(id){S.tab=id;save();try{history.replaceState(null,"","#"+id)}catch(e){try{location.hash=id}catch(e2){}}render();window.scrollTo(0,0)}
window.addEventListener("hashchange",function(){var id="";try{id=decodeURIComponent(location.hash.replace(/^#/,""))}catch(e){}if(id&&tabIndex(id)!=-1&&id!==S.tab){S.tab=id;save();render()}});
function match(p){
 if(S.th!==""&&T[p[5]]!==S.th)return false;
 if(S.ly!==""&&L[p[4]]!==S.ly)return false;
 if(S.q){var q=S.q.toLowerCase();if(("himmel-"+p[0]+" "+p[1]).toLowerCase().indexOf(q)<0)return false}
 return true}
function subset(){return P.filter(match)}
function layerChip(p){var l=el("span","chip l",L[p[4]]);l.style.setProperty("--c","var("+LC[p[4]]+")");return l}
function notePath(n){return D.DR[n[0]]+"/"+n[1]}
function card(p){
 var c=el("div","card");c.appendChild(el("div","t",p[1]));if(p[9])c.appendChild(el("div","ui",p[9]));
 var m=el("div","meta");m.appendChild(el("span","key","HIMMEL-"+p[0]));m.appendChild(layerChip(p));
 if(p[10])m.appendChild(el("span","fx","effort "+p[10]));else if(p[6])m.appendChild(el("span","fx","effort "+p[6]+" S-eq"));
 if(p[13])m.appendChild(el("span","chip pf","plan first: "+p[13]+" slice"));
 if(p[11]!=null)m.appendChild(el("span","fx","ready "+p[11]+"/4"));
 if(p[12]!=null)m.appendChild(el("span","fx","impact "+p[12]+"/5"));
 m.appendChild(el("span",null,T[p[5]]));
 if(p[7]==1)m.appendChild(el("span","chip drift","drift"));
 if(p[7]==2)m.appendChild(el("span","chip off","off-plan"));
 c.appendChild(m);
 if(p[8]&&p[8].length){var d=el("details"),s=el("summary",null,"vault notes ("+p[8].length+")");d.appendChild(s);
  d.appendChild(el("div","nt","Jira key: HIMMEL-"+p[0]));
  p[8].forEach(function(i){var n=D.N[i],pa=notePath(n),b=el("div","nt");b.appendChild(el("div","ti",n[2]));
   b.appendChild(el("code",null,pa));b.appendChild(el("code",null,"obsidian://open?vault=luna&file="+encodeURIComponent(pa.replace(/\.md$/,""))));d.appendChild(b)});
  c.appendChild(d)}
 return c}
function row(p){
 var r=el("div","row");r.appendChild(el("span","st st"+p[2]));r.appendChild(el("span","key","HIMMEL-"+p[0]));r.appendChild(el("span","t",p[1]));r.appendChild(layerChip(p));if(p[7]==1)r.appendChild(el("span","chip drift","drift"));return r}
function seg(cls,n,tot){var i=el("i",cls);i.style.width=(100*n/(tot||1))+"%";return i}
function pctf(n,t){return t?Math.round(100*n/t):0}
function ledger(){
 var a=P.filter(function(p){return /^v1\.0\.\d+$/.test(V[p[3]])}),t=tally(a),tot=a.length;
 $("stamp").textContent="Generated "+D.gen+" from mirror updated "+D.mir+"; plan built at main "+D.sha+".";
 var l=$("ledger");l.textContent="";
 D.LG.forEach(function(x){l.appendChild(el("p",x.indexOf("Needs attention")==0?"x":null,x))});
 var o=$("overall");o.textContent="";o.appendChild(seg("seg-d",t[2],tot));o.appendChild(seg("seg-p",t[1],tot));
 o.setAttribute("aria-label","v1.0.x: "+t[2]+" done, "+t[1]+" in progress, "+t[0]+" to do")}
function tabs(){
 var t=$("tabs");t.textContent="";var sel=null;
 [["overview","Overview",null]].concat(V.map(function(v,i){return[tid(v),v,i]})).forEach(function(x){
  var b=el("button",x[2]==cur?"cur":"",x[1]);b.setAttribute("role","tab");b.setAttribute("aria-selected",x[0]===S.tab);
  if(x[2]!==null){var tl=tally(inV(x[2])),n=tl[0]+tl[1]+tl[2];var m=el("span","m");m.style.width=pctf(tl[2],n)+"%";b.appendChild(m);b.title=V[x[2]]+": "+tl[2]+"/"+n+" done"}
  b.addEventListener("click",function(){setTab(x[0])});t.appendChild(b);if(x[0]===S.tab)sel=b});
 if(sel&&sel.scrollIntoView){try{t.scrollLeft=Math.max(0,sel.offsetLeft-t.clientWidth/2+sel.offsetWidth/2)}catch(e){}}}
function layerMix(f){
 var w=el("div"),c=L.map(function(_,i){return f.filter(function(p){return p[4]==i}).length});
 var hb=el("div","hbar");c.forEach(function(n,i){if(!n)return;var d=el("i");d.style.width=(100*n/(f.length||1))+"%";d.style.background="var("+LC[i]+")";d.title=L[i]+" "+n;hb.appendChild(d)});w.appendChild(hb);
 var lg=el("div","legend");L.forEach(function(l,i){if(!c[i])return;var s=el("span"),b=el("i");b.style.background="var("+LC[i]+")";s.appendChild(b);s.appendChild(document.createTextNode(l+" "+c[i]));lg.appendChild(s)});w.appendChild(lg);return w}
function meter(n,c){
 var mx=Math.max(c?c*1.2:0,n,0.001),ld=el("div","load"),d=el("i");d.style.left="0";d.style.width=(100*n/mx)+"%";d.style.background=ldc(n,c);ld.appendChild(d);
 if(c){var b=el("b");b.style.left=(100*c/mx)+"%";ld.appendChild(b)}return ld}
function loadBar(v){
 var w=el("div"),vl=D.VL[v],dfr=!/^v1\.0\.\d+$/.test(V[v]),c=dfr?null:CAP;
 w.appendChild(meter(vl[5],c));
 w.appendChild(el("div","note","Total load "+vl[5].toFixed(2)+(c?" of "+c+" bank cap ("+Math.round(100*vl[5]/c)+"%)":dfr?" (deferred bucket: no cap)":" (cap not recorded in the plan)")+", ~"+vl[6]+" legs. Dashed line = cap."));
 if(!dfr)L.forEach(function(l,i){var lc=D.CAP.layers[i],r=el("div","lrow");r.appendChild(el("span",null,l));r.appendChild(meter(vl[i],lc));
  r.appendChild(el("b",null,vl[i].toFixed(2)+" / "+(lc==null?"–":lc.toFixed(2))));w.appendChild(r)});
 return w}
function themeList(f){
 var pl=el("div","plist"),used=T.map(function(_,i){return i}).filter(function(i){return f.some(function(p){return p[5]==i})});
 used.map(function(ti){var a=f.filter(function(p){return p[5]==ti});return[ti,a,tally(a)]}).sort(function(x,y){return y[1].length-x[1].length}).forEach(function(x){
  var r=el("div","r");r.appendChild(el("span",null,T[x[0]]));var b=el("div","b");b.appendChild(seg("seg-d",x[2][2],x[1].length));b.appendChild(seg("seg-p",x[2][1],x[1].length));r.appendChild(b);
  r.appendChild(el("span","flag",x[2][2]+"/"+x[1].length));pl.appendChild(r)});return pl}
function versionTab(pane,v){
 // HIMMEL-3957: Done off-plan work sits in the Done column (it counts toward this version); only open off-plan work is listed apart.
 var f=subset().filter(function(p){return p[3]==v}),pl=f.filter(function(p){return p[7]!=2||p[2]==2}),un=f.filter(function(p){return p[7]==2&&p[2]!=2}),dr=f.filter(function(p){return p[7]==1}),t=tally(f);
 var off=f.filter(function(p){return p[7]==2}).length,xs=[];
 if(off)xs.push(off+" off-plan ("+(off-un.length)+" of them done)");if(dr.length)xs.push(dr.length+" drifted");
 pane.appendChild(el("h2",null,V[v]+(v==cur?" (running now)":"")));
 pane.appendChild(el("p","ledger",t[2]+" of "+f.length+" done ("+pctf(t[2],f.length)+" %), "+t[1]+" in progress, "+t[0]+" to do. "+(f.length-off)+" planned"+(xs.length?", "+xs.join(", "):"")+"."));
 var o=el("div","overall");o.appendChild(seg("seg-d",t[2],f.length));o.appendChild(seg("seg-p",t[1],f.length));pane.appendChild(o);
 var fc=el("div","facets"),a=el("div");a.appendChild(el("h3",null,"Layer mix"));a.appendChild(layerMix(f));
 var b=el("div");b.appendChild(el("h3",null,"Effort load vs bank cap"));b.appendChild(loadBar(v));
 var c=el("div");c.appendChild(el("h3",null,"Themes (done/total)"));c.appendChild(themeList(f));
 fc.appendChild(a);fc.appendChild(b);fc.appendChild(c);pane.appendChild(fc);
 var g=el("div","board");
 [[0,"To do",""],[1,"In progress","p"],[2,"Done","d"]].forEach(function(cd){
  var col=el("div","col "+cd[2]),items=pl.filter(function(p){return p[2]==cd[0]});
  col.appendChild(el("h3",null,cd[1]+" ("+items.length+")"));
  items.slice(0,cap[cd[0]]).forEach(function(p){col.appendChild(card(p))});
  if(items.length>cap[cd[0]]){var bt=el("button","more","Show "+(items.length-cap[cd[0]])+" more");bt.addEventListener("click",function(){cap[cd[0]]+=1000;render()});col.appendChild(bt)}
  g.appendChild(col)});
 pane.appendChild(g);
 if(dr.length){var d=el("div","unp");d.appendChild(el("h3",null,"Drift ("+dr.length+")"));d.appendChild(el("div","note","Planned here, but Jira fixVersion names other versions."));dr.forEach(function(p){d.appendChild(row(p))});pane.appendChild(d)}
 if(un.length){var u=el("div","unp");u.appendChild(el("h3",null,"Off-plan, still open in "+V[v]+" ("+un.length+")"));u.appendChild(el("div","note","In this fixVersion in Jira but not in the roadmap plan."));un.forEach(function(p){u.appendChild(row(p))});pane.appendChild(u)}}
function strip(pane,f){
 var by=V.map(function(_,i){return tally(f.filter(function(p){return p[3]==i}))}),mx=1;by.forEach(function(t){mx=Math.max(mx,t[0]+t[1]+t[2])});
 var r=el("div","rail"),tr=el("div","train");
 V.forEach(function(v,i){var b=el("button","car"+(i==cur?" cur":"")),t=by[i];b.title=v+": "+t[2]+" done, "+t[1]+" in progress, "+t[0]+" to do";
  var bar=el("div","bar");[[t[2],"seg-d"],[t[1],"seg-p"],[t[0],"seg-t"]].forEach(function(x){if(!x[0])return;var d=el("div",x[1]);d.style.height=Math.max(3,Math.round(96*x[0]/mx))+"px";bar.appendChild(d)});
  b.appendChild(bar);b.appendChild(el("small",null,lab(i)));b.addEventListener("click",function(){setTab(tid(v))});tr.appendChild(b)});
 r.appendChild(tr);pane.appendChild(r);
 var lg=el("div","legend");[["seg-d","done"],["seg-p","in progress"],["seg-t","to do"]].forEach(function(x){var s=el("span"),i=el("i",x[0]);s.appendChild(i);s.appendChild(document.createTextNode(x[1]));lg.appendChild(s)});
 lg.appendChild(el("span",null,"Bar height = tickets in that version (planned + unplanned). Click a bar to open its tab."));pane.appendChild(lg)}
function burnup(pane,f){
 var W=760,H=220,ml=44,mr=90,mt=12,mb=26,n=LAST,cs=0,cd=0,cp=0,sc=[],dn=[],pg=[];
 for(var i=0;i<n;i++){var t=tally(f.filter(function(p){return p[3]==i}));cs+=t[0]+t[1]+t[2];cd+=t[2];cp+=t[1];sc.push(cs);dn.push(cd);pg.push(cd+cp)}
 var mx=Math.max(1,cs),X=function(i){return ml+(W-ml-mr)*i/(n-1)},Y=function(v){return H-mb-(H-mt-mb)*v/mx};
 var s=svg("svg",{viewBox:"0 0 "+W+" "+H,role:"img","aria-label":"Cumulative tickets across versions: scope "+cs+", done "+cd});
 for(var k=0;k<=4;k++){var v=Math.round(mx*k/4),y=Y(v);s.appendChild(svg("line",{x1:ml,x2:W-mr,y1:y,y2:y,stroke:"var(--line)"}));var tx=svg("text",{x:ml-6,y:y+4,"text-anchor":"end"});tx.textContent=v;s.appendChild(tx)}
 for(i=0;i<n;i+=5){var tx2=svg("text",{x:X(i),y:H-8,"text-anchor":"middle"});tx2.textContent=lab(i);s.appendChild(tx2)}
 var area="M"+X(0)+","+Y(0);dn.forEach(function(v,i){area+=" L"+X(i)+","+Y(v)});area+=" L"+X(n-1)+","+Y(0)+"Z";
 s.appendChild(svg("path",{d:area,fill:"var(--done)","fill-opacity":".35"}));
 function line(a,col,dash,txt){var d="";a.forEach(function(v,i){d+=(i?" L":"M")+X(i)+","+Y(v)});var p=svg("path",{d:d,fill:"none",stroke:col,"stroke-width":2});if(dash)p.setAttribute("stroke-dasharray","5 4");s.appendChild(p);
  var e=svg("text",{x:X(n-1)+6,y:Y(a[n-1])+4});e.style.fill=col;e.textContent=txt+" "+a[n-1];s.appendChild(e)}
 line(dn,"var(--done)",0,"done");line(pg,"var(--prog)",0,"+active");line(sc,"var(--ink)",1,"scope");
 var b=el("div","burn");b.appendChild(s);pane.appendChild(b);
 pane.appendChild(el("div","legend")).appendChild(el("span",null,"Cumulative across v1.0.1 to v1.0.42: done, done + in progress, and total scope (planned + unplanned)."))}
function capBox(pane){var b=el("div","capbox");D.CAP.text.forEach(function(x){b.appendChild(el("p",null,x))});pane.appendChild(b)}
function loadChart(pane){
 // one magnitude per version on the slate load ramp (LD), stepped by share of the cap; never the layer hues.
 var mx=1e-3;V.forEach(function(_,i){if(/^v1\.0\.\d+$/.test(V[i]))mx=Math.max(mx,D.VL[i][5])});mx=Math.max(mx,(CAP||0)*1.15);
 var ch=el("div","chart"),cols=el("div","lcols");
 V.forEach(function(v,i){var col=el("div","lcol"),bar=el("div","bar"),n=D.VL[i][5],dfr=!/^v1\.0\.\d+$/.test(v);
  var off=n>mx;  // a load past the train's scale (the deferred bucket) is clipped, and says so
  if(n){var d=el("div");d.style.height=Math.max(2,Math.round(110*Math.min(n,mx)/mx))+"px";d.style.background=ldc(n,dfr?null:CAP);d.title=v+": load "+n.toFixed(2)+(CAP&&!dfr?" of "+CAP+" ("+Math.round(100*n/CAP)+"%)":dfr?" (deferred, no cap)":"")+(off?"; off the scale, bar clipped":"");bar.appendChild(d)}
  col.appendChild(bar);col.appendChild(el("small",null,lab(i)+(off?" ▲":"")));cols.appendChild(col)});
 if(CAP){var c=el("div","cap");c.style.bottom=(26+110*CAP/mx)+"px";c.appendChild(el("span",null,"cap "+CAP));cols.appendChild(c)}
 ch.appendChild(cols);pane.appendChild(ch);
 var lg=el("div","legend");["under half the cap","half to 80 %","80 % or more"].forEach(function(x,k){var s=el("span"),i=el("i");i.style.background="var("+LD[k]+")";s.appendChild(i);s.appendChild(document.createTextNode(x));lg.appendChild(s)});
 lg.appendChild(el("span",null,"Dashed line = total cap. ▲ = load off the scale, bar clipped. Per-layer load vs its own cap is on each version's tab."));pane.appendChild(lg)}
function layerChart(pane,f){
 var per=V.map(function(_,v){return f.filter(function(p){return p[3]==v})}),mx=1;per.forEach(function(a){mx=Math.max(mx,a.length)});
 var ch=el("div","chart"),cols=el("div","lcols");
 per.forEach(function(a,v){var col=el("div","lcol"),bar=el("div","bar");
  L.forEach(function(_,i){var n=a.filter(function(p){return p[4]==i}).length;if(!n)return;var d=el("div");d.style.height=Math.max(2,Math.round(110*n/mx))+"px";d.style.background="var("+LC[i]+")";d.title=V[v]+" "+L[i]+" "+n;bar.appendChild(d)});
  col.appendChild(bar);col.appendChild(el("small",null,lab(v)));cols.appendChild(col)});
 ch.appendChild(cols);pane.appendChild(ch)}
function heat(pane,f){
 var box=el("div","heat"),tb=el("table"),hr=el("tr");hr.appendChild(el("th"));
 V.forEach(function(v,i){hr.appendChild(el("th",null,lab(i)))});tb.appendChild(hr);
 T.map(function(_,i){return i}).filter(function(i){return f.some(function(p){return p[5]==i})}).forEach(function(ti){var r=el("tr");r.appendChild(el("th","tn",T[ti]));
  V.forEach(function(v,vi){var a=f.filter(function(p){return p[5]==ti&&p[3]==vi}),td=el("td",a.length?"":"z",a.length||"");
   if(a.length){var d=a.filter(function(p){return p[2]==2}).length/a.length;td.style.background="color-mix(in srgb,var(--done) "+Math.round(d*100)+"%,color-mix(in srgb,var(--todo) 30%,var(--panel)))";td.title=T[ti]+" "+v+": "+a.length+" tickets, "+Math.round(d*100)+"% done";
    td.addEventListener("click",function(){setTab(tid(v))})}
   r.appendChild(td)});tb.appendChild(r)});
 box.appendChild(tb);pane.appendChild(box)}
function details(pane){
 var q=(S.q||"").toLowerCase();
 function keep(a){return a.filter(function(x){return !q||("himmel-"+x[0]+" "+x[1]+" "+x[3]).toLowerCase().indexOf(q)>=0})}
 var u=keep(D.U);
 var d2=el("details","sec");d2.appendChild(el("summary",null,"Parked / unplaced ("+u.length+")"));
 u.forEach(function(x){var r=el("div","row");r.appendChild(el("span","st st"+x[2]));r.appendChild(el("span","key","HIMMEL-"+x[0]));r.appendChild(el("span","t",x[1]));r.appendChild(el("span","flag",x[3]));d2.appendChild(r)});
 pane.appendChild(d2)}
function overview(pane){
 var f=subset();
 pane.appendChild(el("h2",null,"Version train"));strip(pane,f);
 pane.appendChild(el("h2",null,"Burn-up"));burnup(pane,f);
 pane.appendChild(el("h2",null,"Effort load per version vs bank cap"));capBox(pane);loadChart(pane);
 pane.appendChild(el("h2",null,"Layer mix"));pane.appendChild(layerMix(f));layerChart(pane,f);
 pane.appendChild(el("h2",null,"Theme by version"));pane.appendChild(el("div","note","Cell = ticket count; green share = done. Click a cell to open that version."));heat(pane,f);
 pane.appendChild(el("h2",null,"Theme progress"));pane.appendChild(themeList(f));
 pane.appendChild(el("h2",null,"Outside the plan"));details(pane)}
function render(){
 ledger();tabs();var p=$("pane");p.textContent="";var i=tabIndex(S.tab);
 if(i<0)overview(p);else versionTab(p,i)}
function fill(sel,arr,cv,lb){sel.textContent="";var o=el("option",null,lb);o.value="";sel.appendChild(o);arr.forEach(function(x){var o2=el("option",null,x);o2.value=x;sel.appendChild(o2)});sel.value=cv}
$("eqs").textContent=D.EQ;
L.forEach(function(l,i){var s=el("span"),b=el("i","sw");b.style.background="var("+LC[i]+")";s.appendChild(b);s.appendChild(document.createTextNode(l+(i<L.length-1?" · ":"")));$("lgl").appendChild(s)});
fill($("fTheme"),T,S.th,"All themes");fill($("fLayer"),L,S.ly,"All layers");$("fQ").value=S.q;
if($("fTheme").value!==S.th)S.th="";if($("fLayer").value!==S.ly)S.ly="";
$("fTheme").addEventListener("change",function(){S.th=this.value;save();render()});
$("fLayer").addEventListener("change",function(){S.ly=this.value;save();render()});
$("fQ").addEventListener("input",function(){S.q=this.value;save();render()});
$("fClr").addEventListener("click",function(){S.th=S.ly=S.q="";$("fTheme").value="";$("fLayer").value="";$("fQ").value="";save();render()});
render();
})();
</script>
'''

if __name__ == '__main__':
    main()
