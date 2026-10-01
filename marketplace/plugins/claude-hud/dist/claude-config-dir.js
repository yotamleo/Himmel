import * as path from 'node:path';
export function expandHomeDirPrefix(inputPath, homeDir) {
    if (inputPath === '~') {
        return homeDir;
    }
    if (inputPath.startsWith('~/') || inputPath.startsWith('~\\')) {
        return path.join(homeDir, inputPath.slice(2));
    }
    return inputPath;
}
export function getClaudeConfigDir(homeDir) {
    const envConfigDir = process.env.CLAUDE_CONFIG_DIR?.trim();
    if (!envConfigDir) {
        return path.join(homeDir, '.claude');
    }
    return path.resolve(expandHomeDirPrefix(envConfigDir, homeDir));
}
// Claude Code keeps .claude.json inside CLAUDE_CONFIG_DIR when it is set, otherwise in the home directory.
export function getClaudeConfigJsonPath(homeDir) {
    const envConfigDir = process.env.CLAUDE_CONFIG_DIR?.trim();
    if (!envConfigDir) {
        return path.join(homeDir, '.claude.json');
    }
    return path.join(getClaudeConfigDir(homeDir), '.claude.json');
}
export function getHudPluginDir(homeDir) {
    return path.join(getClaudeConfigDir(homeDir), 'plugins', 'claude-hud');
}
//# sourceMappingURL=claude-config-dir.js.map