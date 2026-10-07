import { test, expect } from "bun:test";
import { join } from "path";
import { createHash } from "node:crypto";
import { cp, mkdir, mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import pkg from "../package.json";

const ROOT = join(import.meta.dir, "..");

test("pilot pins stable SDK v2 without the v1 monolith", () => {
  expect(pkg.dependencies).toEqual({ "@modelcontextprotocol/server": "2.3.1" });
});

test("stdio start refreshes an old dependency directory and preserves the v1 contract", async () => {
  const installed = await mkdtemp(join(tmpdir(), "luna-correlate-upgrade-"));
  for (const file of ["package.json", "bun.lock", "server.ts", "src"]) {
    await cp(join(ROOT, file), join(installed, file), { recursive: true });
  }
  // An existing directory is not proof that the newly pinned SDK is installed.
  await mkdir(join(installed, "node_modules"));
  const child = Bun.spawn([process.execPath, "run", "--cwd", installed, "--silent", "start"], {
    stdin: "pipe", stdout: "pipe", stderr: "pipe",
  });
  const lines = child.stdout.pipeThrough(new TextDecoderStream()).getReader();
  let buffer = "";
  let id = 0;
  async function request(method: string, params: Record<string, unknown>) {
    const requestId = ++id;
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: requestId, method, params }) + "\n");
    await child.stdin.flush();
    for (;;) {
      const newline = buffer.indexOf("\n");
      if (newline >= 0) {
        const response = JSON.parse(buffer.slice(0, newline));
        buffer = buffer.slice(newline + 1);
        if (response.id === requestId) {
          expect(response.error).toBeUndefined();
          return response.result;
        }
      } else {
        const next = await lines.read();
        if (next.done) throw new Error("server closed before responding");
        buffer += next.value;
      }
    }
  }
  try {
    const initialized = await request("initialize", {
      protocolVersion: "2025-11-25", capabilities: {},
      clientInfo: { name: "stdio-regression", version: "1.0.0" },
    });
    expect(initialized.protocolVersion).toBe("2025-11-25");
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
    await child.stdin.flush();
    const listed = await request("tools/list", {});
    // v1 1.32.1 baseline: full names, descriptions and JSON schemas, not live source.
    expect(createHash("sha256").update(JSON.stringify(listed.tools)).digest("hex")).toBe(
      "4ebc62e55013784ada653ca4da11272aec08aa08fea0d079763ddf850a05537c",
    );
    expect(listed.tools.map((tool: { name: string }) => tool.name)).toEqual([
      "factors.cache", "series.load", "correlate", "signals.report", "signals.dashboard",
    ]);
    const output = await request("tools/call", {
      name: "series.load", arguments: { name: "pain-fixture", dir: join(import.meta.dir, "fixtures") },
    });
    expect(output.isError).toBeUndefined();
    expect(output.content).toHaveLength(1);
    expect(output.content[0].type).toBe("text");
    const series = JSON.parse(output.content[0].text);
    expect(series.n).toBe(10);
    expect(series.points[0]).toEqual({ date: "2026-05-01", value: 2 });
    expect(output.content[0].text).toBe(JSON.stringify(series, null, 2));
    const invalid = await request("tools/call", { name: "series.load", arguments: { name: 42 } });
    expect(invalid).toEqual({
      content: [{ type: "text", text: 'series.load failed: "name" must be a string' }], isError: true,
    });
    const unknown = await request("tools/call", { name: "nope", arguments: {} });
    expect(unknown).toEqual({
      content: [{ type: "text", text: "nope failed: unknown tool: nope" }], isError: true,
    });
    await child.stdin.end();
    expect(await child.exited).toBe(0);
    expect(await new Response(child.stderr).text()).not.toContain("Cannot find module");
  } finally {
    child.kill();
    await child.exited;
    lines.releaseLock();
    // Leave the isolated upgrade fixture for host temporary-directory cleanup.
  }
}, 30000);
