# luna-vitals connectors — Google Health API (HIMMEL-609, alpha)

Opt-in connector that pulls wearable vitals from the **Google Health API**
(`health.googleapis.com/v4`, the Fitbit-Web-API successor) into the luna-vitals
series pipeline (`50-Vitals/` → luna-correlate). **Inert until configured** — it
does nothing without `GOOGLE_HEALTH_*` set in `.env` and a cadence armed.

**Setup / config:** [`docs/luna/google-health-connector-setup.md`](../../../docs/luna/google-health-connector-setup.md).

## Layout
- `map/table.ts` — `MAPPINGS`: which API dataType → which series (the source of truth for coverage).
- `map/shape.ts` — per-dataPoint extraction (daily / sample / interval date + value, unit/string coercion).
- `map/derive.ts` — day aggregation + derived `rhr_bpm` (raw-HR percentile) + `sleep_hours`/`sleep_asleep_hours`.
- `auth/oauth.ts` — refresh→access token, `auth-url`/`exchange`, `RECONSENT_EXIT=75`.
- `fetch/dataType.ts` — paged list (+ gated `dailyRollUp`) + client-side date filter.
- `google-health.ts` — CLI: `pull` / `auth-url` / `auth-exchange`.
- `pull-cadence.{sh,ps1}` — scheduled-pull wrapper (stops at the review artifact).
- `SCHEMA.md` — verified per-type payload shapes + mapping + tiebreaks.
- `__fixtures__/` — synthetic, PHI-free test fixtures.

## Status
Alpha. Single-operator Testing-mode OAuth (refresh token ~7-day expiry → re-consent
reminder via exit 75). The 3 rollup-only types and `nutrition-log`/ECG/food are
scaffolded-or-excluded (see `SCHEMA.md`). Vitals are PHI — keep tokens in `.env`
only; the connector never prints secrets.
