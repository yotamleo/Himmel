// scripts/telegram/session-status.test.ts — HIMMEL-1250 Increment 1.
// Hermetic: no real network send (sendAlert is injected, same pattern as
// luna-sync-alert.test.ts's checkLunaSync tests), no real token file read —
// main()'s I/O path is never exercised here.
import { expect, test } from "bun:test";
import {
  isSalusRepo,
  composeSessionEndStatus,
  composeNotificationStatus,
  runSessionEndStatus,
  runNotificationStatus,
} from "./session-status";

// --- (a) status composition -------------------------------------------------

test("composeSessionEndStatus: includes repo, branch, summary, and mergepub line", () => {
  const text = composeSessionEndStatus({
    repoName: "himmel",
    branch: "feat/himmel-1250-telegram-status",
    reason: "other",
    lastAssistant: "Implemented the outbound status hooks.",
    mergepubLine: "/mergepub 1358 abc1234",
  });
  expect(text).toContain("himmel");
  expect(text).toContain("feat/himmel-1250-telegram-status");
  expect(text).toContain("Implemented the outbound status hooks.");
  expect(text).toContain("/mergepub 1358 abc1234");
});

test("composeSessionEndStatus: omits empty summary/mergepub lines cleanly (concise, no blank lines)", () => {
  const text = composeSessionEndStatus({ repoName: "himmel", branch: "main" });
  expect(text).toContain("himmel");
  expect(text.split("\n").length).toBe(1);
});

test("composeNotificationStatus: includes repo, type, and message", () => {
  const text = composeNotificationStatus({
    repoName: "himmel",
    notificationType: "permission_prompt",
    message: "Bash(rm -rf tmp) needs approval",
  });
  expect(text).toContain("himmel");
  expect(text).toContain("permission_prompt");
  expect(text).toContain("Bash(rm -rf tmp) needs approval");
});

test("truncate is applied to long content so the status stays CONCISE", () => {
  const long = "x".repeat(5000);
  const text = composeSessionEndStatus({ repoName: "himmel", lastAssistant: long });
  expect(text.length).toBeLessThan(1000);
  expect(text).toContain("…");
});

// --- (b) graceful silent no-op when TELEGRAM_GROUP_CHAT_ID is unset --------

test("runSessionEndStatus: chatId null -> skip-no-chat, sendAlert never called (silent no-op)", async () => {
  let called = false;
  const outcome = await runSessionEndStatus({
    chatId: null,
    repoName: "himmel",
    branch: "main",
    lastAssistant: "did stuff",
    sendAlert: async () => { called = true; return true; },
    log: () => {},
  });
  expect(outcome).toBe("skip-no-chat");
  expect(called).toBe(false);
});

test("runNotificationStatus: chatId null -> skip-no-chat, sendAlert never called (silent no-op)", async () => {
  let called = false;
  const outcome = await runNotificationStatus({
    chatId: null,
    repoName: "himmel",
    notificationType: "idle_prompt",
    message: "waiting on you",
    sendAlert: async () => { called = true; return true; },
    log: () => {},
  });
  expect(outcome).toBe("skip-no-chat");
  expect(called).toBe(false);
});

test("runSessionEndStatus: chatId present -> composes + sends, returns sent", async () => {
  const sent: string[] = [];
  const outcome = await runSessionEndStatus({
    chatId: 123,
    repoName: "himmel",
    branch: "main",
    lastAssistant: "did stuff",
    sendAlert: async (text) => { sent.push(text); return true; },
  });
  expect(outcome).toBe("sent");
  expect(sent).toHaveLength(1);
});

test("runSessionEndStatus: sendAlert failure (Telegram drop) -> undelivered, never throws", async () => {
  const outcome = await runSessionEndStatus({
    chatId: 123,
    repoName: "himmel",
    sendAlert: async () => false,
  });
  expect(outcome).toBe("undelivered");
});

// --- (c) PHI / salus exclusion ----------------------------------------------

test("isSalusRepo: matches salus (any case, as a substring) and does not match unrelated names", () => {
  expect(isSalusRepo("salus")).toBe(true);
  expect(isSalusRepo("Salus")).toBe(true);
  expect(isSalusRepo("my-SALUS-vault")).toBe(true);
  expect(isSalusRepo("himmel")).toBe(false);
  expect(isSalusRepo("luna")).toBe(false);
  expect(isSalusRepo(undefined)).toBe(false);
});

test("composeSessionEndStatus: salus repo NEVER includes the last-assistant text, even if passed in", () => {
  const phiLooking = "Patient reports elevated blood pressure, medication X 20mg.";
  const text = composeSessionEndStatus({
    repoName: "salus",
    branch: "main",
    lastAssistant: phiLooking,
    mergepubLine: "/mergepub 1 abc",
  });
  expect(text).not.toContain(phiLooking);
  expect(text).not.toContain("/mergepub");
  expect(text.toLowerCase()).toContain("redacted");
});

test("composeNotificationStatus: salus repo NEVER includes the notification message", () => {
  const phiLooking = "Confirm dosage change for patient record #4471?";
  const text = composeNotificationStatus({
    repoName: "salus-vault",
    notificationType: "permission_prompt",
    message: phiLooking,
  });
  expect(text).not.toContain(phiLooking);
  expect(text.toLowerCase()).toContain("redacted");
});

test("runSessionEndStatus: salus repo still sends a status (chat configured) but the delivered text is redacted", async () => {
  const phiLooking = "diagnosis: hypertension";
  const sent: string[] = [];
  const outcome = await runSessionEndStatus({
    chatId: 123,
    repoName: "salus",
    lastAssistant: phiLooking,
    sendAlert: async (text) => { sent.push(text); return true; },
  });
  expect(outcome).toBe("sent");
  expect(sent[0]).not.toContain(phiLooking);
});

test("runNotificationStatus: salus repo still sends a status but the delivered text is redacted", async () => {
  const phiLooking = "lab result flagged abnormal";
  const sent: string[] = [];
  const outcome = await runNotificationStatus({
    chatId: 123,
    repoName: "salus",
    notificationType: "permission_prompt",
    message: phiLooking,
    sendAlert: async (text) => { sent.push(text); return true; },
  });
  expect(outcome).toBe("sent");
  expect(sent[0]).not.toContain(phiLooking);
});
