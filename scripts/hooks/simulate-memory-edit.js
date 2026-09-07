#!/usr/bin/env node
// simulate-memory-edit.js — apply an Edit/MultiEdit payload to the on-disk
// MEMORY.md so guard-memory-capture.sh can run its Write-path checks (line
// length, line-count ceiling, growth) on the RESULT instead of denying the
// tool outright (HIMMEL-2011). MultiEdit's `edits[]` apply sequentially.
//
// Usage: printf '%s' "$payload" | node simulate-memory-edit.js
//   stdout = simulated file content + a trailing \004 sentinel, exit 0. The
//            sentinel exists because the caller reads this through `$( )`,
//            which strips ALL trailing newlines — without it a growth-cap
//            check on the simulated content undercounts an edit that appends
//            them. The caller strips the sentinel back off.
//   exit 3 = an old_string was not found (Edit tool itself would error on
//            that -> caller allows and lets the real tool surface it)
'use strict';

const fs = require('node:fs');

// EOT. Terminates stdout so the caller's `$( )` capture has no trailing
// newline to strip; the caller removes it again before validating.
const SENTINEL = String.fromCharCode(4);

let raw = '';
process.stdin.on('data', (d) => { raw += d; });
process.stdin.on('end', () => {
  const payload = JSON.parse(raw);
  const input = payload.tool_input || {};
  let content = '';
  // ENOENT = the index does not exist yet (a legitimate new file). Anything
  // else (EACCES, EISDIR, EIO) means we cannot know the current content, so
  // fail CLOSED — exit non-zero and let the caller deny as undecidable rather
  // than simulating against a phantom empty file.
  try {
    content = fs.readFileSync(input.file_path, 'utf8');
  } catch (e) {
    if (e.code !== 'ENOENT') process.exit(1);
  }

  const edits = Array.isArray(input.edits) ? input.edits : [input];
  for (const e of edits) {
    const oldStr = e.old_string;
    const newStr = e.new_string;
    if (!content.includes(oldStr)) process.exit(3);
    // Literal splice, NOT String.replace(str, str): the latter expands `$&`,
    // `$$`, "$`" and `$'` in the REPLACEMENT, so a new_string carrying any of
    // them would simulate content the Edit tool never produces -> a false
    // allow or deny. split/join is already literal; match it here.
    if (e.replace_all) {
      content = content.split(oldStr).join(newStr);
    } else {
      const i = content.indexOf(oldStr);
      content = content.slice(0, i) + newStr + content.slice(i + oldStr.length);
    }
  }
  process.stdout.write(content + SENTINEL);
});
