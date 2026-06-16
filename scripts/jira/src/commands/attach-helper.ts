import { uploadAttachment } from '../client.js';

export type UploadFn = (issueKey: string, filePath: string) => Promise<unknown>;

/**
 * Upload every path to issueKey in order. Logs a per-file breadcrumb
 * to stderr as each file is processed (✓ on success, ✗ on failure) so
 * the operator can see partial-state progress even when a later file
 * fails. Stops at first failure and rethrows with the file name
 * prepended.
 */
export async function uploadAll(
  issueKey: string,
  paths: string[],
  upload: UploadFn = uploadAttachment,
): Promise<number> {
  let n = 0;
  for (const p of paths) {
    try {
      await upload(issueKey, p);
      console.error(`  ✓ ${p}`);
    } catch (e) {
      const msg = (e as Error).message;
      console.error(`  ✗ ${p}: ${msg}`);
      throw new Error(`${p}: ${msg}`);
    }
    n += 1;
  }
  return n;
}
