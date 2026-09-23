# fixture readme

Mentions `scripts/quux-doc.sh` and `scripts/precedence-test.sh` in prose only;
neither is actually run from here.

Also mentions `scripts/doc-and-code.sh` by its full path; it has a real code
caller elsewhere too, so this doc mention must not mask that caller and
demote it to DOC-ONLY.
