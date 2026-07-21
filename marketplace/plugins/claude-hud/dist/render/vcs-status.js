import { DEFAULT_CONFIG } from '../config.js';
import { sanitizeDisplayText } from '../utils/sanitize.js';
/**
 * Resolve VCS-specific visibility once so compact and expanded layouts cannot
 * drift. jj never inherits Git-only ahead/behind or file-stat settings.
 */
export function getVcsDisplayState(status, config) {
    if (!status)
        return null;
    const kind = status.vcs === 'jj' ? 'jj' : 'git';
    const gitConfig = config.gitStatus ?? DEFAULT_CONFIG.gitStatus;
    const jjConfig = config.jjStatus ?? DEFAULT_CONFIG.jjStatus;
    const enabled = kind === 'jj' ? jjConfig.enabled : gitConfig.enabled;
    if (!enabled)
        return null;
    const showDirty = kind === 'jj' ? jjConfig.showDirty : gitConfig.showDirty;
    const isGit = kind === 'git';
    return {
        kind,
        branch: sanitizeDisplayText(status.branch),
        dirty: showDirty && status.isDirty,
        conflict: kind === 'jj' && jjConfig.showConflicts && status.conflict === true,
        ahead: isGit && gitConfig.showAheadBehind ? status.ahead : 0,
        behind: isGit && gitConfig.showAheadBehind ? status.behind : 0,
        fileStats: isGit && gitConfig.showFileStats ? status.fileStats : undefined,
        lineDiff: isGit && gitConfig.showFileStats ? status.lineDiff : undefined,
        branchUrl: isGit ? status.branchUrl : undefined,
        branchOverflow: gitConfig.branchOverflow,
    };
}
//# sourceMappingURL=vcs-status.js.map