import * as fs from 'node:fs';
import type { HudConfig } from './config.js';
import type { UsageData } from './types.js';
export declare const EXTERNAL_USAGE_WRITE_THROTTLE_MS = 30000;
type FileSystemDeps = {
    chmodSync: typeof fs.chmodSync;
    existsSync: typeof fs.existsSync;
    readFileSync: typeof fs.readFileSync;
    renameSync: typeof fs.renameSync;
    rmSync: typeof fs.rmSync;
    statSync: typeof fs.statSync;
    writeFileSync: typeof fs.writeFileSync;
};
export declare function writeExternalUsageSnapshot(config: HudConfig, usage: UsageData | null, now?: number, deps?: FileSystemDeps): boolean;
export declare function getUsageFromExternalSnapshot(config: HudConfig, now?: number): UsageData | null;
export {};
//# sourceMappingURL=external-usage.d.ts.map