#!/usr/bin/env node
// fleet.mjs — HIMMEL-3404. A local status UI for the console's legs, headed or
// headless: one row per leg (runtime, process, lock, newest status bullet, PR + CI,
// last session-log line) plus the fleet/bank header and a "needs the console"
// strip. With legs moving to headless background sessions there is no window to
// glance at; this page is the glance.
//
//   node fleet.mjs --doc <console doc> --serve [--port 7788]   live page, polls /api/fleet
//   node fleet.mjs --doc <console doc> --out <file.html>       static snapshot (publishable)
//   node fleet.mjs --doc <console doc> --json                  the snapshot as JSON
//   common: [--logs <launch-log dir>] [--handover-root <dir>] [--repo <dir>]
//
// READ-ONLY. The server binds 127.0.0.1 (there is no flag to change that), answers
// GET/HEAD only, and has no route that runs anything or writes anywhere. Sources:
// the console doc's `## Live state` legs: block, each leg doc's `## Results`, the
// queue-lock sweep, /proc, bank-preflight.sh, gh, and the launch logs. Nonces, lock
// tokens and token spans are redacted from every string BEFORE it is put in the
// snapshot (so the JSON endpoint is as clean as the page); the page renders with
// textContent only, and the embedded snapshot has `<` escaped.
//
// PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only (/proc, the
// konsole launch logs). Node ESM, no dependencies.
//
// ponytail: board.mjs exports nothing and runs on import, so its parsers (the
// legs: block, the PR-bullet grammar, the redaction patterns, ciOf) are re-stated
// here, not imported; a change to one wants the same change in the other.
// ponytail: uptime assumes CLK_TCK=100 (every Linux the kit runs on); a leg's
// status age is the bullet's own HH:MM against today's clock, so a bullet from
// yesterday reads as up to 24 h younger than it is.
import { execFile } from 'node:child_process';
import { closeSync, existsSync, fstatSync, openSync, readFileSync, readSync, readdirSync, renameSync, statSync, writeFileSync } from 'node:fs';
import http from 'node:http';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const HERE = dirname(fileURLToPath(import.meta.url));
const run = promisify(execFile);

// ---------------------------------------------------------------- args
const USAGE = 'usage: fleet.mjs --doc <console doc> (--serve [--port 7788] | --out <file.html> | --json) [--logs <dir>] [--handover-root <dir>] [--repo <dir>]';
const args = process.argv.slice(2);
const opt = {};
for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--serve' || a === '--json') { opt[a.slice(2)] = true; continue; }
    if (!['--doc', '--out', '--logs', '--handover-root', '--repo', '--port'].includes(a) || args[i + 1] === undefined) {
        console.error(USAGE);
        process.exit(2);
    }
    opt[a.slice(2)] = args[++i];
}
if (!opt.doc || [opt.serve, opt.json, opt.out !== undefined].filter(Boolean).length !== 1) {
    console.error(USAGE);
    process.exit(2);
}
const port = opt.port === undefined ? 7788 : Number(opt.port);
if (!Number.isInteger(port) || port < 0 || port > 65535) {
    console.error(USAGE);
    process.exit(2);
}
const docPath = resolve(opt.doc);
if (!existsSync(docPath)) {
    console.error(`fleet: no such console doc: ${docPath}`);
    process.exit(1);
}
const bucket = dirname(docPath);
const repo = resolve(opt.repo || join(HERE, '..', '..', '..'));
const handoverRoot = resolve(opt['handover-root'] || process.env.HANDOVER_DIR || dirname(dirname(bucket)));
const logsDir = resolve(opt.logs || (process.env.XDG_RUNTIME_DIR
    ? join(process.env.XDG_RUNTIME_DIR, 'himmel-console')
    : join(process.env.TMPDIR || '/tmp', `himmel-console-${process.getuid ? process.getuid() : 0}`)));
const QUEUE_LOCK = process.env.FLEET_QUEUE_LOCK || join(repo, 'scripts', 'handover', 'queue-lock.sh');
const BANK = process.env.FLEET_BANK || join(repo, 'scripts', 'lib', 'bank-preflight.sh');
const GH = process.env.FLEET_GH || 'gh';
const PROC = process.env.FLEET_PROC || '/proc';
const LEGID = process.env.FLEET_LEGID || join(repo, 'scripts', 'lib', 'leg-identity.sh');
const AGENTS = process.env.FLEET_AGENTS ? [process.env.FLEET_AGENTS, []] : ['claude', ['agents', '--json']];

// ---------------------------------------------------------------- redaction
// Same patterns as board.mjs: `V-N255-93f72f64` nonces, `cachyos-x8664-pid909468`
// lock tokens, bare `pid<N>` and a `token \`...\`` span. Redact BEFORE clipping so a
// clip cannot cut a token into a fragment the patterns no longer match.
const redact = (s) => String(s)
    .replace(/\b[A-Z]{1,2}-[A-Za-z0-9][A-Za-z0-9._-]*-[0-9a-f]{6,}\b/g, '[nonce]')
    .replace(/\b[A-Za-z0-9_]+-[A-Za-z0-9_]+-pid\d+\b/g, '[lock]')
    .replace(/\bpid\d{4,}\b/g, '[pid]')
    .replace(/\b(tokens?|nonces?)(\s*[:=]?\s*)`[^`]*`/gi, '$1$2[redacted]');
const clip = (s, n) => (s.length > n ? `${s.slice(0, n - 1)}…` : s);
const safe = (s, n = Infinity) => clip(redact(String(s)).replace(/\x1b\[[0-9;]*[A-Za-z]/g, '').replace(/[\x00-\x08\x0b-\x1f\x7f]/g, ' '), n);
const deepRedact = (v) => {
    if (typeof v === 'string') return redact(v);
    if (Array.isArray(v)) return v.map(deepRedact);
    if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, deepRedact(x)]));
    return v;
};

// ---------------------------------------------------------------- helpers
const sh = async (cmd, cmdArgs, o = {}) => {
    try {
        const r = await run(cmd, cmdArgs, { encoding: 'utf8', timeout: o.timeout || 30000, cwd: o.cwd, maxBuffer: 16 << 20 });
        return { ok: true, out: r.stdout, err: r.stderr };
    } catch (e) {
        return { ok: false, out: e.stdout || '', err: e.stderr || '', spawnFailed: e.code === 'ENOENT' };
    }
};
const cache = new Map();
const cached = async (key, ttlMs, fn) => {
    const hit = cache.get(key);
    if (hit && Date.now() - hit.at < ttlMs) return hit.v;
    const v = await fn();
    cache.set(key, { at: Date.now(), v });
    return v;
};
const readText = (p) => { try { return readFileSync(p, 'utf8'); } catch { return null; } };
const tailLine = (p) => {
    let fd;
    try {
        fd = openSync(p, 'r');
        const st = fstatSync(fd);
        if (!st.isFile()) return '';
        const len = Math.min(st.size, 8192);
        const buf = Buffer.alloc(len);
        readSync(fd, buf, 0, len, st.size - len);
        const lines = buf.toString('utf8').split('\n').map((l) => l.trim()).filter(Boolean);
        return lines.length ? lines[lines.length - 1] : '';
    } catch { return ''; } finally { if (fd !== undefined) closeSync(fd); }
};
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
const ticketOf = (name) => (/^([A-Z][A-Z0-9]*-\d+)/.exec(name) || [])[1] || '';
const LABEL_RE = /^N\d+[a-z]*$/;

// ---------------------------------------------------------------- console doc
// The legs: block, read by tick.sh's grammar (mirrored in board.mjs): an entry is a
// backtick span of exactly four non-empty colon fields <label>:<nonce>:<lock>:<pid>.
// Only the label and the pid are kept; the nonce picks the doc, and is never rendered.
const LEG_LABEL_CLASS = /^[A-Za-z0-9_.-]+$/;
const parseLive = (text) => {
    const live = sectionOf(text.split('\n'), '## Live state', true);
    const entries = [];
    let inBlock = false;
    for (const l of live) {
        if (/^legs:/.test(l)) inBlock = true;
        else if (inBlock && (/^\s*$/.test(l) || /^[A-Za-z][A-Za-z ]*:/.test(l) || /^\s*([-*+]|\d+[.)])\s/.test(l) || /^\s*[>#]/.test(l))) inBlock = false;
        if (!inBlock) continue;
        for (const m of l.matchAll(/`([^`]*)`/g)) {
            const f = m[1].split(':');
            if (/\s/.test(m[1]) || f.length !== 4 || f.some((x) => !x) || !LEG_LABEL_CLASS.test(f[0])) continue;
            entries.push({ stem: f[0], nonce: f[1], pid: /^\d+$/.test(f[3]) ? Number(f[3]) : null });
        }
    }
    return entries;
};

// One bash call derives every leg's identity (label + the session names it may run
// under) from scripts/lib/leg-identity.sh, the one derivation the tick uses.
const identities = new Map();
const primeIdentities = async (names) => {
    const todo = [...new Set(names)].filter((n) => !identities.has(n));
    if (!todo.length) return true;
    const r = await sh('bash', ['-c', 'source "$1" || exit 1; shift; for s in "$@"; do leg_identity "$s"; done', 'bash', LEGID, ...todo], { timeout: 30000 });
    const lines = r.out.split('\n');
    todo.forEach((n, i) => {
        const [label, names2] = (lines[i] || '').split('\t');
        // Cache only a successful lookup, so a transient helper failure is retried (and re-warned) next snapshot.
        if (label) identities.set(n, { label, names: (names2 || '').split(',').filter(Boolean) });
    });
    return r.ok && todo.every((n) => identities.has(n));
};
const idOf = (name) => identities.get(name) || { label: '', names: [] };

// ---------------------------------------------------------------- leg docs
const STATUS_RE = /^- (?:(\d{1,2}):(\d{2})\s+)?(?:\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE)(?![A-Za-z0-9_])(.*)$/;
const PR_RE = /^- (?:\d{1,2}:\d{2}\s+)?(?:LIVE\s*[-–—:]?\s*PR\s*#?(\d{2,})\s+open\b|READY\s+#?(\d{2,})\s+[0-9a-f]{7,}|MERGED\s+#(\d{2,})\b)/;
const readLegDoc = (file, now) => {
    const text = readText(file);
    if (text === null) return null;
    const lines = text.split('\n');
    const bullets = sectionOf(lines, '## Results').filter((l) => l.startsWith('- '));
    let pr = null;
    let status = null;
    for (const b of bullets) {
        const pm = PR_RE.exec(b);
        if (pm) pr = Number(pm[1] || pm[2] || pm[3]);
        const sm = STATUS_RE.exec(b);
        if (sm) {
            let ageSec = null;
            let time = '';
            if (sm[1] !== undefined) {
                time = `${sm[1].padStart(2, '0')}:${sm[2]}`;
                const at = new Date(now);
                at.setHours(Number(sm[1]), Number(sm[2]), 0, 0);
                if (at > now) at.setDate(at.getDate() - 1);
                ageSec = Math.max(0, Math.round((now - at) / 1000));
            }
            status = { token: sm[3], time, ageSec, text: safe(sm[4].replace(/^[\s—–:-]+/, '').replace(/\*\*/g, ''), 220) };
        }
    }
    const model = (/^# .*\((claude-[^,)]+)/m.exec(text) || [])[1] || '';
    return { pr, status, model };
};

// ---------------------------------------------------------------- launch logs
// A leg's launch log: <name>.launch.log (or launch-<name>.log) under --logs, joined by
// file name or by a `name=` / `session=` / `for <name>` mention. Fields are read
// tolerantly: `headless=1`, the last `pid=`, `model=`, and a session-log path.
const indexLogs = () => {
    const files = [];
    const walk = (dir, depth) => {
        let ents = [];
        try { ents = readdirSync(dir, { withFileTypes: true }); } catch { return; }
        for (const e of ents) {
            const p = join(dir, e.name);
            if (e.isDirectory() && depth < 2) walk(p, depth + 1);
            else if (e.isFile() && e.name.endsWith('.log')) {
                try { files.push({ path: p, mtime: statSync(p).mtimeMs }); } catch { /* raced away */ }
            }
        }
    };
    walk(logsDir, 0);
    return files.sort((a, b) => b.mtime - a.mtime).slice(0, 400).map((f) => {
        let head = '';
        try {
            const fd = openSync(f.path, 'r');
            const buf = Buffer.alloc(8192);
            head = buf.toString('utf8', 0, readSync(fd, buf, 0, 8192, 0));
            closeSync(fd);
        } catch { /* unreadable: matched by name only */ }
        const stem = basename(f.path).replace(/\.log$/, '').replace(/\.launch$/, '').replace(/^launch-/, '').replace(/-launch$/, '');
        return { ...f, stem, head };
    });
};
const findLaunchLog = (logs, names) => {
    const esc = (n) => n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    for (const f of logs) {
        for (const n of names) {
            if (f.stem === n || new RegExp(`(?:name=|session=|for )${esc(n)}(?![A-Za-z0-9_.-])`).test(f.head)) return f;
        }
    }
    return null;
};
const lastMatch = (text, re) => { let v = ''; for (const m of text.matchAll(re)) v = m[1]; return v; };
const parseLaunch = (f) => ({
    headless: /\bheadless=1\b/.test(f.head),
    konsole: /konsole launched/.test(f.head),
    pid: Number(lastMatch(f.head, /(?:^|\s)pid=(\d+)/gm)) || null,
    model: lastMatch(f.head, /\bmodel=(\S+)/g),
    sessionLog: lastMatch(f.head, /\b(?:session[_-]?log|log[_-]?path|logfile|stdout[_-]?log)=(\S+)/g),
});

// ---------------------------------------------------------------- /proc
const procInfo = (pid) => {
    if (!pid) return { alive: false, known: false, argv: [], uptimeSec: null };
    const cmd = readText(join(PROC, String(pid), 'cmdline'));
    const stat = readText(join(PROC, String(pid), 'stat'));
    if (cmd === null || stat === null) return { alive: false, known: true, argv: [], uptimeSec: null };
    const rest = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
    if (rest[0] === 'Z' || rest[0] === 'X') return { alive: false, known: true, argv: [], uptimeSec: null };
    const up = parseFloat((readText(join(PROC, 'uptime')) || '').split(' ')[0]);
    const start = Number(rest[19]);
    const uptimeSec = Number.isFinite(up) && Number.isFinite(start) ? Math.max(0, Math.floor(up - start / 100)) : null;
    return { alive: true, known: true, argv: cmd.split('\0').filter(Boolean), uptimeSec };
};
const modelFromArgv = (argv) => {
    const i = argv.indexOf('--model');
    if (i >= 0 && argv[i + 1]) return argv[i + 1];
    const eq = argv.find((a) => a.startsWith('--model='));
    return eq ? eq.slice(8) : '';
};

// ---------------------------------------------------------------- sweep / bank / gh
const slugOf = (docFile) => relative(handoverRoot, docFile).replace(/\.md$/, '').split('/').join('__');
const readSweep = async () => {
    const r = await sh('bash', [QUEUE_LOCK, 'status', '--sweep', handoverRoot], { timeout: 30000 });
    const map = new Map();
    if (!r.out.includes('slug=')) return r.ok ? map : null;
    for (const l of r.out.split('\n')) {
        if (!l.startsWith('slug=')) continue;
        const f = Object.fromEntries([...l.matchAll(/(?:^|\s)([a-z]+)=(\S*)/g)].map((m) => [m[1], m[2]]));
        map.set(f.slug, f);
    }
    return map;
};
// `claude agents --json` lists the daemon's sessions, background ones included. A
// background-mode leg runs under the daemon with comm = the version string and its own
// argv/env, so neither a process-table census nor the launcher's cmdline finds it; the
// session NAME (-n) is the join key. null = command absent, failing, or not JSON.
const AG_DONE = /^(done|completed?|failed|error(ed)?|stopped|killed|exited|cancel(l)?ed|dead)$/i;
const readAgents = async () => {
    const r = await sh(AGENTS[0], AGENTS[1], { timeout: 20000 });
    let rows;
    try { rows = JSON.parse(r.out); } catch { return null; }
    if (!r.ok || !Array.isArray(rows)) return null;
    const rank = (a) => (a.kind === 'background' ? (AG_DONE.test(a.state || '') ? 2 : 0) : 1);
    const byName = new Map();
    for (const a of rows) {
        if (!a || typeof a.name !== 'string') continue;
        const cur = byName.get(a.name);
        if (!cur || rank(a) < rank(cur) || (rank(a) === rank(cur) && (a.startedAt || 0) > (cur.startedAt || 0))) byName.set(a.name, a);
    }
    return byName;
};
const readBank = async () => {
    const r = await sh('bash', [BANK], { timeout: 30000 });
    const text = `${r.out}\n${r.err}`;
    const total = /total=(\d+)\/(\d+)/.exec(text);
    const five = /five_hour=([\d.]+)/.exec(text);
    const seven = /seven_day=([\d.]+)/.exec(text);
    if (!total && !five) return null;
    return {
        fleet: total ? { live: Number(total[1]), cap: Number(total[2]) } : null,
        bank: five || seven ? { fiveHour: five ? five[1] : null, sevenDay: seven ? seven[1] : null } : null,
    };
};
const ciOf = (pr) => {
    const rollup = (pr && pr.statusCheckRollup) || [];
    if (!rollup.length) return 'pending';
    const verdict = (c) => c.conclusion || c.state || '';
    if (rollup.some((c) => ['FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'STARTUP_FAILURE', 'ACTION_REQUIRED'].includes(verdict(c)))) return 'failing';
    if (rollup.some((c) => (c.status ? c.status !== 'COMPLETED' : false) || ['', 'PENDING', 'EXPECTED'].includes(verdict(c)))) return 'pending';
    return 'green';
};
const ghJson = async (ghArgs) => {
    const r = await sh(GH, ghArgs, { cwd: repo, timeout: 45000 });
    if (!r.ok) return null;
    try { return JSON.parse(r.out); } catch { return null; }
};
const readOpenPrs = () => cached('open-prs', 60000, async () => {
    const v = await ghJson(['pr', 'list', '--state', 'open', '--limit', '100', '--json', 'number,title,headRefName,isDraft,statusCheckRollup']);
    return Array.isArray(v) ? v : null;
});
const prState = (n) => cached(`pr-state-${n}`, 300000, async () => {
    const v = await ghJson(['pr', 'view', String(n), '--json', 'state']);
    return v && v.state ? String(v.state).toLowerCase() : '';
});

// ---------------------------------------------------------------- snapshot
const ATTN = {
    blocked: 'needs a ruling (BLOCKED)',
    finding: 'needs a ruling (FINDING)',
    ready: 'READY — awaiting GO',
    'lock-lost': 'lock lost or stale while the process is alive',
    'proc-dead': 'process is dead but the lock is still held',
    'wrapped-alive': 'WRAPPED but the process is still alive (holds a fleet slot)',
};
const buildSnapshot = async () => {
    const now = new Date();
    const warnings = [];
    const docText = readFileSync(docPath, 'utf8');
    const entries = parseLive(docText);

    const docs = readdirSync(bucket).filter((f) => f.endsWith('-RESUME.md'));
    const idsOk = await primeIdentities([...entries.map((e) => e.stem), ...docs]);
    if (!idsOk) warnings.push('leg labels unavailable — some legs may be missing');

    const [sweep, bankInfo, openPrs, agents] = await Promise.all([cached('sweep', 4000, readSweep), cached('bank', 30000, readBank), readOpenPrs(), cached('agents', 4000, readAgents)]);
    if (agents === null) warnings.push('agents: unavailable — headless legs are found only through launch logs and /proc');
    if (sweep === null) warnings.push('queue-lock sweep unavailable — lock states unknown');
    if (bankInfo === null) warnings.push('bank-preflight unavailable — fleet and bank unknown');
    if (openPrs === null) warnings.push('gh unavailable — PR and CI state unknown');

    // One doc per Live-state entry: the doc its stem names, else -- among docs sharing
    // the label -- the one holding the entry's nonce, else the newest by mtime.
    const picked = new Map();
    for (const e of entries) {
        const label = idOf(e.stem).label;
        if (!label || picked.has(label)) continue;
        const exact = docs.find((f) => f === `${e.stem}.md` || f === `${e.stem}-RESUME.md`);
        const cands = docs.filter((f) => idOf(f).label === label).map((f) => join(bucket, f));
        const tokenRe = new RegExp(`(?<![A-Za-z0-9_.-])${e.nonce.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![A-Za-z0-9_.-])`);
        const holders = cands.filter((f) => tokenRe.test(readText(f) || ''));
        const pool = holders.length ? holders : cands;
        const file = exact ? join(bucket, exact) : (pool.length ? pool.reduce((a, b) => (statSync(a).mtimeMs >= statSync(b).mtimeMs ? a : b)) : null);
        picked.set(label, { entry: e, file, listed: true });
    }
    // A leg that holds a lock but is not in Live state still gets a row (the console
    // may have dispatched it and not yet edited the block).
    if (sweep) {
        for (const f of docs) {
            const label = idOf(f).label;
            if (!LABEL_RE.test(label) || picked.has(label) || !sweep.has(slugOf(join(bucket, f)))) continue;
            picked.set(label, { entry: null, file: join(bucket, f), listed: false });
        }
    }

    const logs = indexLogs();
    const openByNum = new Map((openPrs || []).map((p) => [p.number, p]));
    const legs = [];
    for (const [label, { entry, file, listed }] of picked) {
        const doc = file ? readLegDoc(file, now) : null;
        const stem = file ? basename(file, '.md') : (entry ? entry.stem : label);
        const names = file ? idOf(basename(file)).names : idOf(stem).names;
        const lk = file && sweep ? sweep.get(slugOf(file)) : undefined;
        const launch = (() => { const f = findLaunchLog(logs, names.length ? names : [stem]); return f ? parseLaunch(f) : null; })();
        const lockPid = lk ? Number((/pid(\d+)$/.exec(lk.session || '') || [])[1]) || null : null;
        // The daemon's row for this session (by name) is authoritative for a background
        // leg: its pid is the real session, not the launcher's wrapper.
        const ag = agents ? (names.length ? names : [stem]).map((n) => agents.get(n)).find(Boolean) || null : null;
        const agBg = !!ag && ag.kind === 'background';
        const agPid = ag && Number.isInteger(ag.pid) ? ag.pid : null;
        // A finished bg row says nothing about a live process (its pid may be reused or
        // stale); it only hints at the mode.
        const agRun = agBg && !AG_DONE.test(ag.state || '');
        const pid = (agRun && agPid) || (entry && entry.pid) || (launch && launch.pid) || lockPid || agPid || null;
        let proc = procInfo(pid);
        const sinceStart = ag && ag.startedAt ? Math.max(0, Math.floor((now - ag.startedAt) / 1000)) : null;
        if (agRun && !agPid) proc = { alive: true, known: true, argv: [], uptimeSec: sinceStart };
        else if (agRun && proc.alive && proc.uptimeSec === null) proc.uptimeSec = sinceStart;
        const exe = basename(proc.argv[0] || '');
        let mode = '?';
        if (agRun || (launch && launch.headless)) mode = 'headless';
        else if (exe === 'konsole') mode = 'headed';
        else if (proc.argv.includes('--bg') || proc.argv.includes('--background')) mode = 'headless';
        else if (launch && launch.konsole) mode = 'headed';
        else if (agBg) mode = 'headless';
        else if (ag) mode = 'headed';
        const model = modelFromArgv(proc.argv) || (launch && launch.model) || (doc && doc.model) || '';

        let lockState;
        let idle = false;
        if (sweep === null || !file) lockState = 'UNKNOWN';
        else if (lk) {
            idle = lk.status === 'IDLE-HELD?';
            lockState = lk.status === 'OK' || idle ? 'FRESH' : lk.status;
        } else lockState = doc && doc.status && doc.status.token === 'WRAPPED' ? 'WRAPPED' : 'FREE';
        const lockAge = lk && /^\d+s$/.test(lk.age || '') ? Number(lk.age.slice(0, -1)) : null;

        const ticket = ticketOf(stem);
        let prNum = doc ? doc.pr : null;
        if (!prNum && openPrs && ticket) {
            const hit = openPrs.find((p) => String(p.title).includes(`[${ticket}]`));
            if (hit) prNum = hit.number;
        }
        let pr = null;
        if (prNum) {
            const open = openByNum.get(prNum);
            let ci = '?';
            if (open) ci = ciOf(open);
            else if (openPrs !== null) ci = (await prState(prNum)) || '?';
            pr = { number: prNum, ci, draft: !!(open && open.isDraft) };
        }

        const tail = doc && doc.status ? doc.status.token : '';
        const attention = [];
        if (tail === 'BLOCKED' || tail === 'HALTED') attention.push('blocked');
        if (tail === 'FINDING') attention.push('finding');
        if (tail === 'READY') attention.push('ready');
        if (proc.alive && ['FREE', 'STALE', 'CORRUPT'].includes(lockState)) attention.push('lock-lost');
        if (proc.known && !proc.alive && ['FRESH', 'STALE'].includes(lockState)) attention.push('proc-dead');
        if (proc.alive && tail === 'WRAPPED') attention.push('wrapped-alive');

        let lastLine = '';
        if (launch && launch.sessionLog) lastLine = safe(tailLine(launch.sessionLog), 200);
        legs.push({
            label, ticket, model: safe(model, 60), mode, pid, alive: proc.alive, uptimeSec: proc.uptimeSec,
            lock: { state: lockState, ageSec: lockAge, idle },
            agent: ag ? { kind: ag.kind, state: safe(ag.state || ag.status || '', 30) } : null,
            status: doc ? doc.status : null, pr, lastLine, listed, hasDoc: !!file,
            attention: attention.map((code) => ({ code, text: ATTN[code] })),
        });
    }
    // Attention first, then live legs, then wrapped ones; by leg number within each.
    const rank = (l) => (l.attention.length ? 0 : l.lock.state === 'WRAPPED' ? 2 : 1);
    legs.sort((a, b) => rank(a) - rank(b) || parseInt(a.label.slice(1), 10) - parseInt(b.label.slice(1), 10) || a.label.localeCompare(b.label));
    return deepRedact({
        generatedAt: now.getTime(),
        console: basename(docPath, '.md'),
        fleet: bankInfo ? bankInfo.fleet : null,
        bank: bankInfo ? bankInfo.bank : null,
        warnings,
        legs,
    });
};

// ---------------------------------------------------------------- page
// The page renders the snapshot with textContent only (never innerHTML), so nothing a
// bullet or a log line says can become markup. The static snapshot embeds the same
// JSON with < > & escaped; the live page fetches api/fleet every 10 s.
const embed = (v) => JSON.stringify(v).replace(/</g, '\\u003c').replace(/>/g, '\\u003e').replace(/&/g, '\\u0026').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');
const page = (snap, live) => String.raw`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Fleet status</title>
<style>
:root { --bg:#f4f5f7; --surface:#fff; --text:#1a1f26; --muted:#56616d; --line:#d6dbe1; --accent:#1f4fb8; --ok:#17692f; --warn:#85560a; --bad:#b3202b; --tint:color-mix(in srgb, var(--bad) 9%, var(--surface)); --sel:#cfe0ff; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg:#0e1217; --surface:#161b22; --text:#e4e8ed; --muted:#9aa5b1; --line:#2a323c; --accent:#7aa2ff; --ok:#4cc26b; --warn:#e0a63a; --bad:#ff8079; --sel:#27407a; } }
:root[data-theme="dark"] { --bg:#0e1217; --surface:#161b22; --text:#e4e8ed; --muted:#9aa5b1; --line:#2a323c; --accent:#7aa2ff; --ok:#4cc26b; --warn:#e0a63a; --bad:#ff8079; --sel:#27407a; }
* { box-sizing:border-box; }
html { color-scheme:light dark; scrollbar-color:var(--line) var(--bg); }
body { margin:0; padding:16px; background:var(--bg); color:var(--text); font:14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; overflow-wrap:anywhere; }
::selection { background:var(--sel); color:var(--text); }
:focus-visible { outline:2px solid var(--accent); outline-offset:2px; }
main { max-width:1500px; margin:0 auto; }
.mono, .k { font-family:ui-monospace, "SF Mono", Menlo, Consolas, monospace; font-size:.9em; font-variant-numeric:tabular-nums; }
header { display:flex; flex-wrap:wrap; align-items:baseline; gap:6px 28px; margin:0 0 12px; }
h1 { font-size:1.25rem; margin:0; }
h2 { font-size:.95rem; margin:0 0 6px; }
.stats { display:flex; flex-wrap:wrap; gap:4px 24px; margin:0; }
.stats div { display:flex; gap:6px; align-items:baseline; }
.stats dt { color:var(--muted); } .stats dd { margin:0; font-weight:600; font-variant-numeric:tabular-nums; }
.banner { border:1px solid var(--warn); color:var(--warn); background:var(--surface); border-radius:6px; padding:6px 10px; margin:0 0 10px; }
.banner.bad { border-color:var(--bad); color:var(--bad); }
section { margin:0 0 16px; }
ul { list-style:none; margin:0; padding:0; }
.attn { border:1px solid var(--bad); border-radius:8px; background:var(--tint); padding:10px 12px; }
.attn li { padding:3px 0; } .attn .none { color:var(--ok); margin:0; }
.attn.clear { border-color:var(--line); background:var(--surface); }
.hdr, .row { display:grid; gap:4px 14px; padding:8px 12px; }
.hdr { display:none; color:var(--muted); font-size:.8rem; padding-top:0; padding-bottom:4px; }
.rows { border:1px solid var(--line); border-radius:8px; background:var(--surface); overflow:hidden; }
.row { border-top:1px solid var(--line); align-items:start; }
.row:first-child { border-top:0; }
.row[data-attn="1"] { background:var(--tint); }
.row[data-wrapped="1"] { opacity:.62; }
.c { min-width:0; }
.c[data-k]::before { content:attr(data-k) " "; color:var(--muted); font-size:.78rem; }
.lbl { font-weight:700; font-size:1.05rem; } .tk { color:var(--muted); }
.sub { color:var(--muted); font-size:.85rem; }
.tok { display:inline-block; border:1px solid currentColor; border-radius:4px; padding:0 6px; font-weight:700; font-size:.78rem; letter-spacing:.02em; }
.tok-BLOCKED, .tok-HALTED, .tok-FINDING { color:var(--bad); } .tok-READY { color:var(--warn); } .tok-LIVE, .tok-RESOLVED { color:var(--accent); } .tok-WRAPPED { color:var(--muted); }
.flag { display:inline-block; color:var(--bad); font-weight:600; font-size:.82rem; margin-top:2px; }
.st-FRESH, .ci-green, .alive { color:var(--ok); } .st-STALE, .st-FREE, .st-CORRUPT, .ci-failing, .dead { color:var(--bad); } .ci-pending { color:var(--warn); } .st-WRAPPED, .st-UNKNOWN { color:var(--muted); }
.dot::before { content:""; display:inline-block; width:.6em; height:.6em; border-radius:50%; background:currentColor; margin-right:.4em; }
.dead.dot::before { background:transparent; border:2px solid currentColor; width:.55em; height:.55em; }
.text { margin-top:2px; }
.log { color:var(--muted); }
.none { color:var(--muted); margin:0; padding:10px 12px; }
@media (min-width: 1000px) {
  .hdr { display:grid; }
  .hdr, .row { grid-template-columns:minmax(8rem,.9fr) minmax(8rem,.9fr) minmax(6.5rem,.7fr) minmax(6.5rem,.7fr) minmax(16rem,3fr) minmax(6rem,.8fr) minmax(10rem,2fr); }
  .c[data-k]::before { display:none; }
}
@media (max-width: 999px) { .row { grid-template-columns:1fr 1fr; } .c-leg, .c-status, .c-log { grid-column:1 / -1; } }
</style>
</head>
<body>
<main>
<header>
<h1>Fleet status</h1>
<dl class="stats">
<div><dt>Legs</dt><dd id="s-fleet">–</dd></div>
<div><dt>Bank 5h</dt><dd id="s-5h">–</dd></div>
<div><dt>Bank 7d</dt><dd id="s-7d">–</dd></div>
<div><dt>Needs the console</dt><dd id="s-attn">–</dd></div>
<div><dt id="s-when-k">Refreshed</dt><dd id="s-when">–</dd></div>
</dl>
</header>
<div id="banner" class="banner" role="status" hidden></div>
<section aria-labelledby="h-attn">
<h2 id="h-attn">Needs the console</h2>
<div id="attn" class="attn clear"></div>
</section>
<section aria-labelledby="h-legs">
<h2 id="h-legs">Legs</h2>
<div class="hdr" aria-hidden="true"><span>Leg</span><span>Runtime</span><span>Process</span><span>Lock</span><span>Latest status</span><span>PR · CI</span><span>Session log</span></div>
<ul id="legs" class="rows"></ul>
</section>
</main>
<script type="application/json" id="snap">${embed(snap)}</script>
<script>
const LIVE = ${live ? 'true' : 'false'};
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined && text !== null) e.textContent = text; return e; };
const dur = (s) => s === null || s === undefined ? '–' : s < 60 ? s + 's' : s < 3600 ? Math.round(s / 60) + 'm' : s < 86400 ? Math.floor(s / 3600) + 'h ' + Math.round((s % 3600) / 60) + 'm' : Math.floor(s / 86400) + 'd ' + Math.floor((s % 86400) / 3600) + 'h';
const clock = (ms) => new Date(ms).toLocaleTimeString([], { hour12: false });
const cell = (cls, key, kids) => { const c = el('div', 'c c-' + cls); c.dataset.k = key; for (const k of kids) c.append(k); return c; };
function row(l) {
  const li = el('li', 'row');
  if (l.attention.length) li.dataset.attn = '1';
  if (l.lock.state === 'WRAPPED') li.dataset.wrapped = '1';
  li.dataset.label = l.label;
  const leg = [el('span', 'lbl', l.label), document.createTextNode(' '), el('span', 'tk', l.ticket || '')];
  if (!l.listed) leg.push(el('div', 'sub', 'not in Live state'));
  if (!l.hasDoc) leg.push(el('div', 'sub', 'no handover doc'));
  for (const a of l.attention) leg.push(el('div', 'flag', a.text));
  const rt = [el('span', null, l.mode), el('div', 'sub mono', l.model || 'model ?')];
  const proc = [el('span', 'dot ' + (l.alive ? 'alive' : 'dead'), l.alive ? 'alive' : (l.pid ? 'dead' : 'no pid')), el('div', 'sub mono', (l.pid ? 'pid ' + l.pid : 'pid ?') + (l.alive ? ' · up ' + dur(l.uptimeSec) : '') + (l.agent && l.agent.kind === 'background' && l.agent.state ? ' · ' + l.agent.state : ''))];
  const lock = [el('span', 'st-' + l.lock.state, l.lock.state), el('div', 'sub', l.lock.ageSec === null ? '' : (l.lock.idle ? 'idle ' : 'beat ') + dur(l.lock.ageSec) + ' ago')];
  let st;
  if (l.status) {
    st = [el('span', 'tok tok-' + l.status.token, l.status.token), el('span', 'sub', ' ' + (l.status.ageSec === null ? (l.status.time || '') : dur(l.status.ageSec) + ' ago')), el('div', 'text', l.status.text)];
  } else st = [el('span', 'sub', 'no status bullet yet')];
  const pr = l.pr ? [el('span', 'mono', '#' + l.pr.number), el('div', 'sub ci-' + l.pr.ci, l.pr.ci + (l.pr.draft ? ' · draft' : ''))] : [el('span', 'sub', '–')];
  li.append(cell('leg', 'Leg', leg), cell('rt', 'Runtime', rt), cell('proc', 'Process', proc), cell('lock', 'Lock', lock), cell('status', 'Status', st), cell('pr', 'PR · CI', pr), cell('log', 'Log', [el('span', 'log mono', l.lastLine || '–')]));
  return li;
}
function render(s, note) {
  document.getElementById('s-fleet').textContent = s.fleet ? s.fleet.live + '/' + s.fleet.cap : '?';
  document.getElementById('s-5h').textContent = s.bank && s.bank.fiveHour !== null ? s.bank.fiveHour + '%' : '?';
  document.getElementById('s-7d').textContent = s.bank && s.bank.sevenDay !== null ? s.bank.sevenDay + '%' : '?';
  const need = s.legs.filter((l) => l.attention.length);
  document.getElementById('s-attn').textContent = String(need.length);
  document.getElementById('s-when').textContent = clock(s.generatedAt);
  document.title = (need.length ? '(' + need.length + ') ' : '') + 'Fleet status';
  const attn = document.getElementById('attn');
  attn.replaceChildren();
  attn.className = 'attn' + (need.length ? '' : ' clear');
  if (!need.length) attn.append(el('p', 'none', 'Nothing is waiting on the console.'));
  else {
    const ul = el('ul');
    for (const l of need) for (const a of l.attention) { const li = el('li'); li.append(el('b', null, l.label), document.createTextNode(' ' + a.text), el('div', 'sub', l.status ? l.status.text : '')); ul.append(li); }
    attn.append(ul);
  }
  const legs = document.getElementById('legs');
  legs.replaceChildren();
  if (!s.legs.length) legs.append(el('li', 'none', 'No legs found in the console doc\'s Live state.'));
  for (const l of s.legs) legs.append(row(l));
  const b = document.getElementById('banner');
  const msgs = [note].concat(s.warnings).filter(Boolean);
  b.hidden = !msgs.length;
  b.className = 'banner' + (note && LIVE ? ' bad' : '');
  b.textContent = msgs.join(' · ');
}
let last = null;
async function poll() {
  try {
    const r = await fetch('api/fleet', { cache: 'no-store' });
    if (!r.ok) throw new Error('http ' + r.status);
    last = await r.json();
    render(last, '');
  } catch (e) {
    if (last) render(last, 'Server unreachable — showing data from ' + clock(last.generatedAt) + '. Retrying every 10 s.');
    else { const b = document.getElementById('banner'); b.hidden = false; b.className = 'banner bad'; b.textContent = 'Waiting for the fleet server…'; }
  }
}
if (LIVE) { document.getElementById('s-when-k').textContent = 'Refreshed'; poll(); setInterval(poll, 10000); }
else { const s = JSON.parse(document.getElementById('snap').textContent); document.getElementById('s-when-k').textContent = 'Snapshot'; render(s, 'Static snapshot from ' + clock(s.generatedAt) + ' — not live.'); }
</script>
</body>
</html>
`;

// ---------------------------------------------------------------- snapshot cache
let inflight = null;
let lastSnap = null;
let lastAt = 0;
const getSnapshot = async () => {
    if (lastSnap && Date.now() - lastAt < 5000) return lastSnap;
    inflight ||= buildSnapshot().then((s) => { lastSnap = s; lastAt = Date.now(); return s; }).finally(() => { inflight = null; });
    return inflight;
};

// ---------------------------------------------------------------- modes
if (opt.json) {
    process.stdout.write(`${JSON.stringify(await buildSnapshot(), null, 1)}\n`);
} else if (opt.out !== undefined) {
    const outPath = resolve(opt.out);
    const tmp = `${outPath}.tmp${process.pid}`;
    writeFileSync(tmp, page(await buildSnapshot(), false));
    renameSync(tmp, outPath);
    console.log(outPath);
} else {
    // Loopback only, by construction: the host is a constant, not an option. The Host
    // header is checked too, so a page on another origin cannot read this server
    // through a DNS-rebinding name that resolves to 127.0.0.1.
    const HOST_OK = /^(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/i;
    const send = (res, status, type, body, extra = {}) => {
        res.writeHead(status, { 'content-type': type, 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', ...extra });
        res.end(body);
    };
    const server = http.createServer(async (req, res) => {
        try {
            if (!HOST_OK.test(req.headers.host || '')) return send(res, 403, 'text/plain; charset=utf-8', 'forbidden\n');
            if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'text/plain; charset=utf-8', 'read-only\n', { allow: 'GET, HEAD' });
            const path = new URL(req.url, 'http://localhost').pathname;
            if (path === '/') {
                return send(res, 200, 'text/html; charset=utf-8', req.method === 'HEAD' ? '' : page(null, true),
                    { 'content-security-policy': "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'" });
            }
            if (path === '/api/fleet') return send(res, 200, 'application/json; charset=utf-8', req.method === 'HEAD' ? '' : JSON.stringify(await getSnapshot()));
            return send(res, 404, 'text/plain; charset=utf-8', 'not found\n');
        } catch (e) {
            return send(res, 500, 'text/plain; charset=utf-8', 'snapshot failed\n');
        }
    });
    server.on('error', (e) => { console.error(`fleet: cannot listen on 127.0.0.1:${port}: ${e.code || e.message}`); process.exit(1); });
    server.listen(port, '127.0.0.1', () => console.log(`fleet: listening on http://127.0.0.1:${server.address().port}/`));
}
