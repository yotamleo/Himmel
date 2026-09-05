// Pure formatting/parsing helpers for scripts/lanes/bank-status.ts and /lanes.

// The remedy every fail-closed codex reason names (HIMMEL-1678): the ONLY way
// to refresh the codex bank reading is to run the bounded probe — bank-status
// itself never spawns it.
export const CODEX_BANK_PROBE_REMEDY = 'run: bun scripts/lanes/codex-bank-probe.ts';

// Mirrors windowLabel() in scripts/observability/quota-sources.ts (300->5h,
// 10080->weekly, 43200->monthly). This .mjs copy exists because this module
// is imported by plain-node consumers (resolve.mjs, node --test) that cannot
// import the .ts original; keep the two in sync when a label is added.
export function codexWindowLabel(minutes) {
  if (minutes === 300) return '5h';
  if (minutes === 10080) return 'weekly';
  if (minutes === 43200) return 'monthly';
  return `${minutes}m`;
}

// Cache-timestamp parsing: the probe writes capturedAt as an ISO string; a
// bare number is tolerated as ms when huge, else epoch seconds. Null = the
// cache cannot be aged at all, which the caller reports fail-closed.
function parseCacheTimestampMs(v) {
  if (typeof v === 'number' && Number.isFinite(v) && v > 0) return v > 1e12 ? v : v * 1000;
  if (typeof v === 'string') {
    const ms = Date.parse(v);
    if (Number.isFinite(ms)) return ms;
  }
  return null;
}

// readCodexBankCache(text, nowMs, ttlSeconds) -> bank-status DisplayResult
// (HIMMEL-1678). FAIL-CLOSED interpretation of the probe's cache file: a
// fresh cache with live limit windows resolves to measured; anything else —
// unparseable, malformed, stale past the TTL, or with no limit window whose
// resetsAt is still in the future — resolves to unmeasurable with a reason
// that names the remedy. Never a fabricated number, never a silent fail-open.
// The per-limit live-window gate is the payoff the old sqlite scan could not
// buy (its HIMMEL-1689 hole #1: a reading with no window attribution is
// incomparable, not merely stale).
/**
 * @typedef {{ window: string, usedPct: number, resetsAt: number }} CodexBankReading
 * @typedef {{ kind: 'measured', readings: CodexBankReading[] }
 *          | { kind: 'unmeasurable', reason: string }} CodexBankCacheResult
 */
/**
 * The `kind` literals above are load-bearing: TS consumers (bank-status.ts,
 * spawn-claudex.ts) discriminate on them. A widened `kind: string` gives
 * nothing to narrow on, and `.reason` / `.readings` then silently read as
 * `undefined` — in the dispatch preflight that is exactly how a fail-closed
 * guard starts passing quietly.
 * @param {unknown} text
 * @param {number} nowMs
 * @param {number} ttlSeconds
 * @returns {CodexBankCacheResult}
 */
export function readCodexBankCache(text, nowMs, ttlSeconds) {
  /** @type {(reason: string) => CodexBankCacheResult} */
  const unmeasurable = (reason) => ({ kind: 'unmeasurable', reason: `${reason} — ${CODEX_BANK_PROBE_REMEDY}` });
  let parsed;
  try { parsed = JSON.parse(String(text)); } catch { return unmeasurable('codex bank cache unparseable'); }
  if (!parsed || typeof parsed !== 'object' || !Array.isArray(parsed.limits)) {
    return unmeasurable('codex bank cache malformed (no limits array)');
  }
  const capturedMs = parseCacheTimestampMs(parsed.capturedAt);
  if (capturedMs === null) return unmeasurable('codex bank cache has no usable capturedAt');
  const ageSec = (nowMs - capturedMs) / 1000;
  if (ageSec > ttlSeconds) {
    return unmeasurable(`codex bank cache stale (age ${Math.max(0, Math.floor(ageSec / 60))}min > TTL ${Math.floor(ttlSeconds / 60)}min)`);
  }
  // The account carries MULTIPLE limitIds (observed: `codex` and
  // `codex_bengalfox`), several of which land on the same window label. The
  // GOVERNING one — the highest used% — wins, carrying its OWN resetsAt. A
  // first-wins rule would be fail-open: a fresh 0% sibling limit arriving
  // first would mask an exhausted one and read as funded. Each surviving
  // reading keeps its own reset instant; no global reset is synthesized
  // (HIMMEL-1725), and every raw per-limit reset stays in the cache file.
  /** @type {Map<string, CodexBankReading>} */
  const byWindow = new Map();
  for (const limit of parsed.limits) {
    if (!limit || typeof limit !== 'object') continue;
    const { usedPercent, windowDurationMins, resetsAt } = limit;
    if (typeof usedPercent !== 'number' || !Number.isFinite(usedPercent) || usedPercent < 0 || usedPercent > 100) continue;
    if (typeof windowDurationMins !== 'number' || !Number.isFinite(windowDurationMins) || windowDurationMins <= 0) continue;
    const resetsMs = parseCacheTimestampMs(resetsAt);
    if (resetsMs === null || resetsMs <= nowMs) continue; // window already reset — the value would fabricate
    const window = codexWindowLabel(windowDurationMins);
    const prev = byWindow.get(window);
    if (prev && prev.usedPct >= usedPercent) continue; // fail-open-ok: prev.usedPct is only ever set below from a usedPercent already Number.isFinite-checked above (line 82)
    byWindow.set(window, { window, usedPct: usedPercent, resetsAt: resetsMs });
  }
  const readings = [...byWindow.values()];
  if (readings.length === 0) return unmeasurable('codex bank cache holds no live limit window');
  return { kind: 'measured', readings };
}

function pct(value) {
  return Number.isInteger(value) ? String(value) : String(Number(value.toFixed(2)));
}

export function formatMeasured(readings) {
  return `measured ${readings.map(({ window, usedPct, resetsAt }) => {
    const used = pct(usedPct);
    const free = pct(100 - usedPct);
    // resets= is per READING (HIMMEL-1725): each limit window resets at its
    // own instant and must never be collapsed into one global value. Only the
    // codex cache reader populates it today; claude/glm render unchanged.
    const resets = Number.isFinite(resetsAt) ? ` resets=${new Date(resetsAt).toISOString()}` : '';
    return `${window} used=${used}% free=${free}%${resets}`;
  }).join('; ')}`;
}

export function formatUnmeasurable(reason) {
  return `unmeasurable reason=${JSON.stringify(reason)}`;
}

export function parseBankStatusOutput(output) {
  const byLane = new Map();
  for (const line of String(output).split(/\r?\n/)) {
    const match = line.match(/^(\S+)\s+(funded|spent|unknown)\s+(.+)$/);
    if (match) byLane.set(match[1], { guardState: match[2], detail: match[3] });
  }
  return byLane;
}

export function formatBankAnnotation(status) {
  if (!status) return '[bank: unmeasurable — no status returned]';
  if (status.detail === 'flat-rate') return '[bank: flat-rate / n/a]';
  if (status.detail.startsWith('measured ')) {
    // The free= capture must exclude ';' (HIMMEL-1678 CR, glm-2). A bare (\S+)
    // swallowed the reading separator, so a MULTI-reading detail rendered as
    // "weekly 14% used / 86%, free daily 5% used / 95% free" — the word "free"
    // orphaned past the comma. Single-reading details hid it (nothing follows
    // the last free=), which is why the suite was green.
    const usage = status.detail.slice('measured '.length)
      .replace(/(\S+) used=(\S+) free=([^\s;]+)/g, '$1 $2 used / $3 free')
      .replace(/;/g, ',');
    return `[bank: ${usage}]`;
  }
  if (status.detail.startsWith('unmeasurable reason=')) {
    const raw = status.detail.slice('unmeasurable reason='.length);
    let reason = raw;
    try { reason = JSON.parse(raw); } catch { /* render the raw reason */ }
    return `[bank: unmeasurable — ${reason}]`;
  }
  return `[bank: unmeasurable — unrecognised status]`;
}

// guardState(result, active, maxPct) -> 'funded' | 'spent' | 'unknown'
// (HIMMEL-1768 round 3). The verdict is derived from per-window EVIDENCE about
// the RESOLVED active access path — never from list lengths, array counts, or
// positional index assumptions (the property both earlier defect rounds
// violated). `active` is resolveActiveAccessPath(quota) from resolve.mjs
// (kept a param so this pure module need not import its own importer);
// `result` is the bank read ('unmeasurable' or measured readings).
//
//   funded — every governing limit the path declares was actually measured and
//            every measurement sits below maxPct. A metered-api-key path
//            declares no subscription windows, so it is funded by construction
//            (pay-as-you-go has no window to exhaust) — even when the
//            now-irrelevant subscription bank read is unmeasurable.
//   spent  — some measured governing limit sits at/over maxPct.
//   unknown — the governing limits cannot be established (no resolvable
//            path; a non-metered path declaring no windows) or cannot be
//            measured (bank unmeasurable; a declared window with no reading).
//            Duplicate readings can no longer fake the coverage the old
//            count-equality check pretended to verify.
export function guardState(result, active, maxPct) {
  if (!active.ok) return 'unknown';
  const windows = (Array.isArray(active.path.windows) ? active.path.windows : [])
    .filter((w) => typeof w === 'string');
  if (windows.length === 0) {
    return active.path.kind === 'metered-api-key' ? 'funded' : 'unknown';
  }
  // HIMMEL-1678: flat-rate is a POSITIVE not-applicable determination by the
  // bank reader (the z.ai GLM plan is flat-rate — see readGlmDisplay in
  // bank-status.ts), not missing evidence, so `unknown` would be the wrong
  // word: it reads as a bug while the lane is in fact always-available. This
  // is NOT the round-2 fail-open reborn — that one flipped a measured,
  // EXHAUSTED bank to funded; here no metered reading exists to ignore.
  if (result.kind === 'flat-rate') return 'funded';
  if (result.kind === 'unmeasurable') return 'unknown';
  for (const window of windows) {
    const evidence = result.readings.filter((reading) => reading.window === window);
    if (evidence.length === 0) return 'unknown';
    if (evidence.some((reading) => !Number.isFinite(reading.usedPct))) return 'unknown';
    if (evidence.some((reading) => reading.usedPct >= maxPct)) return 'spent';
  }
  return 'funded';
}
