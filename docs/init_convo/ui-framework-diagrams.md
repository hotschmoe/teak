# TEA + Command Buffer: Architecture Diagrams

Visual reference for the framework's internals. Companion to `ui-framework-spec.md`.

---

## 1. The Core Loop

The heartbeat of the application. Every frame follows this cycle.

```
                        ┌──────────────────────────────────────────┐
                        │              APPLICATION                 │
                        │                                          │
                        │   ┌─────────┐    Msg     ┌──────────┐   │
                        │   │         │───────────▶│          │   │
                        │   │  Model  │            │  update  │   │
                        │   │ (state) │◀───────────│  (switch)│   │
                        │   │         │  new Model │          │   │
                        │   └────┬────┘            └──────────┘   │
                        │        │                       ▲         │
                        │        │ read                  │ Msg     │
                        │        ▼                       │         │
                        │   ┌─────────┐            ┌─────┴────┐   │
                        │   │         │  []Cmd     │          │   │
                        │   │  view   │───────────▶│  passes  │   │
                        │   │  (emit) │            │          │   │
                        │   └─────────┘            └──────────┘   │
                        │                                          │
                        └──────────────────────────────────────────┘

    Model is never mutated directly.
    view never mutates anything — it only emits commands.
    passes never mutate the Model — they only read commands and produce output.
    Only update touches the Model, and only in response to a Msg.
```

---

## 2. The Command Buffer Pipeline

What happens between `view()` and pixels on screen.

```
    view(model, &cmds)
            │
            │ emits
            ▼
    ┌───────────────────────────────────────────────────┐
    │                  Command Buffer                   │
    │                                                   │
    │  ┌──────┬──────┬──────┬──────┬──────┬──────┐     │
    │  │push  │ text │button│button│ text │ pop  │ ... │
    │  │group │      │  +   │  -   │input │group │     │
    │  └──────┴──────┴──────┴──────┴──────┴──────┘     │
    │                                                   │
    │  Tagged unions. Flat array. Arena-allocated.       │
    └───────────┬───────────┬───────────┬───────────────┘
                │           │           │
       ┌────────┘     ┌─────┘     ┌─────┘
       ▼              ▼           ▼
  ┌─────────┐   ┌──────────┐  ┌──────────┐
  │ LAYOUT  │   │ HIT-TEST │  │  RENDER  │
  │  pass   │   │   pass   │  │   pass   │
  └────┬────┘   └────┬─────┘  └────┬─────┘
       │              │             │
       ▼              ▼             ▼
    []Rect          ?Msg        wgpu draw
  (positions)    (user input    calls to
                  mapped to      GPU
                  messages)

    Each pass is a pure function: []Cmd in, result out.
    Passes do not communicate except through their inputs.
    Any pass can be skipped, cached, or run in parallel.
```

---

## 3. Command Tagged Union Anatomy

The actual Cmd type. Every command the view can emit.

```
    Cmd = union(enum)
    ┌─────────────────────────────────────────────────────────┐
    │                                                         │
    │  .push_group ──▶ GroupStyle { layout, gap, padding }    │
    │  .pop_group  ──▶ (void)                                 │
    │  .text       ──▶ TextCmd { fmt, args, style }           │
    │  .button     ──▶ ButtonCmd { msg: Msg, label, style }   │
    │  .text_input ──▶ TextInputCmd { msg, value, cursor }    │
    │  .image      ──▶ ImageCmd { handle, size, fit }         │
    │  .spacer     ──▶ f32 (pixels)                           │
    │  .divider    ──▶ DividerStyle { thickness, color }      │
    │  .custom     ──▶ CustomCmd { draw_fn, ctx }             │
    │                                                         │
    └─────────────────────────────────────────────────────────┘

    Adding a new widget = adding a variant here
                        + a case in each pass
                        + a convenience method on CmdBuffer.
```

---

## 4. Arena Double Buffering

How memory works across frames. No per-widget allocation or deallocation.

```
    Frame N                              Frame N+1
    ═══════                              ═════════

    Arena A (active)                     Arena B (active)
    ┌─────────────────────┐              ┌─────────────────────┐
    │ cmd cmd cmd cmd cmd  │              │ cmd cmd cmd cmd cmd  │
    │ cmd cmd cmd cmd      │              │ cmd cmd cmd          │
    │ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │              │ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │
    │     (in use)         │              │     (in use)         │
    │                      │              │                      │
    │ ░░░░░░░░░░░░░░░░░░░ │              │ ░░░░░░░░░░░░░░░░░░░ │
    │     (free space)     │              │     (free space)     │
    └─────────────────────┘              └─────────────────────┘

    Arena B (previous)                   Arena A (previous)
    ┌─────────────────────┐              ┌─────────────────────┐
    │ old old old old old  │  ◀── diff   │ old old old old old  │
    │ old old old          │     against  │ old old old old      │
    │                      │              │                      │
    │  (kept for diffing,  │              │  (bulk freed after   │
    │   freed next frame)  │              │   diff completes)    │
    └─────────────────────┘              └─────────────────────┘

    ┌──────────────────────────────────────────────────────────┐
    │  Diff is a LINEAR SCAN, not a tree walk.                 │
    │                                                          │
    │  Frame N cmds:   [push][text][btn][btn][pop]             │
    │  Frame N+1 cmds: [push][text][btn][btn][pop]             │
    │                    =     =     =    =    =    → no change│
    │                                          → skip render   │
    │                                                          │
    │  Frame N cmds:   [push][text][btn][btn][pop]             │
    │  Frame N+1 cmds: [push][text][btn][btn][btn][pop]        │
    │                    =     =     =    =    ≠    ≠          │
    │                                          → dirty region  │
    └──────────────────────────────────────────────────────────┘
```

---

## 5. Layout Pass Detail

How the layout pass converts flat commands into positioned rectangles.

```
    Input: []Cmd                    Output: []Rect
    ────────────                    ──────────────

    [0] push_group(vertical, gap=8)     [0] { x:0,  y:0,  w:400, h:148 }
    [1] text("Hello!")                  [1] { x:8,  y:8,  w:384, h:20  }
    [2] button("+")                     [2] { x:8,  y:36, w:384, h:32  }
    [3] button("-")                     [3] { x:8,  y:76, w:384, h:32  }
    [4] text_input(name)                [4] { x:8,  y:116,w:384, h:24  }
    [5] pop_group                       [5] (matches [0])


    Layout algorithm (two sub-passes):

    ┌─ MEASURE ──────────────────────────────────────────────┐
    │                                                        │
    │  Walk commands. Each widget reports its preferred size. │
    │  Groups accumulate children's sizes + gaps.            │
    │                                                        │
    │  text("Hello!")     → wants 384 × 20                   │
    │  button("+")        → wants 384 × 32                   │
    │  button("-")        → wants 384 × 32                   │
    │  text_input(name)   → wants 384 × 24                   │
    │                                                        │
    │  vertical group     → wants 384 × (20+32+32+24 + 3×8) │
    │                            = 384 × 132 + padding       │
    └────────────────────────────────────────────────────────┘
                    │
                    ▼
    ┌─ POSITION ─────────────────────────────────────────────┐
    │                                                        │
    │  Walk commands again with constraint (available space). │
    │  Assign x, y, w, h to each command index.              │
    │                                                        │
    │  Cursor starts at (padding, padding).                  │
    │  Each child placed at cursor, cursor advances by       │
    │  child height + gap.                                   │
    │                                                        │
    └────────────────────────────────────────────────────────┘
```

---

## 6. Hit-Test Pass Detail

Mapping mouse/touch input back to Msg values.

```
    Inputs: []Cmd, []Rect, mouse position

    Mouse at (200, 82)
                                        ┌───────────────────┐
    ┌──────────────────────────────┐    │ Walk []Rect:      │
    │          SCREEN              │    │                    │
    │  ┌────────────────────────┐  │    │ [0] group → skip  │
    │  │     "Hello!"           │  │    │ [1] text  → skip  │
    │  │  y: 8..28              │  │    │     (not interactive)
    │  ├────────────────────────┤  │    │ [2] btn+  → miss  │
    │  │     [ + ]              │  │    │     (y: 36..68)    │
    │  │  y: 36..68             │  │    │ [3] btn-  → HIT!  │
    │  ├────────────────────────┤  │    │     (y: 76..108)   │
    │  │     [ - ]  ◀── MOUSE  │  │    │     → return       │
    │  │  y: 76..108  (200,82) │  │    │       .decrement   │
    │  ├────────────────────────┤  │    │                    │
    │  │  [ name input ]        │  │    │ Result: Msg =      │
    │  │  y: 116..140           │  │    │   .decrement       │
    │  └────────────────────────┘  │    └───────────────────┘
    └──────────────────────────────┘

    The hit-test pass reads the Msg variant directly from the
    ButtonCmd. No callback lookup. No ID resolution.
    The command IS the event binding.
```

---

## 7. Render Pass to wgpu

How commands + rects become GPU draw calls.

```
    []Cmd + []Rect
         │
         ▼
    ┌──────────────────────────────────────────────────────┐
    │                    RENDER PASS                       │
    │                                                      │
    │  for each (cmd, rect) pair:                          │
    │                                                      │
    │    .text ──────▶ glyph quads → vertex buffer batch   │
    │    .button ────▶ rounded rect + glyph quads          │
    │    .text_input ▶ rect + glyphs + cursor line         │
    │    .image ─────▶ textured quad                        │
    │    .divider ───▶ thin rect                            │
    │    .group ─────▶ optional background rect             │
    │                                                      │
    └──────────────────────┬───────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────┐
    │                 BATCHING LAYER                       │
    │                                                      │
    │  Sorts draw calls by texture atlas / pipeline state. │
    │  Merges adjacent quads into single draw calls.       │
    │                                                      │
    │  Text glyphs:    1 draw call (shared atlas)          │
    │  Solid rects:    1 draw call (no texture)            │
    │  Images:         1 draw call per unique texture      │
    │                                                      │
    │  Typical frame: 3-5 draw calls total                 │
    └──────────────────────┬───────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────┐
    │              wgpu COMMAND ENCODER                    │
    │                                                      │
    │  encoder.beginRenderPass(...)                        │
    │    encoder.setPipeline(solid_pipeline)                │
    │    encoder.setVertexBuffer(0, rect_verts)            │
    │    encoder.draw(rect_count * 6, 1, 0, 0)            │
    │                                                      │
    │    encoder.setPipeline(text_pipeline)                 │
    │    encoder.setBindGroup(0, atlas_bind_group)         │
    │    encoder.setVertexBuffer(0, glyph_verts)           │
    │    encoder.draw(glyph_count * 6, 1, 0, 0)           │
    │  encoder.endRenderPass()                             │
    │  queue.submit(encoder.finish())                      │
    └──────────────────────────────────────────────────────┘

    Note: the UI command buffer and the wgpu command encoder are
    separate concepts that share the same "record now, execute later"
    philosophy. The UI command buffer feeds INTO the wgpu encoder.
```

---

## 8. TEA State Flow — Concrete Example

Adding a to-do item, traced through the entire cycle.

```
    USER TYPES "buy milk" AND PRESSES ENTER
    ═════════════════════════════════════════

    ┌─ INPUT EVENT ──────────────────────────────────────────┐
    │ keyboard: Enter                                        │
    │ hit-test: text_input widget is focused                 │
    │ Msg generated: .submit_todo                            │
    └────────────────────────┬───────────────────────────────┘
                             │
                             ▼
    ┌─ UPDATE ───────────────────────────────────────────────┐
    │                                                        │
    │  fn update(model: *Model, msg: Msg) void {             │
    │      switch (msg) {                                    │
    │          .submit_todo => {                              │
    │              model.todos.append(.{                      │
    │                  .text = model.input_text,              │
    │                  .done = false,                         │
    │              });                                        │
    │              model.input_text = "";                     │
    │              model.input_cursor = 0;                    │
    │          },                                             │
    │          ...                                            │
    │      }                                                  │
    │  }                                                      │
    │                                                        │
    │  Model BEFORE:                 Model AFTER:            │
    │  ┌──────────────────┐          ┌──────────────────┐    │
    │  │ input: "buy milk"│          │ input: ""        │    │
    │  │ cursor: 8        │          │ cursor: 0        │    │
    │  │ todos: [         │          │ todos: [         │    │
    │  │   "walk dog" ✓   │          │   "walk dog" ✓   │    │
    │  │   "read book" ✗  │          │   "read book" ✗  │    │
    │  │ ]                │          │   "buy milk" ✗   │    │
    │  └──────────────────┘          │ ]                │    │
    │                                └──────────────────┘    │
    └────────────────────────┬───────────────────────────────┘
                             │
                             ▼
    ┌─ VIEW (next frame) ───────────────────────────────────┐
    │                                                        │
    │  cmd.push_group(.vertical)                             │
    │  cmd.text("To-Do List")                                │
    │  for (model.todos) |todo| {                            │
    │      cmd.checkbox(.{ .toggle = todo.id }, todo.done)   │
    │      cmd.text(todo.text)                               │
    │  }                                                      │
    │  cmd.text_input(.edit_input, model.input_text, .{})    │
    │  cmd.pop_group()                                       │
    │                                                        │
    │  Command buffer now has ONE MORE entry than last frame. │
    │  Diff detects the change. Render pass runs.            │
    └────────────────────────────────────────────────────────┘
```

---

## 9. Comptime Code Generation

How comptime inspects types and generates framework code.

```
    YOUR CODE                           COMPTIME GENERATES
    ═════════                           ══════════════════

    const Model = struct {          ┌──▶  const Msg = union(enum) {
        count: i32 = 0,             │        set_count: i32,
        name: []const u8 = "",      │        set_name: []const u8,
        speed: f32 = 1.0,           │        set_speed: f32,
        debug: bool = false,        │        toggle_debug,
    };                              │    };
                                    │
    // annotate with:               │
    comptime {                      │
        Msg = GenMsgs(Model); ──────┘

        Inspector = GenInspector(Model);
              │
              │
              ▼

    // GenInspector produces a view function:

    fn auto_inspector(model: Model, cmd: *CmdBuffer) void {
        cmd.push_group(.{ .layout = .vertical });
        //
        // for every field in Model, at comptime:
        //
        // i32    → cmd.slider("count", model.count, ...)
        // []u8   → cmd.text_input("name", model.name, ...)
        // f32    → cmd.slider("speed", model.speed, ...)
        // bool   → cmd.checkbox("debug", model.debug)
        //
        cmd.pop_group();
    }

    // GenSerializer produces:

    fn serialize(model: Model, writer: anytype) !void {
        // walks fields at comptime, emits write calls
    }

    fn deserialize(reader: anytype) !Model {
        // walks fields at comptime, emits read calls
    }
    }

    ┌──────────────────────────────────────────────────────┐
    │  COMPTIME FIELD INSPECTION                           │
    │                                                      │
    │  @typeInfo(Model).@"struct".fields →                 │
    │                                                      │
    │    [0] .name = "count",  .type = i32                 │
    │    [1] .name = "name",   .type = []const u8          │
    │    [2] .name = "speed",  .type = f32                 │
    │    [3] .name = "debug",  .type = bool                │
    │                                                      │
    │  Each type maps to a widget:                         │
    │    i32, f32    → slider                              │
    │    bool        → checkbox                            │
    │    []const u8  → text_input                          │
    │    enum        → dropdown                            │
    │    struct      → recurse (nested group)              │
    │    ?T          → optional toggle + recurse           │
    └──────────────────────────────────────────────────────┘
```

---

## 10. Undo / Redo via Msg Log

Time-travel debugging falls out of TEA for free.

```
    ┌──────────────────────────────────────────────────────┐
    │                    MSG HISTORY                        │
    │                                                      │
    │  [0]  .set_name("hello")                             │
    │  [1]  .increment                                     │
    │  [2]  .increment                                     │
    │  [3]  .set_speed(2.5)                                │
    │  [4]  .increment           ◀── current position      │
    │  [5]  .decrement           ◀── undone (grayed out)   │
    │  [6]  .toggle_debug        ◀── undone                │
    │                                                      │
    └──────────────────────────────────────────────────────┘

    UNDO: move pointer back to [3], replay [0]..[3] from initial Model
    REDO: move pointer forward to [5], replay [0]..[5]

    ┌──────────────────────────────────────────────────────┐
    │  REPLAY                                              │
    │                                                      │
    │  model = Model{};        // initial state            │
    │  for (history[0..ptr]) |msg| {                       │
    │      update(&model, msg);                            │
    │  }                                                   │
    │  // model is now at the desired point in time        │
    │                                                      │
    │  Cost: O(n) per undo. For large histories, snapshot  │
    │  the Model every K steps and replay from there.      │
    │                                                      │
    │  ┌─────┐     ┌─────┐     ┌─────┐     ┌─────┐       │
    │  │snap │────▶│ msg │────▶│ msg │────▶│ msg │ ...    │
    │  │  0  │     │  1  │     │  2  │     │  3  │        │
    │  └─────┘     └─────┘     └─────┘     └─────┘       │
    │  ▲                                                   │
    │  └── replay from nearest snapshot                    │
    └──────────────────────────────────────────────────────┘
```

---

## 11. Component Composition

How larger UIs compose from smaller Model/Msg/view triples.

```
    ┌─ App ─────────────────────────────────────────────────────┐
    │                                                           │
    │  const AppModel = struct {                                │
    │      sidebar: Sidebar.Model,                              │
    │      editor: Editor.Model,                                │
    │      status_bar: StatusBar.Model,                         │
    │  };                                                       │
    │                                                           │
    │  const AppMsg = union(enum) {                             │
    │      sidebar: Sidebar.Msg,                                │
    │      editor: Editor.Msg,                                  │
    │      status_bar: StatusBar.Msg,                           │
    │      // app-level messages:                               │
    │      open_file: []const u8,                               │
    │      quit,                                                │
    │  };                                                       │
    │                                                           │
    │  ┌─────────────────────────────────────────────────────┐  │
    │  │                    SCREEN                           │  │
    │  │  ┌──────────┐  ┌────────────────────────────────┐  │  │
    │  │  │          │  │                                │  │  │
    │  │  │ Sidebar  │  │           Editor               │  │  │
    │  │  │          │  │                                │  │  │
    │  │  │ .Model   │  │           .Model               │  │  │
    │  │  │ .Msg     │  │           .Msg                 │  │  │
    │  │  │ .view()  │  │           .view()              │  │  │
    │  │  │ .update()│  │           .update()            │  │  │
    │  │  │          │  │                                │  │  │
    │  │  └──────────┘  └────────────────────────────────┘  │  │
    │  │  ┌───────────────────────────────────────────────┐  │  │
    │  │  │              StatusBar                        │  │  │
    │  │  │  .Model   .Msg   .view()   .update()         │  │  │
    │  │  └───────────────────────────────────────────────┘  │  │
    │  └─────────────────────────────────────────────────────┘  │
    │                                                           │
    │  fn app_update(model: *AppModel, msg: AppMsg) void {     │
    │      switch (msg) {                                       │
    │          .sidebar   => |m| Sidebar.update(&model.sidebar, m),
    │          .editor    => |m| Editor.update(&model.editor, m),
    │          .status_bar=> |m| StatusBar.update(&model.status_bar, m),
    │          .open_file => |f| { ... },                       │
    │          .quit      => { ... },                           │
    │      }                                                    │
    │  }                                                        │
    │                                                           │
    │  Message routing is JUST TAGGED UNION NESTING.            │
    │  No event bus. No pub/sub. No string keys.                │
    │  Compiler enforces exhaustive handling at every level.    │
    └───────────────────────────────────────────────────────────┘
```

---

## 12. Data Flow — No Hidden State

Comparison: where state lives in each paradigm.

```
    RETAINED MODE (Qt, GTK)          THIS FRAMEWORK
    ═══════════════════════          ══════════════

    ┌──────────────┐                 ┌──────────────┐
    │  App State   │                 │    Model     │
    │  (your code) │                 │  (one struct)│
    └──────┬───────┘                 └──────┬───────┘
           │ sync?                          │
           ▼                                │ that's it.
    ┌──────────────┐                        │ there is no
    │ Widget Tree  │                        │ second box.
    │  (framework) │                        │
    │              │                        │
    │ Button.text  │                 The view function reads the
    │ Input.value  │                 Model and emits commands.
    │ Scroll.pos   │                 Commands are transient.
    │ List.items   │                 Nothing persists between
    │ Tab.selected │                 frames except the Model.
    │   ...        │
    │              │
    │ (hidden,     │
    │  mutable,    │
    │  scattered)  │
    └──────────────┘


    IMGUI (Dear ImGui)               THIS FRAMEWORK
    ══════════════════               ══════════════

    ┌──────────────┐                 ┌──────────────┐
    │  App State   │                 │    Model     │
    │  (your code) │                 │  (one struct)│
    └──────┬───────┘                 └──────────────┘
           │
           ▼                         cursor position?  → in Model
    ┌──────────────┐                 scroll offset?    → in Model
    │ ID State Map │                 focus state?      → in Model
    │  (framework) │                 animation timer?  → in Model
    │              │                 open/closed?      → in Model
    │ id(###save)  │
    │   → cursor   │                 ┌──────────────────────────┐
    │   → scroll   │                 │ There is no second box.  │
    │   → active   │                 │ All state is explicit,   │
    │   → focus    │                 │ named, typed, visible    │
    │   ...        │                 │ in one place.            │
    │              │                 └──────────────────────────┘
    │ (hidden,     │
    │  hash-keyed, │
    │  implicit)   │
    └──────────────┘
```

---

## 13. LLM Code Generation Pattern

The mechanical steps an LLM follows to add any feature.

```
    TASK: "Add a dark mode toggle"

    ┌─ STEP 1: Add field to Model ──────────────────────────┐
    │                                                        │
    │  const Model = struct {                                │
    │      ...                                               │
    │  +   dark_mode: bool = false,                          │
    │  };                                                    │
    │                                                        │
    └────────────────────────────────────────────────────────┘
                        │
                        ▼
    ┌─ STEP 2: Add variant to Msg ──────────────────────────┐
    │                                                        │
    │  const Msg = union(enum) {                             │
    │      ...                                               │
    │  +   toggle_dark_mode,                                 │
    │  };                                                    │
    │                                                        │
    └────────────────────────────────────────────────────────┘
                        │
                        ▼
    ┌─ STEP 3: Add switch arm to update ────────────────────┐
    │                                                        │
    │  fn update(model: *Model, msg: Msg) void {             │
    │      switch (msg) {                                    │
    │          ...                                           │
    │  +       .toggle_dark_mode => {                        │
    │  +           model.dark_mode = !model.dark_mode;       │
    │  +       },                                            │
    │      }                                                  │
    │  }                                                      │
    │                                                        │
    └────────────────────────────────────────────────────────┘
                        │
                        ▼
    ┌─ STEP 4: Add commands to view ────────────────────────┐
    │                                                        │
    │  fn view(model: Model, cmd: *CmdBuffer) void {         │
    │      ...                                               │
    │  +   cmd.checkbox(.toggle_dark_mode, model.dark_mode); │
    │  +   cmd.text(if (model.dark_mode) "Dark" else "Light");│
    │      ...                                               │
    │  }                                                      │
    │                                                        │
    └────────────────────────────────────────────────────────┘

    ┌────────────────────────────────────────────────────────┐
    │                                                        │
    │  That's it. Four insertions. No wiring. No callbacks.  │
    │  No registration. No lifecycle hooks.                  │
    │                                                        │
    │  If the LLM forgets step 2 or 3, the code won't       │
    │  compile — the exhaustive switch catches it.           │
    │                                                        │
    │  If the LLM adds the wrong Msg type, the tagged union  │
    │  type system catches it.                               │
    │                                                        │
    │  The compiler is the LLM's safety net.                 │
    │                                                        │
    └────────────────────────────────────────────────────────┘
```

---

## 14. Full Frame Timeline

Everything that happens in a single frame, in order.

```
    TIME ──────────────────────────────────────────────────────▶

    ┌──────┐ ┌───────┐ ┌──────┐ ┌──────┐ ┌─────┐ ┌──────┐ ┌──────┐
    │input │ │update │ │ view │ │layout│ │diff │ │render│ │submit│
    │poll  │ │       │ │      │ │ pass │ │     │ │ pass │ │ GPU  │
    └──┬───┘ └──┬────┘ └──┬───┘ └──┬───┘ └──┬──┘ └──┬───┘ └──┬───┘
       │        │         │        │        │        │        │
       │  Msg?  │ Model'  │ []Cmd  │ []Rect │changed?│ wgpu   │
       │───────▶│────────▶│───────▶│───────▶│───────▶│ cmds  ▶│
       │        │         │        │        │ yes/no │        │
       │        │         │        │        │        │        │
       ▼        ▼         ▼        ▼        ▼        ▼        ▼

    ~0.1ms   ~0.01ms   ~0.1ms   ~0.1ms   ~0.05ms  ~0.2ms   ~0.01ms

    Total CPU per frame: < 1ms typical
    Budget at 60fps:     16.6ms
    Budget at 144fps:     6.9ms

    ┌─────────────────────────────────────────────────────────────┐
    │  IF NOTHING CHANGED:                                       │
    │                                                            │
    │  input poll → no Msg → skip update                         │
    │                      → skip view (model unchanged)         │
    │                      → skip layout                         │
    │                      → skip diff                           │
    │                      → skip render                         │
    │                      → present last frame's buffer         │
    │                                                            │
    │  Cost of an idle frame: ~0.1ms (just input polling)        │
    └─────────────────────────────────────────────────────────────┘
```

---

## 15. Platform Layer

How wgpu + WASM enables cross-platform with one codebase.

```
    ┌───────────────────────────────────────────────────────────┐
    │                  APPLICATION CODE                         │
    │                                                           │
    │         Model / Msg / update / view                       │
    │              (pure Zig, no platform deps)                 │
    └─────────────────────────┬─────────────────────────────────┘
                              │
                              ▼
    ┌───────────────────────────────────────────────────────────┐
    │                  FRAMEWORK LAYER                          │
    │                                                           │
    │   CmdBuffer, layout pass, hit-test pass, render pass      │
    │              (pure Zig, depends only on wgpu C API)       │
    └─────────────────────────┬─────────────────────────────────┘
                              │
                              ▼
    ┌───────────────────────────────────────────────────────────┐
    │                   wgpu C API                              │
    │               (wgpu-native or Dawn)                       │
    └────┬────────────┬────────────┬────────────┬───────────────┘
         │            │            │            │
         ▼            ▼            ▼            ▼
    ┌─────────┐ ┌──────────┐ ┌─────────┐ ┌──────────────┐
    │ Vulkan  │ │  Metal   │ │  DX12   │ │  WebGPU      │
    │         │ │          │ │         │ │  (browser)    │
    │ Linux   │ │  macOS   │ │ Windows │ │  WASM target  │
    │ Android │ │  iOS     │ │         │ │              │
    └─────────┘ └──────────┘ └─────────┘ └──────────────┘


    WASM BUILD:
    ┌───────────────────────────────────────────────────────┐
    │                                                       │
    │  zig build -Dtarget=wasm32-freestanding               │
    │       │                                               │
    │       ▼                                               │
    │  app.wasm ─────▶ browser loads WASM                   │
    │                  browser provides WebGPU adapter      │
    │                  same []Cmd, same passes              │
    │                  same pixels                          │
    │                                                       │
    │  Platform differences are BELOW the wgpu line.        │
    │  Everything ABOVE is identical across all targets.    │
    └───────────────────────────────────────────────────────┘
```

---

*These diagrams describe the intended architecture. Implementation will refine them.*
