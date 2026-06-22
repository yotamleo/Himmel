// scripts/where-are-we/lib/errors.mjs
// Expected user-input errors (e.g. a missing required flag). The CLI entry
// catch prints a clean one-line message for these and a full stack for anything
// else (an unexpected runtime error = a bug worth a stack trace).
export class UsageError extends Error {
  constructor(message) {
    super(message);
    this.name = 'UsageError';
  }
}
