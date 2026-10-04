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

// Literals to scrub: the .env values of secret-bearing keys, 3+ chars. A
// literal under 6 chars is matched only as a whole token (not inside a longer
// word), so a short secret is scrubbed without shredding ordinary words; plain
// config such as a project key or a step list is not secret-named and stays
// readable in titles and remedies. `parseDotEnv` is probes.js's parser, passed in.
const SECRET_KEY = /TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY|COOKIE|CREDENTIAL/i;
const MIN_LITERAL = 3;
const SHORT_LITERAL = 6;
// probes.js's parser keeps an unbalanced quote (a multiline value's opener, or a
// dangling one), so the literal would never match the bare text: strip it.
function unquote(v) {
  return v.replace(/^["']+/, '').replace(/["']+$/, '');
}
function secretValues(obj) {
  return Object.entries(obj || {})
    .filter(([k, v]) => SECRET_KEY.test(k) && typeof v === 'string')
    .map(([, v]) => unquote(v))
    .filter((v) => v.length >= MIN_LITERAL);
}
// The continuation lines of a quoted value that spans lines (the parser reads
// only the first). Every line of such a secret-named value is a literal.
// Index of the closing quote q in str; a backslash-escaped double quote does not close.
function closeIdx(str, q) {
  for (let i = 0; i < str.length; i++) {
    if (q === '"' && str[i] === '\\') { i++; continue; }
    if (str[i] === q) return i;
  }
  return -1;
}
function multilineValues(raw) {
  const out = [];
  const lines = String(raw).split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const m = /^\s*(?:export\s+)?([A-Za-z0-9_]+)\s*=\s*(["'])(.*)$/.exec(lines[i]);
    if (!m || !SECRET_KEY.test(m[1]) || closeIdx(m[3], m[2]) !== -1) continue;
    out.push(m[3]);
    for (let j = i + 1; j < lines.length; j++) {
      const end = closeIdx(lines[j], m[2]);
      out.push(end === -1 ? lines[j] : lines[j].slice(0, end));
      if (end !== -1) { i = j; break; }
    }
  }
  return out.map((v) => v.trim()).filter((v) => v.length >= MIN_LITERAL);
}
// raw: .env text; extraEnv: optional object (process.env) whose secret-named values count too.
function envValues(raw, parseDotEnv, extraEnv) {
  let parsed = {};
  try { parsed = parseDotEnv(raw) || {}; } catch { parsed = {}; }
  return secretValues(parsed).concat(multilineValues(raw), secretValues(extraEnv));
}

function redact(input, opts) {
  if (typeof input !== 'string' || input === '') return input;
  let s = input;
  const literals = ((opts && opts.literals) || []).filter((v) => typeof v === 'string' && v.length >= MIN_LITERAL);
  // longest first so a value that contains a shorter one is replaced whole
  for (const v of literals.slice().sort((a, b) => b.length - a.length)) {
    const body = escapeRe(v);
    s = s.replace(new RegExp(v.length < SHORT_LITERAL ? `(?<![A-Za-z0-9])${body}(?![A-Za-z0-9])` : body, 'g'), REDACTED);
  }
  for (const re of TOKEN_SHAPES) s = s.replace(re, REDACTED);
  if (opts && opts.idKey) return s;
  s = s.replace(SECRET_ASSIGN, (_m, name, sep) => `${name}${sep}${REDACTED}`);
  s = s.replace(LONG_RUN, (m) => (/^[0-9a-f]+$/i.test(m) || !(/[A-Za-z]/.test(m) && /[0-9]/.test(m)) ? m : REDACTED));
  return s;
}

// Deep-redact every string in a JSON-shaped value. An `id` is a row key we
// mint (`secret:NAME` would otherwise read as `secret: value`), but part of it
// comes from subprocess output, so it still gets literal + token-shape redaction.
function redactDeep(v, opts) {
  if (typeof v === 'string') return redact(v, opts);
  if (Array.isArray(v)) return v.map((x) => redactDeep(x, opts));
  if (v && typeof v === 'object') {
    const out = {};
    for (const k of Object.keys(v)) out[k] = k === 'id' && typeof v[k] === 'string' ? redact(v[k], Object.assign({}, opts, { idKey: true })) : redactDeep(v[k], opts);
    return out;
  }
  return v;
}

module.exports = { redact, redactDeep, envValues, REDACTED };
