/**
 * Strip ANSI escape sequences (CSI, OSC, 7-bit C1/Fe), control characters,
 * and bidi overrides from an untrusted string.
 *
 * Use this whenever displaying user-supplied or external text in the
 * terminal to prevent escape injection and layout corruption.
 */
export declare function sanitizeDisplayText(input: string): string;
//# sourceMappingURL=sanitize.d.ts.map