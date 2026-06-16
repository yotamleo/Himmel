/**
 * Parse a comma-separated `--labels` argument into the string array Jira's
 * REST API expects for `fields.labels` (HIMMEL-243).
 *
 * Split on comma, trim each token, drop empties. An argument that yields no
 * labels (empty string, whitespace, bare commas) is an operator error —
 * unlike `--status` there is no sensible default to fall back to, and on
 * `edit` a silently-empty array would wipe every label on the issue.
 */
export function parseLabels(arg: string): string[] {
  const labels = arg
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  if (labels.length === 0) {
    throw new Error(
      '--labels requires at least one non-empty label (comma-separated, e.g. --labels a,b)',
    );
  }
  return labels;
}
