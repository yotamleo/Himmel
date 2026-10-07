import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Command } from 'commander';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return { ...actual, request: vi.fn() };
});
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { registerVersions } from './versions.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

function run(args: string[]): Promise<Command> {
  const p = new Command();
  p.exitOverride();
  registerVersions(p);
  return p.parseAsync(['node', 'jira', ...args]);
}

const VERSIONS = [
  { id: '100', name: 'v1', self: 'https://j/rest/api/3/version/100', released: true, releaseDate: '2026-01-01' },
  { id: '101', name: 'v2', self: 'https://j/rest/api/3/version/101' },
];

describe('version commands + fix-version', () => {
  const savedKey = process.env.JIRA_PROJECT_KEY;
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    process.env.JIRA_PROJECT_KEY = 'HIM';
  });
  afterEach(() => {
    if (savedKey === undefined) delete process.env.JIRA_PROJECT_KEY;
    else process.env.JIRA_PROJECT_KEY = savedKey;
  });

  it('versions: GET /project/<key>/versions, prints name/released/date rows', async () => {
    mockRequest.mockResolvedValue(VERSIONS);
    await run(['versions']);
    expect(mockRequest).toHaveBeenCalledWith('GET', '/project/HIM/versions');
    expect(console.log).toHaveBeenNthCalledWith(1, 'v1\ttrue\t2026-01-01');
    expect(console.log).toHaveBeenNthCalledWith(2, 'v2\tfalse\t');
  });

  it('versions --project overrides the env key', async () => {
    mockRequest.mockResolvedValue([]);
    await run(['versions', '--project', 'OTH']);
    expect(mockRequest).toHaveBeenCalledWith('GET', '/project/OTH/versions');
  });

  it('version-create: POST /version with name/project/dates/released/description', async () => {
    mockRequest.mockResolvedValue({ id: '200', name: 'v3.0.0' });
    await run(['version-create', ' v3.0.0 ', '--start-date', '2026-02-01', '--release-date', '2026-03-01', '--released', '--description', 'd']);
    expect(mockRequest).toHaveBeenCalledWith('POST', '/version', {
      name: 'v3.0.0',
      project: 'HIM',
      description: 'd',
      startDate: '2026-02-01',
      releaseDate: '2026-03-01',
      released: true,
    });
    expect(console.log).toHaveBeenCalledWith('Created version v3.0.0 (id 200)');
  });

  it('version-create with a bad date rejects before any request', async () => {
    await expect(run(['version-create', 'v3.0.0', '--release-date', '2026-02-30'])).rejects.toThrow(/--release-date must be YYYY-MM-DD/);
    expect(mockRequest).not.toHaveBeenCalled();
  });

  it('version-edit: finds the id, PUTs only the given fields', async () => {
    mockRequest.mockImplementation(async (m: string) => (m === 'GET' ? VERSIONS : {}));
    await run(['version-edit', 'v2', '--start-date', '2026-04-01']);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/version/101', { startDate: '2026-04-01' });
    expect(console.log).toHaveBeenCalledWith('Edited version v2');
  });

  it('version-edit --name: PUTs the new name in place (HIMMEL-4872)', async () => {
    mockRequest.mockImplementation(async (m: string) => (m === 'GET' ? VERSIONS : {}));
    await run(['version-edit', 'v2', '--name', 'v1.1.0']);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/version/101', { name: 'v1.1.0' });
    expect(console.log).toHaveBeenCalledWith('Edited version v2');
  });

  it('version-edit --name refuses a non-semver name before any request (HIMMEL-4872)', async () => {
    await expect(run(['version-edit', 'v2', '--name', 'v1.0.2b'])).rejects.toThrow(/semver/);
    expect(mockRequest).not.toHaveBeenCalled();
  });

  it('version-create refuses a non-semver name before any request (HIMMEL-4872)', async () => {
    await expect(run(['version-create', 'v1.0.2i'])).rejects.toThrow(/semver/);
    expect(mockRequest).not.toHaveBeenCalled();
  });

  it('version-edit with nothing to edit rejects without a request', async () => {
    await expect(run(['version-edit', 'v2'])).rejects.toThrow(/nothing to edit/);
    expect(mockRequest).not.toHaveBeenCalled();
  });

  it('version-release --date: PUT released:true + releaseDate', async () => {
    mockRequest.mockImplementation(async (m: string) => (m === 'GET' ? VERSIONS : {}));
    await run(['version-release', 'v2', '--date', '2026-05-05']);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/version/101', { released: true, releaseDate: '2026-05-05' });
    expect(console.log).toHaveBeenCalledWith('Released version v2');
  });

  it('version-release of an unknown version rejects and never PUTs', async () => {
    mockRequest.mockResolvedValue(VERSIONS);
    await expect(run(['version-release', 'nope'])).rejects.toThrow('no version named "nope" in project HIM');
    expect(mockRequest.mock.calls.some((c) => c[0] === 'PUT')).toBe(false);
  });

  it('version-move --position First: POST /version/<id>/move {position}', async () => {
    mockRequest.mockImplementation(async (m: string) => (m === 'GET' ? VERSIONS : {}));
    await run(['version-move', 'v2', '--position', 'First']);
    expect(mockRequest).toHaveBeenCalledWith('POST', '/version/101/move', { position: 'First' });
    expect(console.log).toHaveBeenCalledWith('Moved version v2 to First');
  });

  it('version-move --after: sends the anchor self URL', async () => {
    mockRequest.mockImplementation(async (m: string) => (m === 'GET' ? VERSIONS : {}));
    await run(['version-move', 'v2', '--after', 'v1']);
    expect(mockRequest).toHaveBeenCalledWith('POST', '/version/101/move', { after: 'https://j/rest/api/3/version/100' });
    expect(console.log).toHaveBeenCalledWith('Moved version v2 after v1');
  });

  it('fix-version --add: PUT update.fixVersions add, breadcrumb, line', async () => {
    mockRequest.mockResolvedValue({});
    await run(['fix-version', 'HIM-9', '--add', 'v2']);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/issue/HIM-9', { update: { fixVersions: [{ add: { name: 'v2' } }] } });
    expect(writeJiraBreadcrumb).toHaveBeenCalledWith('HIM-9');
    expect(console.log).toHaveBeenCalledWith('HIM-9 fixVersion +v2');
  });

  it('fix-version --remove: remove verb and - sign', async () => {
    mockRequest.mockResolvedValue({});
    await run(['fix-version', 'HIM-9', '--remove', 'v1']);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/issue/HIM-9', { update: { fixVersions: [{ remove: { name: 'v1' } }] } });
    expect(console.log).toHaveBeenCalledWith('HIM-9 fixVersion -v1');
  });

  it('fix-version needs exactly one of --add/--remove', async () => {
    await expect(run(['fix-version', 'HIM-9'])).rejects.toThrow(/exactly one of --add/);
    await expect(run(['fix-version', 'HIM-9', '--add', 'a', '--remove', 'b'])).rejects.toThrow(/exactly one of --add/);
    expect(mockRequest).not.toHaveBeenCalled();
  });
});
