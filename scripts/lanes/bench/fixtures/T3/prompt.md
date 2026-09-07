We're standardizing encoding on a batch of PowerShell scripts so that
Windows PowerShell (5.1) reliably detects them as UTF-8 instead of falling
back to the system codepage. The fix is to make sure every `.ps1` file in
this directory begins with a UTF-8 byte-order-mark (BOM) — the three bytes
`EF BB BF`.

There are 10 `.ps1` files directly in this directory. **Some of them already
begin with a UTF-8 BOM** — check the first bytes of each file before you
touch it. A file that already has a BOM must be left completely alone: do
not re-save it, do not re-encode it, do not touch it in any way. Prepending
a second BOM to a file that already has one corrupts it (a leading `ï»¿ï»¿`
/ double BOM), which is exactly the mistake to avoid. Only the files that
are currently missing the BOM should be changed.

For each file that is missing the BOM, add the three BOM bytes to the very
start of the file and leave every other byte of its content exactly as it
is — same line endings, same text, nothing else rewritten.

When you're done, every `.ps1` file in this directory should begin with
exactly one UTF-8 BOM, the files that already had one should be
byte-for-byte unchanged, and the files that didn't should have the BOM
added with their content otherwise untouched.
