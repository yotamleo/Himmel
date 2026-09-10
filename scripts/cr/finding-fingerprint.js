'use strict';

const crypto = require('crypto');

function foldWhitespace(value) {
  return String(value == null ? '' : value)
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
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
  return foldWhitespace(claim);
}

function findingFingerprint(slug, file, text) {
  const normalizedSlug = foldWhitespace(slug);
  const normalizedAnchor = normalizeFileAnchor(file);
  const normalizedClaim = normalizeClaim(text);
  if (!normalizedSlug || !normalizedClaim) return '';
  const digest = crypto.createHash('sha256')
    .update(`${normalizedSlug}${normalizedAnchor}${normalizedClaim}`, 'utf8')
    .digest('hex');
  return `fp1:${digest}`;
}

module.exports = {
  findingFingerprint,
  normalizeClaim,
  normalizeFileAnchor,
};
