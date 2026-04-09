#!/usr/bin/env bash
# macOS: set DEVELOPER_DIR so Zig 0.15 can link the build runner (see PR #406).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
if [[ "$(uname -s)" == "Darwin" ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
fi
exec "${ZIG:-zig}" build "$@"
