# Teak: Second Prototype

Goal: a multi-component application with text input, flex layout, and comptime composition. Two independent components — a counter and a text greeter — composed at comptime into one app. The full component lifecycle: comptime validates, generates routing, and the composed app runs with both components side-by-side.

Stretch goal: press-highlight and focus tracking via TransientState, proving the escape hatch scales beyond hover.

---

## What We're Building

```
    ┌──────────────────────────────────────────────┐
    │                                              │
    │  ┌──────────────┐  ┌──────────────────────┐  │
    │  │   Counter     │  │   Greeter            │  │
    │  │              │  │                      │  │
    │  │  Count: 7    │  │  Name: [Isaac     ]  │  │
    │  │              │  │                      │  │
    │  │  [ + ] [ - ] │  │  Hello, Isaac!       │  │
    │  │              │  │                      │  │
    │  │  [ Reset ]   │  │                      │  │
    │  └──────────────┘  └──────────────────────┘  │
    │                                              │
    └──────────────────────────────────────────────┘

    Counter: same as prototype 1.
    Greeter: type a name, see a greeting.
    They share a window but have independent state and messages.
    Comptime stitches them together.
```

---

## What We're Validating

Prototype 1 proved the core loop. Prototype 2 proves the framework **scales**:

| Claim from spec | How we test it |
|---|---|
| Comptime component composition generates routing | Two components, one app, zero manual routing |
| `validateComponent` produces clear compile errors | Intentionally break a component, verify the error names the component and problem |
| Text input state lives in Model (no hidden widget state) | Cursor position, text buffer — all explicit Model fields |
| Adding a widget = variant + cases + convenience method | Add `text_input` to Cmd union, implement in each pass |
| Flex layout distributes remaining space | Counter and greeter split the window proportionally |
| Arena double-buffering enables frame diffing | Two arenas alternate, only re-render on diff |
| TransientState scales to press + focus | Press-highlight on mouse-down, focus ring on active input |

---

## Project Structure Changes

```
src/
  main.zig           -- (existing) CLI demo
  ui_main.zig        -- (existing) Win32 + wgpu app, updated for composition
  root.zig           -- (existing) public API root, updated exports
  cmd.zig            -- (existing) add text_input variant
  layout.zig         -- (existing) add flex proportions + text_input sizing
  hit_test.zig       -- (existing) add text_input focus handling
  render.zig         -- (existing) add text_input rendering + focus ring
  transient.zig      -- (existing) add press_index, focus_index tracking
  compose.zig        -- NEW: Components(), validateComponent, comptime routing
  counter.zig        -- NEW: Counter component (extracted from model.zig)
  greeter.zig        -- NEW: Greeter component (text input + greeting)
  app.zig            -- NEW: composed app = Components(.{ .counter, .greeter })
```

`model.zig` is retired. Its contents split into `counter.zig` (the counter component) and `app.zig` (the composed application). This is the natural evolution — the monolithic Model/Msg/update becomes composed components.

---

## Phase 1: Comptime Component Composition

This is the highest-risk item. If Zig's comptime can't generate the composed types cleanly, the composition story falls apart.

### compose.zig

The `Components` function takes a tuple of component types and an optional app-level type, and produces a composed application type with generated `Model`, `Msg`, `update`, and `view`.

```zig
pub fn Components(comptime components: anytype, comptime AppLevel: ?type) type {
    // 1. Validate every component
    inline for (std.meta.fields(@TypeOf(components))) |field| {
        validateComponent(@field(components, field.name));
    }

    return struct {
        // 2. Generate composed Model
        //    One field per component's Model, plus app-level fields
        pub const Model = GenerateModel(components, AppLevel);

        // 3. Generate composed Msg
        //    One variant per component wrapping its Msg, plus app-level variants
        pub const Msg = GenerateMsg(components, AppLevel);

        // 4. Generate routing update
        pub fn update(model: *Model, msg: Msg) void {
            // switch on msg, route to correct component's update
        }

        // 5. Generate composed view
        pub fn view(model: Model, cmd: *CmdBuffer) void {
            // call each component's view in sequence
        }
    };
}
```

### validateComponent

Before any type generation, validate shape and produce human-readable errors:

```zig
fn validateComponent(comptime T: type) void {
    if (!@hasDecl(T, "Model"))
        @compileError("Component '" ++ @typeName(T) ++ "' is missing a 'Model' type");
    if (!@hasDecl(T, "Msg"))
        @compileError("Component '" ++ @typeName(T) ++ "' is missing a 'Msg' type");
    if (@typeInfo(T.Msg) != .@"union")
        @compileError("Component '" ++ @typeName(T) ++ "'.Msg must be a union(enum)");
    if (!@hasDecl(T, "update"))
        @compileError("Component '" ++ @typeName(T) ++ "' is missing an 'update' function");
    if (!@hasDecl(T, "view"))
        @compileError("Component '" ++ @typeName(T) ++ "' is missing a 'view' function");
    // Validate function signatures...
}
```

### The Hard Part: Msg Routing Through CmdBuffer

The command buffer currently embeds `Msg` directly in `ButtonCmd`. In a composed app, `counter.zig` emits buttons with `Counter.Msg` and `greeter.zig` emits buttons with `Greeter.Msg`. But the `CmdBuffer` needs a single `Msg` type.

Two options:

**Option A — Generic CmdBuffer.** `CmdBuffer` becomes `CmdBuffer(AppMsg)` where `AppMsg` is the composed type. Components call `cmd.button(.{ .counter = .increment }, "+")`. This is explicit but leaks the composed type into component code.

**Option B — Comptime view wrapper.** Each component's `view` emits commands with its own `Msg` type. The composed `view` wraps each component's commands, rewriting `Msg` values to the composed `AppMsg`. This keeps components ignorant of composition.

**Decision:** Start with Option A. It's simpler, explicit, and Zig-idiomatic. Components know they're being composed — that's not a secret worth hiding. If this feels wrong in practice, Option B is available.

**Checkpoint:** define `Counter` and `Greeter` as component types. `Components(.{ .counter = Counter, .greeter = Greeter }, null)` compiles and produces a type with `Model`, `Msg`, `update`. Write tests that create the composed `Model`, send component-scoped messages, and verify state changes route correctly. Intentionally break a component (remove its `Msg` type), verify the compile error names the component.

---

## Phase 2: Text Input Widget

This is the first widget with internal state that the user manages. It validates the spec's claim that "stateful widgets are solved, not hidden."

### The Greeter Component

```zig
pub const Greeter = struct {
    pub const Model = struct {
        name: [64]u8 = [_]u8{0} ** 64,
        name_len: usize = 0,
        cursor: usize = 0,
    };

    pub const Msg = union(enum) {
        name_char: u8,
        name_backspace,
        name_cursor_left,
        name_cursor_right,
    };

    pub fn update(model: *Model, msg: Msg) void {
        switch (msg) {
            .name_char => |c| {
                if (model.name_len < 63) {
                    // insert at cursor
                    std.mem.copyBackwards(u8,
                        model.name[model.cursor + 1 .. model.name_len + 1],
                        model.name[model.cursor .. model.name_len],
                    );
                    model.name[model.cursor] = c;
                    model.name_len += 1;
                    model.cursor += 1;
                }
            },
            .name_backspace => {
                if (model.cursor > 0) {
                    std.mem.copyForwards(u8,
                        model.name[model.cursor - 1 .. model.name_len - 1],
                        model.name[model.cursor .. model.name_len],
                    );
                    model.name_len -= 1;
                    model.cursor -= 1;
                }
            },
            .name_cursor_left => {
                if (model.cursor > 0) model.cursor -= 1;
            },
            .name_cursor_right => {
                if (model.cursor < model.name_len) model.cursor += 1;
            },
        }
    }

    pub fn view(model: Model, cmd: *CmdBuffer) void {
        cmd.pushGroup(.{ .direction = .vertical, .padding = 16, .gap = 8 });

        const name_slice = model.name[0..model.name_len];
        cmd.textInput(.name_char, name_slice, model.cursor);

        const greeting = std.fmt.allocPrint(
            cmd.arena.allocator(),
            "Hello, {s}!",
            .{if (model.name_len > 0) name_slice else "World"},
        ) catch unreachable;
        cmd.text(greeting);

        cmd.popGroup();
    }
};
```

All text input state — the buffer, the length, the cursor position — lives in the Model. Nothing is hidden. Undo/redo would replay the `Msg` history. Serialization captures the full input state.

### Changes to cmd.zig

Add `text_input` to the `Cmd` union:

```zig
const TextInputCmd = struct {
    msg: Msg,           // base message for character input
    content: []const u8,
    cursor: usize,
    style: TextInputStyle,
};

const TextInputStyle = struct {
    bg: [4]f32 = .{ 0.15, 0.15, 0.15, 1.0 },
    fg: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    border: [4]f32 = .{ 0.4, 0.4, 0.4, 1.0 },
    focus_border: [4]f32 = .{ 0.3, 0.5, 1.0, 1.0 },
    corner_radius: f32 = 4,
};

const Cmd = union(enum) {
    push_group: GroupStyle,
    pop_group,
    text: TextCmd,
    button: ButtonCmd,
    text_input: TextInputCmd,   // <-- new
};
```

Add a convenience emitter on `CmdBuffer`:

```zig
fn textInput(self: *CmdBuffer, msg: Msg, content: []const u8, cursor: usize) void {
    self.cmds.append(.{ .text_input = .{
        .msg = msg,
        .content = content,
        .cursor = cursor,
    } }) catch unreachable;
}
```

This is exactly the pattern the spec predicts: one new variant, one case in each pass, one convenience method.

**Checkpoint:** Greeter component compiles. Write a test: send `.name_char = 'A'`, `.name_char = 'B'`, `.name_backspace`. Verify `model.name[0..model.name_len]` is `"A"` and `model.cursor` is `1`. Call `view`, verify the command buffer contains a `text_input` command with the correct content.

---

## Phase 3: Flex Layout

The layout pass currently uses fixed sizes. Flex layout lets children declare proportional sizes relative to remaining space.

### Changes to cmd.zig

Add a `flex` field to `GroupStyle`:

```zig
const GroupStyle = struct {
    direction: Direction = .vertical,
    padding: f32 = 8,
    gap: f32 = 8,
    flex: f32 = 0,      // 0 = intrinsic size, >0 = proportional weight
};
```

Leaf widgets can also carry flex:

```zig
const TextInputStyle = struct {
    // ... existing fields
    flex: f32 = 1,  // text inputs expand by default
};
```

### Changes to layout.zig

The measure pass gains a two-sub-pass structure for groups containing flex children:

```
    MEASURE WITH FLEX
    ═════════════════

    pop_group hits. The group has 3 children: [fixed:60, flex:1, flex:2]

    1. Sum fixed children: fixed_total = 60
    2. Sum flex weights:   flex_total  = 3
    3. Remaining space:    remaining   = parent_available - fixed_total - gaps - padding
    4. Distribute:         flex:1 gets remaining * (1/3)
                           flex:2 gets remaining * (2/3)

    Still O(n) — each command visited a constant number of times.
    GroupContext gains: fixed_total, flex_total fields.
```

The key insight: flex resolution happens at `pop_group` time. The stack already tracks all children's sizes. We just need to distinguish fixed children from flex children and do the proportional split.

```zig
const GroupContext = struct {
    cmd_index: usize,
    direction: Direction,
    padding: f32,
    gap: f32,

    // existing
    main_axis_total: f32 = 0,
    cross_axis_max: f32 = 0,
    child_count: u32 = 0,

    // new: flex tracking
    fixed_total: f32 = 0,
    flex_total: f32 = 0,
    available: f32 = 0,       // set by parent or window size
};
```

### The Composed Layout

The app's view arranges the two components side-by-side:

```zig
fn view(model: Model, cmd: *CmdBuffer) void {
    cmd.pushGroup(.{ .direction = .horizontal, .padding = 16, .gap = 16 });

    // Counter takes intrinsic width
    cmd.pushGroup(.{ .direction = .vertical, .padding = 16, .gap = 8 });
    Counter.view(model.counter, cmd);
    cmd.popGroup();

    // Greeter takes remaining space (flex)
    cmd.pushGroup(.{ .direction = .vertical, .padding = 16, .gap = 8, .flex = 1 });
    Greeter.view(model.greeter, cmd);
    cmd.popGroup();

    cmd.popGroup();
}
```

**Checkpoint:** with a 800px window, the counter panel should take its intrinsic width (~180px) and the greeter panel should fill the remaining ~600px. Resize the window. The greeter panel should grow/shrink while the counter stays fixed. Verify by printing rects and checking the math by hand.

---

## Phase 4: Text Input in Each Pass

The text input widget needs handling in layout, hit-test, and render.

### Layout

```
    text_input → size = (flex or MIN_INPUT_WIDTH, INPUT_HEIGHT)
                 add to stack.top accumulator
                 write size to rects[i]
```

If the text input has `flex > 0` and is inside a group, its width is resolved during the flex distribution at `pop_group` time.

### Hit-Test

Text input hit-test does two things:

1. **Click inside the input** — sets focus (via TransientState) to this command index.
2. **Click position within the input** — could set cursor position (stretch).

For now, clicking a text input sets focus. Keyboard events route to the focused text input.

```zig
.text_input => |input| {
    if (rectContains(rect, mouse_x, mouse_y)) {
        return .{ .index = i, .msg = input.msg };
    }
},
```

Focus management needs a decision: does clicking a text input produce a `Msg` (goes through `update`) or just set `TransientState.focus_index` (presentation only)?

**Decision:** Focus is application state. Clicking a text input produces a focus `Msg`. Keyboard input routes based on `Model.focused_field`, not `TransientState.focus_index`. TransientState only controls the visual focus ring. This keeps the boundary clean — the Model knows which field is active, TransientState knows how to draw it.

### Render

```
    text_input → draw background rect
                 draw border (or focus border if focused)
                 draw text content as placeholder rect (same as buttons for now)
                 draw cursor line at cursor position (thin rect)
```

The cursor is a thin vertical rectangle at `x = rect.x + padding + cursor * CHAR_WIDTH`.

**Checkpoint:** text input appears on screen. Clicking it gives it a focus ring. Typing characters updates the text (via Msg routing through the composed app). The greeting text updates reactively. The cursor position is visible and moves correctly.

---

## Phase 5: Arena Double-Buffering

The spec promises two arenas alternating each frame, enabling linear-scan diffing. Prototype 1 used one arena with full reset. Time to prove the optimization.

### The Double-Buffer

```zig
const FrameBuffers = struct {
    arenas: [2]std.heap.ArenaAllocator,
    cmd_bufs: [2]CmdBuffer,
    rects: [2][]Rect,
    current: u1 = 0,

    fn swap(self: *FrameBuffers) void {
        self.current ^= 1;
    }

    fn currentBuf(self: *FrameBuffers) *CmdBuffer {
        return &self.cmd_bufs[self.current];
    }

    fn previousBuf(self: *FrameBuffers) *CmdBuffer {
        return &self.cmd_bufs[self.current ^ 1];
    }
};
```

### Diffing

After building the current frame's commands and rects, diff against the previous frame:

```
    DIFF STRATEGY
    ═════════════

    Walk both []Cmd arrays in parallel.
    If lengths differ → full re-render.
    If any (cmd, rect) pair differs → mark dirty.

    For the prototype: if ANY command differs, re-render everything.
    This still validates the double-buffer mechanism.

    Future optimization: dirty-rect tracking, partial vertex buffer updates.
```

The diff is a linear scan — compare tags and payloads. Arena-allocated strings compare by content, not pointer (pointers differ between arenas). This is O(n) where n is the command count.

### Skip Optimization

If the diff finds zero changes (model didn't change, window didn't resize), skip `buildVertices` and `render_pass` entirely. Resubmit the previous frame's vertex buffer. This is the first real performance win from the architecture.

**Checkpoint:** add a frame counter or log. With the mouse still and no clicks, verify that after the first frame, `buildVertices` is not called again. Click a button, verify it runs once for the changed frame, then stops again. The diff is working.

---

## Phase 6: Keyboard Input Pipeline

Prototype 1 only handled mouse clicks. Text input requires keyboard events flowing through the system.

### Input Events

```zig
const InputEvent = union(enum) {
    mouse_click: struct { x: f32, y: f32 },
    mouse_move: struct { x: f32, y: f32 },
    key_char: u8,
    key_down: Key,
    window_resize: struct { w: u32, h: u32 },
};

const Key = enum {
    backspace,
    delete,
    left,
    right,
    home,
    end,
    tab,
    enter,
    escape,
};
```

### Routing

Keyboard events route based on application focus state (in the Model, not TransientState):

```
    KEYBOARD ROUTING
    ════════════════

    key_char 'A'
        │
        ▼
    Is there a focused text input? (check Model)
        │ yes
        ▼
    Produce Msg for that input: .{ .greeter = .{ .name_char = 'A' } }
        │
        ▼
    update() routes to Greeter.update()
        │
        ▼
    Model.greeter.name updated, cursor advanced
        │
        ▼
    Next frame: view() emits text_input with new content
```

### Win32 Integration

`ui_main.zig` gains `WM_CHAR` and `WM_KEYDOWN` handling in the window procedure:

```
    WM_CHAR     → InputEvent{ .key_char = wParam }
    WM_KEYDOWN  → InputEvent{ .key_down = translateKey(wParam) }
    WM_LBUTTONDOWN → InputEvent{ .mouse_click = .{ ... } }
    WM_MOUSEMOVE   → InputEvent{ .mouse_move = .{ ... } }
```

**Checkpoint:** click the text input. Type "Hello". See the characters appear. Press backspace. See a character removed. Press left/right arrows. See the cursor move. The full keyboard pipeline works.

---

## Phase 7: Close the Composed Loop

Wire everything together. The composed app runs in the main loop with both components interactive.

### The Updated Main Loop

```
    model = App.Model{};
    frames = FrameBuffers.init(allocator);

    loop {
        // 1. Poll input events
        events = poll_events();

        for (events) |event| {
            switch (event) {
                .mouse_click => |pos| {
                    if (hit_test(prev_cmds, prev_rects, pos.x, pos.y)) |hit| {
                        App.update(&model, hit.msg);
                    }
                },
                .key_char => |c| {
                    if (model.focused_input) |focus_msg| {
                        App.update(&model, focus_msg.withChar(c));
                    }
                },
                .mouse_move => |pos| {
                    transient.hover_index = hover_test(prev_cmds, prev_rects, pos.x, pos.y);
                },
                // ...
            }
        }

        // 2. Rebuild current frame
        frames.swap();
        buf = frames.currentBuf();
        buf.reset();
        App.view(model, buf);

        // 3. Layout
        doLayout(buf.cmds.items, rects, window_size);

        // 4. Diff against previous frame
        if (changed(buf, frames.previousBuf())) {
            vertices = buildVertices(buf.cmds.items, rects, transient);
            uploadVertices(vertices);
        }

        // 5. Render + present
        render(encoder);
        surface.present();
    }
```

**Checkpoint:** both components work independently. Click the counter buttons — count changes. Click the text input — it gains focus. Type a name — greeting updates. Resize the window — flex layout adjusts. The composed application behaves as if it were hand-written.

---

## Stretch Goal: Press-Highlight and Focus Ring

Extend TransientState to handle press (mouse-down) and focus visuals.

### transient.zig updates

```zig
const TransientState = struct {
    hover_index: ?usize = null,
    press_index: ?usize = null,   // mouse button held down on this widget
    focus_index: ?usize = null,   // visual focus ring (mirrors Model's focus)
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
};
```

### Behavior

```
    PRESS STATE
    ═══════════

    mouse_down on button at index 5:
        transient.press_index = 5
        render uses btn.style.press_bg (darker)

    mouse_up:
        if still over index 5 → emit click Msg
        transient.press_index = null

    mouse_drag off button:
        transient.press_index = null (cancel)
        no Msg emitted


    FOCUS RING
    ══════════

    click text_input at index 8:
        Model.focused_field = .greeter_name (application state)
        transient.focus_index = 8 (visual state)

    render sees focus_index == 8:
        draw focus_border color instead of border color
        draw blinking cursor (blink driven by frame counter in TransientState)
```

**Checkpoint:** press and hold a button — it shows the press color. Release — it clicks. Drag off — it cancels. The text input has a visible focus ring. The cursor blinks. All of this works without any `Msg` for hover/press — only the click and focus changes produce messages.

---

## What You Should Have When Done

```
    ┌──────────────────────────────────────────────────────┐
    │                                                      │
    │  ✓ Comptime component composition (compose.zig)      │
    │  ✓ validateComponent with clear compile errors       │
    │  ✓ Two components composed into one app              │
    │  ✓ Text input widget (all state in Model)            │
    │  ✓ Flex layout (proportional space distribution)     │
    │  ✓ Arena double-buffering with frame diffing         │
    │  ✓ Keyboard input pipeline (char + special keys)     │
    │  ✓ Full composed loop: counter + greeter interactive │
    │  ✓ Press-highlight + focus ring (stretch)            │
    │                                                      │
    │  What you STILL don't have:                          │
    │  ✗ Real text rendering (still colored rects)         │
    │  ✗ Scrolling                                         │
    │  ✗ Animations beyond hover/press                     │
    │  ✗ Cross-platform (still Win32 only)                 │
    │  ✗ Undo/redo (architecture supports it, untested)    │
    │  ✗ Component-to-component communication              │
    │  ✗ Any complex widget (dropdown, list, tree)         │
    │                                                      │
    │  And that's fine. The framework's scaling story       │
    │  is proven. Composition works. Widgets work.         │
    │  Everything else is more of the same.                │
    └──────────────────────────────────────────────────────┘
```

---

## Order of Operations

```
    Phase 1 ──▶ Phase 2 ──▶ Phase 3 ──▶ Phase 4 ──▶ Phase 5 ──▶ Phase 6 ──▶ Phase 7
    Comptime    Text        Flex        Input       Arena       Keyboard    Close
    compose     input       layout      in each     double-     pipeline    the
    + validate  widget      pass        buf                     composed
                                                                loop

    HIGH RISK ──────────────┤           ├── MEDIUM RISK ────────┤
    (comptime + generics)               (optimization + input)
                            ├── LOW RISK (mechanical extension) ─┤

    Stretch: Press-highlight + focus ring ──▶ after Phase 7
```

Phase 1 is the riskiest — comptime type generation with tagged unions is unexplored territory. If it works, the rest is mechanical extension of patterns proven in prototype 1.

Phase 3 (flex) is conceptually simple but the measure pass changes require care. Get the math right on paper before writing code.

Phase 5 (double-buffering) is an optimization. If it blocks progress, skip it and come back — the app works fine with single-arena full re-render.

**The rule from prototype 1 still holds:** each phase has a checkpoint. Don't move to the next phase until the checkpoint passes.

---

## Key Design Decisions to Make During Implementation

These are open questions the spec deferred to implementation experience:

1. **Generic CmdBuffer vs. comptime view wrapper.** Starting with generic `CmdBuffer(AppMsg)`. Revisit if component code becomes awkward.

2. **Focus in Model vs. TransientState.** Starting with focus in Model (application state). The visual focus ring mirrors it in TransientState. If this creates unnecessary re-renders, reconsider.

3. **Keyboard routing mechanism.** The composed `update` needs to know which component should receive keyboard input. This is driven by which field is focused in the Model. The routing needs to be clean — if it's ugly, the composition story weakens.

4. **Arena diffing granularity.** Starting with all-or-nothing (any change = full re-render). If this is fast enough, stop there. Dirty-rect tracking is a future optimization.

Document decisions as they're made. Update the spec if anything changes the architecture.

---

*When this prototype works, the framework has proven: pure TEA scales via composition, the command buffer extends cleanly to new widgets, flex layout works over flat buffers, and the double-buffer optimization is real. The next step is real text rendering — the last barrier between prototype and usable toolkit.*
