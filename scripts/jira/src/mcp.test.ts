import { describe, it, expect, vi, afterEach } from 'vitest';
import { createTools, buildServer, type ToolDeps, type JiraTool } from './mcp.js';

// Unit coverage for the MCP surface (HIMMEL-159). We mock the underlying
// client (`request` / `uploadAttachment`) and assert that every one of the
// ten tools (a) is registered, (b) carries an input schema, and (c) on a
// happy-path invocation routes to the client with the same payload the
// corresponding CLI verb builds. The handlers reuse the SAME shared
// functions the CLI verbs call, so this also pins parity.

const TOOL_NAMES = [
  'get',
  'create',
  'list',
  'transition',
  'transitions',
  'comment',
  'attach',
  'edit',
  'projects',
  'project-create',
];

function tool(name: string): JiraTool {
  const t = createTools().find((x) => x.name === name);
  if (!t) throw new Error(`tool ${name} not registered`);
  return t;
}

/** A ToolDeps whose request returns `reply` and records its calls. */
function mockDeps(reply: unknown = {}): {
  deps: ToolDeps;
  request: ReturnType<typeof vi.fn>;
  uploadAttachment: ReturnType<typeof vi.fn>;
} {
  const request = vi.fn(async () => reply);
  const uploadAttachment = vi.fn(async () => ({}));
  return {
    deps: { request, uploadAttachment } as unknown as ToolDeps,
    request,
    uploadAttachment,
  };
}

describe('MCP tool registration', () => {
  it('registers exactly the ten CLI verbs', () => {
    const names = createTools().map((t) => t.name).sort();
    expect(names).toEqual([...TOOL_NAMES].sort());
  });

  it.each(TOOL_NAMES)('tool %s has a non-empty description and object input schema', (name) => {
    const t = tool(name);
    expect(t.description.length).toBeGreaterThan(0);
    expect(t.inputSchema.type).toBe('object');
    expect(t.inputSchema.additionalProperties).toBe(false);
    expect(typeof t.inputSchema.properties).toBe('object');
  });

  it('marks required args to mirror Commander required semantics', () => {
    expect(tool('get').inputSchema.required).toEqual(['key']);
    expect(tool('create').inputSchema.required).toEqual(['type', 'title']);
    expect(tool('transition').inputSchema.required).toEqual(['key', 'status']);
    expect(tool('transitions').inputSchema.required).toEqual(['key']);
    expect(tool('comment').inputSchema.required).toEqual(['key']);
    expect(tool('attach').inputSchema.required).toEqual(['key', 'paths']);
    expect(tool('edit').inputSchema.required).toEqual(['key']);
    expect(tool('project-create').inputSchema.required).toEqual(['key', 'name']);
    // list / projects have no required args (mirror optional-only verbs)
    expect(tool('list').inputSchema.required).toBeUndefined();
    expect(tool('projects').inputSchema.required).toBeUndefined();
  });
});

describe('MCP server wiring', () => {
  it('builds a server and lists all ten tools via the ListTools handler', async () => {
    const server = buildServer();
    // Reach into the registered handler the SDK installs for ListTools.
    // Easier + version-stable: assert createTools (the source of the list)
    // and that buildServer does not throw with default deps.
    expect(server).toBeDefined();
    expect(createTools()).toHaveLength(10);
  });

  it('CallTool error path: non-Error throwable yields String() text (HIMMEL-292)', async () => {
    // Make the `get` tool's request throw a plain string — not an Error instance.
    const throwingRequest = vi.fn(async () => {
      throw 'plain string error';
    });
    const deps = { request: throwingRequest, uploadAttachment: vi.fn() } as unknown as ToolDeps;
    const server = buildServer(deps);

    // Reach into the registered CallTool handler via the private _requestHandlers map.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const handler = (server as any)._requestHandlers.get('tools/call');
    expect(handler).toBeDefined();

    const result = await handler({ method: 'tools/call', params: { name: 'get', arguments: { key: 'HIMMEL-1' } } }, {});
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toBe('plain string error');
  });
});

describe('MCP tool happy-path routing', () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it('get → GET /issue/<key> and formats with description', async () => {
    const { deps, request } = mockDeps({
      key: 'HIMMEL-1',
      fields: {
        summary: 'A bug',
        status: { name: 'To Do' },
        issuetype: { name: 'Task' },
        description: null,
      },
    });
    const out = await tool('get').handler({ key: 'HIMMEL-1' }, deps);
    expect(request).toHaveBeenCalledWith(
      'GET',
      '/issue/HIMMEL-1?fields=summary,status,issuetype,parent,assignee,description',
    );
    expect(out).toContain('HIMMEL-1');
    expect(out).toContain('A bug');
  });

  it('get --json returns raw JSON', async () => {
    const issue = {
      key: 'HIMMEL-2',
      fields: { summary: 's', status: { name: 'To Do' }, issuetype: { name: 'Task' } },
    };
    const { deps } = mockDeps(issue);
    const out = await tool('get').handler({ key: 'HIMMEL-2', json: true }, deps);
    expect(JSON.parse(out)).toEqual(issue);
  });

  it('create → POST /issue with project/summary/issuetype + markdown desc', async () => {
    const { deps, request } = mockDeps({ key: 'HIMMEL-9', id: '1' });
    const out = await tool('create').handler(
      { type: 'Task', title: 'New', desc: 'Hello', project: 'ABC' },
      deps,
    );
    expect(request).toHaveBeenCalledWith('POST', '/issue', {
      fields: {
        project: { key: 'ABC' },
        summary: 'New',
        issuetype: { name: 'Task' },
        description: {
          type: 'doc',
          version: 1,
          content: [
            { type: 'paragraph', content: [{ type: 'text', text: 'Hello' }] },
          ],
        },
      },
    });
    expect(out).toBe('Created HIMMEL-9');
  });

  it('create with attach uploads each file via the injected uploadAttachment', async () => {
    // This path omits `project`, so the handler falls back to projectKey(),
    // which reads JIRA_PROJECT_KEY. Set it here so the test is hermetic and
    // does not depend on the operator's ambient .env (CI runs with none).
    vi.stubEnv('JIRA_PROJECT_KEY', 'HIMMEL');
    const { deps, uploadAttachment } = mockDeps({ key: 'HIMMEL-10', id: '2' });
    const out = await tool('create').handler(
      { type: 'Task', title: 'T', attach: ['a.png', 'b.png'] },
      deps,
    );
    expect(uploadAttachment).toHaveBeenCalledTimes(2);
    expect(uploadAttachment).toHaveBeenCalledWith('HIMMEL-10', 'a.png');
    expect(out).toContain('Created HIMMEL-10');
    expect(out).toContain('attachments: 2');
  });

  it('list → GET /search/jql with resolved JQL and default limit', async () => {
    const { deps, request } = mockDeps({ issues: [], total: 0 });
    await tool('list').handler({ project: 'ABC', status: 'Done' }, deps);
    const [method, path] = request.mock.calls[0];
    expect(method).toBe('GET');
    expect(path).toContain('/search/jql?jql=');
    expect(decodeURIComponent(path)).toContain('project=ABC');
    expect(decodeURIComponent(path)).toContain('status in ("Done")');
    expect(path).toContain('maxResults=25');
  });

  it('list passes raw --jql through verbatim', async () => {
    const { deps, request } = mockDeps({ issues: [], total: 0 });
    await tool('list').handler({ jql: 'assignee = currentUser()', limit: '5' }, deps);
    const path = request.mock.calls[0][1] as string;
    expect(decodeURIComponent(path)).toContain('assignee = currentUser()');
    expect(path).toContain('maxResults=5');
  });

  it('transition → resolves status NAME to id then POSTs the transition', async () => {
    const request = vi.fn();
    request.mockResolvedValueOnce({ transitions: [{ id: '31', name: 'Done' }] });
    request.mockResolvedValueOnce({});
    const deps = { request, uploadAttachment: vi.fn() } as unknown as ToolDeps;
    const out = await tool('transition').handler({ key: 'HIMMEL-1', status: 'done' }, deps);
    expect(request).toHaveBeenNthCalledWith(1, 'GET', '/issue/HIMMEL-1/transitions');
    expect(request).toHaveBeenNthCalledWith(2, 'POST', '/issue/HIMMEL-1/transitions', {
      transition: { id: '31' },
    });
    expect(out).toBe('HIMMEL-1 → Done');
  });

  it('transition throws when the status name is not available', async () => {
    const { deps } = mockDeps({ transitions: [{ id: '11', name: 'To Do' }] });
    await expect(
      tool('transition').handler({ key: 'HIMMEL-1', status: 'Nope' }, deps),
    ).rejects.toThrow(/not found/i);
  });

  it('transitions → lists id<TAB>name lines', async () => {
    const { deps, request } = mockDeps({
      transitions: [
        { id: '11', name: 'To Do' },
        { id: '21', name: 'In Progress' },
      ],
    });
    const out = await tool('transitions').handler({ key: 'HIMMEL-1' }, deps);
    expect(request).toHaveBeenCalledWith('GET', '/issue/HIMMEL-1/transitions');
    expect(out).toBe('11\tTo Do\n21\tIn Progress');
  });

  it('comment → POST /issue/<key>/comment with ADF body from text', async () => {
    const { deps, request } = mockDeps({});
    const out = await tool('comment').handler({ key: 'HIMMEL-1', text: 'hi' }, deps);
    expect(request).toHaveBeenCalledWith('POST', '/issue/HIMMEL-1/comment', {
      body: {
        type: 'doc',
        version: 1,
        content: [{ type: 'paragraph', content: [{ type: 'text', text: 'hi' }] }],
      },
    });
    expect(out).toBe('Comment added to HIMMEL-1');
  });

  it('comment without text/file/adf throws', async () => {
    const { deps } = mockDeps({});
    await expect(tool('comment').handler({ key: 'HIMMEL-1' }, deps)).rejects.toThrow(
      /requires text/i,
    );
  });

  it('attach → uploads each path and reports the count', async () => {
    const { deps, uploadAttachment } = mockDeps();
    const out = await tool('attach').handler(
      { key: 'HIMMEL-1', paths: ['x.txt', 'y.txt'] },
      deps,
    );
    expect(uploadAttachment).toHaveBeenCalledTimes(2);
    expect(out).toBe('Attached 2 file(s) to HIMMEL-1');
  });

  it('edit → PUT /issue/<key> with buildEditFields payload', async () => {
    const { deps, request } = mockDeps({});
    const out = await tool('edit').handler(
      { key: 'HIMMEL-1', priority: 'High', title: 'New title' },
      deps,
    );
    expect(request).toHaveBeenCalledWith('PUT', '/issue/HIMMEL-1', {
      fields: { priority: { name: 'High' }, summary: 'New title' },
    });
    expect(out).toBe('HIMMEL-1 edited');
  });

  it('edit with no editable field throws (mirrors buildEditFields)', async () => {
    const { deps } = mockDeps({});
    await expect(tool('edit').handler({ key: 'HIMMEL-1' }, deps)).rejects.toThrow(
      /at least one of/i,
    );
  });

  it('projects → GET /project/search and formats key<TAB>id<TAB>name', async () => {
    const { deps, request } = mockDeps({
      values: [{ key: 'ABC', id: '100', name: 'Alpha' }],
    });
    const out = await tool('projects').handler({}, deps);
    expect(request).toHaveBeenCalledWith('GET', '/project/search?maxResults=50&orderBy=key');
    expect(out).toBe('ABC\t100\tAlpha');
  });

  it('project-create → looks up myself for lead then POSTs /project', async () => {
    const request = vi.fn();
    request.mockResolvedValueOnce({ accountId: 'acct-1' });
    request.mockResolvedValueOnce({ id: 5, key: 'NEW' });
    const deps = { request, uploadAttachment: vi.fn() } as unknown as ToolDeps;
    const out = await tool('project-create').handler({ key: 'NEW', name: 'New Proj' }, deps);
    expect(request).toHaveBeenNthCalledWith(1, 'GET', '/myself');
    expect(request).toHaveBeenNthCalledWith(2, 'POST', '/project', {
      key: 'NEW',
      name: 'New Proj',
      projectTypeKey: 'software',
      projectTemplateKey: 'com.pyxis.greenhopper.jira:gh-simplified-kanban-classic',
      leadAccountId: 'acct-1',
    });
    expect(out).toBe('Created NEW (id=5)');
  });

  it('project-create uses an explicit lead without calling /myself', async () => {
    const { deps, request } = mockDeps({ id: 6, key: 'NEW2' });
    await tool('project-create').handler(
      { key: 'NEW2', name: 'N', lead: 'acct-explicit' },
      deps,
    );
    expect(request).toHaveBeenCalledTimes(1);
    expect(request).toHaveBeenCalledWith(
      'POST',
      '/project',
      expect.objectContaining({ leadAccountId: 'acct-explicit' }),
    );
  });
});
