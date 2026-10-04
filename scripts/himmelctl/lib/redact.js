'use strict';
// scripts/himmelctl/lib/redact.js — HIMMEL-4254 P2 (spec A14b): the one
// redactor every string leaving the config feed (and, in P3/P4, the UI server)
// passes through. Defence in depth on top of A7 (secrets show presence only).
//
// Replaces, with REDACTED:
//   - any caller-supplied literal (the .env values — see envValues())
//   - well-known token shapes (GitHub, Slack, AWS, OpenAI/Anthropic-style sk-,
//     JWTs, Bearer headers)
//   - the value of NAME=value / NAME: value when NAME looks secret-bearing
//   - any other 32+ char mixed letter+digit run that is not a path segment or
//     a pure-hex digest (git shas stay readable)
//
// ponytail: shape-based, so a short or low-entropy secret is caught only
// through the .env-value literals; the config UI must keep passing envValues.

const REDACTED = '‹redacted›';

const TOKEN_SHAPES = [
  /\bgh[pousr]_[A-Za-z0-9]{20,}\b/g,
  /\bgithub_pat_[A-Za-z0-9_]{20,}\b/g,
  /\bxox[abprs]-[A-Za-z0-9-]{10,}\b/g,
  /\bAKIA[0-9A-Z]{16}\b/g,
  /\bsk-[A-Za-z0-9_-]{16,}\b/g,
  /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*\b/g,
  /\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{12,}/gi,
];
const SECRET_ASSIGN = /\b([A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|COOKIE|CREDENTIAL)[A-Za-z0-9_]*)(\s*[=:]\s*)(?!‹)(["']?)[^\s"',;)]{4,}\3/gi;
const LONG_RUN = /(?<![A-Za-z0-9/_.-])[A-Za-z0-9_-]{32,}(?![A-Za-z0-9/_.-])/g;

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Literals to scrub: the .env values of secret-bearing keys, 6+ chars (shorter
// ones would shred ordinary words; plain config such as a project key or a
// step list must stay readable in titles and remedies). `parseDotEnv` is
// probes.js's parser, passed in.
const SECRET_KEY = /TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY|COOKIE|CREDENTIAL/i;
function secretValues(obj) {
  return Object.entries(obj || {})
    .filter(([k, v]) => SECRET_KEY.test(k) && typeof v === 'string' && v.length >= 6)
    .map(([, v]) => v);
}
// raw: .env text; extraEnv: optional object (process.env) whose secret-named values count too.
function envValues(raw, parseDotEnv, extraEnv) {
  let parsed = {};
  try { parsed = parseDotEnv(raw) || {}; } catch { parsed = {}; }
  return secretValues(parsed).concat(secretValues(extraEnv));
}

function redact(input, opts) {
  if (typeof input !== 'string' || input === '') return input;
  let s = input;
  const literals = ((opts && opts.literals) || []).filter((v) => typeof v === 'string' && v.length >= 6);
  // longest first so a value that contains a shorter one is replaced whole
  for (const v of literals.slice().sort((a, b) => b.length - a.length)) {
    s = s.replace(new RegExp(escapeRe(v), 'g'), REDACTED);
  }
  for (const re of TOKEN_SHAPES) s = s.replace(re, REDACTED);
  s = s.replace(SECRET_ASSIGN, (_m, name, sep) => `${name}${sep}${REDACTED}`);
  s = s.replace(LONG_RUN, (m) => (/^[0-9a-f]+$/i.test(m) || !(/[A-Za-z]/.test(m) && /[0-9]/.test(m)) ? m : REDACTED));
  return s;
}

// Deep-redact every string in a JSON-shaped value. `id` is a row key our own
// code mints (`secret:NAME` would otherwise read as `secret: value`).
function redactDeep(v, opts) {
  if (typeof v === 'string') return redact(v, opts);
  if (Array.isArray(v)) return v.map((x) => redactDeep(x, opts));
  if (v && typeof v === 'object') {
    const out = {};
    for (const k of Object.keys(v)) out[k] = k === 'id' ? v[k] : redactDeep(v[k], opts);
    return out;
  }
  return v;
}

module.exports = { redact, redactDeep, envValues, REDACTED };
