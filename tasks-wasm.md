# Teak: WASM Gap Supplement

Companion to `tasks.md`. Records the concrete deficiencies surfaced by actually building Teak against `wasm32-freestanding`, so the upcoming refactor (tasks 3a / 3b / 6) has a precise punch list rather than a vague "make it work on web."

**Method**: compiled `src/root.zig` and a probe exercising the full pipeline (`CmdBuffer → view → LayoutEngine.doLayout → hitTest → buildVertices → update`) via `zig build-exe ... -target wasm32-freestanding -fno-entry -rdynamic`. Probe compiled cleanly to a 687 KB wasm module on Zig 0.16.0.

---

## 0. Assessment: are we positioned to support wasm via zunk?

**Yes, structurally** — with the understanding that both projects need to mature and zunk subsumes more of Rust's pipeline than trunk alone. Specifically, zunk replaces `wasm-bindgen` + `trunk` + the hand-written `index.html` in one tool, so our web story does **not** require us to ship HTML or JS glue. We only need to ship wasm-clean Zig plus a host impl that uses zunk's Layer 2 modules.

**Three structural fits** (why this isn't speculative):

1. **Core is wasm-clean today, proven.** The probe in §6 compiles the full pipeline to `wasm32-freestanding`. Library extraction (task 3b) is a packaging exercise, not a port.
2. **The two platform concerns in `ui_main.zig` map 1:1 to zunk modules.** Windowing + input → `zunk.web.app` + `zunk.web.input`. GPU → `zunk.web.gpu`. The seam exists in our code already; task 3a just names it.
3. **Input model is already polling.** Teak's `WM_CHAR` drain loop and zunk's shared-memory poll are the same pattern at different addresses. No async-event refactor needed.

**Three frictions worth naming** (plan around these, don't discover them late):

1. **Loop-ownership inversion.** Our `while (running) { peek; frame; present; }` becomes zunk's `export fn frame(dt: f32)`. Task 3a's host interface must support both a host-drives-loop model (Win32) and an app-provides-callbacks model (zunk/rAF). See §2d.
2. **Async adapter/device acquisition.** Win32 spins `while (adapter == null) wgpuInstanceProcessEvents(...)`. Web can't spin — you yield. Zunk's lifecycle protocol (`export fn init()` fires *after* the GPU device is ready) is the resolution, but it changes the init sequencing: adapter/device acquisition moves out of our code and into zunk's pre-`init` bootstrap.
3. **Zunk WebGPU coverage gaps that intersect Teak.** Zunk's own `README.md` contributing list flags **vertex buffer layouts, sampler support, depth/stencil state, and error handling** as known gaps. Teak's `Vertex` (8 × f32 interleaved) depends on vertex buffer layouts — that's an upstream PR into zunk, not a workaround in Teak. See §4.

**Bottom line:** every gap below is either a known zunk coverage item (trackable via upstream issues) or a refactor we were already planning under tasks 3a/3c. No unknown-unknowns surfaced by the probe or the zunk audit. Proceed with the task-1→3→6 sequence as written; this doc is the input checklist, not a blocker.

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

### 2d. Main-loop ownership inversion

Our Win32 host owns the loop: `while (running) { PeekMessage; drain_input; build_frame; render; present; }`. Zunk inverts this — **zunk owns the `requestAnimationFrame` loop and calls into exported functions**. Zunk's lifecycle protocol (from its README):

| Export | Signature | When zunk calls it |
|---|---|---|
| `init` | `fn () void` | Once after WASM + canvas + GPU device are ready |
| `frame` | `fn (dt: f32) void` | Every rAF tick |
| `resize` | `fn (w: u32, h: u32) void` | On window resize |
| `cleanup` | `fn () void` | On `beforeunload` |

Mapping our current Win32 main onto this contract:

- Everything *before* the loop (instance creation, adapter/device acquisition, surface configure, pipeline build, buffer allocation) → `init`. **Except** adapter/device acquisition, which zunk already completes before `init` fires (see §0 friction 2).
- Everything *inside* the loop body → `frame(dt)`. Our input queue drain becomes a zunk input poll at the top of `frame`.
- `WM_SIZE` handler → `resize(w, h)`.
- Shutdown → `cleanup`.

**Implication for task 3a**: the Host interface cannot bake in "who owns `while (running)`". Two clean shapes that both satisfy the rAF constraint:

- **Callback-style Host**: Host exposes `registerFrameCallback(fn(dt) void)` and the platform impl chooses when to call it. Win32 impl calls it inside its own loop; wasm impl relies on zunk's generated rAF driver calling the exported `frame`.
- **Thin "do one frame" Host**: Host exposes `pollInputs() → Inputs`, `beginFrame() → Encoder`, `endFrame()`. The app writes a `frame(dt)` function that calls these in order. Win32 impl wraps it in a `while (running)`; wasm impl exports it directly.

The second shape is simpler and more in the spirit of "app is a pure function of state" — prefer it unless zunk integration forces otherwise.

---

## 3. Missing scaffolding (net-new, not a port)

Zunk subsumes the HTML + JS-glue + dev-server layers that a Rust-on-trunk stack would require us to hand-author. So the surface we *actually* need to produce shrinks to:

| Artefact | Purpose | Depends on |
|---|---|---|
| `src/host/wasm.zig` | Host impl delegating to `zunk.web.app` / `input` / `gpu`; declares the `init` / `frame` / `resize` / `cleanup` exports zunk detects | Task 3a interface |
| `examples/counter_greeter/build.zig` web branch | Invokes `zig build` with `-target wasm32-freestanding` and hands the artifact to `zunk run` / `zunk deploy` | Task 3c layout |
| `bridge.js` (only if needed) | Custom shims for anything zunk's Layer 2 doesn't cover (unlikely per §4; would be a stopgap while upstreaming into zunk) | Task 6 audit |

**Explicitly not in the list** (zunk handles these, and this is the architectural win over iced-on-trunk):

- **No `index.html`.** Zunk auto-generates it from detected exports (`frame` export → rAF loop; `resize` export → fullscreen canvas handler; etc.).
- **No JS glue.** Zunk's 5-tier resolver reads our wasm import table and emits exactly the JS we need (target: ~10 KB for a full canvas + input + GPU app).
- **No dev server or file watcher.** `zunk run` does it.
- **No deploy pipeline.** `zunk deploy` emits content-hashed `dist/` ready for any static host.
- **No `build.zig.zon` entry for a web bundler.** Zunk is invoked as a CLI against our `.wasm` output.

---

## 4. Zunk integration: known answers vs. open audit items

Zunk's README answered several questions the original audit listed. Splitting the checklist:

### Known answers (from zunk README)

- **Input model**: polling via shared memory — `zunk.web.input.init()` + `input.poll()` each frame. Matches our existing drain-queue shape. No refactor.
- **Shader format**: WebGPU in browsers accepts WGSL; `zunk.web.gpu` passes through. `shaders/quad.wgsl` needs no translation.
- **Async adapter/device**: zunk sequences adapter/device acquisition **before `init` fires**. Our spin loop is deleted on web, not ported.
- **Lifecycle shape**: `init` / `frame(dt)` / `resize(w, h)` / `cleanup` — documented. Host interface (§2d) designs to this.
- **Text input**: `zunk.web.input` covers keyboard; **verify** it exposes a `WM_CHAR`-equivalent Unicode text channel distinct from keydown scancodes. Greeter needs it. If missing → upstream PR or `bridge.js` stopgap.
- **HTML/JS generation**: zunk. Not our problem.

### Open audit items (read `../zunk/src/web/gpu.zig` and compare against our wgpu calls)

Enumerate every wgpu call `ui_main.zig` makes and check each against `zunk.web.gpu`'s 33 extern fns:

- `wgpuInstanceCreateSurface` — web equivalent is implicit (canvas context). Verify `zunk.web.gpu` surfaces the device + queue + swapchain-equivalent cleanly.
- `wgpuDeviceCreateShaderModule` — present in zunk? (likely — `particle-life` example uses WGSL).
- `wgpuDeviceCreateRenderPipeline` — **vertex buffer layout coverage is a known gap** per zunk's own contributing list. This is the most likely blocker for Teak's WebGPU story. Check `zunk.web.gpu.createRenderPipeline` or equivalent; if vertex buffer layouts aren't parameterizable, that's the first upstream PR.
- `wgpuDeviceCreateBuffer` / `wgpuQueueWriteBuffer` — per-frame upload path. Verify no hidden per-call allocation; zunk's README claims "no hidden heap growth" as a principle.
- `wgpuCommandEncoder*` + `wgpuRenderPassEncoder*` (`beginRenderPass`, `setPipeline`, `setVertexBuffer`, `draw`, `end`, `submit`) — standard pipeline; verify coverage.
- **Known zunk gaps that may hit us**: sampler support, depth/stencil state, error handling. Teak's current UI doesn't need samplers or depth/stencil, so these are "not blocking prototype" but "blocking text-rendering-via-glyph-atlas" (future task).

**Deliverable**: `docs/zunk-integration.md` (task 6) reframes around this split. "Known answers" becomes a short reference section; "open audit items" becomes a checklist with upstream-issue links as they're filed.

---

## 5. Sequencing against tasks.md

No new ordering — these gaps slot into existing tasks:

- **Task 1 (Zig 0.16)**: already done. Probe confirmed clean on 0.16.0.
- **Task 3a (host abstraction)**: `build.zig` panic fix (§2a) lands here. Host interface must accommodate both loop-ownership models (§2d) — prefer the "thin do-one-frame Host" shape so the wasm impl is an export surface, not a driver.
- **Task 3b (library extraction)**: §1 is the easy half — core is already portable. Focus on packaging cleanness.
- **Task 3c (examples extraction)**: CLI allocator swap (§2b) lands here. Also the dual-target `build.zig` that produces both the native `ui` binary and the `wasm32-freestanding` artifact for zunk to consume.
- **Task 5 (pitfalls)**: add the wasm-core compile check as a canary (§1).
- **Task 6 (zunk audit)**: §4 is the input checklist — split into "known answers" (short reference) and "open items" (upstream-issue-backed checklist).

**First upstream PR candidate into zunk** (task 6 side effect): vertex buffer layout support in `zunk.web.gpu.createRenderPipeline`, if the audit confirms it's missing. This is the narrowest load-bearing gap — everything else about our pipeline is standard.

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
