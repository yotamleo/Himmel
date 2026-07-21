import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { createDebug } from './debug.js';
import { sanitizeDisplayText } from './utils/sanitize.js';
const debug = createDebug('jj');
const execFileAsync = promisify(execFile);
// Defensive bound against pathological/symlink cases; real repo trees never
// nest this deep.
const MAX_WALK_DEPTH = 64;
const MAX_OUTPUT_BYTES = 16 * 1024;
const MAX_DISPLAY_LABEL_LENGTH = 64;
const FIELD_SEPARATOR = '\x1f';
const BOOKMARK_SEPARATOR = '\x1e';
const defaultRunner = async (file, args, options) => {
    const { stdout } = await execFileAsync(file, [...args], options);
    return { stdout };
};
function resolveRealDirectory(cwd) {
    try {
        const resolved = fs.realpathSync(cwd);
        return fs.lstatSync(resolved).isDirectory() ? resolved : null;
    }
    catch {
        return null;
    }
}
function markerType(markerPath) {
    try {
        return fs.lstatSync(markerPath).isDirectory() ? 'directory' : 'other';
    }
    catch {
        return null;
    }
}
/**
 * Cheap, synchronous, subprocess-free check: walk upward from cwd looking for
 * a `.jj` directory, the same way jj's own CLI locates a repo root. Runs
 * before any subprocess is spawned so non-jj users pay ~zero cost per
 * invocation (a few fs.statSync calls, never an execFile).
 */
export function isJjRepo(cwd) {
    if (!cwd)
        return false;
    let dir = resolveRealDirectory(cwd);
    if (!dir)
        return false;
    for (let i = 0; i < MAX_WALK_DEPTH; i++) {
        // A real, same-directory .jj wins for colocated repositories. lstatSync is
        // deliberate: following a contributor-controlled marker symlink could
        // cause the HUD to execute jj in a directory that is not actually a repo.
        if (markerType(path.join(dir, '.jj')) === 'directory')
            return true;
        // Do not escape a nested Git repository to discover an unrelated parent
        // jj checkout. A .git directory or worktree marker file is a boundary.
        if (markerType(path.join(dir, '.git')) !== null)
            return false;
        const parent = path.dirname(dir);
        if (parent === dir)
            break; // reached filesystem root
        dir = parent;
    }
    return false;
}
// Four \x1f-delimited fields collected in a single `jj log` call:
//   change id (short) | bookmarks at @ | dirty flag | conflict flag
const JJ_TEMPLATE = [
    'change_id.shortest(8)',
    '"\\x1f"',
    'self.local_bookmarks().map(|bookmark| bookmark.name()).join("\\x1e")',
    '"\\x1f"',
    'if(self.empty(), "0", "1")',
    '"\\x1f"',
    'if(self.conflict(), "1", "0")',
].join(' ++ ');
const JJ_ARGS = [
    '--ignore-working-copy',
    '--at-operation=@',
    '--no-pager',
    'log',
    '-r',
    '@',
    '--no-graph',
    '--color',
    'never',
    '-T',
    JJ_TEMPLATE,
];
function removeSingleLineEnding(output) {
    if (output.endsWith('\r\n'))
        return output.slice(0, -2);
    if (output.endsWith('\n'))
        return output.slice(0, -1);
    return output;
}
function sanitizeLabel(value) {
    const sanitized = sanitizeDisplayText(value).trim();
    if (!sanitized)
        return null;
    // Count Unicode code points rather than UTF-16 code units so the display
    // limit cannot leave a dangling surrogate at the truncation boundary.
    return Array.from(sanitized).slice(0, MAX_DISPLAY_LABEL_LENGTH).join('');
}
function parseJjOutput(stdout) {
    const output = removeSingleLineEnding(stdout);
    if (output.includes('\n') || output.includes('\r'))
        return null;
    const fields = output.split(FIELD_SEPARATOR);
    if (fields.length !== 4)
        return null;
    const [changeIdRaw, bookmarksRaw, dirtyFlag, conflictFlag] = fields;
    if ((dirtyFlag !== '0' && dirtyFlag !== '1') ||
        (conflictFlag !== '0' && conflictFlag !== '1')) {
        return null;
    }
    const changeId = sanitizeLabel(changeIdRaw);
    if (!changeId)
        return null;
    const bookmarks = bookmarksRaw === '' ? [] : bookmarksRaw.split(BOOKMARK_SEPARATOR);
    if (bookmarks.some((bookmark) => bookmark.length === 0))
        return null;
    const branch = sanitizeLabel(bookmarks[0] ?? changeId);
    if (!branch)
        return null;
    return {
        branch,
        isDirty: dirtyFlag === '1',
        ahead: 0,
        behind: 0,
        vcs: 'jj',
        conflict: conflictFlag === '1',
    };
}
export async function getJjStatus(cwd, runner = defaultRunner) {
    if (!cwd)
        return null;
    const resolvedCwd = resolveRealDirectory(cwd);
    if (!resolvedCwd)
        return null;
    try {
        const { stdout } = await runner('jj', JJ_ARGS, {
            cwd: resolvedCwd,
            timeout: 2000,
            maxBuffer: MAX_OUTPUT_BYTES,
            encoding: 'utf8',
            windowsHide: true,
            shell: false,
        });
        return parseJjOutput(stdout);
    }
    catch (err) {
        // Covers: jj binary missing (ENOENT), not in a jj repo, or a template
        // incompatible with the installed jj version — all treated the same as
        // git.ts's failure handling: return null, render nothing.
        debug('getJjStatus failed (jj missing/incompatible?):', err instanceof Error ? err.message : err);
        return null;
    }
}
//# sourceMappingURL=jj.js.map