#!/usr/bin/env bash
# End-to-end hot-reload check on examples/todo (headless backend, Linux):
#   v1 build -> add todos over the control channel -> rebuild with a changed
#   title colour -> the loader swaps libapp.so in -> same todos, same layout,
#   different pixels -> rebuild with a changed Model type -> state reset (said so).
# Usage: tools/hot_reload_check.sh   (needs `zig` on PATH; builds teak-drive)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
EX=$ROOT/examples/todo
OUT=${HR_OUT:-$(mktemp -d)}
SOCK=$OUT/hr.sock
LOG=$OUT/loader.log
APP=$EX/src/app.zig
cleanup() { [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true; (cd "$ROOT" && git checkout -q -- examples/todo/src/app.zig) || true; }
trap cleanup EXIT

(cd "$ROOT" && zig build drive >/dev/null)
D=$ROOT/zig-out/bin/teak-drive
cd "$EX"
zig build dev -Dbackend=headless >/dev/null
TEAK_CONTROL=$SOCK ./zig-out/bin/todo-dev >"$LOG" 2>&1 &
PID=$!
for _ in $(seq 50); do [ -S "$SOCK" ] && break; sleep 0.1; done

d() { "$D" --socket "$SOCK" "$@"; }
d click --role text_input >/dev/null
for t in "buy milk" "walk dog" "ship teak"; do d type "$t" >/dev/null; d key enter >/dev/null; done
d click --role checkbox --label "walk dog" >/dev/null
body() { sed -n '/^group/,$p'; }   # drop the frame-dependent header
d snapshot | body >"$OUT/snap1.txt"
d state >"$OUT/state1.txt"
d screenshot "$OUT/p1.png" >/dev/null
grep -q 'items=3' "$OUT/state1.txt"

waitnote() {
  for _ in $(seq 100); do grep -q "$1" "$LOG" && return 0; sleep 0.1; done
  echo "FAIL: loader never said '$1'"; cat "$LOG"; exit 1
}

# v2: a colour-only change.
sed -i 's|cb.text("Todo");|cb.textStyled("Todo", teak.DEFAULT_FONT, .{ 1.0, 0.45, 0.2, 1.0 });|' "$APP"
zig build dev -Dbackend=headless >/dev/null
waitnote "Model kept"
d snapshot | body >"$OUT/snap2.txt"
d state >"$OUT/state2.txt"
d screenshot "$OUT/p2.png" >/dev/null
diff <(sed 's/,"frame".*//' "$OUT/state1.txt") <(sed 's/,"frame".*//' "$OUT/state2.txt") >/dev/null || { echo "FAIL: state changed across reload"; exit 1; }
diff "$OUT/snap1.txt" "$OUT/snap2.txt" >/dev/null || { echo "FAIL: layout changed (colour-only edit)"; diff "$OUT/snap1.txt" "$OUT/snap2.txt"; exit 1; }
cmp -s "$OUT/p1.png" "$OUT/p2.png" && { echo "FAIL: pixels identical, the new colour is not live"; exit 1; }
echo "ok: colour change live, 3 todos kept (checked item preserved)"

# v3: the Model type changes -> reset, announced.
sed -i 's|input_focused: bool = false,|input_focused: bool = false,\n    hr_probe: u8 = 0,|' "$APP"
zig build dev -Dbackend=headless >/dev/null
waitnote "state reset"
d state | grep -q 'items=0' || { echo "FAIL: expected a fresh Model after a type change"; exit 1; }
echo "ok: Model type change resets state and says so"
echo "HOT RELOAD PASS ($OUT)"
