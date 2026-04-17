# Teak: target file structure

Companion to `tasks.md` §3 (file restructure). Refines the sketch in §3 into a concrete target layout that task 3a/3b/3c will execute against.

Adapted from Isaac's reference sketch. Deviations from that sketch are **marked and justified** — this doc reflects Teak's actual state today (Win32 host, no glyph rendering, wasm-via-zunk instead of GLFW).

The design goal is one hard boundary: **`gpu/` is the only directory that imports wgpu-native or `zunk.web.gpu`.** Everything above it (`core/`, `layout/`, `input/`, `render/`) compiles and tests on `wasm32-freestanding` with zero platform deps. This is what made `tasks-wasm.md` §1 possible — Teak's core is already wasm-clean, the restructure just names the boundary.

---

## Target tree

```
teak/
├── build.zig
├── build.zig.zon
├── CLAUDE.md
├── README.md
├── tasks.md
├── tasks-file-struct.md          ← this doc
├── tasks-wasm.md
│
├── docs/
│   ├── HARDLINE.md               ← task 7
│   ├── spec.md                   ← living architecture spec (distilled from ui-framework-spec.md)
│   ├── pitfalls.md               ← task 5
│   ├── path_to_wasm_test.md
│   ├── zunk-integration.md
│   ├── features/                 ← task 4: one doc per pub surface item
│   │   ├── validateComponent.md
│   │   ├── Components.md
│   │   ├── TransientState.md
│   │   └── ...
│   ├── journal/                  ← task 2: dated historical entries
│   │   ├── 2026-04-15-day1_recap.md
│   │   ├── 2026-04-15-proto_2.md
│   │   └── 2026-04-15-proto2_post.md
│   └── archive/
│       └── init_convo/           ← task 2: original design MDs
│
├── shaders/
│   └── quad.wgsl                 ← solid rounded-corner quads (current)
│   (text.wgsl, textured.wgsl     ← future, when glyph atlas lands)
│
├── src/                          ← the library, consumable as a Zig module
│   ├── teak.zig                  ← public root (replaces root.zig) — re-exports the pub surface
│   │
│   ├── core/                     ← pure logic. No GPU, no platform, no allocators beyond arena.
│   │   ├── cmd.zig               ← Cmd union, CmdBuffer, GroupStyle, arena management
│   │   ├── component.zig         ← Components(), validateComponent, buildMsgs (from today's compose.zig)
│   │   └── transient.zig         ← TransientState (hover/press/focus — bypasses TEA loop)
│   │
│   ├── layout/                   ← []Cmd → []Rect. Two linear passes. No allocation beyond the output slice.
│   │   ├── engine.zig            ← doLayout entry point, measure pass, position pass (from today's layout.zig)
│   │   └── stack.zig             ← GroupContext, fixed-depth layout stack
│   │   (constraints.zig          ← future: flex weights, min/max sizing)
│   │
│   ├── input/                    ← events + (cmd, rect, pos) → ?Msg. No allocation.
│   │   ├── hit_test.zig          ← hitTest + hoverTest (from today's hit_test.zig)
│   │   ├── events.zig            ← platform-neutral input event types (Mouse, Key, Text, Resize)
│   │   └── keys.zig              ← SpecialKey enum, key-code normalization
│   │   (focus.zig                ← future: tab-order traversal)
│   │
│   ├── render/                   ← []Cmd + []Rect + TransientState → []Vertex. CPU-only; no wgpu calls.
│   │   ├── vertex.zig            ← Vertex struct, emitQuad
│   │   └── build.zig             ← buildVertices (from today's render.zig)
│   │   (batch.zig                ← future: sort by pipeline/texture once we have >1)
│   │   (text.zig                 ← future: glyph atlas, shaping — blocked on zunk §3.2+§3.3)
│   │
│   ├── gpu/                      ← the ONLY directory that imports wgpu-native or zunk.web.gpu.
│   │   ├── context.zig           ← Gpu interface: device, queue, surface, resize. Backend-polymorphic.
│   │   ├── native.zig            ← wgpu-native backend (wraps @cImport(webgpu.h))
│   │   ├── web.zig               ← zunk.web.gpu backend
│   │   ├── pipeline.zig          ← shader loading, render pipeline descriptor (backend-neutral)
│   │   └── buffer.zig            ← vertex + uniform buffer lifecycle
│   │
│   └── platform/                 ← window/input event source. Drives or yields to the main loop.
│       ├── host.zig              ← Host interface: pollInputs() / beginFrame() / endFrame() / viewportSize()
│       ├── win32.zig             ← extracted from today's ui_main.zig windowing
│       ├── wasm.zig              ← thin shim over zunk.web.{app,input,gpu} + exported init/frame/resize/cleanup
│       (cocoa.zig                ← future)
│       (x11.zig / wayland.zig    ← future)
│
├── examples/
│   ├── counter_greeter/          ← today's proto 2, relocated
│   │   ├── build.zig
│   │   └── src/
│   │       ├── main.zig          ← imports teak, picks host, runs the app
│   │       ├── counter.zig
│   │       ├── greeter.zig
│   │       └── app.zig
│   (todomvc/                     ← future)
│   (calculator/                  ← future)
│
└── test/                         ← cross-cutting integration only. Unit tests stay inline per Zig idiom.
    └── integration_test.zig      ← view → layout → hit_test → buildVertices round-trip
                                    (plus a wasm32-freestanding compile canary per tasks-wasm.md §1)
```

---

## Key boundaries

| Directory | Depends on | Must NOT depend on | Test strategy |
|---|---|---|---|
| `core/` | std only | layout, input, render, gpu, platform | Inline `test` blocks. `wasm32-freestanding`-clean. |
| `layout/` | core/cmd | input, render, gpu, platform | Inline. Feed `[]Cmd`, assert `[]Rect`. No window. |
| `input/` | core/cmd, layout/engine (for Rect) | render, gpu, platform | Inline. Feed `(cmd, rect, pos)`, assert `?Msg`. |
| `render/` | core/cmd, core/transient, layout/engine | input, gpu, platform | Inline. Feed `(cmds, rects, transient)`, assert vertex buffer contents. |
| `gpu/` | render (for Vertex shape), core (for Cmd color info) | platform | Inline where possible; full GPU needs hardware — gate behind a build flag. |
| `platform/` | gpu (for surface/device acquisition), input/events | — (top of stack) | Integration only. Stubbable in tests. |
| `examples/*/src/` | teak (as a module) | anything in src/ directly | Example's own `build.zig test` step. |

**The load-bearing invariant**: `src/teak.zig` re-exports *types and functions* from `core/`, `layout/`, `input/`, `render/`. It does **not** re-export anything from `gpu/` or `platform/` — those are host-concerns the consumer wires up in their `build.zig`. A library consumer who wants a custom host (e.g. SDL3, termbox) imports `teak` and writes their own `platform/` equivalent. This keeps Teak embeddable; it keeps the "pure logic" half honest.

---

## Deviations from the reference sketch

Five changes against Isaac's reference structure, each with a reason:

1. **No `core/model.zig`.** Teak's `Model` and `Msg` types are *per-app* — they live in `examples/<app>/src/`, not in the library. `core/` provides the machinery (`Components`, `validateComponent`, `Cmd`, `CmdBuffer`, `TransientState`), not a generic `Model` base. Following the sketch's `core/model.zig` would invite a base class Teak explicitly doesn't have.

2. **`platform/win32.zig`, not `platform/glfw.zig`.** Teak's current host is raw Win32 (`ui_main.zig`). Adopting GLFW is a separate decision with real tradeoffs (binary size, compile time, dep surface). The sketch used GLFW as shorthand for "cross-platform windowing"; Teak's actual win32-native path stays direct. Adding GLFW later is a new file, not a restructure.

3. **`platform/wasm.zig` wraps zunk, not raw canvas.** The sketch has `platform/web.zig` calling `requestAnimationFrame` directly. Teak delegates to zunk instead (see `docs/path_to_wasm_test.md`) — zunk owns the rAF loop, the JS glue, and the HTML. Our wasm file is a 50-line shim over `zunk.web.{app,input,gpu}`, not a from-scratch web host.

4. **`gpu/` has a backend split (`native.zig` + `web.zig`), not a single wgpu wrapper.** Teak targets two WebGPU-shaped APIs that are *similar but not identical*: wgpu-native's C API via `@cImport` and zunk's typed-handle Zig API. The abstraction boundary sits *inside* `gpu/`, not above it, because both are "WebGPU". The `context.zig` interface is narrow enough that callers in `render/` don't know which backend they're on. This is the "wgpu backend abstraction" sub-decision from `tasks.md` §3a, now with a concrete home.

5. **Tests stay inline, not in a separate `test/` tree.** Zig idiom is `test "description" { ... }` in the same file as the code under test. The `test/` directory is reserved for genuinely cross-cutting integration tests that don't belong to any one file (the current round-trip test + a wasm compile canary). The sketch's per-file test mirror (`cmd_test.zig`, `layout_test.zig`, ...) fights the `zig build test` convention — we'd be re-inventing what `zig test src/core/cmd.zig` already does.

---

## Migration plan (maps to tasks.md §3a/3b/3c)

Execute in this order to keep every intermediate state compiling:

1. **3a.1 — Create the directories, move files verbatim.** No content changes.
   ```
   src/cmd.zig       → src/core/cmd.zig
   src/compose.zig   → src/core/component.zig
   src/transient.zig → src/core/transient.zig
   src/layout.zig    → src/layout/engine.zig
   src/hit_test.zig  → src/input/hit_test.zig
   src/render.zig    → src/render/build.zig  (split Vertex into render/vertex.zig)
   src/root.zig      → src/teak.zig
   ```
   Update imports. `zig build test` passes. Single commit.

2. **3a.2 — Extract `platform/win32.zig`.** Split `ui_main.zig` into:
   - `src/platform/host.zig` — the interface.
   - `src/platform/win32.zig` — windowing + message pump.
   - `src/gpu/native.zig` — wgpu-native device/surface/pipeline/buffer wiring.
   - `src/gpu/context.zig` — the Gpu interface both backends satisfy.

   `ui_main.zig` shrinks to the app-level `while (running) { ... }` and moves to `examples/counter_greeter/src/main_ui.zig` (or is absorbed into `main.zig`).

3. **3a.3 — Stub `platform/wasm.zig` and `gpu/web.zig`.** Declare the interface-satisfying shape. Doesn't build until zunk §3.1 lands (see `docs/path_to_wasm_test.md`). This is the file that step 3 of the wasm path plan fills in.

4. **3b — `build.zig.zon` declares the `teak` module.** `src/teak.zig` is the entry. No executable targets in the library build.

5. **3c — Move examples.** `counter.zig` / `greeter.zig` / `app.zig` / `main.zig` → `examples/counter_greeter/src/`. Example's `build.zig` depends on `teak` as a local-path module.

6. **Acceptance test**: swap `platform/win32.zig` for a stub that returns empty inputs and a no-op GPU. Everything in `src/core/`, `src/layout/`, `src/input/`, `src/render/` still compiles and passes tests.

---

## What this enables

- **Fast iteration**: adding a widget is `core/cmd.zig` + a case in `layout/engine.zig` + a case in `input/hit_test.zig` + a case in `render/build.zig`. Four files, all GPU-free. The dev loop is `zig build test`, not `zig build ui`.
- **Swappable backends**: if wgpu-native ever breaks or a consumer wants Vulkan-direct / software rasterization, `gpu/native.zig` is the only file that changes. `render/` doesn't know or care.
- **Swappable hosts**: SDL3, termbox-gui, egui-style embedded-in-another-framework — all just new files in `platform/`.
- **Library consumers**: import `teak`, use it from their own `build.zig`. They're never forced to adopt our host choices.
- **Wasm story**: `platform/wasm.zig` + `gpu/web.zig` are the only new files. The rest of the framework doesn't notice the target change. (`tasks-wasm.md` §1 already confirmed this empirically.)

---

## Non-goals

- **No `core/model.zig`.** Teak doesn't ship a Model base type; apps define their own. (See deviation 1.)
- **No widget library.** Buttons, inputs, lists are emitted by user `view()` functions via `cmd.*` calls. We don't ship a `src/widgets/` tree.
- **No retained-mode cache.** `render/batch.zig` is listed for *draw-call batching* (sort by pipeline/texture to reduce state changes), not for widget-state caching. Retained widgets violate HARDLINE invariant 1 (`tasks.md` §7).
- **No lifecycle hooks.** `onMount` / `onUnmount` are in the forbidden-patterns list. Components expose `Model` / `Msg` / `update` / `view` — that's it.
