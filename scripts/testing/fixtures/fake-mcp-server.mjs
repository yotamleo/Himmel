// Fake stdio MCP server for the credential-free startup suite (HIMMEL-4410).
// Zero-dep JSON-RPC over newline-delimited stdio: answers initialize, tools/list
// and tools/call, so a Claude session can connect it without qmd or a network.
// FAKE_MCP_MODE=broken exits before answering, the RED control for the harness.
import { createInterface } from 'node:readline';

if (process.env.FAKE_MCP_MODE === 'broken') process.exit(3);

const send = (msg) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...msg }) + '\n');
const TOOL = {
  name: 'fake_echo',
  description: 'Echo the input back (startup-suite fixture).',
  inputSchema: { type: 'object', properties: { text: { type: 'string' } } },
};

createInterface({ input: process.stdin }).on('line', (line) => {
  let m;
  try { m = JSON.parse(line); } catch { return; }
  if (m.id === undefined) return; // notification
  if (m.method === 'initialize') {
    send({ id: m.id, result: { protocolVersion: m.params?.protocolVersion ?? '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: 'fake-mcp', version: '0.0.1' } } });
  } else if (m.method === 'tools/list') {
    send({ id: m.id, result: { tools: [TOOL] } });
  } else if (m.method === 'tools/call') {
    send({ id: m.id, result: { content: [{ type: 'text', text: String(m.params?.arguments?.text ?? '') }] } });
  } else {
    send({ id: m.id, error: { code: -32601, message: 'method not found' } });
  }
});
