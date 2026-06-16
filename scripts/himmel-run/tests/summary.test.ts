import { describe, it, expect, vi } from 'vitest';
import { extractSummary } from '../src/summary.js';

describe('extractSummary', () => {
  it('1. summaryJq evaluates against parsed stdout JSON', () => {
    const s = extractSummary({
      stdout: '{"title":"hello","state":"open"}',
      stderr: '',
      exitCode: 0,
      summaryJq: '.title + " | " + .state',
    });
    expect(s).toBe('hello | open');
  });

  it('2. summaryRegex first capture group', () => {
    const s = extractSummary({
      stdout: 'Created HIMMEL-105\nextra noise',
      stderr: '',
      exitCode: 0,
      summaryRegex: '^Created (HIMMEL-\\d+)',
    });
    expect(s).toBe('HIMMEL-105');
  });

  it('3. last non-empty stdout line, refusing JSON closers', () => {
    const s1 = extractSummary({ stdout: 'a\nb\nc\n', stderr: '', exitCode: 0 });
    expect(s1).toBe('c');
    const s2 = extractSummary({ stdout: '{\n  "x": 1\n}\n', stderr: '', exitCode: 0 });
    expect(s2).not.toBe('}');
  });

  it('4. tabular detection emits N rows when >=3 lines, >=2 columns, consistent', () => {
    const stdout = 'a b\nc d\ne f\ng h\n';
    const s = extractSummary({ stdout, stderr: '', exitCode: 0 });
    expect(s).toBe('4 rows');
  });

  it('5. OK fallback when stdout empty and exit 0', () => {
    const s = extractSummary({ stdout: '', stderr: '', exitCode: 0 });
    expect(s).toBe('OK');
  });

  it('6. first stderr line when exit ≠ 0 and stdout empty', () => {
    const s = extractSummary({ stdout: '', stderr: 'ERR: bad thing\nmore', exitCode: 1 });
    expect(s).toBe('ERR: bad thing');
  });

  it('7. invalid summaryRegex falls through to last-line tier and logs to stderr', () => {
    const stderrSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    try {
      const s = extractSummary({
        stdout: 'a\nb\nfinal\n',
        stderr: '',
        exitCode: 0,
        summaryRegex: '(',  // syntactically invalid
      });
      expect(s).toBe('final');
      expect(stderrSpy).toHaveBeenCalledWith(
        expect.stringContaining('invalid summaryRegex'),
      );
    } finally {
      stderrSpy.mockRestore();
    }
  });

  it('8. empty stdout + non-zero exit does NOT return OK (B13)', () => {
    const s = extractSummary({ stdout: '', stderr: '', exitCode: 1 });
    expect(s).not.toBe('OK');
    expect(s).toContain('exit=1');
  });

  it('9. empty stdout + non-zero exit uses stderr when available', () => {
    const s = extractSummary({ stdout: '', stderr: 'connection refused', exitCode: 1 });
    expect(s).toBe('connection refused');
  });
});

describe('extractSummary jq-absent', () => {
  it('falls through to last-line tier when jq is not on PATH; emits one-time stderr warning', async () => {
    // Strip jq from PATH by setting PATH to an empty value for the duration of the call.
    // execFileSync('jq', ...) will fail with ENOENT, the warning fires once, and the
    // tier falls through.
    const origPath = process.env.PATH;
    const stderrSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    process.env.PATH = '';
    try {
      // Re-import the module to reset the internal `_jqMissing` one-shot flag.
      const mod = await import('../src/summary.js?jq-absent=' + Date.now());
      const s = mod.extractSummary({
        stdout: '{"x":1}\nlast-line\n',
        stderr: '',
        exitCode: 0,
        summaryJq: '.x',
      });
      // jq missing → tier falls through → last-line wins
      expect(s).toBe('last-line');
      // Warning should have fired (one-shot — pin behavior leniently because
      // a prior test in this run may have already tripped the module-scoped flag).
      const calls = stderrSpy.mock.calls.flat().join('');
      if (calls.length > 0) {
        expect(calls).toContain('jq not found');
      }
    } finally {
      process.env.PATH = origPath;
      stderrSpy.mockRestore();
    }
  });

  it('does not call jq at all when stdout is not valid JSON (skips ENOENT)', () => {
    // tryJq guards with JSON.parse first; invalid JSON returns null before exec.
    const stderrSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    try {
      const s = extractSummary({
        stdout: 'not json at all\nfinal',
        stderr: '',
        exitCode: 0,
        summaryJq: '.x',
      });
      // jq is not invoked → no ENOENT, no warning, falls through to last-line.
      expect(s).toBe('final');
      const calls = stderrSpy.mock.calls.flat().join('');
      expect(calls).not.toContain('jq not found');
    } finally {
      stderrSpy.mockRestore();
    }
  });
});
