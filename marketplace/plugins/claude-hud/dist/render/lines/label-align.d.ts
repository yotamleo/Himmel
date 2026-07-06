import type { HudColorOverrides } from "../../config.js";
import type { MessageKey } from "../../i18n/types.js";
/**
 * Compute the visual width of a plain-text string (no ANSI).
 * CJK ideographs count as 2 cells; ASCII characters count as 1.
 * In CJK locales, East Asian Ambiguous-width chars also count as 2.
 */
declare function plainTextWidth(str: string): number;
/** Compute the max visual width across the three progress-bar labels. */
declare function maxLabelWidth(): number;
/**
 * Return a label whose visible text is right-padded to align with the widest
 * progress-bar label in the current locale, then wrapped with the `label()`
 * ANSI helper.
 */
export declare function paddedLabel(key: MessageKey, colors?: Partial<HudColorOverrides>): string;
export declare function progressLabel(key: MessageKey, colors?: Partial<HudColorOverrides>, align?: boolean): string;
export { plainTextWidth as _plainTextWidth, maxLabelWidth as _maxLabelWidth };
//# sourceMappingURL=label-align.d.ts.map