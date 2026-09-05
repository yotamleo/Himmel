The test cases in `tests/` are tagged with `TC-NNN` test-case IDs, but the
tagging has rotted: some IDs got reused by more than one case, and the
numbering has gaps. Renumber every test case so the IDs are clean, using
this exact scheme:

- Process the files in `tests/` in alphabetical order by filename, and
  within each file take the cases in the order they appear top to bottom.
- Assign IDs sequentially starting at `TC-001`, incrementing by one for
  each case with no gaps and no number reused: the first case overall
  becomes `TC-001`, the second `TC-002`, and so on through the last case in
  the suite.
- IDs are zero-padded to 3 digits (`TC-001`, not `TC-1`).

Each test case's ID appears in two places — the comment line directly
above the case, and the `PASS`/`FAIL` message the case prints — update
both consistently. Do not change any case's description text or its
underlying logic, and do not add, remove, merge, or reorder any cases.

The suite must still run successfully afterward: `bash run-tests.sh` from
the repository root should exit 0.
