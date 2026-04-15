# Refinement: Surviving Contact With Reality

Companion to `ui-framework-spec.md` and `ui-framework-diagrams.md`.

This document addresses three architectural friction points identified during design review. Each section names the problem, explains why it matters, describes the solution, and calls out the implementation traps that will bite you if you're not careful.

---

## The Three Walls of Pure TEA

Pure TEA (Model-View-Update) is elegant in theory. Every framework that has adopted it has hit the same three walls. These aren't edge cases — they're fundamental tensions between TEA's purity and the realities of interactive UI.

The goal is not to abandon TEA when it gets hard. The goal is to identify the *precise boundary* where purity costs more than it buys, make a deliberate and bounded exception, and keep everything else pure.

---

## 1. Model Bloat & Component Composition

### The Problem

In pure TEA, all state lives in one Model struct. This is a strength — until your application grows.

Consider a settings panel with 10 text inputs. Each input has its own text buffer, cursor position, and selection range. The Model needs an array of 10 input states. The Msg needs variants like `.input_changed = .{ .index = 3, .text = "hello" }`. Now add a calendar widget, a color picker, and a file browser. Each has its own internal state and message vocabulary. The top-level Model and Msg become enormous.

Elm solves this with `Cmd.map` and nested Model/Msg/update triples. It works, but it's verbose even in Elm. In Zig without closures, manually writing the nesting and routing code for every component would be agonizing.

```
    THE BLOAT PROBLEM
    ═════════════════

    // This is fine at 3 features:

    const Model = struct {
        count: i32,
        name: []const u8,
        dark_mode: bool,
    };

    // This is not fine at 30:

    const Model = struct {
        sidebar: SidebarState,
        editor: EditorState,
        file_browser: FileBrowserState,
        settings: SettingsState,
        color_picker: ColorPickerState,
        calendar: CalendarState,
        toast_notifications: ToastState,
        modal_stack: ModalState,
        search: SearchState,
        ...
    };

    // And the Msg union is WORSE:

    const Msg = union(enum) {
        sidebar_toggle,
        sidebar_resize: f32,
        editor_type: EditorKeyEvent,
        editor_select: SelectionRange,
        editor_scroll: f32,
        file_browser_navigate: []const u8,
        file_browser_select: usize,
        file_browser_confirm,
        settings_change_theme: Theme,
        settings_change_font_size: f32,
        ... // 50 more variants
    };
```

### The Solution: Comptime Component Stitching

Zig's comptime eliminates the manual boilerplate. A component is any type that exposes a specific shape — `Model`, `Msg`, `update`, `view` — and comptime stitches them together.

A component looks like this:

```zig
const Sidebar = struct {
    pub const Model = struct {
        open: bool = true,
        width: f32 = 250,
        selected: ?usize = null,
    };

    pub const Msg = union(enum) {
        toggle,
        resize: f32,
        select: usize,
    };

    pub fn update(model: *Model, msg: Msg) void {
        switch (msg) {
            .toggle => model.open = !model.open,
            .resize => |w| model.width = w,
            .select => |i| model.selected = i,
        }
    }

    pub fn view(model: Model, cmd: *CmdBuffer) void {
        if (!model.open) return;
        cmd.push_group(.{ .layout = .vertical, .width = model.width });
        // ... sidebar contents
        cmd.pop_group();
    }
};
```

The application composes components at comptime:

```zig
const App = Components(.{
    .sidebar = Sidebar,
    .editor = Editor,
    .status_bar = StatusBar,
}, struct {
    // App-level state beyond child components
    file_path: ?[]const u8 = null,

    // App-level messages beyond child components
    pub const Msg = union(enum) {
        open_file: []const u8,
        quit,
    };

    pub fn update(model: *@This(), msg: Msg) void {
        switch (msg) {
            .open_file => |p| model.file_path = p,
            .quit => std.process.exit(0),
        }
    }
});
```

Comptime generates:

```
    WHAT COMPTIME PRODUCES
    ══════════════════════

    Components(.{ .sidebar = Sidebar, .editor = Editor, ... })
        │
        │  @typeInfo introspection at compile time
        ▼

    const AppModel = struct {        ◀── fields from each child's Model
        sidebar: Sidebar.Model,          + app-level fields
        editor: Editor.Model,
        status_bar: StatusBar.Model,
        file_path: ?[]const u8,
    };

    const AppMsg = union(enum) {     ◀── nested child Msgs
        sidebar: Sidebar.Msg,            + app-level Msgs
        editor: Editor.Msg,
        status_bar: StatusBar.Msg,
        open_file: []const u8,
        quit,
    };

    fn app_update(model: *AppModel, msg: AppMsg) void {
        switch (msg) {               ◀── generated routing
            .sidebar    => |m| Sidebar.update(&model.sidebar, m),
            .editor     => |m| Editor.update(&model.editor, m),
            .status_bar => |m| StatusBar.update(&model.status_bar, m),
            .open_file  => |p| App.update(model, .{ .open_file = p }),
            .quit       => App.update(model, .quit),
        }
    }
```

For indexed collections (the "10 text inputs" case), the Msg carries an index:

```zig
const TextInputList = struct {
    pub const Model = struct {
        inputs: std.BoundedArray(TextInputState, 32) = .{},
    };

    pub const Msg = union(enum) {
        changed: struct { index: usize, text: []const u8 },
        cursor_move: struct { index: usize, pos: usize },
        add,
        remove: usize,
    };
};
```

This is more explicit than React's per-component `useState`, but the tradeoff is that the state is serializable, inspectable, and visible to LLMs in one place.

### The Trap: Comptime Error Spew

The danger with comptime component stitching is error messages. If a user makes a typo in a component's update signature, a naive comptime generator will produce a 200-line compiler error pointing at the framework's internal metaprogramming, not at the user's code.

The fix: validate before stitching. Before `Components()` does any type generation, it runs a `validateComponent(T)` function that checks each component's shape and produces human-readable errors:

```zig
fn validateComponent(comptime T: type) void {
    if (!@hasDecl(T, "Model")) {
        @compileError("Component '" ++ @typeName(T) ++ "' is missing a 'Model' type");
    }
    if (!@hasDecl(T, "Msg")) {
        @compileError("Component '" ++ @typeName(T) ++ "' is missing a 'Msg' type");
    }
    if (@typeInfo(T.Msg) != .@"union") {
        @compileError("Component '" ++ @typeName(T) ++ "'.Msg must be a union(enum)");
    }
    if (!@hasDecl(T, "update")) {
        @compileError("Component '" ++ @typeName(T) ++ "' is missing an 'update' function");
    }
    // Validate update signature
    const update_info = @typeInfo(@TypeOf(T.update));
    if (update_info.@"fn".params.len != 2) {
        @compileError("Component '" ++ @typeName(T) ++
            "'.update must take (*Model, Msg)");
    }
}
```

**Rule:** Every comptime error the user can trigger should name the component and the specific problem in plain English. The user should never see raw `@typeInfo` field names or framework internals in an error message.

---

## 2. High-Frequency Transient State

### The Problem

A user moves their mouse over a button. The button should highlight. In pure TEA, this means:

1. The hit-test pass detects the mouse is over button at index 7.
2. A `Msg.hover = 7` is emitted.
3. `update` runs, sets `model.hover_target = 7`.
4. `view` runs, the entire command buffer is rebuilt.
5. The layout pass runs.
6. The render pass draws the button with a different color.

This happens 60+ times per second as the mouse moves. For a hover highlight. The full TEA loop is architecturally wrong here — hover state isn't an application state transition, it's a presentation concern. The Model shouldn't know or care which button the mouse is currently over.

The same applies to press-highlight (mouse down on a button), tooltip delay timers, scroll momentum, and transition animations. These are visual/temporal effects that don't affect application logic.

```
    THE FREQUENCY PROBLEM
    ═════════════════════

    Mouse moves 1 pixel:

    PURE TEA:
    input → Msg → update → Model' → view → []Cmd → layout → render
    ────────────────── FULL PIPELINE ──────────────────────────────
    × 60 per second. For a highlight color change.

    WITH TRANSIENT STATE:
    input → hit_test → hover_index → render (swap color)
    ──────── SHORT CIRCUIT ─────────────────────────────
    No Msg. No update. No view. No layout. Just repaint.
```

### The Solution: Presentation State in the Pass Layer

The render pass owns a small, fixed `TransientState` struct that never touches the Model. The hit-test pass already knows which command index the mouse is over. The render pass uses that information directly.

```zig
const TransientState = struct {
    hover_index: ?CmdIndex = null,
    press_index: ?CmdIndex = null,
    focus_index: ?CmdIndex = null,

    // Animation timers, keyed by command index
    hover_t: [MAX_ANIMATED]f32 = .{0} ** MAX_ANIMATED,
    press_t: [MAX_ANIMATED]f32 = .{0} ** MAX_ANIMATED,
};

fn render_pass(
    cmds: []const Cmd,
    rects: []const Rect,
    transient: TransientState,
    encoder: *wgpu.RenderPassEncoder,
) void {
    for (cmds, rects, 0..) |cmd, rect, i| {
        switch (cmd) {
            .button => |btn| {
                const bg = if (transient.press_index == i)
                    btn.style.press_bg
                else if (transient.hover_index == i)
                    btn.style.hover_bg
                else
                    btn.style.bg;

                draw_rounded_rect(encoder, rect, bg);
                draw_text(encoder, rect, btn.label);
            },
            // ...
        }
    }
}
```

The command structs anticipate this by carrying style variants:

```zig
const ButtonStyle = struct {
    bg: Color = colors.surface,
    hover_bg: Color = colors.surface_hover,
    press_bg: Color = colors.surface_press,
    fg: Color = colors.on_surface,
    corner_radius: f32 = 6,
};

const ButtonCmd = struct {
    msg: Msg,
    label: []const u8,
    style: ButtonStyle = .{},
};
```

The user's view function remains purely declarative — they specify the style, including hover variants, as data. They never write hover logic. The framework handles the high-frequency presentation state internally.

```
    THE BOUNDARY RULE
    ═════════════════

    Ask: "Does this state affect what happens NEXT in the application?"

    YES → It's application state.  → Model.
          Examples: selected item, input text, current page,
                    user preferences, todo list contents.

    NO  → It's presentation state. → TransientState.
          Examples: hover highlight, press animation,
                    scroll momentum, tooltip delay,
                    transition progress.

    The Model is the source of truth for the APPLICATION.
    TransientState is the source of truth for the PRESENTATION.
    They do not overlap. They do not conflict.
```

### The Trap: Scope Creep

The danger is that TransientState becomes a junk drawer. Once you have a place for "state that isn't in the Model," it's tempting to put more and more there. Suddenly you have focus management, drag state, scroll position, and animation timelines all living outside the Model, and you've recreated IMGUI's hidden state cache.

**Rule:** TransientState is bounded by policy. It contains *only* state that meets all three criteria:

1. It is derivable from the current frame's input (mouse position, time delta).
2. It does not affect application logic (no branching in `update` based on it).
3. It resets cleanly if lost (dropping a hover highlight is not a bug).

If a piece of state fails any of these tests, it belongs in the Model. Focus management is a borderline case — it affects tab order and keyboard input routing, which feel like application logic. The conservative choice is to put focus in the Model. The pragmatic choice is to put it in TransientState but expose it to the hit-test pass. This is a decision to defer to implementation experience.

---

## 3. Tree Layout Over a Flat Buffer

### The Problem

The command buffer is a flat array. `push_group` and `pop_group` encode an implicit tree. Layout algorithms (even simple vertical/horizontal stacking) need parent-child relationships: a parent's size depends on its children, and children's positions depend on their parent's final size and layout direction.

This is a fundamental tension: the data structure is flat (good for cache, good for arenas, good for diffing), but the algorithm is hierarchical.

```
    THE STRUCTURE MISMATCH
    ══════════════════════

    What view() emits (flat):

    [push_v] [text] [push_h] [btn] [btn] [pop] [input] [pop]
       0       1       2      3     4     5       6      7

    What layout needs (tree):

         vertical_group (0)
         ├── text (1)
         ├── horizontal_group (2)
         │   ├── button (3)
         │   └── button (4)
         └── text_input (6)
```

### The Solution: Stack-Based Linear Passes

You never build the tree. You process the flat buffer with a stack that tracks the current group context. Two linear passes, each O(n), no heap allocation beyond a fixed-size stack.

**Pass 1 — Measure (bottom-up):** Walk forward through `[]Cmd`. The stack tracks open groups. Leaf widgets report their intrinsic size. When `pop_group` is hit, the group's size is computed from its children's sizes plus gaps and padding.

**Pass 2 — Position (top-down):** Walk forward again. Now that all sizes are known, assign absolute x/y coordinates. The stack tracks the current cursor position within each group. Each child is placed at the cursor, and the cursor advances.

```
    PASS 1: MEASURE (forward scan with stack)
    ══════════════════════════════════════════

    Stack: []                   Rects: [_, _, _, _, _, _, _, _]

    [0] push_v  → stack: [Group{dir=V, children=[]}]
    [1] text    → measure "Hello" → 384×20
                  stack.top.children.add(384×20)
                  rects[1].size = 384×20

    [2] push_h  → stack: [Group{V, ...}, Group{dir=H, children=[]}]
    [3] btn "+" → measure "+" → 60×32
                  stack.top.children.add(60×32)
                  rects[3].size = 60×32
    [4] btn "-" → measure "-" → 60×32
                  stack.top.children.add(60×32)
                  rects[4].size = 60×32
    [5] pop     → finalize H group: width=60+gap+60=128, height=32
                  rects[2].size = 128×32
                  pop stack, add 128×32 to parent's children

    [6] input   → measure → 384×24
                  stack.top.children.add(384×24)
                  rects[6].size = 384×24
    [7] pop     → finalize V group: width=384, height=20+gap+32+gap+24=100
                  rects[0].size = 384×100

    Stack: []    ← balanced (view function was well-formed)


    PASS 2: POSITION (forward scan with stack)
    ═══════════════════════════════════════════

    Stack: []                   Rects updated in-place with x, y

    [0] push_v  → stack: [Cursor{x=pad, y=pad, dir=V}]
                  rects[0].pos = (0, 0)
    [1] text    → rects[1].pos = (pad, pad)
                  cursor.y += 20 + gap

    [2] push_h  → rects[2].pos = (pad, cursor.y)
                  stack: [..., Cursor{x=pad, y=cursor.y, dir=H}]
    [3] btn "+" → rects[3].pos = (pad, cursor.y)
                  cursor.x += 60 + gap
    [4] btn "-" → rects[4].pos = (pad+60+gap, cursor.y)
                  cursor.x += 60 + gap
    [5] pop     → pop H cursor
                  parent cursor.y += 32 + gap

    [6] input   → rects[6].pos = (pad, cursor.y)
                  cursor.y += 24 + gap
    [7] pop     → done
```

Both passes are linear forward scans. No pointer chasing. No tree nodes allocated. The stack is a fixed-size array on the stack frame (`[MAX_DEPTH]GroupContext`) — nesting depth beyond 32-64 levels doesn't occur in real UIs.

The `[]Rect` output array is arena-allocated alongside `[]Cmd`, same lifetime, same bulk-free.

### The Trap: Flex-Style Proportional Layout

Simple stacking (vertical, horizontal, fixed sizes) works cleanly in two passes. But flex-style layout — where a child says "I want 30% of the remaining space" — requires knowing the parent's final size before positioning children, and the parent's final size depends on the fixed-size children.

This is solvable in two passes but the measure pass gets more complex:

1. **Measure pass, first sub-pass:** compute intrinsic sizes for all fixed-size children. Sum them. Subtract from the parent's available space to get "remaining space."
2. **Measure pass, second sub-pass:** distribute remaining space to flex children proportionally.

This is still O(n) overall — each command is visited a constant number of times. The stack just needs to track both the fixed total and the flex total for each open group.

```zig
const GroupContext = struct {
    direction: enum { horizontal, vertical },
    padding: f32,
    gap: f32,

    // Measure state
    fixed_total: f32 = 0,
    flex_total: f32 = 0, // sum of flex weights
    child_count: u32 = 0,

    // Position state (used in pass 2)
    cursor: f32 = 0,
    available: f32 = 0,
};
```

More advanced layout (CSS Grid, constraint-based) would need more passes or a different algorithm entirely. The architecture supports this — the layout pass is a replaceable function `fn([]Cmd, Constraints) []Rect`. You can swap in Cassowary, yoga-layout, or a custom constraint solver without touching the rest of the framework. The command buffer and the render pass don't care how `[]Rect` was produced.

**Rule:** Start with vertical/horizontal stacking and flex proportions. This covers 90% of application UI. Add more sophisticated layout algorithms only when real applications demand them, and add them as alternative layout pass implementations, not as changes to the command buffer or the TEA layer.

---

## Summary of Escape Hatches

Three deliberate deviations from pure TEA, each bounded and justified:

| Problem | Pure TEA says | We do instead | Boundary |
|---|---|---|---|
| Composition | Manually nest Model/Msg/update | Comptime generates nesting and routing | Components must pass `validateComponent` |
| Hover/animation | All state in Model | TransientState in render pass | Only state that is derivable, non-logical, and safely losable |
| Tree layout | N/A (TEA has no opinion on layout) | Stack-based linear passes over flat `[]Cmd` | Fixed-depth stack, two O(n) passes, replaceable pass function |

Each escape hatch has an explicit rule for what does and doesn't belong there. If a piece of state or logic doesn't fit the rule, it goes back into pure TEA. The framework stays honest about where it deviates and why.

---

*These refinements are based on design review and have not yet been validated by implementation. Expect further refinement when code is written.*
