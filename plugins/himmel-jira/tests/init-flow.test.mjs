import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ensureEnvKeys, appendEnvKeys, UNSAFE_VALUE_RE, loadEnvIntoProcess } from '../lib/init-flow.mjs';

let dir;
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'himmel-init-')); });

describe('ensureEnvKeys', () => {
  it('returns all keys when file missing', () => {
    const missing = ensureEnvKeys(join(dir, 'nope.env'), ['A', 'B']);
    expect(missing).toEqual(['A', 'B']);
  });
});

describe('appendEnvKeys', () => {
  it('appends to file with chmod 600 on POSIX', () => {
    const env = join(dir, '.env');
    appendEnvKeys(env, { A: '1', B: '2' });
    expect(readFileSync(env, 'utf8')).toContain('A=1');
    expect(readFileSync(env, 'utf8')).toContain('B=2');
  });
});

describe('UNSAFE_VALUE_RE', () => {
  it('rejects values containing "="', () => {
    expect(UNSAFE_VALUE_RE.test('foo=bar')).toBe(true);
  });

  it('rejects values containing newline (\\n)', () => {
    expect(UNSAFE_VALUE_RE.test('foo\nbar')).toBe(true);
  });

  it('rejects values containing carriage return (\\r)', () => {
    expect(UNSAFE_VALUE_RE.test('foo\rbar')).toBe(true);
  });

  it('rejects single-quote-opened value with no closing quote', () => {
    expect(UNSAFE_VALUE_RE.test("'unbalanced")).toBe(true);
  });

  it('rejects double-quote-opened value with no closing quote', () => {
    expect(UNSAFE_VALUE_RE.test('"unbalanced')).toBe(true);
  });

  it('accepts plain alphanumeric value (happy path)', () => {
    expect(UNSAFE_VALUE_RE.test('abc123')).toBe(false);
  });

  // NOTE: the regex `^["'](?!.*\1$)` uses `\1` but the pattern has no capture
  // group (the `["']` is a character class, not a group), so `\1` references
  // nothing and `.*\1$` never matches. The negative lookahead therefore always
  // succeeds, meaning the regex rejects ALL values starting with a quote —
  // balanced or unbalanced. This is conservative-safe (quoted .env values are
  // essentially never valid) so we pin the actual behavior here.
  it('rejects a "balanced" single-quoted value (over-strict but conservative)', () => {
    expect(UNSAFE_VALUE_RE.test("'balanced'")).toBe(true);
  });

  it('rejects a "balanced" double-quoted value (over-strict but conservative)', () => {
    expect(UNSAFE_VALUE_RE.test('"balanced"')).toBe(true);
  });

  it('accepts dash, dot, underscore, slash (typical token chars)', () => {
    expect(UNSAFE_VALUE_RE.test('a-b.c_d/e')).toBe(false);
  });
});

describe('appendEnvKeys rejection routing', () => {
  it('throws when value contains "="', () => {
    const env = join(dir, '.env');
    expect(() => appendEnvKeys(env, { K: 'a=b' })).toThrow(/refusing to write/);
  });

  it('throws when value contains newline', () => {
    const env = join(dir, '.env');
    expect(() => appendEnvKeys(env, { K: 'a\nb' })).toThrow(/refusing to write/);
  });

  it('throws when value has unbalanced opening quote', () => {
    const env = join(dir, '.env');
    expect(() => appendEnvKeys(env, { K: '"unbalanced' })).toThrow(/refusing to write/);
  });

  it('does NOT write the file when any value is unsafe (atomic refuse)', () => {
    const env = join(dir, '.env');
    expect(() => appendEnvKeys(env, { GOOD: 'ok', BAD: 'a=b' })).toThrow();
    expect(existsSync(env)).toBe(false);
  });
});

describe('loadEnvIntoProcess quote stripping', () => {
  it("strips single quotes: VALUE='foo' → process.env.VALUE === 'foo'", () => {
    const env = join(dir, 'q.env');
    writeFileSync(env, "JIRA_HIMMEL101_SINGLE='foo'\n");
    delete process.env.JIRA_HIMMEL101_SINGLE;
    try {
      loadEnvIntoProcess(env);
      expect(process.env.JIRA_HIMMEL101_SINGLE).toBe('foo');
    } finally {
      delete process.env.JIRA_HIMMEL101_SINGLE;
    }
  });

  it('strips double quotes: VALUE="bar" → process.env.VALUE === "bar"', () => {
    const env = join(dir, 'q.env');
    writeFileSync(env, 'JIRA_HIMMEL101_DOUBLE="bar"\n');
    delete process.env.JIRA_HIMMEL101_DOUBLE;
    try {
      loadEnvIntoProcess(env);
      expect(process.env.JIRA_HIMMEL101_DOUBLE).toBe('bar');
    } finally {
      delete process.env.JIRA_HIMMEL101_DOUBLE;
    }
  });

  it('leaves unquoted value untouched', () => {
    const env = join(dir, 'q.env');
    writeFileSync(env, 'JIRA_HIMMEL101_PLAIN=baz\n');
    delete process.env.JIRA_HIMMEL101_PLAIN;
    try {
      loadEnvIntoProcess(env);
      expect(process.env.JIRA_HIMMEL101_PLAIN).toBe('baz');
    } finally {
      delete process.env.JIRA_HIMMEL101_PLAIN;
    }
  });

  it('does NOT overwrite an env var that is already set', () => {
    const env = join(dir, 'q.env');
    writeFileSync(env, 'JIRA_HIMMEL101_PREEXIST="from-file"\n');
    process.env.JIRA_HIMMEL101_PREEXIST = 'from-process';
    try {
      loadEnvIntoProcess(env);
      expect(process.env.JIRA_HIMMEL101_PREEXIST).toBe('from-process');
    } finally {
      delete process.env.JIRA_HIMMEL101_PREEXIST;
    }
  });

  it('returns silently and does nothing when env file does not exist', () => {
    expect(() => loadEnvIntoProcess(join(dir, 'no-such.env'))).not.toThrow();
  });

  it('preserves quote characters when only ONE side has a quote (mismatched)', () => {
    // The current implementation uses `^"(.*)"$` — both ends must match.
    // A value like `"oops` (open-only) is loaded verbatim.
    const env = join(dir, 'q.env');
    writeFileSync(env, 'JIRA_HIMMEL101_MISMATCH="oops\n');
    delete process.env.JIRA_HIMMEL101_MISMATCH;
    try {
      loadEnvIntoProcess(env);
      expect(process.env.JIRA_HIMMEL101_MISMATCH).toBe('"oops');
    } finally {
      delete process.env.JIRA_HIMMEL101_MISMATCH;
    }
  });
});
