import { expect, test } from "bun:test";
import { classify } from "./router";
test("classifies control/dispatch/followup/chat + validates key", () => {
  expect(classify("status")).toEqual({ kind: "control", verb: "status" });
  expect(classify("stop HIMMEL-9")).toEqual({ kind: "control", verb: "stop", ticket: "HIMMEL-9" });
  expect(classify("work on HIMMEL-216")).toEqual({ kind: "dispatch", ticket: "HIMMEL-216" });
  expect(classify("HIMMEL-216: also do Z")).toEqual({ kind: "followup", ticket: "HIMMEL-216", text: "also do Z" });
  expect(classify("hello there")).toEqual({ kind: "chat", text: "hello there" });
  expect(classify("work on lol-rm -rf")).toEqual({ kind: "chat", text: "work on lol-rm -rf" });
});

test("classifies /arm auto-commands (ticket|path + optional time), default smart", () => {
  // ticket arg, no time suffix → smart
  expect(classify("/arm HIMMEL-389")).toEqual({ kind: "auto", op: "arm-resume", arg: "HIMMEL-389", time: "smart" });
  // path arg → smart
  expect(classify("/arm handovers/yotam/x.md")).toEqual({ kind: "auto", op: "arm-resume", arg: "handovers/yotam/x.md", time: "smart" });
  // explicit time forms
  expect(classify("/arm HIMMEL-389 at 02:00")).toEqual({ kind: "auto", op: "arm-resume", arg: "HIMMEL-389", time: "02:00" });
  expect(classify("/arm HIMMEL-389 auto")).toEqual({ kind: "auto", op: "arm-resume", arg: "HIMMEL-389", time: "auto" });
  expect(classify("/arm HIMMEL-389 smart")).toEqual({ kind: "auto", op: "arm-resume", arg: "HIMMEL-389", time: "smart" });
  // leading/trailing whitespace tolerated (whole-message trim)
  expect(classify("  /arm HIMMEL-389  ")).toEqual({ kind: "auto", op: "arm-resume", arg: "HIMMEL-389", time: "smart" });
});

test("/arm with bad/missing pieces or mid-text falls through to chat (never auto)", () => {
  // garbage time → not auto
  expect(classify("/arm HIMMEL-389 at 99:99")).toEqual({ kind: "chat", text: "/arm HIMMEL-389 at 99:99" });
  expect(classify("/arm HIMMEL-389 at 2pm")).toEqual({ kind: "chat", text: "/arm HIMMEL-389 at 2pm" });
  // unknown trailing modifier → not auto
  expect(classify("/arm HIMMEL-389 now")).toEqual({ kind: "chat", text: "/arm HIMMEL-389 now" });
  // no arg → chat
  expect(classify("/arm")).toEqual({ kind: "chat", text: "/arm" });
  // mid-text /arm → chat (not anchored at start)
  expect(classify("please /arm HIMMEL-389")).toEqual({ kind: "chat", text: "please /arm HIMMEL-389" });
});

test("classifies /mergepub <pr> <sha12> auto-commands (HIMMEL-1213)", () => {
  expect(classify("/mergepub 123 abcdef123456")).toEqual({ kind: "auto", op: "merge-public", arg: "123", time: "abcdef123456" });
  // optional leading # on the PR number
  expect(classify("/mergepub #123 abcdef123456")).toEqual({ kind: "auto", op: "merge-public", arg: "123", time: "abcdef123456" });
  // full 40-char SHA accepted
  const sha40 = "0123456789abcdef0123456789abcdef01234567".slice(0, 40);
  expect(classify(`/mergepub 9 ${sha40}`)).toEqual({ kind: "auto", op: "merge-public", arg: "9", time: sha40 });
  // case-insensitive verb + hex, but the captured SHA is normalized to lowercase
  // (git oids are lowercase; auto-action.sh + the chokepoint compare lowercase) —
  // HIMMEL-1213 codex CR-2.
  expect(classify("/MERGEPUB 123 ABCDEF123456")).toEqual({ kind: "auto", op: "merge-public", arg: "123", time: "abcdef123456" });
  // leading/trailing whitespace tolerated (whole-message trim)
  expect(classify("  /mergepub 123 abcdef123456  ")).toEqual({ kind: "auto", op: "merge-public", arg: "123", time: "abcdef123456" });
});

test("/mergepub with bad/missing pieces or mid-text falls through to chat (never auto)", () => {
  // sha too short (<12 hex) — 11 hex is one below the floor, must fall through
  expect(classify("/mergepub 123 abcdef12345")).toEqual({ kind: "chat", text: "/mergepub 123 abcdef12345" });
  // sha too long (>40 hex) — the trailing chars break the whole-message anchor
  const sha41 = "0123456789abcdef0123456789abcdef012345678";
  expect(classify(`/mergepub 123 ${sha41}`)).toEqual({ kind: "chat", text: `/mergepub 123 ${sha41}` });
  // sha not hex
  expect(classify("/mergepub 123 not-a-sha")).toEqual({ kind: "chat", text: "/mergepub 123 not-a-sha" });
  // pr not numeric
  expect(classify("/mergepub abc abcdef123456")).toEqual({ kind: "chat", text: "/mergepub abc abcdef123456" });
  // pr too long (>6 digits)
  expect(classify("/mergepub 1234567 abcdef123456")).toEqual({ kind: "chat", text: "/mergepub 1234567 abcdef123456" });
  // missing sha
  expect(classify("/mergepub 123")).toEqual({ kind: "chat", text: "/mergepub 123" });
  // no args
  expect(classify("/mergepub")).toEqual({ kind: "chat", text: "/mergepub" });
  // mid-text → chat (not anchored at start)
  expect(classify("please /mergepub 123 abcdef123456")).toEqual({ kind: "chat", text: "please /mergepub 123 abcdef123456" });
  // trailing garbage after a valid pair → chat (whole-message anchor)
  expect(classify("/mergepub 123 abcdef123456 please")).toEqual({ kind: "chat", text: "/mergepub 123 abcdef123456 please" });
});
