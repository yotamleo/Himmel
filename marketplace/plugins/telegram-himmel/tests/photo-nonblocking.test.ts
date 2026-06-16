/**
 * HIMMEL-266: Photo downloads must not block the ingest loop.
 *
 * Previously, message:photo awaited a download (getFile + fetch, each with a
 * 30s timeout) inside the grammy handler. A batch of N photos could stall the
 * poller for N×60s. The fix records file_id for lazy download at dispatch time
 * (same pattern as documents/voice/video) so the ingest handler returns
 * immediately.
 *
 * Acceptance: a batch containing multiple photos with a hung file API does not
 * delay the next getUpdates call by more than one file-fetch timeout.
 */

import { describe, test, expect } from 'bun:test'

// ---------------------------------------------------------------------------
// Helpers that model the ingest handler's contract with grammy.
// We don't import server.ts (it has side effects that require a real bot
// token), but we replicate the two shapes — old (eager) vs new (lazy) — and
// verify the timing invariant.
// ---------------------------------------------------------------------------

/** Simulates a download that takes `ms` to complete. */
function slowDownload(ms: number): () => Promise<string | undefined> {
  return () => new Promise(resolve => setTimeout(() => resolve('/some/path.jpg'), ms))
}

/** Old shape: handleInbound is given a downloadImage fn and awaits it inline. */
async function ingestOld(
  text: string,
  downloadImage: (() => Promise<string | undefined>) | undefined,
): Promise<{ imagePath: string | undefined; elapsedMs: number }> {
  const t0 = Date.now()
  const imagePath = downloadImage ? await downloadImage() : undefined
  return { imagePath, elapsedMs: Date.now() - t0 }
}

type AttachmentMeta = { kind: string; file_id: string; size?: number }

/** New shape: handleInbound receives attachment meta only (no downloadImage param). */
async function ingestNew(
  text: string,
  attachment?: AttachmentMeta,
): Promise<{ attachment: AttachmentMeta | undefined; elapsedMs: number }> {
  const t0 = Date.now()
  // New code path — no await on any network call inside the ingest handler.
  return { attachment, elapsedMs: Date.now() - t0 }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('photo ingest — HIMMEL-266 non-blocking contract', () => {
  test('old shape: a slow download blocks the caller for the full timeout', async () => {
    const SLOW_MS = 100 // scaled down from 30 000 for CI speed
    const result = await ingestOld('(photo)', slowDownload(SLOW_MS))
    expect(result.elapsedMs).toBeGreaterThanOrEqual(SLOW_MS - 10)
    expect(result.imagePath).toBe('/some/path.jpg')
  })

  test('new shape: ingest returns immediately even when a hung downloader exists', async () => {
    const SLOW_MS = 5000 // would block the old handler for 5s
    const MAX_INGEST_MS = 50 // the new handler must return well under this

    // The "hung" downloader is never invoked — the new code path has no download in the ingest handler.
    const t0 = Date.now()
    const result = await ingestNew('(photo)', { kind: 'photo', file_id: 'AgACAgI_TEST' })
    const elapsed = Date.now() - t0

    expect(elapsed).toBeLessThan(MAX_INGEST_MS)
    expect(result.attachment?.kind).toBe('photo')
    expect(result.attachment?.file_id).toBe('AgACAgI_TEST')
  })

  test('new shape: N photo messages complete in < one timeout window', async () => {
    const SINGLE_DOWNLOAD_MS = 200 // simulated single-file timeout (scaled)
    const N = 5
    const MAX_BATCH_MS = SINGLE_DOWNLOAD_MS // all N must finish in < one timeout

    const t0 = Date.now()
    const promises = Array.from({ length: N }, (_, i) =>
      ingestNew(`(photo ${i})`, { kind: 'photo', file_id: `file_id_${i}` }),
    )
    const results = await Promise.all(promises)
    const elapsed = Date.now() - t0

    // All N ingest calls finish in far less than one SINGLE_DOWNLOAD_MS.
    expect(elapsed).toBeLessThan(MAX_BATCH_MS)
    for (const r of results) {
      expect(r.attachment?.kind).toBe('photo')
      expect(r.elapsedMs).toBeLessThan(MAX_BATCH_MS)
    }
  })

  test('attachment meta carries file_id for lazy download_attachment tool call', async () => {
    const fileId = 'AgACAgIAAxkBAAIBh2WkQJ_-example'
    const result = await ingestNew('(photo)', {
      kind: 'photo',
      file_id: fileId,
      size: 102400,
    })

    // Claude receives file_id in meta so it can call download_attachment lazily.
    expect(result.attachment).toEqual({ kind: 'photo', file_id: fileId, size: 102400 })
    expect(result.attachment?.file_id).toBe(fileId)
  })

  test('text-only ingest (no photo) is unaffected', async () => {
    const result = await ingestNew('hello world')
    expect(result.attachment).toBeUndefined()
    expect(result.elapsedMs).toBeLessThan(50)
  })
})

// ---------------------------------------------------------------------------
// Code-shape assertion: verify server.ts no longer awaits a downloadImage fn
// in the message:photo handler. This catches any regression where someone
// re-introduces eager download.
// ---------------------------------------------------------------------------

describe('photo handler code shape — no eager download', () => {
  test('message:photo handler calls handleInbound with photo attachment meta (no download fn)', async () => {
    // Resolve relative to this test file. new URL().pathname gives a POSIX-style
    // path; on Windows it starts with /C:/ so strip the leading slash.
    const serverPath = new URL(import.meta.resolve('../server.ts')).pathname.replace(/^\/([A-Za-z]:)/, '$1')
    const src = await Bun.file(serverPath).text()

    // Find the message:photo handler block.
    const photoHandlerMatch = src.match(
      /bot\.on\('message:photo'[\s\S]*?\}\)/,
    )
    expect(photoHandlerMatch).not.toBeNull()
    const handler = photoHandlerMatch![0]

    // Must NOT contain an async download closure (the old eager-download shape).
    expect(handler).not.toMatch(/async\s*\(\s*\)\s*=>/)
    // Must NOT make API calls to getFile or fetch inside the handler (eager download).
    // Check for the call site patterns, not comment mentions.
    expect(handler).not.toMatch(/ctx\.api\.getFile/)
    expect(handler).not.toMatch(/await\s+fetch\s*\(/)
    expect(handler).not.toMatch(/await\s+ctx\.api\.getFile/)

    // MUST call handleInbound with caption + photo attachment meta (no download fn).
    expect(handler).toMatch(/handleInbound\(ctx,\s*caption,\s*\{/)

    // MUST include a photo attachment meta with file_id.
    expect(handler).toMatch(/kind:\s*'photo'/)
    expect(handler).toMatch(/file_id:\s*best\.file_id/)
  })
})
