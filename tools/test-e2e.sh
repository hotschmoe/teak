#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
zig=${ZIG:-zig}
run_example() {
  local example=$1 output
  echo "Running $example"
  if ! output=$(cd "$root/examples/$example" && "$zig" build run -j4 2>&1); then
    printf '%s\n' "$output" >&2
    return 1
  fi
  if ! case "$example" in
    counter_greeter)
      [[ "$output" == *"counter.count = 2"* && "$output" == *'greeter.name = "H"'* ]] ;;
    todo)
      [[ "$output" == *'clear_completed -> items_len = 1'* && "$output" == *'ship teak'* ]] ;;
    tree)
      [[ "$output" == *"after toggle('input')"* && "$output" == *'frame has '* ]] ;;
    *) [[ -n "$output" ]] ;;
  esac; then
    printf 'Unexpected result from %s:\n%s\n' "$example" "$output" >&2
    return 1
  fi
}
case "${1:-}" in
  blocking)
    for example in counter_greeter todo tree; do run_example "$example"; done ;;
  heavy)
    for example in chrome effects fonts gallery kerf_viewer notes scene3d scene_layers tables vector_canvas viewport; do
      run_example "$example"
    done
    "$root/tools/drive-e2e.sh" ;;
  *) echo 'usage: tools/test-e2e.sh blocking|heavy' >&2; exit 2 ;;
esac
