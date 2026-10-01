// tracker-model-check.js <page.html> — HIMMEL-3990. Runs the pure model block of a rendered tracker page
// (between /*MODEL*/ and /*END MODEL*/) against a synthetic data set and against the page's own data.
// Prints one "ok - " / "FAIL - " line per check, like test-tracker.sh, which calls it. No network, no DOM.
'use strict';
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
let fails = 0;
const say = (ok, name, got) => {
    if (ok) console.log('ok - ' + name);
    else { console.log('FAIL - ' + name + ' (got ' + JSON.stringify(got) + ')'); fails++; }
};
const eq = (name, got, want) => say(JSON.stringify(got) === JSON.stringify(want), name, got);
const a = html.indexOf('/*MODEL*/'), b = html.indexOf('/*END MODEL*/');
if (a < 0 || b < a) { console.log('FAIL - the page carries a /*MODEL*/ block (HIMMEL-3990)'); console.log('1 failure(s)'); process.exit(1); }
const model = new Function(html.slice(a, b) + '\nreturn model;')();
const nums = (rows) => rows.map((p) => p[0]);

// Synthetic plan: v1.0.1 running, v1.0.2 queued, v2/v3 deferred (no caps); themes tooling, handover.
// row: num,title,st,ver,layer,theme,mid,flag,notes,user_impact,erange,ready,impact,slice,issue_plain,load
const P = [
    [10, 'done fix', 2, 0, 0, 0, 1, 0, [], 'Users get A', 'S', 4, 5, '', 'plain A', 0.009],
    [11, 'leg fix', 1, 0, 0, 0, 2, 0, [], 'Users get B', 'M', 3, 3, '', 'plain B', 0.018],
    [12, 'tidy', 0, 0, 1, 1, 1, 0, [], 'Internal: tidy C', 'S', 2, 4, '', '', 0.009],
    [13, 'off plan', 0, 0, 1, 1, 0, 2, [], '', '', null, null, '', '', 0],
    [14, 'later', 0, 1, 2, 0, 1, 0, [], 'Users get D', 'S', 3, 2, '', '', 0.009],
    [15, 'parked', 0, 2, 2, 1, 5, 0, [], 'Users get E', 'L', 1, 1, '', '', 0.045],
];
const caps = { t: 20, tot: 0.6, l: [0.01, 0.1, 0.1, 0.1, 0.1] };
const D = { V: ['v1.0.1', 'v1.0.2', 'v2/v3'], T: ['tooling', 'handover'], P, VC: [caps, caps, null],
    LEG: { 11: ['N9', 'LIVE', 77], 10: ['N8', 'READY', 70] } };
const M = model(D);

// Every number drills to its tickets.
eq('the version tally counts done, in progress, to do and live legs (HIMMEL-3990)', M.tally(M.inV(0)),
    { n: 4, done: 1, prog: 1, todo: 2, live: 1, left: 3 });
eq('done % drills to the done tickets (HIMMEL-3990)', nums(M.drill('done', { v: 0 })), [10]);
eq('what is left drills to open tickets, live leg first (HIMMEL-3990)', nums(M.drill('left', { v: 0 })), [11, 12, 13]);
eq('the legs figure drills to the tickets a leg is on (HIMMEL-3990)', nums(M.drill('live', { v: 0 })), [11]);
eq('the started-no-leg figure drills to started tickets without a leg (HIMMEL-3990)', nums(M.drill('prog', { v: 0 })), []);
eq('a done ticket shows no leg even if its doc lingers (HIMMEL-3990)', M.leg(P[0]), null);
eq('a theme drills across the train only (HIMMEL-3990)', nums(M.drill('all', { t: 0 })), [11, 14, 10]);
eq('the train figure spans every v1.0.x version (HIMMEL-3990)', M.tally(M.inTrain()).n, 5);

// Budget by kind and by ticket, against the version's own caps.
const ld = M.load(0);
eq('the version budget sums planned tickets only (HIMMEL-3990)', [ld.used, ld.cap, ld.planned, ld.tcap], [0.036, 0.6, 3, 20]);
eq('a kind carries its tickets, heaviest first (HIMMEL-3990)', nums(ld.kinds[0].tickets), [11, 10]);
eq('a kind over its cap is flagged with negative headroom (HIMMEL-3990)', [ld.kinds[0].used, ld.kinds[0].over, ld.kinds[0].head], [0.027, true, -0.017]);
eq('a kind under its cap has headroom (HIMMEL-3990)', [ld.kinds[1].used, ld.kinds[1].over, ld.kinds[1].head], [0.009, false, 0.091]);
eq('an off-plan ticket adds no budget (HIMMEL-3990)', nums(ld.kinds[1].tickets), [12]);
eq('the deferred bucket has no cap (HIMMEL-3990)', [M.load(2).deferred, M.load(2).cap], [true, null]);

// Summaries: deterministic words from user impact.
const s0 = M.summary(M.inV(0), 'theme');
eq('the version summary leads with user changes by theme (HIMMEL-3990)', s0.lead,
    'Ships 2 changes for users and 1 internal one; mostly tooling (2).');
eq('the summary quotes the top ticket of each theme verbatim (HIMMEL-3990)', s0.quotes.map((q) => q.text), ['Users get A']);
eq('an internal-only set reads as housekeeping (HIMMEL-3990)', M.summary([P[2]], 'theme').lead, 'Housekeeping only: 1 internal change.');
eq('a theme summary names its version span (HIMMEL-3990)', M.summary(M.inT(0), 'version').lead,
    'Ships 3 changes for users, from v1.0.1 to v1.0.2.');

// Remaining only: done tickets leave every list, and every figure recomputes.
eq('remaining-only drops done tickets from the tally (HIMMEL-3990)', M.tally(M.inV(0, true)),
    { n: 3, done: 0, prog: 1, todo: 2, live: 1, left: 3 });
eq('remaining-only empties the done drill-down (HIMMEL-3990)', M.drill('done', { v: 0 }, true), []);
eq('remaining-only recomputes the budget (HIMMEL-3990)', [M.load(0, true).used, nums(M.load(0, true).kinds[0].tickets)], [0.027, [11]]);
eq('remaining-only recomputes the summary (HIMMEL-3990)', [M.summary(M.inV(0, true), 'theme').lead, M.summary(M.inV(0, true), 'theme').quotes[0].text],
    ['Ships 1 change for users and 1 internal one; mostly tooling (1).', 'Users get B']);

// Trail versions: a trail reads as its parent's overflow, belongs to the train, and shows its P90 (cautious load).
const M2 = model({ V: ['v1.0.1', 'v1.0.1b', 'v1.0.2', 'v1.0.2c', 'v2/v3'], T: ['tooling'], P: [],
    VC: [caps, Object.assign({ p9: 0.8 }, caps), caps, caps, null], VP: [0.7, 0.05, null, null, null] });
eq('a trail is named as its parent overflow (HIMMEL-3990)', [0, 1, 2, 3, 4].map(M2.vname),
    ['v1.0.1', 'v1.0.1 · overflow', 'v1.0.2', 'v1.0.2 · overflow 2', 'v2/v3']);
eq('a trail rides the v1.0.x train (HIMMEL-3990)', [M2.train(1), M2.train(3), M2.train(4)], [true, true, false]);
eq('the budget carries the P90 and its cap (HIMMEL-3990)', [M2.load(1).p90, M2.load(1).p90cap, M2.load(0).p90cap], [0.05, 0.8, null]);

// Steering (the release desk): a peel moves the lowest-return movable tickets out until every cap holds; pinned, leg and
// done tickets never move; the what-if shows both versions before and after; the decisions queue orders what needs input.
const c3 = { t: 3, tot: 0.05, l: [0.1, 0.1, 0.1, 0.1, 0.1], p9: 0.08 };
const row = (n, st, v, mid, imp, flag) => [n, 't' + n, st, v, 0, 0, mid, flag || 0, [], 'Users get ' + n, 'S', 3, imp, '', '', flag === 2 ? 0 : mid * 0.009];
const M3 = model({ V: ['v1.0.1', 'v1.0.1b', 'v1.0.2', 'v2/v3'], T: ['tooling'], CUR: 0, PIN: [23],
    P: [row(20, 2, 0, 1, 5), row(21, 0, 0, 2, 1), row(22, 0, 0, 1, 4), row(23, 0, 0, 3, 3), row(24, 0, 0, 1, 1),
        row(25, 0, 1, 1, 5), row(26, 0, 2, 1, 2, 1)],
    VC: [c3, c3, c3, null], VP: [0.1, null, null, null], U: [[30, 'x', 0, 'why']],
    LEG: { 24: ['N1', 'LIVE', 5], 25: ['N2', 'BLOCKED', null] } });
const r3 = (x) => Math.round(x * 1e4) / 1e4;
eq('a trail follows its parent, the next letter follows a trail (HIMMEL-3990)', [M3.trail(0), M3.trail(2), M3.trail(1)],
    [{ i: 1, name: 'v1.0.1b' }, { i: -1, name: 'v1.0.2b' }, { i: -1, name: 'v1.0.1c' }]);
eq('the full version breaches its mean, ticket and P90 caps (HIMMEL-3990)', M3.breaches(0, M3.stats(0, M3.inV(0))).map((b) => b.what),
    ['mean', 'tickets', 'P90']);
const pk = M3.peel(0);
eq('a peel moves the lowest-return movable tickets until every cap holds (HIMMEL-3990)', [nums(pk.moved), pk.left, nums(pk.held)], [[21, 22], [], [23]]);
eq('unpinning a ticket lets the peel take it (HIMMEL-3990)', nums(M3.peel(0, { unpin: [23] }).moved), [21, 23]);
const pk2 = M3.peel(0, { keep: [21] });
eq('keeping a ticket that is needed leaves the caps breached (HIMMEL-3990)', [nums(pk2.moved), pk2.left.map((b) => b.what)], [[22], ['mean', 'tickets', 'P90']]);
const w = M3.whatIf(0, pk.moved, 1);
eq('the what-if shows the source before and after (HIMMEL-3990)', [w.from.before.n, r3(w.from.before.m), w.from.after.n, r3(w.from.after.m), r3(w.from.after.p9), w.from.after.b],
    [5, 0.072, 3, 0.045, 0.0625, []]);
eq('the what-if shows the target before and after, under its own caps (HIMMEL-3990)', [w.to.before.n, r3(w.to.before.m), w.to.after.n, r3(w.to.after.m), w.to.after.b],
    [1, 0.009, 3, 0.036, []]);
eq('a new trail starts empty and keeps its parent caps (HIMMEL-3990)', [M3.whatIf(2, [], -1).to.before.n, M3.whatIf(0, pk.moved, -1).to.after.b], [0, []]);
eq('decisions: a stopped leg first, the running version cap, then drift and the unplaced (HIMMEL-3990)',
    M3.decisions().map((d) => d.type + ':' + d.band + ':' + (d.p ? d.p[0] : d.i)), ['leg:0:25', 'cap:1:0', 'drift:2:26', 'unplaced:2:1']);
eq('what we gained lists done work by version, newest first (HIMMEL-3990)', M3.gains().map((g) => [g.i, nums(g.done)]), [[0, [20]]]);
const M4 = model({ V: ['v1.0.1', 'v1.0.1b'], T: ['tooling'], CUR: 0, P: [row(40, 0, 0, 1, 2), row(41, 0, 1, 1, 5), row(42, 0, 1, 4, 1)],
    VC: [c3, c3], VP: [null, null], U: [], LEG: {} });
eq('fold back takes trail work by best return while the parent stays in its caps (HIMMEL-3990)', nums(M4.fold(1)), [41]);
eq('a trail whose parent has room is a decision (HIMMEL-3990)', M4.decisions().map((d) => d.type + ':' + d.i), ['fold:1']);

// The page's own data runs through the same model (the Python blob and the JS agree on shapes).
const m = /<script type="application\/json" id="data">([\s\S]*?)<\/script>/.exec(html);
const R = model(JSON.parse(m[1]));
const r1 = R.drill('live', { v: 0 });
eq('the rendered data: the live leg ticket drills from the legs figure (HIMMEL-3990)', [nums(r1), R.leg(r1[0])], [[1], ['N55', 'LIVE', 1525]]);
eq('the rendered data: the planned ticket loads its kind (HIMMEL-3990)', [R.load(0).kinds[0].used, nums(R.load(0).kinds[0].tickets)], [0.009, [1]]);
eq('the rendered data: the row text is the user impact (HIMMEL-3990)', r1[0][9], 'changed impact');

console.log(fails + ' failure(s)');
process.exit(fails ? 1 : 0);
