# Teak

A Zig-native UI framework combining **TEA** (The Elm Architecture) with **command buffer rendering** via wgpu.

```
Model → view() → []Cmd → layout → []Rect → render → pixels
                                      ↑
          mouse click → hit_test → Msg → update → Model'
```

Every arrow is an explicit function call with typed inputs and outputs. No globals, no singletons, no event bus, no widget state, no virtual DOM diffing. All state lives in one `Model` struct; every transition is a `Msg`; `view` is a pure function from model to flat command buffer.

> **Design rules are non-negotiable.** Teak is an experiment in a
> specific paradigm; the failure mode is accidentally reinventing
> React/Flutter/etc. by reaching for a familiar shortcut. The keystone
> doc [`docs/HARDLINE.md`](docs/HARDLINE.md) lists the core invariants,
> the named escape hatches, and the forbidden patterns. Read it before
> touching state flow, widget identity, or the host boundary. `zig build
> audit` enforces the greppable half.

## Status

- **Proto-2 shipped** on three hosts: **Windows** (Win32 + wgpu-native), **Linux** (X11 + wgpu-native), and **WebAssembly** (WebGPU via [zunk](https://github.com/hotschmoe/zunk)). One `linkNativeWgpu` call picks the native backend by target OS. *(Linux X11 runs under XWayland; a native Wayland backend is not yet implemented.)*
- **Text rendering shipped.** Both backends rasterize glyph-accurate text into a texture atlas and draw via `uploadText` / `renderFrame`.
- **Functional-gaps push landed** on `functional_gaps_yolo`: overlay layer, image rendering, selection + clipboard, subscriptions, multi-window + dialogs surface, virtual list, a11y tree, rich text. See [`docs/features/functional-gaps.md`](docs/features/functional-gaps.md).

## Build commands

Requires **Zig 0.16.0+**.

```sh
# From repo root — library
zig build test           # unit + integration tests
zig build test-wasm      # wasm32-freestanding compile canary
zig build audit          # HARDLINE drift audit (depends on test-wasm)

# From examples/counter_greeter or examples/todo
zig build run            # CLI canary
zig build ui             # wgpu native window (Linux X11 / Windows, by target OS)
zig build web            # wasm + WebGPU via zunk — writes dist/
zig build web-run        # same, then serves dist/ on localhost:8080
```

Building the Linux UI needs no X11 dev package (libX11 is `dlopen`ed at runtime); at runtime it needs `libX11.so.6`, a Vulkan driver, and a monospace TTF (DejaVuSansMono by default; override with `TEAK_FONT`).

Three examples so far: **counter_greeter** (composed app via `Components`, one counter + one greeter), **todo** (dynamic-list stress: N rows from `Model.items`, `Msg`-with-index for per-row actions, scroll-clipped list), and **tree** (recursive view emission, conditional visibility by ancestor state, expand/collapse over a flat pre-order node array).

Windows ARM64 hosts: pass `-Dtarget=aarch64-windows-gnu` to `zig build ui` until Zig ships a fix for [Codeberg #31865](https://codeberg.org/ziglang/zig/issues/31865). See [`docs/archive/zig-016-win-arm64-crash.md`](docs/archive/zig-016-win-arm64-crash.md).

## Where to read next

- [`docs/HARDLINE.md`](docs/HARDLINE.md) — the non-negotiable rules. Start here.
- [`docs/consuming-teak.md`](docs/consuming-teak.md) — **build an app**: `build.zig.zon` → `teak.run` in a few steps.
- [`CLAUDE.md`](CLAUDE.md) — orientation for LLMs and new contributors.
- [`docs/features/`](docs/features/) — one contract per `pub` surface unit (`teak.run`, widgets, `Components`, `TransientState`, `Host`, `Gpu`, hit-test, layout, focus).
- [`docs/pitfalls.md`](docs/pitfalls.md) — real bugs we hit and how to recognise their shape next time.
- [`docs/archive/zunk-roadmap.md`](docs/archive/zunk-roadmap.md) — what Teak needs from zunk next, in priority order.
- [`spec.md`](spec.md) — full architecture spec.

## Module layout

```
src/
├── teak.zig              public library root, re-exports
├── run.zig               teak.run — canonical host-loop wrapper
├── core/
│   ├── cmd.zig           Cmd union, CmdBuffer, arena management (incl. disabled)
│   ├── component.zig     Components(), validateComponent, buildMsgs
│   ├── text_field.zig    TextField(cap) + key dispatch helpers
│   ├── numeric_field.zig NumericField(config) — parse/validate/value
│   ├── dropdown.zig      Dropdown(cap) — closed button + open overlay list
│   └── transient.zig     hover/press/focus presentation state
├── layout/engine.zig     measure + position passes
├── input/
│   ├── hit_test.zig      mouse → CmdIndex → Msg (disabled leaves inert)
│   ├── focus.zig         traversal + indexOfFocusMsg / focusMsgAt
│   └── keys.zig          SpecialKey enum (incl. tab / shift_tab)
├── render/
│   ├── vertex.zig        Vertex struct, emitQuad
│   └── build.zig         []Cmd + []Rect + TransientState → vertex buffer
├── platform/             Host interface + Win32 / X11 / wasm backends
└── gpu/                  Gpu interface + wgpu-native (Win32+GDI / X11+stb_truetype) / zunk

examples/counter_greeter/  proto-2 demo; composed Components + focus routing
examples/todo/             dynamic-list demo; N rows, Msg-with-index, scroll
examples/tree/             recursive tree with expand/collapse over flat Model
tools/audit.zig            HARDLINE drift audit (zig build audit)
test/integration_test.zig  round-trip pipeline + wasm canary
shaders/quad.wgsl          colored-rectangle shader (shared by both GPU backends)
```

The library has no external dependencies. Concrete Host and GPU backends pull in wgpu-native (native) or zunk (web); each example wires the backends it needs in its own `build.zig`.
