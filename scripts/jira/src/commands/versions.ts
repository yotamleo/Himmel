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
  released?: boolean;
  releaseDate?: string;
}

export interface VersionCreateOptions {
  description?: string;
  releaseDate?: string;
  released?: boolean;
}

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

function checkDate(d: string, flag: string): string {
  if (!ISO_DATE.test(d)) throw new Error(`${flag} must be YYYY-MM-DD (got "${d}")`);
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
  if (opts.description !== undefined) body.description = opts.description;
  if (opts.releaseDate !== undefined) body.releaseDate = checkDate(opts.releaseDate, '--release-date');
  if (opts.released !== undefined) body.released = opts.released;
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

// HIMMEL-3713: shared validation so `edit --fix-version`/`--add-fix-version`
// and `create --fix-version` fail loud on a typo'd version name instead of
// silently no-oping or surfacing a bare Jira 400 with no project context.
export async function assertVersionExists(project: string, name: string): Promise<void> {
  const found = (await fetchVersions(project)).some((v) => v.name === name);
  if (!found) throw new Error(`no version named "${name}" in project ${project}`);
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
    .option('--release-date <date>', 'Release date, YYYY-MM-DD')
    .option('--released', 'Mark the version released')
    .option('--description <text>', 'Version description')
    .action(
      async (
        name: string,
        options: { project?: string; releaseDate?: string; released?: boolean; description?: string },
      ) => {
        console.log(
          await createVersion(options.project ?? projectKey(), name, {
            description: options.description,
            releaseDate: options.releaseDate,
            released: options.released,
          }),
        );
      },
    );

  program
    .command('version-release <name>')
    .description('Mark an existing project version released')
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .option('--date <date>', 'Release date, YYYY-MM-DD')
    .action(async (name: string, options: { project?: string; date?: string }) => {
      console.log(await releaseVersion(options.project ?? projectKey(), name, options.date));
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
