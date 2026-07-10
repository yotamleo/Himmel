# Google Health API — verified payload schema (HIMMEL-609 ground truth, 2026-06-29)

Captured from the operator's real account. Drives `map/table.ts` + adapters.
Three categories by date source; values often JSON **strings** → coerce.

## Date extraction
- **daily**: `<field>.date {year,month,day}` (civil, user TZ).
- **sample**: `<field>.sampleTime.civilTime.date {year,month,day}`.
- **interval**: prefer `<field>.interval.civilEndTime.date`; fallback compute from
  `interval.endTime` + `interval.endUtcOffset`. (Sleep may lack civilEndTime → fallback.)

## Per-type mapping (dataTypeId → field, value path, unit, aggregate)
`aggregate` = how to collapse multiple same-day points into one series value.

| dataTypeId | field | value path | unit | aggregate | notes |
|---|---|---|---|---|---|
| daily-resting-heart-rate | dailyRestingHeartRate | beatsPerMinute (STRING) | bpm | none | Fitbit, historical |
| daily-heart-rate-variability | dailyHeartRateVariability | averageHeartRateVariabilityMilliseconds | ms (RMSSD) | none | historical |
| daily-oxygen-saturation | dailyOxygenSaturation | averagePercentage | % | none | live (Samsung) |
| daily-respiratory-rate | dailyRespiratoryRate | breathsPerMinute | br/min | none | historical |
| daily-sleep-temperature-derivations | dailySleepTemperatureDerivations | nightlyTemperatureCelsius | °C | none | historical |
| heart-rate | heartRate | beatsPerMinute (STRING) | bpm | (derive rhr: daily min/5th-pctile) | live; raw samples, many/day |
| heart-rate-variability | heartRateVariability | rootMeanSquareOfSuccessiveDifferencesMilliseconds | ms | mean | historical |
| oxygen-saturation | oxygenSaturation | percentage | % | mean | live |
| weight | weight | weightGrams → /1000 | kg | last | sample |
| height | height | heightMillimeters (STRING) → /10 | cm | last | sample, rare |
| body-fat | bodyFat | percentage | % | last | sample, old |
| steps | steps | count (STRING) | steps | sum | sub-daily interval; civilEndTime present |
| distance | distance | millimeters (STRING) → /1e6 | km | sum | sub-daily |
| active-energy-burned | activeEnergyBurned | kcal | kcal | sum | sub-daily |
| active-minutes | activeMinutes | activeMinutesByActivityLevel[].activeMinutes (STRINGs) | min | sum (sum the array, then sum/day) | nested array |
| active-zone-minutes | activeZoneMinutes | activeZoneMinutes (STRING) | min | sum | per-zone points |
| sedentary-period | sedentaryPeriod | (interval end−start) | min | sum | value = duration |
| altitude | altitude | gainMillimeters (STRING) → /1e6 | km | sum | elevation gain |
| swim-lengths-data | swimLengthsData | strokeCount (STRING) | strokes | sum | rare |
| exercise | exercise | (interval end−start as minutes) | min | sum | also has exerciseType, metricsSummary; emit exercise_minutes |
| hydration-log | hydrationLog | amountConsumed.milliliters | ml | sum | |
| sleep | sleep | (interval; stages[]) | hours | main session | emit sleep_hours (Σ non-AWAKE, only if the rounded value is >0) + sleep_in_bed_hours (in-bed) |

### Migration note (HIMMEL-785)
Prior to HIMMEL-785 the connector emitted `sleep_hours` = time-in-bed (what is now
`sleep_in_bed_hours`). `writeSeries` only overlays emitted rows onto the existing
on-disk CSV, so `sleep_hours.csv` values written by pre-HIMMEL-785 artifacts are
**not** auto-reconciled — any vault that ever landed old connector artifacts verbatim
must one-time repair that series (the operator vault was repaired in salus commit `a1c9456`).

### Degraded stage data (HIMMEL-793)
If any non-AWAKE stage in the main sleep session has an unparseable start/end timestamp
(`Date.parse` → NaN), the session's stage data is treated as DEGRADED for that date:
`sleep_hours` is omitted entirely (the remaining valid stages would under-count sleep),
`sleep_in_bed_hours` is still emitted (derived from the session interval, not the stages),
and a `[google-health]` stderr warning is printed. Invalid AWAKE stages never enter the
asleep sum, so they do not trigger the degraded path.

### Durable warnings field (HIMMEL-794)
The degraded warning above is now ALSO recorded durably in the review artifact's optional
`warnings: string[]` field — absent from the JSON when there are no warnings, written by
`pull` and preserved through `merge` (deduped across inputs). A clean pull keeps producing
a byte-identical artifact to pre-HIMMEL-794; a pull whose sleep payload triggers a
degraded date carries `warnings: ["sleep <date>: malformed stage timestamps - sleep_hours
omitted (degraded stage data)"]`. The stderr line is unchanged — the artifact copy is
additive. A dated warning is recorded on the artifact only when its date falls inside the
pull's `[from, to]` window (matching the rows filter); a warning with no derivable date is
always recorded regardless of window.

Four adjacent paths that previously skipped silently now each produce a warning too
(stderr + artifact); row-emission behavior is unchanged for all four. The three
session-scoped warnings embed the dataPoint index (`sleep dataPoint <i> …`) so two
distinct dropped sessions never share a text — `merge` dedups warnings by exact text,
so identical text must mean the same event:
- A session whose interval is missing `startTime`/`endTime` entirely is still dropped:
  `sleep dataPoint <i> (<date>): missing interval startTime/endTime - session dropped` when
  an end date is still derivable (from `civilEndTime` or `endTime` + `endUtcOffset`),
  undated (`sleep dataPoint <i>: missing interval startTime/endTime - session dropped`)
  otherwise.
- A session with no `civilEndTime` and no `endUtcOffset` (no date derivable) is still
  dropped: `sleep dataPoint <i> ending <endTime>: no civilEndTime and no endUtcOffset - session dropped`.
- An unparseable session interval (`startMs`/`endMs` not finite) is still dropped:
  `sleep dataPoint <i> (<date>): unparseable interval start/end - session dropped` (undated
  `sleep dataPoint <i>: unparseable interval start/end - session dropped` when a garbage
  `endTime` makes the date underivable).
- A non-array `stages` field is still coerced to `[]` (stage-less: `sleep_in_bed_hours`
  emits, `sleep_hours` does not): `sleep <date>: non-array "stages" field - treated as
  stage-less (sleep_hours unavailable)`. The warning refers to the MAIN session for the
  date — a malformed shorter/nap session does not warn, since it never contributes rows.
  An absent `stages` field is the normal classic stage-less case and produces NO warning.

`write` surfaces any artifact `warnings` on stderr as `[luna-vitals] artifact warning:
<text>` before writing series — advisory only, does not block the write. Warnings are
not persisted past the artifact (writeSeries ignores them).

### Known limitations
`writeSeries` only overlays emitted rows onto the existing on-disk CSV — metrics absent
from artifact rows are never rewritten, so a degraded date's previously written
`sleep_hours` value is left untouched (the operator must repair that series manually).
Intentional; noted under HIMMEL-794.

A merged artifact's warnings record DERIVATION-TIME loss, not final-artifact state — a
warned (metric, date) gap may have been filled by the other merge pool, so a warning does
not guarantee the merged rows lack that date.

A sleep dataPoint with no recognizable typed payload field at all is dropped WITHOUT a
warning (deliberate scope-out — HIMMEL-801).

## Derived
- `rhr_bpm` ← heart-rate raw samples: per civil day, take a low estimator
  (documented: 5th percentile of the day's bpm) so the live Samsung HR feed yields
  a resting estimate (the Fitbit daily aggregate stopped 2024-09).

## Categorical / non-numeric → EXCLUDE from series (config, not vitals)
- activity-level (activityLevelType enum), time-in-heart-rate-zone (zone enum),
  daily-heart-rate-zones (zone config, sentinel date 9998).
- electrocardiogram (waveformSamples[] — bulky; beatsPerMinuteAvg often 0).
- food, food-measurement-unit (food DB definitions, not measurements).
- nutrition-log (nutrients[] array — multi-nutrient; defer to a followup, complex).

## No data (skip): blood-glucose, core-body-temperature, daily-vo2-max, run-vo2-max,
## vo2-max, irregular-rhythm-notification.

## Rollup-only (list 400s — use dailyRollUp method; shape TBD): calories-in-heart-rate-zone, floors, total-calories.

## Tiebreaks
- `last` aggregate: when multiple same-date points arrive, the point with the lexicographically-greatest
  `source` string is kept. Note: source sort order is platform-name-dependent and may vary cross-platform
  if platform identifiers differ (e.g. "FITBIT" vs "HEALTH_CONNECT").
- Sleep main-session selection: when two sessions share the same maximum duration, the **first** session
  in API-response order is kept (stable pick, no secondary sort key).
