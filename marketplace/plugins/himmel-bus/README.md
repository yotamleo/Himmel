# himmel-bus store

Private, chained local message storage (plan T2). The store currently imports
`../../../../scripts/telegram/bus.ts` and requires Linux `flock` and Node 24+;
standalone marketplace-cache packaging is owned by HIMMEL-4830.

## Delivery and recovery

`append(root, name, record)` stamps the chain. `read(root, name)` returns
`{ records, next, cursors, notice? }` without committing delivery. Emit records
before `commit(root, name, next)`. Commit **empty batches too**: `next` can move
past a completed archive with no new records. A read visits at most one segment;
repeat read/emit/commit while `pending(root, name)` is true. Per-record `cursors`
remain available for partial delivery. Records are at-least-once, not exactly-once.

Delivery commits validate cursor shape and reject stale or halted cursors.
An empty, malformed JSON or invalid-shaped persisted cursor wakes the reader;
`read` persists a fail-closed halt and returns one explicit `notice` explaining
that recovery will replay from the beginning. Subsequent reads return no records
and no repeated notice; `pending` is false. The consuming delivery hook must log
or forward `notice` (the primitive does not print to stdout).

After investigating/repairing the cause, call `unhalt(root, name)` explicitly.
It clears only the halt flag under the same lock, preserving a valid committed
position. For an unreadable cursor, that position is the beginning, so recovery
can replay already-delivered records: consumers must deduplicate. Unhalt does not
approve corrupted log bytes; the next read verifies the chain and halts again
if the damage remains. Ordinary delivery commits cannot clear a halt.

Native EACCES, EPERM, EIO, EMFILE, ENFILE and access-policy errors propagate
without persisting a tamper halt. Fix the filesystem cause and retry; these
failures do not imply the chain was altered.

## Archive costs and ceilings

`pending` lists segment names and checks metadata, never reading/decompressing
archive contents. `read` loads only the cursor's segment (comparing duplicate
plain/compressed copies left by interrupted rotation). `append` loads at most
the latest archive, and only when it needs a predecessor for an empty live log.
Already-consumed archive contents are not re-audited on every poll.

A segment rotates at 256 KiB; one final record can take it beyond that threshold.
The live file and selected archive are still read whole, so the batch byte budget
is one segment, not a hard per-record/byte limit. Directory enumeration remains
linear in the number of retained segments, and history is not pruned. A retained
segment index/pruning policy belongs with the later consumer lifecycle work;
this change does not claim constant-time polling or a decompression-bomb limit.

Cursor publication is atomic for process crashes, not fsynced for power loss.
No bridge, transport, registration or CLI wiring is installed by this package.

## Tests

`npm test` runs `tests/test-store.mjs`. The existing `node-suites` GitHub Actions
matrix includes `himmel-bus` with Node 24; other matrix packages keep Node 22.
