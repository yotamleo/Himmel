import { test, expect, describe } from "bun:test";
import {
  parseGithubSource,
  groupNotesByRepo,
  applyCanonicalRenames,
  buildIdentityFields,
  patchFrontmatter,
} from "../lib/source-identity.mjs";

describe("parseGithubSource", () => {
  test("parses a plain repo URL", () => {
    expect(parseGithubSource("https://github.com/owner/repo")).toEqual({ owner: "owner", repo: "repo" });
  });

  test("strips trailing slash, .git suffix and /tree|/blob subpaths", () => {
    expect(parseGithubSource("https://github.com/owner/repo/")).toEqual({ owner: "owner", repo: "repo" });
    expect(parseGithubSource("https://github.com/owner/repo.git")).toEqual({ owner: "owner", repo: "repo" });
    expect(parseGithubSource("https://github.com/owner/repo/tree/main")).toEqual({ owner: "owner", repo: "repo" });
    expect(parseGithubSource("https://github.com/owner/repo/blob/main/README.md")).toEqual({ owner: "owner", repo: "repo" });
  });

  test("returns null for a non-github source", () => {
    expect(parseGithubSource("https://bitbucket.org/ws/repo")).toBeNull();
    expect(parseGithubSource("https://github.com/owner/repo/issues/5")).toBeNull();
  });
});

describe("groupNotesByRepo — key on owner/repo, not note path", () => {
  test("two notes at different paths pointing at the same repo land in one group", () => {
    const notes = [
      { path: "30-Resources/Tech/router-for-me-cliproxyapi.md", owner: "router-for-me", repo: "CLIProxyAPI" },
      { path: "30-Resources/Tech/CLIProxyAPI.md", owner: "router-for-me", repo: "CLIProxyAPI" },
      { path: "Clippings/_done/other.md", owner: "someone", repo: "other-repo" },
    ];
    const grouped = groupNotesByRepo(notes);
    expect(grouped.size).toBe(2);
    expect(grouped.get("router-for-me/cliproxyapi").length).toBe(2);
    expect(grouped.get("someone/other-repo").length).toBe(1);
  });

  test("grouping is case-insensitive on the key", () => {
    const notes = [
      { path: "a.md", owner: "Owner", repo: "Repo" },
      { path: "b.md", owner: "owner", repo: "repo" },
    ];
    const grouped = groupNotesByRepo(notes);
    expect(grouped.size).toBe(1);
    expect(grouped.get("owner/repo").length).toBe(2);
  });
});

describe("applyCanonicalRenames — rename resolution", () => {
  test("merges two raw keys that resolve to the same canonical nameWithOwner", () => {
    const grouped = new Map([
      ["all-hands-ai/openhands", [{ path: "a.md", owner: "all-hands-ai", repo: "openhands" }]],
      ["opendevin/opendevin", [{ path: "b.md", owner: "OpenDevin", repo: "OpenDevin" }]],
    ]);
    const canonicalByRawKey = new Map([
      ["all-hands-ai/openhands", "OpenHands/OpenHands"],
      ["opendevin/opendevin", "OpenHands/OpenHands"],
    ]);
    const { merged, renames } = applyCanonicalRenames(grouped, canonicalByRawKey);
    expect(merged.size).toBe(1);
    const entry = merged.get("OpenHands/OpenHands");
    expect(entry.notes.length).toBe(2);
    expect(entry.notes.map((n) => n.path).sort()).toEqual(["a.md", "b.md"]);
    // both raw keys differ in case/name from the canonical -> both are renames
    expect(renames.length).toBe(2);
    expect(renames.map((r) => r.from).sort()).toEqual(["all-hands-ai/openhands", "opendevin/opendevin"]);
    expect(renames.every((r) => r.to === "OpenHands/OpenHands")).toBe(true);
  });

  test("a pure-casing match to the same name is not reported as a rename", () => {
    const grouped = new Map([["owner/repo", [{ path: "a.md", owner: "owner", repo: "repo" }]]]);
    const canonicalByRawKey = new Map([["owner/repo", "owner/repo"]]);
    const { merged, renames } = applyCanonicalRenames(grouped, canonicalByRawKey);
    expect(merged.size).toBe(1);
    expect(renames.length).toBe(0);
  });

  test("a raw key with no canonical entry (fetch failed / repo gone) keeps its own group untouched", () => {
    const grouped = new Map([["ghost/repo", [{ path: "a.md", owner: "ghost", repo: "repo" }]]]);
    const canonicalByRawKey = new Map(); // no entry at all
    const { merged, renames } = applyCanonicalRenames(grouped, canonicalByRawKey);
    expect(merged.size).toBe(1);
    expect(merged.has("ghost/repo")).toBe(true);
    expect(renames.length).toBe(0);
  });
});

describe("buildIdentityFields", () => {
  test("full case: commit, pushed_at, readme hash, and a stars/pushed_at delta", () => {
    const fields = buildIdentityFields({
      oid: "abc123",
      upstreamPushedAt: "2026-09-10T00:00:00Z",
      readmeSha256: "deadbeef",
      revalidatedAt: "2026-09-16T00:00:00Z",
      existingStars: 964,
      newStars: 1200,
      existingPushedAt: "2026-05-21",
      newPushedAtDate: "2026-09-10",
    });
    const keys = fields.map((f) => f.key);
    expect(keys).toEqual([
      "upstream_commit",
      "upstream_pushed_at",
      "readme_sha256",
      "last_revalidated",
      "revalidation_delta",
    ]);
    expect(fields.find((f) => f.key === "upstream_commit").value).toBe("abc123");
    const delta = fields.find((f) => f.key === "revalidation_delta").value;
    expect(delta).toContain("964");
    expect(delta).toContain("1200");
  });

  test("missing README omits readme_sha256 entirely rather than hashing an absent file", () => {
    const fields = buildIdentityFields({
      oid: "abc123",
      upstreamPushedAt: "2026-09-10T00:00:00Z",
      readmeSha256: null,
      revalidatedAt: "2026-09-16T00:00:00Z",
      existingStars: null,
      newStars: 5,
      existingPushedAt: null,
      newPushedAtDate: "2026-09-10",
    });
    expect(fields.some((f) => f.key === "readme_sha256")).toBe(false);
  });

  test("missing upstream_commit (fetch failed) omits the field, others still populate", () => {
    const fields = buildIdentityFields({
      oid: null,
      upstreamPushedAt: "2026-09-10T00:00:00Z",
      readmeSha256: "deadbeef",
      revalidatedAt: "2026-09-16T00:00:00Z",
      existingStars: null,
      newStars: null,
      existingPushedAt: null,
      newPushedAtDate: null,
    });
    expect(fields.some((f) => f.key === "upstream_commit")).toBe(false);
    expect(fields.some((f) => f.key === "readme_sha256")).toBe(true);
  });
});

describe("patchFrontmatter — additive write + idempotence", () => {
  const original = [
    "---",
    "type: tech-ingest",
    "source: https://github.com/owner/repo",
    "source_type: github",
    "ingested_at: 2026-06-14T18:53:09Z",
    "last_revalidated: 2026-06-14T18:53:09Z",
    "stars: 964",
    "safety_flag:",
    "---",
    "",
    "# repo",
    "",
    "body text mentioning source: not a frontmatter key",
    "",
  ].join("\n");

  test("appends new fields without touching a single existing line, and never touches the body", () => {
    const { content, changed } = patchFrontmatter(original, [
      { key: "upstream_commit", value: "abc123" },
      { key: "readme_sha256", value: "deadbeef" },
    ]);
    expect(changed).toBe(true);
    const originalLines = original.split("\n");
    const newLines = content.split("\n");
    // every original line must still be present, in order, unmodified
    for (const line of originalLines) {
      expect(newLines).toContain(line);
    }
    // body content is byte-identical
    expect(content.endsWith(original.split("---\n").slice(2).join("---\n"))).toBe(true);
    expect(content).toContain("upstream_commit: abc123");
    expect(content).toContain("readme_sha256: deadbeef");
  });

  test("a field that already exists is left untouched, never overwritten or duplicated", () => {
    const { content, changed } = patchFrontmatter(original, [
      { key: "last_revalidated", value: "2099-01-01T00:00:00Z" },
      { key: "upstream_commit", value: "abc123" },
    ]);
    // last_revalidated already existed with the old value -> untouched
    expect(content).toContain("last_revalidated: 2026-06-14T18:53:09Z");
    expect(content).not.toContain("2099-01-01T00:00:00Z");
    // it must not appear twice
    expect(content.split("last_revalidated:").length - 1).toBe(1);
    expect(content).toContain("upstream_commit: abc123");
    expect(changed).toBe(true); // upstream_commit was genuinely new
  });

  test("re-running with fields that are all already present is a true no-op (idempotent)", () => {
    const first = patchFrontmatter(original, [{ key: "upstream_commit", value: "abc123" }]);
    const second = patchFrontmatter(first.content, [{ key: "upstream_commit", value: "abc123" }]);
    expect(second.changed).toBe(false);
    expect(second.content).toBe(first.content);
  });

  test("a value containing a colon-space sequence is quoted so it stays valid YAML", () => {
    const { content } = patchFrontmatter(original, [
      { key: "revalidation_delta", value: 'stars: 964→1200 (+236)' },
    ]);
    expect(content).toContain('revalidation_delta: "stars: 964→1200 (+236)"');
  });
});
