#!/usr/bin/env node
// mock-anthropic.mjs — scripted local Anthropic API for zero-cost Claude turn tests
// (HIMMEL-4411, epic HIMMEL-4409 step 2). Loopback only, no dependencies.
//
//   node mock-anthropic.mjs --fixture <file.json> --port-file <file> [--log <file>]
//
// Serves POST /v1/messages (SSE: message_start, content_block_start/delta/stop,
// message_delta with stop_reason, message_stop) and POST /v1/messages/count_tokens.
// Every other path gets a 404; EVERY request is appended to --log as one JSON
// line {method, path, status, turn, body}. The port is ephemeral (listen on 0)
// and written to --port-file once the socket is bound, so a reader that sees the
// file knows the server is up.
//
// Fixture: {"turns":[{"match"?: "<substring of the request body>", "reply": <block|[blocks]>}]}
//   block = {"type":"text","text":"…"} | {"type":"tool_use","name":"Bash","input":{…}}
// A request takes the first UNUSED turn whose match (if any) occurs in its body;
// when none is left it gets a plain-text reply and is logged turn:null.
// No record mode (MVP). ponytail: sequential/substring matching only, regex or
// request-shape matchers when a scenario needs them.
import http from "node:http";
import fs from "node:fs";

const arg = (name) => {
  const i = process.argv.indexOf(name);
  return i > 0 ? process.argv[i + 1] : undefined;
};
const fixturePath = arg("--fixture");
const portFile = arg("--port-file");
const logFile = arg("--log");
if (!fixturePath || !portFile) {
  console.error("usage: mock-anthropic.mjs --fixture <file> --port-file <file> [--log <file>]");
  process.exit(2);
}
const turns = JSON.parse(fs.readFileSync(fixturePath, "utf8")).turns;
if (!Array.isArray(turns)) {
  console.error("mock-anthropic: fixture needs a turns array");
  process.exit(2);
}
const used = new Set();

const log = (rec) => {
  if (logFile) fs.appendFileSync(logFile, JSON.stringify(rec) + "\n");
};

const sse = (res, event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);

function streamReply(res, model, blocks) {
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
  const toolUse = blocks.some((b) => b.type === "tool_use");
  sse(res, "message_start", {
    type: "message_start",
    message: {
      id: "msg_mock_" + Date.now(), type: "message", role: "assistant", model, content: [],
      stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 },
    },
  });
  blocks.forEach((b, index) => {
    if (b.type === "text") {
      sse(res, "content_block_start", { type: "content_block_start", index, content_block: { type: "text", text: "" } });
      sse(res, "content_block_delta", { type: "content_block_delta", index, delta: { type: "text_delta", text: b.text } });
    } else {
      sse(res, "content_block_start", {
        type: "content_block_start", index,
        content_block: { type: "tool_use", id: `toolu_mock_${index}_${Date.now()}`, name: b.name, input: {} },
      });
      sse(res, "content_block_delta", {
        type: "content_block_delta", index,
        delta: { type: "input_json_delta", partial_json: JSON.stringify(b.input ?? {}) },
      });
    }
    sse(res, "content_block_stop", { type: "content_block_stop", index });
  });
  sse(res, "message_delta", {
    type: "message_delta",
    delta: { stop_reason: toolUse ? "tool_use" : "end_turn", stop_sequence: null },
    usage: { output_tokens: 1 },
  });
  sse(res, "message_stop", { type: "message_stop" });
  res.end();
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const raw = Buffer.concat(chunks).toString("utf8");
    const path = req.url.split("?")[0];
    let body = null;
    try { body = raw ? JSON.parse(raw) : null; } catch { body = raw; }
    if (req.method === "POST" && path === "/v1/messages") {
      let turn = null;
      for (let i = 0; i < turns.length; i++) {
        if (used.has(i)) continue;
        if (turns[i].match && !raw.includes(turns[i].match)) continue;
        turn = i;
        break;
      }
      if (turn !== null) used.add(turn);
      const reply = turn === null ? { type: "text", text: "mock: no scripted turn left" } : turns[turn].reply;
      log({ method: req.method, path, status: 200, turn, body });
      return streamReply(res, (body && body.model) || "mock-model", Array.isArray(reply) ? reply : [reply]);
    }
    if (req.method === "POST" && path === "/v1/messages/count_tokens") {
      log({ method: req.method, path, status: 200, turn: null, body });
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(JSON.stringify({ input_tokens: 1 }));
    }
    log({ method: req.method, path, status: 404, turn: null, body });
    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ type: "error", error: { type: "not_found_error", message: "mock-anthropic: " + path } }));
  });
});

server.listen(0, "127.0.0.1", () => {
  const tmp = portFile + ".tmp";
  fs.writeFileSync(tmp, String(server.address().port) + "\n");
  fs.renameSync(tmp, portFile); // atomic: a reader never sees a partial port
});
for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, () => server.close(() => process.exit(0)));
