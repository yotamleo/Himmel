import { existsSync, readFileSync, watch } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildFleet, type FleetRoots } from "./aggregator/fleet";
import { readEscalations } from "./aggregator/escalations";

// Complete against the process-env provider keys documented in .env.example
// (plus the Claude/OpenAI/z.ai keys the fleet itself may run under). The page is
// read-only localhost, but the served process must never expose a live key.
export const PROVIDER_KEY_NAMES = [
  "ZAI_API_KEY",
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_AUTH_TOKEN",
  "OPENAI_API_KEY",
  "GEMINI_API_KEY",
  "GOOGLE_API_KEY",
  "XAI_API_KEY",
  "PERPLEXITY_API_KEY",
  "DASHSCOPE_API_KEY",
  "NVIDIA_API_KEY",
  "OPENROUTER_API_KEY",
  "DEEPSEEK_API_KEY",
  "OLLAMA_API_KEY",
  "TELEGRAM_BOT_TOKEN",
  "JIRA_API_TOKEN",
  "BITBUCKET_API_TOKEN",
  "CONFLUENCE_API_TOKEN",
] as const;

export function scrubProviderKeys(env: Record<string, string | undefined>): void {
  for (const k of PROVIDER_KEY_NAMES) delete env[k];
}

// Resolve where codex-companion writes its job state, mirroring the fallback
// chain in scripts/codex/companion-liveness.sh (first hit wins):
//   $CLAUDE_PLUGIN_DATA -> ~/.claude/plugins/data/codex-openai-codex -> <tmpdir>/codex-companion
// readCodexJobs treats the arg as a plugin-data root (<root>/state) or, when no
// /state subdir exists (the tmpdir case), as the bare state root.
export function resolveCodexStateRoot(env: Record<string, string | undefined> = process.env): string {
  if (env.CLAUDE_PLUGIN_DATA) return env.CLAUDE_PLUGIN_DATA;
  const home = env.HOME ?? env.USERPROFILE;
  if (home) {
    const p = join(home, ".claude", "plugins", "data", "codex-openai-codex");
    if (existsSync(p)) return p;
  }
  return join(tmpdir(), "codex-companion");
}

export type ServerOpts = { port?: number; stateRoot: string; bridgeRoot?: string; pluginDataRoot?: string; env?: Record<string, string | undefined> };

function rootsFor(opts: ServerOpts): FleetRoots {
  return { bridgeRoot: opts.bridgeRoot ?? opts.stateRoot, stateRoot: opts.stateRoot, pluginDataRoot: opts.pluginDataRoot ?? join(opts.stateRoot, "codex-plugin-data") };
}

function jsonResponse(value: unknown): Response {
  return new Response(JSON.stringify(value), { headers: { "content-type": "application/json" } });
}

function staticResponse(path: string, contentType: string): Response {
  return new Response(readFileSync(path), { headers: { "content-type": contentType } });
}

export function eventsResponse(watchRoots: string | string[], watchFactory: typeof watch = watch): Response {
  // Watch every distinct root (fleet-control state dir AND the bridge root,
  // where glm-sessions/ lives) so all lane changes ping a refetch. A root
  // nested inside an already-watched recursive root is skipped as redundant.
  const requested = (Array.isArray(watchRoots) ? watchRoots : [watchRoots]).filter(Boolean);
  const isUnder = (child: string, parent: string) => child.startsWith(parent + "/") || child.startsWith(parent + "\\");
  const roots = requested.filter((r, i) =>
    requested.indexOf(r) === i && !requested.some((other) => other !== r && isUnder(r, other)));
  const watchers: ReturnType<typeof watch>[] = [];
  let closed = false;
  const closeAll = () => { closed = true; for (const w of watchers) w.close(); };
  const enc = new TextEncoder();
  const stream = new ReadableStream({
    start(controller) {
      const emit = () => {
        if (closed) return;
        try {
          controller.enqueue(enc.encode("event: refetch\ndata: {}\n\n"));
        } catch {
          // The consumer went away between the fs event and the enqueue: stop
          // emitting and release the watchers instead of throwing on a dead stream.
          closeAll();
        }
      };
      const degrade = (reason: string) => {
        if (closed) return;
        try { controller.enqueue(enc.encode(`event: degraded\ndata: ${JSON.stringify({ reason })}\n\n`)); } catch { /* stream already gone */ }
      };
      emit();
      let watching = 0;
      for (const root of roots) {
        try {
          if (existsSync(root)) {
            watchers.push(watchFactory(root, { recursive: true }, emit));
            watching++;
          }
        } catch (e) {
          degrade(`fs.watch unavailable for ${root}: ${e instanceof Error ? e.message : String(e)}`);
        }
      }
      if (watching === 0) degrade("no watchable roots; live updates unavailable");
    },
    // WHATWG Streams: start()'s return value is NOT a teardown hook - teardown on
    // consumer cancel belongs here, so the watchers are always released.
    cancel() {
      closeAll();
    },
  });
  return new Response(stream, { headers: { "content-type": "text/event-stream", "cache-control": "no-cache" } });
}

export function startServer(opts: ServerOpts): { server: import("bun").Server; port: number } {
  scrubProviderKeys(opts.env ?? process.env);
  const publicRoot = join(import.meta.dir, "public");
  const roots = rootsFor(opts);
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: opts.port ?? 7350,
    fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/fleet") return jsonResponse(buildFleet(roots));
      if (url.pathname === "/escalations") return jsonResponse(readEscalations(roots.bridgeRoot));
      if (url.pathname === "/events") return eventsResponse([opts.stateRoot, roots.bridgeRoot]);
      if (url.pathname === "/") return staticResponse(join(publicRoot, "index.html"), "text/html; charset=utf-8");
      if (url.pathname === "/app.js") return staticResponse(join(publicRoot, "app.js"), "application/javascript; charset=utf-8");
      return new Response("not found", { status: 404 });
    },
  });
  return { server, port: server.port };
}

export function resolveServeRoots(env: Record<string, string | undefined> = process.env): { stateRoot: string; bridgeRoot: string } {
  // glm-sessions/ lives under the BRIDGE root; fleet-control state is its
  // child dir. Deriving bridgeRoot from stateRoot's default parent (or the
  // explicit envs) keeps the GLM/escalation readers pointed at the right tree.
  const bridgeRoot = env.FLEET_CONTROL_BRIDGE_ROOT ?? env.BRIDGE_ROOT ?? join(env.HOME ?? process.cwd(), ".claude", "handover", "bridge");
  const stateRoot = env.FLEET_CONTROL_STATE_ROOT ?? join(bridgeRoot, "fleet-control");
  return { stateRoot, bridgeRoot };
}

if (import.meta.main && process.argv[2] === "serve") {
  const { stateRoot, bridgeRoot } = resolveServeRoots();
  const { port } = startServer({ port: Number(process.env.FLEET_CONTROL_PORT ?? 7350), stateRoot, bridgeRoot, pluginDataRoot: resolveCodexStateRoot() });
  console.log(`fleet-control listening on http://127.0.0.1:${port}`);
}
