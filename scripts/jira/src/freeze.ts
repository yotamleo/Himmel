/**
 * The v1 bug freeze (operator ruling 2026-09-24, HIMMEL-3411): a Bug filed
 * after `cutoff` defaults to the earliest unreleased version after `v1Version`
 * (`pickFreezeVersion`, HIMMEL-4489) unless it is labelled `blockerLabel`.
 * The one place the date and version names live — `create` applies the
 * default and `freeze-check` reports what slipped past it.
 */
export const BUG_FREEZE = {
  cutoff: '2026-09-25',
  v1Version: 'v1.0.0',
  blockerLabel: 'v1-blocker',
} as const;

/** Today as YYYY-MM-DD in local time, the same calendar Jira's `created` date uses for the operator. */
export function todayIso(now: Date = new Date()): string {
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

/** Whether the freeze applies to a `create` of this type/labels today. */
export function freezeApplies(
  type: string,
  labels: string[] | undefined,
  today: string,
): boolean {
  if (type.toLowerCase() !== 'bug') return false;
  if (today <= BUG_FREEZE.cutoff) return false;
  return !labels?.includes(BUG_FREEZE.blockerLabel);
}

/**
 * The freeze default: the first unreleased, unarchived version after `v1Version`
 * in the project's version order, or undefined when none exists (or v1 is absent).
 */
export function pickFreezeVersion(
  versions: Array<{ name: string; released?: boolean; archived?: boolean }>,
): string | undefined {
  const v1 = versions.findIndex((v) => v.name === BUG_FREEZE.v1Version);
  if (v1 < 0) return undefined;
  return versions.slice(v1 + 1).find((v) => !v.released && !v.archived)?.name;
}

/** Post-cutoff Bugs sitting in the v1 version without the blocker label — the freeze's leaks. */
export function freezeCheckJql(project: string): string {
  const { cutoff, v1Version, blockerLabel } = BUG_FREEZE;
  // Jira reads `created > "<date>"` as after 00:00 that day, so start at the day after the cutoff.
  const firstFrozenDay = new Date(`${cutoff}T00:00:00Z`);
  firstFrozenDay.setUTCDate(firstFrozenDay.getUTCDate() + 1);
  return (
    `project = "${project}" AND issuetype = Bug AND created >= "${firstFrozenDay.toISOString().slice(0, 10)}" ` +
    `AND fixVersion = "${v1Version}" AND (labels IS EMPTY OR labels != "${blockerLabel}") ORDER BY key ASC`
  );
}
