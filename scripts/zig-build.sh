#!/usr/bin/env bash
# Run `zig build` with a macOS SDK that works with Zig 0.15's bundled lld.
#
# On Apple Silicon with Xcode 26.x, the default SDK can make `zig build` fail
# while linking the *build runner* (undefined symbols from libSystem such as
# __availability_version_check, _abort, _dispatch_*). Pointing DEVELOPER_DIR at
# Command Line Tools makes `xcrun --show-sdk-path` resolve to the CLT SDK and
# avoids that failure.
#
# Usage: ./scripts/zig-build.sh [args passed to zig build]
#   or:  ZIG=path/to/zig ./scripts/zig-build.sh test

set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ "$(uname -s)" == "Darwin" ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
fi

zig="${ZIG:-zig}"
exec "$zig" build "$@"
