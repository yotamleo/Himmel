import { existsSync, readdirSync, statSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { cacheRoot, indexDir } from './paths.js';

export async function gc(tag: string, maxAgeDays: number, rootOverride?: string): Promise<number> {
  // B10: guard against path traversal via tag
  if (!tag || /[/\\]|^\.\.?$/.test(tag)) {
    throw new Error(`himmel-run: invalid tag "${tag}" (no path separators or '..' allowed)`);
  }

  const root = rootOverride ?? cacheRoot();
  const idx = rootOverride ? join(root, tag, 'index') : indexDir(tag);
  if (!existsSync(idx)) return 0;
  const cutoff = Date.now() - maxAgeDays * 86400_000;
  let removed = 0;
  for (const name of readdirSync(idx)) {
    if (!name.endsWith('.json')) continue;
    const p = join(idx, name);
    if (statSync(p).mtimeMs < cutoff) {
      unlinkSync(p);
      removed++;
    }
  }
  return removed;
}
