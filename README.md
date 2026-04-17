# Teak

A Zig-native UI framework built on **TEA (The Elm Architecture)** + **command buffer rendering** via **wgpu**.

Teak explores what a UI paradigm looks like when designed from Zig's strengths — comptime metaprogramming, tagged unions with exhaustive switching, explicit allocators, and arena-based memory — rather than porting an existing framework.

## Architecture

| Layer           | Paradigm         | Zig Mechanism                    |
|-----------------|------------------|----------------------------------|
| State           | TEA              | `struct` + `union(enum)` + `switch` |
| View            | Command buffer   | `[]Cmd` in arena allocator       |
| Layout          | Multi-pass       | `fn([]Cmd) []Rect`              |
| Rendering       | wgpu             | Command encoder from `[]Rect`    |
| Input           | Hit-test pass    | `fn([]Cmd, []Rect, Mouse) ?Msg` |
| Metaprogramming | Comptime         | Type reflection + code generation |

### The Core Loop

```
Model → view() → []Cmd → layout → []Rect → render → pixels
                                      ↑
          mouse click → hit_test → Msg → update → Model'
```

Every arrow is a function call with explicit inputs and outputs. No globals, no singletons, no event bus.

### Key Design Decisions

- **All state in one Model struct.** No hidden widget state caches, no ID hashing. Cursor positions, scroll offsets, and focus state are explicit fields.
- **Commands are flat tagged unions.** The view function emits commands into an arena-allocated buffer. Layout, hit-test, and render are independent passes over that buffer.
- **TransientState for presentation concerns.** Hover highlights and press animations bypass the TEA loop entirely — no `Msg`, no `update`, no `view` rebuild. Just a short circuit from input to render.
- **Comptime component composition.** Components expose `Model`/`Msg`/`update`/`view` and comptime stitches them together, generating routing and nesting automatically.

## Building

Requires **Zig 0.16.0+**.

```sh
# Library tests (run from repo root)
zig build test

# Example app — CLI canary and wgpu UI both live in examples/counter_greeter
cd examples/counter_greeter
zig build test                               # example tests
zig build run                                # CLI demo
zig build ui -Dtarget=aarch64-windows-gnu    # wgpu + Win32 UI (ARM64 host)
zig build ui                                 # wgpu + Win32 UI (x86_64 host)
```

The wgpu-native dependency is fetched automatically by the Zig build system on first build.

### Cross-target builds

The example's `build.zig` auto-picks the right wgpu-native prebuilt (aarch64 or x86_64 Windows) based on the resolved target, so on a native x86_64 Windows host `zig build ui` just works without flags.

### Windows ARM64 notes

Zig's own 0.16.0 `aarch64-windows` compiler binary is currently broken (upstream [Codeberg #31865](https://codeberg.org/ziglang/zig/issues/31865)) — so we run the **x86_64-windows** `zig.exe` under Windows-on-ARM (Prism) emulation, and cross-compile the app to native `aarch64-windows` with `-Dtarget=aarch64-windows-gnu`. Only the compiler is emulated; `teak-ui.exe` is a real ARM64 binary. See [`docs/zig-016-win-arm64-crash.md`](docs/zig-016-win-arm64-crash.md) for the full story.

## Project Structure

```
teak/
├── build.zig              ← library build (module + tests)
├── build.zig.zon
├── src/                   ← the library, consumable as a Zig module
│   ├── teak.zig           ← public library root / re-exports
│   ├── core/
│   │   ├── cmd.zig        ← Cmd union, CmdBuffer, arena management
│   │   ├── component.zig  ← Components(), validateComponent, buildMsgs
│   │   └── transient.zig  ← hover/press/focus state
│   ├── layout/
│   │   └── engine.zig     ← measure + position passes
│   ├── input/
│   │   └── hit_test.zig   ← mouse → CmdIndex → Msg
│   └── render/
│       ├── vertex.zig     ← Vertex struct + emitQuad
│       └── build.zig      ← []Cmd + []Rect → vertex buffer
├── examples/
│   └── counter_greeter/   ← the proto-2 demo; consumes teak as a module
│       ├── build.zig
│       ├── build.zig.zon
│       └── src/
│           ├── main.zig        ← CLI canary entry
│           ├── ui_main.zig     ← wgpu + Win32 entry
│           ├── app.zig         ← composed app (counter + greeter)
│           ├── counter.zig
│           └── greeter.zig
├── shaders/
│   └── quad.wgsl          ← shader for colored rectangles
└── docs/                  ← spec, journal, archive
```

## Documentation

- [`spec.md`](spec.md) — Full architecture specification, design rationale, and implementation plan.
- [`docs/archive/init_convo/`](docs/archive/init_convo/) — Original design documents that shaped the framework.

## Status

Early prototype. The first milestone is a clickable counter: mouse click on a button, hit-test, Msg, update, Model changes, next frame draws the new state. The full loop, closed, with real pixels.
