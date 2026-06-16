export interface RunResult {
  runId: string;
  exitCode: number;
  summary: string;
  /** Length of the formatted summary line emitted to Claude — measured AFTER the 200-char cap. Always <= 200. */
  bytesToClient: number;
  startedAt: string;
  finishedAt: string;
}

export interface IndexEntry extends RunResult {
  tag: string;
  /** Non-empty command array: first element is the executable. */
  cmd: [string, ...string[]];
  logOffsetStart: number;
  logOffsetEnd: number;
  errOffsetStart: number;
  errOffsetEnd: number;
}
