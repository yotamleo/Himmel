// scripts/lanes/tests/lib/resolve-bash.mjs — HIMMEL-1723 test helper
// On this machine (and generally on Windows), a bare `bash` on PATH can
// resolve to the WSL launcher (C:\Windows\System32\bash.exe) instead of Git
// Bash — confirmed empirically: WSL bash cannot read a `C:/Users/...`
// Windows-form path at all ("No such file or directory"), which breaks every
// bench test that shells out to a .sh fixture. scripts/hooks/run-hook-with-
// bash.js already solves exactly this (refuses the WSL/WindowsApps aliases,
// selects a real Git Bash), so bench tests reuse it here instead of
// re-deriving the same resolver a second time.
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { resolveBash } = require(join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'hooks', 'run-hook-with-bash.js'));

// Falls back to the bare 'bash' command (matches run-hook-with-bash.js's own
// fail-open-to-nothing shape is NOT replicated here — a null resolution on a
// non-Windows CI box just means "use whatever bash is on PATH", which is
// correct there since the WSL-alias problem is Windows-only).
export const BASH_BIN = resolveBash() || 'bash';
