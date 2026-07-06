/**
 * Wrap `text` in an OSC 8 hyperlink pointing to `uri`.
 */
export declare function hyperlink(uri: string, text: string): string;
/**
 * Convert a filesystem path to a `file://` URL string.
 * Returns `null` on failure.
 */
export declare function getFileHref(filePath: string): string | null;
/**
 * Wrap `text` in an OSC 8 hyperlink after validating the URI.
 *
 * Only `https:` and `file:` protocols are allowed. Returns plain `text`
 * when the URI is missing, invalid, or uses a disallowed protocol.
 *
 * @param uri       - The URI to link to (may be undefined/null).
 * @param text      - The visible text to display.
 * @param protocols - Allowed URL protocols (default: `['https:', 'file:']`).
 */
export declare function safeHyperlink(uri: string | undefined | null, text: string, protocols?: string[]): string;
//# sourceMappingURL=hyperlinks.d.ts.map