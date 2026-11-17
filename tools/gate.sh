#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec "${ZIG:-zig}" build test -j4
