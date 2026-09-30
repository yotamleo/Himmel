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

// The page's own data runs through the same model (the Python blob and the JS agree on shapes).
const m = /<script type="application\/json" id="data">([\s\S]*?)<\/script>/.exec(html);
const R = model(JSON.parse(m[1]));
const r1 = R.drill('live', { v: 0 });
eq('the rendered data: the live leg ticket drills from the legs figure (HIMMEL-3990)', [nums(r1), R.leg(r1[0])], [[1], ['N55', 'LIVE', 1525]]);
eq('the rendered data: the planned ticket loads its kind (HIMMEL-3990)', [R.load(0).kinds[0].used, nums(R.load(0).kinds[0].tickets)], [0.009, [1]]);
eq('the rendered data: the row text is the user impact (HIMMEL-3990)', r1[0][9], 'changed impact');

console.log(fails + ' failure(s)');
process.exit(fails ? 1 : 0);
