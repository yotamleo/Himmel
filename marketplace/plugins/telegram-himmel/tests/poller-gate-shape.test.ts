/**
 * The fork's whole reason to exist: only a TELEGRAM_OWN_POLLER=1 session may
 * touch the single getUpdates slot. An upstream re-sync re-bases server.ts on
 * upstream's copy and re-applies the three `[telegram-himmel fork]` edits by
 * hand (README § Upstream-watch protocol) — dropping one silently restores
 * upstream's ungated poller, and every claude session starts stealing the slot
 * from the running bridge again.
 *
 * test-telegram-poller-gate.sh proves the *behaviour* by booting the server,
 * but it needs bun + installed deps and skips without them. This is the cheap
 * always-runnable companion: it asserts the three edits are still in the source.
 */

import { describe, test, expect } from 'bun:test'

const serverPath = new URL(import.meta.resolve('../server.ts')).pathname.replace(/^\/([A-Za-z]:)/, '$1')
const src = await Bun.file(serverPath).text()

describe('telegram-himmel fork — TELEGRAM_OWN_POLLER gate survives an upstream re-sync', () => {
  test('edit 1: OWN_POLLER is derived from the env var', () => {
    expect(src).toMatch(/const OWN_POLLER = process\.env\.TELEGRAM_OWN_POLLER === '1'/)
  })

  test('edit 2: the stale-kill and the bot.pid write are owner-only', () => {
    // The gate must OPEN before the try{} that reads bot.pid, and the write
    // must sit inside it — a non-owner that writes bot.pid steals the slot.
    const gated = src.match(/if \(OWN_POLLER\) \{[\s\S]*?\n\}/)
    expect(gated).not.toBeNull()
    expect(gated![0]).toMatch(/readFileSync\(PID_FILE/)
    expect(gated![0]).toMatch(/writeFileSync\(PID_FILE, String\(process\.pid\)\)/)
  })

  test('edit 3: bot.start() is unreachable for a non-owner', () => {
    expect(src).toMatch(/if \(!OWN_POLLER\) \{[\s\S]*?poller disabled[\s\S]*?\} else void \(async \(\) => \{/)
  })

  test('no ungated top-level poller IIFE remains', () => {
    // Upstream's shape is a bare `void (async () => {` at column 0. Ours is
    // only ever reached through the `} else` above, so a bare one means the
    // gate was lost in a re-sync.
    expect(src).not.toMatch(/^void \(async \(\) => \{/m)
  })

  test('bot.pid is never written outside the gate', () => {
    const writes = src.match(/writeFileSync\(PID_FILE/g) ?? []
    expect(writes.length).toBe(1)
  })

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
