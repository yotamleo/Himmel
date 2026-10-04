// scripts/lanes/cloud-route.mjs
// HIMMEL-4262 — classify tickets for the cloud credit lane, write the brief,
// print the operator launch line.
//
// A sibling of fanout-plan.mjs, not an extension of it: /fanout routes an
// abstract work item to a model tier through a pure function, while this gates a
// real Jira ticket (live Jira + gh reads) and writes files into the console
// bucket. It NEVER launches a session — `claude --cloud` needs a TTY in the
// operator's terminal and spends credit, so the tool only prints the line.
//
// Classes, first match wins:
//   BLOCKED      ticket not To Do, the open-PR/held-file list is unknown, or a
//                file it touches is held (one writer per file)
//   HOOK-BYPASS  touches scripts/hooks/ (hooks do not run in the cloud, and the
//                integrity guard locks hook edits out of a normal leg)
//   LOCAL-NATIVE a trust path (needs a trust-reviewed GO), a run-time need the
//                cloud lacks (Jira, qmd, graphify, luna, handover state), more
//                than 3 asks, or no file named to scope a brief on
//   CLOUD-OK     everything else
import { readFileSync, appendFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..', '..');
const MAX_ASKS = 3;
const HOOKS = /^scripts\/hooks\//;
const NEEDS = /\bqmd\b|\bgraphify\b|\bluna\b|\bvault\b|handover state|\$HANDOVER_DIR|\bjira (cli|api|write|comment|transition|issue|ticket)/i;
const FILE_RE = /(?<![\w./-])((?:scripts|docs|marketplace|templates|tools|\.claude|\.github|\.codex)\/[\w.+@-]+(?:\/[\w.+@-]+)*\/?|CLAUDE\.md|AGENTS\.md|\.pre-commit-config\.yaml)/g;

// The trust list is read as data, one extended regex per line (ci-trust-paths.txt).
export function loadTrust(path = join(REPO, 'scripts', 'ci', 'ci-trust-paths.txt')) {
  return readFileSync(path, 'utf8').split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#')).map((l) => new RegExp(l));
}

export function parseJiraGet(raw) {
  const text = raw.trimEnd();
  const nl = text.indexOf('\n');
  const [key, type, status, ...title] = (nl < 0 ? text : text.slice(0, nl)).split('\t');
  return { key, type, status, title: title.join('\t'), description: nl < 0 ? '' : text.slice(nl + 1).trim(), raw: text };
}

export function extractFiles(text) {
  const out = [];
  for (const m of text.matchAll(FILE_RE)) {
    const f = m[1].replace(/[.,;:)\]-]+$/, '');
    if (f && !out.includes(f)) out.push(f);
  }
  return out;
}

// Ask lines: the numbered lines under an "Asks:" header, else any numbered
// line; a ticket with none is one ask.
export function askLines(description) {
  const lines = description.split('\n');
  const numbered = (ls) => ls.filter((l) => /^\s*\d+[.)]\s/.test(l)).map((l) => l.trim());
  const at = lines.findIndex((l) => /^\s*asks?\s*:/i.test(l));
  const under = at >= 0 ? numbered(lines.slice(at + 1)) : [];
  return under.length ? under : numbered(lines);
}

const overlaps = (a, b) => a === b || (b.endsWith('/') && a.startsWith(b)) || (a.endsWith('/') && b.startsWith(a));

// classifyTicket(ticket, {trust, held, heldUnknown}) -> {class, reason, files, asks}. Pure.
// held is [{file, why}]; ticket.files (console-supplied) overrides text extraction.
export function classifyTicket(t, ctx) {
  const files = t.files?.length ? t.files : extractFiles(`${t.title}\n${t.description}`);
  const asks = Math.max(1, askLines(t.description).length);
  const v = (cls, reason) => ({ class: cls, reason, files, asks });

  if (!/^(to do|backlog|open)$/i.test(t.status ?? '')) return v('BLOCKED', `status is '${t.status}', not To Do — already in flight or done`);
  if (!files.length) return v('LOCAL-NATIVE', 'no file named in the ticket — nothing to scope a brief on (pass files)');
  for (const f of files) {
    const h = (ctx.held ?? []).find((x) => overlaps(f, x.file));
    if (h) return v('BLOCKED', `${f} is held (${h.why}) — one writer per file`);
  }
  const hook = files.find((f) => HOOKS.test(f));
  if (hook) return v('HOOK-BYPASS', `touches ${hook} — hooks do not run in the cloud and edits need the hook-integrity bypass`);
  const trust = files.find((f) => (ctx.trust ?? []).some((re) => re.test(f)));
  if (trust) return v('LOCAL-NATIVE', `touches trust path ${trust} — needs a trust-reviewed GO`);
  const need = `${t.title}\n${t.description}`.match(NEEDS);
  if (need) return v('LOCAL-NATIVE', `run-time need '${need[0]}' — the cloud has no Jira, qmd, graphify, luna or handover state`);
  if (asks > MAX_ASKS) return v('LOCAL-NATIVE', `${asks} asks (more than ${MAX_ASKS}) — cloud sessions drop second asks`);
  if (ctx.heldUnknown) return v('BLOCKED', 'open-PR file list unavailable (gh failed) — cannot prove the files are free');
  return v('CLOUD-OK', `${files.length} file(s), ${asks} ask(s), no hook, trust path or run-time need, none held`);
}

const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').split('-').slice(0, 6).join('-').slice(0, 40).replace(/-$/, '');

// buildBrief(ticket, opts) -> string, following docs/handover/cloud-brief-template.md.
export function buildBrief(t, o = {}) {
  const n = t.key.replace(/^HIMMEL-/, '');
  const date = o.date ?? new Date().toISOString().slice(0, 10);
  const type = o.branchType ?? (/^bug$/i.test(t.type) ? 'fix' : 'feat');
  const branch = `${type}/himmel-${n}-${slug(t.title)}`;
  const subject = `${type}: [${t.key}] ${t.title.toLowerCase()}`;
  const files = t.files?.length ? t.files : extractFiles(`${t.title}\n${t.description}`);
  const exists = o.exists ?? (() => true);
  const named = files.map((f) => `- \`${f}\`${exists(f) ? '' : ' (not on main: create it)'}`).join('\n');
  const asks = askLines(t.description);
  const coverage = asks.length ? asks.map((a) => `- ${a.replace(/^\d+[.)]\s*/, '')} — done`).join('\n') : `- ${t.title} — done`;
  const completes = o.completes ?? 'yes';
  const change = o.change ?? "Implement the ticket's asks above, in the named files only.";
  return `You are working in a cloud clone of the GitHub repo yotamleo/Himmel. This is a small, well-scoped task. Work only from this brief: you cannot reach Jira or any local state.

## Ticket ${t.key} (verbatim from Jira)

${t.raw}

## The change (verified against main on ${date}; line numbers are approximate — find the code by its text)

${change}

Files:
${named}

## How to do it
1. Read \`CLAUDE.md\` and these files in full before editing: ${files.join(' ')}
2. Create branch \`${branch}\` from \`main\` BEFORE any edit (the repo's edit-on-main guard denies edits on \`main\`).
3. Edit ONLY these files: ${files.join(' ')}. Keep the diff minimal and match the surrounding style.
4. Write the new or changed test FIRST and show it RED without the fix, then green. Run \`shellcheck\` on every \`.sh\` file you touch. Report rc and the PASS/FAIL tail of each.
5. Make exactly ONE commit, never amend it. Before pushing, run the impacted suites: \`bash scripts/cr/impacted-suites.sh origin/main..HEAD --shell\` lists every suite that references a changed file, and \`bash scripts/ci/run-shell-tests.sh --impacted origin/main..HEAD\` runs them. A red suite is fixed in a NEW commit, never an amend.

    ${subject}

    <2-4 line body>

    Platforms tested: linux
    Security reviewed: manual — confirm the change only does what the ticket asks and widens no permission or check

6. Push the branch and open a PR to \`main\` titled \`${subject}\`. The body must include a summary, the files changed, the test/shellcheck/impacted-suite results, the line \`cloud-pilot: ${t.key} (console ${o.consoleId ?? 'unknown'})\`, the line \`completes-ticket: ${completes}\` and a \`## Ticket coverage\` section: one line per ask of the ticket, each ending \`done\` or \`deferred → HIMMEL-<n>\`. The asks:

${coverage}

7. Turn on \`/autofix-pr\` for the PR, so you fix your own CI reds and review comments.
8. Do NOT merge, do NOT request reviewers, and do NOT touch any other file.

When done, print the PR URL, the branch, the commit SHA, and a 3-line summary.
`;
}

export function launchLine(briefPath) {
  const p = /^[\w./+@:-]+$/.test(briefPath) ? briefPath : `'${briefPath.replace(/'/g, `'\\''`)}'`;
  return `konsole --separate -e claude --cloud "$(cat ${p})" --permission-mode auto`;
}

// ---- I/O (CLI only) ----
function primaryCheckout() {
  const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd: REPO, encoding: 'utf8' }).trim();
  return dirname(common);
}

function fetchTicket(key) {
  const cmd = process.env.CLOUD_ROUTE_JIRA_CMD;
  const [bin, args] = cmd ? [cmd, ['get', key]] : [process.execPath, [join(primaryCheckout(), 'scripts/jira/dist/index.js'), 'get', key]];
  return parseJiraGet(execFileSync(bin, args, { encoding: 'utf8', env: { JIRA_PROJECT_KEY: 'HIMMEL', ...process.env } }));
}

function openPrFiles() {
  const gh = process.env.CLOUD_ROUTE_GH_CMD || 'gh';
  const out = [];
  const nums = execFileSync(gh, ['pr', 'list', '--state', 'open', '--limit', '200', '--json', 'number', '--jq', '.[].number'], { encoding: 'utf8' }).split('\n').filter(Boolean);
  for (const num of nums) {
    for (const f of execFileSync(gh, ['pr', 'diff', num, '--name-only'], { encoding: 'utf8' }).split('\n').filter(Boolean)) out.push({ file: f, why: `open PR ${num}` });
  }
  return out;
}

function main(argv) {
  const opt = { bucket: null, console: null, held: null, spec: null, classifyOnly: false };
  const keys = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--bucket') opt.bucket = argv[++i];
    else if (a === '--console') opt.console = argv[++i];
    else if (a === '--held') opt.held = argv[++i];
    else if (a === '--spec') opt.spec = argv[++i];
    else if (a === '--classify-only') opt.classifyOnly = true;
    else keys.push(a);
  }
  if (!keys.length || (!opt.classifyOnly && (!opt.bucket || !opt.console))) {
    process.stderr.write('usage: cloud-route.mjs [--classify-only] --bucket <dir> --console <id> [--held <file>] [--spec <json>] HIMMEL-<n>...\n');
    return 2;
  }
  const spec = opt.spec ? JSON.parse(readFileSync(opt.spec, 'utf8')) : {};
  const held = opt.held ? readFileSync(opt.held, 'utf8').split('\n').map((l) => l.trim()).filter(Boolean).map((file) => ({ file, why: 'console held list' })) : [];
  let heldUnknown = false;
  try { held.push(...openPrFiles()); } catch (e) { heldUnknown = true; process.stderr.write(`cloud-route: gh failed, open-PR files unknown — ${e.message.split('\n')[0]}\n`); }
  const ctx = { trust: loadTrust(), held, heldUnknown };
  const date = new Date().toISOString().slice(0, 10);
  const launches = [];
  if (!opt.classifyOnly) mkdirSync(opt.bucket, { recursive: true });

  for (const key of keys) {
    const s = spec[key] ?? {};
    const t = { ...fetchTicket(key), ...(s.files ? { files: s.files } : {}) };
    const v = classifyTicket(t, ctx);
    process.stdout.write(`${key}\t${v.class}\t${v.reason}\n`);
    let brief = null;
    if (!opt.classifyOnly) {
      if (v.class === 'CLOUD-OK') {
        brief = join(resolve(opt.bucket), `cloud-brief-${key}.md`);
        const exists = (f) => existsSync(join(REPO, f));
        writeFileSync(brief, buildBrief({ ...t, files: v.files }, { consoleId: opt.console, date, exists, change: s.change, branchType: s.branchType, completes: s.completes }));
        launches.push(launchLine(brief));
      }
      appendFileSync(join(opt.bucket, 'cloud-route.jsonl'), JSON.stringify({ ticket: key, class: v.class, reason: v.reason, brief, time: new Date().toISOString() }) + '\n');
    }
  }
  if (launches.length) process.stdout.write(`\nOperator launch lines (run each in your terminal; this tool never launches):\n${launches.join('\n')}\n`);
  return 0;
}

if (process.argv[1]?.endsWith('cloud-route.mjs')) {
  try { process.exit(main(process.argv.slice(2))); }
  catch (e) { process.stderr.write(`cloud-route: ${e.message}\n`); process.exit(1); }
}
