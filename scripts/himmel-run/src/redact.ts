export const DEFAULT_REDACT_PATTERNS = [
  'Bearer\\s+[A-Za-z0-9._-]+',
  'eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}',
  '(?<=token=)[A-Za-z0-9._-]+',
  '(?<=password=)[^\\s&]+',
  '(?<=api[_-]?key=)[A-Za-z0-9._-]+',
];

// I22: ReDoS mitigation — inputs larger than 1 MB skip the regex tier.
// Regex backtracking on untrusted input can cause catastrophic slowdowns.
// 1 MB is well above any realistic CLI output; legitimate output is unaffected.
const REDACT_MAX_BYTES = 1_048_576; // 1 MB

export function redact(text: string, patterns: string[]): string {
  if (Buffer.byteLength(text) > REDACT_MAX_BYTES) {
    // Append a note so callers know redaction was skipped, then return raw.
    // Actual secrets in oversized payloads should not reach Claude anyway
    // because log truncation in log.ts caps appended bytes at 4 KB.
    return text + '\n[himmel-run: input too large for regex redaction, skipped]';
  }
  let out = text;
  for (const p of patterns) {
    try {
      out = out.replace(new RegExp(p, 'gi'), '[REDACTED]');
    } catch {
      // invalid pattern — skip and continue
    }
  }
  return out;
}
