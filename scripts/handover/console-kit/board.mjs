#!/usr/bin/env node
// board.mjs — HIMMEL-3361. Render the console's progress board: a self-contained
// HTML page (console-board.html, next to the console doc) that shows the fleet,
// every leg's phase, what needs the console, epic progress and the operator's
// open decisions. The console republishes it as an artifact (that call is the
// console's own; this script never publishes).
//
//   node board.mjs --doc <console doc> [--legs "<leg doc> ..."] [--out <file>] [--repo <dir>]
//
// State comes from tick.sh (leg locks, tails, fleet, open PRs, and the board
// fingerprint via --emit-fp), the console doc's `## Live state` block, the leg
// docs' Results bullets, and `gh` (open + merged PRs). tick.sh's `board=` field
// compares the fingerprint embedded here with a freshly recomputed one, so a
// stale board is structurally visible. The published page is public-ish: nonces,
// lock tokens and token spans are redacted from everything before it is escaped.
//
// Optional Live-state lines the console may keep (console-template.md):
//   epics: HIMMEL-3332=4, HIMMEL-3340=2     declared totals; merged is counted from gh
//   decisions: first?; second?              open operator decisions, ';'-separated
//
// PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only (tick.sh
// reads pgrep, atq and the konsole launch logs). Node ESM, no dependencies.
//
// ponytail: the epic "merged" count is PRs whose title cites [KEY], from one
// `gh pr list --search "KEY in:title"` (200 max); an epic whose PRs cite it only
// in the branch name, or with more than 200 merged PRs, undercounts. The declared
// total in `epics:` is the console's own number -- nothing derives it from Jira.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));

const args = process.argv.slice(2);
const opt = {};
for (let i = 0; i < args.length; i += 2) {
    if (!['--doc', '--legs', '--out', '--repo'].includes(args[i]) || args[i + 1] === undefined) {
        console.error('usage: board.mjs --doc <console doc> [--legs "<leg doc> ..."] [--out <file>] [--repo <dir>]');
        process.exit(2);
    }
    opt[args[i].slice(2)] = args[i + 1];
}
if (!opt.doc) {
    console.error('usage: board.mjs --doc <console doc> [--legs "<leg doc> ..."] [--out <file>] [--repo <dir>]');
    process.exit(2);
}
const docPath = resolve(opt.doc);
if (!existsSync(docPath)) {
    console.error(`board: no such console doc: ${docPath}`);
    process.exit(1);
}
const bucket = dirname(docPath);
const repo = resolve(opt.repo || join(HERE, '..', '..', '..'));
const outPath = resolve(opt.out || join(bucket, 'console-board.html'));

// ---------------------------------------------------------------- redaction
// Nonces (`V-N255-93f72f64`, `AA-N1-abcdef12`, or a leg stem
// `V-HIMMEL-3340-N1-alpha-cafe0123`), lock tokens (`cachyos-x8664-pid909468`)
// and a `token \`...\`` span never reach a published page. Console letters run
// A-Z then AA-ZZ. Runs BEFORE escaping.
const redact = (s) => s
    .replace(/\b[A-Z]{1,2}-[A-Za-z0-9][A-Za-z0-9._-]*-[0-9a-f]{6,}\b/g, '[nonce]')
    .replace(/\b[A-Za-z0-9_]+-[A-Za-z0-9_]+-pid\d+\b/g, '[lock]')
    .replace(/\bpid\d{4,}\b/g, '[pid]')
    .replace(/\b(tokens?|nonces?)(\s*[:=]?\s*)`[^`]*`/gi, '$1$2[redacted]');
const esc = (s) => String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
const clip = (s, n) => (s.length > n ? `${s.slice(0, n - 1)}…` : s);
// Redact BEFORE clipping: a clip that cuts a lock token in half would leave a
// fragment the patterns no longer match.
const safe = (s, n = Infinity) => esc(clip(redact(String(s)), n));

// ---------------------------------------------------------------- console doc
const docText = readFileSync(docPath, 'utf8');
const docLines = docText.split('\n');
// A section runs from its heading to the next `## ` heading -- never past it. The
// tick reads `## Live state` by exact heading, so `exact` mirrors that.
const sectionOf = (lines, title, exact = false) => {
    const out = [];
    let on = false;
    for (const l of lines) {
        if (on && /^## /.test(l)) break;
        if (on) out.push(l);
        if (l === title || (!exact && l.startsWith(`${title} `))) on = true;
    }
    return out;
};
const section = (title, exact) => sectionOf(docLines, title, exact);
const live = section('## Live state', true);
const liveField = (key) => {
    const l = live.find((x) => x.startsWith(`${key}:`));
    return l ? l.slice(key.length + 1).trim() : '';
};
// The legs: BLOCK, read by tick.sh's own grammar (HIMMEL-3366): every `legs:` line
// plus the lines wrapped under it, up to the first blank line, the next `word:`
// field, or a list-marker / `>` / `#` line (a detail bullet may quote a span
// freely). An entry is a backtick span of exactly four non-empty colon fields
// `<label>:<nonce>:<lock-token>:<pid>`, no whitespace, the label all
// LEG_LABEL_CLASS (scripts/lib/leg-identity.sh: letters, digits, `_`, `.`, `-`),
// so a leg doc stem parses too. Only the label and the nonce are kept: the nonce
// picks the leg's doc among docs sharing a label, and is never rendered.
// ponytail: a malformed span (tick reports it MALFORMED by label) is not an entry
// here, so a leg named only by one is missing from the board's Live-state set.
const LEG_LABEL_CLASS = /^[A-Za-z0-9_.-]+$/;
const liveEntries = [];
{
    let inBlock = false;
    for (const l of live) {
        if (/^legs:/.test(l)) inBlock = true;
        else if (inBlock && (/^\s*$/.test(l) || /^[A-Za-z][A-Za-z ]*:/.test(l) || /^\s*([-*+]|\d+[.)])\s/.test(l) || /^\s*[>#]/.test(l))) inBlock = false;
        if (!inBlock) continue;
        for (const m of l.matchAll(/`([^`]*)`/g)) {
            const f = m[1].split(':');
            if (/\s/.test(m[1]) || f.length !== 4 || f.some((x) => !x) || !LEG_LABEL_CLASS.test(f[0])) continue;
            liveEntries.push({ stem: f[0], nonce: f[1] });
        }
    }
}
const epicsDeclared = liveField('epics').split(/[,\s]+/).filter(Boolean).map((e) => {
    const m = /^([A-Z][A-Z0-9]*-\d+)=(\d+)$/.exec(e);
    return m ? { key: m[1], total: Number(m[2]) } : null;
}).filter(Boolean);
const decisions = liveField('decisions').split(';').map((d) => d.trim()).filter((d) => d && d !== 'none');
const queueLine = liveField('queue');
const lastGo = liveField('last GO').replace(/`/g, '');
const consoleResults = section('## Results').filter((l) => l.startsWith('- ')).slice(-8);

// ---------------------------------------------------------------- leg docs
// A leg's label comes from leg-identity.sh, the ONE derivation the tick uses for
// leg docs and its own legs= (a local regex here is how the two drift). One bash
// call labels every name.
const LEGID = join(HERE, '..', '..', 'lib', 'leg-identity.sh');
const legLabel = new Map();
const primeLabels = (names) => {
    const todo = [...new Set(names)].filter((n) => !legLabel.has(n));
    if (!todo.length) return;
    let out = '';
    try {
        out = execFileSync('bash', ['-c', 'source "$1" || exit 1; shift; for s in "$@"; do leg_label "$s"; printf "\\n"; done', 'bash', LEGID, ...todo],
            { encoding: 'utf8', timeout: 30000, stdio: ['ignore', 'pipe', 'ignore'] });
    } catch { /* no labels: the docs read as unlabelled and are skipped */ }
    const lines = out.split('\n');
    todo.forEach((n, i) => legLabel.set(n, lines[i] || ''));
};
const labelOf = (name) => legLabel.get(name) || '';
const ticketOf = (file) => (/^([A-Z][A-Z0-9]*-\d+)/.exec(basename(file)) || [])[1] || '';
const newer = (a, b) => (statSync(a).mtimeMs >= statSync(b).mtimeMs ? a : b);
let legFiles;
if (opt.legs !== undefined) {
    legFiles = opt.legs.split(/[\s,]+/).filter(Boolean).map((f) => resolve(f));
    primeLabels([...liveEntries.map((e) => e.stem), ...legFiles.map((f) => basename(f))]);
} else {
    const docs = readdirSync(bucket).filter((f) => f.endsWith('-RESUME.md'));
    primeLabels([...liveEntries.map((e) => e.stem), ...docs]);
    // One doc per Live-state entry, from the leg's identity: the doc its stem names,
    // else -- among docs sharing the label -- the one holding the entry's nonce,
    // else the newest by mtime (a label alone cannot tell two consoles' N1 apart).
    const byLabel = new Map();
    for (const e of liveEntries) {
        const label = labelOf(e.stem);
        if (!label || byLabel.has(label)) continue;
        const exact = docs.find((f) => f === `${e.stem}.md` || f === `${e.stem}-RESUME.md`);
        const cands = docs.filter((f) => labelOf(f) === label).map((f) => join(bucket, f));
        const holders = cands.filter((f) => readFileSync(f, 'utf8').includes(e.nonce));
        const pool = holders.length ? holders : cands;
        const doc = exact ? join(bucket, exact) : (pool.length ? pool.reduce(newer) : null);
        if (doc) byLabel.set(label, doc);
    }
    legFiles = [...byLabel.values()];
}
const liveLabels = [...new Set(liveEntries.map((e) => labelOf(e.stem)).filter(Boolean))];
const legInfo = new Map();
for (const f of legFiles) {
    const label = labelOf(basename(f));
    if (!label || !existsSync(f)) continue;
    const bullets = sectionOf(readFileSync(f, 'utf8').split('\n'), '## Results').filter((l) => l.startsWith('- '));
    let pr = null;
    for (const b of bullets) {
        const m = /\bPR\s*#?(\d{2,})\b/.exec(b) || /\bREADY\s+#?(\d{2,})\s+[0-9a-f]{7,}/.exec(b)
            || /\/pull\/(\d+)/.exec(b) || /(?:^|[\s(])#(\d{2,})\b/.exec(b);
        if (m) pr = Number(m[1]);
    }
    legInfo.set(label, { file: f, ticket: ticketOf(f), last: bullets.length ? bullets[bullets.length - 1].slice(2) : '', pr });
}

// ---------------------------------------------------------------- tick
const tickBin = process.env.BOARD_TICK || join(HERE, 'tick.sh');
const tickArgs = ['--doc', docPath, '--repo', repo, '--emit-fp'];
if (opt.legs !== undefined) tickArgs.push('--legs', opt.legs);
else if (legFiles.length) tickArgs.push('--legs', legFiles.join(' '));
// tick's own DOC/TOKEN/LEGS env must not leak in: a board render sends no
// heartbeat (no token) and reads exactly the arm passed above.
const tickEnv = { ...process.env };
for (const k of ['DOC', 'TOKEN', 'LEGS']) delete tickEnv[k];
let tickLine = '';
let fp = '';
try {
    const cmd = tickBin.endsWith('.sh') ? ['bash', [tickBin, ...tickArgs]] : [tickBin, tickArgs];
    const out = execFileSync(cmd[0], cmd[1], { encoding: 'utf8', env: tickEnv, timeout: 90000, stdio: ['ignore', 'pipe', 'ignore'] });
    for (const l of out.split('\n')) {
        if (l.startsWith('TICK ') && !tickLine) tickLine = l;
        const m = /^board-fp=([0-9a-f]{16})$/.exec(l);
        if (m) fp = m[1];
    }
} catch { /* degraded: the board still renders, marked tick-unavailable, with no fingerprint */ }
if (!tickLine) fp = '';
const field = {};
for (const m of tickLine.matchAll(/(?:^|\s)([a-z]+)=(\S*)/g)) field[m[1]] = m[2];
const pairs = (v) => new Map((v || '').split(',').map((p) => p.split(':')).filter((p) => /^N\d+[a-z]*$/.test(p[0] || '')).map((p) => [p[0], p.slice(1).join(':')]));
const locks = pairs(field.legs);
const tails = pairs(field.tails);
const [fleetLive, fleetCap] = (field.fleet || '').split('/').map(Number);
const fleetOk = Number.isFinite(fleetLive) && Number.isFinite(fleetCap) && fleetCap > 0;
const idle = fleetOk ? Math.max(0, fleetCap - fleetLive) : 0;

// ---------------------------------------------------------------- gh
const ghJson = (ghArgs) => {
    try {
        return JSON.parse(execFileSync('gh', ghArgs, { cwd: repo, encoding: 'utf8', timeout: 45000, stdio: ['ignore', 'pipe', 'ignore'] }));
    } catch { return null; }
};
const gh = (ghArgs) => {
    const v = ghJson(ghArgs);
    return Array.isArray(v) ? v : null;
};
const openPrs = gh(['pr', 'list', '--state', 'open', '--limit', '100', '--json', 'number,title,headRefName,isDraft,statusCheckRollup']);
const since = new Date(Date.now() - 86400e3).toISOString().slice(0, 19) + 'Z';
const mergedPrs = gh(['pr', 'list', '--state', 'merged', '--limit', '60', '--search', `merged:>=${since}`, '--json', 'number,title,mergedAt,headRefName']);
const epics = epicsDeclared.map((e) => {
    const found = gh(['pr', 'list', '--state', 'merged', '--limit', '200', '--search', `${e.key} in:title`, '--json', 'number,title']);
    const merged = found ? new Set(found.filter((p) => String(p.title).includes(`[${e.key}]`)).map((p) => p.number)).size : '?';
    return { ...e, merged };
});
const ciOf = (pr) => {
    const rollup = (pr && pr.statusCheckRollup) || [];
    // No checks reported yet is not a green build: it reads pending.
    if (!rollup.length) return 'pending';
    // A rollup mixes CheckRuns (status + conclusion) and StatusContexts (state only).
    const verdict = (c) => c.conclusion || c.state || '';
    if (rollup.some((c) => ['FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'STARTUP_FAILURE'].includes(verdict(c)))) return 'failing';
    if (rollup.some((c) => (c.status ? c.status !== 'COMPLETED' : false) || ['', 'PENDING', 'EXPECTED'].includes(verdict(c)))) return 'pending';
    return 'green';
};
const openByNum = new Map((openPrs || []).map((p) => [p.number, p]));
// Merge state is asked of each PR a leg names (`gh pr view`), not read off the
// 24 h merged panel: a leg whose PR merged yesterday must still read MERGED.
// ponytail: a PR gh cannot answer for (gh down, not a PR of this repo) reads not
// merged, so its leg falls back to LIVE / READY.
const mergedNums = new Set((mergedPrs || []).map((p) => p.number));
for (const n of new Set([...legInfo.values()].map((i) => i.pr).filter(Boolean))) {
    if (openByNum.has(n) || mergedNums.has(n)) continue;
    const v = ghJson(['pr', 'view', String(n), '--json', 'state']);
    if (v && v.state === 'MERGED') mergedNums.add(n);
}

// ---------------------------------------------------------------- phases
const LADDER = ['LIVE', 'READY-TO-OPEN', 'PR open', 'READY', 'BLOCKED', 'MERGED', 'WRAPPED'];
const labels = [...new Set([...liveLabels, ...locks.keys(), ...tails.keys(), ...legInfo.keys()])]
    .sort((a, b) => parseInt(a.slice(1), 10) - parseInt(b.slice(1), 10) || a.localeCompare(b));
const legs = labels.map((label) => {
    const info = legInfo.get(label) || { ticket: '', last: '', pr: null };
    const tail = tails.get(label) || '';
    const lock = locks.get(label) || '';
    let phase;
    if (tail === 'WRAPPED' || lock === 'WRAPPED') phase = 'WRAPPED';
    else if (info.pr && mergedNums.has(info.pr)) phase = 'MERGED';
    else if (tail === 'BLOCKED' || tail === 'HALTED') phase = 'BLOCKED';
    else if (tail === 'READY') phase = info.pr ? 'READY' : 'READY-TO-OPEN';
    else if (info.pr && openByNum.has(info.pr)) phase = 'PR open';
    else phase = 'LIVE';
    const pr = info.pr ? openByNum.get(info.pr) : null;
    const lostLock = ['STALE', 'FREE', 'MISSING', 'CORRUPT'].includes(lock) && phase !== 'WRAPPED' && phase !== 'MERGED';
    const needs = phase === 'READY' || phase === 'READY-TO-OPEN' || phase === 'BLOCKED' || tail === 'FINDING' || lostLock;
    return { label, ticket: info.ticket, phase, tail, lock, prNum: info.pr, ci: pr ? ciOf(pr) : '', last: info.last, needs, lostLock };
});

// ---------------------------------------------------------------- render
const now = new Date();
const stamp = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')} ${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
const consoleName = basename(docPath, '.md');

const legCard = (l) => `<li class="leg" data-label="${esc(l.label)}" data-phase="${esc(l.phase)}"${l.ci ? ` data-ci="${l.ci}"` : ''}>
  <div class="leg-head"><b>${esc(l.label)}</b> <span class="tk">${esc(l.ticket)}</span> <span class="ph">${esc(l.phase)}</span>${l.prNum ? ` <span class="pr">PR #${l.prNum}${l.ci ? ` · ${l.ci}` : ''}</span>` : ''}</div>
  <div class="leg-last">${l.last ? safe(l.last, 220) : '<i>no handover bullet yet</i>'}</div>
</li>`;
const ladder = LADDER.map((p) => `<li data-ladder="${esc(p)}" data-count="${legs.filter((l) => l.phase === p).length}"><span>${esc(p)}</span><b>${legs.filter((l) => l.phase === p).length}</b></li>`).join('\n');
const needRows = legs.filter((l) => l.needs).map((l) => {
    const why = l.phase === 'READY' ? `READY${l.prNum ? ` · PR #${l.prNum}` : ''} — awaiting GO`
        : l.phase === 'READY-TO-OPEN' ? 'READY-TO-OPEN — awaiting PR open'
            : l.phase === 'BLOCKED' ? 'BLOCKED — needs a ruling'
                : l.tail === 'FINDING' ? 'FINDING — needs a ruling'
                    : `lock ${l.lock} — lost or stale`;
    return `<li data-need="${esc(l.label)}"><b>${esc(l.label)}</b> ${esc(why)}<div class="leg-last">${safe(l.last, 160)}</div></li>`;
}).join('\n');
const epicRows = epics.map((e) => {
    const pct = e.merged === '?' ? 0 : Math.min(100, Math.round((e.merged / Math.max(1, e.total)) * 100));
    return `<li data-epic="${esc(e.key)}" data-merged="${e.merged}" data-total="${e.total}"><b>${esc(e.key)}</b> ${e.merged}/${e.total}<div class="bar"><i style="width:${pct}%"></i></div></li>`;
}).join('\n');
const prRows = (openPrs || []).map((p) => `<li data-ci="${ciOf(p)}"><b>#${p.number}</b> ${safe(p.title, 90)} <span class="pr">${ciOf(p)}${p.isDraft ? ' · draft' : ''}</span></li>`).join('\n');
const mergedRows = (mergedPrs || []).map((p) => `<li><b>#${p.number}</b> ${safe(p.title, 90)}</li>`).join('\n');
const logRows = consoleResults.map((l) => `<li>${safe(l.slice(2), 200)}</li>`).join('\n');
const panel = (title, body, empty) => `<section><h2>${title}</h2>${body ? `<ul>${body}</ul>` : `<p class="none">${empty}</p>`}</section>`;

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Console Board</title>
${fp ? `<meta name="console-board-fp" content="${fp}">` : ''}
<style>
:root { --bg:#f6f7f9; --surface:#fff; --text:#1c2128; --muted:#5b6672; --line:#d9dee4; --accent:#2457c5; --ok:#1a7f37; --warn:#9a6700; --bad:#cf222e; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg:#0f1318; --surface:#181d24; --text:#e6e9ed; --muted:#96a1ad; --line:#2b333d; --accent:#7aa2ff; --ok:#3fb950; --warn:#d29922; --bad:#ff7b72; } }
:root[data-theme="dark"] { --bg:#0f1318; --surface:#181d24; --text:#e6e9ed; --muted:#96a1ad; --line:#2b333d; --accent:#7aa2ff; --ok:#3fb950; --warn:#d29922; --bad:#ff7b72; }
* { box-sizing: border-box; }
body { margin:0; padding:16px; background:var(--bg); color:var(--text); font:15px/1.45 system-ui, sans-serif; overflow-wrap:anywhere; }
main { max-width:1100px; margin:0 auto; }
h1 { font-size:1.35rem; margin:0 0 2px; } h2 { font-size:.8rem; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); margin:0 0 8px; }
.sub { color:var(--muted); font-size:.85rem; margin:0 0 14px; }
.banner { background:var(--surface); border:1px solid var(--bad); color:var(--bad); border-radius:8px; padding:8px 12px; margin:0 0 12px; }
.grid { display:grid; grid-template-columns:repeat(auto-fit, minmax(min(100%, 300px), 1fr)); gap:12px; }
section { background:var(--surface); border:1px solid var(--line); border-radius:10px; padding:12px; min-width:0; }
ul { list-style:none; margin:0; padding:0; } li { padding:6px 0; border-top:1px solid var(--line); } li:first-child { border-top:0; }
.none { color:var(--muted); margin:0; }
.ladder { display:flex; flex-wrap:wrap; gap:6px; } .ladder li { border:1px solid var(--line); border-radius:8px; padding:4px 10px; display:flex; gap:8px; } .ladder li[data-count="0"] { opacity:.45; }
.fleet { font-size:1.6rem; font-weight:650; } .fleet small { font-size:.85rem; color:var(--muted); font-weight:400; }
.idle { color:var(--warn); font-weight:600; }
.tk, .pr, .leg-last { color:var(--muted); font-size:.85rem; } .ph { color:var(--accent); font-weight:600; }
li[data-phase="BLOCKED"] .ph, li[data-ci="failing"] .pr { color:var(--bad); } li[data-phase="WRAPPED"] .ph, li[data-phase="MERGED"] .ph, li[data-ci="green"] .pr { color:var(--ok); } li[data-ci="pending"] .pr { color:var(--warn); }
.bar { height:6px; background:var(--line); border-radius:3px; margin-top:4px; } .bar i { display:block; height:100%; background:var(--accent); border-radius:3px; }
.wide { grid-column:1 / -1; }
</style>
</head>
<body>
<main>
<h1>Console Board</h1>
<p class="sub">${safe(consoleName)} · rendered ${stamp}${lastGo ? ` · last GO ${safe(lastGo)}` : ''}${queueLine ? ` · queue ${safe(queueLine)}` : ''}</p>
${fp ? '' : '<p class="banner">tick unavailable — this board has no state fingerprint and will read STALE until it is re-rendered.</p>'}
<div class="grid">
<section>
<h2>Fleet</h2>
${fleetOk ? `<div class="fleet" data-fleet="${fleetLive}/${fleetCap}">${fleetLive}<small>/${fleetCap} legs live</small></div>${idle ? `<div class="idle" data-idle="${idle}">${idle} idle slot${idle === 1 ? '' : 's'} — underfilled</div>` : ''}` : '<p class="none">fleet unavailable</p>'}
<p class="sub">bank ${safe(field.bank || '?')} · gql ${safe(field.gql || '?')}</p>
</section>
<section>
<h2>Phase ladder</h2>
<ul class="ladder">
${ladder}
</ul>
</section>
${panel('Needs the console', needRows, 'nothing waiting on the console')}
${panel('Open operator decisions', decisions.map((d) => `<li>${safe(d)}</li>`).join('\n'), 'none recorded (Live state decisions:)')}
${epics.length ? panel('Epics — merged / total', epicRows, '') : ''}
<section class="wide">
<h2>Legs</h2>
${legs.length ? `<ul>${legs.map(legCard).join('\n')}</ul>` : '<p class="none">no legs</p>'}
</section>
${panel('Open PRs', prRows, openPrs ? 'none open' : 'gh unavailable')}
${panel('Merged in the last 24 hours', mergedRows, mergedPrs ? 'none' : 'gh unavailable')}
${panel('Console log — newest last', logRows, 'no Results yet')}
</div>
</main>
</body>
</html>
`;

const tmp = `${outPath}.tmp${process.pid}`;
writeFileSync(tmp, html);
renameSync(tmp, outPath);
console.log(outPath);
