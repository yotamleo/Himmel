import { test, expect } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";

test("serves static fleet-control page and app js", async () => {
  const stateRoot = mkdtempSync(join(tmpdir(), "fleet-page-"));
  const { server, port } = startServer({ port: 0, stateRoot });
  try {
    const html = await fetch(`http://127.0.0.1:${port}/`);
    expect(html.headers.get("content-type")).toContain("text/html");
    expect(await html.text()).toContain('id="fleet-table"');

    const js = await fetch(`http://127.0.0.1:${port}/app.js`);
    expect(js.headers.get("content-type")).toContain("application/javascript");
  } finally { server.stop(); }
});
