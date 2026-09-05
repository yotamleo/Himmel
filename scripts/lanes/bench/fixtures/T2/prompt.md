This directory contains eight shell scripts — check-alpha.sh, check-beta.sh,
check-gamma.sh, check-delta.sh, check-epsilon.sh, check-zeta.sh, check-eta.sh,
and check-theta.sh. Each one defines several small functions that check
whether a heartbeat file has a particular field set to a particular value.
Every one of these functions currently does the check with a two-stage grep
pipeline of this exact shape:

    grep "^FIELD=" "$VAR" | grep -q "VALUE"

This is fragile: the pipeline's overall exit status only reflects the second
grep, and the matching line is piped through a second process for no reason.
Replace every occurrence of this two-stage pattern, in all eight files, with
the equivalent single-pass form:

    grep -q "^FIELD=.*VALUE" "$VAR"

For each call site, keep FIELD, VALUE, and VAR (the file argument being
grepped) exactly as they appear in the original two grep calls — only the
shape of the command changes, never the field name, the value being matched,
or the file argument. Do not change anything else: function names,
indentation, comments, and every line that isn't one of these two-stage grep
pipelines must stay exactly as it is.

Do not modify run-tests.sh or any other file in this directory. It is a test
harness that exercises every function above and must keep passing, unmodified,
after your edit.
