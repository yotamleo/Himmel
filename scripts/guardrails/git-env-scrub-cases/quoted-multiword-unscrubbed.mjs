import { execSync } from 'node:child_process';

// RED: a single quoted multi-word command string ('git status') — the call
// detector used to require the quote to close immediately after "git",
// which only matched the array-arg form ('git', [...]) and missed this
// shape entirely (HIMMEL-3570 CR fixup). No scrub visible, no exemption.
export function status() {
  return execSync('git status --short', { encoding: 'utf8' });
}
