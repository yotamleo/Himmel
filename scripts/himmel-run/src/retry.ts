export function shouldRetryExit(exit: number, codes: number[] | undefined): boolean {
  if (!codes || codes.length === 0) return false;
  return codes.includes(exit);
}

export function shouldRunRecovery(stderr: string, pattern: string | undefined): boolean {
  if (!pattern) return false;
  try {
    return new RegExp(pattern).test(stderr);
  } catch (e) {
    // I2: log invalid regex via stderr instead of silently swallowing
    process.stderr.write(`himmel-run: invalid recovery pattern "${pattern}": ${(e as Error).message}\n`);
    return false;
  }
}

export function computeBackoffMs(base: number, cap: number): number {
  return base + Math.floor(Math.random() * (cap - base));
}

export function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
