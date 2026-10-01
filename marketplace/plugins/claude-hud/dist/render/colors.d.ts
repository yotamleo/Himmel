import type { HudColorOverrides, UsageValueMode } from '../config.js';
import { type UsagePace } from '../usage-pace.js';
export declare const RESET = "\u001B[0m";
export declare function green(text: string): string;
export declare function yellow(text: string): string;
export declare function red(text: string): string;
export declare function cyan(text: string): string;
export declare function magenta(text: string): string;
export declare function dim(text: string): string;
export declare function claudeOrange(text: string): string;
export declare function model(text: string, colors?: Partial<HudColorOverrides>): string;
export declare function project(text: string, colors?: Partial<HudColorOverrides>): string;
export declare function git(text: string, colors?: Partial<HudColorOverrides>): string;
export declare function gitBranch(text: string, colors?: Partial<HudColorOverrides>): string;
export declare function label(text: string, colors?: Partial<HudColorOverrides>): string;
export declare function custom(text: string, colors?: Partial<HudColorOverrides>): string;
export declare function warning(text: string, colors?: Partial<HudColorOverrides>): string;
export declare function critical(text: string, colors?: Partial<HudColorOverrides>): string;
export interface ContextThresholds {
    warning?: number;
    critical?: number;
}
export declare function getContextColor(percent: number, colors?: Partial<HudColorOverrides>, thresholds?: ContextThresholds): string;
/**
 * Usage-window colour: the more severe of the used-percentage band and the
 * consumption pace (when pace is given).
 */
export declare function getQuotaColor(percent: number, colors?: Partial<HudColorOverrides>, pace?: UsagePace | null): string;
/**
 * A usage window's percentage (or remaining percentage) in its quota colour,
 * followed by a ▲ in the pace colour when pace is amber/red.
 */
export declare function formatQuotaPercent(percent: number | null, colors?: Partial<HudColorOverrides>, mode?: UsageValueMode, pace?: UsagePace | null): string;
export declare function quotaBar(percent: number, width?: number, colors?: Partial<HudColorOverrides>, pace?: UsagePace | null): string;
export declare function coloredBar(percent: number, width?: number, colors?: Partial<HudColorOverrides>, thresholds?: ContextThresholds): string;
//# sourceMappingURL=colors.d.ts.map