/**
 * The fork's whole reason to exist: only a TELEGRAM_OWN_POLLER=1 session may
 * touch the single getUpdates slot. An upstream re-sync re-bases server.ts on
 * upstream's copy and re-applies the four `[telegram-himmel fork]` edits by
 * hand (README § Upstream-watch protocol) — dropping one silently restores
 * upstream's ungated poller, and every claude session starts stealing the slot
 * from the running bridge again.
 *
 * tests/test-telegram-poller-gate.sh already behaviourally proves the
 * bot.pid half of the gate (owner writes+removes bot.pid on shutdown, a
 * non-owner never writes it, a second owner reaps a stale one — HIMMEL-1858)
 * by booting the server and reading its state dir. It does NOT prove the
 * other half: that an owner actually reaches `bot.start()` and a non-owner
 * never does. A mutation that guts the owner's `await bot.start(...)` call
 * (e.g. wraps it in `if (false)`) leaves both that suite AND this file's
 * former source-shape assertions green — bot.pid still gets written and
 * removed on schedule, and every asserted regex still matches — while the
 * poller never actually starts (verified: `bash
 * marketplace/plugins/telegram-himmel/tests/test-telegram-poller-gate.sh`
 * still PASSes under that mutation). The describe block below closes that
 * gap: it boots the server for real, points its proxy env at a TCP canary
 * instead of a closed port, and asserts an owner session actually attempts
 * an outbound call while a non-owner does not — behaviour, not source shape.
 *
 * The Windows `ps`-fallback case stays source-inspection: this suite only
 * ever runs on Linux CI, so a real `ps` that throws (MSYS-only) can't be
 * reproduced behaviourally here — the shape check is the cheapest guard
 * that still exists for it.
 */

import { describe, test, expect } from 'bun:test'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { dirname, join } from 'path'

const serverPath = new URL(import.meta.resolve('../server.ts')).pathname.replace(/^\/([A-Za-z]:)/, '$1')
const serverDir = dirname(serverPath)
const src = await Bun.file(serverPath).text()

describe('telegram-himmel fork — TELEGRAM_OWN_POLLER gate survives an upstream re-sync', () => {
  test('an unusable ps still kills the stale poller (Windows)', () => {
    // Upstream 0.0.7 gates the SIGTERM on execFileSync('ps', …) inside one
    // broad try/catch. `ps` THROWS on Windows (verified: it throws even for the
    // caller's own live pid), so that shape skips the kill while bot.pid is
    // still overwritten — a live stale poller plus a new one, i.e. the 409
    // storm the OWN_POLLER gate exists to prevent. The kill must therefore
    // default to ON and be suppressed only by a ps that actually ran.
    expect(src).toMatch(/let looksLikeServer = true/)
    // The ps call carries its own try/catch, so a throw cannot skip the kill.
    const region = src.match(/let looksLikeServer = true[\s\S]*?if \(looksLikeServer\) \{/)
    expect(region).not.toBeNull()
    expect(region![0]).toMatch(/try \{[\s\S]*execFileSync\('ps'[\s\S]*\} catch \{\}/)
    // …and the only assignment from ps is inside that try.
    expect(region![0]).toMatch(/looksLikeServer = cmd\.includes\('server\.ts'\)/)
  })
})

describe('telegram-himmel fork — OWN_POLLER actually gates bot.start(), not just bot.pid', () => {
  async function runPollAttempt(ownPoller: string): Promise<{ attempted: boolean; disabledMessage: boolean }> {
    // A TCP canary in place of a closed port: any inbound connection proves
    // the server actually tried to reach out through the proxy, i.e. that
    // bot.start() (or its onStart getMe/setMyCommands calls) really ran —
    // not just that source text matches the expected shape.
    let hits = 0
    const canary = Bun.listen({
      hostname: '127.0.0.1',
      port: 0,
      socket: {
        open(socket) { hits++; socket.end() },
        data() {},
        close() {},
        drain() {},
        error() {},
      },
    })
    const proxy = `http://127.0.0.1:${canary.port}`
    const tmp = mkdtempSync(join(tmpdir(), 'poller-gate-poll-'))
    const proc = Bun.spawn(['bun', serverPath], {
      cwd: serverDir,
      env: {
        ...process.env,
        TELEGRAM_STATE_DIR: tmp,
        TELEGRAM_BOT_TOKEN: '123:DUMMY',
        TELEGRAM_OWN_POLLER: ownPoller,
        HTTPS_PROXY: proxy, HTTP_PROXY: proxy, ALL_PROXY: proxy,
        https_proxy: proxy, http_proxy: proxy, all_proxy: proxy,
        NO_PROXY: '', no_proxy: '',
      },
      // Held open so the stdin-EOF shutdown path doesn't fire before the
      // sampling window closes (that path belongs to test-telegram-poller-gate.sh).
      stdin: 'pipe',
      stdout: 'ignore',
      stderr: 'pipe',
    })
    let stderr = ''
    const drain = (async () => {
      const reader = proc.stderr.getReader()
      const decoder = new TextDecoder()
      try {
        for (;;) {
          const { done, value } = await reader.read()
          if (done) break
          stderr += decoder.decode(value)
        }
      } catch {}
    })()
    await Bun.sleep(2000)
    proc.kill('SIGKILL')
    await Promise.race([proc.exited, Bun.sleep(3000)])
    await Promise.race([drain, Bun.sleep(500)])
    canary.stop()
    rmSync(tmp, { recursive: true, force: true })
    return { attempted: hits > 0, disabledMessage: stderr.includes('poller disabled') }
  }

  test('owner (TELEGRAM_OWN_POLLER=1) actually attempts to reach Telegram', async () => {
    const { attempted, disabledMessage } = await runPollAttempt('1')
    expect(disabledMessage).toBe(false)
    expect(attempted).toBe(true)
  }, 10000)

  test('non-owner never attempts to reach Telegram', async () => {
    const { attempted, disabledMessage } = await runPollAttempt('')
    expect(disabledMessage).toBe(true)
    expect(attempted).toBe(false)
  }, 10000)
})
