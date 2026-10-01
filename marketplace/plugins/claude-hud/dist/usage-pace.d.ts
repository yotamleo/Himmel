import type { HudConfig } from './config.js';
import type { ScopedUsageWindow, UsageData } from './types.js';
export type UsagePace = 'normal' | 'warning' | 'critical';
export declare const FIVE_HOUR_WINDOW_MS: number;
export declare const SEVEN_DAY_WINDOW_MS: number;
/**
 * Grades how fast a rate-limit window is being consumed by projecting the
 * used percentage linearly to the window's reset. Returns null when there is
 * no usable rate: missing data, a reset already past, or a reset at least a
 * full window away (no time elapsed).
 */
export declare function getUsagePace(percent: number | null, resetAt: Date | null, windowMs: number, now?: number): UsagePace | null;
/** True when pace should draw attention (amber or red). */
export declare function isPaceAlert(pace: UsagePace | null): boolean;
/** Pace of every usage window, plus the display rules pace imposes. */
export interface UsagePaces {
    fiveHour: UsagePace | null;
    sevenDay: UsagePace | null;
    /** Parallel to the scoped windows passed in. */
    scoped: Array<UsagePace | null>;
    /** Some window is at amber/red pace: show usage despite `usageThreshold`. */
    alert: boolean;
    /** Show the weekly window: at/above `sevenDayThreshold`, or at amber/red pace. */
    showSevenDay: boolean;
}
/**
 * Grades every window's pace (all null unless `display.usagePace` is on) and
 * resolves the visibility rules both usage renderers share.
 */
export declare function resolveUsagePaces(usage: UsageData, scopedWindows: ScopedUsageWindow[], display: Partial<HudConfig['display']> | undefined, now?: number): UsagePaces;
//# sourceMappingURL=usage-pace.d.ts.map