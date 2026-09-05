This directory holds a set of small shell libraries, each defining a batch
of predicate functions (things like `cfgval_01`, `netguard_07`, etc.) used
elsewhere in the codebase to test whether a string matches some pattern.

Almost every one of these predicate functions is implemented with this
idiom:

```sh
printf '%s\n' "$SOMEVAR" | grep -q "SOMEPATTERN"
```

This idiom is fragile under `set -o pipefail`. If `grep -q` finds its match
early, it can exit (and close its stdin) before `printf` has finished
writing, so `printf` can receive SIGPIPE. With `pipefail` active, the
pipeline's exit status then reflects that SIGPIPE instead of the intended
grep result, so callers that rely on the exit status of this pipeline can
get a spurious failure that has nothing to do with whether the pattern
actually matched.

## What to do

1. Create a new file named exactly `strcheck.sh` in this directory,
   containing this function, defined exactly once, byte-for-byte as written
   here (a `#!/usr/bin/env bash` shebang line above it is fine, no other
   content is needed):

   ```sh
   str_contains() {
       grep -q -- "$2" <<< "$1"
   }
   ```

   This uses a here-string instead of a pipe, so there is no second process
   to receive SIGPIPE.

2. In every `*.sh` file in this directory (except `run-tests.sh`, see
   below), find every occurrence of the exact idiom

   ```sh
   printf '%s\n' "$X" | grep -q "Y"
   ```

   (where `$X` is whatever expression appears there — a plain variable like
   `$val`, a positional parameter like `$1`, etc. — and `"Y"` is whatever
   pattern text appears there) and replace that occurrence, in place, with:

   ```sh
   str_contains "$X" "Y"
   ```

   using the exact same `$X` and the exact same `"Y"` that were in the
   original — do not change the pattern text, do not change the quoting
   style of the pattern, and do not add flags like `--`. Everything else on
   the line and around it (the `if`/`then`/`fi`, `&&`, `||`, `!`, variable
   assignments, etc.) stays exactly as it is — only the piped
   `printf | grep -q` fragment itself is replaced by the `str_contains`
   call.

   For example, this:

   ```sh
   if printf '%s\n' "$val" | grep -q "^prod-"; then
       return 0
   fi
   ```

   becomes this:

   ```sh
   if str_contains "$val" "^prod-"; then
       return 0
   fi
   ```

   and this:

   ```sh
   printf '%s\n' "$1" | grep -q "^feature/"
   ```

   becomes this:

   ```sh
   str_contains "$1" "^feature/"
   ```

3. Do not modify `run-tests.sh`. It already sources `strcheck.sh` (if
   present) before sourcing everything else, so once `strcheck.sh` exists
   and every call site has been converted, it should continue to pass
   unchanged. You can check your work by running:

   ```sh
   bash run-tests.sh
   ```

   It should print `ran 400 checks, 0 failed` and exit successfully.

4. When you are done, there should be zero remaining occurrences anywhere
   in this directory of a `printf` piped into `grep -q` — every call site
   must be converted, not just some of them. Do not touch any file that
   doesn't contain this idiom.
