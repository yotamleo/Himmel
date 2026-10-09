#!/usr/bin/env bash
# shellcheck disable=SC2164
# e.sh DIR - run in DIR
main() {
  local dir="$1"
  cd "$dir"
  echo "RAN in $(pwd)"
}
main "$@"
