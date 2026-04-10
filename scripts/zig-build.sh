#!/usr/bin/env bash
# Wrapper for zig build on macOS 26+ where Zig 0.15.x's bundled lld
# cannot link against the system SDK.  Falls back to the system linker
# and the Command Line Tools 15.4 SDK when available.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ "$(uname -s)" == "Darwin" ]]; then
  CLT_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
  if [[ -d "$CLT_SDK" ]]; then
    export ZIG_LLD_FLAG="-fno-lld"
    export ZIG_SYSROOT="--sysroot=$CLT_SDK"
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
  fi
fi

exec "${ZIG:-zig}" build "$@"
