export declare const TRANSCRIPT_MODEL_MAX_LEN = 80;
/**
 * Normalize model IDs read from transcripts or their cache before display.
 * Proxy-provided model values are untrusted terminal input, so strip ANSI,
 * OSC, control, and bidi sequences and keep the retained value bounded.
 */
export declare function sanitizeTranscriptModel(value: unknown): string | undefined;
//# sourceMappingURL=model-source.d.ts.map