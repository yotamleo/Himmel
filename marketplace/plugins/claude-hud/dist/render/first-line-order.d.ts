import type { FirstLineSegment } from '../config.js';
export interface FirstLinePart {
    /** Segment key for orderable parts; null keeps the part in its original slot. */
    key: FirstLineSegment | null;
    text: string;
}
/**
 * Reorders the keyed parts of the first HUD line according to `order` while
 * unkeyed (renderer-specific) parts keep their original slots. A segment may
 * contribute multiple adjacent parts (e.g. project + git when
 * `branchOverflow` is "wrap"); those stay together. Keys present in `parts`
 * but absent from `order` are appended in their original order so every
 * rendered part always survives reordering.
 */
export declare function orderFirstLineParts(parts: FirstLinePart[], order: readonly FirstLineSegment[]): string[];
//# sourceMappingURL=first-line-order.d.ts.map