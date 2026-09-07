export const UNKNOWN_TERMINAL_WIDTH = null;
export const MAX_TERMINAL_WIDTH = 1000;

function normalizeColumns(columns: number): number {
  return Math.min(Math.floor(columns), MAX_TERMINAL_WIDTH);
}

function parseEnvColumns(): number | null {
  const envColumns = Number.parseInt(process.env.COLUMNS ?? '', 10);
  return Number.isFinite(envColumns) && envColumns > 0 ? normalizeColumns(envColumns) : null;
}

function parseStreamColumns(columns: unknown): number | null {
  return typeof columns === 'number' && Number.isFinite(columns) && columns > 0
    ? normalizeColumns(columns)
    : null;
}

export function getTerminalWidth(options: { preferEnv?: boolean; fallback?: number | null } = {}): number | null {
  const { preferEnv = false, fallback = null } = options;
  const normalizedFallback = parseStreamColumns(fallback);

  if (preferEnv) {
    return parseEnvColumns()
      ?? parseStreamColumns(process.stdout?.columns)
      ?? parseStreamColumns(process.stderr?.columns)
      ?? normalizedFallback;
  }

  return parseStreamColumns(process.stdout?.columns)
    ?? parseStreamColumns(process.stderr?.columns)
    ?? parseEnvColumns()
    ?? normalizedFallback;
}

// Returns a progress bar width scaled to the current terminal width.
// Wide (>=100): 10, Medium (60-99): 6, Narrow (<60): 4.
export function getAdaptiveBarWidth(): number {
  const cols = getTerminalWidth({ preferEnv: true });

  if (cols !== null) {
    if (cols >= 100) return 10;
    if (cols >= 60) return 6;
    return 4;
  }
  return 10;
}
