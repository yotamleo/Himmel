import type { Command } from 'commander';
import { confluenceV1, confluenceV2 } from '../../client.js';

export function searchPath(cql: string, limit: number): string {
  return `/search?cql=${encodeURIComponent(cql)}&limit=${limit}`;
}

export function registerSearch(program: Command): void {
  program.command('search')
    .description('Search Confluence with CQL')
    .requiredOption('--cql <cql>', 'CQL query, e.g. \'type=page AND text~"foo"\'')
    .option('--limit <n>', 'Max results', '25')
    .action(async (opts: { cql: string; limit: string }) => {
      const r = await confluenceV1<{ results: Array<{ content?: { id: string; title: string; type: string } }> }>(
        'GET', searchPath(opts.cql, Number(opts.limit)));
      for (const hit of r.results ?? []) {
        if (hit.content) console.log(`${hit.content.id}\t${hit.content.type}\t${hit.content.title}`);
      }
    });
  program.command('spaces')
    .description('List Confluence spaces')
    .option('--limit <n>', 'Max results', '25')
    .action(async (opts: { limit: string }) => {
      const r = await confluenceV2<{ results: Array<{ id: string; key: string; name: string }> }>(
        'GET', `/spaces?limit=${Number(opts.limit)}`);
      for (const s of r.results ?? []) console.log(`${s.id}\t${s.key}\t${s.name}`);
    });
}
