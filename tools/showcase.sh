#!/bin/bash
# Regenerate docs/images/showcase/ (see docs/showcase.md). Run after the last merges:
#   tools/showcase.sh [tmp-dir]
# Needs: zig, a Vulkan device (native shots), chromium + `cd tools && npm ci` (web shots,
# WEBSHOT_ANGLE=vulkan on hosts that need it), python3 with Pillow. Takes a few minutes.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=${1:-/tmp/showcase}
mkdir -p "$TMP/native" "$TMP/web"
(cd "$ROOT/tools/qa" && zig build -p out)
for e in gallery kerf_viewer scene_layers notes tables chrome todo; do
  "$ROOT/tools/qa/out/bin/qa-$e" "$TMP/native" --scale 1
done
"$ROOT/tools/qa/out/bin/qa-kerf_viewer" "$TMP/native" --scale 2 --state section_hover
# complex scripts through HarfBuzz (optional: needs the Noto faces, see docs/features/harfbuzz.md)
FONTS=${NOTES_SCRIPT_FONTS:-$HOME/.cache/teak-test-fonts}
if [ -f "$FONTS/NotoNaskhArabic-Regular.ttf" ]; then
  (cd "$ROOT/examples/notes" && NOTES_SCRIPT_FONTS="$FONTS" zig build shot -Dharfbuzz=true -- "$TMP/native/notes-scripts@1x.png" --state scripts)
fi
for e in gallery kerf_viewer chrome tables; do (cd "$ROOT/examples/$e" && zig build web); done
export CHROME_PATH=${CHROME_PATH:-/usr/bin/chromium} QA_SCALES=1
QA_STATE=controls python3 "$ROOT/tools/qa/web.py" gallery "$TMP"
QA_STATE=section python3 "$ROOT/tools/qa/web.py" kerf_viewer "$TMP"
QA_STATE=modern python3 "$ROOT/tools/qa/web.py" chrome "$TMP"
QA_STATE=initial python3 "$ROOT/tools/qa/web.py" tables "$TMP"
python3 "$ROOT/tools/showcase.py" "$TMP" "$ROOT/docs/images/showcase"
