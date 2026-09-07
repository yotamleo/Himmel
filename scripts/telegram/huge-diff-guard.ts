// scripts/telegram/huge-diff-guard.ts — the huge-diff lane guard (HIMMEL-1778).
//
// Live incident (2026-08): two consecutive claudex dispatches died before
// editing a single file with "Prompt is too long · automatic compaction
// failed: summarization produced empty response". Root cause: the target
// branch had regenerated the TRACKED, generated artifact
// graphify-out/graph.json (~15 MB / ~430k lines), so a worker orienting
// itself with `git diff main` ingested ~408k diff lines and blew its context
// window. The error named nothing useful, so the first diagnosis ("the brief
// is too dense") was wrong and cost a second failed dispatch to disprove.
//
// The .gitattributes `-diff` entries (PR #1686, same ticket) already make git
// report the two graph artifacts as `Bin` instead of hundreds of thousands of
// diff lines — but they only protect a worktree whose TREE carries the entry:
// a branch that predates #1686 and regenerated the graph still explodes when
// ITS worktree runs `git diff main`, and a huge non-artifact file regenerates
// the same failure class on any repo. This guard is the lane-boundary
// backstop: name the dominating file BY NAME and its share, before the worker
// launches, so the next misdiagnosis has the actual cause in the dispatch log.
//
// WARN-ONLY and FAIL-OPEN by design: a legitimately large branch must still
// dispatch (HIMMEL-1788 — unattended runs fail LOUD, never block); the guard
// only makes the hazard visible. A probe that cannot evaluate (no default-
// branch ref, broken git, a synthetic test repo) stays SILENT — a missing
// base ref is an expected condition in a fresh clone, and a guard that cries
// wolf on every normal dispatch gets ignored.
//
// Shared seam (the defect class this repo keeps re-learning): ONE predicate
// in this module, imported by both spawn-glm.ts and spawn-claudex.ts — never
// copy-pasted into the two spawners (the moonshot fence bypass, PR #1680, and
// the openrouter first-match-wins bug, #1691, were both a predicate written
// twice and drifting).

// Thresholds, named once (round-guard convention: a number stated in a
// comment drifts from the code — the code is the only home).
// A path "dominates" when BOTH hold:
//   - it is >= HUGE_DIFF_SHARE of the branch's changed-path bytes, and
//   - it is >= HUGE_DIFF_MIN_BYTES in absolute size.
// The byte floor keeps the warning off small branches whose single touched
// file is trivially 100% of the diff; the share keeps it off genuinely large
// multi-file work. The incident file was ~15 MB at ~99% of its branch.
export const HUGE_DIFF_SHARE = 0.9;
export const HUGE_DIFF_MIN_BYTES = 1 << 20; // 1 MiB

// Injected so tests can drive the decision table without git; the real impl
// is a plain spawnSync (mirrors planSharedSpawn's git probes).
export type GitProbe = (args: string[], cwd: string) => { code: number; stdout: string; stderr: string };

export function gitProbe(args: string[], cwd: string): { code: number; stdout: string; stderr: string } {
  const r = Bun.spawnSync(["git", "-C", cwd, ...args], { stdout: "pipe", stderr: "pipe" });
  return { code: r.exitCode ?? -1, stdout: r.stdout.toString(), stderr: r.stderr.toString() };
}

// The metric is changed-path BYTES (ls-tree blob sizes), not diff LINE
// counts, on purpose: `git diff --numstat` collapses a `-diff`-marked file to
// `- -` (binary), so a line-share probe run from a checkout whose
// .gitattributes carries the entries (the primary, since #1686) is blind to
// exactly the branch that still explodes — one whose tree predates them.
// Blob sizes are attribute-independent. For each changed path the size is the
// LARGER of the two sides' blobs: the diff text a worker ingests scales with
// both the old and the new content (the incident's 15 MB side was the OLD
// blob, the deletion side of the diff).
//
// `git ls-tree -r -l -z <ref>` entries are
// `<mode> <type> <sha> <size right-padded with spaces>\t<path>`
// NUL-delimited: the FIRST tab splits meta from path, and the path itself may
// carry tabs/newlines verbatim (why entries are never whitespace-split);
// non-blob rows (submodules) carry `-` as the size and count 0.
export function parseLsTreeSizes(out: string): Map<string, number> {
  const sizes = new Map<string, number>();
  for (const entry of out.split("\0")) {
    const tab = entry.indexOf("\t");
    if (tab < 0) continue;
    // ls-tree right-aligns the size column (any sub-7-digit size is preceded
    // by padding spaces), so the meta fields are whitespace-RUN separated — a
    // single-space split reads meta[3] === "" there, Number("") === 0, and the
    // file silently weighs 0 bytes, understating totals and overstating every
    // share computed from them (a false-warning class).
    const meta = entry.slice(0, tab).split(/\s+/);
    const path = entry.slice(tab + 1);
    if (meta[1] !== "blob") continue;
    const size = Number(meta[3]);
    if (Number.isFinite(size) && size >= 0) sizes.set(path, size);
  }
  return sizes;
}

// Changed paths + their byte weights for `base...branch`. THREE-DOT,
// never two-dot: on a branch based on an older main, two-dot reports every
// un-merged main change as a deletion, and the "dominating" path can be a
// file the branch never touched.
//
// ONE revision pair (CR round 1): three-dot names are
// `merge-base(base, branch)..branch`, so the merge-base is resolved ONCE and
// that same revision feeds BOTH the name set and every old-side size lookup —
// reading `base`'s TIP instead would attribute base-side post-fork growth to
// the branch (false warning) or miss a huge old blob the base tip no longer
// carries (the incident's 15 MB side was exactly such an old blob). A
// merge-base probe failure fails open exactly like the diff probe below it.
export function changedPathBytes(
  probe: GitProbe, cwd: string, base: string, branch: string,
): { ok: true; mergeBase: string; paths: { path: string; bytes: number }[] } | { ok: false; error: string } {
  const mb = probe(["merge-base", base, branch], cwd);
  if (mb.code !== 0) return { ok: false, error: `git merge-base ${base} ${branch}: ${mb.stderr.trim()}` };
  const mergeBase = mb.stdout.trim().split("\n")[0]; // a rev, not a path — trim is safe here
  // --no-renames (HIMMEL-1804): the name set must be a property of the
  // REPOSITORY, not a view of the user's config. `git diff --name-only`
  // honors diff.renames (git's default since 2.9, plus any user/repo
  // setting): when detection fires, a rename collapses to its NEW path only,
  // dropping the old-side blob this guard exists to weigh — and the same
  // branch then measures differently depending on a config the guard never
  // read. Pinning --no-renames makes the probe deterministic and weighs BOTH
  // sides' paths, per-path (the premise of the max() below).
  const names = probe(["diff", "--name-only", "-z", "--no-renames", `${mergeBase}...${branch}`], cwd);
  if (names.code !== 0) return { ok: false, error: `git diff --name-only --no-renames ${mergeBase}...${branch}: ${names.stderr.trim()}` };
  // -z: paths are NUL-delimited and un-quoted, so a path is defined by its
  // delimiter, never by trimming whitespace off it — git paths may legally
  // carry leading/trailing whitespace, and a trimmed key silently misses the
  // size lookup. filter(Boolean) drops only the trailing NUL field; a real
  // path is never empty.
  const paths = names.stdout.split("\0").filter(Boolean);
  if (paths.length === 0) return { ok: true, mergeBase, paths: [] };
  // A failed ls-tree reads as an empty map (every path 0 bytes) — fail-open,
  // consistent with the guard's posture; the refs necessarily exist or the
  // probes above would already have failed.
  const branchSizes = parseLsTreeSizes(probe(["ls-tree", "-r", "-l", "-z", branch], cwd).stdout);
  const mergeBaseSizes = parseLsTreeSizes(probe(["ls-tree", "-r", "-l", "-z", mergeBase], cwd).stdout);
  // mergeBase rides along so downstream policy probes (the rename pairing
  // below) read the SAME revision pair the names and sizes came from — a
  // re-derived merge-base is a second resolution that can only drift.
  return {
    ok: true,
    mergeBase,
    paths: paths.map((path) => ({ path, bytes: Math.max(branchSizes.get(path) ?? 0, mergeBaseSizes.get(path) ?? 0) })),
  };
}

// Pure decision fn over the per-path byte weights. Null = no dominating path
// (silent). Exported so the threshold table is unit-testable without git.
export function findDominatingPath(paths: { path: string; bytes: number }[]):
  | { path: string; bytes: number; share: number; totalBytes: number; pathCount: number }
  | null {
  let total = 0;
  let top: { path: string; bytes: number } | undefined;
  for (const p of paths) {
    total += p.bytes;
    if (!top || p.bytes > top.bytes) top = p;
  }
  if (!top || top.bytes < HUGE_DIFF_MIN_BYTES) return null;
  const share = total > 0 ? top.bytes / total : 0;
  if (share < HUGE_DIFF_SHARE) return null;
  return { ...top, share, totalBytes: total, pathCount: paths.length };
}

// ── rename pairing (HIMMEL-1804 round 2: the hazard the WORKER ingests) ───────
//
// The pinned --no-renames name set splits ONE logical rename into a delete
// path and an add path, each weighing ~N of the pair's 2N — so the per-path
// dominance test above reads ~50% and stays silent. That silence models the
// worker's ingest only when the worker's OWN `git diff` will attribute the
// rename (diff.renames on, git's default since 2.9) and print a similarity
// header instead of the blobs. With diff.renames=false — a real repo/user
// setting — the worker ingests the FULL deletion plus the FULL addition, a
// multi-MiB un-attributed text rename blows its context window, and a silent
// guard is exactly the failure HIMMEL-1778 exists to prevent. So the verdict
// is CONDITIONED on the worker-side guarantee (read from the same cwd the
// worker will run in), and only the un-guaranteed case groups a detected
// delete/add pair into ONE logical hazard at the SUM of both blobs.
//
// Attribution comes from a probe that forces `-M` — the explicit flag
// overrides diff.renames, so the pairing itself stays config-independent and
// deterministic, exactly like the pinned name set; the config decides only
// whether the grouping models the worker's actual ingest.

// `git diff --name-status -z` rows are NUL-delimited as
// `<status>\0<path>\0` — and `<status>\0<old>\0<new>\0` for R rows, the only
// two-path status `-M` emits. Stepping by each row's path count keeps the
// parser aligned on delimiters, never on whitespace inside a path.
export function parseNameStatusRenames(out: string): { oldPath: string; newPath: string }[] {
  const pairs: { oldPath: string; newPath: string }[] = [];
  const fields = out.split("\0").filter(Boolean); // drops only the trailing NUL field
  for (let i = 0; i < fields.length;) {
    const status = fields[i];
    if (status.startsWith("R")) pairs.push({ oldPath: fields[i + 1], newPath: fields[i + 2] });
    i += 1 + (status.startsWith("R") ? 2 : 1);
  }
  return pairs;
}

// Fold each detected pair into ONE logical entry at old+new bytes — the text
// a worker whose diff does NOT attribute the rename actually ingests — and
// pass everything else through untouched. The TOTAL is unchanged (a pair's
// sum equals its members'), so only the dominance GRANULARITY moves.
export function mergeRenamePairs(
  paths: { path: string; bytes: number }[],
  pairs: { oldPath: string; newPath: string }[],
): { path: string; bytes: number }[] {
  const byPath = new Map(paths.map((p) => [p.path, p]));
  const grouped: { path: string; bytes: number }[] = [];
  const consumed = new Set<string>();
  for (const pair of pairs) {
    const oldSide = byPath.get(pair.oldPath);
    const newSide = byPath.get(pair.newPath);
    if (!oldSide || !newSide) continue; // a pair member outside the --no-renames name set cannot happen; skip, never guess
    consumed.add(pair.oldPath);
    consumed.add(pair.newPath);
    grouped.push({ path: `${pair.oldPath} -> ${pair.newPath}`, bytes: oldSide.bytes + newSide.bytes });
  }
  for (const p of paths) if (!consumed.has(p.path)) grouped.push(p);
  return grouped;
}

// The base is RESOLVED from the repository (CR round 3 / R2a), never
// hard-coded: himmel supports `main` OR `master` (HIMMEL-297), and on a
// master-default repo a hard-coded `main` makes the guard silently fail open
// — the warning it exists to deliver never fires. The ORDER mirrors the RULE
// of `default_branch` in scripts/guardrails/lib.sh (same order, same
// tie-breaks) so every caller in the repo derives the same answer; do not
// fork the rule here. The RETURN SHAPE deliberately diverges (HIMMEL-1804):
// lib.sh prints a bare NAME its consumers re-verify (`refs/heads/$db`,
// fail-closed rc=2), but this guard hands the string straight to
// `git merge-base`, where a bare name resolves only to refs/heads/<name> —
// NEVER to refs/remotes/origin/<name>. So every name the resolver returns
// (except the terminal fallback) is a ref VERIFIED to exist, qualified
// `origin/<name>` when only the remote-tracking ref does — the pre-fix bare
// name on that repo shape resolved to nothing, the merge-base probe failed,
// and the warning silently missed on exactly the branches R2a exists to
// cover.
//
// Order: origin/HEAD symbolic-ref -> LOCAL main, then LOCAL master (both ->
// "main", the HIMMEL-323 documented tie-break) -> init.defaultBranch config
// -> REMOTE-TRACKING origin/main, then origin/master (both -> "main") ->
// "main" (lib.sh always yields a name). The remote-tracking fallbacks are a
// SEPARATE, LAST precedence phase (round 2, codex-adv-2): folding them into
// per-name resolution let a remote origin/main outrank a LOCAL master and
// preempt init.defaultBranch — and in a migrated or mirrored repo the remote
// ref can be stale or unrelated, so the guard would measure the wrong range.
// A name that names no ref is how an "unresolvable" base manifests: the
// merge-base probe below fails and the guard stays SILENT — never throws.
export function resolveDefaultBranch(probe: GitProbe, cwd: string): string {
  // Resolve a default-branch NAME to a revision git accepts as a merge-base
  // operand: the LOCAL branch when it exists, else the remote-tracking ref of
  // the same name. null = the name resolves to nothing here.
  const resolve = (name: string): string | null => {
    if (probe(["rev-parse", "--verify", "--quiet", `refs/heads/${name}`], cwd).code === 0) return name;
    if (probe(["rev-parse", "--verify", "--quiet", `refs/remotes/origin/${name}`], cwd).code === 0) return `origin/${name}`;
    return null;
  };
  const head = probe(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], cwd);
  if (head.code === 0) {
    const b = head.stdout.trim().replace(/^origin\//, ""); // a ref, not a path — trim is safe here
    const r = b ? resolve(b) : null;
    if (r) return r;
  }
  // The LOCAL phase — ONE precedence phase, main before master.
  if (probe(["rev-parse", "--verify", "--quiet", "refs/heads/main"], cwd).code === 0) return "main";
  if (probe(["rev-parse", "--verify", "--quiet", "refs/heads/master"], cwd).code === 0) return "master";
  // The CONFIG phase — before any remote-tracking fallback: a repo whose
  // default is `trunk` must not be measured against a stale origin/main just
  // because the remote ref lingers.
  const cfg = probe(["config", "init.defaultBranch"], cwd);
  if (cfg.code === 0 && cfg.stdout.trim() !== "") {
    const r = resolve(cfg.stdout.trim()); // a ref name — trim is safe here
    if (r) return r;
  }
  // Only now the REMOTE-TRACKING fallbacks, in the same documented order
  // (both -> the "main" side, HIMMEL-323). Local resolution above already
  // missed, so these probes check the remote-tracking refs alone.
  const remote = (name: string): string | null =>
    probe(["rev-parse", "--verify", "--quiet", `refs/remotes/origin/${name}`], cwd).code === 0 ? `origin/${name}` : null;
  const mainRef = remote("main");
  const masterRef = remote("master");
  if (mainRef && masterRef) return mainRef;
  if (mainRef) return mainRef;
  if (masterRef) return masterRef;
  return "main";
}

// The dispatch-time check both worker lanes call in runBody (before the
// worker launches, after the branch exists — it covers own-branch AND shared
// modes from one call site). Returns at most a `note` for the caller to
// console.error; it NEVER refuses, and it never throws (a probe that throws —
// Bun.spawnSync does on an unresolvable binary — is caught and silenced).
export function checkHugeDiff(
  lane: string,
  args: { cwd: string; branch: string; base?: string },
  probe: GitProbe = gitProbe,
): { note?: string } {
  try {
    const base = args.base ?? resolveDefaultBranch(probe, args.cwd);
    const res = changedPathBytes(probe, args.cwd, base, args.branch);
    if (!res.ok) return {}; // fail-open + silent (header rationale)
    // Worker-side rename attribution (round 2, codex-adv-1): the per-path
    // verdict below is the worker's ingest ONLY when its own `git diff`
    // will attribute renames (a similarity header, not the blobs). The
    // guarantee is read from the SAME cwd the worker will run in — repo
    // config wins over user config, exactly as the worker's git would see
    // it. Anything but an explicit `false` (unset = git's default since
    // 2.9, and any probe weirdness) keeps the round-1 verdict: a config
    // read that cannot be trusted must not manufacture a warning class.
    const renames = probe(["config", "--type=bool", "diff.renames"], args.cwd);
    const workerAttributesRenames = !(renames.code === 0 && renames.stdout.trim() === "false");
    let paths = res.paths;
    if (!workerAttributesRenames) {
      // Un-guaranteed: model the dump — group each detected delete/add pair
      // into ONE logical hazard at the sum of both blobs. The pairing probe
      // forces -M (flag beats config, so it stays deterministic); a failed
      // probe reads as no pairs — fail-open back to the round-1 verdict.
      const pairs = probe(["diff", "--name-status", "-z", "-M", `${res.mergeBase}...${args.branch}`], args.cwd);
      if (pairs.code === 0) paths = mergeRenamePairs(paths, parseNameStatusRenames(pairs.stdout));
    }
    const dom = findDominatingPath(paths);
    if (!dom) return {};
    const mib = (n: number) => `${(n / (1024 * 1024)).toFixed(1)} MiB`;
    // Print-time sanitization (HIMMEL-1804): EVERY repository-controlled
    // field interpolated into this note — path, base, AND branch — goes
    // through ONE log-safe encoder. The -z probes emit raw bytes and git
    // paths may legally carry C0/C1 controls; ref names reject ASCII
    // controls by format but DO admit the Unicode ones, so a branch may
    // legally carry U+202E or U+2028. This note lands in dispatch logs an
    // operator scans line-by-line when diagnosing a dead dispatch — a raw
    // control, a bidi override that visually reorders the line, or a Zl/Zp
    // separator some viewers render as a line break would let a crafted
    // name forge or garble whole log lines. Escaped to backslash-u form:
    // recognizable, inert. \p{Cc} is C0+DEL+C1; \p{Cf} is the bidi/format
    // class; U+2028/U+2029 are Zl/Zp, which \p{Cc} does NOT cover.
    const printable = (s: string) => s.replace(/[\p{Cc}\p{Cf}\u2028\u2029]/gu, (c) => `\\u${c.codePointAt(0)!.toString(16).padStart(4, "0")}`);
    const b = printable(base);
    const br = printable(args.branch);
    return {
      note: `${lane}: WARNING (huge-diff guard, HIMMEL-1778): ${b}...${br} is dominated by ONE file — ${printable(dom.path)} is ${mib(dom.bytes)}, ${(dom.share * 100).toFixed(1)}% of the ${mib(dom.totalBytes)} across ${dom.pathCount} changed path(s). A worker that orients itself with \`git diff ${b}...${br}\` can blow its context window on this one file (two claudex dispatches died exactly this way — "prompt is too long", and nothing in the error named the file). Dispatching anyway (fail-open): scope diffs by path (\`git diff ${b}...${br} -- <path>\`), never ingest the whole branch diff.`,
    };
  } catch {
    return {}; // probe threw — fail-open, silent
  }
}
