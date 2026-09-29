// scripts/lib/is-main.mjs — HIMMEL-3810. The one "am I the entry script?" check
// for .mjs CLIs: `if (isMain(import.meta.url)) main();`
//
// WHY realpath BOTH sides: Node resolves import.meta.url through symlinks to the
// REALPATH, while process.argv[1] stays the path the caller typed. Comparing the
// two raw (resolve(argv[1]) === fileURLToPath(import.meta.url), or
// pathToFileURL(argv[1]).href === import.meta.url) is false whenever the script
// is invoked through a symlinked directory or file (macOS /tmp -> /private/tmp,
// any symlinked dir on Linux), so main() silently never runs: empty stdout,
// rc 0, and e.g. `himmelctl trust on` looks applied but is not.
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export function isMain(importMetaUrl) {
  const argv1 = process.argv[1];
  if (!argv1) return false;
  try {
    return realpathSync(fileURLToPath(importMetaUrl)) === realpathSync(argv1);
  } catch {
    return false; // argv[1] not a real path (node -e, REPL) or url not file:
  }
}
