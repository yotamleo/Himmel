import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { mapFile, mapJournal } from "../agui/journal-mapper.ts";
import { commandVerdicts, extractLedgerVerdicts, extractVerdicts, parsePanelReport } from "../agui/review-panel.ts";
import type { AguiEvent } from "../agui/events.ts";
import { aguiViolations } from "./agui-schema.ts";

const FIX = join(import.meta.dir, "fixtures", "agui");
const HEAD = "0123456789abcdef0123456789abcdef01234567";

// Apply the emitted snapshot and deltas the way a client would (adds only).
function replayState(events: AguiEvent[]): unknown {
  let state: unknown;
  for (const ev of events) {
    if (ev.type === "STATE_SNAPSHOT") state = structuredClone(ev.snapshot);
    if (ev.type === "STATE_DELTA") {
      for (const op of ev.delta) {
        const keys = op.path.split("/").slice(1);
        let node = state as Record<string, unknown>;
        for (const k of keys.slice(0, -1)) node = node[k] as Record<string, unknown>;
        node[keys.at(-1)!] = op.value;
      }
    }
  }
  return state;
}

// A tool call appended to the review-panel fixture, with its result.
const tool = (n: number, name: string, input: Record<string, unknown>, isError = false, content = "ok") => [
  JSON.stringify({ type: "assistant", uuid: `a-x${n}`, sessionId: "sess-rev", message: { id: `msg_X${n}`, role: "assistant", content: [{ type: "tool_use", id: `toolu_x${n}`, name, input }] } }),
  JSON.stringify({ type: "user", uuid: `u-x${n}`, sessionId: "sess-rev", message: { role: "user", content: [{ type: "tool_result", tool_use_id: `toolu_x${n}`, content, ...(isError ? { is_error: true } : {}) }] } }),
];
const bash = (n: number, command: string, content = "ok") => tool(n, "Bash", { command }, false, content);
const amended = (id: string) => `ledger-append.sh: amended ${id} at ${HEAD.slice(0, 8)} -> {"verdict":"fixed"}`;
const withExtra = (extra: string[]) => mapJournal(readFileSync(join(FIX, "review-panel.jsonl"), "utf8") + extra.join("\n") + "\n").events;

describe("a /pr-check run", () => {
  const { events } = mapFile(join(FIX, "review-panel.jsonl"));
  const stateEvents = events.filter((e) => e.type === "STATE_SNAPSHOT" || e.type === "STATE_DELTA");

  test("the panel result snapshots the findings, then each recorded verdict is a delta", () => {
    expect(stateEvents.map((e) => e.type)).toEqual(["STATE_SNAPSHOT", "STATE_DELTA", "STATE_DELTA"]);
    expect(stateEvents[0]).toMatchObject({
      snapshot: {
        review: {
          head: HEAD, round: 1, maxRounds: 3,
          findings: [
            { id: "codex-1", severity: "crit", title: "The parser crashes on an empty line.", file: "scripts/demo/parse.ts", line: 42 },
            { id: "codex-2", severity: "imp", title: "The retry loop never backs off." },
            { id: "codex-3", severity: "sug", title: "Rename tmp to buffer for clarity.", file: "scripts/demo/parse.ts", line: 7 },
          ],
        },
      },
    });
  });

  test("the snapshot follows its TOOL_CALL_RESULT; deltas apply only on a successful result", () => {
    const panelResult = events.findIndex((e) => e.type === "TOOL_CALL_RESULT" && e.toolCallId === "toolu_panel");
    expect(events[panelResult + 1].type).toBe("STATE_SNAPSHOT");
    expect(stateEvents[1]).toMatchObject({
      delta: [
        { op: "add", path: "/review/findings/0/verdict", value: "agreed" },
        { op: "add", path: "/review/findings/1/verdict", value: "disproved" },
      ],
    });
    expect(stateEvents[2]).toMatchObject({
      delta: [
        { op: "add", path: "/review/findings/2/verdict", value: "deferred" },
        { op: "add", path: "/review/findings/2/ticket", value: "HIMMEL-9999" },
      ],
    });
  });

  test("verdicts land when the writer runs, not when a file merely contains them", () => {
    const writerResult = events.findIndex((e) => e.type === "TOOL_CALL_RESULT" && e.toolCallId === "toolu_write_verdicts_run");
    expect(events[writerResult + 1]).toBe(stateEvents[1]);
  });

  test("replaying the stream yields the final review state", () => {
    const final = replayState(events) as { review: { findings: Record<string, unknown>[] } };
    expect(final.review.findings.map((f) => [f.id, f.verdict, f.ticket])).toEqual([
      ["codex-1", "agreed", undefined],
      ["codex-2", "disproved", undefined],
      ["codex-3", "deferred", "HIMMEL-9999"],
    ]);
  });

  test("every event validates", () => {
    expect(events.flatMap((e) => aguiViolations(e as Record<string, unknown>))).toEqual([]);
  });

  test("a ledger row for another head, or one merely echoed, leaves the review alone", () => {
    const extra = [
      ...bash(1, "bash scripts/cr/ledger-append.sh amend --head fedcba9876543210fedcba9876543210fedcba98 --id codex-1 --set verdict=fixed --reason r", "ledger-append.sh: amended codex-1 at fedcba98 -> {}"),
      ...bash(2, "echo 'bash scripts/cr/ledger-append.sh finding --id codex-2 --verdict fixed --reason r'"),
      ...bash(3, `bash scripts/cr/ledger-append.sh amend --head ${HEAD} --id codex-2 --set verdict=fixed --reason r`, amended("codex-2")),
    ];
    const deltas = withExtra(extra).filter((e) => e.type === "STATE_DELTA");
    expect(deltas).toHaveLength(3);
    expect(deltas[2]).toMatchObject({ delta: [{ op: "add", path: "/review/findings/1/verdict", value: "fixed" }] });
  });

  // HIMMEL-4655 (codex-3): a command's success is not each ledger call's success.
  test("an amend applies only when its confirmation line is in the result", () => {
    const deltas = withExtra([
      ...bash(1, `bash scripts/cr/ledger-append.sh amend --head ${HEAD} --id codex-1 --set verdict=fixed --reason r || true`, "ledger-append.sh: amend found NO finding codex-1 at head 01234567 - nothing amended."),
      ...bash(2, `if false; then bash scripts/cr/ledger-append.sh amend --head ${HEAD} --id codex-2 --set verdict=fixed --reason r; fi`, ""),
      ...bash(3, `bash scripts/cr/ledger-append.sh amend --head ${HEAD} --id codex-1 --set verdict=fixed --reason r; bash scripts/cr/ledger-append.sh amend --head ${HEAD} --id codex-2 --set verdict=agreed --reason r || true`, amended("codex-1")),
    ]).filter((e) => e.type === "STATE_DELTA");
    expect(deltas).toHaveLength(3);
    expect(deltas[2]).toMatchObject({ delta: [{ op: "add", path: "/review/findings/0/verdict", value: "fixed" }] });
  });

  test("a finding row applies unless the ledger refused something, or it was appended as an amend", () => {
    const finding = (id: string, verdict: string) => `bash scripts/cr/ledger-append.sh finding --head ${HEAD} --id ${id} --verdict ${verdict} --reason r`;
    const deltas = withExtra([
      ...bash(1, `${finding("codex-1", "fixed")} || true`, "ledger-append.sh: finding codex-1 is ALREADY recorded at head 0123 with different content - NOTHING was written"),
      ...bash(2, `${finding("codex-1", "fixed")}; ${finding("codex-2", "fixed")} || true`, "ledger-append.sh: appended verdict amend for codex-1 at 01234567\nledger-append.sh: --verdict must be agreed|disproved (got 'x') - NOTHING was written"),
    ]).filter((e) => e.type === "STATE_DELTA");
    expect(deltas).toHaveLength(3);
    expect(deltas[2]).toMatchObject({ delta: [{ op: "add", path: "/review/findings/0/verdict", value: "fixed" }] });
  });

  // HIMMEL-4655 (codex-4): an Edit of a staged verdict file is followed, never shown stale.
  test("an Edit of a staged verdict file updates what write-verdicts --from-file applies", () => {
    const run = "bash scripts/cr/write-verdicts.sh aggregate --from-file /tmp/scratch/v2.txt";
    const deltas = withExtra([
      ...tool(1, "Write", { file_path: "/tmp/scratch/v2.txt", content: "VERDICT [codex-1] = agreed\nVERDICT [codex-2] = agreed\n" }),
      ...tool(2, "Edit", { file_path: "/tmp/scratch/v2.txt", old_string: "[codex-2] = agreed", new_string: "[codex-2] = conflict" }),
      ...bash(3, run),
      ...tool(4, "Edit", { file_path: "/tmp/scratch/v2.txt", old_string: "not in the cached text", new_string: "x" }),
      ...bash(5, run),
    ]).filter((e) => e.type === "STATE_DELTA");
    expect(deltas).toHaveLength(3);
    expect(deltas[2]).toMatchObject({
      delta: [
        { op: "add", path: "/review/findings/0/verdict", value: "agreed" },
        { op: "add", path: "/review/findings/1/verdict", value: "conflict" },
      ],
    });
  });

  test("a failed Edit leaves the staged text; replace_all replaces every match", () => {
    const deltas = withExtra([
      ...tool(1, "Write", { file_path: "/tmp/scratch/v3.txt", content: "VERDICT [codex-1] = agreed\nVERDICT [codex-2] = agreed\n" }),
      ...tool(2, "Edit", { file_path: "/tmp/scratch/v3.txt", old_string: "agreed", new_string: "disproved", replace_all: true }),
      ...tool(3, "Edit", { file_path: "/tmp/scratch/v3.txt", old_string: "disproved", new_string: "conflict", replace_all: true }, true),
      ...bash(4, "bash scripts/cr/write-verdicts.sh aggregate --from-file /tmp/scratch/v3.txt"),
    ]).filter((e) => e.type === "STATE_DELTA");
    expect(deltas[2]).toMatchObject({
      delta: [
        { op: "add", path: "/review/findings/0/verdict", value: "disproved" },
        { op: "add", path: "/review/findings/1/verdict", value: "disproved" },
      ],
    });
  });
});

describe("ledger confirmations and Edits, review follow-ups", () => {
  test("one confirmation line backs one amend row of an id", () => {
    const deltas = withExtra([
      ...bash(1, `bash scripts/cr/ledger-append.sh amend --head ${HEAD} --id codex-1 --set verdict=fixed --reason r; bash scripts/cr/ledger-append.sh amend --head ${HEAD} --id codex-1 --set verdict=agreed --reason r`, amended("codex-1")),
    ]).filter((e) => e.type === "STATE_DELTA");
    expect(deltas).toHaveLength(3);
    expect(deltas[2]).toMatchObject({ delta: [{ op: "add", path: "/review/findings/0/verdict", value: "fixed" }] });
  });

  test("an Edit that removes every VERDICT line is still followed by a later Edit", () => {
    const deltas = withExtra([
      ...tool(1, "Write", { file_path: "/tmp/scratch/v4.txt", content: "VERDICT [codex-1] = agreed\n" }),
      ...tool(2, "Edit", { file_path: "/tmp/scratch/v4.txt", old_string: "VERDICT [codex-1] = agreed", new_string: "nothing" }),
      ...tool(3, "Edit", { file_path: "/tmp/scratch/v4.txt", old_string: "nothing", new_string: "VERDICT [codex-1] = disproved" }),
      ...bash(4, "bash scripts/cr/write-verdicts.sh aggregate --from-file /tmp/scratch/v4.txt"),
    ]).filter((e) => e.type === "STATE_DELTA");
    expect(deltas[2]).toMatchObject({ delta: [{ op: "add", path: "/review/findings/0/verdict", value: "disproved" }] });
  });
});

describe("parsePanelReport", () => {
  test("text that is not a panel report gives null", () => {
    expect(parsePanelReport("README.md\nscripts")).toBeNull();
  });

  test("a clean panel gives an empty findings list", () => {
    const text = "pr-check: round 2 of 3 on feat/x\n# Critic Panel Review (2/2 critics responded)\n## Critical Issues (0 found)\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n";
    expect(parsePanelReport(text)).toEqual({ round: 2, maxRounds: 3, findings: [] });
  });

  test("sections after Suggestions are not findings", () => {
    const text = "# Critic Panel Review (1/1 critics responded)\n## Suggestions (1 found)\n- [codex-1]: Keep it.\n\n## Dropped Citations (1 dropped)\n- codex / Critical: a dropped line [x.ts:1]\n";
    expect(parsePanelReport(text)?.findings).toEqual([{ id: "codex-1", severity: "sug", title: "Keep it." }]);
  });
});

describe("extractVerdicts", () => {
  test("reads VERDICT lines; ignores anything else", () => {
    expect(extractVerdicts("VERDICT [a-1] = agreed\n  VERDICT [a-2] = deferred -> HIMMEL-12\nVERDICT [a-3] = maybe\nnoise")).toEqual([
      { id: "a-1", verdict: "agreed" },
      { id: "a-2", verdict: "deferred", ticket: "HIMMEL-12" },
    ]);
  });
});

describe("extractLedgerVerdicts", () => {
  test("reads finding rows and verdict amends; ignores other ledger verbs and fields", () => {
    expect(extractLedgerVerdicts("bash scripts/cr/ledger-append.sh finding --id \"b-1\" --verdict fixed --head abc")).toEqual([
      { id: "b-1", verdict: "fixed" },
    ]);
    expect(extractLedgerVerdicts(
      "bash scripts/cr/ledger-append.sh amend --head abc --id 'b-2' --set verdict=deferred --set deferred_to=HIMMEL-7 --set 'reason=out of scope' --reason 'step 4.5'",
    )).toEqual([{ id: "b-2", verdict: "deferred", ticket: "HIMMEL-7" }]);
    expect(extractLedgerVerdicts("bash scripts/cr/ledger-append.sh avail --id b-1 --verdict fixed")).toEqual([]);
    expect(extractLedgerVerdicts("bash scripts/cr/ledger-append.sh amend --head abc --id b-3 --set severity=sug --reason x")).toEqual([]);
  });

  test("a row carries the review head it was recorded against", () => {
    expect(extractLedgerVerdicts("bash scripts/cr/ledger-append.sh amend --head abc1234 --id b-1 --set verdict=fixed --reason r")).toEqual([
      { id: "b-1", verdict: "fixed", head: "abc1234" },
    ]);
  });

  test("only a command-position invocation counts, never a quoted mention", () => {
    expect(extractLedgerVerdicts("echo 'bash scripts/cr/ledger-append.sh finding --id b-1 --verdict fixed --reason x'")).toEqual([]);
    expect(extractLedgerVerdicts("printf '%s\\n' \"ledger-append.sh amend --id b-1 --set verdict=agreed --reason x\"")).toEqual([]);
    expect(extractLedgerVerdicts("cd /x && \"$R/scripts/cr/ledger-append.sh\" finding --id b-1 --verdict fixed")).toEqual([
      { id: "b-1", verdict: "fixed" },
    ]);
  });

  test("an unquoted flag value stops at a shell separator", () => {
    expect(extractLedgerVerdicts("bash scripts/cr/ledger-append.sh finding --id b-1 --verdict fixed; echo done")).toEqual([
      { id: "b-1", verdict: "fixed" },
    ]);
    expect(extractLedgerVerdicts("bash scripts/cr/ledger-append.sh finding --id b-2 --verdict agreed&&true")).toEqual([
      { id: "b-2", verdict: "agreed" },
    ]);
  });

  test("an invocation's flags end at its shell command; a separator inside quotes does not end it", () => {
    expect(extractLedgerVerdicts("bash scripts/cr/ledger-append.sh finding --id b-1; echo --verdict fixed")).toEqual([]);
    expect(extractLedgerVerdicts("bash scripts/cr/ledger-append.sh finding --reason 'a; b' --id b-2 --verdict fixed")).toEqual([
      { id: "b-2", verdict: "fixed" },
    ]);
  });
});

describe("commandVerdicts", () => {
  const files = (path: string) => (path === "v.txt" ? "VERDICT [c-1] = agreed" : undefined);

  test("write-verdicts reads its own --from-file, never a later command's", () => {
    expect(commandVerdicts("bash scripts/cr/write-verdicts.sh aggregate --from-file v.txt", files)).toEqual([
      { id: "c-1", verdict: "agreed" },
    ]);
    expect(commandVerdicts("bash scripts/cr/write-verdicts.sh aggregate; echo --from-file v.txt", files)).toEqual([]);
  });

  test("every invocation in one command counts, each with its own flags", () => {
    const command = [
      "bash scripts/cr/ledger-append.sh amend --head abc --id codex-1 --set verdict=agreed --reason r",
      "bash scripts/cr/ledger-append.sh amend --head abc --id codex-2 --set verdict=disproved --reason r",
      "bash scripts/cr/ledger-append.sh finding --head abc --id codex-3 --verdict deferred --deferred-to HIMMEL-5",
    ].join(" && ");
    expect(extractLedgerVerdicts(command)).toEqual([
      { id: "codex-1", verdict: "agreed" },
      { id: "codex-2", verdict: "disproved" },
      { id: "codex-3", verdict: "deferred", ticket: "HIMMEL-5" },
    ]);
  });
});
