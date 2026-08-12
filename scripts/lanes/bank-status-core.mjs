// Pure formatting/parsing helpers for scripts/lanes/bank-status.ts and /lanes.

// Byte windows for the backwards tail scan of the codex log, newest-first.
// Consecutive windows OVERLAP by overlapBytes (HIMMEL-1678 CR, codex-2/glm-3):
// the original scan used contiguous non-overlapping chunks, so a
// `"secondary":{"used_percent":N}` fragment straddling a chunk boundary was
// truncated in BOTH halves and matched in neither, silently yielding an older
// reading. The overlap must exceed the longest such fragment.
export function codexScanWindows(size, scanLimit, chunkBytes, overlapBytes) {
  const windows = [];
  if (!(size > 0) || !(scanLimit > 0) || !(chunkBytes > 0)) return windows;
  const limit = Math.min(size, scanLimit);
  const stride = Math.max(1, chunkBytes - Math.max(0, overlapBytes));
  for (let scanned = 0; scanned < limit; scanned += stride) {
    const length = Math.min(chunkBytes, limit - scanned);
    windows.push({ start: size - scanned - length, length });
    if (length < chunkBytes) break;
  }
  return windows;
}

export function parseCodexWeeklyUsedPercent(raw) {
  const re = /"secondary"\s*:\s*\{[^}]*?"used_percent"\s*:\s*([0-9]+(?:\.[0-9]+)?)/g;
  let match;
  let last = null;
  while ((match = re.exec(raw)) !== null) {
    const value = Number(match[1]);
    if (Number.isFinite(value) && value >= 0 && value <= 100) last = value;
  }
  return last;
}

function pct(value) {
  return Number.isInteger(value) ? String(value) : String(Number(value.toFixed(2)));
}

export function formatMeasured(readings) {
  return `measured ${readings.map(({ window, usedPct }) => {
    const used = pct(usedPct);
    const free = pct(100 - usedPct);
    return `${window} used=${used}% free=${free}%`;
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
