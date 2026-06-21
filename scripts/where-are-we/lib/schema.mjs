// scripts/where-are-we/lib/schema.mjs
export const REQUIRED = ['ts', 'source', 'key', 'kind'];
export const LIST_FIELDS = ['blockers', 'awaiting_operator'];

export function validateRecord(obj) {
  for (const f of REQUIRED) {
    if (!hasField(obj, f) || obj[f] === null || obj[f] === '') {
      return { ok: false, error: `missing required field: ${f}` };
    }
  }
  return { ok: true };
}

export function hasField(obj, f) {
  return Object.prototype.hasOwnProperty.call(obj, f);
}

export function isClear(obj, f) {
  if (!hasField(obj, f)) return false;
  const v = obj[f];
  return LIST_FIELDS.includes(f) ? Array.isArray(v) && v.length === 0 : v === null;
}
