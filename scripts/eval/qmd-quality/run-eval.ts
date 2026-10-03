// scripts/eval/qmd-quality/run-eval.ts - run the golden set through qmd's SDK
// in each retrieval mode and write the ranked lists (HIMMEL-4184). Called by
// qmd-quality.sh, which hands it a SNAPSHOT of the index (the SDK's store
// opens read-write and caches LLM calls into the DB).
//
//   bun run-eval.ts --index <sqlite> --golden <jsonl> --out <runs.jsonl>
//                   [--modes lex,vec,hybrid,hybrid-rerank] [--scope all|golden]
//                   [--candidate-limit N]
//
// Modes (every one but `auto` is deterministic: no generative LLM call):
//   lex            BM25 on the golden row's `lex` keywords (else its query)
//   vec            vector search on the natural-language query
//   hybrid         lex + vec sub-queries fused by RRF, rerank OFF
//   hybrid-rerank  the same, reranked, with the row's `intent`
//   hybrid-hyde    lex + vec + hyde (the row's `hyde` passage), reranked
//   auto           the plain `query` path: LLM expansion + rerank (MCP default)
// --scope all searches every default collection (what an unscoped agent call
// sees); golden restricts each query to its golden collections.
import { appendFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { readJsonl, validateGolden, type Golden } from "./score.ts";

type GoldenRow = Golden & { lex?: string; intent?: string; hyde?: string };

function arg(name: string, dflt?: string): string | undefined {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : dflt;
}

const indexPath = arg("--index");
const goldenPath = arg("--golden");
const outPath = arg("--out");
const modes = (arg("--modes", "lex,vec,hybrid,hybrid-rerank") as string).split(",");
const scope = arg("--scope", "all") as string;
const candidateLimit = Number(arg("--candidate-limit", "40"));
const LIMIT = 10;
const KNOWN = ["lex", "vec", "hybrid", "hybrid-rerank", "hybrid-hyde", "auto"];

if (!indexPath || !goldenPath || !outPath) {
  console.error("usage: bun run-eval.ts --index <sqlite> --golden <jsonl> --out <runs.jsonl> [--modes ...] [--scope all|golden]");
  process.exit(64);
}
const unknown = modes.filter((m) => !KNOWN.includes(m));
if (unknown.length || !["all", "golden"].includes(scope)) {
  console.error(`run-eval: unknown mode(s) '${unknown.join(",")}' or scope '${scope}'`);
  process.exit(64);
}
const golden = readJsonl<GoldenRow>(goldenPath);
const bad = validateGolden(golden);
if (bad) {
  console.error(`run-eval: ${bad}`);
  process.exit(2);
}

const forkDir = process.env.QMD_FORK_DIR || join(homedir(), ".himmel", "qmd-fork");
const sdk = await import(join(forkDir, "dist", "index.js"));
const store = await sdk.createStore({ dbPath: indexPath });

// A result's identity as the golden set spells it: <collection>/<path>.
function docKey(r: any): string {
  const f: string = r.file ?? r.filepath ?? "";
  if (f.startsWith("qmd://")) return f.slice("qmd://".length).split("?")[0]!;
  return `${r.collectionName}/${r.displayPath}`;
}

function dedupe(keys: string[]): string[] {
  return [...new Set(keys)];
}

writeFileSync(outPath, "");
for (const mode of modes) {
  const t0 = performance.now();
  for (const g of golden) {
    const collections = scope === "golden" ? g.collections : undefined;
    const lex = g.lex || g.query;
    const s = performance.now();
    let results: any[] = [];
    let error: string | undefined;
    // A query qmd refuses (e.g. a `-term` inside a vec sub-query) is what an
    // agent sending it would get: record it as a miss with its error.
    try {
    switch (mode) {
      case "lex":
        results = await store.searchLex(lex, { limit: LIMIT, collection: collections });
        break;
      case "vec":
        results = await store.searchVector(g.query, { limit: LIMIT, collection: collections });
        break;
      case "hybrid":
      case "hybrid-rerank":
      case "hybrid-hyde": {
        const queries = [{ type: "lex", query: lex }, { type: "vec", query: g.query }];
        if (mode === "hybrid-hyde" && g.hyde) queries.push({ type: "hyde", query: g.hyde });
        results = await store.search({
          queries,
          collections,
          limit: LIMIT,
          candidateLimit,
          rerank: mode !== "hybrid",
          intent: mode === "hybrid" ? undefined : g.intent,
        });
        break;
      }
      case "auto":
        results = await store.search({ query: g.query, intent: g.intent, collections, limit: LIMIT, candidateLimit });
        break;
      default:
        throw new Error(`unreachable mode ${mode}`);
    }
    } catch (e) {
      error = (e as Error).message;
    }
    const row = { id: g.id, mode, ranked: dedupe(results.map(docKey)).slice(0, LIMIT), ms: Math.round(performance.now() - s), ...(error ? { error } : {}) };
    appendFileSync(outPath, JSON.stringify(row) + "\n");
  }
  console.error(`run-eval: ${mode} done in ${((performance.now() - t0) / 1000).toFixed(1)}s for ${golden.length} queries`);
}
await store.close();
