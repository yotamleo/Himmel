// thread-prefix.mjs — expand a 6-char thread prefix to its full id via the per-PR
// thread cache. Shared by the forge-routed mutate CLIs (thread-reply-cli /
// thread-resolve-action-cli). Returns a discriminated result instead of exiting
// so each CLI owns its own stderr/exit conventions.

import { readThreadCache, lookupPrefix } from './thread-cache.mjs';

export function expandPrefix({ owner, repo, number, prefix }) {
  const cached = readThreadCache(undefined, owner, repo, Number(number));
  if (!cached) {
    return { ok: false, message: `no-cache: run /gh-pr-comments ${number} first` };
  }
  const res = lookupPrefix(cached, prefix);
  if (res.status === 'no-match') {
    return {
      ok: false,
      message: `no-match: prefix "${prefix}" not in cache for ${owner}/${repo}#${number}`,
    };
  }
  if (res.status === 'ambiguous') {
    return { ok: false, message: `ambiguous: "${prefix}" matches ${res.prefixes.join(', ')}` };
  }
  return { ok: true, id: res.id };
}
