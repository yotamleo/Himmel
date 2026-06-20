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
