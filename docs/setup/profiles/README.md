# Install profiles

HIMMEL-2307. This directory holds committed **v2 install-profile** files
(`schemaVersion: 2` — see `scripts/install/capture-operator-profile.mjs`'s
header comment for the exact shape). Filename suffix `.install-profile.json`
is load-bearing: a CI glob elsewhere (the HIMMEL-2308 schema-validation leg)
matches it across this directory.

## `operator.install-profile.json`

A live capture of the operator's own reference machine — the most-loaded
himmel install that exists, used as the "does the wizard cover everything a
real setup needs" reference. Every path in it is a placeholder token
(`<LUNA_VAULT_PATH>`, `<HANDOVER_DIR>`, ...), never a real personal path.

Regenerate it with:

```bash
node scripts/install/capture-operator-profile.mjs --profile-out docs/setup/profiles/operator.install-profile.json
```

Run the command from the operator's **normal shell** — the capture reads live
environment variables (`CLAUDE_CONFIG_DIR`, `HIMMEL_OBSERVABILITY_CONFIG`,
`WHISPER_DIR`/`WHISPER_MODEL`, `HANDOVER_DIR`, `LUNA_VAULT_PATH`). A bare or
sterile shell captures defaults and will drift against the staleness gate
(`scripts/install/test-operator-profile-staleness.sh`), which loads the same
keys from the primary checkout's `.env` file.

Then commit the result. The capture is read-only (no arm/disarm, no writes
to `~/.claude`, no scheduled-task mutation) and deterministic — two
consecutive runs on an unchanged machine produce a byte-identical file.

## Status: the v2 loader reads it; the paths are still placeholders

Two separate things, previously conflated here.

**The schema is live.** This file is authored against the v2 profile schema
(`schemaVersion: 2`), and `scripts/himmelctl/bin.js`'s `loadProfile` reads
that schema on main today: it branches on `obj.schemaVersion === 2` and
validates the `profile` enum (`starter|luna|operator|custom`) plus a boolean
`devOverlay`, instead of the v1 `role` field this file does not carry. The
older note here — that `loadProfile` was still the v1 loader and would reject
this file for a missing `role` — is no longer true. A profile with no
`schemaVersion` is still read as an implicit v1 (legacy) cache and validated
against the old role-based shape; any other `schemaVersion` value fails loud
rather than being reinterpreted.

HIMMEL-2348 dropped `tier` from what the wizard writes — it was a hardcoded
`'standard'` placeholder no reader ever consumed. `loadProfile` never
enumerated it (it validates a named allowlist and ignores unknown keys), so a
profile captured before this change and still carrying `tier` remains valid
input.

**The committed file is still not runnable input as-is.** Every path in it is
a placeholder token (`<LUNA_VAULT_PATH>`, `<HANDOVER_DIR>`, `<WHISPER_CLI>`)
written by the capture's scrub pass, and **nothing expands those tokens** —
there is no substitution step in `bin.js` between `loadProfile` and the plan.
They are non-empty strings, so they pass validation and would then be used
verbatim as filesystem paths. So

```bash
himmelctl install --from-profile docs/setup/profiles/operator.install-profile.json
```

loads and validates, but does not describe a real machine. To replay it,
substitute real paths for the placeholder tokens first; to replay your OWN
machine, use the profile the wizard cached for you rather than this one.

This file's job is to be a reference artifact: proof that the v2 schema
captures a real, fully-loaded install, and the fixture the schema-validation
CI check runs against.

## Staleness gate

`scripts/install/test-operator-profile-staleness.sh` re-captures the
operator's machine and `--check`s it against
`operator.install-profile.json`, failing CI with a field-level diff if the
committed file has drifted from the live machine. It self-skips everywhere
except the operator's own machine (gated on `HIMMEL_OPERATOR_MACHINE=1` in
that machine's `.env`). On drift, the fix is always the same: re-run the
regenerate command above and commit.

This directory's schema validity (not staleness) is a separate CI check
owned by the HIMMEL-2308 leg — this suite does not duplicate it.
