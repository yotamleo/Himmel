/**
 * The v1 bug freeze (operator ruling 2026-09-24, HIMMEL-3411): a Bug filed
 * after `cutoff` goes to `deferVersion` unless it is labelled `blockerLabel`.
 * The one place the date and version names live — `create` applies the
 * default and `freeze-check` reports what slipped past it.
 */
export const BUG_FREEZE = {
  cutoff: '2026-09-25',
  v1Version: 'v1.0.0',
  deferVersion: 'v1.0.1',
  blockerLabel: 'v1-blocker',
} as const;

/** Today as YYYY-MM-DD in local time, the same calendar Jira's `created` date uses for the operator. */
export function todayIso(now: Date = new Date()): string {
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

/** The fixVersion `create` should set, or undefined when the freeze does not apply. */
export function freezeFixVersion(
  type: string,
  labels: string[] | undefined,
  today: string,
): string | undefined {
  if (type.toLowerCase() !== 'bug') return undefined;
  if (today <= BUG_FREEZE.cutoff) return undefined;
  if (labels?.includes(BUG_FREEZE.blockerLabel)) return undefined;
  return BUG_FREEZE.deferVersion;
}

/** Post-cutoff Bugs sitting in the v1 version without the blocker label — the freeze's leaks. */
export function freezeCheckJql(project: string): string {
  const { cutoff, v1Version, blockerLabel } = BUG_FREEZE;
  return (
    `project = "${project}" AND issuetype = Bug AND created > "${cutoff}" ` +
    `AND fixVersion = "${v1Version}" AND (labels IS EMPTY OR labels != "${blockerLabel}") ORDER BY key ASC`
  );
}
