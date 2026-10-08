#!/usr/bin/env bash
# Local merge gate for teak (+ the sibling zunk checkout).
#
#   tools/gate.sh            full gate
#   tools/gate.sh --quick    library test + audit + fmt + examples/chrome test
#
# Env:  ZIG=zig            compiler to use
#       GATE_OUT=zig-out/gate   logs (logs/*.log) and screenshots (*.png)
#       GATE_JOBS=4        parallel example lanes
# Exit status is nonzero when any step failed. Steps that cannot run on this
# machine (no Vulkan, no ../zunk) are reported SKIP and do not fail the gate.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG="${ZIG:-zig}"
OUT="${GATE_OUT:-zig-out/gate}"
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
JOBS="${GATE_JOBS:-4}"
QUICK=0
for a in "$@"; do
  case "$a" in
    --quick) QUICK=1 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done
export ZIG

rm -rf "$OUT"; mkdir -p "$OUT/logs" "$OUT/res"
cd "$ROOT" || exit 2
echo "gate: $($ZIG version) | out=$OUT | quick=$QUICK | jobs=$JOBS"

# step <label> <dir> <cmd...>: run, log, record "label|STATUS|secs" in res/.
step() {
  local label="$1" dir="$2"; shift 2
  local log="$OUT/logs/${label//[^A-Za-z0-9._-]/_}.log" t0=$SECONDS st=PASS
  (cd "$dir" && "$@") >"$log" 2>&1 || st=FAIL
  printf '%s|%s|%ss\n' "$label" "$st" "$((SECONDS - t0))" >"$OUT/res/${label//[^A-Za-z0-9._-]/_}"
  [ "$st" = FAIL ] && echo "  FAIL $label (log: $log)"
  return 0
}
skip() { printf '%s|SKIP|%s\n' "$1" "$2" >"$OUT/res/${1//[^A-Za-z0-9._-]/_}"; }

have_vulkan() {
  command -v vulkaninfo >/dev/null 2>&1 && vulkaninfo --summary >/dev/null 2>&1 && return 0
  [ -n "${VK_ICD_FILENAMES:-}" ] && return 0
  compgen -G '/usr/share/vulkan/icd.d/*.json' >/dev/null || compgen -G '/etc/vulkan/icd.d/*.json' >/dev/null
}

example_lane() {
  local ex="$1" d="$ROOT/examples/$1"
  step "$ex: test" "$d" "$ZIG" build test
  step "$ex: build" "$d" "$ZIG" build
  step "$ex: web" "$d" "$ZIG" build web
  if [ -f "$d/dist/$ex-web.wasm" ]; then
    printf '%s|%s\n' "$ex" "$(stat -c %s "$d/dist/$ex-web.wasm")" >"$OUT/res/.wasm_$ex"
  fi
  if grep -q 'step("shot"' "$d/build.zig"; then
    if have_vulkan; then step "$ex: shot" "$d" "$ZIG" build shot -- "$OUT/$ex.png"
    else skip "$ex: shot" "no Vulkan"; fi
  fi
  if [ "$ex" = chrome ]; then
    step "chrome: windows x86_64 cross" "$d" "$ZIG" build -Dtarget=x86_64-windows-gnu --prefix zig-out/win
  fi
}
# cross_compile_check <target>: compile (never run) every library test root for
# another OS. The tests cannot execute here, so each run step "fails" with an
# exec-format error; only real compile errors count. This catches the
# Linux-only code (std.DynLib, vDSO clocks, posix sockets) that slips past a
# Linux-only gate and turns Windows / macOS CI red.
cross_compile_check() {
  local out rc
  out="$("$ZIG" build test -Dtarget="$1" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] && return 0
  # Anything that is not a foreign-binary exec failure is a real problem.
  if printf '%s\n' "$out" | grep -E 'compile .* [0-9]+ errors?|^[^ ]+:[0-9]+:[0-9]+: error:' >/dev/null; then return 1; fi
  printf '%s\n' "$out" | grep -Ev 'unable to (execute|spawn)|failed command|consider using|run test failure|transitive failure|^\+-|^[| ]*$|^test$|^Build Summary|^error: ' | grep -q . && return 1
  return 0
}
export -f example_lane step skip have_vulkan cross_compile_check
export ROOT OUT ZIG

step "lib: test" "$ROOT" "$ZIG" build test
step "lib: audit" "$ROOT" "$ZIG" build audit
step "fmt" "$ROOT" bash -c 'git ls-files -z "*.zig" "*.zon" | xargs -0 "$ZIG" fmt --check'

for t in x86_64-windows-gnu aarch64-windows-gnu aarch64-macos; do
  step "lib: compile for $t" "$ROOT" bash -c "cross_compile_check $t"
done

if [ "$QUICK" = 1 ]; then
  step "chrome: test" "$ROOT/examples/chrome" "$ZIG" build test
else
  step "lib: test ReleaseSafe" "$ROOT" "$ZIG" build test -Doptimize=ReleaseSafe
  if have_vulkan; then step "lib: test-gpu" "$ROOT" "$ZIG" build test-gpu
  else skip "lib: test-gpu" "no Vulkan"; fi

  ls "$ROOT/examples" | xargs -P "$JOBS" -I{} bash -c 'example_lane {}'

  if [ -d "$ROOT/../zunk" ]; then step "zunk: test" "$ROOT/../zunk" "$ZIG" build test
  else skip "zunk: test" "no ../zunk"; fi
fi

# Summary

echo; echo "== gate summary =="
printf '%-34s %-6s %s\n' STEP RESULT TIME
for f in "$OUT"/res/*; do
  [ -f "$f" ] || continue
  IFS='|' read -r label st t <"$f"
  printf '%-34s %-6s %s\n' "$label" "$st" "$t"
done | sort
fails=$(cat "$OUT"/res/* 2>/dev/null | grep -c '|FAIL|')
if ls "$OUT"/res/.wasm_* >/dev/null 2>&1; then
  echo; echo "wasm sizes (bytes):"
  cat "$OUT"/res/.wasm_* | sort | while IFS='|' read -r n s; do printf '  %-18s %s\n' "$n" "$s"; done
fi
ls "$OUT"/*.png >/dev/null 2>&1 && { echo; echo "screenshots:"; ls "$OUT"/*.png | sed 's/^/  /'; }
echo; if [ "$fails" -eq 0 ]; then echo "GATE PASS (${SECONDS}s)"; else echo "GATE FAIL: $fails step(s) (${SECONDS}s)"; fi
[ "$fails" -eq 0 ]
