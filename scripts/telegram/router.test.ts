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
