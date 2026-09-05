import type { HourCycleMode, TimeFormatMode } from '../config.js';
import type { MessageKey } from '../i18n/types.js';
/** Options controlling how wall-clock time is rendered. */
export interface WallClockOptions {
    hourCycle: HourCycleMode;
    showSeconds: boolean;
}
/**
 * Formats a usage-window reset timestamp for display in the HUD.
 *
 * @param resetAt - The reset timestamp, or null if unknown.
 * @param mode    - How to express the time:
 *   - `'relative'` (default) — duration until reset, e.g. `2h 30m`
 *   - `'absolute'`           — wall-clock time,       e.g. `at 14:30` (locale-aware)
 *   - `'both'`               — both combined,          e.g. `2h 30m, at 14:30` (locale-aware)
 * @param opts    - Wall-clock rendering options (hourCycle, showSeconds); defaults preserve existing behavior.
 * @returns A formatted string, or an empty string when the reset is in the past
 *          or the date is unknown.
 */
export declare function formatResetTime(resetAt: Date | null, mode?: TimeFormatMode, opts?: WallClockOptions): string;
/**
 * Renders a timestamp as wall-clock time, e.g. `at 14:30`, adding a date
 * component when it falls on a different calendar day than `now`.
 *
 * @param at   - The timestamp to render.
 * @param now  - Reference for the same-day check.
 * @param opts - Wall-clock rendering options (hourCycle, showSeconds).
 */
export declare function formatAbsoluteTime(resetAt: Date, now: Date, opts?: WallClockOptions, pattern?: MessageKey): string;
//# sourceMappingURL=format-reset-time.d.ts.map