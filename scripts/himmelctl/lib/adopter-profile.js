'use strict';
// scripts/himmelctl/lib/adopter-profile.js — HIMMEL-862 v1 adopter-user
// profile: the lane SUBSET selection + honest probe, and the always-on
// machine-hardening CHECKLIST.
//
// Scope (operator rescope 2026-07-31): v1 is the adopter-user profile,
// LOCAL-only. The himmel + luna-vault components are already installed by
// bin.js's existing adopt.sh derivation — this module adds the two rows the
// T2/T3 answer schema had reserved but never asked (`lanes`, `alwaysOn`),
// plus the final honest summary.
//
// Two deliberate NON-behaviours, both load-bearing:
//
//   1. Lanes are PROBED, never force-activated. `himmelctl config set
//      lanes.<id> on` writes probe.kind=always into the lanes.local.json
//      overlay, which makes a lane report available whether or not its CLI
//      exists. Using that here would let the installer certify a lane it
//      never installed. So a selected-but-absent lane is reported as MANUAL
//      with the exact install command instead. Actually RUNNING those
//      third-party installers is deliberately v2 (see the split-off note in
//      the ticket) — it needs per-OS recipes and manifest items, and every
//      one of them is a machine-wide package-manager mutation.
//
//   2. Machine hardening is PRINTED, never executed (rescope, explicit).
//      Power profile / sshd / auto-logon are machine-wide, need elevation,
//      and are NOT reversible by `himmelctl uninstall` — so v1 emits the
//      docs/setup/windows-clean-machine.md Phase-6 steps as a checklist the
//      operator runs by hand.
//
// Lane probing and hardening remain non-mutating. The one deliberate write is
// HIMMEL-1428's applied-install persistence of the selected lane ids into the
// gitignored lanes.local.json profile allowlist; dry-runs still write nothing.
//
// It is NOT spawn-free, and this comment used to claim it was (corrected in CR
// round 5). Inspecting a machine sometimes means running something: the
// resolver's buildCtx shells out to `git` to locate the main checkout, and the
// manifest-backed readiness probes reached through probesLib may execute a
// tool to ask its version or health. Those are reads. The distinction that
// matters for --dry-run is mutation, not process creation — so the epilogue
// runs there too, and everything it reports is as true before the install as
// after it.

const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');
const probesLib = require('./probes.js');
// RETASK stage1-build-6d2e round 10 [codex-1]: a pure-data read (not
// bin.js's logic) so buildSummary can look up whether an 'unconfigured'
// secret shares its aggregate luna-sources probe with a sibling credential —
// see the secrets-walk loop below for why that matters.
const SECRETS_MANIFEST = require('./secrets-manifest.json');
// HIMMEL-2302: per-cadence wizard registry — see the file's own $comment.
// resolveCadenceDispositions() below lives HERE (not bin.js) so bin.js's
// preview/apply steps AND this file's own buildSummary can never drift on
// what "disposition" means — the exact reason SECRETS_MANIFEST already
// lives in this module instead of bin.js (see the comment just above).
const CADENCE_REGISTRY = require('./cadence-registry.json').cadences;

// ── the v1 lane subset ──────────────────────────────────────────────────────
//
// `id` is the himmelctl-facing short name (what the operator types).
// `registryId` names the scripts/lanes/lanes.json lane whose probe decides
// availability — the registry stays the single source of truth for HOW a lane
// is detected, so this table never grows a second detection heuristic.
// `optIn: true` lanes are NEVER selected by default — they are reachable only
// via their explicit flag (or naming them at the interactive prompt, which
// IS that same explicit consent — see askLanes()'s own comment in bin.js).
//
// HIMMEL-2352 (operator ruling 34, 2026-09-01): v1 ships Claude tiers as the
// ONLY implementation lanes; codex and hermes are offered here ONLY as
// cross-model CR (code-review) lanes for /pr-check. ollama-local and
// copilot-cli — previously the two non-opt-in default lanes — are DROPPED
// from this table entirely: the wizard no longer offers, selects, or probes
// them at all. They still exist as ordinary (now `dormant`) rows in
// scripts/lanes/lanes.json, reachable by an operator who opts in directly via
// that registry's optInEnv — this table's job is only "what the installer
// asks about", and v1 no longer asks about them. See DORMANT_LANE_HINTS below
// for the --lanes/interactive refusal wording that points at that door.
//
// BOTH `install` and `note` are per-platform maps resolved through
// pickByPlatform. CR round 7 [codex-adv-r6-2]: `note` used to be a bare string
// while `install` was already platform-aware, so a Linux adopter got a correct
// install command followed by completion guidance naming a .ps1 script and a
// Windows-only runbook — able to install the binary, unable to finish. Every
// path named below is verified to exist in this repo; a POSIX entry pointing at
// a Windows-only artifact would just be a different lie.
const V1_LANES = [
  {
    id: 'codex',
    registryId: 'codex-exec',
    optIn: true,
    // The one v1 lane with a RICHER readiness probe than "the binary exists":
    // the manifest's cmd:codex_provisioned also requires the provisioning
    // cache, so codex can actually be confirmed ready rather than merely
    // installed (CR round 4 [codex-adv-r3-2]).
    manifestItem: 'codex-cli',
    install: {
      win32: 'winget install OpenAI.Codex',
      default: 'npm install -g @openai/codex',
    },
    note: {
      win32: 'then `pwsh -File scripts/codex/install-himmel-codex.ps1` (pwsh/PowerShell 7 preferred — `winget install Microsoft.PowerShell`; powershell.exe also works for this step); auth lives in ~/.codex/auth.json',
      default: 'then `bash scripts/codex/install-himmel-codex.sh`; auth lives in ~/.codex/auth.json',
    },
  },
  {
    id: 'hermes',
    registryId: 'hermes-oneshot',
    optIn: true,
    install: {
      win32: 'see docs/setup/windows-clean-machine.md Phase 5 (git clone + uv venv + pip install -e .)',
      default: 'see docs/hermes-runbook.md § "Install hermes (upstream)" — the Linux / macOS / WSL2 branch',
    },
    note: {
      win32: 'then `pwsh -File scripts/hermes/install-himmel-profile.ps1` (pwsh/PowerShell 7 preferred — `winget install Microsoft.PowerShell`; powershell.exe also works for this step). Do NOT auto-start the gateway — same-token platform pollers conflict across machines',
      default: 'then `bash scripts/hermes/install-himmel-profile.sh`. Do NOT auto-start the gateway — same-token platform pollers conflict across machines',
    },
  },
];

const ALL_LANE_IDS = V1_LANES.map((l) => l.id);
const PROFILE_LANE_REGISTRY_IDS = V1_LANES.map((l) => l.registryId);
const DEFAULT_LANE_IDS = V1_LANES.filter((l) => !l.optIn).map((l) => l.id);
const OPT_IN_LANE_IDS = V1_LANES.filter((l) => l.optIn).map((l) => l.id);
// The lane ids an operator may name directly (interactively or via --lanes).
// The opt-in lanes are excluded on purpose: `--lanes codex` must NOT be a
// second, quieter door around the explicit --with-codex consent.
//
// This is the SAME set as the defaults today — every non-opt-in lane is both
// offered and selected by default — so it is an alias rather than a second
// copy of the expression (CR round 11 [glm-r10-2]: two identical filters would
// drift the moment one of them gained a condition). The names stay distinct
// because the CONCEPTS are: "what you may type" and "what you get if you type
// nothing" only happen to coincide.
const SELECTABLE_LANE_IDS = DEFAULT_LANE_IDS;

// HIMMEL-2352 (ruling 34): the wizard's own lane subset is now codex/hermes
// ONLY, and both are opt-in — DEFAULT_LANE_IDS/SELECTABLE_LANE_IDS are
// therefore empty in v1. That is not a bug in the alias above: an empty
// "what you may type via --lanes" is exactly the "one door, not two" the
// ticket asks for (--lanes accepts only 'none'; codex/hermes stay reachable
// solely via --with-codex/--with-hermes or the interactive prompt below).
//
// HIMMEL-2308 (pre-2352 history): the INTERACTIVE lanes question offers
// ALL_LANE_IDS — every v1 lane, opt-in or not — while the --lanes CSV flag
// stays restricted to SELECTABLE_LANE_IDS (parseLaneList's default, below):
// naming codex/hermes THERE must still be refused, so --lanes never becomes a
// second, quieter door around --with-codex/--with-hermes. Selecting codex/
// hermes AT THE INTERACTIVE PROMPT is instead treated as the same explicit
// consent the flag provides — same principle as loadProfile()'s "naming
// codex/hermes in a profile IS the consent" comment — so askLanes() (bin.js)
// calls parseLaneList(..., { allowOptIn: true }) for that one call site only.
//
// HIMMEL-2303: disclosure of the CONSEQUENCE of skipping both opt-ins stays
// unchanged in spirit — a default or lanes=none install, with neither codex
// nor hermes taken, leaves NO non-Claude critic available, so /pr-check's
// CR_REQUIRE_CROSS_MODEL floor (docs/configuration.md) cannot be satisfied —
// the review panel runs Claude-only. Printed once, before the lanes prompt,
// by bin.js's askLanes().
function laneCrossModelDisclosureLines() {
  // The wrap points are load-bearing, not cosmetic: `test-wizard-questions.sh`
  // case1 greps this text for the single-line phrases
  // "Claude-only, and CR_REQUIRE_CROSS_MODEL" (the awk that proves the
  // disclosure prints BEFORE the lanes prompt) and
  // "CR_REQUIRE_CROSS_MODEL cannot be satisfied" (the consequence itself).
  // Both must stay on ONE line -- rewrapping so the phrase spans two is what
  // broke this case under HIMMEL-2352, and a consequence a reader has to
  // reassemble across a line break is worse copy anyway.
  return [
    'note: codex and hermes add cross-model review to /pr-check — Claude tiers',
    '  remain the only v1 implementation lanes (select codex/hermes below, or use',
    '  --with-codex / --with-hermes non-interactively). Without one, the /pr-check',
    '  review panel runs Claude-only, and CR_REQUIRE_CROSS_MODEL cannot be satisfied',
    '  (see docs/configuration.md).',
  ];
}

// HIMMEL-2308: one-line "what this lane needs" help text for the interactive
// lanes menu (askLanes, bin.js) — the per-option help apparatus askProfile
// pioneered (PROFILE_HELP), generalized to this question too. Kept HERE
// (not bin.js) because this module already owns every other lane fact
// (install/note/optIn) — a second lane-fact table in bin.js would drift from
// this one the first time a lane's install story changed.
const LANE_HELP = {
  codex: 'requires the codex CLI + its own login; skip if you don\'t have it',
  hermes: 'gateway lane; own opt-in, own install profile, own credentials',
};

// HIMMEL-2352 (ruling 34): ollama-local and copilot-cli are no longer part of
// V1_LANES at all — the wizard neither offers nor probes them — but a typo'd
// or muscle-memory `--lanes ollama` / the interactive prompt's `ollama` still
// deserves a more useful refusal than a bare "unknown lane": this table exists
// ONLY to name the scripts/lanes/lanes.json opt-in door those two lanes moved
// behind, so parseLaneList's error can point there instead. Kept as short ids
// (not registry ids) because that is what an operator actually types; the
// optInEnv values must match the `dormant.optInEnv` this ticket adds to their
// lanes.json rows exactly, or the printed hint would lie.
const DORMANT_LANE_HINTS = {
  ollama: { optInEnv: 'OLLAMA_LOCAL_LANE_OK' },
  copilot: { optInEnv: 'COPILOT_CLI_LANE_OK' },
};

function laneById(id) {
  return V1_LANES.filter((l) => l.id === id)[0] || null;
}

// Resolve a per-platform map ({ win32, darwin, default }) for one platform,
// falling back to `default` when there is no platform-specific entry. ONE
// resolver for both maps so an entry can never be platform-aware in the
// install column and platform-blind in the guidance column again.
function pickByPlatform(map, platform) {
  if (!map) return '';
  const p = platform || process.platform;
  return map[p] || map.default || '';
}

// The platform-appropriate install command for a lane.
function installHint(lane, platform) {
  return pickByPlatform(lane.install, platform);
}

// The platform-appropriate post-install setup step for a lane — the work the
// binary probe cannot establish (auth, model pull, profile provisioning).
function setupNote(lane, platform) {
  return pickByPlatform(lane.note, platform);
}

// ── selection ───────────────────────────────────────────────────────────────

// Parse a --lanes / interactive-answer CSV into a validated id list.
// Returns { ok: true, lanes } or { ok: false, error }. 'none' is the explicit
// empty selection (an empty string is NOT — that means "accept the default",
// which the caller resolves before ever getting here).
//
// `opts.allowOptIn` (HIMMEL-2308): the --lanes CLI flag calls this with no
// options, so OPT_IN_LANE_IDS still hit the "select it with --with-<id>"
// refusal below — --lanes must never become a quieter door around that
// explicit consent. bin.js's askLanes() (the INTERACTIVE menu only) passes
// { allowOptIn: true }, because choosing codex/hermes AT THE PROMPT is itself
// the explicit consent, same principle as a profile file naming them.
//
// HIMMEL-2352 (ruling 34): a third refusal shape, checked BEFORE the opt-in
// one and regardless of `allowOptIn` — ollama/copilot are not merely opt-in,
// they are dormant-in-v1 (DORMANT_LANE_HINTS above): no flag or prompt answer
// in himmelctl can select them at all, so the error must say WHERE that door
// actually is (scripts/lanes/lanes.json's own optInEnv) rather than implying
// a --with-ollama flag that does not exist.
function parseLaneList(csv, opts) {
  const allowOptIn = Boolean(opts && opts.allowOptIn);
  const known = allowOptIn ? ALL_LANE_IDS : SELECTABLE_LANE_IDS;
  const raw = String(csv == null ? '' : csv).trim();
  if (raw === 'none') return { ok: true, lanes: [] };
  const parts = raw.split(',').map((s) => s.trim()).filter((s) => s !== '');
  if (parts.length === 0) {
    return { ok: false, error: `empty lane list — use 'none' to select no lanes (known: ${known.join(', ')})` };
  }
  const out = [];
  for (const p of parts) {
    if (known.indexOf(p) === -1) {
      const dormant = DORMANT_LANE_HINTS[p];
      if (dormant) {
        return {
          ok: false,
          error: `lane '${p}' is dormant in v1: opt in with ${dormant.optInEnv}=1 (scripts/lanes/lanes.json), not via himmelctl — Claude tiers are the only v1 implementation lanes; codex/hermes are the only CR lanes`,
        };
      }
      const optIn = !allowOptIn && OPT_IN_LANE_IDS.indexOf(p) !== -1;
      const hint = optIn
        ? `lane '${p}' is opt-in — select it with --with-${p}, not --lanes`
        : `unknown lane '${p}' (known: ${known.join(', ')}, or 'none')`;
      return { ok: false, error: hint };
    }
    if (out.indexOf(p) === -1) out.push(p);
  }
  return { ok: true, lanes: out };
}

// Append the opt-in lanes their flags requested. Kept separate from
// parseLaneList so the opt-in consent is applied identically no matter where
// the base selection came from (flag, prompt, or the default).
function applyOptIns(baseLanes, opts) {
  const out = baseLanes.slice();
  if (opts && opts.withCodex && out.indexOf('codex') === -1) out.push('codex');
  if (opts && opts.withHermes && out.indexOf('hermes') === -1) out.push('hermes');
  return out;
}

function registryIdsForSelection(selected) {
  const out = [];
  for (const id of selected || []) {
    const lane = laneById(id);
    if (!lane) throw new Error(`unknown adopter lane '${id}'`);
    if (out.indexOf(lane.registryId) === -1) out.push(lane.registryId);
  }
  return out;
}

// Validate the profile-overlay conditions that are predictable before the core
// installer runs. The real write repeats the same checks after the install so a
// change during the run still fails closed; interruption inside the core
// installer remains outside this bounded preflight.
async function preflightProfileLaneAllowlist(repoRoot) {
  // LANES_REGISTRY is a wholesale resolver override: resolve.mjs deliberately
  // skips lanes.local.json while it is set. Writing the default overlay here
  // would therefore report a consent boundary that the active resolver ignores.
  if (process.env.LANES_REGISTRY) {
    throw new Error('LANES_REGISTRY is set, so the active resolver ignores lanes.local.json; refusing to report the adopter lane profile as persisted');
  }
  const lanesDir = path.resolve(__dirname, '..', '..', 'lanes');
  const writer = await import(pathToFileURL(path.join(lanesDir, 'set-lane-override.mjs')).href);
  const file = path.join(repoRoot || process.cwd(), 'scripts', 'lanes', 'lanes.local.json');
  writer.validateProfileAllowlistTarget(file);
  return { writer, file };
}

// Persist the adopter selection as a top-level profileAllowlist in the SAME
// gitignored overlay the resolver already reads. profileAllowlistScope limits
// the policy to the lanes this wizard actually owns; every other registry lane
// stays on its real base probe. Legacy scope-less allowlists keep their global
// semantics instead. The allowlist is still applied AFTER each real probe, so
// it can suppress but never conjure availability. The writer preserves existing
// per-lane overrides and uses its proven lock + atomic-rename path.
async function persistProfileLaneAllowlist(selected, repoRoot) {
  const { writer, file } = await preflightProfileLaneAllowlist(repoRoot);
  const ids = registryIdsForSelection(selected);
  const preservedLegacyGlobal = writer.writeProfileAllowlist(file, ids, PROFILE_LANE_REGISTRY_IDS);
  return { ids, preservedLegacyGlobal };
}

// ── probing ─────────────────────────────────────────────────────────────────

// Parse a lane registry file into a THREE-way result:
//   { status: 'ok',      value }         — parsed, right shape
//   { status: 'absent' }                 — the file simply isn't there
//   { status: 'invalid', detail }        — present but unreadable/not JSON/wrong shape
//
// CR round 4 [codex-adv-r3-3]: these last two used to collapse into a single
// `null`. For the OVERLAY that conflation is a semantics divergence, not
// cosmetics: a corrupt lanes.local.json made himmelctl silently fall back to
// the base registry and certify lanes, while the canonical resolver die(2)s on
// exactly that file and cannot resolve anything at all. The installer must not
// be more confident than the resolver it is describing.
function readRegistryFile(file) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (e) {
    if (e && e.code === 'ENOENT') return { status: 'absent' };
    return { status: 'invalid', detail: e && e.message ? e.message : 'unreadable' };
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    return { status: 'invalid', detail: `not valid JSON (${e && e.message ? e.message : 'parse error'})` };
  }
  if (!parsed || typeof parsed !== 'object' || !Array.isArray(parsed.lanes)) {
    return { status: 'invalid', detail: "must be an object with a 'lanes' array" };
  }
  return { status: 'ok', value: parsed };
}

// Read BOTH registries: the shared base and the machine-local overlay
// `himmelctl config set lanes.<id> on|off` writes.
//
// CR round 2 [codex-adv-r2-1]: this used to read the base alone, so a lane the
// operator had locally DISABLED still reported "available" here while `/lanes`
// correctly excluded it — the installer's epilogue contradicted the runtime
// surface it was describing. The overlay is not decoration: it is the documented
// way to turn a lane off, and an installer that ignores it is reporting a
// machine that does not exist.
//
// Returns null when the BASE is unusable (callers degrade to 'unknown'). An
// ABSENT overlay is normal (`local: null`); a PRESENT-but-invalid one is
// reported via `localError` so callers can fail closed the way the resolver
// does, naming the offending file.
function readLaneRegistries(repoRoot) {
  const lanesDir = path.join(repoRoot, 'scripts', 'lanes');

  // CR round 11 [codex-adv-r10-3]: LANES_REGISTRY is the resolver's documented
  // test/CI override, and it replaces the registry WHOLESALE — resolve.mjs
  // returns that file's contents and skips lanes.local.json entirely. Reading
  // the checkout default plus the overlay under that override made the
  // epilogue describe a different lane set than /lanes resolved.
  //
  // The policy is mirrored, not the loader: resolve.mjs's loadRegistry() ends
  // in die(2) on a malformed file, which is right for a CLI and wrong here —
  // this module answers 'unknown' and lets the caller keep going. Reusing it
  // would turn a bad registry into an abrupt himmelctl exit and break the
  // fail-to-unknown contract the rest of this file is built on. Read from
  // process.env for the same reason resolve.mjs does: it is a process-wide
  // override, not per-call context.
  const override = process.env.LANES_REGISTRY;
  if (override) {
    const overridden = readRegistryFile(override);
    if (overridden.status !== 'ok') return null;
    return { base: overridden.value, local: null, localError: null };
  }

  const base = readRegistryFile(path.join(lanesDir, 'lanes.json'));
  if (base.status !== 'ok') return null;
  const localFile = path.join(lanesDir, 'lanes.local.json');
  const local = readRegistryFile(localFile);
  if (local.status === 'invalid') {
    return { base: base.value, local: null, localError: { file: localFile, detail: local.detail } };
  }
  return { base: base.value, local: local.status === 'ok' ? local.value : null, localError: null };
}

// Load the CANONICAL lane probe machinery: the pure evaluator
// (scripts/lanes/probe.mjs) plus the context builder that supplies it with
// real machine state (scripts/lanes/resolve.mjs `buildCtx` — merged repo
// .env, a PATHEXT-aware PATH scan, and the hermes install probe).
//
// CR round 1 [codex-adv-3]: this used to be a hand-rolled switch that read
// the registry's `installed` kind as a bare PATH lookup. That is NOT what
// `installed` means — the canonical hermes probe honors $HERMES_PY and finds
// venvs under $HERMES_HOME / %LOCALAPPDATA%, none of which put `hermes` on
// PATH. The duplicate therefore reported a valid hermes install as missing,
// and would report any unrelated `hermes` executable as present. Reusing the
// real evaluator means himmelctl's answer to "is this lane available?" is by
// construction the same answer `/lanes` gives, and cannot drift from it.
//
// Both modules are ESM and this file is CJS, hence the dynamic import; the
// single call site is already async. Note the two roots are deliberately
// different: the MODULES come from this checkout (they ship with himmelctl),
// while the REGISTRY comes from `repoRoot`, which a hermetic test redirects.
// Returns null if the resolver cannot be loaded — callers degrade to
// 'unknown' rather than falling back to a weaker guess.
async function loadLaneProbe(repoRoot, env) {
  try {
    const lanesDir = path.resolve(__dirname, '..', '..', 'lanes');
    const [resolveMod, probeMod] = await Promise.all([
      import(pathToFileURL(path.join(lanesDir, 'resolve.mjs')).href),
      import(pathToFileURL(path.join(lanesDir, 'probe.mjs')).href),
    ]);
    return {
      ctx: resolveMod.buildCtx(repoRoot, env || process.env),
      evalProbe: probeMod.evalProbe,
      // The resolver's OWN overlay merge (a true per-lane shallow merge, not a
      // wholesale replace) — reused rather than re-derived for the same reason
      // evalProbe is.
      mergeLocalOverlay: resolveMod.mergeLocalOverlay,
    };
  } catch (e) {
    // CR round 11 [glm-r10-4]: a bare catch here turned every lane UNKNOWN
    // with no way to find out why. The reason goes to stderr so the cause is
    // visible without changing the (correct) fail-to-unknown behaviour.
    console.error(`himmelctl: could not load the lane resolver — lanes will report UNKNOWN: ${e && e.message ? e.message : e}`);
    return null;
  }
}

// The probe kinds the canonical evaluator actually decides. Anything outside
// this set is reported 'unknown' rather than taking evalProbe's fail-closed
// `false` and presenting it to the operator as a definite "not installed".
const EVALUABLE_PROBE_KINDS = ['always', 'never', 'path', 'env', 'installed', 'crprofile'];

// Human-readable detail for a decided probe. Presentation ONLY — the verdict
// comes from evalProbe; nothing here re-implements detection.
function probeDetail(probe, ok, platform) {
  const p = platform || process.platform;
  switch (probe.kind) {
    case 'path': return ok ? `${probe.cli} found on PATH` : `${probe.cli} not on PATH`;
    case 'installed': {
      if (ok) return `${probe.tool} installation detected`;
      // CR round 2 [glm-r2-2]: %LOCALAPPDATA% is meaningless off Windows, and
      // naming a location the operator cannot have is worse than naming none.
      const where = p === 'win32'
        ? '$HERMES_PY, or a venv under $HERMES_HOME / %LOCALAPPDATA%\\hermes'
        : '$HERMES_PY, or a venv under $HERMES_HOME';
      return `no ${probe.tool} installation found (checked ${where})`;
    }
    case 'env': return ok ? `${probe.name} is set` : `${probe.name} is not set`;
    case 'crprofile': return ok ? `CR_PROFILE carries '${probe.token}'` : `CR_PROFILE lacks '${probe.token}'`;
    default: return `registry probe kind=${probe.kind}`;
  }
}

// Evaluate ONE lane, separating PHYSICAL availability (the shared base probe)
// from EFFECTIVE availability (the base probe as overridden by the machine's
// lanes.local.json). Returns { state, detail } where state is:
//
//   present  — physically there AND enabled: the delegation machinery can use it
//   disabled — physically there but turned OFF by the local overlay. Reported
//              distinctly (CR round 2 [codex-adv-r2-1]) because "install it"
//              and "re-enable it" are different next steps, and collapsing
//              either into the other misdescribes the machine.
//   absent   — not physically there
//   unknown  — we cannot honestly say
//
// 'unknown' is a first-class answer, not a failure mode: an unreadable base
// registry, a lane the registry does not declare, a probe kind the canonical
// evaluator does not decide, and an unloadable resolver are all cases where
// claiming any of the other three would be a guess. An installer that guesses
// is exactly what the probe-truth spine (HIMMEL-1093) exists to prevent.
function probeLane(lane, ctx) {
  const platform = ctx && ctx.platform;
  const regs = readLaneRegistries((ctx && ctx.repoRoot) || process.cwd());
  if (regs === null) {
    return { state: 'unknown', detail: 'lane registry scripts/lanes/lanes.json is missing or unreadable' };
  }
  if (regs.localError) {
    // Fail closed, matching the resolver's die(2) on this exact file: if
    // `/lanes` cannot resolve at all, himmelctl must not answer for it.
    return {
      state: 'unknown',
      detail: `lane overlay ${regs.localError.file} is present but invalid (${regs.localError.detail}) — fix or remove it; the lane resolver cannot run either`,
    };
  }
  const laneProbe = ctx && ctx.laneProbe;
  if (!laneProbe) {
    return { state: 'unknown', detail: 'the canonical lane resolver could not be loaded' };
  }
  // Merge exactly as the resolver does, so the overlay's per-lane semantics
  // (shallow merge, local fields win) cannot drift from `/lanes`.
  const merged = regs.local ? laneProbe.mergeLocalOverlay(regs.base, regs.local) : regs.base;
  const pick = (reg) => reg.lanes.filter((l) => l && l.id === lane.registryId)[0];
  const baseEntry = pick(regs.base);
  const mergedEntry = pick(merged) || baseEntry;

  // ORDER IS LOAD-BEARING (CR round 5 [codex-adv-r5-1]). The BASE probe — and
  // only the base probe — answers "is this thing physically installed?". The
  // merged/overlay probe answers a DIFFERENT question: "is this lane switched
  // on?". Round 2 evaluated the merged probe first and returned `present` on
  // any truthy result, which re-opened the exact trap this module was built to
  // avoid: `himmelctl config set lanes.<id> on` writes probe.kind=always, so a
  // machine with no binary at all reported "binary present" and lost its
  // install command. An override can express intent; it cannot conjure an
  // executable. So: physical FIRST, enabled SECOND, and the two are combined
  // below rather than collapsed into one truthy check.
  const baseProbe = baseEntry && baseEntry.probe;
  if (!baseProbe || !baseProbe.kind) {
    return { state: 'unknown', detail: `lane '${lane.registryId}' declares no probe in the registry` };
  }
  if (EVALUABLE_PROBE_KINDS.indexOf(baseProbe.kind) === -1) {
    return { state: 'unknown', detail: `probe kind '${baseProbe.kind}' is not one the lane resolver decides` };
  }
  const physical = Boolean(laneProbe.evalProbe(baseProbe, laneProbe.ctx));

  // Enabled state comes from the merged probe, and must FAIL CLOSED exactly
  // where the canonical evaluator does.
  //
  // CR round 9 [codex-adv-r8-1]: this used to fall back to the base probe for a
  // null/absent merged probe, and to `enabled = true` for a kind it could not
  // decide. evalProbe returns FALSE for all of those (null, non-object, empty
  // or unknown kind — verified against probe.mjs), so a hand-edited
  // `{"probe": null}` or a version-skewed kind EXCLUDES the lane from /lanes
  // while this reported it present with nothing to do. Optimism about an
  // override we cannot read is the same class of false-green as trusting
  // kind=always: when the overlay is unreadable, say so and treat the lane as
  // off, because that is what every other consumer will do.
  //
  // Whether an overlay speaks for this lane is read from the overlay itself
  // rather than inferred from object identity after the merge.
  const overridden = Boolean(regs.local)
    && regs.local.lanes.some((l) => l && l.id === lane.registryId);
  const mergedProbe = mergedEntry ? mergedEntry.probe : baseProbe;
  let enabled;
  let overlayFault = '';
  if (!mergedProbe || typeof mergedProbe !== 'object' || !mergedProbe.kind) {
    enabled = false;
    overlayFault = 'its lanes.local.json entry declares no usable probe';
  } else if (EVALUABLE_PROBE_KINDS.indexOf(mergedProbe.kind) === -1) {
    enabled = false;
    overlayFault = `its lanes.local.json entry declares probe kind '${mergedProbe.kind}', which the lane resolver does not evaluate`;
  } else {
    enabled = Boolean(laneProbe.evalProbe(mergedProbe, laneProbe.ctx));
  }

  if (physical && enabled) {
    return { state: 'present', detail: probeDetail(baseProbe, true, platform) };
  }
  if (physical && !enabled) {
    return {
      state: 'disabled',
      detail: overlayFault
        ? `installed (${probeDetail(baseProbe, true, platform)}) but NOT usable — ${overlayFault}; /lanes excludes it too`
        : `installed (${probeDetail(baseProbe, true, platform)}) but DISABLED by scripts/lanes/lanes.local.json`,
    };
  }
  // Not installed. Two sub-cases carry an EXTRA blocker beyond the missing
  // binary, and CR round 11 [codex-r10-1] is the second of them: installing
  // the CLI does not make the lane usable while the overlay still turns it
  // off, so /lanes keeps excluding it and the adopter has followed our
  // instructions and got nothing. `overlayFix` names the second step; the
  // summary renders it after the install command.
  if (!physical && !enabled && overlayFault) {
    // Not installed AND the overlay is broken — name both, so fixing one does
    // not leave the other as a silent surprise.
    return {
      state: 'absent',
      detail: `${probeDetail(baseProbe, false, platform)}; also ${overlayFault}`,
      overlayFix: `repair or remove that entry in scripts/lanes/lanes.local.json — installing the CLI alone will not make the lane usable`,
    };
  }
  if (!physical && !enabled && overridden) {
    return {
      state: 'absent',
      detail: `${probeDetail(baseProbe, false, platform)}; and DISABLED by scripts/lanes/lanes.local.json`,
      overlayFix: `then re-enable it (the local overlay turns it off, so /lanes excludes it even once installed): node scripts/himmelctl/bin.js config set lanes.${lane.registryId} on`,
    };
  }
  if (!physical && enabled && overridden) {
    // Forced ON by the overlay while nothing is actually installed. Its own
    // state, because the fix is BOTH "install it" and "stop lying about it",
    // and because silently calling it `absent` would hide a local config that
    // is actively misreporting the machine to every lane consumer.
    return {
      state: 'misconfigured',
      detail: `forced ON by scripts/lanes/lanes.local.json, but ${probeDetail(baseProbe, false, platform)}`,
    };
  }
  return { state: 'absent', detail: probeDetail(baseProbe, false, platform) };
}

// Is a PRESENT lane actually ready to use, or merely installed?
//
// CR round 4 [codex-adv-r3-2]: the registry probes establish that an
// executable exists — nothing more. ollama still needs its model pulled,
// copilot needs an interactive device-flow login, codex needs provisioning.
// Reporting such a lane as "ready" and dropping its setup note told the
// adopter the opposite of the truth about a lane they cannot yet use.
//
// Returns one of:
//   'ready'       — a richer probe confirms setup is complete
//   'incomplete'  — a richer probe says setup is NOT done
//   'unverified'  — no richer probe exists (or it could not run); the binary
//                   is there and that is genuinely all we know
function laneSetupState(lane, ctx) {
  if (!lane.manifestItem) return { state: 'unverified', detail: '' };
  const repoRoot = (ctx && ctx.repoRoot) || process.cwd();
  let item = null;
  try {
    const manifest = JSON.parse(fs.readFileSync(path.join(repoRoot, 'scripts', 'install', 'manifest.json'), 'utf8'));
    item = (manifest.items || []).filter((i) => i && i.id === lane.manifestItem)[0] || null;
  } catch (_e) {
    return { state: 'unverified', detail: '' };
  }
  if (!item) return { state: 'unverified', detail: '' };
  try {
    const r = probesLib.runProbe(item, {
      repoRoot: repoRoot,
      targetPath: repoRoot,
      scope: 'user',
      env: (ctx && ctx.env) || process.env,
    });
    if (r.actual === 'present') return { state: 'ready', detail: r.detail || '' };
    return { state: 'incomplete', detail: r.detail || '' };
  } catch (_e) {
    return { state: 'unverified', detail: '' };
  }
}

// Probe every lane in the v1 subset, tagging each with whether it was
// selected. Returns rows: { id, selected, state, detail, hint, note }.
// Non-selected lanes are still reported (as skipped) so the summary can say
// WHY a lane the operator might expect is missing.
//
// HIMMEL-1428 persists the selected registry ids as the resolver's narrowing
// profile allowlist after an applied install. These rows still probe only the
// selected v1 lanes for the install summary; `/lanes` separately reports any
// physically-available non-selected lane in this wizard-owned subset as
// suppressed-by-profile. Registry lanes outside the subset remain unconstrained.
function probeSelection(selected, ctx) {
  return V1_LANES.map((lane) => {
    const chosen = selected.indexOf(lane.id) !== -1;
    const probe = chosen ? probeLane(lane, ctx) : { state: 'not-selected', detail: '' };
    const setup = probe.state === 'present'
      ? laneSetupState(lane, ctx)
      : { state: 'unverified', detail: '' };
    return {
      setupState: setup.state,
      setupDetail: setup.detail,
      id: lane.id,
      registryId: lane.registryId,
      selected: chosen,
      optIn: lane.optIn,
      state: probe.state,
      detail: probe.detail,
      overlayFix: probe.overlayFix || '',
      hint: installHint(lane, ctx && ctx.platform),
      note: setupNote(lane, ctx && ctx.platform),
    };
  });
}

// ── always-on hardening checklist (PRINTED, never executed) ─────────────────
//
// Transcribed from docs/setup/windows-clean-machine.md Phase 0 + Phase 6.
// These are machine-wide, need elevation, and `himmelctl uninstall` cannot
// undo them — which is exactly why they are a checklist and not a step.
const HARDENING_CHECKLIST = [
  {
    title: 'Power profile — never sleep, never hibernate',
    why: 'a sleeping machine drops scheduled claude relaunches and any inbound SSH',
    platform: 'win32',
    commands: [
      'powercfg /change standby-timeout-ac 0',
      'powercfg /change standby-timeout-dc 0',
      'powercfg /change hibernate-timeout-ac 0',
      'powercfg /change hibernate-timeout-dc 0',
      'powercfg /change disk-timeout-ac 0',
      'powercfg /hibernate off',
      'powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0',
      'powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0',
      'powercfg /S SCHEME_CURRENT',
    ],
  },
  {
    title: 'No lock screen on wake',
    why: 'a locked console blocks GUI-attached tools (Obsidian) in the auto-logon session',
    platform: 'win32',
    commands: [
      'powercfg /setacvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0',
      'powercfg /setdcvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0',
      'powercfg /S SCHEME_CURRENT',
    ],
  },
  // CR round 8 [codex-adv-r7-2]: this used to be ONE step that installed the
  // capability and started the service in two lines. Installing Windows
  // OpenSSH opens an inbound port-22 firewall rule and the default config
  // accepts PASSWORD auth — so that ordering stood up a password-reachable
  // remote shell on the very machine this checklist is configuring for
  // unattended auto-logon, before any access policy existed. The policy now
  // comes first and the service is started last, after `sshd -t` validates
  // the config. Still printed, never executed.
  {
    title: 'SSH access policy — do ALL of this BEFORE enabling the service',
    why: 'installing OpenSSH opens inbound 22 and defaults to password auth; on an auto-logon box that is a password-reachable shell',
    platform: 'win32',
    commands: [
      '# 1. install the component ONLY (do not start it yet)',
      'Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0',
      '',
      '# 2. put your PUBLIC key in place. For an ADMIN account Windows uses one',
      '#    shared file, and sshd REFUSES it unless the ACL is locked down:',
      '#      C:\\ProgramData\\ssh\\administrators_authorized_keys',
      'icacls C:\\ProgramData\\ssh\\administrators_authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"',
      '#    (a NON-admin account uses %USERPROFILE%\\.ssh\\authorized_keys instead)',
      '',
      '# 3. restrict WHO may log in — edit C:\\ProgramData\\ssh\\sshd_config:',
      '#      PubkeyAuthentication yes',
      '#      PasswordAuthentication no',
      '#      KbdInteractiveAuthentication no',
      '#      AllowGroups <your-ssh-group>          # or AllowUsers <you>',
      '#    and confirm the Match block at the end does not re-open password auth',
      '',
      '# 4. scope the firewall rule to the networks you actually use —',
      '#    the rule the capability adds allows ANY remote address',
      '#    (e.g. 192.168.1.0/24 for a typical home LAN)',
      'Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -RemoteAddress <your-lan-subnet>',
      '',
      '# 5. validate the config BEFORE starting anything (prints nothing if OK)',
      'C:\\Windows\\System32\\OpenSSH\\sshd.exe -t',
    ],
  },
  {
    title: 'Enable sshd — only once every step above is done',
    why: 'remote-over-SSH adopter installs are HIMMEL-1424 — v1 installs LOCAL only, so enable this only if you will drive the machine remotely',
    platform: 'win32',
    commands: [
      'Set-Service -Name sshd -StartupType Automatic',
      '',
      '# sshd reads its config at START. `Start-Service` on an ALREADY-RUNNING',
      '# daemon is a silent no-op, so the OLD config (password auth and all)',
      '# would stay live and the policy above would never take effect. RESTART a',
      '# running service; only START a stopped one.',
      "if ((Get-Service sshd).Status -eq 'Running') { Restart-Service sshd } else { Start-Service sshd }",
      '',
      '# confirm it came back with the config you just validated',
      'Get-Service sshd | Select-Object Name, Status, StartType',
      '',
      '# verify from ANOTHER machine that key auth works and password auth is refused:',
      '#   ssh -o PreferredAuthentications=password <user>@<host>   -> must FAIL',
    ],
  },
  {
    title: 'Auto-logon (so scheduled claude relaunches get a desktop session)',
    why: 'schtasks-armed claude needs an interactive session, not just a logon token',
    platform: 'win32',
    commands: [
      "Set-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\PasswordLess\\Device' -Name DevicePasswordLessBuildVersion -Value 0",
      'then use Sysinternals Autologon (https://live.sysinternals.com/Autologon64.exe)',
      '  — it stores the password LSA-encrypted; the DefaultPassword registry value is PLAINTEXT. Do not use it.',
    ],
  },
  {
    title: 'Vault app on the auto-logon session (optional)',
    why: 'Obsidian must be running for the luna vault sync/plugins to tick',
    platform: 'win32',
    commands: [
      "Set-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run' -Name Obsidian -Value \"`\"$env:LOCALAPPDATA\\Programs\\Obsidian\\Obsidian.exe`\"\"",
    ],
  },
];

// Render the checklist as lines. Returns an array of strings so the caller
// owns the writing (and a test can assert on the content without capturing
// stdout). `platform` filters to the steps that apply; a non-win32 host gets
// the honest "these are Windows-only" note rather than commands it cannot run.
function hardeningChecklistLines(platform) {
  const p = platform || process.platform;
  const lines = [];
  lines.push('');
  lines.push('── always-on machine hardening — CHECKLIST ONLY, himmelctl ran NONE of this ──');
  lines.push('');
  lines.push('These are machine-wide, need an elevated shell, and `himmelctl uninstall`');
  lines.push('cannot undo them. Run them by hand once you have read them.');
  const applicable = HARDENING_CHECKLIST.filter((s) => s.platform === p);
  if (applicable.length === 0) {
    lines.push('');
    lines.push(`  (no hardening steps are published for platform '${p}' — the runbook`);
    lines.push('   docs/setup/windows-clean-machine.md Phase 6 is Windows-only so far)');
    lines.push('');
    return lines;
  }
  for (let i = 0; i < applicable.length; i++) {
    const step = applicable[i];
    lines.push('');
    lines.push(`  [ ] ${i + 1}. ${step.title}`);
    lines.push(`         why: ${step.why}`);
    for (const c of step.commands) lines.push(`         ${c}`);
  }
  lines.push('');
  lines.push('  Full runbook + verification checklist: docs/setup/windows-clean-machine.md');
  lines.push('');
  return lines;
}

// The one-line pointer printed when the operator said this is NOT an
// always-on machine — the checklist stays one command away without dumping
// 30 lines of powercfg on someone installing to a laptop.
function hardeningPointerLines() {
  return [
    '',
    'always-on hardening: skipped (you answered alwaysOn=no).',
    '  If you later run this machine unattended, see docs/setup/windows-clean-machine.md Phase 6.',
    '',
  ];
}

// HIMMEL-2300: the honest counterpart to hardeningPointerLines() for a run
// that never asked the always-on question at all. HIMMEL-2308 made alwaysOn
// universal (askQuestions() asks every profile), so this now matters only for
// a legacy/hand-edited --from-profile that carries no alwaysOn answer.
// hardeningPointerLines()'s "you answered alwaysOn=no" is a fabricated
// consent record in that case; this says plainly that nothing was asked,
// same round-8 not-asked/answered distinction already applied to
// luna/secretsWalk/bridge.
function hardeningNotAskedLines() {
  return [
    '',
    'always-on hardening: not asked (this flow does not ask the always-on question).',
    '  If this machine runs unattended, see docs/setup/windows-clean-machine.md Phase 6.',
    '',
  ];
}

// ── PHI + trust-class checklist (PRINTED, never executed) ──────────────────
//
// HIMMEL-2176 Task 8, design A10: the wizard records ONLY `luna.phi.declared`
// — the adopter's yes/no ANSWER to "does this vault handle PHI?" (design A10:
// an explicit declaration, not a "checklist shown" receipt — every adopter
// with a vault sees this checklist regardless of their answer, so "shown"
// would be true for essentially everyone and the stored value would carry no
// signal; status item S3/phi-coherence depends on `declared` meaning the
// adopter's actual declaration). The wizard NEVER creates/writes .salus,
// phi-roots, egress-denylist or access.json itself — those are trust-bearing,
// human-authored artifacts (design A8.1). Paths verified in-tree against
// probes.js's phi-coherence probe (`.salus` ancestor marker,
// `~/.config/claude-glm/phi-roots`) and docs/internals/egress-matrix.md
// (`~/.config/claude-glm/egress-denylist`).
//
// RETASK stage1-build-6d2e round 11 [codex-2]: the printed text below (and
// buildSummary's own manual-entry wording for phiDeclared, a few hundred
// lines down) used to say "himmelctl records only that you saw this
// checklist" — describing the OLD, wrong "shown" semantics rather than what
// the field actually stores. Fixed the WORDING, not the behaviour — the
// field, its name, and status S3's dependency on it are all correct as
// shipped; only the sentence describing it was wrong.
function phiChecklistLines() {
  return [
    '',
    '── PHI checklist — READ ONLY, himmelctl creates none of this ──────────────',
    '',
    'If this vault will hold Protected Health Information, do ALL of this by hand',
    '(himmelctl records only your yes/no answer below, at luna.phi.declared —',
    'it never creates the markers themselves; that stays on you):',
    '',
    '  [ ] 1. drop a `.salus` marker file at the vault root (or an ancestor dir)',
    '  [ ] 2. add the vault\'s absolute path as a line in ~/.config/claude-glm/phi-roots',
    '  [ ] 3. add the relevant path(s)/pattern(s) to ~/.config/claude-glm/egress-denylist',
    '',
    '  Full reference: docs/internals/egress-matrix.md',
    '',
  ];
}

// RETASK stage1-build-6d2e — CR finding treated as more than a Suggestion:
// bridge persistence installs a DIFFERENT artifact per platform (a Windows
// scheduled task; a Linux systemd --user unit + linger; nothing anywhere
// else), and THREE user-facing sites need to agree on which: bin.js's
// interactive consent prompt, bin.js's --dry-run preview (via
// attemptBridgePersistence itself, already correct), and this module's own
// buildSummary() --dry-run wording below. Round 4 fixed the preview, round 9
// fixed the summary — the consent prompt was missed BOTH times, and an
// explicit sweep for platform assumptions in the dry-run text still missed
// it, because each site independently re-decided the same platform branch
// instead of reading one answer. This is that one answer now; every
// consumer (bin.js's consent prompt included) calls this instead of
// re-testing process.platform. Null means no installer exists for this
// platform — a caller must not offer/claim an install in that case.
function bridgePersistenceArtifact(platform) {
  const p = platform || process.platform;
  if (p === 'win32') return 'a HimmelTelegramBridge scheduled task';
  if (p === 'linux') return 'a systemd --user unit (telegram-bridge.service) + linger';
  return null;
}

// HIMMEL-2302 legacy interplay: resolve `{ <id>: 'armed'|'off' }` for every
// cadence unit this run has an ACTUAL answer for — an id absent from the
// result means "never asked" (never a fabricated 'off'), same "not asked ≠
// answered off" discipline every other section already follows. `cadences`
// is a TOP-LEVEL optional answer section (buildAnswers, bin.js — same
// pattern as luna/secretsWalk/bridge, NOT nested inside `luna`); when
// present it is AUTHORITATIVE — `luna.cadenceEnabled` is validated
// (loadProfile) but never consulted for arming. When ABSENT (every
// pre-HIMMEL-2302 profile/fixture), pipeline's disposition is derived from
// the legacy `luna.cadenceEnabled` boolean and every OTHER unit stays
// never-asked. Shared by bin.js's previewLunaSections/applyLunaSectionsStep
// and this module's own buildSummary below, so the three can never drift.
function resolveCadenceDispositions(answers) {
  if (answers.cadences !== undefined && answers.cadences !== null) return answers.cadences;
  const luna = answers.luna;
  if (luna && typeof luna.cadenceEnabled === 'boolean') {
    return { pipeline: luna.cadenceEnabled ? 'armed' : 'off' };
  }
  return {};
}

// HIMMEL-2305: the closed set of "feature areas" the installed configuration
// surface can be scoped by. Mirrored (not shared — different module system,
// see that file's own comment) by scripts/lib/gen-secrets-doc.mjs's
// FEATURE_IDS, which validates secrets-manifest.json's `feature` field
// against the same list.
const FEATURE_IDS = ['core', 'vault', 'cadence', 'bridge', 'whisper', 'lane:codex', 'lane:hermes'];

// HIMMEL-2305: the ONE place that turns a recorded install profile's answers
// into the set of feature areas it actually opted into — consumed by BOTH
// bin.js's secrets walk (filtering secrets-manifest.json entries by their
// `feature` tag) and status-report.js (downgrading telegram-bridge/
// hermes-lanes/codex-cli to n/a when their feature was never selected),
// so the two surfaces can never disagree on what "selected" means.
//
// Returns `null` — the fail-open sentinel — when `answers` itself is not a
// usable object at all: a caller with no real profile to consult must keep
// every item at its ORIGINAL (full-nag / full-walk) behavior rather than
// silently going quiet. When `answers` IS a real object, a feature the
// wizard never asked about (an absent `bridge`/`cadences` section, an empty
// `lanes` array) resolves to OFF for scoping — the same "not asked ≠
// answered off, but still OFF here" rule every other luna/secretsWalk/bridge
// section in this file already follows (see resolveCadenceDispositions
// above). `core` is always on: it has no gating question.
function resolveActiveFeatures(answers) {
  if (!answers || typeof answers !== 'object') return null;
  const active = new Set(['core']);
  if (answers.vault && answers.vault.mode && answers.vault.mode !== 'none') active.add('vault');
  const dispositions = resolveCadenceDispositions(answers);
  if (Object.keys(dispositions).some((id) => dispositions[id] === 'armed')) active.add('cadence');
  if (answers.bridge && answers.bridge.enabled) {
    active.add('bridge');
    active.add('whisper');
  }
  const lanes = Array.isArray(answers.lanes) ? answers.lanes : [];
  if (lanes.indexOf('codex') !== -1) active.add('lane:codex');
  if (lanes.indexOf('hermes') !== -1) active.add('lane:hermes');
  return active;
}

// ── final honest summary ────────────────────────────────────────────────────

// Build the summary model from the answers + lane probe rows. Pure data, so
// the test can assert on the model rather than scraping formatted text.
//
//   installed — what this run ACTUALLY put on the machine (applied runs only)
//   planned   — what it WOULD do (--dry-run only)
//   skipped   — what it deliberately did not do, each with a reason
//   manual    — what the operator must still do themselves
//
// CR round 1 [codex-1]: `installed` and `planned` are separate keys and
// exactly ONE is ever populated, rather than one list plus a mode flag the
// caller has to remember to consult. Under --dry-run nothing is executed, so
// a reader (or a test) that looks at `installed` must get an EMPTY list — not
// a list of would-be work it has to re-interpret. An installer whose summary
// over-claims is worse than one with no summary at all: this whole module
// exists to refuse exactly that, and it was doing it under --dry-run.
//
// `skipped` and `manual` need no mode-awareness: every entry in them is a
// statement of fact ("you answered vault=none", "ollama not on PATH") that is
// equally true whether or not the install ran.
function buildSummary(answers, laneRows, opts) {
  const o = opts || {};
  const dryRun = Boolean(o.dryRun);
  const actions = [];
  const skipped = [];
  const manual = [];

  // CR round 8 [glm-r7-2]: the planned bucket must read as PLANNED throughout.
  // The plugin row already said "would be enabled" while the vault/handover
  // rows stayed in the past tense ("scaffolded", "upgraded"), so one preview
  // mixed both tenses and half of it read like completed work.
  const did = (past, future) => (dryRun ? future : past);

  // HIMMEL-2308: role died — profile/devOverlay are the two orthogonal axes
  // now (see bin.js's T2 comment above askQuestions()).
  const overlaySuffix = answers.devOverlay ? '+dev' : '';
  actions.push(dryRun
    ? `himmel (profile=${answers.profile}${overlaySuffix}, scope=${answers.scope}) — would run ${o.derived || 'the derived installer'}`
    : `himmel (profile=${answers.profile}${overlaySuffix}, scope=${answers.scope}) via ${o.derived || 'the derived installer'}`);

  // HIMMEL-2536: the git gate hooks, reported from what is actually on disk
  // after the installer ran (`o.gitHooks`, probed by bin.js's
  // gitGateHooksState()). adopt.sh WARNs and continues when it cannot install
  // pre-commit -- neither uv nor pipx present is the common stock-Linux case
  // (HIMMEL-2521) -- and that warning scrolls away, so the measured 2457 cell
  // ended with NO commit-msg hook, a garbage commit message landing at rc=0,
  // and this section printing `(nothing)`. An ungated repo whose installer
  // reports nothing was left undone is the worse of the two failures; this row
  // is the one artifact the adopter still has once the scrollback is gone.
  //
  // `null` (a --dry-run, where nothing ran) and `applicable:false` (the target
  // is not a git repo, which adopt.sh skips by design, not by failure) both
  // produce no row -- a preview must never claim a probe it did not perform.
  // CR round 1 [codex-2]: an UNVERIFIABLE hook state gets its own row rather
  // than being folded into either "placed" or "not a git repo". Saying nothing
  // because the probe failed is the same silence this section exists to end.
  if (o.gitHooks && o.gitHooks.applicable && o.gitHooks.verified === false) {
    manual.push({
      what: `git gate hooks — could NOT be verified (${o.gitHooks.reason}); treat this repo as possibly ungated until you have checked`,
      how: 'run `git rev-parse --git-path hooks` in this repo and confirm pre-commit, commit-msg and pre-push are executable files there',
      note: '',
    });
  } else if (o.gitHooks && o.gitHooks.applicable && o.gitHooks.verified && !o.gitHooks.placed) {
    manual.push({
      what: `git gate hooks — NOT placed (missing: ${o.gitHooks.missing.join(', ')}); commits in this repo are NOT gated`,
      how: 'install uv (see https://astral.sh/uv) or pipx, then re-run `himmelctl install` — adopt.sh installs pre-commit through whichever of the two it finds',
      note: 'derived from the hooks on disk after the install, not from adopt.sh\'s own warning line; a hook that is not an executable regular file counts as missing, because git would not run it either',
    });
  }

  // HIMMEL-2537: the dev overlay's setup.sh step [0.5/9] is advisory now — it
  // WARNs and continues on an unresolved USER_SLUG instead of aborting the
  // install. That abort was what used to make this row unnecessary: runPlan
  // returned on the overlay's rc=1 and no summary was printed at all. With the
  // install completing, the skipped step has to be named here or it is named
  // nowhere that outlives the scrollback — the same argument as the gitHooks
  // row above.
  //
  // `null` (dry-run, or an install with no dev overlay, where no step resolved
  // a slug) and `applicable:false` (win32, whose setup.ps1 has no such step)
  // both produce no row: a summary must not report on a check nobody ran.
  if (o.userSlug && o.userSlug.applicable && o.userSlug.verified === false) {
    manual.push({
      what: `USER_SLUG — could NOT be verified (${o.userSlug.reason}); treat it as unresolved until you have checked`,
      how: 'run `bash scripts/setup/check-user-slug.sh --dotenv-root .` in your himmel checkout — rc=0 prints the slug, rc=3 names the three ways to set one',
      note: '',
    });
  } else if (o.userSlug && o.userSlug.applicable && o.userSlug.verified && !o.userSlug.resolved) {
    manual.push({
      what: 'USER_SLUG — did NOT resolve; handover bucket paths, registry.json and scratch dir names cannot be derived until it does',
      how: 'set ONE of: USER_SLUG in your shell or .env, an authenticated forge CLI (`gh auth login`), or `git config --global user.name`',
      note: 'setup.sh no longer aborts on this (HIMMEL-2537) — no re-run is needed either, because every consumer resolves the slug at the moment it runs',
    });
  }

  const vaultMode = answers.vault && answers.vault.mode;
  const vaultPath = o.vaultPath || (answers.vault && answers.vault.path);
  if (vaultMode === 'default-template') {
    // CR round 8 [codex-adv-r7-3]: adopt.sh's do_luna() SKIPS the template copy
    // when the destination already exists, so "scaffolded" was asserted for
    // runs where nothing was copied. The row is now built from whether
    // scaffolding actually ran (`o.vaultScaffolded`); an occupied destination
    // that is not a stamped luna vault never reaches here at all — runPlan
    // refuses it before the shell-out.
    if (o.vaultScaffolded === false) {
      skipped.push(`luna vault — existing STAMPED vault reused at ${vaultPath}; no scaffolding ran (adopt.sh skips the copy when the destination exists)`);
    } else {
      actions.push(did(
        `luna vault scaffolded from templates/luna-second-brain -> ${vaultPath}`,
        `luna vault — would scaffold from templates/luna-second-brain -> ${vaultPath}`,
      ));
    }
  } else if (vaultMode === 'existing') {
    actions.push(did(
      `luna vault upgraded in place -> ${vaultPath}`,
      `luna vault — would upgrade in place -> ${vaultPath}`,
    ));
  } else {
    skipped.push('luna vault — you answered vault=none');
  }

  if (answers.handover && answers.handover.mode === 'external') {
    const hp = o.handoverPath || answers.handover.path;
    actions.push(did(
      `handover state -> ${hp} (HANDOVER_DIR)`,
      `handover state — would point HANDOVER_DIR at ${hp}`,
    ));
  } else {
    skipped.push('external handover state — you answered handover=inline (the repo-local default applies)');
  }

  // HIMMEL-2304: 'full' is a legacy-accepted --from-profile value (loadProfile
  // still validates it, for an old cache's backward compat) but its enable
  // step is GONE — applyPluginStep() is now unconditionally a no-op — so
  // there is nothing left to report as installed/failed for either answer.
  // Before this ticket, this branch read `pluginFailures`/`pluginTotal` off
  // the (now-always-trivial) applyPluginStep() result to print "full plugin
  // set enabled" or a partial-failure breakdown; keeping that machinery
  // around a step that can no longer run or fail would just be a new way to
  // fabricate "enabled" for work that never happened.
  if (answers.pluginSet === 'full') {
    skipped.push('full plugin set — this profile answers pluginSet=full, but that option was retired (HIMMEL-2304); no plugin-enable step ran');
  } else {
    skipped.push('full plugin set — you answered pluginSet=lean (the documented adopter default)');
  }

  for (const row of laneRows) {
    if (!row.selected) {
      const reason = row.optIn
        ? `opt-in lane, not requested (--with-${row.id})`
        : 'not selected';
      skipped.push(`lane ${row.id} — ${reason}`);
      continue;
    }
    if (row.state === 'present') {
      // A present lane is a FACT, never an action — himmelctl installs no
      // lane CLI in v1, so listing it as work would misreport under an
      // applied run and self-contradict under a "would install" heading.
      skipped.push(`lane ${row.id} — binary already present (${row.detail}), nothing to install`);
      // ...but "the binary exists" is not "the lane works". Anything the
      // probe did not establish stays visible as a remaining step, phrased
      // as verify/complete rather than install (CR round 4 [codex-adv-r3-2]).
      if (row.setupState === 'incomplete') {
        manual.push({
          what: `lane ${row.id} — installed but setup INCOMPLETE (${row.setupDetail})`,
          how: row.note,
          note: 'the CLI is present; this is the remaining setup, not a reinstall',
        });
      } else if (row.setupState !== 'ready' && row.note) {
        // The notes are written to follow an install command ("then ..."), so
        // drop that lead-in when the step stands alone as a verify item.
        manual.push({
          what: `lane ${row.id} — binary present, but this probe cannot confirm setup (auth/model/config)`,
          how: `verify: ${row.note.replace(/^then /, '')}`,
          note: '',
        });
      }
    } else if (row.state === 'misconfigured') {
      // Install command RETAINED: the lane genuinely is not installed, and the
      // bogus override must not cost the adopter the one line that fixes that.
      // CR round 9 [codex-adv-r8-2]: the SETUP note is retained too, ordered
      // after the remediation. Round 7 guaranteed the platform-specific setup
      // step survives; the overlay branches were dropping it, so a forced-on
      // absent ollama got install + override repair and never heard about the
      // model pull. Remediation first, then what to do once it is installed.
      manual.push({
        what: `lane ${row.id} — ${row.detail}`,
        how: row.hint,
        note: [
          `the local overlay forces this lane on without it being installed — install it, or clear the override: node scripts/himmelctl/bin.js config set lanes.${row.registryId} off`,
        ].concat(row.note ? [`then complete setup: ${row.note.replace(/^then /, '')}`] : []),
      });
    } else if (row.state === 'disabled') {
      // Installed but switched off locally: the fix is a config flip, NOT a
      // reinstall, so it gets its own entry with the exact re-enable command.
      manual.push({
        what: `lane ${row.id} — ${row.detail}`,
        how: `node scripts/himmelctl/bin.js config set lanes.${row.registryId} on`,
        // CR round 9 [codex-adv-r8-2]: re-enabling is only half the story — a
        // disabled copilot still needs its device-flow login once it is back
        // on. Remediation first, then the setup step round 7 promised to keep.
        note: ['nothing to install — the CLI is present, the local overlay turns the lane off']
          .concat(row.note ? [`once re-enabled, confirm setup: ${row.note.replace(/^then /, '')}`] : []),
      });
    } else if (row.state === 'absent') {
      // Ordered follow-ups: the install command is `how`; an overlay blocker
      // (CR round 11 [codex-r10-1]) comes next because the lane stays
      // unusable until it is cleared; the setup step last (round 7/9).
      manual.push({
        what: `lane ${row.id} — ${row.detail}`,
        how: row.hint,
        note: (row.overlayFix ? [row.overlayFix] : [])
          .concat(row.note ? [`then complete setup: ${row.note.replace(/^then /, '')}`] : []),
      });
    } else {
      manual.push({ what: `lane ${row.id} — could not be probed: ${row.detail}`, how: row.hint, note: row.note });
    }
  }

  // HIMMEL-2303: disclose the RESULTING cross-model CR floor from the final
  // lane selection — regardless of how it was set (interactive prompt,
  // --lanes flag, --with-codex/--with-hermes, or a replayed --from-profile).
  // A fact, not an action: lands in `skipped`, equally true before/after the
  // install, same as the other "you answered X" entries in this bucket.
  //
  // CR round 1 [codex-2]: opting in is not the same as the lane actually
  // being usable — `selected` only means the operator asked for it; a lane
  // whose probe found it absent/misconfigured/disabled can't run a review
  // either, so claiming "satisfied" off `selected` alone would falsely
  // report the floor met for a lane that cannot review anything. Require
  // `state === 'present'` (the same bar the rest of this summary treats as
  // "the binary is actually there") before calling the floor satisfied.
  //
  // CR round 2 [codex-1]: checking only the FIRST opted-in lane meant that
  // with BOTH codex and hermes opted in, an absent codex (V1_LANES order
  // puts it first) reported the floor unsatisfied even when hermes was
  // present and would have satisfied it. Check every opted-in lane for one
  // that is actually present; only fall back to the first opted-in lane's
  // own not-available detail when NONE of them are.
  const optedInLanes = laneRows.filter((row) => row.optIn && row.selected);
  const readyLane = optedInLanes.find((row) => row.state === 'present');
  const firstOptedInLane = optedInLanes[0];
  skipped.push(readyLane
    ? `cross-model CR floor — satisfied (${readyLane.id} opted in and present): the review panel is not Claude-only`
    : firstOptedInLane
      ? `cross-model CR floor — NOT satisfied yet: ${firstOptedInLane.id} opted in but not available (${firstOptedInLane.detail}) — install/configure it (see the lane row above); see docs/configuration.md CR_REQUIRE_CROSS_MODEL`
      : 'cross-model CR floor — NOT satisfied: no codex/hermes opt-in, so the /pr-check review panel runs Claude-only (opt in via the lanes question, --with-codex, or --with-hermes; see docs/configuration.md CR_REQUIRE_CROSS_MODEL)');

  if (answers.alwaysOn) {
    manual.push({ what: 'always-on machine hardening', how: 'run the checklist printed above (himmelctl executed none of it)', note: '' });
  }

  // ── HIMMEL-2176 Task 8: luna cadence / PHI / secrets walk / bridge ────────
  // `answers.luna`/`answers.secretsWalk`/`answers.bridge` are undefined on a
  // pre-Task-8 legacy --from-profile cache (loadProfile treats the whole
  // section as optional for backward compat) — default to the same "off"
  // shape bin.js's own buildAnswers() falls back to, so this never throws on
  // an old profile.
  //
  // RETASK stage1-build-6d2e round 3 [coordinator ruling on codex-1]: an
  // untouched section (no luna key at all — bin.js's applyLunaSectionsStep
  // deliberately left the on-disk value alone) is a DIFFERENT fact from "the
  // operator answered off", and this summary's whole purpose is to never say
  // something false to the adopter. Saying "you answered cadence=off" for a
  // legacy-profile replay that PRESERVED an already-armed cadence would be
  // exactly backwards. `lunaSupplied`/`bridgeSupplied` key a third,
  // untouched-specific wording, distinct from the explicit-off skip text —
  // both still land in `skipped` (never `installed`), which was already the
  // safety-relevant half; this is the honesty half.
  // CR fix (HIMMEL-2176): a --dry-run whose ~/.himmel/config.json could not
  // be read (bin.js's previewLunaSections sets this) is the SAME refusal
  // applyLunaSectionsStep performs for real on a load failure — it returns
  // before touching cadence/PHI/secrets/bridge at all, so this summary must
  // not claim any of that as `planned` either, regardless of what the
  // profile answered.
  const configLoadFailed = Boolean(o.configLoadFailed);
  // HIMMEL-2302 fix: keyed on `phiDeclared` specifically, mirroring bin.js's
  // own lunaSectionSupplied() — see its comment for why bare `luna !==
  // undefined` is no longer sufficient once a vault=none run can build a
  // partial `luna = { disarmCadence }` with no PHI answer in it.
  const lunaSupplied = Boolean(answers.luna) && typeof answers.luna.phiDeclared === 'boolean';
  const luna = answers.luna || { cadenceEnabled: false, phiDeclared: false };
  if (configLoadFailed) {
    skipped.push('luna cadence — ~/.himmel/config.json could not be read (see the WARN line above); left untouched');
    skipped.push('PHI checklist — ~/.himmel/config.json could not be read (see the WARN line above); left untouched');
    // CR round 1 [HIMMEL-2302 Fix 2]: this branch used to return here,
    // reporting only the two legacy lines above and never reaching the
    // per-unit loop in the `else` branch below — a profile that requested
    // qmd/graphmap/codex-sweep arming lost those rows entirely on a
    // config-load failure, silently dropping the request from the summary
    // instead of honestly saying it was not armed. `pipeline` is excluded:
    // the legacy "luna cadence" line above already covers it (same
    // load-failure fact, same wording family), so it would otherwise appear
    // twice.
    const dispositionsOnFailure = resolveCadenceDispositions(answers);
    for (const row of CADENCE_REGISTRY) {
      if (row.id === 'pipeline') continue;
      if (dispositionsOnFailure[row.id] === 'armed') {
        skipped.push(`${row.label} cadence — requested but not armed: ~/.himmel/config.json could not be read (see the WARN line above); left untouched`);
      }
    }
  } else {
    // HIMMEL-2302: per-cadence dispositions replace the old single
    // luna.cadenceEnabled boolean — resolveCadenceDispositions() (shared
    // with bin.js, see its own comment above) covers both a fresh top-level
    // `cadences` section (authoritative) and a legacy profile that only
    // ever carried `luna.cadenceEnabled` (derives pipeline only). An id
    // absent from the result was never asked this run (a row filtered out
    // by the codex-lane gate, or every unit but pipeline on a legacy
    // profile) — distinct from "asked and declined", never conflated.
    const dispositions = resolveCadenceDispositions(answers);
    if (Object.keys(dispositions).length === 0) {
      skipped.push('luna cadence — left as-is (the profile carries no luna section)');
    } else {
      const armResults = o.cadenceResults || {};
      const disarmResults = o.cadenceDisarmResults || {};
      for (const row of CADENCE_REGISTRY) {
        const disp = dispositions[row.id];
        const isPipeline = row.id === 'pipeline';
        const label = isPipeline ? 'luna cadence' : `${row.label} cadence`;
        const scriptFull = row.script;
        const scriptBase = path.basename(scriptFull);
        if (disp === undefined) {
          skipped.push(`${label} — never asked this run (requires ${row.requires}); left as-is`);
          continue;
        }
        if (disp === 'armed') {
          const arm = armResults[row.id];
          if (arm && arm.ran) {
            if (arm.rc === 0) {
              actions.push(did(
                `${label} armed — ${arm.argvDisplay}`,
                `${label} — would arm: ${arm.argvDisplay}`,
              ));
            } else {
              manual.push({
                what: `${label} — ${scriptBase} arm exited rc=${arm.rc}`,
                how: `re-run \`himmelctl install --from-profile <cache>\` to retry, or run ${scriptBase} by hand`,
                note: arm.argvDisplay,
              });
            }
          } else if (arm) {
            // RETASK stage1-build-6d2e round 6 [codex-1 enumeration]: `arm`
            // IS present but `arm.ran` is false — bin.js sets exactly this
            // shape when building the flags/spawning the command THREW
            // mid-step (arm.argvDisplay carries the thrown message in that
            // case), a DIFFERENT fact from "the step was never reached at
            // all" (the `else` branch below). Distinct wording either way
            // lands in manual, never installed.
            manual.push({
              what: `${label} — the arm step threw before it could run: ${arm.argvDisplay}`,
              how: 're-run `himmelctl install --from-profile <cache>` once the underlying issue is resolved',
              note: '',
            });
          } else if (dryRun) {
            actions.push(`${label} — would arm via ${scriptBase}`);
          } else {
            // RETASK stage1-build-6d2e round 5 [codex-1]: the arm step
            // never reporting a result under an APPLIED run (a config save
            // failure upstream skipped it, or any other reason) is NOT
            // "installed" — `actions` renders under `installed:`, the one
            // bucket this whole design promises never overclaims — so this
            // belongs in `manual`, same as every other "declared but never
            // ran" shape below.
            manual.push({
              what: `${label} — you answered ${isPipeline ? 'cadence=on' : 'armed'}, but the arm step never ran (see the WARN lines above for why — most likely a config save failure) — treat ${isPipeline ? 'cadence' : label} as NOT armed`,
              how: 're-run `himmelctl install --from-profile <cache>` once the earlier issue is resolved',
              note: '',
            });
          }
        } else {
          skipped.push(isPipeline ? 'luna cadence — you answered cadence=off' : `${label} — you answered off`);
          // RETASK stage1-build-6d2e round 4 [codex-1] (extended HIMMEL-2302
          // to every unit): answering off writes the disposition but does
          // NOT by itself touch the scheduler — spec §3.5 S1 explicitly
          // anticipates enabled:false + tasks-still-present as a WARN
          // ("unmanaged leftovers"), not a forbidden state, so disarming is
          // its own consented step (mirrors bridge persistence below),
          // never silent. Declined/not-applicable (a legacy --from-profile
          // that never answered the question) both land here: name the
          // exact command so the adopter is told their existing jobs may
          // still be armed, rather than silently assuming "off" already
          // took effect.
          const disarm = disarmResults[row.id];
          if (luna.disarmCadence && disarm && disarm.ran) {
            if (disarm.rc === 0) {
              actions.push(did(
                `${label} disarmed — ${disarm.argvDisplay}`,
                `${label} — would disarm: ${disarm.argvDisplay}`,
              ));
            } else {
              manual.push({
                what: `${label} disarm — ${scriptBase} disarm exited rc=${disarm.rc}`,
                how: `re-run \`himmelctl install --from-profile <cache>\` to retry, or run ${scriptBase} disarm by hand`,
                note: disarm.argvDisplay,
              });
            }
          } else if (luna.disarmCadence && disarm) {
            // RETASK stage1-build-6d2e round 6 [codex-1 enumeration]:
            // `disarm` present but `disarm.ran` false — the disarm attempt
            // THREW mid-step (same shape/distinction as the arm branch
            // above), not "never reached". Still manual either way (never
            // claim success).
            manual.push({
              what: `${label} — the disarm step threw before it could run: ${disarm.argvDisplay}`,
              how: `re-run \`himmelctl install --from-profile <cache>\` once the underlying issue is resolved, or run ${scriptBase} disarm by hand`,
              note: '',
            });
          } else if (luna.disarmCadence && dryRun) {
            // RETASK stage1-build-6d2e round 6 [codex-1 enumeration]: a
            // --dry-run "would disarm" is a PLANNED action, same bucket as
            // the arm branch's own dry-run case a few lines up and
            // bridge-persistence's dry-run case below — it belongs in
            // `actions`/`planned`, not `manual`.
            actions.push(`${label} — would disarm via ${scriptBase} (see the DRY line above)`);
          } else if (luna.disarmCadence) {
            // Consent was given but the step never reported at all under an
            // APPLIED run (most likely gated off by a config-save failure
            // upstream) — never silently claim it happened.
            manual.push({
              what: `${label} disarm was requested, but the step reported no result (treat any existing jobs as still armed)`,
              how: `${scriptFull} disarm`,
              note: '',
            });
          } else {
            manual.push({
              what: `${label} — you answered ${isPipeline ? 'cadence=off' : 'off'}, but any PREVIOUSLY ARMED jobs are still armed and will keep firing (himmelctl never auto-disarms)`,
              how: `${scriptFull} disarm`,
              note: '',
            });
          }
        }
      }
    }

    if (!lunaSupplied) {
      skipped.push('PHI checklist — left as-is (the profile carries no luna section)');
    } else if (luna.phiDeclared) {
      // RETASK stage1-build-6d2e round 6 [codex-2 enumeration]: this "himmelctl
      // records..." claim is a config-document write, same as bridge config
      // below — false under an APPLIED run whose save() failed (o.configSaveOk
      // === false is the only "failed" signal; undefined, e.g. under --dry-run
      // where save() never runs, and true both mean "not gated").
      manual.push(o.configSaveOk === false ? {
        what: 'PHI declaration requested, but the config save failed — luna.phi.declared may NOT have been recorded (see the WARN lines above)',
        how: 're-run `himmelctl install --from-profile <cache>` once the earlier issue is resolved',
        note: '',
      } : {
        what: 'PHI trust markers (.salus / phi-roots / egress-denylist)',
        how: 'you declared this vault handles PHI — himmelctl records that answer at luna.phi.declared but never creates these files itself; that stays on you',
        note: '',
      });
    } else {
      skipped.push('PHI checklist — you answered no (this vault is not declared PHI)');
    }
  }

  // RETASK stage1-build-6d2e round 9 [codex-1 follow-up]: same "left as-is"
  // vs "you answered X=skip" distinction as luna/bridge above, now that
  // round 8's fix makes `answers.secretsWalk` genuinely undefined (not a
  // manufactured 'skip') when the question was never asked (vaultMode=='none'
  // or contributor role) — before that fix this branch was unreachable
  // (secretsWalk was always at least the string 'skip'), which is why it was
  // left. No data-loss risk here (the walk is pure reporting, never a
  // write) — this is the same false-statement class the wording fix is
  // still worth making for.
  const secretsWalkSupplied = answers.secretsWalk !== undefined && answers.secretsWalk !== null;
  const secretsWalk = answers.secretsWalk || 'skip';
  if (configLoadFailed) {
    skipped.push('secrets walk — ~/.himmel/config.json could not be read (see the WARN line above); not run');
  } else if (!secretsWalkSupplied) {
    skipped.push('secrets walk — left as-is (the profile carries no secretsWalk section)');
  } else if (secretsWalk === 'run') {
    const results = o.secretsWalkResults || [];
    for (const r of results) {
      if (r.status === 'configured') {
        actions.push(did(
          `secret ${r.name} — probe confirmed configured (${r.detail})`,
          `secret ${r.name} — would probe once you configure it (${r.detail})`,
        ));
      } else if (r.status === 'degraded') {
        manual.push({ what: `secret ${r.name} — configured but the probe flagged a problem (${r.detail})`, how: r.obtain, note: '' });
      } else if (r.status === 'error') {
        // RETASK stage1-build-6d2e round 6 [codex-3]: the probe itself threw
        // (our code, not the credential) — a DIFFERENT fact from "configured
        // but unhealthy" (that phrasing presumes we know it's configured) AND
        // from 'unconfigured' (which tells the adopter to go set up something
        // that may already BE set up). Its own wording: we don't know, go
        // look at why the probe broke.
        manual.push({ what: `secret ${r.name} — probe error, could not determine status (${r.detail})`, how: 'investigate the probe failure above, then re-run install to re-check', note: '' });
      } else {
        // 'unconfigured' — the adopter simply has not set this one up yet
        // (or, for a luna-sources-typed entry, the wizard has no per-source
        // descriptor to actively probe — see the apply-step comment). Either
        // way this is a normal skip, never an error (design A15).
        //
        // RETASK stage1-build-6d2e round 10 [codex-1]: a paired credential
        // (BITBUCKET_EMAIL/BITBUCKET_API_TOKEN, TWITTER_AUTH_TOKEN/
        // TWITTER_CT0) shares ONE aggregate luna-sources probe with its
        // sibling — the probe can only speak for the source as a whole, so
        // 'unconfigured' here does NOT mean THIS credential specifically is
        // the one missing; it could just as easily be the sibling. Naming
        // only this one would send an adopter who already set IT correctly
        // on a wasted trip to "fix" something that isn't broken — never
        // invent a per-credential verdict the probe has no evidence for;
        // just say honestly that it can't tell the pair apart.
        const manifestEntry = SECRETS_MANIFEST.secrets.find((s) => s.name === r.name);
        const pairedWith = manifestEntry && manifestEntry.pairedWith;
        skipped.push((pairedWith && pairedWith.length > 0)
          ? `secret ${r.name} — unconfigured: paired with ${pairedWith.join(', ')} (one shared probe covers both — either credential may be the one missing, the probe cannot tell them apart). ${r.obtain}`
          : `secret ${r.name} — unconfigured: ${r.obtain}`);
      }
    }
    if (results.length === 0) {
      // RETASK stage1-build-6d2e round 5 [codex-1]: same "declared but never
      // ran" shape as cadence-arm/bridge-persistence above — SECRETS_MANIFEST
      // always has entries, so this is unreachable in a normal apply run
      // today, but "never actually happens yet" is not a reason to let an
      // APPLIED run's `installed:` bucket claim a walk that reported nothing.
      if (dryRun) {
        actions.push('secrets walk — would show the instruction card + probe for each secret');
      } else {
        manual.push({ what: 'secrets walk requested, but it reported no results — treat as NOT run', how: 're-run `himmelctl install --from-profile <cache>`', note: '' });
      }
    }
  } else {
    skipped.push('secrets walk — you answered secretsWalk=skip');
  }

  const bridgeSupplied = answers.bridge !== undefined && answers.bridge !== null;
  const bridge = answers.bridge || { enabled: false };
  if (configLoadFailed) {
    skipped.push('telegram bridge — ~/.himmel/config.json could not be read (see the WARN line above); left untouched');
  } else if (!bridgeSupplied) {
    skipped.push('telegram bridge — left as-is (the profile carries no bridge section)');
  } else if (bridge.enabled) {
    // RETASK stage1-build-6d2e round 6 [codex-2]: this claimed a config-
    // document write (bridge.envPath/whisper.*) UNCONDITIONALLY under
    // installed:, even when the save() that was supposed to persist it had
    // already failed (o.configSaveOk === false) — the exact same "declared
    // but never happened" defect already fixed for cadence/persistence,
    // arriving from a fourth direction. `undefined` (e.g. --dry-run, where
    // save() never runs at all) is NOT a failure signal — only an explicit
    // `false` gates this.
    if (o.configSaveOk === false) {
      manual.push({
        what: `telegram bridge config — NOT written (config save failed; see the WARN lines above): envPath=${bridge.envPath}, whisper.cli=${bridge.whisperCli || '(default)'}, whisper.model=${bridge.whisperModel}`,
        how: 're-run `himmelctl install --from-profile <cache>` once the earlier issue is resolved',
        note: '',
      });
    } else {
      actions.push(did(
        `telegram bridge config -> envPath=${bridge.envPath}, whisper.cli=${bridge.whisperCli || '(default)'}, whisper.model=${bridge.whisperModel}`,
        `telegram bridge config — would write envPath=${bridge.envPath}, whisper.cli=${bridge.whisperCli || '(default)'}, whisper.model=${bridge.whisperModel}`,
      ));
    }
    const probes = o.bridgeProbes || {};
    for (const key of ['whisperReady', 'pythonInterpreter', 'distinctTokens']) {
      const r = probes[key];
      if (!r) continue;
      if (r.actual === 'present') {
        skipped.push(`bridge probe ${key} — already ready (${r.detail})`);
      } else {
        manual.push({ what: `bridge probe ${key} — ${r.actual} (${r.detail})`, how: 'resolve, then re-run install/status to re-check', note: '' });
      }
    }
    if (bridge.installPersistence) {
      const p = o.bridgePersistence;
      if (p) {
        if (p.ok) {
          actions.push(did(
            `bridge persistence installed — ${p.detail}`,
            `bridge persistence — would install: ${(p.actions || []).join('; ')}`,
          ));
        } else if (p.skipped) {
          // RETASK stage1-build-6d2e round 3 [coordinator ruling on
          // codex-2]: a deliberate skip (readiness probes not green) is the
          // DESIGNED behaviour, not a failure — rc stays 0 for this case
          // (bin.js) and the wording here must say so plainly, distinct from
          // an installer that actually ran and failed.
          // RETASK stage1-build-6d2e round 4: `p.skipped` now covers TWO
          // distinct deliberate-skip reasons (probes not ready [codex-2] AND
          // a config save failure upstream [codex-3]) — the wording stays
          // generic and lets `p.detail` (bin.js's own, reason-specific text)
          // say which, rather than hardcoding one reason into both.
          manual.push({ what: `bridge persistence — SKIPPED: ${p.detail}`, how: 're-run install once the issue above is resolved', note: '' });
        } else if (p.partial) {
          // RETASK stage1-build-6d2e round 6 [codex-4]: Linux unit
          // install+start succeeded but linger did not — a DIFFERENT fact
          // from "nothing was installed" (the else branch below), and
          // "NOT installed" would be false for the half that worked. No
          // automatic rollback (bin.js's own ruling: unwinding machine state
          // on a partial failure is its own risk) — report the partial
          // state honestly, with the exact remediation command (already
          // embedded in p.detail by attemptBridgePersistence).
          manual.push({ what: `bridge persistence PARTIAL — ${p.detail}`, how: 'run the remediation command above, then re-run install/status to confirm', note: '' });
        } else {
          manual.push({ what: `bridge persistence NOT installed — ${p.detail}`, how: (p.actions || []).join('; ') || 'see docs/setup', note: '' });
        }
      } else if (dryRun) {
        // RETASK stage1-build-6d2e round 10 [codex-2] / later CR finding:
        // platform-branch the wording via the ONE shared decision
        // (bridgePersistenceArtifact() above), the same source bin.js's
        // consent prompt now reads too — --dry-run is the one surface whose
        // entire job is describing what has not happened yet, and a
        // platform with no installer at all must say so rather than
        // claiming an install that could never happen.
        const artifact = bridgePersistenceArtifact();
        if (artifact) {
          actions.push(`bridge persistence — would install (${artifact})`);
        } else {
          manual.push({
            what: `bridge persistence — not supported on this platform (${process.platform}); nothing would be installed`,
            how: 'install/enable it manually (see docs/setup)',
            note: '',
          });
        }
      } else {
        // RETASK stage1-build-6d2e round 5 [codex-1]: same "declared but
        // never ran" shape as the cadence-arm fix above — an APPLIED run
        // where the step reported nothing is not "installed"; belongs under
        // still-manual, never actions/installed.
        manual.push({
          what: 'bridge persistence requested, but the install step never ran — treat persistence as NOT installed',
          how: 're-run `himmelctl install --from-profile <cache>` once the earlier issue is resolved',
          note: '',
        });
      }
    } else {
      skipped.push('bridge persistence — you answered installPersistence=no');
    }
  } else {
    skipped.push('telegram bridge — you answered bridge=off');
  }

  return {
    dryRun: dryRun,
    installed: dryRun ? [] : actions,
    planned: dryRun ? actions : [],
    skipped: skipped,
    manual: manual,
  };
}

function summaryLines(summary) {
  const lines = [];
  lines.push('');
  lines.push('── install summary ─────────────────────────────────────────────────');
  lines.push('');
  // The heading tracks the bucket: an applied run says `installed:`, a
  // --dry-run says so in the heading itself, so the word "installed" never
  // appears above a list of things that were not installed.
  const actions = summary.dryRun ? summary.planned : summary.installed;
  lines.push(summary.dryRun
    ? 'would install (--dry-run — NOTHING below was executed):'
    : 'installed:');
  if (actions.length === 0) lines.push('  (nothing)');
  for (const s of actions) lines.push(`  + ${s}`);
  lines.push('');
  lines.push('skipped:');
  if (summary.skipped.length === 0) lines.push('  (nothing)');
  for (const s of summary.skipped) lines.push(`  - ${s}`);
  lines.push('');
  lines.push(summary.dryRun
    ? 'still manual — himmelctl would NOT do these either:'
    : 'still manual — himmelctl did NOT do these:');
  if (summary.manual.length === 0) lines.push('  (nothing)');
  for (const m of summary.manual) {
    lines.push(`  ! ${m.what}`);
    if (m.how) lines.push(`      ${m.how}`);
    // `note` is one line or an ORDERED list of them (remediation, then the
    // setup step it unblocks) — CR round 9 [codex-adv-r8-2].
    for (const n of (Array.isArray(m.note) ? m.note : [m.note])) {
      if (n) lines.push(`      ${n}`);
    }
  }
  lines.push('');
  return lines;
}

module.exports = {
  V1_LANES,
  ALL_LANE_IDS,
  DEFAULT_LANE_IDS,
  OPT_IN_LANE_IDS,
  SELECTABLE_LANE_IDS,
  DORMANT_LANE_HINTS,
  LANE_HELP,
  laneCrossModelDisclosureLines,
  laneById,
  installHint,
  setupNote,
  loadLaneProbe,
  // Exported for the drift test only (CR round 11 [glm-r10-3]): this constant
  // hand-tracks evalProbe's switch in scripts/lanes/probe.mjs, which exports
  // no equivalent set, so the suite compares the two and fails if probe.mjs
  // grows or loses a kind.
  EVALUABLE_PROBE_KINDS,
  parseLaneList,
  applyOptIns,
  registryIdsForSelection,
  preflightProfileLaneAllowlist,
  persistProfileLaneAllowlist,
  probeLane,
  probeSelection,
  HARDENING_CHECKLIST,
  hardeningChecklistLines,
  hardeningPointerLines,
  hardeningNotAskedLines,
  phiChecklistLines,
  bridgePersistenceArtifact,
  buildSummary,
  summaryLines,
  CADENCE_REGISTRY,
  resolveCadenceDispositions,
  FEATURE_IDS,
  resolveActiveFeatures,
};
