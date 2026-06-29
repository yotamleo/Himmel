/**
 * Google Health API dataType → luna-vitals series mapping table.
 * Ground truth: scripts/luna-vitals/connectors/SCHEMA.md (HIMMEL-609).
 *
 * aggregate semantics:
 *   none     — already one value per day (daily aggregates from Fitbit/Samsung)
 *   sum      — sum all same-day points (steps, distance, energy, …)
 *   mean     — mean of same-day points (HRV samples, SpO2 samples)
 *   last     — last reading of the day (weight, height, body-fat)
 *   duration — compute value = (interval end − start) in the declared unit; sum per day
 *   derive   — custom per-metric computation (rhr_bpm = 5th percentile of raw HR samples)
 */

export type Mapping = {
  dataTypeId: string;
  metric: string;
  category: 'daily' | 'sample' | 'interval';
  /** Dot path into the metric object. '' when there is no single scalar path (duration/derive/array). */
  valuePath: string;
  unit: string;
  aggregate: 'none' | 'sum' | 'mean' | 'last' | 'duration' | 'derive';
  /** API fetch method. Omit (= default list) unless the type requires dailyRollUp. */
  method?: 'list' | 'dailyRollUp';
  note?: string;
};

export const MAPPINGS: Mapping[] = [
  // ── Daily aggregates ────────────────────────────────────────────────────────
  // One value per civil date; date extracted from <field>.date {year,month,day}.
  {
    dataTypeId: 'daily-resting-heart-rate',
    metric: 'daily_rhr_bpm',
    category: 'daily',
    valuePath: 'beatsPerMinute',
    unit: 'bpm',
    aggregate: 'none',
    note: 'Fitbit historical daily RHR; beatsPerMinute is a string. Stopped 2024-09 — use rhr_bpm (heart-rate derive) for live data.',
  },
  {
    dataTypeId: 'daily-heart-rate-variability',
    metric: 'daily_hrv_ms',
    category: 'daily',
    valuePath: 'averageHeartRateVariabilityMilliseconds',
    unit: 'ms',
    aggregate: 'none',
    note: 'Historical daily HRV RMSSD aggregate from Fitbit. Use hrv_ms (heart-rate-variability samples) for live data.',
  },
  {
    dataTypeId: 'daily-oxygen-saturation',
    metric: 'daily_spo2_pct',
    category: 'daily',
    valuePath: 'averagePercentage',
    unit: '%',
    aggregate: 'none',
    note: 'Daily SpO2 average (Samsung live feed).',
  },
  {
    dataTypeId: 'daily-respiratory-rate',
    metric: 'respiratory_rate',
    category: 'daily',
    valuePath: 'breathsPerMinute',
    unit: 'br/min',
    aggregate: 'none',
    note: 'Historical daily breathing rate from Fitbit.',
  },
  {
    dataTypeId: 'daily-sleep-temperature-derivations',
    metric: 'sleep_temp_c',
    category: 'daily',
    valuePath: 'nightlyTemperatureCelsius',
    unit: '°C',
    aggregate: 'none',
    note: 'Nightly skin temperature deviation (historical, Fitbit).',
  },

  // ── Sample points ────────────────────────────────────────────────────────────
  // Point-in-time; date from <field>.sampleTime.civilTime.date.
  {
    dataTypeId: 'heart-rate',
    metric: 'rhr_bpm',
    category: 'sample',
    valuePath: '',
    unit: 'bpm',
    aggregate: 'derive',
    note: 'Per-day 5th-percentile of raw HR samples → resting heart rate estimate. beatsPerMinute is a string. Replaces daily-resting-heart-rate for live Samsung feed (Fitbit aggregate stopped 2024-09).',
  },
  {
    dataTypeId: 'heart-rate-variability',
    metric: 'hrv_ms',
    category: 'sample',
    valuePath: 'rootMeanSquareOfSuccessiveDifferencesMilliseconds',
    unit: 'ms',
    aggregate: 'mean',
    note: 'RMSSD HRV from individual samples; mean per day.',
  },
  {
    dataTypeId: 'oxygen-saturation',
    metric: 'spo2_pct',
    category: 'sample',
    valuePath: 'percentage',
    unit: '%',
    aggregate: 'mean',
    note: 'Per-sample SpO2; mean per day.',
  },
  {
    dataTypeId: 'weight',
    metric: 'weight_kg',
    category: 'sample',
    valuePath: 'weightGrams',
    unit: 'kg',
    aggregate: 'last',
    note: 'weightGrams → /1000 for kg. Last reading per day.',
  },
  {
    dataTypeId: 'height',
    metric: 'height_cm',
    category: 'sample',
    valuePath: 'heightMillimeters',
    unit: 'cm',
    aggregate: 'last',
    note: 'heightMillimeters (string) → /10 for cm. Rare updates.',
  },
  {
    dataTypeId: 'body-fat',
    metric: 'body_fat_pct',
    category: 'sample',
    valuePath: 'percentage',
    unit: '%',
    aggregate: 'last',
    note: 'Body fat percentage; last reading per day. Historical/sparse.',
  },

  // ── Interval spans ───────────────────────────────────────────────────────────
  // Date from <field>.interval.civilEndTime.date; fallback: compute from endTime+endUtcOffset.
  {
    dataTypeId: 'steps',
    metric: 'steps',
    category: 'interval',
    valuePath: 'count',
    unit: 'steps',
    aggregate: 'sum',
    note: 'count is a string (provisional field name — verify against live API before production). Sum sub-daily intervals per day.',
  },
  {
    dataTypeId: 'distance',
    metric: 'distance_km',
    category: 'interval',
    valuePath: 'millimeters',
    unit: 'km',
    aggregate: 'sum',
    note: 'millimeters (string) → /1e6 for km. Sum sub-daily intervals.',
  },
  {
    dataTypeId: 'active-energy-burned',
    metric: 'active_energy_kcal',
    category: 'interval',
    valuePath: 'kcal',
    unit: 'kcal',
    aggregate: 'sum',
    note: 'Active energy burned; sum sub-daily intervals.',
  },
  {
    dataTypeId: 'active-minutes',
    metric: 'active_minutes',
    category: 'interval',
    valuePath: '',
    unit: 'min',
    aggregate: 'sum',
    note: 'activeMinutesByActivityLevel[] — sum each element\'s activeMinutes (strings), then sum elements per day. No single scalar path.',
  },
  {
    dataTypeId: 'active-zone-minutes',
    metric: 'active_zone_minutes',
    category: 'interval',
    valuePath: 'activeZoneMinutes',
    unit: 'min',
    aggregate: 'sum',
    note: 'Per-zone interval points; activeZoneMinutes is a string. Sum all zones per day.',
  },
  {
    dataTypeId: 'sedentary-period',
    metric: 'sedentary_minutes',
    category: 'interval',
    valuePath: '',
    unit: 'min',
    aggregate: 'duration',
    note: 'Value = interval (end − start) in minutes; sum all sedentary intervals per day. No scalar field — duration computed from timestamps.',
  },
  {
    dataTypeId: 'altitude',
    metric: 'altitude_gain_km',
    category: 'interval',
    valuePath: 'gainMillimeters',
    unit: 'km',
    aggregate: 'sum',
    note: 'gainMillimeters (string) → /1e6 for km. Elevation gain; sum per day.',
  },
  {
    dataTypeId: 'swim-lengths-data',
    metric: 'swim_strokes',
    category: 'interval',
    valuePath: 'strokeCount',
    unit: 'strokes',
    aggregate: 'sum',
    note: 'strokeCount (string). Rare / sport-specific data type.',
  },
  {
    dataTypeId: 'exercise',
    metric: 'exercise_minutes',
    category: 'interval',
    valuePath: '',
    unit: 'min',
    aggregate: 'duration',
    note: 'Value = interval (end − start) in minutes. Also contains exerciseType and metricsSummary; only duration is emitted here.',
  },
  {
    dataTypeId: 'hydration-log',
    metric: 'hydration_ml',
    category: 'interval',
    valuePath: 'amountConsumed.milliliters',
    unit: 'ml',
    aggregate: 'sum',
    note: 'Dot path into nested amountConsumed object.',
  },
  // sleep → two entries (in-bed duration + asleep duration)
  {
    dataTypeId: 'sleep',
    metric: 'sleep_hours',
    category: 'interval',
    valuePath: '',
    unit: 'hours',
    aggregate: 'duration',
    note: 'Total time-in-bed: main-session (longest) interval (end − start) per local date. Two entries for sleep dataTypeId; see also sleep_asleep_hours.',
  },
  {
    dataTypeId: 'sleep',
    metric: 'sleep_asleep_hours',
    category: 'interval',
    valuePath: '',
    unit: 'hours',
    aggregate: 'duration',
    note: 'Total asleep time: sum of non-AWAKE stage durations in the main sleep session. Second entry for sleep dataTypeId.',
  },

  // ── Rollup-only (dailyRollUp method; shape TBD) ──────────────────────────────
  // list endpoint returns HTTP 400 for these — must use the dailyRollUp fetch method.
  // Scaffolded here so the connector knows to route them; do not wire until shape confirmed.
  {
    dataTypeId: 'calories-in-heart-rate-zone',
    metric: 'calories_in_hr_zone_kcal',
    category: 'daily',
    valuePath: '',
    unit: 'kcal',
    aggregate: 'none',
    method: 'dailyRollUp',
    note: 'rollup shape TBD — confirm before enabling',
  },
  {
    dataTypeId: 'floors',
    metric: 'floors',
    category: 'daily',
    valuePath: '',
    unit: 'floors',
    aggregate: 'none',
    method: 'dailyRollUp',
    note: 'rollup shape TBD — confirm before enabling',
  },
  {
    dataTypeId: 'total-calories',
    metric: 'total_calories_kcal',
    category: 'daily',
    valuePath: '',
    unit: 'kcal',
    aggregate: 'none',
    method: 'dailyRollUp',
    note: 'rollup shape TBD — confirm before enabling',
  },
];

/** Types excluded from the series mapping. */
export const EXCLUDED: { dataTypeId: string; reason: string }[] = [
  // Categorical / non-numeric
  {
    dataTypeId: 'activity-level',
    reason: 'Categorical enum (activityLevelType) — not a numeric series.',
  },
  {
    dataTypeId: 'time-in-heart-rate-zone',
    reason: 'Categorical zone enum — not a numeric series.',
  },
  {
    dataTypeId: 'daily-heart-rate-zones',
    reason: 'Zone configuration data with sentinel date 9998 — configuration, not a vitals measurement.',
  },
  {
    dataTypeId: 'electrocardiogram',
    reason: 'Waveform samples array (bulky); beatsPerMinuteAvg often 0 — excluded, not a scalar series.',
  },
  {
    dataTypeId: 'food',
    reason: 'Food database definitions, not measurements.',
  },
  {
    dataTypeId: 'food-measurement-unit',
    reason: 'Food unit definitions, not measurements.',
  },
  {
    dataTypeId: 'nutrition-log',
    reason: 'Multi-nutrient array (nutrients[]); complex shape — deferred to a followup connector.',
  },
  // No data returned from the API
  {
    dataTypeId: 'blood-glucose',
    reason: 'No data returned from API.',
  },
  {
    dataTypeId: 'core-body-temperature',
    reason: 'No data returned from API.',
  },
  {
    dataTypeId: 'daily-vo2-max',
    reason: 'No data returned from API.',
  },
  {
    dataTypeId: 'run-vo2-max',
    reason: 'No data returned from API.',
  },
  {
    dataTypeId: 'vo2-max',
    reason: 'No data returned from API.',
  },
  {
    dataTypeId: 'irregular-rhythm-notification',
    reason: 'No data returned from API.',
  },
];
