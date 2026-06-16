import { describe, it, expect } from 'vitest';
import { redact, DEFAULT_REDACT_PATTERNS } from '../src/redact.js';

describe('redact', () => {
  it('replaces matches with [REDACTED]', () => {
    const out = redact('token=abc123 user=foo', ['token=\\S+']);
    expect(out).toBe('[REDACTED] user=foo');
  });

  it('default patterns catch Bearer tokens', () => {
    const out = redact('Authorization: Bearer ey.abc.def', DEFAULT_REDACT_PATTERNS);
    expect(out).not.toContain('ey.abc.def');
    expect(out).toContain('[REDACTED]');
  });

  it('returns input unchanged with empty patterns', () => {
    const out = redact('hello', []);
    expect(out).toBe('hello');
  });

  it('invalid pattern does not crash, falls through', () => {
    expect(redact('x', ['('])).toBe('x');
  });

  it('I22: input > 1 MB short-circuits regex and appends note', () => {
    // Build a string just over 1 MB
    const big = 'a'.repeat(1_048_577);
    const out = redact(big, DEFAULT_REDACT_PATTERNS);
    expect(out).toContain('[himmel-run: input too large for regex redaction, skipped]');
    // Original text is preserved (not redacted)
    expect(out.startsWith('a'.repeat(100))).toBe(true);
  });

  it('default patterns catch password=mysecret123', () => {
    const out = redact('password=mysecret123', DEFAULT_REDACT_PATTERNS);
    expect(out).not.toContain('mysecret123');
    expect(out).toContain('[REDACTED]');
  });

  it('default patterns catch api_key=abc-def-123', () => {
    const out = redact('api_key=abc-def-123', DEFAULT_REDACT_PATTERNS);
    expect(out).not.toContain('abc-def-123');
    expect(out).toContain('[REDACTED]');
  });

  it('default patterns catch api-key=abc-def-123 (hyphen variant)', () => {
    const out = redact('api-key=abc-def-123', DEFAULT_REDACT_PATTERNS);
    expect(out).not.toContain('abc-def-123');
    expect(out).toContain('[REDACTED]');
  });

  it('default patterns catch token=mytoken123', () => {
    const out = redact('token=mytoken123', DEFAULT_REDACT_PATTERNS);
    expect(out).not.toContain('mytoken123');
    expect(out).toContain('[REDACTED]');
  });

  it('ReDoS guard: 2 MB input completes in <500 ms', () => {
    const big = 'a'.repeat(2 * 1_048_576);
    const start = Date.now();
    redact(big, DEFAULT_REDACT_PATTERNS);
    expect(Date.now() - start).toBeLessThan(500);
  });
});
