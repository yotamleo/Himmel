export function printJson(data: unknown): void {
  console.log(JSON.stringify(data, null, 2));
}

// Resolve user-slug per spec §5.4: nickname → account_id → uuid. Errors loudly
// if none present — an empty slug silently corrupts handover paths.
export function resolveSlug(user: {
  nickname?: string;
  account_id?: string;
  uuid?: string;
}): string {
  const slug = user.nickname || user.account_id || user.uuid;
  if (!slug) {
    throw new Error(
      'bitbucket: GET /user returned no nickname, account_id, or uuid — cannot resolve a user-slug.',
    );
  }
  return slug;
}
