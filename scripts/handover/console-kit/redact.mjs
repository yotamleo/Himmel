// redact.mjs — HIMMEL-4834. The one redactor for text that leaves the console:
// board.mjs (published page) and himmel-bus lib/agui.mjs (AG-UI fleet feed) both
// import it, so there is a single copy to keep current. board.mjs is a CLI and
// cannot be imported, which is why this lives in its own module.
//
// Nonces (`V-N255-93f72f64`, `AA-N1-abcdef12`, a leg stem
// `V-HIMMEL-3340-N1-alpha-cafe0123`), the canonical RETASK token
// `R-<32 hex>` (mintRetaskNonce, scripts/telegram/brief-blocks.ts), lock tokens
// (`cachyos-x8664-pid909468`), key-shaped strings and a `token \`...\`` span are
// replaced. Console letters run A-Z then AA-ZZ. Runs BEFORE escaping and BEFORE
// any clip: a clip that cuts a token in half leaves a fragment no pattern matches.
export const redact = (s) => s
    .replace(/\b[A-Z]{1,2}-[A-Za-z0-9][A-Za-z0-9._-]*-[0-9a-f]{6,}\b/g, '[nonce]')
    .replace(/\bR-[0-9a-f]{16,}/g, '[nonce]')
    .replace(/\b[A-Za-z0-9_]+-[A-Za-z0-9_]+-pid\d+\b/g, '[lock]')
    .replace(/\bpid\d{4,}\b/g, '[pid]')
    .replace(/\b(?:sk-|ghp_|gho_|github_pat_|xox[a-z]-|AKIA)[A-Za-z0-9_-]{16,}/g, '[key]')
    .replace(/\b(tokens?|nonces?)(\s*[:=]?\s*)`[^`]*`/gi, '$1$2[redacted]');
