import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import { platform } from 'node:os';

export function metadataPath() {
  const win = platform() === 'win32';
  const base = win
    ? process.env.LOCALAPPDATA
    : (process.env.XDG_CACHE_HOME || (process.env.HOME && join(process.env.HOME, '.cache')));
  if (!base) {
    throw new Error(
      `Cannot resolve cache dir: ${win ? 'LOCALAPPDATA' : 'HOME / XDG_CACHE_HOME'} unset`,
    );
  }
  const dir = join(base, 'himmel-cli', 'jira');
  return { dir, file: join(dir, 'metadata.json') };
}

export function readMetadata() {
  const { file } = metadataPath();
  if (!existsSync(file)) return null;
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch (e) {
    process.stderr.write('[jira] warning: metadata.json corrupt, ignoring: ' + e.message + '\n');
    return null;
  }
}

export function writeMetadata(data) {
  const { dir, file } = metadataPath();
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true, mode: 0o700 });
  writeFileSync(file, JSON.stringify(data, null, 2), { mode: 0o600 });
  if (platform() !== 'win32') chmodSync(file, 0o600);
}

export function isStale(metadata, days = 30) {
  if (!metadata?.fetched_at) return true;
  const age = Date.now() - new Date(metadata.fetched_at).getTime();
  return age > days * 86400_000;
}
