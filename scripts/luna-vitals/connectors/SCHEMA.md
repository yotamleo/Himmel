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
| sleep | sleep | (interval; stages[]) | hours | main session | emit sleep_hours (in-bed) + sleep_asleep_hours (Σ non-AWAKE) |

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
