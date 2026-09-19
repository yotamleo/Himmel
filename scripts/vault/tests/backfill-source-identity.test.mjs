// End-to-end tests for scripts/vault/backfill-source-identity.mjs (HIMMEL-3063).
//
// The script is run as a subprocess against a TEMP-DIR vault with a PATH-stub
// `gh` and a preloaded fetch stub — never the live vault, never the network.
// The fetch stub 404s raw.githubusercontent.com (what a private repo does) and
// throws for anything else, so a code path that reaches the network fails loud.
import { test, expect, describe, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = join(HERE, "..", "backfill-source-identity.mjs");
const FETCH_STUB = pathToFileURL(join(HERE, "fixtures", "fetch-stub.mjs")).href;
const GH_STUB = join(HERE, "fixtures", "gh-stub.sh");

const sha256 = (buf) => createHash("sha256").update(buf).digest("hex");

let work;
beforeEach(() => {
  work = mkdtempSync(join(tmpdir(), "backfill-identity-"));
});
afterEach(() => {
  rmSync(work, { recursive: true, force: true });
});

/**
 * One repo, one-or-more notes, run --apply (or dry-run) against the stubs.
 * `readme` = Buffer of the README bytes the authenticated API serves, or null
 * for "the API 404s". `pushedAt` is what GraphQL reports upstream.
 */
function run({ notes, readme = null, pushedAt = "2026-09-10T15:00:00Z", oid = "abc123", apply = true }) {
  const vault = join(work, "vault");
  const stubDir = join(work, "stub");
  mkdirSync(vault, { recursive: true });
  mkdirSync(stubDir, { recursive: true });
  for (const [rel, content] of Object.entries(notes)) {
    mkdirSync(dirname(join(vault, rel)), { recursive: true });
    writeFileSync(join(vault, rel), content);
  }
  writeFileSync(
    join(stubDir, "graphql.json"),
    JSON.stringify({
      data: { r0: { nameWithOwner: "Owner/Repo", defaultBranchRef: { target: { oid } }, pushedAt, stargazerCount: 5 } },
    }),
  );
  if (readme !== null) {
    // GitHub wraps the base64 at 60 columns with embedded newlines.
    const b64 = readme.toString("base64").replace(/(.{60})/g, "$1\n");
    writeFileSync(join(stubDir, "readme.b64"), b64 + "\n");
  }
  // A stub `gh` first on PATH, under a name the script's execFileSync("gh") finds.
  const binDir = join(work, "bin");
  mkdirSync(binDir, { recursive: true });
  writeFileSync(join(binDir, "gh"), readFileSync(GH_STUB), { mode: 0o755 });

  const args = ["--import", FETCH_STUB, SCRIPT, "--vault", vault];
  if (apply) args.push("--apply");
  const stdout = execFileSync("node", args, {
    encoding: "utf8",
    env: { ...process.env, PATH: `${binDir}:${process.env.PATH}`, GH_STUB_DIR: stubDir },
    stdio: ["ignore", "pipe", "ignore"],
  });
  const summary = JSON.parse(stdout.slice(stdout.indexOf("{")));
  const calls = existsSync(join(stubDir, "calls.log")) ? readFileSync(join(stubDir, "calls.log"), "utf8") : "";
  return { vault, summary, calls, read: (rel) => readFileSync(join(vault, rel)) };
}

const LF_NOTE = [
  "---",
  "type: tech-ingest",
  "source: https://github.com/owner/repo",
  "stars: 5",
  "---",
  "",
  "# repo",
  "",
].join("\n");

describe("item 1 — README hash comes from the authenticated README API, same bytes as luna-ingest", () => {
  // Non-ASCII + CRLF + trailing bytes: enough structure that any re-encoding or
  // newline normalisation would change the hash.
  const README = Buffer.from("# Title\r\n\r\nnaïve café → ok\r\n" + "x".repeat(200) + "\n", "utf8");

  test("private repo: raw.githubusercontent 404s, the README API serves it -> readme_sha256 present", () => {
    const r = run({ notes: { "30-Resources/Tech/repo.md": LF_NOTE }, readme: README });
    expect(r.read("30-Resources/Tech/repo.md").toString()).toContain(`readme_sha256: ${sha256(README)}`);
    expect(r.calls).toContain("repos/Owner/Repo/readme");
  });

  test("hashes the SAME bytes as luna-ingest's own gh|tr|base64|sha256sum pipeline", () => {
    const r = run({ notes: { "30-Resources/Tech/repo.md": LF_NOTE }, readme: README });
    const fromScript = r.read("30-Resources/Tech/repo.md").toString().match(/^readme_sha256: (\S+)$/m)[1];
    // luna-ingest SKILL.md Phase 1: `gh api "repos/$owner_repo/readme" --jq '.content' | tr -d '\n' | base64 -d`
    // then sha256sum of the decoded bytes. Same gh stub, same fixture.
    const pipeline = execFileSync(
      "bash",
      [
        "-c",
        'gh api "repos/Owner/Repo/readme" --jq ".content" | tr -d "\\n" | base64 -d | (sha256sum 2>/dev/null || shasum -a 256) | cut -d" " -f1',
      ],
      {
        encoding: "utf8",
        env: { ...process.env, PATH: `${join(work, "bin")}:${process.env.PATH}`, GH_STUB_DIR: join(work, "stub") },
      },
    ).trim();
    expect(fromScript).toBe(pipeline);
    expect(fromScript).toBe(sha256(README));
  });

  test("no README (API 404) omits readme_sha256 rather than hashing empty bytes", () => {
    const r = run({ notes: { "30-Resources/Tech/repo.md": LF_NOTE }, readme: null });
    const out = r.read("30-Resources/Tech/repo.md").toString();
    expect(out).not.toContain("readme_sha256");
    expect(out).toContain("upstream_commit: abc123"); // the rest of the identity still lands
  });
});
