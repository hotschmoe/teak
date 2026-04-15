# Teak: First Prototype

Goal: a clickable counter on screen. Mouse click on a button → hit-test → Msg → update → Model changes → next frame draws the new state. The full loop, closed, with real pixels.

Stretch goal: hover highlight via TransientState, proving the TEA escape hatch from day one.

---

## What We're Building

```
    ┌────────────────────────────────┐
    │                                │
    │        Count: 7                │
    │                                │
    │    [ + ]        [ - ]          │
    │                                │
    │    [ Reset ]                   │
    │                                │
    └────────────────────────────────┘

    Click [ + ]  → count becomes 8
    Click [ - ]  → count becomes 6
    Click [Reset]→ count becomes 0
    Hover any button → background color changes (stretch goal)
```

That's it. No text input. No scrolling. No flex layout. Just enough to prove every layer talks to every other layer.

---

## Project Structure

```
teak/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig           ← entry point, window creation, main loop
│   ├── teak.zig           ← public root: re-exports framework types
│   ├── model.zig          ← Model, Msg, update (the app)
│   ├── cmd.zig            ← Cmd union, CmdBuffer, arena management
│   ├── layout.zig         ← measure + position passes
│   ├── hit_test.zig       ← mouse → CmdIndex → Msg
│   ├── render.zig         ← []Cmd + []Rect → wgpu draw calls
│   └── transient.zig      ← hover/press state (stretch goal)
└── shaders/
    └── quad.wgsl          ← single shader for colored rectangles
```

Each file is small. Each file does one thing. Resist the urge to merge them.

---

## Phase 1: Model, Msg, Update

This is the application. It should take five minutes.

### model.zig

```zig
const Msg = union(enum) {
    increment,
    decrement,
    reset,
};

const Model = struct {
    count: i32 = 0,
};

fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .increment => model.count += 1,
        .decrement => model.count -= 1,
        .reset => model.count = 0,
    }
}
```

That's the entire application. Everything else is framework.

**Checkpoint:** this compiles. Write a test that calls `update` with each `Msg` variant and asserts the expected `Model` state. Run it. Move on.

---

## Phase 2: Command Buffer

The command buffer is a flat array of tagged unions, backed by an arena allocator.

### cmd.zig

Start with the minimum set of commands:

```zig
const Cmd = union(enum) {
    push_group: GroupStyle,
    pop_group,
    text: TextCmd,
    button: ButtonCmd,
};

const GroupStyle = struct {
    direction: enum { vertical, horizontal } = .vertical,
    padding: f32 = 8,
    gap: f32 = 8,
};

const TextCmd = struct {
    content: []const u8,
};

const ButtonCmd = struct {
    msg: Msg,       // what this button triggers when clicked
    label: []const u8,
    style: ButtonStyle = .{},
};

const ButtonStyle = struct {
    bg: [4]f32 = .{ 0.25, 0.25, 0.25, 1.0 },
    hover_bg: [4]f32 = .{ 0.35, 0.35, 0.35, 1.0 },  // stretch goal
    press_bg: [4]f32 = .{ 0.15, 0.15, 0.15, 1.0 },  // stretch goal
    fg: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    corner_radius: f32 = 4,
};
```

The buffer itself:

```zig
const CmdBuffer = struct {
    cmds: std.ArrayList(Cmd),
    arena: std.heap.ArenaAllocator,

    fn init(backing: std.mem.Allocator) CmdBuffer {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .cmds = std.ArrayList(Cmd).init(backing),
        };
    }

    fn reset(self: *CmdBuffer) void {
        self.cmds.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    // --- convenience emitters ---

    fn push_group(self: *CmdBuffer, style: GroupStyle) void {
        self.cmds.append(.{ .push_group = style }) catch unreachable;
    }

    fn pop_group(self: *CmdBuffer) void {
        self.cmds.append(.pop_group) catch unreachable;
    }

    fn text(self: *CmdBuffer, content: []const u8) void {
        self.cmds.append(.{ .text = .{ .content = content } }) catch unreachable;
    }

    fn button(self: *CmdBuffer, msg: Msg, label: []const u8) void {
        self.cmds.append(.{ .button = .{
            .msg = msg,
            .label = label,
        } }) catch unreachable;
    }
};
```

### The view function

This lives in `model.zig` alongside the Model. It's the bridge between application and framework.

```zig
fn view(model: Model, cmd: *CmdBuffer) void {
    cmd.push_group(.{ .direction = .vertical, .padding = 20, .gap = 12 });

    // Format count into arena-allocated string
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

Note: the formatted string is allocated from the command buffer's arena. It lives until `cmd.reset()` next frame. No leak, no manual free.

**Checkpoint:** call `view` with a test Model, iterate `cmd.cmds.items`, print each command's tag. You should see: `push_group, text, push_group, button, button, pop_group, button, pop_group`. The structure is correct. Move on.

---

## Phase 3: Layout Pass

Two linear passes over `[]Cmd`, producing `[]Rect`.

### layout.zig

```zig
const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

const GroupContext = struct {
    cmd_index: usize,           // index of the push_group command
    direction: GroupStyle.Direction,
    padding: f32,
    gap: f32,

    // accumulator for children's sizes
    main_axis_total: f32 = 0,   // sum along layout direction
    cross_axis_max: f32 = 0,    // max perpendicular to layout direction
    child_count: u32 = 0,
};

const LayoutEngine = struct {
    stack: std.BoundedArray(GroupContext, 32) = .{},
    rects: []Rect,

    // Hardcoded sizes for the prototype. Replace with real text measurement later.
    const TEXT_HEIGHT = 20;
    const BUTTON_HEIGHT = 36;
    const BUTTON_MIN_WIDTH = 60;
};
```

**Pass 1 — Measure:**

Walk forward. Leaf widgets get hardcoded sizes (real text measurement comes later). Groups accumulate children.

```
    ALGORITHM:
    
    push_group → push GroupContext onto stack
    text       → size = (TEXT_WIDTH, TEXT_HEIGHT)
                 add to stack.top accumulator
                 write size to rects[i]
    button     → size = (max(label_width, BUTTON_MIN_WIDTH), BUTTON_HEIGHT)
                 add to stack.top accumulator
                 write size to rects[i]
    pop_group  → compute group size from accumulator:
                   vertical:   w = cross_axis_max + 2*pad
                                h = main_axis_total + gaps + 2*pad
                   horizontal: w = main_axis_total + gaps + 2*pad
                                h = cross_axis_max + 2*pad
                 write group size to rects[group.cmd_index]
                 pop stack
                 add group size to NEW stack.top (parent)
```

For the prototype, text width can be `content.len * CHAR_WIDTH` with a monospace assumption. Good enough.

**Pass 2 — Position:**

Walk forward again. Now all sizes are known. Assign x, y.

```
    ALGORITHM:

    push_group → cursor starts at (rect.x + pad, rect.y + pad)
                 push cursor onto stack
    text       → rects[i].x = cursor.x
                 rects[i].y = cursor.y
                 advance cursor (down if V, right if H)
    button     → same as text
    pop_group  → pop cursor from stack
```

**Checkpoint:** after both passes, print every `Rect`. For the counter UI with a 400px window, you should see something like:

```
    [0] push_v:  x=0    y=0    w=400  h=128
    [1] text:    x=20   y=20   w=360  h=20
    [2] push_h:  x=20   y=52   w=136  h=36
    [3] btn "+": x=20   y=52   w=60   h=36
    [4] btn "-": x=88   y=52   w=60   h=36
    [5] pop_h
    [6] btn "R": x=20   y=100  w=80   h=36
    [7] pop_v
```

Verify these numbers by hand. If they're wrong, fix the layout before touching rendering. This is the foundation everything else sits on.

---

## Phase 4: Render Pass (wgpu)

This is where you bring zilmaril experience. The render pass takes `[]Cmd` and `[]Rect` and emits wgpu draw calls.

### The Minimal Renderer

For the prototype, you need exactly one capability: **draw a colored rectangle at a position.**

Text is also colored rectangles — each glyph is a quad textured from a font atlas. But for day one, you can cheat: render text as a solid rectangle with a different color and print the actual text to stderr. Ugly, but it closes the loop. Real text rendering is a week of work; don't let it block the prototype.

### quad.wgsl

One shader, two modes: solid color and textured (for text later).

```wgsl
struct VertexOutput {
    @builtin(position) pos: vec4f,
    @location(0) color: vec4f,
    @location(1) uv: vec2f,
};

struct Uniforms {
    screen_size: vec2f,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

@vertex
fn vs_main(
    @location(0) pos: vec2f,      // pixel coordinates
    @location(1) color: vec4f,
    @location(2) uv: vec2f,
) -> VertexOutput {
    // Convert pixel coords to clip space
    let clip = vec2f(
        (pos.x / uniforms.screen_size.x) * 2.0 - 1.0,
        1.0 - (pos.y / uniforms.screen_size.y) * 2.0,
    );
    return VertexOutput(vec4f(clip, 0.0, 1.0), color, uv);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    return in.color;
}
```

### render.zig

```
    FOR EACH (cmd, rect) PAIR:

    .text   → emit 1 quad: rect position, text bg color
              (placeholder: just a colored rectangle)
              log actual text to stderr for debugging

    .button → emit 1 quad: rect position, button bg color
              (later: emit glyph quads for label on top)

    .push_group, .pop_group → skip (or optionally draw debug outlines)
```

Build a vertex buffer from all the quads, submit one draw call. For the prototype this is fine — you'll have maybe 6 quads total.

```zig
const Vertex = struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    u: f32,
    v: f32,
};

fn emit_quad(verts: *std.ArrayList(Vertex), rect: Rect, color: [4]f32) void {
    // Two triangles for a rectangle
    const x0 = rect.x;
    const y0 = rect.y;
    const x1 = rect.x + rect.w;
    const y1 = rect.y + rect.h;

    const c = color;
    verts.appendSlice(&.{
        .{ .x = x0, .y = y0, .r = c[0], .g = c[1], .b = c[2], .a = c[3], .u = 0, .v = 0 },
        .{ .x = x1, .y = y0, .r = c[0], .g = c[1], .b = c[2], .a = c[3], .u = 1, .v = 0 },
        .{ .x = x0, .y = y1, .r = c[0], .g = c[1], .b = c[2], .a = c[3], .u = 0, .v = 1 },
        .{ .x = x1, .y = y0, .r = c[0], .g = c[1], .b = c[2], .a = c[3], .u = 1, .v = 0 },
        .{ .x = x1, .y = y1, .r = c[0], .g = c[1], .b = c[2], .a = c[3], .u = 1, .v = 1 },
        .{ .x = x0, .y = y1, .r = c[0], .g = c[1], .b = c[2], .a = c[3], .u = 0, .v = 1 },
    }) catch unreachable;
}
```

**Checkpoint:** you see colored rectangles on screen that correspond to your layout rects. The text rectangle is a different color from the button rectangles. The positions match what the layout pass computed. It looks like a brutalist wireframe and that is correct.

---

## Phase 5: Hit-Test Pass

Map mouse position to a Msg.

### hit_test.zig

```zig
fn hit_test(
    cmds: []const Cmd,
    rects: []const Rect,
    mouse_x: f32,
    mouse_y: f32,
) ?struct { index: usize, msg: Msg } {
    // Walk BACKWARDS — last drawn is on top (painter's order)
    var i: usize = cmds.len;
    while (i > 0) {
        i -= 1;
        const rect = rects[i];
        switch (cmds[i]) {
            .button => |btn| {
                if (mouse_x >= rect.x and mouse_x <= rect.x + rect.w and
                    mouse_y >= rect.y and mouse_y <= rect.y + rect.h)
                {
                    return .{ .index = i, .msg = btn.msg };
                }
            },
            else => {},
        }
    }
    return null;
}
```

That's it. Walk backwards (for z-order), check bounds, return the Msg embedded in the command.

No ID hashing. No callback lookup. No event registration. The command *is* the event binding.

**Checkpoint:** log the hit-test result on every mouse click. You should see `.increment`, `.decrement`, or `.reset` depending on where you click, and `null` when you click empty space.

---

## Phase 6: Close the Loop

### main.zig — the main loop

This is where everything connects.

```
    MAIN LOOP (pseudocode):
    ════════════════════════

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

        // 3. Rebuild command buffer
        cmd_buf.reset();
        view(model, &cmd_buf);

        // 4. Layout
        measure_pass(cmd_buf.cmds.items, rects, window_size);
        position_pass(cmd_buf.cmds.items, rects);

        // 5. Render
        render_pass(cmd_buf.cmds.items, rects, encoder);

        // 6. Present
        surface.present();
    }
```

Note: hit-testing runs against the *previous* frame's commands and rects. This is correct and unavoidable — you need to know where things were when the user clicked, not where they'll be after the state change. The one-frame latency is imperceptible.

```
    THE CLOSED LOOP
    ════════════════

    ┌─────────┐    click     ┌──────────┐
    │  mouse  │─────────────▶│ hit_test │
    └─────────┘              └────┬─────┘
                                  │ Msg
                                  ▼
                             ┌──────────┐
                             │  update  │
                             └────┬─────┘
                                  │ Model'
                                  ▼
                             ┌──────────┐
                             │   view   │
                             └────┬─────┘
                                  │ []Cmd
                                  ▼
                             ┌──────────┐
                             │  layout  │
                             └────┬─────┘
                                  │ []Rect
                                  ▼
                             ┌──────────┐
                             │  render  │──────▶ pixels
                             └──────────┘

    Every arrow is a function call with explicit inputs and outputs.
    No globals. No singletons. No event bus.
    You can trace any pixel back to the Model field that caused it.
```

**Checkpoint:** click `+` three times, see `Count: 3`. Click `-`, see `Count: 2`. Click `Reset`, see `Count: 0`. The full architecture is proven.

---

## Stretch Goal: Hover via TransientState

This is the first deliberate break from pure TEA. We're doing it now to validate the escape hatch early.

### transient.zig

```zig
const TransientState = struct {
    hover_index: ?usize = null,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
};
```

### Changes to hit_test.zig

Add a non-click query:

```zig
fn hover_test(
    cmds: []const Cmd,
    rects: []const Rect,
    mouse_x: f32,
    mouse_y: f32,
) ?usize {
    var i: usize = cmds.len;
    while (i > 0) {
        i -= 1;
        switch (cmds[i]) {
            .button => {
                const rect = rects[i];
                if (mouse_x >= rect.x and mouse_x <= rect.x + rect.w and
                    mouse_y >= rect.y and mouse_y <= rect.y + rect.h)
                {
                    return i;
                }
            },
            else => {},
        }
    }
    return null;
}
```

### Changes to render.zig

The render pass takes TransientState as an additional input:

```zig
fn render_pass(
    cmds: []const Cmd,
    rects: []const Rect,
    transient: TransientState,
    encoder: *wgpu.RenderPassEncoder,
) void {
    for (cmds, rects, 0..) |cmd, rect, i| {
        switch (cmd) {
            .button => |btn| {
                const bg = if (transient.hover_index == i)
                    btn.style.hover_bg
                else
                    btn.style.bg;

                emit_quad(&verts, rect, bg);
            },
            // ...
        }
    }
}
```

### Changes to main loop

```
    // Between input poll and view:

    transient.mouse_x = mouse.x;
    transient.mouse_y = mouse.y;
    transient.hover_index = hover_test(last_cmds, last_rects, mouse.x, mouse.y);

    // hover_test runs every frame (mouse move)
    // but NO Msg is emitted
    // update() is NOT called
    // view() is NOT called (model hasn't changed)
    // only render() re-runs with new transient state
```

```
    THE SHORT CIRCUIT
    ═════════════════

    Mouse moves, no click:

    ┌─────────┐              ┌────────────┐
    │  mouse  │─────────────▶│ hover_test │
    └─────────┘              └─────┬──────┘
                                   │ ?usize
                                   ▼
                             ┌───────────┐
                             │ transient │
                             │   state   │
                             └─────┬─────┘
                                   │
                    ┌──────────────┘
                    ▼
              ┌──────────┐
              │  render  │──────▶ pixels (button color changed)
              └──────────┘

    Skipped: update, view, layout.
    Cost: one hit-test scan + one render.
    No Msg. No Model mutation. No command buffer rebuild.
```

**Checkpoint:** move mouse over a button, it lights up. Move away, it returns to normal. Click still works. The TEA loop and the transient state path coexist without interfering.

---

## What You Should Have When Done

```
    ┌──────────────────────────────────────────────────────┐
    │                                                      │
    │  ✓ Model + Msg + update (pure TEA)                   │
    │  ✓ CmdBuffer with arena allocator                    │
    │  ✓ view() emitting flat []Cmd                        │
    │  ✓ Two-pass layout producing []Rect                  │
    │  ✓ Hit-test mapping mouse → Msg                      │
    │  ✓ wgpu render pass drawing colored quads             │
    │  ✓ Closed loop: click → update → view → render       │
    │  ✓ TransientState for hover (stretch)                │
    │                                                      │
    │  Total: ~8 files, ~400-600 lines of Zig              │
    │                                                      │
    │  What you DON'T have yet:                            │
    │  ✗ Real text rendering (just colored rects)          │
    │  ✗ Flex layout                                       │
    │  ✗ Comptime component composition                    │
    │  ✗ Arena double-buffering / diffing                  │
    │  ✗ Animations                                        │
    │  ✗ Text input                                        │
    │  ✗ Scrolling                                         │
    │  ✗ Any widget beyond button and text                 │
    │                                                      │
    │  And that's fine. Every layer of the architecture     │
    │  is proven. Everything else is additive.             │
    └──────────────────────────────────────────────────────┘
```

---

## Order of Operations

Do them in this order. Don't skip ahead.

```
    Phase 1 ──▶ Phase 2 ──▶ Phase 3 ──▶ Phase 4 ──▶ Phase 5 ──▶ Phase 6
    Model       CmdBuffer    Layout      Render      Hit-test    Close
    Msg         Cmd union    measure     wgpu        mouse→Msg   the
    update      view()       position    quads                   loop
    
    5 min       30 min       1-2 hrs     2-4 hrs     30 min      30 min
    
    ─────────── no wgpu needed ─────────┤
                                        │
                            test in terminal up to here
                            (print cmds, print rects)


    Stretch: TransientState + hover ──▶ 1 hr after Phase 6
```

Phase 3 is where you'll spend the most thinking time — getting the stack-based measure pass right requires care. Phase 4 is where you'll spend the most *typing* time — wgpu boilerplate is verbose but mechanical.

**The rule:** each phase has a checkpoint. Don't move to the next phase until the checkpoint passes. If a phase is taking longer than expected, you're overcomplicating it. Strip it back to the minimum that proves the concept.

---

*When this prototype works, come back to the spec docs. The next steps will be obvious: real text, horizontal layout, more widgets. But the architecture will already be proven.*
