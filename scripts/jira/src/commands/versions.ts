import type { Command } from 'commander';
import { request, projectKey } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';

// HIMMEL-3429: Jira project versions (the fixVersions pick-list) mirror the
// GitHub release tags. REST v3: GET /project/{key}/versions is unpaginated (a
// plain array); POST /version creates; PUT /version/{id} releases; an issue's
// fixVersions is multi-valued and edited with the add/remove `update` verbs so
// adding one never clobbers another.

interface JiraVersion {
  id: string;
  name: string;
  self?: string;
  released?: boolean;
  releaseDate?: string;
}

export interface VersionCreateOptions {
  description?: string;
  startDate?: string;
  releaseDate?: string;
  released?: boolean;
}

// HIMMEL-3890: the start date is what `roadmap sync-sprints` uses as a sprint start.
export type VersionEditOptions = Pick<VersionCreateOptions, 'description' | 'startDate' | 'releaseDate'>;

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

/** YYYY-MM-DD that is also a real calendar day (2026-02-30 is refused here, not by Jira). */
export function checkDate(d: string, flag: string): string {
  const real = ISO_DATE.test(d) && !Number.isNaN(Date.parse(d)) && new Date(d).toISOString().startsWith(d);
  if (!real) throw new Error(`${flag} must be YYYY-MM-DD (got "${d}")`);
  return d;
}

export function buildVersionCreateBody(
  project: string,
  name: string,
  opts: VersionCreateOptions,
): Record<string, unknown> {
  const trimmed = name.trim();
  if (!trimmed) throw new Error('version name must not be blank');
  const body: Record<string, unknown> = { name: trimmed, project };
  Object.assign(body, datedFields(opts));
  if (opts.released !== undefined) body.released = opts.released;
  return body;
}

function datedFields(opts: VersionEditOptions): Record<string, unknown> {
  const body: Record<string, unknown> = {};
  if (opts.description !== undefined) body.description = opts.description;
  if (opts.startDate !== undefined) body.startDate = checkDate(opts.startDate, '--start-date');
  if (opts.releaseDate !== undefined) body.releaseDate = checkDate(opts.releaseDate, '--release-date');
  return body;
}

export function buildFixVersionBody(
  op: 'add' | 'remove',
  name: string,
): { update: { fixVersions: Array<Record<string, { name: string }>> } } {
  return { update: { fixVersions: [{ [op]: { name } }] } };
}

const fetchVersions = (project: string) =>
  request<JiraVersion[]>('GET', `/project/${encodeURIComponent(project)}/versions`);

export async function listVersions(project: string): Promise<string[]> {
  const versions = await fetchVersions(project);
  return versions.map((v) => `${v.name}\t${v.released ? 'true' : 'false'}\t${v.releaseDate ?? ''}`);
}

export async function createVersion(
  project: string,
  name: string,
  opts: VersionCreateOptions,
): Promise<string> {
  const created = await request<JiraVersion>(
    'POST',
    '/version',
    buildVersionCreateBody(project, name, opts),
  );
  return `Created version ${created.name} (id ${created.id})`;
}

export async function releaseVersion(
  project: string,
  name: string,
  date?: string,
): Promise<string> {
  const body: Record<string, unknown> = { released: true };
  if (date !== undefined) body.releaseDate = checkDate(date, '--date');
  const found = (await fetchVersions(project)).find((v) => v.name === name);
  if (!found) throw new Error(`no version named "${name}" in project ${project}`);
  await request('PUT', `/version/${found.id}`, body);
  return `Released version ${name}`;
}

export interface VersionArchiveOptions {
  unarchive?: boolean;
  force?: boolean;
}

// HIMMEL-4469: archiving hides a version from the fixVersion pick-list. It is
// refused while issues still carry the version (counted via relatedIssueCounts)
// unless --force; --unarchive restores it and never needs the check.
export async function archiveVersion(
  project: string,
  name: string,
  opts: VersionArchiveOptions,
): Promise<string> {
  const found = (await fetchVersions(project)).find((v) => v.name === name);
  if (!found) throw new Error(`no version named "${name}" in project ${project}`);
  const archived = !opts.unarchive;
  if (archived && !opts.force) {
    const counts = await request<{ issuesFixedCount?: number; issuesAffectedCount?: number }>(
      'GET',
      `/version/${found.id}/relatedIssueCounts`,
    );
    const fixed = counts.issuesFixedCount ?? 0;
    const affected = counts.issuesAffectedCount ?? 0;
    if (fixed + affected > 0) {
      throw new Error(
        `version "${name}" still has ${fixed} fix-version and ${affected} affects-version issues; pass --force to archive it anyway`,
      );
    }
  }
  await request('PUT', `/version/${found.id}`, { archived });
  return `${archived ? 'Archived' : 'Unarchived'} version ${name}`;
}

export async function editVersion(
  project: string,
  name: string,
  opts: VersionEditOptions,
): Promise<string> {
  const body = datedFields(opts);
  if (Object.keys(body).length === 0) {
    throw new Error('version-edit: nothing to edit (pass --start-date, --release-date or --description)');
  }
  const found = (await fetchVersions(project)).find((v) => v.name === name);
  if (!found) throw new Error(`no version named "${name}" in project ${project}`);
  await request('PUT', `/version/${found.id}`, body);
  return `Edited version ${name}`;
}

export interface VersionMoveOptions {
  after?: string;
  position?: string;
}

const MOVE_POSITIONS = ['First', 'Last'];

// HIMMEL-4006: Jira appends a new version at the END of the release list; this
// repositions one (POST /version/{id}/move) so a trail version sits by its parent.
export async function moveVersion(
  project: string,
  name: string,
  opts: VersionMoveOptions,
): Promise<string> {
  if ((opts.after === undefined) === (opts.position === undefined)) {
    throw new Error('version-move needs exactly one of --after <name> or --position First|Last');
  }
  if (opts.position !== undefined && !MOVE_POSITIONS.includes(opts.position)) {
    throw new Error(`--position must be one of ${MOVE_POSITIONS.join('|')} (got "${opts.position}")`);
  }
  const versions = await fetchVersions(project);
  const find = (n: string) => {
    const v = versions.find((x) => x.name === n);
    if (!v) throw new Error(`no version named "${n}" in project ${project}`);
    return v;
  };
  const moving = find(name);
  if (opts.after !== undefined) {
    const anchor = find(opts.after);
    if (!anchor.self) throw new Error(`version "${opts.after}" has no self URL in the Jira response`);
    await request('POST', `/version/${moving.id}/move`, { after: anchor.self });
    return `Moved version ${name} after ${opts.after}`;
  }
  await request('POST', `/version/${moving.id}/move`, { position: opts.position });
  return `Moved version ${name} to ${opts.position}`;
}

// HIMMEL-3713: shared validation so `edit --fix-version`/`--add-fix-version`
// and `create --fix-version` fail loud on a typo'd version name instead of
// silently no-oping or surfacing a bare Jira 400 with no project context.
export async function assertVersionExists(project: string, name: string): Promise<void> {
  const found = (await fetchVersions(project)).some((v) => v.name === name);
  if (!found) throw new Error(`no version named "${name}" in project ${project}`);
}

// A Jira project key never contains a hyphen, so the project is everything
// before the LAST one — used to validate `edit <key> --fix-version` against
// the issue's own project rather than the configured default (HIMMEL-3713:
// `edit` has no `--project` flag, unlike `create`).
export function projectFromKey(key: string): string {
  const idx = key.lastIndexOf('-');
  if (idx <= 0) throw new Error(`"${key}" is not a valid issue key (expected PROJECT-NUMBER)`);
  return key.slice(0, idx);
}

export async function setFixVersion(
  key: string,
  op: 'add' | 'remove',
  name: string,
): Promise<string> {
  await request('PUT', `/issue/${key}`, buildFixVersionBody(op, name));
  return `${key} fixVersion ${op === 'add' ? '+' : '-'}${name}`;
}

export function registerVersions(program: Command): void {
  program
    .command('versions')
    .description('List project versions (name, released, releaseDate)')
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .action(async (options: { project?: string }) => {
      for (const row of await listVersions(options.project ?? projectKey())) console.log(row);
    });

  program
    .command('version-create <name>')
    .description('Create a project version')
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .option('--start-date <date>', 'Start date, YYYY-MM-DD')
    .option('--release-date <date>', 'Release date, YYYY-MM-DD')
    .option('--released', 'Mark the version released')
    .option('--description <text>', 'Version description')
    .action(
      async (
        name: string,
        options: {
          project?: string;
          startDate?: string;
          releaseDate?: string;
          released?: boolean;
          description?: string;
        },
      ) => {
        console.log(
          await createVersion(options.project ?? projectKey(), name, {
            description: options.description,
            startDate: options.startDate,
            releaseDate: options.releaseDate,
            released: options.released,
          }),
        );
      },
    );

  program
    .command('version-edit <name>')
    .description('Edit an existing project version (start date, release date, description)')
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .option('--start-date <date>', 'Start date, YYYY-MM-DD')
    .option('--release-date <date>', 'Release date, YYYY-MM-DD')
    .option('--description <text>', 'Version description')
    .action(async (name: string, options: VersionEditOptions & { project?: string }) => {
      console.log(
        await editVersion(options.project ?? projectKey(), name, {
          description: options.description,
          startDate: options.startDate,
          releaseDate: options.releaseDate,
        }),
      );
    });

  program
    .command('version-release <name>')
    .description('Mark an existing project version released')
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .option('--date <date>', 'Release date, YYYY-MM-DD')
    .action(async (name: string, options: { project?: string; date?: string }) => {
      console.log(await releaseVersion(options.project ?? projectKey(), name, options.date));
    });

  program
    .command('version-archive <name>')
    .description('Archive a project version (refused while issues carry it, unless --force)')
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .option('--unarchive', 'Restore an archived version instead')
    .option('--force', 'Archive even if issues still carry the version')
    .action(async (name: string, options: VersionArchiveOptions & { project?: string }) => {
      console.log(
        await archiveVersion(options.project ?? projectKey(), name, {
          unarchive: options.unarchive,
          force: options.force,
        }),
      );
    });

  program
    .command('version-move <name>')
    .description('Reposition a project version in the release list (after another version, or First/Last)')
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .option('--after <name>', 'Place directly after this version')
    .option('--position <pos>', 'First or Last')
    .action(async (name: string, options: VersionMoveOptions & { project?: string }) => {
      console.log(
        await moveVersion(options.project ?? projectKey(), name, {
          after: options.after,
          position: options.position,
        }),
      );
    });

  program
    .command('fix-version <key>')
    .description('Add or remove one fixVersion on an issue (multi-valued; other versions untouched)')
    .option('--add <name>', 'Version name to add')
    .option('--remove <name>', 'Version name to remove')
    .action(async (key: string, options: { add?: string; remove?: string }) => {
      if ((options.add === undefined) === (options.remove === undefined)) {
        throw new Error('fix-version needs exactly one of --add <name> or --remove <name>');
      }
      const op = options.add !== undefined ? 'add' : 'remove';
      console.log(await setFixVersion(key, op, (options.add ?? options.remove) as string));
      writeJiraBreadcrumb(key);
    });
}
