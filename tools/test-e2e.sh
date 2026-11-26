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
    for example in todo counter_greeter tree gallery tables notes probe; do
      frames=128
      seed=1
      (cd "$root" && "$zig" build sim -j4 -- --app "$example" --seed "$seed" \
        --frames "$frames" --record-check 1)
    done ;;
  heavy)
    set +e
    (
      set -e
      for example in counter_greeter todo tree chrome effects fonts gallery kerf_viewer notes scene3d scene_layers sysmon tables vector_canvas viewport; do
        run_example "$example"
      done
      "$root/tools/drive-e2e.sh"
      (cd "$root/examples/todo" && "$zig" build web -j4)
      WEBSHOT_ANGLE="${WEBSHOT_ANGLE:-vulkan}" node "$root/tools/a11yprobe.mjs" todo "$root/examples/todo/dist"
    )
    status=$?
    (cd "$root" && "$zig" build gates -j4) || status=1
    (cd "$root" && "$zig" build sim-heavy -j4) || status=1
    exit "$status" ;;
  *) echo 'usage: tools/test-e2e.sh blocking|heavy' >&2; exit 2 ;;
esac
