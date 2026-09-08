// Pure helpers for scripts/lanes/codex-bank-probe.ts (HIMMEL-1678). Kept in a
// plain .mjs — importable by node --test — so the framing parser and the
// rateLimits normalizer are unit-testable without ever spawning `codex`.

// takeJsonRpcMessage(buf) -> { text, rest } | null
// Extract ONE JSON-RPC message from a byte buffer, tolerating BOTH stdio
// JSON-RPC framings on the INBOUND side:
//   - newline-delimited JSON (the MCP stdio shape — requests are SENT in this
//     framing; codex's own rollout files are NDJSON too), and
//   - LSP-style `Content-Length: N\r\n\r\n<bytes>` frames.
// Which one a message uses is decided per message start, not per stream, and
// non-`{` banner lines are skipped, so a chatty server preamble cannot wedge
// the parser. Returns null when no COMPLETE message is in the buffer yet
// (the caller keeps the buffer and waits for more bytes). Never throws.
export function takeJsonRpcMessage(buf) {
  let b = buf;
  for (;;) {
    if (!b || b.length === 0) return null;
    // Strip \r\n padding between messages (both framings allow it).
    let start = 0;
    while (start < b.length && (b[start] === 0x0d || b[start] === 0x0a)) start++;
    if (start === b.length) return null;
    b = b.subarray(start);

    const head = b.toString('latin1', 0, Math.min(b.length, 64));
    if (/^content-length[ \t]*:/i.test(head)) {
      const headerEnd = b.indexOf('\r\n\r\n');
      if (headerEnd === -1) return null; // incomplete header block — wait
      const headerText = b.toString('latin1', 0, headerEnd).toLowerCase();
      const m = /content-length[ \t]*:[ \t]*([0-9]+)/.exec(headerText);
      if (!m) return null; // header block without a usable length — wait
      const bodyStart = headerEnd + 4;
      const bodyEnd = bodyStart + Number(m[1]); // Content-Length counts BYTES
      if (b.length < bodyEnd) return null; // body still streaming in
      return { text: b.toString('utf8', bodyStart, bodyEnd), rest: b.subarray(bodyEnd) };
    }

    const nl = b.indexOf(0x0a);
    if (nl === -1) return null; // line not terminated yet — wait (banner or JSON)
    let line = b.toString('utf8', 0, nl);
    if (line.endsWith('\r')) line = line.slice(0, -1);
    if (!line.startsWith('{')) {
      // Banner/garbage line — DROP it and rescan. Advancing `b` here is what
      // makes the loop terminate: `continue` on the unconsumed buffer re-reads
      // the same line forever (a 100%-CPU spin that blocks the event loop, so
      // even the probe's own deadline timer never fires).
      b = b.subarray(nl + 1);
      continue;
    }
    return { text: line, rest: b.subarray(nl + 1) };
  }
}

export function encodeJsonRpcLine(message) {
  return `${JSON.stringify(message)}\n`;
}

// The window slots a rate-limit bucket can carry. `primary` is the account's
// governing window (weekly on the observed plan); `secondary` is the shorter
// one and is often null.
const WINDOW_SLOTS = ['primary', 'secondary'];

// normalizeRateLimits(result) -> { limits, planType }
// Flatten an `account/rateLimits/read` RESULT object into the cache schema.
// The live payload (verified against `codex app-server` on 2026-08-17) is:
//
//   { rateLimits:          <bucket>,               // the default limit only
//     rateLimitsByLimitId: { <limitId>: <bucket> } // EVERY limit
//     ... }
//   <bucket> = { limitId, planType, primary: <window>|null, secondary: <window>|null, ... }
//   <window> = { usedPercent, windowDurationMins, resetsAt }
//
// rateLimitsByLimitId is preferred because it is the only container that
// carries every limit — the observed account has two (`codex` and
// `codex_bengalfox`) whose resetsAt are DAYS apart, so they stay separate rows
// and no single global reset is ever synthesized (HIMMEL-1725).
//
// planType lives INSIDE a bucket, never at the top level. Reading it from the
// top was the whole `plan=unknown` defect.
//
// resetsAt stays epoch-seconds as it arrived (or null when absent) —
// conversion is the cache reader's job.
export function normalizeRateLimits(result) {
  const out = { limits: [], planType: null };
  if (!result || typeof result !== 'object') return out;
  const byId = result.rateLimitsByLimitId;
  const buckets = byId && typeof byId === 'object' && !Array.isArray(byId)
    ? Object.entries(byId)
    // Fallbacks: the single-bucket container, else a bare bucket.
    : [[null, result.rateLimits && typeof result.rateLimits === 'object' ? result.rateLimits : result]];
  for (const [key, bucket] of buckets) {
    if (!bucket || typeof bucket !== 'object' || Array.isArray(bucket)) continue;
    if (out.planType === null && typeof bucket.planType === 'string') out.planType = bucket.planType;
    const id = typeof bucket.limitId === 'string' && bucket.limitId !== '' ? bucket.limitId : key;
    for (const slot of WINDOW_SLOTS) {
      const window = bucket[slot];
      if (!window || typeof window !== 'object') continue; // null/absent slot
      const { usedPercent, windowDurationMins, resetsAt } = window;
      if (typeof usedPercent !== 'number' || !Number.isFinite(usedPercent)) continue;
      if (typeof windowDurationMins !== 'number' || !Number.isFinite(windowDurationMins) || windowDurationMins <= 0) continue;
      out.limits.push({
        limitId: id === null ? slot : `${id}/${slot}`,
        usedPercent: Math.min(100, Math.max(0, usedPercent)),
        windowDurationMins,
        resetsAt: typeof resetsAt === 'number' && Number.isFinite(resetsAt) && resetsAt > 0 ? resetsAt : null,
      });
    }
  }
  return out;
}
