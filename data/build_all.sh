#!/usr/bin/env bash
# Alias: ./data/build_all.sh → ./data/build.sh
exec "$(cd "$(dirname "$0")" && pwd)/build.sh" "$@"
