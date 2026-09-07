#!/usr/bin/env bash
set -euo pipefail

eslint . --max-warnings=0  
shellcheck ./*.sh   


