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

Requires **Zig 0.15.2+**.

```sh
# Run the main executable
zig build run

# Run the UI (wgpu + Win32)
zig build ui

# Run tests
zig build test
```

The wgpu-native dependency is fetched automatically by the Zig build system on first build.

## Project Structure

```
teak/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig           ← entry point, window creation, main loop
│   ├── root.zig           ← public library root
│   ├── teak.zig           ← re-exports framework types
│   ├── model.zig          ← Model, Msg, update (the app)
│   ├── cmd.zig            ← Cmd union, CmdBuffer, arena management
│   ├── layout.zig         ← measure + position passes
│   ├── hit_test.zig       ← mouse → CmdIndex → Msg
│   ├── render.zig         ← []Cmd + []Rect → wgpu draw calls
│   └── transient.zig      ← hover/press state
├── shaders/
│   └── quad.wgsl          ← shader for colored rectangles
├── docs/
│   └── init_convo/        ← original design conversation
└── spec.md                ← full specification
```

## Documentation

- [`spec.md`](spec.md) — Full architecture specification, design rationale, and implementation plan.
- [`docs/init_convo/`](docs/init_convo/) — Original design documents that shaped the framework.

## Status

Early prototype. The first milestone is a clickable counter: mouse click on a button, hit-test, Msg, update, Model changes, next frame draws the new state. The full loop, closed, with real pixels.
