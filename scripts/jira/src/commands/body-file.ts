import { readFileSync } from 'node:fs';

/**
 * Read a markdown body (comment text or issue description) from a file.
 *
 * Lets callers pass a long / multi-line body via a file path instead of an
 * inline shell argument. A multi-line inline argument carries embedded
 * newlines (and often `;` `|` `>` prose), which makes the whole Bash command
 * un-vettable by the `auto-approve-safe-bash` hook → it falls through to the
 * auto-mode classifier and the jira write is DENIED. A `--*-file` flag keeps
 * the command a single line, so the hook can grant it (HIMMEL-209 complement).
 *
 * Mirrors the existing `--adf-file` error handling: a read failure prints a
 * one-line diagnostic to stderr and exits 1.
 */
export function readBodyFile(path: string, flag: string): string {
  try {
    return readFileSync(path, 'utf8');
  } catch (e) {
    console.error(`jira: cannot read ${flag} "${path}": ${(e as Error).message}`);
    process.exit(1);
  }
}
