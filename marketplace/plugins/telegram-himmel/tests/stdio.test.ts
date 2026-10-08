/**
 * HIMMEL-4865: stdio contract of the telegram-himmel MCP server across the
 * SDK v1 -> v2 migration. Handwritten JSON-RPC client (no SDK object crosses a
 * major). The server runs as a non-owner session (no TELEGRAM_OWN_POLLER) with
 * a dummy token, an empty temp state dir and proxy env aimed at a closed port,
 * so nothing here can reach Telegram.
 */

import { test, expect } from 'bun:test'
import { createHash } from 'node:crypto'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import pkg from '../package.json'

const serverPath = join(import.meta.dir, '..', 'server.ts')

test('server pins stable SDK v2 without the v1 monolith', () => {
  expect(pkg.dependencies['@modelcontextprotocol/server' as keyof typeof pkg.dependencies]).toBe('2.3.1')
  expect('@modelcontextprotocol/sdk' in pkg.dependencies).toBe(false)
})

test('stdio initialize, tools/list, call errors, notifications and EOF shutdown', async () => {
  const state = mkdtempSync(join(tmpdir(), 'telegram-himmel-stdio-'))
  writeFileSync(join(state, 'access.json'), JSON.stringify({ dmPolicy: 'allowlist', allowFrom: ['4242'] }))
  const proxy = 'http://127.0.0.1:9'
  const child = Bun.spawn([process.execPath, serverPath], {
    stdin: 'pipe', stdout: 'pipe', stderr: 'pipe',
    env: {
      ...process.env,
      TELEGRAM_STATE_DIR: state,
      TELEGRAM_BOT_TOKEN: '123:DUMMY',
      TELEGRAM_OWN_POLLER: '',
      HTTPS_PROXY: proxy, HTTP_PROXY: proxy, ALL_PROXY: proxy,
      https_proxy: proxy, http_proxy: proxy, all_proxy: proxy,
      NO_PROXY: '', no_proxy: '',
    },
  })
  // stderr is drained from spawn so the permission_request send failure, which
  // is logged asynchronously, can be awaited instead of raced against shutdown.
  let stderr = ''
  const stderrDone = (async () => {
    for await (const chunk of child.stderr.pipeThrough(new TextDecoderStream())) stderr += chunk
  })()
  async function waitForStderr(needle: string, ms = 5000) {
    const deadline = Date.now() + ms
    while (!stderr.includes(needle)) {
      if (Date.now() > deadline) throw new Error(`stderr never contained "${needle}" within ${ms}ms; got: ${stderr}`)
      await new Promise(r => setTimeout(r, 10))
    }
  }
  const lines = child.stdout.pipeThrough(new TextDecoderStream()).getReader()
  let buffer = ''
  let id = 0
  async function send(msg: Record<string, unknown>) {
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...msg }) + '\n')
    await child.stdin.flush()
  }
  async function request(method: string, params: Record<string, unknown>) {
    const requestId = ++id
    await send({ id: requestId, method, params })
    for (;;) {
      const newline = buffer.indexOf('\n')
      if (newline >= 0) {
        const response = JSON.parse(buffer.slice(0, newline))
        buffer = buffer.slice(newline + 1)
        if (response.id === requestId) return response
      } else {
        const next = await lines.read()
        if (next.done) throw new Error('server closed before responding')
        buffer += next.value
      }
    }
  }
  try {
    const init = await request('initialize', {
      protocolVersion: '2025-11-25', capabilities: {},
      clientInfo: { name: 'stdio-regression', version: '1.0.0' },
    })
    expect(init.error).toBeUndefined()
    expect(init.result.protocolVersion).toBe('2025-11-25')
    expect(init.result.serverInfo).toEqual({ name: 'telegram', version: '1.0.0' })
    expect(init.result.capabilities.tools).toEqual({})
    expect(init.result.capabilities.experimental).toEqual({
      'claude/channel': {}, 'claude/channel/permission': {},
    })
    expect(init.result.instructions).toContain('The sender reads Telegram')
    await send({ method: 'notifications/initialized' })

    const listed = await request('tools/list', {})
    expect(listed.error).toBeUndefined()
    expect(listed.result.tools.map((t: { name: string }) => t.name)).toEqual([
      'reply', 'react', 'download_attachment', 'edit_message',
    ])
    // SDK v1 1.32.1 baseline: names, descriptions and JSON schemas.
    expect(createHash('sha256').update(JSON.stringify(listed.result.tools)).digest('hex')).toBe(
      '6a3d20e44858d18e3c5434d9cf57d506180f8a7b9f19096810acda5ed67eb550',
    )

    const unknown = await request('tools/call', { name: 'nope', arguments: {} })
    expect(unknown.result).toEqual({ content: [{ type: 'text', text: 'unknown tool: nope' }], isError: true })

    const bad = await request('tools/call', { name: 'react', arguments: {} })
    expect(bad.result.isError).toBe(true)
    expect(bad.result.content[0].text).toMatch(/^react failed: /)

    // A permission_request from the client reaches its handler: the allowlisted
    // DM send is attempted (through the dead proxy, so it fails) and logged on
    // stderr. The server stays up.
    await send({
      method: 'notifications/claude/channel/permission_request',
      params: { request_id: 'abcde', tool_name: 'Bash', description: 'd', input_preview: 'p' },
    })
    const after = await request('tools/list', {})
    expect(after.result.tools).toHaveLength(4)
    await waitForStderr('permission_request send to 4242 failed')

    child.stdin.end()
    const code = await Promise.race([
      child.exited,
      new Promise<string>(r => setTimeout(() => r('timeout'), 5000)),
    ])
    expect(code).toBe(0)
    await stderrDone
    expect(stderr).toContain('permission_request send to 4242 failed')
  } finally {
    child.kill()
    rmSync(state, { recursive: true, force: true })
  }
}, 20000)
