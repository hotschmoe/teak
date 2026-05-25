# Teak Specification

TEA + Command Buffer: A Zig-Native UI Framework.

---

## Motivation

Every generation of UI frameworks has been shaped by the language it was written in. Cocoa is inseparable from Objective-C's message passing. React is inseparable from JavaScript's closures. Elm Architecture is inseparable from Elm's algebraic types.

Zig is a genuinely new language with genuinely new properties. The interesting question is: *what UI paradigm would you invent if Zig were your only language?*

Teak is an answer to that question. It combines TEA's state management with command-buffer rendering, leveraging Zig's comptime, tagged unions, explicit allocators, and first-class C interop.

---

## Goals

1. **Zig-idiomatic.** The framework should feel like Zig. If a design choice fights the language, we change the design.
2. **Comptime-leveraged.** Use comptime as a structural advantage — generating code, enforcing invariants, eliminating boilerplate.
3. **LLM-friendly.** Regular patterns, explicit state, enumerated transitions, linear code flow. Every feature follows: add field to Model, add variant to Msg, add switch arm to update, add commands to view.
4. **Cross-platform via wgpu.** Native graphics on desktop, WebGPU via WASM on the web.
5. **Novel.** Not a port. Not a clone. Something new, shaped by the intersection of Zig's properties and the problem space of interactive UIs.

---

## Zig Properties That Shape the Design

### Zig Gives Us

- **Comptime metaprogramming** — type inspection, code generation, inline loops over struct fields.
- **Tagged unions with exhaustive switching** — `union(enum)` types where the compiler enforces every variant is handled.
- **Explicit allocators** — every allocation site names its allocator. Arena allocators for bulk alloc/free.
- **`anytype` / duck-typing at comptime** — generic functions resolved and monomorphized at compile time.
- **First-class C interop** — `@cImport` directly.
- **WASM target** — first-class compilation to WebAssembly.

### Zig Denies Us

- Closures / capturing lambdas.
- Inheritance / virtual dispatch.
- Runtime type information.
- Operator overloading.
- Implicit allocation.
- Trait / interface dispatch.

### wgpu Constrains Us To

- A render loop (request frame, encode commands, submit, present).
- Command buffer encoding — record drawing commands, don't draw directly.
- GPU resources that lag CPU by a frame or two.
- A pipeline model that rewards batching draw calls.

---

## Architecture

### State Layer: TEA (Model-View-Update)

All application state is a struct. Every possible state transition is a variant of a tagged union. The update function is a switch.

```zig
const Model = struct {
    count: i32 = 0,
};

const Msg = union(enum) {
    increment,
    decrement,
    reset,
};

fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .increment => model.count += 1,
        .decrement => model.count -= 1,
        .reset => model.count = 0,
    }
}
```

Stateful widgets are solved, not hidden. A text input's cursor position is a field in the Model. Scroll offsets are in the Model. There is no hidden widget state cache. Everything is visible, inspectable, and serializable.

Undo/redo is free — log the Msg history, replay from the beginning to any point.

### View Layer: Command Buffer

The view function emits commands into a flat, arena-allocated buffer. It does not draw anything. It does not allocate persistent state. It runs every frame.

```zig
fn view(model: Model, cmd: *CmdBuffer) void {
    cmd.push_group(.{ .direction = .vertical, .padding = 20, .gap = 12 });

    const count_str = std.fmt.allocPrint(
        cmd.arena.allocator(),
        "Count: {d}",
        .{model.count},
    ) catch unreachable;
    cmd.text(count_str);

    cmd.push_group(.{ .direction = .horizontal, .gap = 8 });
    cmd.button(.increment, "+");
    cmd.button(.decrement, "-");
    cmd.pop_group();

    cmd.button(.reset, "Reset");

    cmd.pop_group();
}
```

Commands are a tagged union:

```zig
const Cmd = union(enum) {
    push_group: GroupStyle,
    pop_group,
    push_scroll: ScrollStyle,
    pop_scroll,
    push_overlay: OverlayStyle(Msg),    // floating layer, draws above + hit-tests first; `modal`/`backdrop_msg` for click-outside-to-close
    pop_overlay,
    push_virtual_list: VirtualListStyle, // 10k-row tables w/ bounded per-frame work
    pop_virtual_list,
    text: TextCmd,
    rich_text: RichTextCmd,             // mixed-run styled text (color/font per span)
    image: ImageCmd,                    // textured quad, opaque TextureHandle
    button: ButtonCmd(Msg),
    text_input: TextInputCmd(Msg),      // carries selection_anchor for ranges
    checkbox: CheckboxCmd(Msg),
    radio: RadioCmd(Msg),
    slider: SliderCmd(Msg),
    divider: DividerStyle,
};
```

Adding a new widget = adding a variant + a case in each pass + a convenience method on CmdBuffer.

The overlay layer + subscription runtime were added under HARDLINE §2 escape hatches 5 and 6 respectively. See [`docs/features/functional-gaps.md`](docs/features/functional-gaps.md) for the full functional-gaps push that closed the production-readiness list.

### Passes

After the view function fills the command buffer, independent passes process it:

```
view(model, &cmds)
        |
        v
  []Cmd flat buffer  <-- arena-allocated tagged unions
        |
   +----|------------------+
   v    v                  v
layout  hit_test        render
 pass    pass             pass
   |       |                |
   v       v                v
[]Rect   ?Msg      wgpu draw calls
```

Each pass is a plain function. No callbacks, no closures, no object graphs.

### Layout Pass

Two linear passes over `[]Cmd`, producing `[]Rect`.

**Pass 1 — Measure (bottom-up):** Walk forward. Leaf widgets get sizes. Groups accumulate children via a stack.

**Pass 2 — Position (top-down):** Walk forward again. All sizes known. Assign absolute x, y coordinates. Stack tracks cursor position within each group.

Both passes are O(n) forward scans. The stack is a fixed-size array (`BoundedArray(GroupContext, 32)`) — nesting beyond 32 levels doesn't occur in real UIs. No tree nodes allocated. No pointer chasing.

### Hit-Test Pass

Walk backwards through `[]Cmd` and `[]Rect` (painter's order for z-ordering). Check bounds. Return the `Msg` embedded in the command. No ID hashing. No callback lookup. The command *is* the event binding.

### Render Pass

Takes `[]Cmd`, `[]Rect`, and `TransientState`. Emits wgpu draw calls. For the prototype: colored rectangles only. Text rendered as placeholder rects with actual text logged to stderr.

### Arena Double Buffering

Two arenas alternate each frame. Frame N's commands live in arena A; frame N+1 in arena B. Diffing is a linear scan over flat arrays, not a tree walk. After diffing, the old arena is bulk-freed. Zero per-widget deallocation. Zero fragmentation.

---

## Escape Hatches from Pure TEA

Three deliberate, bounded deviations:

### 1. Comptime Component Composition

A component is any type exposing `Model`, `Msg`, `update`, `view`. Comptime stitches them together — generating the composed `AppModel`, `AppMsg`, and routing `app_update` function automatically.

```zig
const App = Components(.{
    .sidebar = Sidebar,
    .editor = Editor,
    .status_bar = StatusBar,
}, struct {
    file_path: ?[]const u8 = null,
    pub const Msg = union(enum) { open_file: []const u8, quit };
    pub fn update(model: *@This(), msg: Msg) void { ... }
});
```

**Boundary:** Components must pass `validateComponent` — clear compile errors naming the component and specific problem.

### 2. TransientState for Presentation Concerns

Hover, press, and animation state bypass the TEA loop. The render pass owns a small `TransientState` struct that never touches the Model.

```zig
const TransientState = struct {
    hover_index: ?usize = null,
    press_index: ?usize = null,
    focus_index: ?usize = null,
};
```

**Boundary:** Only state that is (a) derivable from current-frame input, (b) does not affect application logic, and (c) resets cleanly if lost.

### 3. Stack-Based Layout Over Flat Buffer

The command buffer is flat but layout is hierarchical. Solved with a stack-based approach — two O(n) linear passes, fixed-depth stack, no tree construction.

**Boundary:** Start with vertical/horizontal stacking + flex proportions. More advanced layout (CSS Grid, constraints) added as alternative pass implementations, not changes to the command buffer.

---

## The Main Loop

```
model = Model{};
cmd_buf = CmdBuffer.init(allocator);

loop {
    // 1. Poll input
    mouse = poll_mouse_events();

    // 2. Hit-test against LAST FRAME's commands and rects
    if (mouse.clicked) {
        if (hit_test(last_cmds, last_rects, mouse.x, mouse.y)) |hit| {
            update(&model, hit.msg);
        }
    }

    // 3. Update transient state (hover — no Msg, no update)
    transient.hover_index = hover_test(last_cmds, last_rects, mouse.x, mouse.y);

    // 4. Rebuild command buffer
    cmd_buf.reset();
    view(model, &cmd_buf);

    // 5. Layout
    measure_pass(cmd_buf.cmds.items, rects, window_size);
    position_pass(cmd_buf.cmds.items, rects);

    // 6. Render
    render_pass(cmd_buf.cmds.items, rects, transient, encoder);

    // 7. Present
    surface.present();
}
```

Hit-testing runs against the *previous* frame's commands and rects. This is correct — you need to know where things were when the user clicked. The one-frame latency is imperceptible.

---

## Platform Layer

```
                APPLICATION CODE
        Model / Msg / update / view
           (pure Zig, no platform deps)
                    |
                FRAMEWORK LAYER
    CmdBuffer, layout, hit-test, render
           (pure Zig, depends only on wgpu C API)
                    |
                 wgpu C API
            (wgpu-native or Dawn)
           /       |       |       \
        Vulkan   Metal   DX12   WebGPU
        Linux    macOS   Windows  WASM
```

Platform differences are below the wgpu line. Everything above is identical across all targets.

---

## Implementation Phases

### Phase 1: Model, Msg, Update
Define `Model`, `Msg`, `update` in `model.zig`. Write tests. Pure Zig, no wgpu needed.

### Phase 2: Command Buffer
Define `Cmd`, `CmdBuffer`, convenience emitters, and the `view` function. Test by iterating commands and printing tags.

### Phase 3: Layout Pass
Implement measure and position passes in `layout.zig`. Two-pass stack-based algorithm over `[]Cmd` producing `[]Rect`. Test by verifying computed rectangles against hand-calculated values.

### Phase 4: Render Pass (wgpu)
Initialize wgpu, create pipeline with `quad.wgsl` shader. Render `[]Cmd` + `[]Rect` as colored rectangles. Text is placeholder rects for now.

### Phase 5: Hit-Test Pass
Map mouse position to `Msg` by walking `[]Cmd` + `[]Rect` backwards. Log hit results on click.

### Phase 6: Close the Loop
Wire everything together in `main.zig`. Click a button, see the count change. The full architecture is proven.

### Stretch: TransientState + Hover
Add `TransientState`, hover detection, render-time color swapping. Validates the TEA escape hatch.

---

## LLM Friendliness

Every feature addition follows four steps:

1. **Add a field to Model.** (The new state.)
2. **Add a variant to Msg.** (The new transition.)
3. **Add a switch arm to update.** (The new behavior.)
4. **Add `cmd.*` calls to view.** (The new UI.)

The compiler enforces exhaustive handling. If you add a Msg variant and forget the switch arm, it won't compile. The compiler is the safety net.

---

*This specification is a living document. The ideas here are meant to be challenged, extended, and proven or disproven by implementation.*
