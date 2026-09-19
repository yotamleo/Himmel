#!/usr/bin/env bash
# Stub `gh` for backfill-source-identity.test.mjs. Serves fixtures from
# $GH_STUB_DIR; every call is logged (endpoint only) to $GH_STUB_DIR/calls.log.
echo "$1 $2" >> "$GH_STUB_DIR/calls.log"
case "$2" in
  graphql)
    cat "$GH_STUB_DIR/graphql.json"
    ;;
  repos/*/readme)
    if [ -f "$GH_STUB_DIR/readme.fail" ]; then
      cat "$GH_STUB_DIR/readme.fail" >&2
      exit 1
    elif [ -f "$GH_STUB_DIR/readme.b64" ]; then
      cat "$GH_STUB_DIR/readme.b64"
    else
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    ;;
  *)
    echo "gh-stub: unexpected call: $*" >&2
    exit 99
    ;;
esac
