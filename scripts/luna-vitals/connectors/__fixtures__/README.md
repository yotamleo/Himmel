# Google Health API connector fixtures

Synthetic, scrubbed fixtures for hermetic connector tests. **No real PHI** — all timestamps,
values, and identifiers are synthetic. User references are replaced with `REDACTED`.

## Purpose

These files simulate the real Google Health Connect API list-response envelope:

```json
{ "dataPoints": [ ... ], "nextPageToken": "" }
```

They are recorded-response fixtures — shape-faithful to the actual API but with
synthetic numeric values — so connector tests run offline without network access.

## Payload categories

### Daily aggregates (date-keyed, no sampleTime)

Fields keyed by `date: { year, month, day }`. Suitable for direct calendar-date
lookups without time-zone arithmetic on the consumer side.

| File | Key field |
|------|-----------|
| `daily-resting-heart-rate.json` | `dailyRestingHeartRate` |
| `daily-heart-rate-variability.json` | `dailyHeartRateVariability` |
| `daily-oxygen-saturation.json` | `dailyOxygenSaturation` |

Note: `beatsPerMinute` in `daily-resting-heart-rate.json` and `nonRemHeartRateBeatsPerMinute`
in `daily-heart-rate-variability.json` are **strings**, not numbers — this matches the live API.

### Sample points (timestamped, point-in-time)

Fields keyed by `sampleTime: { physicalTime, utcOffset, civilTime }`. Consumer code
must handle UTC-offset math when grouping by local date.

| File | Key field | Notable fields |
|------|-----------|----------------|
| `heart-rate.json` | `heartRate` | `beatsPerMinute` is a string |
| `heart-rate-variability.json` | `heartRateVariability` | `rootMeanSquareOfSuccessiveDifferencesMilliseconds` is a number |
| `oxygen-saturation.json` | `oxygenSaturation` | `percentage` is a number |
| `weight.json` | `weight` | `weightGrams` is a number |
| `height.json` | `height` | `heightMillimeters` is a **string** |

### Interval spans (start/end timestamps)

Fields keyed by `interval: { startTime, startUtcOffset, endTime, endUtcOffset }`.
Used for activities and sleep sessions. Consumer code selects the "main" session
(longest, or by type) when multiple intervals overlap the same local date.

| File | Key field | Notes |
|------|-----------|-------|
| `sleep.json` | `sleep` | 3 points: main night, nap, cross-midnight session |
| `steps.json` | `steps` | `count` field is a string |
| `exercise.json` | `exercise` | minimal shape — no sub-fields beyond `interval` |

### Sleep fixture details (`sleep.json`)

Three data points covering selection-logic edge cases:

1. **Main night (2026-06-28)** — type `STAGES`, 8.5 h window (01:24–09:55 UTC),
   includes AWAKE (~20 min), LIGHT, DEEP, and REM stages. Time-in-bed > time-asleep
   by the AWAKE segment.
2. **Nap (2026-06-28)** — type `STAGES`, 40 min (14:00–14:40 UTC), LIGHT only.
3. **Cross-midnight session** — start 2026-06-26T22:30 UTC, end 2026-06-27T05:30 UTC,
   `endUtcOffset "7200s"` → local end date is 2026-06-27. Tests that a session is
   attributed to its local *end* date (or whichever convention the consumer adopts).

## Provisional field names

**`steps.json` — `count` field is provisional.** The exact field name for step counts
in the Google Health Connect API response was not confirmed against a live response at
fixture-authoring time. The field is named `"count"` (string) here; verify against a
live API response before relying on this name in production adapter code.
