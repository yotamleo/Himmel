import type { Command } from 'commander';
import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';

// HIMMEL-3890: resolution is not on the edit screen, so PUT /issue cannot set
// it. The roadmap workflow owns it instead: every transition's post-function
// sets it from the target status (Done/Closed/In Public -> Done, wont do/wont
// fix -> Won't Do, anything else -> cleared). Re-running the current status's
// self-transition therefore sets or clears the resolution to match the status.

type Req = typeof request;

interface IssueState {
  fields: { status: { id: string; name: string }; resolution: { name: string } | null };
}

const read = (req: Req, key: string) => req<IssueState>('GET', `/issue/${key}?fields=status,resolution`);

export async function syncResolution(key: string, req: Req = request): Promise<string> {
  const before = (await read(req, key)).fields;
  const status = before.status.name;
  const { transitions } = await req<{ transitions: Array<{ id: string; name: string; to?: { id: string } }> }>(
    'GET',
    `/issue/${key}/transitions`,
  );
  // Matched by destination status id: a transition's name need not be its target's name.
  const self = transitions.find((t) => t.to?.id === before.status.id);
  if (!self) throw new Error(`${key}: no self-transition for status "${status}" (not on the roadmap workflow?)`);
  await req('POST', `/issue/${key}/transitions`, { transition: { id: self.id } });
  const after = (await read(req, key)).fields;
  if (after.status.id !== before.status.id) {
    throw new Error(`${key}: status changed from "${status}" to "${after.status.name}" during the resolution sync`);
  }
  const name = (s: IssueState['fields']) => s.resolution?.name ?? '(none)';
  return `${key} ${status}: resolution ${name(before)} -> ${name(after)}`;
}

export function registerResolution(program: Command): void {
  program
    .command('resolution <key>')
    .description("Set or clear an issue's resolution to match its status (self-transition; workflow post-function)")
    .action(async (key: string) => {
      console.log(await syncResolution(key));
      writeJiraBreadcrumb(key);
    });
}
