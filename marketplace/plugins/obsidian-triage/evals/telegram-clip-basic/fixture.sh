#!/usr/bin/env bash
# Seeds a throwaway fixture vault inside the run's own workspace — never
# $HOME, never the real luna vault. Just enough for resolveVault()/
# resolveVaultRoot() to accept it: a directory containing .obsidian/.
set -euo pipefail
mkdir -p vault-fixture/.obsidian
