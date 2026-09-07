// scripts/telegram/lane-args.ts
// HIMMEL-2154: spawn-glm's parseArgs and spawn-claudex's parseClaudexArgs
// duplicated the same cwd/name/branch/timeout/profile/plugins/brief flag
// mechanics — a value-taking flag with a "requires a value" refusal on a
// trailing/missing value, an unrecognized-flag refusal, and a first-positional
// capture. This module is the ONE shared loop; each caller still declares its
// own flag table (spawn-glm.ts's GLM_FLAG_TABLE / spawn-claudex.ts's
// CLAUDEX_FLAG_TABLE) and its own cross-flag constraints explicitly — this is
// not a new validation layer, just the mechanical part factored out once.

export type LaneParseResult = { ok: true } | { ok: false; error: string };

// A value-taking flag (`--x <value>`). apply() commits the raw string to
// state and returns an error string to refuse, or undefined to accept —
// exactly the per-flag validation each caller already wrote inline.
export type ValueFlag<S> = {
  kind: "value";
  apply: (state: S, value: string) => string | undefined;
  // Overrides the default "<flag> requires a value" message (e.g.
  // --rounds-override's reason-required wording).
  missingValueError?: string;
};
// A no-value flag (`--x`) that just mutates state.
export type BoolFlag<S> = { kind: "bool"; apply: (state: S) => void };
export type FlagSpec<S> = ValueFlag<S> | BoolFlag<S>;
export type FlagTable<S> = Record<string, FlagSpec<S>>;

// Runs argv through `table`, mutating `state` in place, and calling
// onPositional for every non-flag token — task capture (first positional
// wins, later ones are silently ignored) is the caller's own concern, this
// loop stays agnostic to what a positional means. Returns the FIRST error
// encountered, exactly like the two hand-written loops did.
export function parseLaneArgs<S>(argv: string[], table: FlagTable<S>, state: S, onPositional: (state: S, token: string) => void): LaneParseResult {
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const spec = table[a];
    if (spec?.kind === "bool") { spec.apply(state); continue; }
    if (spec?.kind === "value") {
      const v = argv[++i];
      if (v === undefined) return { ok: false, error: spec.missingValueError ?? `${a} requires a value` };
      const err = spec.apply(state, v);
      if (err) return { ok: false, error: err };
      continue;
    }
    // HIMMEL-1225: a bare unrecognized flag is a mistyped/unsupported option,
    // NOT a task — fail closed rather than dispatch a real worker to reason
    // about the literal flag string.
    if (a.startsWith("-")) return { ok: false, error: `unrecognized flag "${a}" (--help for usage)` };
    onPositional(state, a);
  }
  return { ok: true };
}
