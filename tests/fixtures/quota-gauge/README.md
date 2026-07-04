# WS9 quota-gauge fixtures — atomicity gate provenance (AC0/T0)

`atomicity-probe.sh` is the BLOCKING first gate of the WS9 cross-lane
quota-gauge ledger (HIMMEL-654). The single-file ledger design (spec D2
primary) rests SOLELY on atomic single-line `O_APPEND`: the GLM lane has
multiple concurrent producers (a 3+ worker spawn-glm fleet), so a torn
write would corrupt the reader. POSIX guarantees atomicity for a single
write < `PIPE_BUF` (4096); Windows Git Bash — the GLM fleet's platform —
is UNVERIFIED by POSIX, so the gate is run for real before any ledger
code lands.

## GO/NO-GO verdict

```
platform=windows/gitbash
runs=5
verdict=PASS
```

All 5 runs printed `PASS` (rc 0): 8 concurrent writers x 500 lines =
4000 lines, every line whole (exactly one `"seq":` per line, each
matching the expected byte pattern), 0 malformed/interleaved lines, no
loss, no merge.

## Decision

**PASS -> the single-file ledger design (D2 primary) stands.** Tasks 1-7
build as written: ONE append-only `$HOME/.himmel/quota-gauge.jsonl`, a
single reader `tail`-scanning one path with a lane-aware look-back bound.
The per-lane-file fallback (`quota-gauge.<lane>.jsonl`, D2's
rejected-but-ready alt) is NOT switched on; the reader does NOT need to
fan out across per-lane files, and `QUOTA_GAUGE_LOOKBACK_N` keeps its
single-file meaning (T18 cross-lane eviction + T26 absent-lane bound stay
as spec'd).
