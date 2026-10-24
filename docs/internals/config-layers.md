# Configuration layers

Every himmel setting has one home and one rule for who wins. This page lists
the homes, who owns each one, whether it is tracked in git, and the order in
which they are read.

## The layers

| Layer | File | Owner | Tracked? | Holds |
|---|---|---|---|---|
| Secrets | `<primary checkout>/.env` | operator | never (gitignored, unreadable to agents) | API tokens, passwords, credentials, and the keys not yet classified (below) |
| Behaviour config | `~/.himmel/himmel.conf` | operator, reviewable | yes on a luna install (a link to `<vault>/.himmel/himmel.conf`); a plain file otherwise | non-secret knobs: `HANDOVER_DIR`, `CR_PROFILE`, `HIMMEL_INITIATIVE`, … |
| Local override | `~/.himmel/himmel.conf.local` | operator, this machine | never | the same keys, for one machine only |
| Gate policy | `~/.himmel/config.json`, under `"policy"` | operator only (a hook refuses agent writes) | no | `CR_REQUIRE_CROSS_MODEL`, `CR_FLOOR_FALLBACK`, `ARMAUTOMERGE` |
| Adopter config | `~/.himmel/config.json`, other fields | `himmelctl install`; `jira.sectorField` by the operator | no | luna cadence, bridge, PHI declarations, the Jira Sector field id (`jira.sectorField`) |
| Install profile | `~/.claude/himmel/install-profile.json` | `himmelctl install` | no | the wizard's answers, replayed by `--from-profile` |
| Handover registry | `~/.claude/handover/registry.json` | `/handover` | no | handover repos, buckets, branch prefixes |
| Plugin and lane profiles | `scripts/machine-setup/` profiles, console-kit `--profile` | himmel repo | yes | which plugins and tools a session loads |
| Chief rules | chief template, worker and judge system prompts, hooks | himmel repo | yes | how chiefs and workers behave |
| Per-chief state | the fleet manifest in the handover bucket | the chief | in the state repo | which workers are live, their docs and tokens |

Status and state are never tracked as configuration: a file that changes
every session (fleet manifest, queue locks, ledgers) is state, not config.

## Who wins

Behaviour keys, read by `load_dotenv` in `scripts/lib/load-dotenv.sh`:

1. the process environment (a non-empty value)
2. `~/.himmel/himmel.conf.local`
3. `~/.himmel/himmel.conf`
4. legacy `.env`, with a `DEPRECATED` notice on stderr
5. the consumer's own default

Gate-policy keys, read by `load_policy` in `scripts/lib/load-dotenv.sh`:

1. `~/.himmel/config.json` `.policy`
2. legacy `.env`, with a `DEPRECATED` notice
3. unset, which every gate treats as its safe default

The process environment is **not** in the policy list. A gate-policy key can
only change by editing a file the operator owns, so
`CR_FLOOR_FALLBACK=claude-only bash scripts/cr/clear-cr-marker.sh` does not
loosen the review gate; `load_policy` drops the value and prints
`ignoring process-env CR_FLOOR_FALLBACK`. A policy key written into
`himmel.conf` or `himmel.conf.local` is ignored too, because no hook guards
agent writes to those files yet.

Secrets are read from `.env` only. A secret key planted in `himmel.conf` is
never loaded.

A policy key exported from a shell profile (for example a sourced
`~/.config/himmel/env`) is process env too, so it is ignored with the same
notice. Move it into `config.json` `.policy`; a behaviour key exported there
still wins, as the list above says.

The directory is always `$HOME/.himmel`. No environment variable moves it
(`HIMMEL_LUNA_CONFIG_PATH`, which `himmelctl` honours for its own fields, is
not consulted for policy).

### Failure behaviour

| Situation | Behaviour keys | Gate-policy keys |
|---|---|---|
| `himmel.conf` missing | fall through to `.env`, then the default | n/a |
| `config.json` missing | n/a | notice; legacy `.env` or the safe default |
| `config.json` not valid JSON | notice; legacy `.env` | `load_policy` returns non-zero; `clear-cr-marker.sh` refuses (exit 14) |
| `.env` present but unreadable | key stays unset | `load_policy` returns non-zero; the gate refuses |

A missing file never turns a gate on its permissive side: unset policy keys
leave the cross-model requirement off, the floor fallback off, and automerge
off, which are today's defaults.

## Which keys go where

Behaviour config (`himmel.conf`): `HANDOVER_DIR`, `USER_SLUG`,
`LUNA_VAULT_PATH`, `HIMMEL_DOC_FRESHNESS`, `HIMMEL_INITIATIVE`,
`HIMMEL_INITIATIVE_OVERNIGHT`, `HIMMEL_OVERNIGHT`, `HIMMEL_WHERE_ARE_WE`,
`HIMMEL_WHERE_ARE_WE_STALE_HOURS`, `HIMMEL_WORKTREE_NUDGE`,
`HIMMEL_UPDATE_AUTOSTASH`, `CR_PROFILE`, `CR_CLAUDE_AGENTS`,
`TICKET_ID_REQUIRED`, `TICKET_ID_PATTERN`, `TICKET_ID_EXEMPT_AUTHORS`,
`TRACKER`. Their meanings and defaults are unchanged; `.env.example`
documents each one.

Gate policy (`config.json` `.policy`): `CR_REQUIRE_CROSS_MODEL`,
`CR_FLOOR_FALLBACK`, `ARMAUTOMERGE`.

Everything else stays in `.env`. That includes keys whose secret-or-config
class has not been decided yet: account emails, chat IDs, cookie-file paths,
service URLs, VM user names and the non-token Jira keys. Until each is
classified with the operator, it is treated as a secret.

The registry is `_himmel_key_class` in `scripts/lib/load-dotenv.sh`. A key
moves from secret to config only by editing that list in a reviewed PR.

`TICKET_ID_REQUIRED` and `TICKET_ID_EXEMPT_AUTHORS` loosen the commit-message
gate when set, so they are candidates for the policy list. They stay
behaviour config until the commit-message hook reads them through
`load_policy`.

## Example files

Tracked templates to copy: `docs/setup/himmel.conf.example` (every behaviour
key, commented out) and `docs/setup/himmel-config.example.json` (the policy
section, every key `null`, which reads as unset). `scripts/lib/test-load-config.sh`
checks that each template names only keys of its own class.

`~/.himmel/himmel.conf` uses the same `KEY=value` form as `.env`. It is
parsed, never executed:

```
HANDOVER_DIR=/home/me/Documents/luna/handovers
CR_PROFILE=free,paid
HIMMEL_INITIATIVE=prcheck,pr,ticket,handover
```

`~/.himmel/config.json`, policy section (other fields belong to `himmelctl`):

```json
{
  "version": 1,
  "policy": {
    "CR_REQUIRE_CROSS_MODEL": "1",
    "CR_FLOOR_FALLBACK": "claude-only"
  }
}
```

`himmelctl install` keeps the `policy` field untouched and names it in one
`WARN` line, as it does for any field outside its own schema.

## Console rules

Prose and hooks stay where they are: the chief template, the worker and judge
system prompts, and the hooks are code, reviewed in the himmel repo. A rule that is
a tunable number or switch moves to `himmel.conf`; per-chief state stays in
the fleet manifest.

Example: the fleet size cap. The rule "a chief never runs more workers than
the cap" stays in the chief template and its enforcing script. The number
itself is a tunable knob, so it belongs in configuration, not prose. Raising
it loosens a safety limit, so its home is the policy section of
`config.json`, not `himmel.conf`; until it joins that list it stays a
guarded process-env variable (`HIMMEL_FLEET_CAP`). Which workers are live right
now is state, so it stays in the fleet manifest.

## Why this route

Two routes were compared.

**Option 1: a tracked file in the luna vault, with a gitignored `.local`
override.** Settings become reviewable and travel with the vault. On its own
it breaks adopters who have no luna vault: there is no tracked place for the
file, and every reader would need to find the vault first.

**Option 2: extend `~/.himmel/config.json`, with env > config > default.**
Works for every install, but the file is untracked, so changes are not
reviewable; and env > config contradicts the requirement that gate policy
cannot be overridden from the environment.

**Chosen: both, split by key class.**

- Behaviour keys use a fixed path, `~/.himmel/himmel.conf`. On a luna install
  it is a link into the vault, so it is tracked and reviewable (option 1's
  benefit). Without luna it is a plain file, so adopters lose nothing (option
  2's reach). Env still wins for these keys, as it always has.
- Gate-policy keys use `~/.himmel/config.json`, which a hook already keeps
  agents from writing, and their reader ignores the environment. This removes
  the env > config conflict for exactly the keys where it matters.
- Nothing that works today stops working: every key still found only in
  `.env` keeps its value until you migrate it.

Policy keys can move into the tracked `himmel.conf` once a hook guards agent
writes to it.

## Migrating an existing install

Setup, adopt and `himmelctl` read and write the behaviour keys in
`~/.himmel/himmel.conf` (a key already set in `.env` is still read as a
fallback), so the migration can run at any time. `--dry-run` lists what would
move without writing.

1. Run `bash scripts/setup/migrate-env-config.sh --dry-run` to list the keys
   it would move. It prints key names only, never values.
2. Run it again without `--dry-run` (add `--vault <luna vault>` on a luna
   install to keep the file in the vault). Behaviour keys are copied into
   `~/.himmel/himmel.conf`; secrets are not touched.
3. For gate-policy keys it prints one command per key. Run each at your own
   prompt: it reads the value from `.env` and writes it into
   `~/.himmel/config.json`, so the value is never shown.
4. Start a session. When no `DEPRECATED` notice appears, delete the moved
   lines from `.env`.

The `.env` fallback for non-secret keys is removed one release after setup,
adopt and `himmelctl` read the new files.

## Not covered yet

A shared multi-user layer (a team's company brain feeding settings to every
member) is out of scope. It is on the backlog; the layer table above leaves
room for it above `himmel.conf`.
