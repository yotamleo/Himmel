import { BitbucketHttpError } from '../client.js';

// Pure error→exit-code mapping for the command layer (HIMMEL-341). Extracted so
// the degradation contracts the forge seam relies on — `issue create`/`issue get`
// 404 → exit 3, `pr merge` 400-conflict → exit 2 — are unit-testable without
// spawning a child process or stubbing process.exit. Action handlers stay thin:
// `const { code, message } = exitFor(err, '<verb>', { <status>: <code> });`.
//
// `special` maps a BitbucketHttpError.status to a non-1 exit code. When the
// caught error is a BitbucketHttpError whose status is listed, the client-built
// message (already prefixed, e.g. "bitbucket: issue create failed: …") is
// surfaced verbatim. Everything else — a generic Error, or a BitbucketHttpError
// whose status is NOT listed (incl. the synthetic status 0 from a non-numeric
// id) — maps to exit 1 with the generic "bitbucket: <verb> failed: …" line.
export interface ExitResult {
  code: number;
  message: string;
}

// Maps a BitbucketHttpError.status to the non-1 exit code it degrades to
// (e.g. { 404: 3 } for issue verbs, { 400: 2 } for pr merge). Partial because
// most statuses aren't special and fall through to the generic exit 1 — and so
// a stray entry like { 404: 1 } reads as the obvious mistake it is.
export type StatusExitMap = Partial<Record<number, number>>;

export function exitFor(err: unknown, verb: string, special: StatusExitMap = {}): ExitResult {
  // Guard the property access: a thrown non-Error (null / primitive) must not
  // crash the failure path itself — that would escape the action handler's
  // try/catch with an unmapped exit code, defeating the helper's whole purpose.
  const message = err instanceof Error ? err.message : String(err);
  if (err instanceof BitbucketHttpError) {
    // Guard-narrowing (vs `in` + cast): a present key in a Partial map is the
    // only way to get a defined code, and the synthetic status 0 (non-numeric
    // id) is absent from every special map → falls through to exit 1.
    const code = special[err.status];
    if (code !== undefined) return { code, message };
  }
  return { code: 1, message: `bitbucket: ${verb} failed: ${message}` };
}
