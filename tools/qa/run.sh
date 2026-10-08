#!/bin/bash
# Visual QA sweep: every example, native (headless wgpu) and web (headless Chromium), 1x and 2x.
#   tools/qa/run.sh [out-dir]          # default /tmp/qa
# Needs: zig, a Vulkan device (lavapipe works), `cd tools && npm ci`, chromium (CHROME_PATH),
# WEBSHOT_ANGLE=vulkan on hosts whose driver ANGLE-swiftshader cannot use. Then LOOK at the PNGs.
set -e
OUT=${1:-/tmp/qa}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$OUT/native" "$OUT/web"
(cd "$ROOT/tools/qa" && zig build -p out)
for s in 1 2; do for b in "$ROOT"/tools/qa/out/bin/qa-*; do "$b" "$OUT/native" --scale $s; done; done
for e in chrome counter_greeter todo tree viewport effects fonts scene3d scene_layers kerf_viewer gallery notes tables; do
  [ -d "$ROOT/examples/$e" ] || continue
  (cd "$ROOT/examples/$e" && zig build web)
done
CHROME_PATH=${CHROME_PATH:-/usr/bin/chromium} python3 "$ROOT/tools/qa/web.py" all "$OUT"
echo "shots in $OUT/native and $OUT/web"
