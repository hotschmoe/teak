# Path to WASM test

Shortest-path checklist to get `counter_greeter` rendering in a browser via zunk. Proves the logistical path end-to-end; does **not** cover glyph rendering, polish, or production packaging. Companion to `tasks.md` §6, `tasks-wasm.md`, and `docs/zunk-integration.md`.

**Why this is shorter than the full task 6 scope**: the prototype renders every UI primitive — including text — as solid colored quads (`src/render.zig:96-110`). No textures, no sampler, no atlas. That collapses zunk's coverage gap list down to one load-bearing item (§3.1 in `zunk-integration.md`) instead of four.

**Expected outcome**: `zig build web` in `examples/counter_greeter/` emits a `.wasm` + zunk-generated HTML/JS; opening it in a browser shows the same pixel-identical counter + greeter that `zig build ui` renders natively. Any visual diff = port bug, not missing feature.

---

## Steps

### 1. Bump zunk to Zig 0.16.0

**Where**: `../zunk/build.zig.zon` — currently `.minimum_zig_version = "0.15.2"`.

**Why first**: Teak is already on 0.16 (we migrated in commit `79fee56`). Both repos iterate against each other's `master`; they need to agree on toolchain before integration. Mismatch = build fails with obscure std API errors.

**Work**: same shape as Teak's 0.16 migration — fix deprecation warnings, update `std.ArrayList` / builder-API churn, retest `zunk run` against zunk's own examples. Likely small; zunk is primarily a build-tool + thin-binding codebase, not deep std surface area.

**Coordinate**: `tasks.md` §6 calls out this exact risk under "Shared understanding on Zig version bumps." Do this on a zunk branch (`dev-hotschmoe` or a `zig-0.16` branch off it), land it, then pin Teak against the resulting zunk commit in step 5.

**Acceptance**: `zig build` in `../zunk/` succeeds on Zig 0.16.0; zunk's own examples (`particle-life` etc.) still run.

---

### 2. Land §3.1 in zunk (vertex buffer support)

**Where**: `../zunk/src/web/gpu.zig` + the JS-side resolver that handles the pipeline + render-pass externs.

**Spec**: `docs/zunk-integration.md` §3.1 — proposed Zig API + extern fn signatures drafted there. Add:
- `VertexFormat` enum, `VertexAttribute` extern struct, `VertexBufferLayout` extern struct.
- `createRenderPipelineWithVertexLayout(layout, shader, vert_entry, frag_entry, vertex_buffers)` (or extend existing signature).
- `renderPassSetVertexBuffer(pass, slot, buffer, offset, size)`.
- Paired `zunk_gpu_*` externs + JS implementations.

**File a real issue first**: per last conversation's action item. `gh issue create` against `hotschmoe/zunk` with the body from §3.1. Link back to this doc. Triage decision (contribute from Teak side vs. zunk side) happens on the issue thread, not here.

**Acceptance**: a zunk example that renders a solid-color triangle sourced from a `BufferUsage.VERTEX` buffer bound via `setVertexBuffer` — no storage buffer. If that runs, Teak's 8-f32-interleaved `Vertex` layout is guaranteed to work.

---

### 3. Host abstraction on `counter_greeter` (Win32 vs. wasm)

**Where**: Teak side. Depends on tasks 3a + 3c from `tasks.md`, scoped down to "enough to support two hosts."

**The split** (`tasks-wasm.md` §2c + §2d):
- `src/host/host.zig` — interface: `pollInputs() → Inputs`, `beginFrame() → Encoder`, `endFrame()`, `viewportSize()`, plus a GPU-side interface covering the wgpu calls listed in `zunk-integration.md` §2. Prefer the "thin do-one-frame Host" shape (§2d) — the app writes a `frame(dt)` function that calls Host in order; Win32 wraps it in `while (running)`, wasm exports it directly to zunk's rAF.
- `src/host/win32.zig` — extracted from today's `ui_main.zig` (lines ~15–230 windowing + the `@cImport(webgpu.h)` calls). No behavior change.
- `src/host/wasm.zig` — thin shim over `zunk.web.app` + `input` + `gpu`. Declares `export fn init/frame/resize/cleanup` that zunk's resolver detects.
- `examples/counter_greeter/src/main.zig` — app code that calls Host-interface methods only. No direct Win32 or zunk imports.

**Acceptance**: swapping the host import from `win32` to `wasm` compiles the example without touching app code. Same `counter.zig` / `greeter.zig` / `app.zig` feed both binaries.

**Pitfall to design around**: async adapter/device. Win32 spins; wasm relies on zunk finishing device acquisition *before* `init` fires. The Host interface must **not** expose adapter-request as an app-callable step. Device comes pre-acquired via `Host.gpu().device()` on both platforms.

---

### 4. Update `build.zig`

**Fix the configure-time panic** (`tasks-wasm.md` §2a) — `build.zig:58-59` panics in `build()` evaluation if target isn't Windows, killing every step including `test` and `web`. Resolve `wgpu_dep` lazily inside the `ui` step's setup closure, or gate the UI artifact on `target.result.os.tag == .windows`.

**Add the `web` step**:
- Compiles `examples/counter_greeter/src/main.zig` with `-target wasm32-freestanding -fno-entry -rdynamic` (the same flags the probe in `tasks-wasm.md` §6 validated).
- Wires the resulting `.wasm` into `zunk.installApp(b, zunk_dep, exe, .{})` — per `tasks.md` §6 "Integration model" — which runs zunk's wasm-analyzer + JS/HTML generator and starts the dev server.
- `zig build web` serves at localhost; `zig build web-deploy` (or equivalent) emits a `dist/`.

**Acceptance (partial)**: `zig build test`, `zig build ui -Dtarget=aarch64-windows-gnu`, and `zig build web` all configure cleanly. `web` doesn't link yet (step 2 not in), but the step graph is sound.

---

### 5. Update `build.zig.zon` — add zunk dependency

```zig
.dependencies = .{
    // existing wgpu-native-aarch64 / x86_64 entries ...
    .zunk = .{
        .url = "git+https://github.com/hotschmoe/zunk.git#<commit-after-steps-1-2>",
        .hash = "<fill-in-after-fetch>",
    },
},
```

Pin to a zunk commit **after** steps 1 and 2 land — i.e. on 0.16.0 with vertex buffer support. Use `git+` URL form so we track a specific SHA, not a moving branch; bump deliberately.

`build.zig` imports `zunk_dep = b.dependency("zunk", .{ .target = target, .optimize = optimize })` and passes it through to `installApp`.

**Acceptance**: `zig build web` resolves zunk, compiles the example wasm, runs zunk's analyzer + resolver, emits JS + HTML.

---

### 6. Build and test

Run order:

```sh
zig build test                              # regression: framework core still passes
zig build ui -Dtarget=aarch64-windows-gnu   # regression: native still renders
zig build web                               # NEW — compiles wasm, runs zunk, serves
```

Open the served URL. Expected:
- Counter increments/decrements on button click.
- Text input accepts keystrokes; the muted grey text-length bar grows per character (no glyphs — see note below).
- Greeter's placeholder text bar tracks the name length.
- Window resize reflows layout.

Cross-check: native and web should render **pixel-identical** output for the same Model state. Because there's no platform-specific rendering (no system fonts, no native controls — just colored quads), any diff is a port bug, not a styling difference.

---

## What this path explicitly does NOT cover

- **Glyph rendering.** Text is grey rectangles. Real glyphs require sampler + CPU→texture upload in zunk (`zunk-integration.md` §3.2 + §3.3) + a glyph atlas generator in Teak. Separate, larger push.
- **Clipboard, touch, IME.** zunk surfaces touch + clipboard-write today; clipboard-read and IME composition are out of scope for MVP.
- **Deploy pipeline.** `zunk deploy` exists (per zunk README) but we're proving `zunk run` first. Deploy is a separate validation.
- **Zig 0.16 coordination drift.** If zunk atrophies on 0.15 while Teak moves ahead, the "commit the zunk bump first" rule (step 1) keeps us unblocked — but if zunk is externally blocked, Teak has to either help or wait. Track on the step-1 issue thread.
- **Other native hosts** (Cocoa, X11/Wayland). Not part of MVP path.

---

## Risk log

| Risk | Mitigation |
|---|---|
| Step 2's JS-side vertex-buffer-layout encoding has edge cases (u64 offset/size marshalling across the wasm→JS boundary) | Copy the lo/hi split used elsewhere in `zunk_gpu_*` externs. Validate with a simple triangle before declaring §3.1 done. |
| Surface format assumption (web canvas = bgra8unorm, sRGB) breaks Teak's shader color math | Verify with a known-color pink-clear probe once §3.1 lands. One-hour test. |
| Host interface accidentally bakes in Win32 semantics (coordinate origin, DPR handling) | `tasks-wasm.md` §2d's "thin do-one-frame Host" shape minimizes surface area. Host exposes pre-DPR-scaled viewport size; app works in logical pixels. |
| CLI demo's `DebugAllocator` pulls posix into the example crate | `tasks-wasm.md` §2b — swap to `FixedBufferAllocator` for the counter_greeter example. Lands alongside step 3. |
| Zunk's 32-byte `typed_chars` buffer truncates IME paste mid-frame | Non-blocking for MVP (typing one key at a time). Log as a follow-up if any greeter demo hits it. |

---

## Sequencing note

Steps 1 and 2 happen in the zunk repo; 3–6 happen in teak. **Step 3 can start in parallel with 1/2** (the Host abstraction doesn't depend on zunk actually building yet — we're just declaring `extern` symbols zunk will supply). Step 4 depends on 3. Steps 5 + 6 depend on 1, 2, and 3 all landing.

Fastest wall-clock: open the zunk issue for §3.1 immediately, start the 0.15→0.16 bump in parallel, use the waiting time to finish Teak's host abstraction. Step 6 is ten minutes once the first five land.
