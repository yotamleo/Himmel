import { execFileSync } from 'node:child_process';

interface ExtractInput {
  stdout: string;
  stderr: string;
  exitCode: number;
  summaryJq?: string;
  summaryRegex?: string;
}

const CLOSERS = new Set(['}', ']', ')']);

let _jqMissing = false;

function tryJq(stdout: string, expr: string): string | null {
  try {
    JSON.parse(stdout);
  } catch {
    return null;
  }
  // I3: distinguish ENOENT (one-time warning) from expression errors (per-call warning)
  // I8: add timeout to avoid hang on stuck jq
  try {
    const out = execFileSync('jq', ['-r', expr], {
      input: stdout,
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
      timeout: 5000,
    });
    return out.trim();
  } catch (e) {
    const err = e as NodeJS.ErrnoException;
    if (err.code === 'ENOENT') {
      if (!_jqMissing) {
        _jqMissing = true;
        process.stderr.write('himmel-run: jq not found; summaryJq will be skipped\n');
      }
    } else {
      process.stderr.write(`himmel-run: jq expression error: ${err.message}\n`);
    }
    return null;
  }
}

function tabularRows(stdout: string): number | null {
  const lines = stdout.split('\n').map((l) => l.trim()).filter(Boolean);
  if (lines.length < 3) return null;
  const cols = lines.map((l) => l.split(/\s+/).length);
  const first = cols[0];
  if (first < 2) return null;
  if (!cols.every((c) => c === first)) return null;
  return lines.length;
}

function lastNonEmptyLine(stdout: string): string | null {
  const lines = stdout.split('\n').map((l) => l.trim()).filter(Boolean);
  if (lines.length === 0) return null;
  const last = lines[lines.length - 1];
  if (CLOSERS.has(last)) return null;
  return last;
}

export function extractSummary(input: ExtractInput): string {
  const { stdout, stderr, exitCode, summaryJq, summaryRegex } = input;

  if (summaryJq) {
    const out = tryJq(stdout, summaryJq);
    if (out) return out;
  }

  if (summaryRegex) {
    try {
      const re = new RegExp(summaryRegex, 'm');
      const m = stdout.match(re);
      if (m) return m[1] ?? m[0];
    } catch (e) {
      process.stderr.write(`himmel-run: invalid summaryRegex "${summaryRegex}": ${(e as Error).message}\n`);
    }
  }

  // tabular check BEFORE last-line so "N rows" wins for consistent tabular output
  const rows = tabularRows(stdout);
  if (rows) return `${rows} rows`;

  const last = lastNonEmptyLine(stdout);
  if (last) return last;

  // B13: only return 'OK' when exit is 0; non-zero with no output gets descriptive message
  if (!stdout.trim() && exitCode === 0) return 'OK';

  const firstErr = stderr.split('\n').map((l) => l.trim()).find(Boolean);
  if (firstErr) return firstErr;
  return exitCode === 0 ? 'OK' : `exit=${exitCode} (no output)`;
}
