# luna-correlate

Offline health-factor correlation MCP (M0 library + M1 MCP + M2 location factors).
Boundary B+C: only `factors.cache` touches the network (gated+logged); all joins are
offline. Kp is global + date-only; location factors (pressure/pollen/aq) fetch a
country-level **grid** — **no PHI, and never the operator's coordinates**. The
operator's date×place stays local and meets the factor cache only inside the offline
proximity index. Outputs are **candidate signals only — never a diagnosis, never
causation**.

## MCP tools

The plugin ships a bun + TypeScript stdio MCP server (`server.ts`) wrapping the M0
library. Mirrors the `telegram-himmel` packaging (`.mcp.json` →
`bun run --cwd ${CLAUDE_PLUGIN_ROOT} ... start`).

| Tool | Network | What it does |
|---|---|---|
| `factors.cache({factor, region?, dateRange?})` | **yes** (gated) | Bulk-fetch a public factor dataset into the local cache (the ONLY network path). `factor:"kp"` = the global, date-only GFZ Kp archive. `factor:"pressure"\|"pollen"\|"aq"` = a country-level GRID over `region` (`LUNA_REGION_BBOX`) for `dateRange` from Open-Meteo — no PHI, **no operator coordinates**. |
| `series.load({name, dir?})` | no | Load a local health/status series by name as generic `(date,value)` points from `<dir or LUNA_SERIES_DIR>/<name>.csv` (explicit `dir` wins). |
| `correlate({series, factor?, lag?, dir?, location?})` | no | Offline join of a named series against the cached factor at an optional day lag → a candidate `Signal`. For location factors, resolves the operator's local `date,lat,lon` (`location` / `LUNA_LOCATION_FILE`) to the nearest cached grid cell first. |
| `signals.report({series, factor?, lag?, dir?, location?, outPath?})` | no | Run a correlation and render the candidate-signal vault note (markdown with caveats + never-diagnose disclaimer); writes to `outPath` when given. |

Series live wherever `LUNA_SERIES_DIR` points (e.g. the luna-medic `50-Vitals/` dir).
`series.load`/`correlate`/`signals.report` accept any series name — `migraine`, `pain`,
`sleep`, `stress`, … — as long as the matching `<name>.csv` exists.

### Factors

- `kp` — global geomagnetic Kp index (date-only, no location). High/low split at Kp≥5.
- `pressure` — barometric pressure, **daily-min** (exposes the front-passage pressure
  drop, a prime migraine trigger). Location factor.
- `pollen` / `aq` — grass pollen / PM2.5, **daily-mean**. Location factors (shorter
  history via the air-quality API).

Continuous location factors have no universal high/low cutoff, so their event-rate split
uses the **median** of the joined values (a generic rule, no per-factor magic number);
Pearson correlation is reported alongside. Kp keeps its geomagnetic-storm cutoff (≥5).

## Kp data source

**Source:** GFZ Potsdam Kp index — `https://kp.gfz.de/app/files/Kp_ap_Ap_SN_F107_since_1932.txt`
- Operator: Helmholtz Centre Potsdam GFZ (public research institute)
- Licence: CC BY 4.0 — free to download and use with attribution
- Auth: none required
- PHI: zero — global geomagnetic activity index, date-only joins
- No location data transmitted — the request is a plain file download

**Rubric verdict (docs/tool-adoption/rubric.md):** ADOPT.
- Goal/KPI: date-only offline correlation (✓ fits Boundary B+C)
- Trust posture: public institution + CC BY 4.0 (✓)
- Data safety: no PHI, no location in request or response (✓)
- Availability: stable archive URL since 1932 coverage (✓)

## Location data source (M2)

**Source:** Open-Meteo — free public weather/air-quality APIs, no API key.
- Pressure (history): Archive API `https://archive-api.open-meteo.com/v1/archive`
  (`hourly=pressure_msl`, hPa).
- Pollen / air-quality: Air-Quality API `https://air-quality-api.open-meteo.com/v1/air-quality`
  (`hourly=pm2_5,grass_pollen`; shorter history than the archive).
- Licence: CC BY 4.0 — free with attribution. Auth: none.
- **No operator coordinates transmitted.** Each request carries only a grid corner the
  fetcher computed from the region bbox (`LUNA_REGION_BBOX`) — never a point derived from the
  operator's location. (Open-Meteo independently snaps a request to its own grid-cell center,
  observed e.g. 52.5→52.478; the privacy guarantee does not depend on that — it rests on the
  fetcher only ever sending bbox grid corners.)
- **Coverage:** the pressure Archive API has long history; the pollen/air-quality API serves
  only a recent rolling window, so historical `dateRange`s fail loud for `pollen`/`aq`.

**Rubric verdict (docs/tool-adoption/rubric.md):** PILOT (PILOT-MEASURE).
- Goal/KPI: first location factor under Boundary B+C — country-grid fetch, offline proximity
  join, zero coordinate leak (✓ the M2 boundary test).
- Trust posture: open public API, CC BY 4.0 (✓), but a **new** external dependency not yet
  proven across a real workload → pilot behind the opt-in `LUNA_REGION_BBOX` config, not ADOPT.
- Data safety: request reveals only country-level extent; operator location never sent (✓).
- Exit: promote to ADOPT (or REJECT) once a real region/date-range cache + correlation run is
  measured.

## File format

The real GFZ archive has 40 `#` header lines, then whitespace-separated fixed-width
rows with the date split across separate `YYYY MM DD` columns (0-indexed):
```
0:YYYY 1:MM 2:DD 3:days 4:days_m 5:Bsr 6:dB 7..14:Kp1..Kp8 15..22:ap1..ap8 23:Ap 24:SN 25:F10.7obs 26:F10.7adj 27:D
```
Missing Kp is the `-1.000` sentinel. Daily-max Kp = `max(valid Kp1..Kp8)`. Example row:
```
2024 06 14 33768 33768.5 2603  1  0.333  0.667  2.000  1.667  1.000  0.667  1.667  2.333    2 ...
```

`parseKpGfz` parses this real format; `parseKpAuto` auto-detects it vs the simplified
`kp-sample.txt` fixture format (`YYYY-MM-DD kp1 kp2 kp3`, parsed by `parseKpText`,
retained for tests). The live fetcher (`fetchKp.ts` / `factors.cache`) routes through
`parseKpAuto`, so a live fetch produces correct ISO dates.

## Usage

### Via MCP

```jsonc
// Kp (global, date-only)
factors.cache({ "factor": "kp" })                         // one-time, gated fetch
correlate({ "series": "migraine", "lag": 1 })             // offline join (LUNA_SERIES_DIR/migraine.csv)
signals.report({ "series": "pain", "lag": 0, "outPath": "…/signals.md" })

// Location factor (barometric pressure) — country-grid fetch, offline proximity join
factors.cache({ "factor": "pressure", "region": "47,5,55,15",
                "dateRange": { "start": "2024-01-01", "end": "2024-12-31" } })
correlate({ "series": "migraine", "factor": "pressure", "lag": 1,
            "location": "…/places.csv" })                 // places.csv = local date,lat,lon (never egressed)
```

### Manual CLI run

```sh
# 1. Fetch and cache the Kp archive (one-time, no PHI sent) — real GFZ format
bun run src/fetchKp.ts

# 2. Prepare your series CSV (date,value — synthetic/your own data, stays local)
#    See tests/fixtures/migraine-fixture.csv for the expected format.

# 3. Run the correlator (fully offline)
bun run src/cli.ts correlate path/to/your-series.csv 1
```

Output is JSON on stdout (or markdown from `signals.report`): a `Signal` with rates,
correlation, caveats, and a `belowMinN` flag. **Candidate signals only — correlation
does not imply causation.**
