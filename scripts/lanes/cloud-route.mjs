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
//                cloud lacks by design (luna, a vault, handover state, the state repo
//                or its specs: private data never leaves the station), more than 3 asks, or no file
//                named to scope a brief on. graphify and BM25 qmd over the repo
//                are not such a need: the cloud setup installs both (HIMMEL-4726).
//                qmd query, vector search and embeds are: it has no qmd models.
//                So is a semantic graphify run (/graphify, --backend): it would
//                send content to a model backend. Station-bound work is too
//                (HIMMEL-4969): ~/.himmel or ~/.cache state, a test VM
//                (himmel-ops:vm, vmsdk, VBoxManage), a LIVE ledger, arming a
//                cadence (at/systemd)
//   VERIFY-LOCAL (HIMMEL-5163) a merged PR cites the ticket key, or touches a
//                file it names, after the ticket was created: it may already be
//                fixed on main, so a local leg verifies it first (a cloud session
//                cannot tell, and spends credit on a no-op)
//   CLOUD-OK     everything else
import { readFileSync, appendFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { gitClean } from './git-clean.mjs';
import { dirname, join, resolve, posix } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..', '..');
const MAX_ASKS = 3;
const REPO_SLUG = 'yotamleo/Himmel';
const HOOKS = /^scripts\/hooks\//;
const NEEDS = /\bluna\b|\bvault\b|handover state|\$HANDOVER_DIR|\bstate[ -]repo\b|(?<![\w.-])handovers\/[\w.-]+\/|(?<![\w.-])specs\/HIMMEL-\d|\bqmd\s+(?:query|vsearch|embed|pull)\b|vector search|(?<![\w.-])\/graphify\b|semantic (?:graphify|extraction)|\bgraphify\b[^\n]*--backend|\bqmd\b[^\n]*?(?<![\w-])(?:-c|--collections?)[\s=]+['"]?(?!himmel(?![\w-]))[\w-]|(?:~|\$HOME|\$\{HOME\})\/\.(?:himmel|cache)\/|\btest VMs?\b|himmel-ops:vm|\bvmsdk\b|\bVBoxManage\b|\bLIVE\b[^\n.]{0,40}\bledger\b|\barm(?:s|ed|ing)?\b[^\n.]{0,40}\bcadence\b|\bsystemd[ -](?:timer|unit|service)s?\b|\batrm\b/i;
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

// Ask lines: the numbered or bulleted lines under an "Asks:" header, else any
// numbered line; a ticket with none is one ask.
export function askLines(description) {
  const lines = description.split('\n');
  const pick = (ls, re) => ls.filter((l) => re.test(l)).map((l) => l.trim());
  const at = lines.findIndex((l) => /^\s*asks?\s*:/i.test(l));
  const under = at >= 0 ? pick(lines.slice(at + 1), /^\s*(\d+[.)]|[-*])\s/) : [];
  return under.length ? under : pick(lines, /^\s*\d+[.)]\s/);
}

const overlaps = (a, b) => a === b || (b.endsWith('/') && a.startsWith(b)) || (a.endsWith('/') && b.startsWith(a));

const STALE_DAYS = 14;

// fixedBy(ticket, files, ctx) -> [{number, why, mergedAt}]: merged PRs that cite the key
// (not a longer one: HIMMEL-46860) or touch a named file, merged after the ticket was
// created. Jira's `get` carries no creation date, so without ticket.created (console spec)
// the cutoff is the last STALE_DAYS days. ponytail: a PR that merely lists the key as a
// deferral also matches, which only costs a local verify; narrow when it becomes noise.
export function fixedBy(t, files, ctx) {
  const parsed = Date.parse(t.created ?? '');
  const cutoff = Number.isNaN(parsed) ? (ctx.now ?? Date.now()) - STALE_DAYS * 86400e3 : parsed;
  const cites = new RegExp(`${t.key}(?!\\d)`);
  const out = [];
  for (const pr of ctx.merged ?? []) {
    const at = Date.parse(pr.mergedAt ?? '');
    if (Number.isNaN(at) || at < cutoff) continue;
    const paths = (pr.files ?? []).map((f) => (typeof f === 'string' ? f : f.path)).filter(Boolean);
    const hit = files.find((f) => paths.some((p) => overlaps(p, f)));
    if (cites.test(`${pr.title ?? ''}\n${pr.body ?? ''}`)) out.push({ number: pr.number, why: `cites ${t.key}`, mergedAt: pr.mergedAt });
    else if (hit) out.push({ number: pr.number, why: `touches ${hit}`, mergedAt: pr.mergedAt });
  }
  return out;
}

// classifyTicket(ticket, {trust, held, heldUnknown, merged, mergedUnknown, now}) -> {class, reason, files, asks, prs?}. Pure.
// held is [{file, why}]; ticket.files (console-supplied) overrides text extraction.
export function classifyTicket(t, ctx) {
  const files = (t.files?.length ? t.files : extractFiles(`${t.title}\n${t.description}`)).map((f) => posix.normalize(f));
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
  if (need) return v('LOCAL-NATIVE', `run-time need '${need[0]}' — luna, vaults, handover state, the state repo, qmd models, semantic graphify, ~/.himmel state, test VMs, live ledgers and cadence arming stay on the station (the cloud has AST-only graphify and BM25 qmd search over the repo only: no qmd models, so no qmd query, vector search or embed)`);
  if (asks > MAX_ASKS) return v('LOCAL-NATIVE', `${asks} asks (more than ${MAX_ASKS}) — cloud sessions drop second asks`);
  if (ctx.heldUnknown) return v('BLOCKED', 'open-PR file list unavailable (gh failed) — cannot prove the files are free');
  if (ctx.mergedUnknown) return v('BLOCKED', 'merged-PR list unavailable (gh failed) — cannot prove the ticket is not already fixed');
  const fixed = fixedBy(t, files, ctx);
  if (fixed.length) return { ...v('VERIFY-LOCAL', `may already be fixed on main — ${fixed.map((f) => `PR ${f.number} (${f.why}, merged ${String(f.mergedAt).slice(0, 10)})`).join('; ')}; verify locally before any cloud session`), prs: fixed.map((f) => f.number) };
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
  return `You are working in a cloud clone of the GitHub repo yotamleo/Himmel. This is a small, well-scoped task. Work only from this brief and the repo. You have no local state. Jira is reachable only through the Atlassian MCP connector (the local jira CLI is absent in the cloud), and that connector may not be enabled in your session. If the Atlassian MCP tools are listed in this session, use them; otherwise do not try a workaround, and list each skipped Jira step under a \`## Jira steps not done\` heading in the PR body so the local shepherd completes it. With the tools: read the ticket, comment, file follow-ups with the fixVersion this brief names. Either way, cite the ticket key in your commits and the PR. If the context7 MCP tools are listed in this session, use them for current library docs; otherwise WebFetch the library's own docs.

## Ticket ${t.key} (verbatim from Jira)

${t.raw}

## The change (verified against main on ${date}; line numbers are approximate — find the code by its text)

${change}

Files:
${named}

## How to do it
1. Read \`CLAUDE.md\` and these files in full before editing: ${files.join(' ')}
2. Claim the ticket: if the Atlassian MCP tools are listed, transition ${t.key} to \`In Progress\`; otherwise record "transition ${t.key} to In Progress" for the \`## Jira steps not done\` section (a cloud session has no handover doc and no queue lock; the ticket status is the claim).
3. Create the branch as a worktree BEFORE any edit: \`git worktree add -b ${branch} .claude/worktrees/himmel-${n} origin/main\`, and work inside it (the repo's edit-on-main guard denies edits in the cloud's primary clone, even on a feature branch).
   If you need repo retrieval, run \`bash scripts/cloud/setup-env.sh\` from this worktree first; it rebuilds the AST graph and repo-only index here. Query \`graphify query "<question>" --graph graphify-out/graph.json\`, never the unclassified cached /tmp graph. Search with \`bash scripts/lib/qmd-bounded.sh search "<terms>" -c himmel\`, never bare qmd search or a vault collection.
4. Edit ONLY these files: ${files.join(' ')}. Keep the diff minimal and match the surrounding style.
5. Write the new or changed test FIRST and show it RED without the fix, then green. Run \`shellcheck\` on every \`.sh\` file you touch. Report rc and the PASS/FAIL tail of each.
6. Make exactly ONE commit, never amend it. Before pushing, run the impacted suites: \`bash scripts/cr/impacted-suites.sh origin/main..HEAD --shell\` lists every suite that references a changed file, and \`bash scripts/ci/run-shell-tests.sh --impacted origin/main..HEAD\` runs them. A red suite is fixed in a NEW commit, never an amend.

    ${subject}

    <2-4 line body>

    Platforms tested: linux
    Security reviewed: manual — confirm the change only does what the ticket asks and widens no permission or check

7. Push the branch and open a PR to \`main\` titled \`${subject}\`. The body must include a summary, the files changed, the test/shellcheck/impacted-suite results, the line \`cloud-pilot: ${t.key} (console ${o.consoleId ?? 'unknown'})\`, the line \`completes-ticket: ${completes}\` a \`## Jira steps not done\` section listing each Jira step you skipped (write "none" if you did them all), and a \`## Ticket coverage\` section: one line per ask of the ticket, each ending \`done\` or \`deferred → HIMMEL-<n>\`. The asks:

${coverage}

8. Turn on \`/autofix-pr\` for the PR, so you fix your own CI reds and review comments.
9. Do NOT merge, do NOT request reviewers, and do NOT touch any other file.
10. Report (this replaces the handover doc): post ONE top-level PR comment whose first line is \`CLOUD-DONE <your session URL>\` followed by the PR head SHA and the test results, then, if the Atlassian MCP tools are listed, comment on ${t.key} with the PR URL (otherwise add that comment to \`## Jira steps not done\`). Leave the ticket \`In Progress\`: the local shepherd closes it at merge. Once a local shepherd comments on the PR, stop pushing to the branch. If you are blocked on a question, post it instead as a \`CLOUD-BLOCKED <your session URL>\` PR comment (a ${t.key} comment if no PR exists yet and the Atlassian MCP tools are listed; otherwise state the blocker in your final output) and end the session.

When done, print the PR URL, the branch, the commit SHA, and a 3-line summary.
`;
}

export function launchLine(briefPath) {
  const p = /^[\w./+@:-]+$/.test(briefPath) ? briefPath : `'${briefPath.replace(/'/g, `'\\''`)}'`;
  return `konsole --separate -e claude --cloud "$(cat ${p})" --permission-mode auto`;
}

// ---- I/O (CLI only) ----
function primaryCheckout() {
  const common = gitClean(['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd: REPO, encoding: 'utf8' }).trim();
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
  const nums = execFileSync(gh, ['pr', 'list', '--repo', REPO_SLUG, '--state', 'open', '--limit', '200', '--json', 'number', '--jq', '.[].number'], { encoding: 'utf8' }).split('\n').filter(Boolean);
  if (nums.length >= 200) throw new Error('200 open PRs listed — the list may be truncated');
  for (const num of nums) {
    for (const f of execFileSync(gh, ['pr', 'diff', num, '--repo', REPO_SLUG, '--name-only'], { encoding: 'utf8' }).split('\n').filter(Boolean)) out.push({ file: f, why: `open PR ${num}` });
  }
  return out;
}

// One shared list of PRs merged since STALE_DAYS ago (the file-overlap rule) plus one
// search per ticket (PRs citing the key, any age), through the same gh the open-PR list
// uses. Deduplicated by number.
function mergedPrs(keys) {
  const gh = process.env.CLOUD_ROUTE_GH_CMD || 'gh';
  const run = (extra) => JSON.parse(execFileSync(gh, ['pr', 'list', '--repo', REPO_SLUG, '--state', 'merged', '--json', 'number,title,body,mergedAt,files', ...extra], { encoding: 'utf8', timeout: 60000 }) || '[]');
  const since = new Date(Date.now() - STALE_DAYS * 86400e3).toISOString().slice(0, 10);
  const all = new Map();
  for (const pr of run(['--limit', '200', '--search', `merged:>=${since}`])) all.set(pr.number, pr);
  for (const k of keys) for (const pr of run(['--limit', '30', '--search', `${k} in:title,body`])) all.set(pr.number, pr);
  return [...all.values()];
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
  let merged = [];
  let mergedUnknown = false;
  try { merged = mergedPrs(keys); } catch (e) { mergedUnknown = true; process.stderr.write(`cloud-route: gh failed, merged PRs unknown — ${e.message.split('\n')[0]}\n`); }
  const ctx = { trust: loadTrust(), held, heldUnknown, merged, mergedUnknown };
  const date = new Date().toISOString().slice(0, 10);
  const launches = [];
  if (!opt.classifyOnly) mkdirSync(opt.bucket, { recursive: true });

  for (const key of keys) {
    const s = spec[key] ?? {};
    const t = { ...fetchTicket(key), ...(s.files ? { files: s.files } : {}), ...(s.created ? { created: s.created } : {}) };
    const v = classifyTicket(t, ctx);
    process.stdout.write(`${key}\t${v.class}\t${v.reason}\n`);
    if (v.class === 'CLOUD-OK') held.push(...v.files.map((file) => ({ file, why: `routed ${key} this run` })));
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
