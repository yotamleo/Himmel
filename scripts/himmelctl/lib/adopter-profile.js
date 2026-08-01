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
// Everything here is NON-MUTATING: it writes nothing, installs nothing, and
// changes no machine state, which is what lets the hermetic suite exercise the
// whole surface on a machine where none of the lane CLIs are installed.
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

// ── the v1 lane subset ──────────────────────────────────────────────────────
//
// `id` is the himmelctl-facing short name (what the operator types).
// `registryId` names the scripts/lanes/lanes.json lane whose probe decides
// availability — the registry stays the single source of truth for HOW a lane
// is detected, so this table never grows a second detection heuristic.
// `optIn: true` lanes are NEVER selected by default (rescope: codex/hermes are
// strictly opt-in) — they are reachable only via their explicit flag.
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
    id: 'ollama',
    registryId: 'ollama-local',
    optIn: false,
    install: {
      win32: 'winget install Ollama.Ollama',
      darwin: 'brew install ollama',
      default: 'see https://ollama.com/download',
    },
    note: { default: 'then `ollama pull qwen2.5-coder:7b` (multi-GB — run it detached)' },
  },
  {
    id: 'copilot',
    registryId: 'copilot-cli',
    optIn: false,
    install: {
      win32: 'winget install GitHub.Copilot',
      default: 'npm install -g @github/copilot',
    },
    note: { default: 'then run `copilot` once for the GitHub device-flow login (per-machine, not portable)' },
  },
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
      win32: 'then `powershell -File scripts/codex/install-himmel-codex.ps1`; auth lives in ~/.codex/auth.json',
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
      win32: 'then `powershell -File scripts/hermes/install-himmel-profile.ps1`. Do NOT auto-start the gateway — same-token platform pollers conflict across machines',
      default: 'then `bash scripts/hermes/install-himmel-profile.sh`. Do NOT auto-start the gateway — same-token platform pollers conflict across machines',
    },
  },
];

const ALL_LANE_IDS = V1_LANES.map((l) => l.id);
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
function parseLaneList(csv) {
  const raw = String(csv == null ? '' : csv).trim();
  if (raw === 'none') return { ok: true, lanes: [] };
  const parts = raw.split(',').map((s) => s.trim()).filter((s) => s !== '');
  if (parts.length === 0) {
    return { ok: false, error: `empty lane list — use 'none' to select no lanes (known: ${SELECTABLE_LANE_IDS.join(', ')})` };
  }
  const out = [];
  for (const p of parts) {
    if (SELECTABLE_LANE_IDS.indexOf(p) === -1) {
      const optIn = OPT_IN_LANE_IDS.indexOf(p) !== -1;
      const hint = optIn
        ? `lane '${p}' is opt-in — select it with --with-${p}, not --lanes`
        : `unknown lane '${p}' (known: ${SELECTABLE_LANE_IDS.join(', ')}, or 'none')`;
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
// DEFERRED (HIMMEL-1428) — ENFORCEMENT only. These rows now READ the same
// merged configuration the resolver does (base lanes.json + lanes.local.json),
// so what they report matches what `/lanes` reports; that accuracy half was
// CR round 2 [codex-adv-r2-1]. What is still deferred is the other direction:
// the adopter's selection is not consumed as an ALLOWLIST, so a lane they did
// not select still resolves as available to the delegation machinery.
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
      'Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -RemoteAddress 192.168.1.0/24',
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

  actions.push(dryRun
    ? `himmel (role=${answers.role}, scope=${answers.scope}) — would run ${o.derived || 'the derived installer'}`
    : `himmel (role=${answers.role}, scope=${answers.scope}) via ${o.derived || 'the derived installer'}`);

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

  // CR round 1 [codex-adv-2]: the plugin step's failures used to be dropped
  // on the floor here — this keyed on pluginSet alone, so a run where plugin
  // commands FAILED still printed "full plugin set enabled" while exiting
  // nonzero. The summary now reports what the step actually achieved.
  // `pluginFailures` absent (dry-run, or a lean answer) means the step never
  // ran, which is not the same as it having succeeded.
  if (answers.pluginSet === 'full') {
    // CR round 2 [codex-r2-1 / glm-r2-3]: `null` (the step never ran — a
    // dry-run) and `[]` (it ran and everything succeeded) are DIFFERENT facts,
    // and the old `|| []` coerced the first into the second, so a preview
    // reported the past-tense "full plugin set enabled" for work it had not
    // done. Keep them distinct and phrase the un-run case as planned work.
    const ran = Array.isArray(o.pluginFailures);
    const failed = ran ? o.pluginFailures : [];
    const total = typeof o.pluginTotal === 'number' ? o.pluginTotal : 0;
    if (!ran) {
      // Only reachable under --dry-run today (both applied call sites pass a
      // result), but an APPLIED run must never print "would be enabled" in the
      // installed bucket — say plainly that the step did not report instead.
      actions.push(dryRun
        ? 'full plugin set (would be enabled)'
        : 'full plugin set — enable step reported no result (treat as unverified)');
    } else if (failed.length === 0) {
      actions.push('full plugin set enabled');
    } else {
      const ok = Math.max(total - failed.length, 0);
      if (ok > 0) actions.push(`plugin set — ${ok} of ${total} plugin command(s) succeeded`);
      manual.push({
        what: `plugin set — ${failed.length} of ${total} plugin command(s) FAILED`,
        how: 're-run `himmelctl install` to retry (the enable step is idempotent)',
        note: failed.join(' | '),
      });
    }
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

  if (answers.alwaysOn) {
    manual.push({ what: 'always-on machine hardening', how: 'run the checklist printed above (himmelctl executed none of it)', note: '' });
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
  probeLane,
  probeSelection,
  HARDENING_CHECKLIST,
  hardeningChecklistLines,
  hardeningPointerLines,
  buildSummary,
  summaryLines,
};
