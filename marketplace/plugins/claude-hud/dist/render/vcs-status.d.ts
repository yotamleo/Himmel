import type { HudConfig, GitBranchOverflowMode } from '../config.js';
import type { GitStatus, FileStats, LineDiff } from '../git.js';
export interface VcsDisplayState {
    kind: 'git' | 'jj';
    branch: string;
    dirty: boolean;
    conflict: boolean;
    ahead: number;
    behind: number;
    fileStats?: FileStats;
    lineDiff?: LineDiff;
    branchUrl?: string;
    branchOverflow: GitBranchOverflowMode;
}
/**
 * Resolve VCS-specific visibility once so compact and expanded layouts cannot
 * drift. jj never inherits Git-only ahead/behind or file-stat settings.
 */
export declare function getVcsDisplayState(status: GitStatus | null, config: Pick<Partial<HudConfig>, 'gitStatus' | 'jjStatus'>): VcsDisplayState | null;
//# sourceMappingURL=vcs-status.d.ts.map