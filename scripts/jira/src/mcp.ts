import { readFileSync } from 'node:fs';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { request, projectKey, uploadAttachment } from './client.js';
import { markdownToAdf } from './adf.js';
import { formatIssue, formatIssueWithDescription } from './output.js';
import { resolveListJql } from './commands/list.js';
import { findTransition } from './commands/transition.js';
import { formatTransitions } from './commands/transitions.js';
import { buildEditFields } from './commands/edit.js';
import { parseLabels } from './commands/labels.js';
import { uploadAll } from './commands/attach-helper.js';
import type {
  JiraIssue,
  JiraSearchResult,
  JiraTransition,
  CreateIssueResponse,
} from './types.js';

/**
 * MCP surface for the himmel jira CLI (HIMMEL-159).
 *
 * Exposes the same ten verbs the Commander CLI registers — get, create,
 * list, transition, transitions, comment, attach, edit, projects,
 * project-create — over the Model Context Protocol on stdio. Each MCP tool
 * routes to the SAME underlying client functions (`request`,
 * `uploadAttachment`, `markdownToAdf`, `buildEditFields`, `resolveListJql`,
 * `findTransition`, …) the CLI verbs call. This module is purely additive:
 * it does not modify any existing verb behaviour, and the per-tool input
 * schemas mirror each verb's Commander `.option()` / argument semantics so
 * validation is identical across the CLI and MCP surfaces.
 *
 * Implementation note: we use the low-level `Server` + raw JSON-Schema
 * `inputSchema` rather than the high-level `McpServer`/Zod surface so the
 * package keeps its single runtime dependency posture (commander + the MCP
 * SDK) without also pulling zod into the schema layer.
 */

/** Dependencies a tool handler needs — injectable so tests can mock them. */
export interface ToolDeps {
  request: typeof request;
  uploadAttachment: typeof uploadAttachment;
}

const defaultDeps: ToolDeps = { request, uploadAttachment };

/** JSON-Schema fragment for a tool's input. */
type JsonSchema = {
  type: 'object';
  properties: Record<string, unknown>;
  required?: string[];
  additionalProperties: false;
};

export interface JiraTool {
  name: string;
  description: string;
  inputSchema: JsonSchema;
  /** Run the verb. Returns the text the CLI would print to stdout. */
  handler: (args: Record<string, unknown>, deps: ToolDeps) => Promise<string>;
}

const str = (description: string) => ({ type: 'string', description });

/**
 * Build the ten tools. The handlers mirror the CLI verbs in
 * `src/commands/*` line-for-line in terms of which client function they call
 * and what payload they build — they just return a string instead of
 * `console.log`-ing it.
 */
export function createTools(): JiraTool[] {
  return [
    {
      name: 'get',
      description: 'Get a Jira issue (with description body by default)',
      inputSchema: {
        type: 'object',
        properties: {
          key: str('Issue key (e.g. HIMMEL-1)'),
          json: { type: 'boolean', description: 'Output raw JSON' },
          short: {
            type: 'boolean',
            description: 'Suppress the description body (one-line header only)',
          },
        },
        required: ['key'],
        additionalProperties: false,
      },
      async handler(args, deps) {
        const key = args.key as string;
        const issue = await deps.request<JiraIssue>(
          'GET',
          `/issue/${key}?fields=summary,status,issuetype,parent,assignee,description`,
        );
        if (args.json) return JSON.stringify(issue, null, 2);
        if (args.short) return formatIssue(issue);
        return formatIssueWithDescription(issue);
      },
    },
    {
      name: 'create',
      description: 'Create a Jira issue',
      inputSchema: {
        type: 'object',
        properties: {
          type: str('Issue type: Epic, Story, Task, Subtask'),
          title: str('Issue summary'),
          desc: str('Description (markdown supported)'),
          descFile: str('Read the markdown description from a file (overrides desc)'),
          adfFile: str('Path to pre-built ADF JSON document (overrides desc)'),
          parent: str('Parent issue key'),
          labels: str('Comma-separated labels to set (e.g. a,b)'),
          project: str('Project key (default: JIRA_PROJECT_KEY env var)'),
          attach: {
            type: 'array',
            items: { type: 'string' },
            description: 'File path(s) to attach',
          },
        },
        required: ['type', 'title'],
        additionalProperties: false,
      },
      async handler(args, deps) {
        const fields: Record<string, unknown> = {
          project: { key: (args.project as string) ?? projectKey() },
          summary: args.title,
          issuetype: { name: args.type },
        };
        if (args.adfFile) {
          fields['description'] = JSON.parse(
            readFileSync(args.adfFile as string, 'utf8'),
          );
        } else if (args.descFile) {
          fields['description'] = markdownToAdf(
            readFileSync(args.descFile as string, 'utf8'),
          );
        } else if (args.desc) {
          fields['description'] = markdownToAdf(args.desc as string);
        }
        if (args.parent) fields['parent'] = { key: args.parent };
        if (args.labels !== undefined) {
          fields['labels'] = parseLabels(args.labels as string);
        }

        const result = await deps.request<CreateIssueResponse>('POST', '/issue', {
          fields,
        });
        let out = `Created ${result.key}`;

        const attachments = (args.attach as string[] | undefined) ?? [];
        if (attachments.length > 0) {
          const n = await uploadAll(result.key, attachments, deps.uploadAttachment);
          out += `\n  attachments: ${n}`;
        }
        return out;
      },
    },
    {
      name: 'list',
      description: 'List Jira issues',
      inputSchema: {
        type: 'object',
        properties: {
          project: str('Project key (default: JIRA_PROJECT_KEY)'),
          type: str('Filter by issue type (Epic, Story, Task, Subtask)'),
          status: str('Comma-separated status filter (default: "To Do,In Progress")'),
          label: str('Filter by a single label (composed into the built JQL)'),
          jql: str('Raw JQL passthrough (overrides project/type/status/label)'),
          limit: str('Max results (default 25)'),
        },
        additionalProperties: false,
      },
      async handler(args, deps) {
        const jql = resolveListJql({
          jql: args.jql as string | undefined,
          project: args.project as string | undefined,
          type: args.type as string | undefined,
          status: args.status as string | undefined,
          label: args.label as string | undefined,
        });
        const limit = (args.limit as string | undefined) ?? '25';
        const result = await deps.request<JiraSearchResult>(
          'GET',
          `/search/jql?jql=${encodeURIComponent(jql)}&fields=summary,status,issuetype&maxResults=${limit}`,
        );
        return result.issues.map((issue) => formatIssue(issue)).join('\n');
      },
    },
    {
      name: 'transition',
      description: 'Transition a Jira issue to a new status',
      inputSchema: {
        type: 'object',
        properties: {
          key: str('Issue key'),
          status: str('Target status NAME (not ID)'),
        },
        required: ['key', 'status'],
        additionalProperties: false,
      },
      async handler(args, deps) {
        const key = args.key as string;
        const status = args.status as string;
        const { transitions } = await deps.request<{ transitions: JiraTransition[] }>(
          'GET',
          `/issue/${key}/transitions`,
        );
        const match = findTransition(transitions, status);
        if (!match) {
          const available = transitions.map((t) => `- ${t.name}`).join('\n');
          throw new Error(`Transition "${status}" not found. Available:\n${available}`);
        }
        await deps.request('POST', `/issue/${key}/transitions`, {
          transition: { id: match.id },
        });
        return `${key} → ${match.name}`;
      },
    },
    {
      name: 'transitions',
      description: 'List available transitions for a Jira issue (id<TAB>name per line)',
      inputSchema: {
        type: 'object',
        properties: { key: str('Issue key') },
        required: ['key'],
        additionalProperties: false,
      },
      async handler(args, deps) {
        const { transitions } = await deps.request<{ transitions: JiraTransition[] }>(
          'GET',
          `/issue/${args.key as string}/transitions`,
        );
        return formatTransitions(transitions);
      },
    },
    {
      name: 'comment',
      description: 'Add a comment to a Jira issue (text supports markdown)',
      inputSchema: {
        type: 'object',
        properties: {
          key: str('Issue key'),
          text: str('Comment body (markdown)'),
          adfFile: str('Path to pre-built ADF JSON document (overrides text)'),
          commentFile: str('Read the markdown comment body from a file (overrides text)'),
          attach: {
            type: 'array',
            items: { type: 'string' },
            description: 'File path(s) to attach to the parent issue',
          },
        },
        required: ['key'],
        additionalProperties: false,
      },
      async handler(args, deps) {
        const key = args.key as string;
        let body: unknown;
        if (args.adfFile) {
          body = JSON.parse(readFileSync(args.adfFile as string, 'utf8'));
        } else {
          const markdown = args.commentFile
            ? readFileSync(args.commentFile as string, 'utf8')
            : (args.text as string | undefined);
          if (markdown === undefined) {
            throw new Error('comment requires text or commentFile or adfFile');
          }
          body = markdownToAdf(markdown);
        }
        await deps.request('POST', `/issue/${key}/comment`, { body });
        let out = `Comment added to ${key}`;

        const attachments = (args.attach as string[] | undefined) ?? [];
        if (attachments.length > 0) {
          const n = await uploadAll(key, attachments, deps.uploadAttachment);
          out += `\n  attachments: ${n}`;
        }
        return out;
      },
    },
    {
      name: 'attach',
      description: 'Upload one or more files as attachments to an existing issue',
      inputSchema: {
        type: 'object',
        properties: {
          key: str('Issue key'),
          paths: {
            type: 'array',
            items: { type: 'string' },
            description: 'File path(s) to upload',
          },
        },
        required: ['key', 'paths'],
        additionalProperties: false,
      },
      async handler(args, deps) {
        const n = await uploadAll(
          args.key as string,
          args.paths as string[],
          deps.uploadAttachment,
        );
        return `Attached ${n} file(s) to ${args.key as string}`;
      },
    },
    {
      name: 'edit',
      description:
        'Edit a Jira issue (priority, severity, title, description, parent, and/or labels)',
      inputSchema: {
        type: 'object',
        properties: {
          key: str('Issue key'),
          priority: str('Priority: Highest|High|Medium|Low|Lowest'),
          severity: str('Severity (custom field): free text'),
          title: str('New summary/title (plain text)'),
          desc: str('New description (markdown; converted to ADF). Alias of description.'),
          description: str('New description (markdown; converted to ADF)'),
          descFile: str('Read the markdown description from a file (overrides desc/description)'),
          parent: str('Parent issue key (e.g. epic) — re-parents the issue'),
          labels: str(
            'REPLACE the issue labels with this comma-separated set (full-replace: ' +
              'existing labels not listed are removed)',
          ),
        },
        required: ['key'],
        additionalProperties: false,
      },
      async handler(args, deps) {
        const key = args.key as string;
        let description = args.description as string | undefined;
        if (args.descFile !== undefined) {
          description = readFileSync(args.descFile as string, 'utf8');
        } else if (args.desc !== undefined && description === undefined) {
          description = args.desc as string;
        }
        const fields = buildEditFields({
          priority: args.priority as string | undefined,
          severity: args.severity as string | undefined,
          title: args.title as string | undefined,
          description,
          parent: args.parent as string | undefined,
          labels: args.labels as string | undefined,
        });
        await deps.request('PUT', `/issue/${key}`, { fields });
        return `${key} edited`;
      },
    },
    {
      name: 'projects',
      description: 'List Jira projects visible to the authenticated user',
      inputSchema: {
        type: 'object',
        properties: { limit: str('Max results (default 50)') },
        additionalProperties: false,
      },
      async handler(args, deps) {
        const limit = (args.limit as string | undefined) ?? '50';
        const result = await deps.request<{
          values: { key: string; id: string; name: string }[];
        }>('GET', `/project/search?maxResults=${limit}&orderBy=key`);
        return result.values.map((p) => `${p.key}\t${p.id}\t${p.name}`).join('\n');
      },
    },
    {
      name: 'project-create',
      description: 'Create a new Jira project (requires admin permissions)',
      inputSchema: {
        type: 'object',
        properties: {
          key: str('Project key (uppercase, 2-10 chars)'),
          name: str('Project display name'),
          type: str('Project type: software, business, service_desk (default software)'),
          template: str('Project template key'),
          lead: str('Lead account ID (defaults to authenticated user)'),
        },
        required: ['key', 'name'],
        additionalProperties: false,
      },
      async handler(args, deps) {
        let leadAccountId = args.lead as string | undefined;
        if (!leadAccountId) {
          const me = await deps.request<{ accountId: string }>('GET', '/myself');
          leadAccountId = me.accountId;
        }
        const result = await deps.request<{ id: number; key: string }>('POST', '/project', {
          key: args.key,
          name: args.name,
          projectTypeKey: (args.type as string | undefined) ?? 'software',
          projectTemplateKey:
            (args.template as string | undefined) ??
            'com.pyxis.greenhopper.jira:gh-simplified-kanban-classic',
          leadAccountId,
        });
        return `Created ${result.key} (id=${result.id})`;
      },
    },
  ];
}

/** Build the MCP server with all ten tools registered. */
export function buildServer(deps: ToolDeps = defaultDeps): Server {
  const tools = createTools();
  const server = new Server(
    { name: 'jira', version: '1.0.0' },
    { capabilities: { tools: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: tools.map((t) => ({
      name: t.name,
      description: t.description,
      inputSchema: t.inputSchema,
    })),
  }));

  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const tool = tools.find((t) => t.name === req.params.name);
    if (!tool) {
      throw new Error(`Unknown tool: ${req.params.name}`);
    }
    try {
      const text = await tool.handler(req.params.arguments ?? {}, deps);
      return { content: [{ type: 'text', text }] };
    } catch (e) {
      return {
        content: [{ type: 'text', text: e instanceof Error ? e.message : String(e) }],
        isError: true,
      };
    }
  });

  return server;
}

/** Boot the MCP server on stdio. Invoked by `jira mcp`. */
export async function runMcpServer(): Promise<void> {
  const server = buildServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
}
