#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
zig=${ZIG:-zig}
work=$(mktemp -d)
socket=$work/control.sock
pid=
cleanup() { if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; }
trap cleanup EXIT
(cd "$root" && "$zig" build drive -j4)
(cd "$root/examples/todo" && "$zig" build drive -j4)
TEAK_CONTROL="$socket" "$root/examples/todo/zig-out/bin/todo-drive" >"$work/app.log" 2>&1 &
pid=$!
for _ in $(seq 1 100); do
  [[ -S "$socket" ]] && break
  if ! kill -0 "$pid" 2>/dev/null; then cat "$work/app.log" >&2; exit 1; fi
  sleep 0.1
done
if [[ ! -S "$socket" ]]; then cat "$work/app.log" >&2; exit 1; fi
drive() { "$root/zig-out/bin/teak-drive" --socket "$socket" "$@"; }
drive click --role text_input > /dev/null
drive type 'a task' > /dev/null
drive key enter > /dev/null
state=$(drive state)
[[ "$state" == *'items=1'* ]]
drive click --role checkbox --label 'a task' > /dev/null
state=$(drive state)
[[ "$state" == *'items=1'* && "$state" == *'[0] x '* ]]
drive click --role text_input > /dev/null
drive type 'עברית' > /dev/null
drive key enter > /dev/null
state=$(drive state)
[[ "$state" == *'items=2'* && "$state" == *'עברית'* ]]
drive click --role text_input > /dev/null
drive type 'א' > /dev/null
drive key backspace > /dev/null
drive key backspace > /dev/null
state=$(drive state)
[[ "$state" == *'items=2'* ]]
