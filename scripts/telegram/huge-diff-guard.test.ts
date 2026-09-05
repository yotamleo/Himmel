// scripts/telegram/huge-diff-guard.test.ts — HIMMEL-1778 huge-diff lane guard.
//
// The real-git cases build the fixture from the SHIPPED artifacts — the
// tracked graphify-out/graph.json and the repo-root .gitattributes, copied
// byte-for-byte into a temp repo — never a hand-written mini-mock: this repo
// has had three incidents of a green suite proving nothing because the
// fixture diverged from what shipped.
import { expect, test } from "bun:test";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, appendFileSync, writeFileSync, readFileSync } from "node:fs";
import {
  HUGE_DIFF_SHARE,
  HUGE_DIFF_MIN_BYTES,
  parseLsTreeSizes,
  changedPathBytes,
  findDominatingPath,
  checkHugeDiff,
  resolveDefaultBranch,
  parseNameStatusRenames,
  mergeRenamePairs,
  gitProbe,
} from "./huge-diff-guard";

// Real-git cases spawn ~a dozen git processes each; bun's 5000ms default is
// tight on Windows (mirrors spawn-claudex.test.ts's CX_GIT_TEST_TIMEOUT_MS).
const GIT_TEST_TIMEOUT_MS = 60_000;

// Windows holds git's pack/index handles briefly after the process exits, so a
// temp-dir teardown can EBUSY on a test that otherwise passed (same helper +
// rationale as spawn-glm.test.ts's rmQuiet). Cleanup failure is not a result.
const rmQuiet = (p: string) => { try { rmSync(p, { recursive: true, force: true }); } catch (_) {} };

// ── parseLsTreeSizes ──────────────────────────────────────────────────────────

test("parseLsTreeSizes: parses blob sizes by the tab separator, skips non-blob rows", () => {
  const out = [
    "100644 blob 16ea5269ac3b4864665b688b18de1af8313ba4d3 1217325\tgraphify-out/graph.json",
    "100644 blob ac5d40f9b63f6e8a6aec27d3030ef3da0caa5345 56227\tgraphify-out/GRAPH_REPORT.md",
    "160000 commit a90d1a0aaae4a8f4d1c1c9e2f0e6d4a1b2c3d4e5 -\tvendor/submodule", // submodule: no size
    "garbage line without a tab",
  ].join("\0");
  const sizes = parseLsTreeSizes(out);
  expect(sizes.get("graphify-out/graph.json")).toBe(1217325);
  expect(sizes.get("graphify-out/GRAPH_REPORT.md")).toBe(56227);
  expect(sizes.has("vendor/submodule")).toBe(false);
  expect(sizes.size).toBe(2);
});

test("parseLsTreeSizes: git PADS the size column (`ls-tree -l` right-aligns it), so meta is whitespace-run separated, never single-space split", () => {
  // Verbatim shape of real `git ls-tree -r -l -z` output for sub-7-digit sizes
  // (verified against this repo's own GRAPH_REPORT.md): the sha is followed by
  // multiple spaces before a right-aligned size. A single-space split reads
  // meta[3] === "" there, and Number("") === 0 — the file silently weighs 0.
  const out = [
    "100644 blob ac5d40f9b63f6e8a6aec27d3030ef3da0caa5345   56227\tgraphify-out/GRAPH_REPORT.md",
    "100644 blob 16ea5269ac3b4864665b688b18de1af8313ba4d3 1217325\tgraphify-out/graph.json",
  ].join("\0");
  const sizes = parseLsTreeSizes(out);
  expect(sizes.get("graphify-out/GRAPH_REPORT.md")).toBe(56227); // NOT 0
  expect(sizes.get("graphify-out/graph.json")).toBe(1217325); // 7-digit sizes are unpadded either way
});

// ── findDominatingPath (pure threshold table) ─────────────────────────────────

const MiB = 1024 * 1024;

test("findDominatingPath: one huge path among small ones dominates, with its share", () => {
  const dom = findDominatingPath([
    { path: "graphify-out/graph.json", bytes: 15 * MiB },
    { path: "src/a.ts", bytes: 3_000 },
    { path: "docs/b.md", bytes: 900 },
  ]);
  expect(dom?.path).toBe("graphify-out/graph.json");
  expect(dom?.share).toBeGreaterThanOrEqual(HUGE_DIFF_SHARE);
  expect(dom?.pathCount).toBe(3);
});

test("findDominatingPath: a big file below the share threshold does NOT dominate", () => {
  expect(findDominatingPath([
    { path: "big-a.bin", bytes: 2 * MiB },
    { path: "big-b.bin", bytes: 2 * MiB },
  ])).toBeNull();
});

test("findDominatingPath: 100% share but under the byte floor does NOT dominate (small branch)", () => {
  expect(findDominatingPath([{ path: "only-file.ts", bytes: HUGE_DIFF_MIN_BYTES - 1 }])).toBeNull();
});

test("findDominatingPath: exactly at both thresholds dominates (boundary)", () => {
  const dom = findDominatingPath([{ path: "only-file.bin", bytes: HUGE_DIFF_MIN_BYTES }]);
  expect(dom?.share).toBe(1);
});

test("findDominatingPath: empty input -> null (a branch with no diff is silent)", () => {
  expect(findDominatingPath([])).toBeNull();
});

// ── rename pairing (HIMMEL-1804 round 2: the hazard the WORKER ingests) ───────

test("parseNameStatusRenames: R rows carry TWO paths and pair them; every other status advances by one", () => {
  const out = ["M\0src/a.ts\0", "R100\0old/big.json\0new/big.json\0", "D\0gone.txt\0", "A\0added.txt\0"].join("");
  expect(parseNameStatusRenames(out)).toEqual([{ oldPath: "old/big.json", newPath: "new/big.json" }]);
});

test("mergeRenamePairs: a detected pair becomes ONE hazard at the SUM of both sides — everything else passes through", () => {
  const merged = mergeRenamePairs(
    [
      { path: "old/big.json", bytes: 5 * MiB },
      { path: "new/big.json", bytes: 4 * MiB },
      { path: "src.ts", bytes: 10 },
    ],
    [{ oldPath: "old/big.json", newPath: "new/big.json" }],
  );
  expect(merged).toEqual([
    { path: "old/big.json -> new/big.json", bytes: 9 * MiB },
    { path: "src.ts", bytes: 10 },
  ]);
  // the point of the grouping: un-grouped, two ~equal sides never reach the
  // 90% share; grouped, the rename IS the dominating hazard.
  expect(findDominatingPath([
    { path: "old/big.json", bytes: 5 * MiB },
    { path: "new/big.json", bytes: 4 * MiB },
    { path: "src.ts", bytes: 10 },
  ])).toBeNull();
  expect(findDominatingPath(merged)?.path).toBe("old/big.json -> new/big.json");
});

// ── checkHugeDiff decision shape (stubbed probe — no git needed) ──────────────

test("checkHugeDiff: a dominating probe yields a WARNING naming lane, path, and share — and NOTHING else (warn-only)", () => {
  // Explicit base: this stub pins the DECISION shape with a fixed probe
  // sequence (merge-base, then the -z name-only diff, then -z ls-tree for
  // branch then merge-base — outputs NUL-delimited, as real git emits them);
  // an undefined base would add the resolver's probes ahead of them.
  const lsOut = "100644 blob aa 16000000\tgraphify-out/graph.json\0" + "100644 blob bb 2000\tsrc/a.ts\0";
  let call = 0;
  const probe = () => {
    call++;
    if (call === 1) return { code: 0, stdout: "0123456789abcdef0123456789abcdef01234567\n", stderr: "" };
    if (call === 2) return { code: 0, stdout: "graphify-out/graph.json\0src/a.ts\0", stderr: "" };
    return { code: 0, stdout: lsOut, stderr: "" };
  };
  const res = checkHugeDiff("spawn-glm", { cwd: "/nowhere", branch: "glm/x", base: "main" }, probe);
  expect(res.note).toBeDefined();
  expect(res.note).toContain("spawn-glm");
  expect(res.note).toContain("graphify-out/graph.json");
  expect(res.note).toMatch(/[0-9]+\.[0-9]%/);
  expect(res.note).toContain("fail-open");
  // warn-only contract: the ONLY key is `note` — there is no refusal to act on
  expect(Object.keys(res)).toEqual(["note"]);
});

test("checkHugeDiff: a failed probe (missing base ref) is SILENT — {}, never a refusal, never a throw", () => {
  expect(checkHugeDiff("spawn-glm", { cwd: "/nowhere", branch: "b", base: "no-such-ref" }, () => ({ code: 128, stdout: "", stderr: "fatal: ambiguous argument" }))).toEqual({});
});

test("checkHugeDiff: a THROWING probe (unresolvable git) is silent {}", () => {
  expect(checkHugeDiff("spawn-glm", { cwd: "/nowhere", branch: "b" }, (() => { throw new Error("spawn ENOENT"); }) as typeof gitProbe)).toEqual({});
});

// ── the printed note cannot forge or reorder dispatch-log lines (HIMMEL-1804 R2) ─
//
// A git path is bytes and may legally contain newlines and other control
// characters (the -z probes emit them verbatim; `ls-tree -z` entries carry the
// raw path after the tab). This note lands in dispatch logs an operator scans
// line-by-line when diagnosing a dead dispatch — a raw \n inside the path
// would let a crafted filename spawn whole spoofed lines ("WARNING",
// "Dispatching anyway", fake next-entry markers). EVERY repository-controlled
// field interpolated into the note — path, base, AND branch — must go through
// ONE log-safe encoder: ref names reject ASCII controls by format but DO
// admit the Unicode ones (U+2028/U+2029 line separators legally render as
// line breaks in Unicode-aware viewers; Cf bidi controls such as U+202E
// visually reorder the line), so the round-1 claim that base/branch "cannot
// carry them" held only for the ASCII range.

test("checkHugeDiff: a dominating path containing a NEWLINE is printed escaped — the note never carries a raw control character", () => {
  // Same stub shape as the decision-table test above (explicit base: probe 1
  // merge-base, probe 2 the -z name-only diff, probes 3+ the -z ls-trees).
  const evil = "evil\nalternate WARNING: totally fine";
  const lsOut = `100644 blob aa 16000000\t${evil}\0` + "100644 blob bb 2000\tsrc/a.ts\0";
  let call = 0;
  const probe = () => {
    call++;
    if (call === 1) return { code: 0, stdout: "0123456789abcdef0123456789abcdef01234567\n", stderr: "" };
    if (call === 2) return { code: 0, stdout: `${evil}\0src/a.ts\0`, stderr: "" };
    return { code: 0, stdout: lsOut, stderr: "" };
  };
  const res = checkHugeDiff("spawn-glm", { cwd: "/nowhere", branch: "glm/x", base: "main" }, probe);
  expect(res.note).toBeDefined();
  // the escaped form keeps the name recognizable...
  expect(res.note).toContain("evil\\u000aalternate");
  // ...and the raw control character NEVER enters the note (ratchet: pre-fix
  // the path was interpolated verbatim, so both assertions fail)
  expect(res.note).not.toContain("evil\nalternate");
  // the whole escaped range is covered, not just \n: BEL (C0), DEL (0x7f),
  // and U+009F (C1) through the same stub shape. Built from code points —
  // not string-literal escapes — so the SOURCE stays ASCII-clean while the
  // value carries the raw controls git would emit.
  const ctrl = (path: string) => {
    let c = 0;
    return () => {
      c++;
      if (c === 1) return { code: 0, stdout: "0123456789abcdef0123456789abcdef01234567\n", stderr: "" };
      if (c === 2) return { code: 0, stdout: `${path}\0src/a.ts\0`, stderr: "" };
      return { code: 0, stdout: `100644 blob aa 16000000\t${path}\0` + "100644 blob bb 2000\tsrc/a.ts\0", stderr: "" };
    };
  };
  const poison = "a" + String.fromCharCode(0x07) + "b" + String.fromCharCode(0x7f) + "c" + String.fromCharCode(0x9f) + " d"
    + String.fromCharCode(0x2028) + "e" + String.fromCharCode(0x202e) + "f" + String.fromCharCode(0x2029) + "g";
  const res2 = checkHugeDiff("spawn-glm", { cwd: "/nowhere", branch: "glm/x", base: "main" }, ctrl(poison) as typeof gitProbe);
  expect(res2.note).toBeDefined();
  expect(res2.note).toContain("a\\u0007b\\u007fc\\u009f d\\u2028e\\u202ef\\u2029g");
  // no raw C0 (0x00-0x1f), DEL (0x7f), C1 (0x80-0x9f), U+2028/U+2029 (Zl/Zp),
  // or Cf (bidi/format) code point anywhere — the classes \\p{Cc}, \\p{Cf},
  // \\u2028, \\u2029 the encoder is documented to escape. (ratchet: round 1
  // escaped only \\p{Cc}, so the three Unicode poison characters entered raw)
  expect([...res2.note].some((ch) => /[\p{Cc}\p{Cf}\u2028\u2029]/u.test(ch))).toBe(false);
});

test("checkHugeDiff: a BRANCH name carrying Unicode bidi/separator controls is printed escaped too — every repo-controlled field goes through the encoder (ratchet)", () => {
  // Same stub shape as above; only the branch argument carries the poison —
  // round 1 interpolated base and branch into the note verbatim.
  const lsOut = "100644 blob aa 16000000\tgraphify-out/graph.json\0" + "100644 blob bb 2000\tsrc/a.ts\0";
  let call = 0;
  const probe = () => {
    call++;
    if (call === 1) return { code: 0, stdout: "0123456789abcdef0123456789abcdef01234567\n", stderr: "" };
    if (call === 2) return { code: 0, stdout: "graphify-out/graph.json\0src/a.ts\0", stderr: "" };
    return { code: 0, stdout: lsOut, stderr: "" };
  };
  const poison = "glm/x" + String.fromCharCode(0x202e) + "y" + String.fromCharCode(0x2028) + "z";
  const res = checkHugeDiff("spawn-glm", { cwd: "/nowhere", branch: poison, base: "main" }, probe as typeof gitProbe);
  expect(res.note).toBeDefined();
  expect(res.note).toContain("glm/x\\u202ey\\u2028z");
  // and the raw controls NEVER enter the note
  expect([...res.note!].some((ch) => /[\p{Cc}\p{Cf}\u2028\u2029]/u.test(ch))).toBe(false);
});

// ── resolveDefaultBranch mirrors lib.sh default_branch (CR round 3: R2a) ──────
//
// The ORDER is scripts/guardrails/lib.sh `default_branch`'s, mirrored — not
// forked: origin/HEAD -> local main/master (both -> "main", HIMMEL-323) ->
// init.defaultBranch -> "main". The RETURN SHAPE deliberately diverges
// (HIMMEL-1804): lib.sh prints a bare NAME its consumers re-verify
// (`refs/heads/$db`, fail-closed rc=2), but the guard hands the string
// straight to `git merge-base`, where a bare name resolves only to
// refs/heads/<name> — never to refs/remotes/origin/<name>. So every
// non-terminal return here is a ref VERIFIED to exist, qualified
// `origin/<name>` when only the remote-tracking ref does. The
// remote-tracking qualification is a SEPARATE, LAST precedence phase
// (HIMMEL-1804 round 2): folding it into per-name resolution let a remote
// origin/main outrank a LOCAL master and preempt init.defaultBranch — in a
// migrated/mirrored repo the remote ref can be stale or unrelated, and the
// guard would measure the wrong range. A probe miss (args not in the table)
// answers like a ref/config that is not there: non-zero.

test("resolveDefaultBranch: the lib.sh order — origin/HEAD, then LOCAL main/master, then init.defaultBranch, then remote-tracking fallbacks, then \"main\" — every non-terminal return is a ref that RESOLVES", () => {
  const rows: { name: string; calls: Record<string, { code: number; stdout: string }>; expect: string }[] = [
    {
      name: "origin/HEAD wins; the stripped name verifies as a LOCAL branch -> bare name (himmel's own shape)",
      calls: {
        "symbolic-ref --quiet --short refs/remotes/origin/HEAD": { code: 0, stdout: "origin/master\n" },
        "rev-parse --verify --quiet refs/heads/master": { code: 0, stdout: "" },
      },
      expect: "master",
    },
    {
      // ratchet (HIMMEL-1804 item 1): pre-fix this row stripped origin/ and
      // returned bare "master", which resolves to NO ref — the merge-base
      // probe fails and the warning silently misses on the exact repo shape
      // (remote-tracking only, no local default branch) the R2a resolution
      // exists to cover.
      name: "origin/HEAD wins but NO local branch of that name -> the REMOTE-TRACKING ref, qualified",
      calls: {
        "symbolic-ref --quiet --short refs/remotes/origin/HEAD": { code: 0, stdout: "origin/master\n" },
        "rev-parse --verify --quiet refs/remotes/origin/master": { code: 0, stdout: "" },
      },
      expect: "origin/master",
    },
    {
      name: "origin/HEAD dangling (target ref gone) falls through to the local arms",
      calls: {
        "symbolic-ref --quiet --short refs/remotes/origin/HEAD": { code: 0, stdout: "origin/master\n" },
        "rev-parse --verify --quiet refs/heads/main": { code: 0, stdout: "" },
      },
      expect: "main",
    },
    {
      name: "BOTH local main and master exist -> main (HIMMEL-323 documented tie-break)",
      calls: {
        "rev-parse --verify --quiet refs/heads/main": { code: 0, stdout: "" },
        "rev-parse --verify --quiet refs/heads/master": { code: 0, stdout: "" },
      },
      expect: "main",
    },
    {
      name: "only master exists locally -> master (a master-default repo is the R2a case)",
      calls: { "rev-parse --verify --quiet refs/heads/master": { code: 0, stdout: "" } },
      expect: "master",
    },
    {
      // ratchet (HIMMEL-1804 round 2, codex-adv-2): pre-fix `resolve()`
      // consulted the remote-tracking fallback per NAME, so origin/main
      // (truthy) beat a LOCAL master through the `if (mainRef && masterRef)`
      // tie-break — a REMOTE ref outranked a LOCAL branch, and a migrated or
      // mirrored repo measured its range against a possibly stale/unrelated
      // remote ref. Local resolution is ONE precedence phase.
      name: "a LOCAL master outranks a REMOTE origin/main — remote-tracking fallbacks are a SEPARATE, LAST phase",
      calls: {
        "rev-parse --verify --quiet refs/heads/master": { code: 0, stdout: "" },
        "rev-parse --verify --quiet refs/remotes/origin/main": { code: 0, stdout: "" },
      },
      expect: "master",
    },
    {
      // ratchet (HIMMEL-1804 round 2, the init.defaultBranch sibling of the
      // same phase bug): pre-fix origin/main was returned BEFORE the config
      // was consulted, so a repo whose default is `trunk` measured against
      // the stale remote ref instead of its configured default.
      name: "init.defaultBranch=trunk with a LOCAL trunk outranks a stale origin/main — config before remote fallbacks",
      calls: {
        "config init.defaultBranch": { code: 0, stdout: "trunk\n" },
        "rev-parse --verify --quiet refs/heads/trunk": { code: 0, stdout: "" },
        "rev-parse --verify --quiet refs/remotes/origin/main": { code: 0, stdout: "" },
      },
      expect: "trunk",
    },
    {
      // ratchet (audit, same class as item 1 through the no-origin/HEAD door)
      name: "NO origin/HEAD and no local main, but remote-tracking origin/main -> qualified ref",
      calls: { "rev-parse --verify --quiet refs/remotes/origin/main": { code: 0, stdout: "" } },
      expect: "origin/main",
    },
    {
      name: "neither local branch -> init.defaultBranch naming a LOCAL branch -> bare name",
      calls: {
        "config init.defaultBranch": { code: 0, stdout: "trunk\n" },
        "rev-parse --verify --quiet refs/heads/trunk": { code: 0, stdout: "" },
      },
      expect: "trunk",
    },
    {
      name: "init.defaultBranch naming only a REMOTE-TRACKING branch -> qualified ref",
      calls: {
        "config init.defaultBranch": { code: 0, stdout: "trunk\n" },
        "rev-parse --verify --quiet refs/remotes/origin/trunk": { code: 0, stdout: "" },
      },
      expect: "origin/trunk",
    },
    {
      name: "init.defaultBranch naming a ref that exists NOWHERE falls through (the name was assumed, not resolved)",
      calls: { "config init.defaultBranch": { code: 0, stdout: "trunk\n" } },
      expect: "main",
    },
    {
      name: "config arm present but EMPTY falls through (git config can hold an empty value)",
      calls: { "config init.defaultBranch": { code: 0, stdout: "\n" } },
      expect: "main",
    },
    {
      name: "nothing resolves -> lib.sh's documented \"main\" fallback (the merge-base probe fails open on it)",
      calls: {},
      expect: "main",
    },
  ];
  for (const row of rows) {
    const probe = (args: string[]) => row.calls[args.join(" ")] ?? { code: 1, stdout: "", stderr: "" };
    expect(resolveDefaultBranch(probe as typeof gitProbe, "/nowhere")).toBe(row.expect);
  }
});

// ── real git ──────────────────────────────────────────────────────────────────

// A temp repo seeded with the SHIPPED artifacts: the tracked
// graphify-out/graph.json + the repo-root .gitattributes (which carries the
// `-diff` entries from PR #1686). What ships is what the guard must judge.
// `defaultBranch` shapes the fixture's default branch (main OR master OR an
// exotic name) so the guard's base RESOLUTION is exercised, not assumed.
function makeGraphRepo(defaultBranch = "main"): { repo: string; git: (args: string[]) => { code: number; stdout: string; stderr: string } } {
  const repo = mkdtempSync(join(tmpdir(), "hugediff-"));
  const git = (args: string[]) => {
    const r = Bun.spawnSync(["git", "-c", "user.email=t@t", "-c", "user.name=t", ...args], { cwd: repo, stdout: "pipe", stderr: "pipe" });
    return { code: r.exitCode ?? -1, stdout: r.stdout.toString(), stderr: r.stderr.toString() };
  };
  git(["init", "-b", defaultBranch]);
  mkdirSync(join(repo, "graphify-out"), { recursive: true });
  copyFileSync(resolve("graphify-out/graph.json"), join(repo, "graphify-out", "graph.json"));
  copyFileSync(resolve(".gitattributes"), join(repo, ".gitattributes"));
  git(["add", "."]);
  git(["commit", "-m", "seed: shipped graph artifact + shipped .gitattributes"]);
  return { repo, git };
}

test("(REAL GIT, shipped artifacts): a branch that regenerates graph.json gets a warning NAMING the path and its share", () => {
  const { repo, git } = makeGraphRepo();
  try {
    git(["checkout", "-b", "feat/graph-refresh"]);
    // A regeneration rewrites the whole generated file; append enough payload
    // that the artifact stays the dominating path by an honest margin.
    appendFileSync(join(repo, "graphify-out", "graph.json"), `,\n  {"regenerated": "${"x".repeat(8192)}"}`);
    writeFileSync(join(repo, "src-touched.ts"), "export const touched = true;\n");
    git(["add", "."]);
    git(["commit", "-m", "regen graph + one source file"]);
    const res = checkHugeDiff("spawn-claudex", { cwd: repo, branch: "feat/graph-refresh" });
    expect(res.note).toBeDefined();
    expect(res.note).toContain("spawn-claudex");
    expect(res.note).toContain("graphify-out/graph.json");
    expect(res.note).toContain("feat/graph-refresh");
    expect(res.note).toMatch(/[0-9]+\.[0-9]% of the/);
  } finally { rmQuiet(repo); }
}, GIT_TEST_TIMEOUT_MS);

test("(REAL GIT, shipped artifacts): the .gitattributes -diff entry makes `git diff --stat main...branch` report graph.json as Bin, not a line count (PR #1686 verification)", () => {
  const { repo, git } = makeGraphRepo();
  try {
    git(["checkout", "-b", "feat/graph-refresh"]);
    appendFileSync(join(repo, "graphify-out", "graph.json"), `,\n  {"regenerated": "${"x".repeat(8192)}"}`);
    git(["add", "."]);
    git(["commit", "-m", "regen graph"]);
    const stat = git(["diff", "--stat", "main...feat/graph-refresh"]).stdout;
    expect(stat).toMatch(/graphify-out\/graph\.json \| Bin/);
    expect(stat).not.toMatch(/graphify-out\/graph\.json \| \d+ [+-]/);
    // and numstat collapses to the binary marker — the reason the guard weighs
    // ls-tree BYTES, not numstat lines (see huge-diff-guard.ts)
    const numstat = git(["diff", "--numstat", "main...feat/graph-refresh"]).stdout;
    expect(numstat).toMatch(/^-\t-\tgraphify-out\/graph\.json$/m);
  } finally { rmQuiet(repo); }
}, GIT_TEST_TIMEOUT_MS);

test("(REAL GIT): a normal small-file branch produces NO warning", () => {
  const { repo, git } = makeGraphRepo();
  try {
    git(["checkout", "-b", "feat/normal"]);
    writeFileSync(join(repo, "a.ts"), "export const a = 1;\n");
    writeFileSync(join(repo, "b.md"), "# b\n");
    git(["add", "."]);
    git(["commit", "-m", "normal work"]);
    expect(checkHugeDiff("spawn-glm", { cwd: repo, branch: "feat/normal" })).toEqual({});
  } finally { rmQuiet(repo); }
}, GIT_TEST_TIMEOUT_MS);

test("(REAL GIT): three-dot semantics — main's post-branch commits do NOT enter the probe (two-dot would report them as branch deletions)", () => {
  const { repo, git } = makeGraphRepo();
  try {
    git(["checkout", "-b", "feat/off-old-main"]);
    writeFileSync(join(repo, "branch-file.txt"), "on the branch\n");
    git(["add", "."]);
    git(["commit", "-m", "branch work"]);
    git(["checkout", "main"]);
    writeFileSync(join(repo, "main-moved-on.txt"), "landed on main after the branch point\n");
    git(["add", "."]);
    git(["commit", "-m", "main moved on"]);
    const res = changedPathBytes(gitProbe, repo, "main", "feat/off-old-main");
    expect(res.ok).toBe(true);
    if (res.ok) expect(res.paths.map((p) => p.path)).toEqual(["branch-file.txt"]); // merge-base, not branch-vs-main-tip
  } finally { rmQuiet(repo); }
}, GIT_TEST_TIMEOUT_MS);

// ── one revision pair for names AND sizes (CR round 1: mismatched pair) ───────
//
// Three-dot names are `merge-base(main, branch)..branch`. The old side of
// every size lookup must be that SAME merge-base — reading main's TIP instead
// attributes main's post-fork growth to the branch (false warning) or misses a
// huge old blob main's tip no longer carries (missed warning). For the poison
// to reach the result the path must sit in the three-dot NAME set — i.e. the
// branch touched it — while the large rewrite lives only on main's tip.

test("(REAL GIT): main's post-fork growth of a path the branch only lightly touched is NOT attributed to the branch (names and sizes share ONE revision pair)", () => {
  const { repo, git } = makeGraphRepo();
  try {
    mkdirSync(join(repo, "docs"), { recursive: true });
    writeFileSync(join(repo, "docs/report.md"), "small seed\n"); // exists at the fork point
    git(["add", "."]);
    git(["commit", "-m", "seed small report"]);
    git(["checkout", "-b", "feat/off-old-main"]);
    writeFileSync(join(repo, "docs/report.md"), "small branch tweak\n");
    mkdirSync(join(repo, "src"), { recursive: true });
    writeFileSync(join(repo, "src/branch.ts"), "export const b = 1;\n");
    git(["add", "."]);
    git(["commit", "-m", "branch work"]);
    git(["checkout", "main"]);
    appendFileSync(join(repo, "docs/report.md"), "x".repeat(3 * 1024 * 1024)); // main grows it AFTER the fork
    git(["add", "."]);
    git(["commit", "-m", "main grows report post-fork"]);
    // The 3 MiB is main's, not the branch's: the merge-base side is ~7 bytes,
    // so no path reaches the 1 MiB floor and the dispatch must stay silent.
    expect(checkHugeDiff("spawn-glm", { cwd: repo, branch: "feat/off-old-main" })).toEqual({});
  } finally { rmQuiet(repo); }
}, GIT_TEST_TIMEOUT_MS);

test("(REAL GIT): mirror — a large artifact dominating the BRANCH is still reported while main has also moved", () => {
  const { repo, git } = makeGraphRepo();
  try {
    git(["checkout", "-b", "feat/graph-refresh"]);
    appendFileSync(join(repo, "graphify-out", "graph.json"), `,\n  {"regenerated": "${"x".repeat(2 * 1024 * 1024)}"}`);
    writeFileSync(join(repo, "src-touched.ts"), "export const touched = true;\n");
    git(["add", "."]);
    git(["commit", "-m", "regen graph + one source file"]);
    git(["checkout", "main"]);
    writeFileSync(join(repo, "main-moved-on.txt"), "landed on main after the branch point\n");
    git(["add", "."]);
    git(["commit", "-m", "main moved on"]);
    const res = checkHugeDiff("spawn-claudex", { cwd: repo, branch: "feat/graph-refresh" });
    expect(res.note).toBeDefined();
    expect(res.note).toContain("graphify-out/graph.json");
  } finally { rmQuiet(repo); }
}, GIT_TEST_TIMEOUT_MS);

test("(REAL GIT): a huge blob at the MERGE-BASE that main's tip no longer carries still warns (the deletion side IS the ingest hazard)", () => {
  const { repo, git } = makeGraphRepo();
  try {
    git(["checkout", "-b", "feat/drop-artifact"]);
    git(["rm", "-q", "graphify-out/graph.json"]); // drops the ~1.2 MiB shipped artifact
    writeFileSync(join(repo, "src-touched.ts"), "export const touched = true;\n");
    git(["add", "."]);
    git(["commit", "-m", "drop artifact + one source file"]);
    git(["checkout", "main"]);
    writeFileSync(join(repo, "graphify-out", "graph.json"), "{}\n"); // main shrank it post-fork
    git(["add", "."]);
    git(["commit", "-m", "main shrinks artifact post-fork"]);
    // Old-side sizes must come from the merge-base, where the blob is still
    // ~1.2 MiB — reading main's tip (2 bytes) would silence the exact
    // incident shape: the 15 MB side of the original incident was the OLD blob.
    const res = checkHugeDiff("spawn-glm", { cwd: repo, branch: "feat/drop-artifact" });
    expect(res.note).toBeDefined();
    expect(res.note).toContain("graphify-out/graph.json");
  } finally { rmQuiet(repo); }
}, GIT_TEST_TIMEOUT_MS);

// ── paths are delimiter-defined, never whitespace-trimmed (CR round 1) ────────

test("(REAL GIT): a changed path with LEADING whitespace resolves to ITS size — the lookup key is the verbatim path", () => {
  const { repo, git } = makeGraphRepo();
  try {
    git(["checkout", "-b", "feat/weird-name"]);
    // Leading spaces are a legal, filesystem-real path on every OS the suite
    // runs on (Win32 strips only TRAILING dots/spaces, so trailing-whitespace
    // names cannot be created there — the same .trim() corruption class).
    writeFileSync(join(repo, "  spaced-name.ts"), "x".repeat(2 * 1024 * 1024 + 100));
    writeFileSync(join(repo, "src-touched.ts"), "export const touched = true;\n");
    git(["add", "."]);
    git(["commit", "-m", "add leading-space file"]);
    const res = changedPathBytes(gitProbe, repo, "main", "feat/weird-name");
    expect(res.ok).toBe(true);
    if (res.ok) {
      const weird = res.paths.find((p) => p.path.includes("spaced-name"));
      expect(weird?.path).toBe("  spaced-name.ts"); // verbatim, not trimmed
      expect(weird?.bytes).toBeGreaterThanOrEqual(HUGE_DIFF_MIN_BYTES); // its blob, not 0 from a missed lookup
    }
    const check = checkHugeDiff("spawn-glm", { cwd: repo, branch: "feat/weird-name" });
    expect(check.note).toContain("  spaced-name.ts"); // the warning names the real path
  } finally { rmQuiet(repo); }
}, GIT_TEST_TIMEOUT_MS);

test("(REAL GIT): a real probe against a missing base ref fails open silently", () => {
  const { repo } = makeGraphRepo();
  try {
    expect(checkHugeDiff("spawn-glm", { cwd: repo, branch: "main", base: "no-such-base" })).toEqual({});
  } finally { rmQuiet(repo); }
}, GIT_TEST_TIMEOUT_MS);

// ── base resolved from the repository, never hard-coded (CR round 3: R2a) ─────
//
// himmel supports `main` OR `master` (HIMMEL-297). A hard-coded `main` makes
// the guard silently fail open on every master-default repo — the warning
// that names the hazard simply never fires. The guard must RESOLVE the base
// the same way scripts/guardrails/lib.sh `default_branch` does: origin/HEAD
// -> local main/master (both -> main, HIMMEL-323) -> init.defaultBranch ->
// "main" — and an unresolvable base stays SILENT (fail-open), never throws.

test("(REAL GIT): a repo whose default branch is master still warns — the base is RESOLVED, not hard-coded", () => {
  const { repo, git } = makeGraphRepo("master");
  try {
    git(["checkout", "-b", "feat/graph-refresh"]);
    appendFileSync(join(repo, "graphify-out", "graph.json"), `,\n  {"regenerated": "${"x".repeat(2 * 1024 * 1024)}"}`);
    writeFileSync(join(repo, "src-touched.ts"), "export const touched = true;\n");
    git(["add", "."]);
    git(["commit", "-m", "regen graph + one source file"]);
    const res = checkHugeDiff("spawn-claudex", { cwd: repo, branch: "feat/graph-refresh" });
    // ratchet: against a hard-coded `main` this repo has NO main ref, the
    // merge-base probe fails, and res.note is undefined — the warning that
    // R2a exists to deliver never fires.
    expect(res.note).toBeDefined();
    // the RESOLVED name feeds the warning end to end (same revision the guard
    // actually probed), not the name it might have assumed
    expect(res.note).toContain("master...feat/graph-refresh");
  } finally { rmQuiet(repo); }
}, GIT_TEST_TIMEOUT_MS);

test("(REAL GIT): a repo whose default branch exists ONLY as remote-tracking (origin/HEAD set, no local master) still warns — the base is a ref that RESOLVES (HIMMEL-1804 item 1)", () => {
  const { repo, git } = makeGraphRepo("master");
  try {
    git(["checkout", "-b", "feat/graph-refresh"]);
    appendFileSync(join(repo, "graphify-out", "graph.json"), `,\n  {"regenerated": "${"x".repeat(2 * 1024 * 1024)}"}`);
    writeFileSync(join(repo, "src-touched.ts"), "export const touched = true;\n");
    git(["add", "."]);
    git(["commit", "-m", "regen graph + one source file"]);
    // The repo shape: origin/HEAD -> origin/master EXISTS, the LOCAL master
    // does not (a pruned clone, or a checkout that never materialized the
    // default branch locally). CONSTRUCTED, not found: himmel itself has a
    // local main, so this shape is unreachable on the real checkout.
    git(["update-ref", "refs/remotes/origin/master", "master"]);
    git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/master"]);
    git(["branch", "-D", "master"]);
    const res = checkHugeDiff("spawn-claudex", { cwd: repo, branch: "feat/graph-refresh" });
    // ratchet: pre-fix the resolver stripped origin/ and returned bare
    // "master" — which resolves to NO ref (git never DWIMs a bare name to
    // refs/remotes/origin/*), the merge-base probe failed, and the warning
    // silently missed on exactly the repo shape the R2a fix exists to cover.
    expect(res.note).toBeDefined();
    // the RESOLVED ref feeds the warning end to end — the qualified name is
    // the revision the guard actually probed
    expect(res.note).toContain("origin/master...feat/graph-refresh");
  } finally { rmQuiet(repo); }
}, GIT_TEST_TIMEOUT_MS);

test("(REAL GIT): a repo where NO base resolves (no origin/HEAD, no main, no master, empty init.defaultBranch) stays SILENT — no throw", () => {
  // A `trunk`-default repo: every arm of the resolver comes up empty (the
  // LOCAL empty init.defaultBranch pins the config arm regardless of the
  // machine's global config), so the resolved name is lib.sh's documented
  // "main" fallback — which names no ref here, the merge-base probe fails,
  // and the guard must fail open SILENTLY even though a dominating path
  // exists (the silence must come from the unresolvable base, not a boring diff).
  const { repo, git } = makeGraphRepo("trunk");
  try {
    git(["config", "init.defaultBranch", ""]);
    git(["checkout", "-b", "feat/graph-refresh"]);
    appendFileSync(join(repo, "graphify-out", "graph.json"), `,\n  {"regenerated": "${"x".repeat(2 * 1024 * 1024)}"}`);
    git(["add", "."]);
    git(["commit", "-m", "regen graph"]);
    expect(checkHugeDiff("spawn-glm", { cwd: repo, branch: "feat/graph-refresh" })).toEqual({});
  } finally { rmQuiet(repo); }
}, GIT_TEST_TIMEOUT_MS);

// ── advice in the guard's own comparison form (CR round 3: R2b) ───────────────

test("(REAL GIT): every `git diff` command the warning PRINTS uses the three-dot form the guard computed — never two-dot", () => {
  const { repo, git } = makeGraphRepo();
  try {
    git(["checkout", "-b", "feat/graph-refresh"]);
    appendFileSync(join(repo, "graphify-out", "graph.json"), `,\n  {"regenerated": "${"x".repeat(2 * 1024 * 1024)}"}`);
    writeFileSync(join(repo, "src-touched.ts"), "export const touched = true;\n");
    git(["add", "."]);
    git(["commit", "-m", "regen graph + one source file"]);
    const res = checkHugeDiff("spawn-glm", { cwd: repo, branch: "feat/graph-refresh" });
    expect(res.note).toBeDefined();
    // INVARIANT: the guard reasons in three-dot (merge-base..branch). Any
    // `git diff <base>` (two-dot) it tells the operator to run reintroduces
    // the base-tip noise three-dot exists to exclude — so EVERY command the
    // note prints must carry the same three-dot pair it actually used.
    const commands = res.note!.match(/git diff [^`]+`/g) ?? [];
    expect(commands.length).toBeGreaterThan(0);
    for (const c of commands) expect(c).toContain("...");
    expect(res.note).toContain("main...feat/graph-refresh");
  } finally { rmQuiet(repo); }
}, GIT_TEST_TIMEOUT_MS);

// ── sizes are read from git's ACTUAL ls-tree format, not an assumed one (audit) ─
//
// `git ls-tree -l` right-pads the size column with spaces (any size under 7
// digits), so the meta fields are whitespace-RUN separated. A single-space
// split reads meta[3] === "" and Number("") === 0: every sub-MiB sibling of
// a dominating file weighs 0 bytes, totalBytes is understated, the share is
// OVERSTATED — and a 1 MiB file among 900 KiB of ordinary work warns as a
// "100%" dominating path. False warning, same assumed-not-derived class.

test("(REAL GIT): a 1 MiB file among sub-MiB siblings does NOT warn — padded sizes must weigh their true bytes", () => {
  const { repo, git } = makeGraphRepo();
  try {
    git(["checkout", "-b", "feat/big-plus-small"]);
    // 1_048_676 bytes: clears the 1 MiB floor (7 digits — unpadded either
    // way, so the dominating side parses fine pre-fix too).
    writeFileSync(join(repo, "big-asset.bin"), "y".repeat(1024 * 1024 + 100));
    // 10 x 95_000 bytes: 5-digit sizes — the PADDED (sub-7-digit) class. True
    // share of the big file = 1_048_676 / 1_998_676 ~= 52% << 90% -> silent.
    // Pre-fix each sibling weighs 0, the share reads 100%, and the guard
    // FALSELY warns.
    for (let i = 0; i < 10; i++) writeFileSync(join(repo, `src-${i}.ts`), "z".repeat(95_000));
    git(["add", "."]);
    git(["commit", "-m", "one big asset plus ordinary work"]);
    expect(checkHugeDiff("spawn-glm", { cwd: repo, branch: "feat/big-plus-small" })).toEqual({});
  } finally { rmQuiet(repo); }
}, GIT_TEST_TIMEOUT_MS);

// ── the name set is the repo's content, not a config view (HIMMEL-1804 item 2) ─
//
// `git diff --name-only` honors diff.renames (git's default since 2.9, plus
// any user/repo setting): when detection fires, a rename collapses to its NEW
// path only — the OLD-side blob this guard exists to weigh is dropped, and
// the same branch measures differently depending on a config the guard never
// read. The probe must be pinned --no-renames so the changed-path set is a
// property of the REPOSITORY, deterministic end to end.

test("(REAL GIT): the changed-path set is INDEPENDENT of diff.renames — a rename weighs BOTH sides' paths, deterministically", () => {
  const { repo, git } = makeGraphRepo();
  try {
    git(["checkout", "-b", "feat/rename-artifact"]);
    git(["mv", "graphify-out/graph.json", "graphify-out/graph2.json"]);
    writeFileSync(join(repo, "src-touched.ts"), "export const touched = true;\n");
    git(["add", "."]);
    git(["commit", "-m", "rename the tracked artifact + one source file"]);
    // The SAME branch, measured under both diff.renames settings. Pre-fix the
    // probe honored the config (ratchet): renames ON collapsed the rename to
    // its new path only; renames OFF listed both sides — one branch, two
    // measurements, decided by a config outside the guard.
    git(["config", "diff.renames", "true"]);
    const on = changedPathBytes(gitProbe, repo, "main", "feat/rename-artifact");
    git(["config", "diff.renames", "false"]);
    const off = changedPathBytes(gitProbe, repo, "main", "feat/rename-artifact");
    expect(on).toEqual(off);
    // and the pinned shape is the no-renames one: BOTH sides' paths, each
    // weighing its own blob — the old path (the ~1.2 MiB shipped blob at the
    // merge base) must be IN the measurement, not collapsed away.
    if (on.ok && off.ok) {
      expect([...on.paths.map((p) => p.path)].sort()).toEqual(["graphify-out/graph.json", "graphify-out/graph2.json", "src-touched.ts"]);
      const oldSide = on.paths.find((p) => p.path === "graphify-out/graph.json");
      expect(oldSide?.bytes ?? 0).toBeGreaterThanOrEqual(HUGE_DIFF_MIN_BYTES);
    }
    // Round-2 semantics (codex-adv-1): the config is STILL diff.renames=false
    // from the probe above — the exact configuration where the worker's own
    // `git diff` does NOT attribute the rename and ingests the FULL deletion
    // plus the FULL addition. Silence here (round 1's verdict, pinned by this
    // very assertion) was a false negative in precisely the state the repo is
    // in: the guard must model the dump the worker will actually ingest and
    // NOTICE the hazard. (ratchet: round 1 asserted toEqual({}) at this line.)
    const noticed = checkHugeDiff("spawn-glm", { cwd: repo, branch: "feat/rename-artifact" });
    expect(noticed.note).toBeDefined();
    // the grouped hazard names BOTH sides — one logical change, both blobs
    expect(noticed.note).toContain("graphify-out/graph.json -> graphify-out/graph2.json");
    // ...while silence stays the honest verdict only when worker-side rename
    // detection is actually guaranteed: with diff.renames=true the worker's
    // diff prints a similarity header, not a blob dump.
    git(["config", "diff.renames", "true"]);
    expect(checkHugeDiff("spawn-glm", { cwd: repo, branch: "feat/rename-artifact" })).toEqual({});
  } finally { rmQuiet(repo); }
}, GIT_TEST_TIMEOUT_MS);

// ── the hazard the WORKER ingests, not the one the probe prints (R2 codex-adv-1) ─
//
// --no-renames splits a rename into a delete path and an add path, each
// weighing ~N of the pair's 2N — so the per-path dominance test reads ~50%
// and stays silent. That silence models the worker's ingest ONLY when the
// worker's own `git diff` will attribute the rename (diff.renames on, git's
// default since 2.9) and print a similarity header instead of the blobs.
// With diff.renames=false — a real repo/user setting — the worker ingests
// the FULL deletion plus the FULL addition, a multi-MiB text rename blows
// the context window, and the guard returning {} is exactly the failure
// HIMMEL-1778 exists to prevent. The regression below is the realistic
// "moved and tweaked" shape (a rename with a small edit, still attributed
// by an explicit -M), asserted under the worker-hazard config.

test("(REAL GIT): an un-attributed large text rename under diff.renames=false is NOTICED — the guard models the dump the worker will ingest", () => {
  const { repo, git } = makeGraphRepo();
  try {
    git(["checkout", "-b", "feat/move-artifact"]);
    git(["mv", "graphify-out/graph.json", "graphify-out/graph2.json"]);
    // a small edit on top of the move — the realistic moved-and-tweaked
    // rename; ~99.7% similar, so an explicit -M still attributes it as R
    appendFileSync(join(repo, "graphify-out/graph2.json"), `,\n  {"moved": "${"x".repeat(4096)}"}`);
    writeFileSync(join(repo, "src-touched.ts"), "export const touched = true;\n");
    git(["add", "."]);
    git(["commit", "-m", "move + tweak the tracked artifact"]);
    git(["config", "diff.renames", "false"]);
    // ratchet: round 1 measured the two sides as separate ~50% paths and
    // asserted silence — in the exact configuration where the worker's own
    // diff emits the full delete plus the full add.
    const res = checkHugeDiff("spawn-claudex", { cwd: repo, branch: "feat/move-artifact" });
    expect(res.note).toBeDefined();
    expect(res.note).toContain("spawn-claudex");
    // ONE logical hazard naming both sides, at the SUM of their blobs
    expect(res.note).toContain("graphify-out/graph.json -> graphify-out/graph2.json");
    expect(res.note).toMatch(/[0-9]+\.[0-9]% of the/);
  } finally { rmQuiet(repo); }
}, GIT_TEST_TIMEOUT_MS);

test("(REAL GIT): a branch NAME may legally carry Unicode bidi/separator controls — the warning escapes base and branch, not just the path", () => {
  const { repo, git } = makeGraphRepo();
  try {
    // Built from code points — not string-literal escapes — so the SOURCE
    // stays ASCII-clean while the value carries the raw controls. That git
    // ACCEPTS this ref name is part of the contract under test: ref names
    // reject ASCII controls by format but admit Cf and Zl/Zp.
    const poison = "feat/x" + String.fromCharCode(0x202e) + "y" + String.fromCharCode(0x2028) + "z";
    git(["branch", poison]);
    git(["checkout", poison]);
    appendFileSync(join(repo, "graphify-out/graph.json"), `,\n  {"regenerated": "${"x".repeat(2 * 1024 * 1024)}"}`);
    writeFileSync(join(repo, "src-touched.ts"), "export const touched = true;\n");
    git(["add", "."]);
    git(["commit", "-m", "regen graph + one source file"]);
    const res = checkHugeDiff("spawn-glm", { cwd: repo, branch: poison });
    expect(res.note).toBeDefined();
    // ratchet: round 1 interpolated the branch verbatim, so the raw bidi
    // override and line separator entered the note un-escaped.
    expect(res.note).toContain("feat/x\\u202ey\\u2028z");
    expect([...res.note!].some((ch) => /[\p{Cc}\p{Cf}\u2028\u2029]/u.test(ch))).toBe(false);
  } finally { rmQuiet(repo); }
}, GIT_TEST_TIMEOUT_MS);

// ── shared-seam pin ───────────────────────────────────────────────────────────

test("the predicate lives ONCE, in the shared module — both spawners import it, neither re-defines it (copy-paste drift: PR #1680, #1691)", () => {
  for (const f of ["scripts/telegram/spawn-glm.ts", "scripts/telegram/spawn-claudex.ts"]) {
    const src = readFileSync(f, "utf8");
    expect(src).toContain('checkHugeDiff("spawn-');
    expect(src).toContain('from "./huge-diff-guard"');
    expect(src).not.toContain("function findDominatingPath");
    expect(src).not.toContain("function changedPathBytes");
  }
});
