'use strict';

const crypto = require('crypto');

function foldWhitespace(value) {
  return String(value == null ? '' : value)
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
}

// HIMMEL-2901: case inside code is identity, case in prose is noise. A token
// keeps its case when it is identifier-shaped — camelCase, snake_case, or a
// dotted name — and everything inside a backtick span keeps its case verbatim.
// An ALL-CAPS word outside backticks is indistinguishable from prose emphasis
// ("CACHE cleanup"), so it still folds; put a constant in backticks to keep it.
function isCodeToken(token) {
  // Trim surrounding prose punctuation, the dot included: a sentence-ending
  // `config.LOGLEVEL.` is still a dotted identifier, and leaving the period on
  // stopped the dotted rule matching it at all (codex-1, HIMMEL-2901 round 1).
  const core = token.replace(/^[^A-Za-z0-9_$]+/, '').replace(/[^A-Za-z0-9_$]+$/, '');
  if (!core) return false;
  return /[a-z][A-Z]/.test(core) ||
    core.includes('_') ||
    /^[A-Za-z0-9_$]+(?:\.[A-Za-z0-9_$]+)+$/.test(core);
}

function foldClaimCase(value) {
  return String(value)
    .split(/(`[^`]*`)/)
    .map((part, index) => (index % 2 === 1
      ? part
      : part.split(/(\s+)/).map((token) => (isCodeToken(token) ? token : token.toLowerCase())).join('')))
    .join('');
}

function foldClaim(value) {
  return foldClaimCase(String(value == null ? '' : value).replace(/\s+/g, ' ').trim());
}

function normalizeFileAnchor(file) {
  return String(file == null ? '' : file)
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/\\/g, '/')
    .replace(/^\.\//, '')
    .replace(/:(?:l)?\d+(?:-\d+)?$/i, '');
}

function scrubClaim(text) {
  return String(text == null ? '' : text)
    .replace(/[\r\n]/g, ' ')
    .replace(/[0-9]{8,10}:[A-Za-z0-9_-]{35}/g, '[REDACTED]')
    .replace(/(Bearer|bearer) [A-Za-z0-9._-]{16,}/g, '$1 [REDACTED]')
    .replace(/sk-[A-Za-z0-9][A-Za-z0-9_-]{15,}/g, '[REDACTED]')
    .replace(/AKIA[0-9A-Z]{16}/g, '[REDACTED]')
    .replace(/([Aa][Pp][Ii][_-]?[Kk]ey|[Tt]oken|[Ss]ecret)[ \t]*[:=][ \t]*[A-Za-z0-9._-]{12,}/g, '$1=[REDACTED]');
}

function normalizeClaim(text) {
  let claim = scrubClaim(text)
    .replace(/^\s*-\s*\[[^\]]+\]\s*:\s*/, '');

  // Finding citations are trailing [file:line] tokens. Remove only their line
  // coordinates; every number in the prose claim remains fingerprint-significant.
  claim = claim.replace(/\s*\[[^\]\r\n]+:\d+(?:-\d+)?\]\s*$/, '');
  return foldClaim(claim);
}

function findingFingerprint(slug, file, text) {
  const normalizedSlug = foldWhitespace(slug);
  const normalizedAnchor = normalizeFileAnchor(file);
  const normalizedClaim = normalizeClaim(text);
  if (!normalizedSlug || !normalizedClaim) return '';
  const digest = crypto.createHash('sha256')
    .update(`${normalizedSlug}${normalizedAnchor}${normalizedClaim}`, 'utf8')
    .digest('hex');
  // fp2 (HIMMEL-2901): the claim fold changed, so a pre-2901 fp1 row must
  // never match a claim hashed under the new rules. The ledger is append-only:
  // old rows keep their fp1 identity and simply stop inheriting across the
  // version boundary.
  return `fp2:${digest}`;
}

module.exports = {
  findingFingerprint,
  normalizeClaim,
  normalizeFileAnchor,
};
