# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

Requires **Zig 0.15.2+**.

```sh
zig build run       # Run the main CLI executable
zig build ui        # Run the UI executable (wgpu + Win32)
zig build test      # Run all tests (library + CLI modules)
```

The `wgpu-native` dependency is fetched automatically on first build. The build targets Windows ARM64 (Snapdragon X Elite) with a workaround for Zig's missing `i8mm` CPU feature detection on aarch64.

## Architecture

Teak is a Zig-native UI framework combining **TEA (The Elm Architecture)** for state management with **command buffer rendering** via wgpu.

### The Core Loop

```
Model -> view() -> []Cmd -> layout -> []Rect -> render -> pixels
                                        ^
          mouse click -> hit_test -> Msg -> update -> Model'
```

Every arrow is a function call with explicit inputs and outputs. No globals, no singletons, no event bus.

### Layers

| Layer | What it does | Key types |
|-------|-------------|-----------|
| **State (TEA)** | `Model` struct holds all app state. `Msg` tagged union enumerates transitions. `update` is a switch. | `Model`, `Msg`, `update()` |
| **View** | `view()` emits flat `[]Cmd` tagged unions into an arena-allocated `CmdBuffer`. Runs every frame. | `Cmd`, `CmdBuffer`, `view()` |
| **Layout** | Two O(n) linear passes (measure bottom-up, position top-down) over `[]Cmd` producing `[]Rect`. Stack-based, no tree allocation. | `Rect`, `LayoutEngine` |
| **Hit-test** | Walks `[]Cmd` + `[]Rect` backwards (painter's order). Returns the `Msg` embedded in the command. No ID hashing. | `hit_test()` |
| **Render** | Converts `[]Cmd` + `[]Rect` + `TransientState` into wgpu draw calls (colored quads). | `render_pass()`, `Vertex` |
| **TransientState** | Hover/press/focus state that bypasses the TEA loop entirely -- short circuits from input to render. | `TransientState` |

### Key Design Patterns

- **All state in one Model struct.** No hidden widget state. Cursor positions, scroll offsets, focus -- all explicit fields.
- **Commands are flat tagged unions.** Layout, hit-test, and render are independent passes over the same `[]Cmd` buffer.
- **Arena allocation per frame.** Two arenas alternate. Bulk-free each frame. Zero per-widget deallocation.
- **Hit-test runs against the previous frame's commands/rects.** One-frame latency is correct and imperceptible.
- **Comptime component composition.** Components expose `Model`/`Msg`/`update`/`view`; comptime generates routing.

### Adding Features

Every feature follows four mechanical steps:

1. Add a field to `Model` (new state)
2. Add a variant to `Msg` (new transition)
3. Add a switch arm to `update` (new behavior)
4. Add `cmd.*` calls to `view` (new UI)

The compiler enforces exhaustive switching -- missing a `Msg` arm won't compile.

### Adding Widgets

Add a variant to the `Cmd` union + a case in each pass (layout, hit-test, render) + a convenience method on `CmdBuffer`.

## Planned Module Structure

```
src/
  main.zig        -- entry point, window creation, main loop
  root.zig        -- public library root
  model.zig       -- Model, Msg, update, view (the application)
  cmd.zig         -- Cmd union, CmdBuffer, arena management
  layout.zig      -- measure + position passes
  hit_test.zig    -- mouse -> CmdIndex -> Msg
  render.zig      -- []Cmd + []Rect -> wgpu draw calls
  transient.zig   -- hover/press state (TransientState)
shaders/
  quad.wgsl       -- shader for colored rectangles
```

Each file does one thing. Keep them separate.

## Implementation Status

The project is in **design-complete, implementation-starting** phase. The prototype goal is a clickable counter demonstrating the full closed loop. Implementation follows six sequential phases (see `docs/init_convo/first_proto.md` for details and checkpoints):

1. Model/Msg/update (pure Zig, no wgpu)
2. CmdBuffer + view function
3. Layout pass (measure + position)
4. Render pass (wgpu colored quads)
5. Hit-test pass
6. Close the loop (wire main.zig)
7. Stretch: TransientState + hover

## Key Documentation

- `spec.md` -- full architecture specification
- `docs/init_convo/first_proto.md` -- phase-by-phase prototype guide with checkpoints
- `docs/init_convo/ui-framework-diagrams.md` -- 15 architecture diagrams
- `docs/init_convo/ui-framework-refinement.md` -- escape hatches, design tradeoffs, implementation traps

## Zig Conventions

- Types: `PascalCase`. Functions: `snake_case`. Enum variants: lowercase with underscores.
- Explicit allocators everywhere. Arena allocators for per-frame data.
- Convenience emitters on `CmdBuffer` use `catch unreachable` (arena OOM is unrecoverable).
- Text measurement uses monospace approximation (`content.len * CHAR_WIDTH`) for the prototype.
