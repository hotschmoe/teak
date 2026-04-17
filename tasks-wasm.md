# Teak: WASM Gap Supplement

Companion to `tasks.md`. Records the concrete deficiencies surfaced by actually building Teak against `wasm32-freestanding`, so the upcoming refactor (tasks 3a / 3b / 6) has a precise punch list rather than a vague "make it work on web."

**Method**: compiled `src/root.zig` and a probe exercising the full pipeline (`CmdBuffer → view → LayoutEngine.doLayout → hitTest → buildVertices → update`) via `zig build-exe ... -target wasm32-freestanding -fno-entry -rdynamic`. Probe compiled cleanly to a 687 KB wasm module on Zig 0.16.0.

---

## 1. What is already wasm-clean (keep it that way)

The entire framework core compiles to `wasm32-freestanding` today with zero changes:

- `src/cmd.zig` — `Cmd` union, `CmdBuffer`, `GroupStyle`, arena management.
- `src/layout.zig` — measure + position passes.
- `src/hit_test.zig` — `hitTest`, `hoverTest`.
- `src/render.zig` — `Vertex`, `emitQuad`, `buildVertices` (pure CPU vertex generation).
- `src/transient.zig` — `TransientState`.
- `src/compose.zig`, `src/counter.zig`, `src/greeter.zig`, `src/app.zig`.
- `src/root.zig` — public re-exports.

Uses only wasm-safe std: `std.ArrayList`, `std.heap.ArenaAllocator`, `std.mem`, tagged unions, comptime. **No posix / fs / threading / time / stdio dependencies leak into the framework core.**

**Implication for task 3b (library extraction)**: the library surface is already portable. The extraction is a packaging exercise, not a code-portability exercise.

**Regression guard to add under task 5 (pitfalls + canaries)**: a CI step that compiles `root.zig` to `wasm32-freestanding` and fails if any future change pulls in a posix-only std dep. One-line command, catches drift instantly.

---

## 2. Concrete gaps, by layer

### 2a. `build.zig:58-59` — configure-time panic blocks non-Windows targets

```zig
const wgpu_dep_name: []const u8 = if (target.result.os.tag != .windows)
    @panic("wgpu-native: only Windows targets are wired up; ...")
```

This panic fires during `build()` evaluation for **every** step, not just `ui`. So `zig build test` and `zig build -Dtarget=wasm32-freestanding` both die in configure before any step graph runs.

**Fix under task 3a**: resolve `wgpu_dep` lazily — only when the UI artifact is actually in the step graph. Either gate the UI artifact behind `target.result.os.tag == .windows`, or move the dependency lookup inside the `ui` step's setup closure. The library + CLI + test steps must configure cleanly for any target.

**Acceptance**: `zig build test -Dtarget=wasm32-freestanding` succeeds; `zig build ui -Dtarget=wasm32-freestanding` fails with a clear "UI host not available for this target" message (not a panic in configure).

### 2b. `src/main.zig:6` — CLI allocator not wasm-portable

```zig
var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
```

`DebugAllocator` references `std.posix.getrandom` and `IOV_MAX`, which `wasm32-freestanding`'s posix stub lacks. Compile errors:

```
std/Io/Threaded.zig:2064: struct 'posix.system' has no member named 'getrandom'
std/posix.zig:90:        struct 'posix.system' has no member named 'IOV_MAX'
```

**Fix under task 3c (examples extraction)**: the CLI demo is moving to `examples/counter_greeter/` anyway. Swap to `FixedBufferAllocator` (bounded workload — known max cmd count) or make the allocator choice conditional on `builtin.target.os.tag`. `std.debug.print` itself is a freestanding no-op — safe.

**Not a library concern.** The framework core never touches `DebugAllocator`; consumers pick their own allocator.

### 2c. `src/ui_main.zig` (762 LoC) — entirely platform-bound

Two distinct native-only bindings, both need web counterparts:

**Win32 windowing** (lines ~15–230):
- `extern "user32"` / `extern "kernel32"` decls: `RegisterClassExW`, `CreateWindowExW`, `ShowWindow`, `PeekMessageW`, `TranslateMessage`, `DispatchMessageW`, `DefWindowProcW`, `PostQuitMessage`, `LoadCursorW`, `GetModuleHandleW`.
- `WNDPROC` message pump dispatching `WM_CHAR`, `WM_KEYDOWN`, `WM_MOUSEMOVE`, `WM_LBUTTONDOWN`, `WM_SIZE`, `WM_DESTROY`.
- UTF-16 window-class + title strings.

**wgpu-native GPU bindings** (via `@cImport`):
```zig
const c = @cImport({
    @cDefine("WGPU_SHARED_LIBRARY", "1");
    @cInclude("webgpu.h");
    @cInclude("wgpu.h");
});
```
Plus linked `wgpu_native.dll`. wasm32-freestanding cannot link a native dll — this whole block has to be replaced, not ported.

**Implication for task 3a (host abstraction)**: the split is cleaner than it looks. The windowing half and the GPU half are already conceptually distinct inside `ui_main.zig` and can be abstracted independently:

- **Host interface** absorbs the windowing half → satisfied on web by `zunk.web.app` + `zunk.web.input`.
- **GPU interface** absorbs the `@cImport(webgpu.h)` surface → satisfied on native by wgpu-native, on web by `zunk.web.gpu`.

The sub-decision called out in task 3a ("wgpu backend abstraction") is the keystone — pin it before writing either backend.

---

## 3. Missing scaffolding (net-new, not a port)

Even once the host abstraction lands, a web build needs artefacts that don't exist in any form today:

| Artefact | Purpose | Depends on |
|---|---|---|
| `src/host/wasm.zig` | Host impl delegating to zunk | Task 3a interface, task 6 audit |
| `examples/counter_greeter/web/index.html` | Loader page | Zunk's generator may produce this |
| JS bridge (if any custom shims) | Unicode text input, clipboard, anything zunk doesn't cover yet | Task 6 gap analysis |
| `zig build web` step | Dual-target the example | Task 3c layout |
| Preview/serve story | `python -m http.server` or zunk CLI | None — doc-only |

All of these are explicitly downstream of task 6's audit. Adding them here only as a reminder that the host impl is not the last piece.

---

## 4. Audit inputs for task 6 (zunk integration)

From the wgpu calls observed in `ui_main.zig`, the concrete coverage questions for the `docs/zunk-integration.md` audit are:

- Surface acquisition: wgpu-native uses `wgpuInstanceCreateSurface` + HWND; web equivalent is canvas context. How does `zunk.web.gpu` expose this?
- Adapter/device: Win32 host spins `while (adapter == null) wgpuInstanceProcessEvents(...)`. Web can't spin. Confirm zunk's async-sequencing model (pre-`init` callback? promise-to-export?).
- Shader module: WGSL passed through (`quad.wgsl` already WGSL — no translation).
- Pipeline + vertex buffer layout for `teak.Vertex` (8 × f32 interleaved: xy / rgba / uv).
- Per-frame upload path: native uses `wgpuQueueWriteBuffer`; confirm zunk equivalent doesn't re-allocate per call.
- Render pass encoder API shape: `beginRenderPass` / `setPipeline` / `setVertexBuffer` / `draw` / `end` / `submit`.
- Input: `WM_CHAR`-equivalent Unicode channel (greeter needs it), not just keydown scancodes.

These questions all have precise answers once zunk's `src/web/gpu.zig` and `src/web/input.zig` are read against the wgpu calls listed above.

---

## 5. Sequencing against tasks.md

No new ordering — these gaps slot into existing tasks:

- **Task 1 (Zig 0.16)**: already done. Probe confirmed clean on 0.16.0.
- **Task 3a (host abstraction)**: `build.zig` panic fix (§2a) lands here. Host interface must accommodate both a host-driven loop (Win32) and an app-provides-callbacks loop (zunk/rAF).
- **Task 3b (library extraction)**: §1 is the easy half — core is already portable. Focus on packaging cleanness.
- **Task 3c (examples extraction)**: CLI allocator swap (§2b) lands here.
- **Task 5 (pitfalls)**: add the wasm-core compile check as a canary (§1).
- **Task 6 (zunk audit)**: §4 is the input checklist.

---

## 6. One-shot repro

For future verification that the core stays wasm-clean:

```sh
# From repo root. Expects Zig 0.16.0+.
cat > /tmp/teak_wasm_probe.zig <<'EOF'
const std = @import("std");
const teak = @import("src/root.zig");
const App = teak.App;
var heap_buf: [1 << 20]u8 = undefined;
export fn probe() u32 {
    var fba = std.heap.FixedBufferAllocator.init(&heap_buf);
    const gpa = fba.allocator();
    var model: App.Model = .{};
    var cb = teak.CmdBuffer(App.Msg).init(gpa);
    defer cb.deinit();
    App.view(&model, &cb);
    var rects: [128]teak.Rect = undefined;
    teak.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 400);
    var verts: std.ArrayList(teak.Vertex) = .empty;
    defer verts.deinit(gpa);
    const transient: teak.TransientState = .{};
    teak.buildVertices(&verts, gpa, cb.cmds.items, rects[0..cb.cmds.items.len], transient);
    return @intCast(verts.items.len);
}
EOF
zig build-exe /tmp/teak_wasm_probe.zig -target wasm32-freestanding -fno-entry -rdynamic
```

If this ever stops compiling, the framework core has picked up a non-portable dep and §1's promise is broken.
