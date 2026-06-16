import envPaths from 'env-paths';
import { join, dirname } from 'node:path';
import { platform } from 'node:os';

const paths = envPaths('himmel-cli', { suffix: '' });

// On Linux/macOS, paths.cache is already the bare "himmel-cli" dir, so no
// stripping is needed. On Windows, env-paths appends \Cache to the app dir;
// strip it so the root is always the bare "himmel-cli" directory regardless
// of platform.
const CACHE_ROOT = platform() === 'win32' ? dirname(paths.cache) : paths.cache;

export function cacheRoot(): string {
  return CACHE_ROOT;
}

export function tagDir(tag: string): string {
  return join(cacheRoot(), tag);
}

export function logPath(tag: string): string {
  return join(tagDir(tag), 'normal.log');
}

export function errPath(tag: string): string {
  return join(tagDir(tag), 'error.log');
}

export function indexDir(tag: string): string {
  return join(tagDir(tag), 'index');
}

export function indexEntryPath(tag: string, runId: string): string {
  return join(indexDir(tag), `${runId}.json`);
}

export function lockPath(tag: string): string {
  return join(tagDir(tag), '.lock');
}

export function repoContextPath(tag: string): string {
  return join(tagDir(tag), 'repo-context.json');
}
