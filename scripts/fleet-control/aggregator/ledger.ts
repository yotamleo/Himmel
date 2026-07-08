import { existsSync, readFileSync } from "node:fs";

export type FeedPaths = { ledgerPath?: string; quotaPath?: string; posturePath?: string };
export type Feeds = { ledger: unknown[]; quota: unknown[]; posture: unknown | null; parseErrors: number; error: string | null };

// Append-only feeds legitimately have a partial final line mid-write, so a bad
// line is SKIPPED (good lines kept) and counted - never a throw that drops the
// whole feed. The skipped count surfaces the incompleteness instead of hiding it.
function readJsonl(path: string | undefined, onError: (msg: string) => void): { rows: unknown[]; parseErrors: number } {
  if (!path || !existsSync(path)) return { rows: [], parseErrors: 0 };
  let parseErrors = 0;
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch (e) {
    onError(e instanceof Error ? e.message : String(e));
    return { rows: [], parseErrors: 0 };
  }
  const rows = text.split(/\r?\n/).filter((l) => l.trim() !== "").flatMap((l) => {
    try { return [JSON.parse(l)]; } catch { parseErrors++; return []; }
  });
  return { rows, parseErrors };
}

export function readFeeds(paths: FeedPaths = {}): Feeds {
  let parseErrors = 0;
  const errors: string[] = [];
  const onError = (msg: string) => errors.push(msg);

  const ledger = readJsonl(paths.ledgerPath, onError);
  const quota = readJsonl(paths.quotaPath, onError);
  const posture = readJsonl(paths.posturePath, onError);
  parseErrors += ledger.parseErrors + quota.parseErrors + posture.parseErrors;

  return {
    ledger: ledger.rows,
    quota: quota.rows,
    posture: posture.rows[posture.rows.length - 1] ?? null,
    parseErrors,
    error: errors.length ? errors.join("; ") : null,
  };
}
