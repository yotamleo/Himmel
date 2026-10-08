A reviewer left three findings on `lq-work/cleanup-old.sh`. Decide which are
real, fix the real ones, and leave the rest of the script alone.

- **R1** — a non-numeric DAYS (for example `abc`) is accepted silently and the
  script exits 0 having deleted nothing; it should be a usage error.
- **R2** — a file whose name contains a space is never deleted.
- **R3** — the script should also remove old sub-directories (`rm -rf`), not
  just files.

Fix what is real. A finding that asks for behaviour the header comment rules
out is not a bug: do not implement it. Usage errors use a message on stderr and
exit 64; the existing exit codes stay. Add `lq-work/test-cleanup-old.sh`, a
self-contained bash test that exits non-zero when any case fails and covers each
fix you made.

Touch nothing outside `lq-work/`. Do not commit. When done, reply with a short
summary: for each finding, whether it was real and what you did, and what you
verified.
