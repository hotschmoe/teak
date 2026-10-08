# Teak cookbook

Task-oriented recipes for "add X to my Teak app." Where the feature docs
in [`docs/features/`](features/) are organized *by feature* (one contract
per `pub` surface), this file is organized *by intent* — find the row that
matches what you're trying to do, jump to the recipe.

Every code block below is real, current-API code (verified against
`src/` and, where noted, compiled headlessly). Read
[`docs/HARDLINE.md`](HARDLINE.md) once before touching state flow, widget
identity, passes, or the host boundary — when a change bumps HARDLINE, the
change yields.

## Task → recipe

| I want to… | Recipe |
|---|---|
| Get the smallest app running on `teak.run` | [1. Hello Teak](#1-hello-teak) |
| Add a new piece of state + behavior | [2. Add a feature, the four-step way](#2-add-a-feature-the-four-step-way) |
| Take a validated number in a form | [3. Validated numeric form field](#3-validated-numeric-form-field) |
| Pop a modal dialog with a dim backdrop | [4. Modal dialog](#4-modal-dialog) |
| Offer a long, scrolling picker | [5. Dropdown with a scrolling list](#5-dropdown-with-a-scrolling-list) |
| Render N sub-widgets, focus-stable | [6. Dynamic list with per-item focus](#6-dynamic-list-with-per-item-focus) |
| Rows that each own several focusable fields | [6b. Rows with several focusable fields](#6b-rows-with-several-focusable-fields) |
| Pick from a long list by typing (type-ahead) | [14. Searchable combobox](#14-searchable-combobox) |
| Draw a line chart from a data series | [7. Line chart](#7-line-chart) |
| Test a view with no Host / GPU | [8. Golden-test a view](#8-golden-test-a-view) |
| Observe a running app as an agent | [9. Watch a running app](#9-watch-a-running-app) |
| Open a second top-level window | [10. Add a second window](#10-add-a-second-window) |
| Fire a Msg on a timer | [11. Timer / subscription](#11-timer--subscription) |
| Add a brand-new widget to the framework | [12. Add a new widget to the framework](#12-add-a-new-widget-to-the-framework) |
| Call an HTTP API, open / save a file, remember a setting | [13. Effects: HTTP, files, storage](#13-effects-http-files-storage) |

The mechanical spine underneath every app recipe: **1.** field on `Model`
· **2.** variant on `Msg` · **3.** arm in `update` · **4.** `cb.*` calls in
`view`. The compiler's exhaustive switch makes step 3 un-skippable.

---

## 1. Hello Teak

**Goal:** the smallest complete app — `Model` / `Msg` / `update` / `view`
plus a `main` that hands the backends to `teak.run`.

**You will touch:** `src/app.zig` (the app struct), `src/ui_main.zig` (the
entry point). See [consuming-teak.md](consuming-teak.md) for `build.zig`.

1. Write the app as a file-struct (`@This()` is the app). Four required
   public decls:

   ```zig
   // src/app.zig
   const std = @import("std");
   const teak = @import("teak");

   pub const Model = struct { count: i32 = 0 };
   pub const Msg = union(enum) { inc, dec };

   pub fn update(m: *Model, msg: Msg) void {
       switch (msg) {
           .inc => m.count += 1,
           .dec => m.count -= 1,
       }
   }

   pub fn view(m: *const Model, cb: anytype) void {
       cb.pushGroup(.{ .direction = .vertical, .padding = 16, .gap = 8 });
       cb.text(std.fmt.allocPrint(cb.arena.allocator(), "Count: {d}", .{m.count}) catch "?");
       cb.pushGroup(.{ .direction = .horizontal, .gap = 8, .padding = 0 });
       cb.button(.inc, "+");
       cb.button(.dec, "-");
       cb.popGroup();
       cb.popGroup();
   }
   ```

2. The entry point picks concrete backends and calls `teak.run`:

   ```zig
   // src/ui_main.zig
   const std = @import("std");
   const teak = @import("teak");
   const platform = @import("teak-platform-native"); // Win32 or X11, by target OS
   const gpu_native = @import("teak-gpu-native");
   const App = @import("app.zig");

   pub fn main() !void {
       var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
       defer _ = gpa_impl.deinit();
       var host = try platform.Host.init("Hello Teak", 900, 500);
       defer host.deinit();
       var gpu = try gpu_native.Gpu.init(host.nativeHandle(), 900, 500);
       defer gpu.deinit();
       try teak.run(App, gpa_impl.allocator(), &host, &gpu, .{});
   }
   ```

3. `zig build ui` (or `-Dtarget=…` to cross-compile). `teak.run` owns the
   whole loop: double-buffering, hit-test, layout, render, present.

**Common mistake:** a `view` that doesn't start with a container. Layout
treats `cmds[0]` as the root and `positionPass` expects every leaf to have
a parent on the stack — the first cmd must be `pushGroup`/`pushScroll`.

**Also:** any slice stored on a Cmd (a `text` label, an option list, chart
primitives) must borrow from `Model` or from `cb.arena.allocator()` —
**never a stack buffer**. The layout and render passes read those slices
*after* `view` returns; a `std.fmt.bufPrint(&buf, …)` into a local is a
use-after-return. That is why recipe 1 formats the count with
`allocPrint(cb.arena.allocator(), …)`.

---

## 2. Add a feature, the four-step way

**Goal:** add a "reset to zero" button to the Hello-Teak counter — the
canonical field → variant → arm → cmds walkthrough.

**You will touch:** `src/app.zig` only.

1. **Field on `Model`** — nothing new here (count already exists); if the
   feature needed state, you'd add it: `last_reset_at: u32 = 0,`.

2. **Variant on `Msg`:**

   ```diff
   -pub const Msg = union(enum) { inc, dec };
   +pub const Msg = union(enum) { inc, dec, reset };
   ```

3. **Arm in `update`** — the compiler *forces* this: adding `.reset`
   without an arm won't compile (exhaustive switch).

   ```diff
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .inc => m.count += 1,
            .dec => m.count -= 1,
   +        .reset => m.count = 0,
        }
    }
   ```

4. **`cb.*` in `view`:**

   ```diff
        cb.button(.dec, "-");
        cb.popGroup();
   +    cb.button(.reset, "Reset");
        cb.popGroup();
   ```

That's the entire loop. No wiring, no registration, no re-render call.

**Common mistake:** reaching for widget-internal state or a callback. A
button carries a **Msg value**, never a `fn` pointer (HARDLINE §3). If a
transition needs data, put the data *in the Msg variant* (`toggle: usize`)
or *on the Model*, never in a closure on the Cmd.

---

## 3. Validated numeric form field

**Goal:** take a number in `[0, 1000]`, show a danger-colored message while
it's invalid, and keep the Submit button disabled until it parses.

**You will touch:** `src/app.zig`. Uses `teak.NumericField`,
`cb.pushFormRow`/`popFormRow`, `cb.buttonDisabled`. Depth:
[widgets.md](features/widgets.md).

1. Instantiate the field and compose it. `NumericField(config)` is a
   component; drop it into `Components(.{…}, AppLevel)`:

   ```zig
   const NF = teak.NumericField(.{ .min = 0, .max = 1000, .invalid_message = "enter 0–1000" });

   pub const FocusField = enum { qty };
   const AppLevel = struct {
       focused: ?FocusField = null,
       accepted: f64 = 0,
       pub const Msg = union(enum) { focus_qty, submit };
       pub fn update(m: anytype, msg: @This().Msg) void {
           switch (msg) {
               .focus_qty => m.focused = .qty,
               .submit => m.accepted = NF.value(&m.qty) orelse m.accepted,
           }
       }
   };
   const App = teak.Components(.{ .qty = NF }, AppLevel);
   pub const Model = App.Model;
   pub const Msg = App.Msg;
   pub const update = App.update;
   ```

2. Hand-write `view`: wrap the field in a form row, gate Submit on
   `NF.isValid`:

   ```zig
   pub fn view(m: *const Model, cb: anytype) void {
       cb.pushGroup(.{ .direction = .vertical, .padding = 16, .gap = 12 });
       cb.pushFormRow(.{ .label = "Quantity", .units = "units" });
       NF.view(&m.qty, cb, .{ .focus = Msg{ .focus_qty = {} } }); // emits danger row when invalid
       cb.popFormRow();
       if (NF.isValid(&m.qty))
           cb.button(Msg{ .submit = {} }, "Submit")
       else
           cb.buttonDisabled(Msg{ .submit = {} }, "Submit");
       cb.popGroup();
   }
   ```

3. Route typing to the field with the host helpers (they build the composed
   Msg for the `"qty"` field) and expose `focusedMsg` so `teak.run` blinks
   the cursor + handles Tab:

   ```zig
   pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
       return if (m.focused == .qty) teak.textFieldChar(Msg, "qty", c) else null;
   }
   pub fn keySpecialMsg(m: *const Model, k: teak.SpecialKey) ?Msg {
       return if (m.focused == .qty) teak.textFieldSpecial(Msg, "qty", k) else null;
   }
   pub fn focusedMsg(m: *const Model) ?Msg {
       return if (m.focused == .qty) Msg{ .focus_qty = {} } else null;
   }
   ```

**Common mistake:** treating an empty field as valid. `NumericField`
deliberately reports empty as **invalid** (`value("") == null`) — a numeric
field expects a number. Gate on `isValid`, don't hand-check `content().len`.

---

## 4. Modal dialog

**Goal:** a help/confirm dialog that dims the app behind it, blocks clicks
to widgets underneath, and closes on either a button or a click on the
backdrop (and, ideally, Escape).

**You will touch:** `src/app.zig`. Uses `cb.pushOverlay` with `modal =
true` + `backdrop_msg`. Escape hatch 5 in [HARDLINE §2](HARDLINE.md);
[functional-gaps.md](features/functional-gaps.md).

1. A bool on `Model` + open/close `Msg` variants:

   ```zig
   // Model:  show_help: bool = false,
   // Msg:    help_open, help_close,
   // update: .help_open => m.show_help = true,  .help_close => m.show_help = false,
   ```

2. Emit the overlay **last** in `view` (doc order = painter's order within a
   layer; hit-test still gives overlays precedence). Force the size to the
   window so the scrim covers everything, and give the inner panel its own
   opaque `bg` so text is readable:

   ```zig
   if (m.show_help) {
       cb.pushOverlay(.{
           .x = 0, .y = 0, .width = 900, .height = 500, .padding = 0,
           .backdrop = .{ 0, 0, 0, 0.78 },   // dim scrim
           .modal = true,                     // swallow clicks to the base layer
           .backdrop_msg = Msg{ .help_close = {} }, // click-outside-to-close (data, not a callback)
       });
       cb.pushGroup(.{ .direction = .vertical, .padding = 16, .gap = 12, .bg = cb.theme.panel_bg });
       cb.heading("Help");
       cb.text("Press Escape or click outside to dismiss.");
       cb.button(Msg{ .help_close = {} }, "Close");
       cb.popGroup();
       cb.popOverlay();
   }
   ```

3. Escape-to-close is a `keySpecialMsg` arm:

   ```zig
   pub fn keySpecialMsg(m: *const Model, k: teak.SpecialKey) ?Msg {
       return switch (k) {
           .escape => if (m.show_help) Msg{ .help_close = {} } else null,
           else => null,
       };
   }
   ```

**Common mistake:** setting `backdrop_msg` but leaving `modal = false`.
Without `modal`, a click on the dim area *falls through* and activates the
button behind it. `modal = true` makes the overlay consume unhandled clicks
(a `null` Msg from hit-test means "modal ate it" — `teak.run` correctly
drops it). Use `modal = false` only for tooltips/popovers you *want*
click-through.

---

## 5. Dropdown with a scrolling list

**Goal:** a select whose open list scrolls once it exceeds N rows, instead
of drawing a mile-long menu.

**You will touch:** `src/app.zig`. Uses `teak.Dropdown(cap)` +
`DropdownViewOpts.max_visible`. The app owns the option labels.

1. Compose the dropdown and keep the option slice app-side:

   ```zig
   const Picker = teak.Dropdown(64);
   const App = teak.Components(.{ .picker = Picker }, AppLevel);
   const options = [_][]const u8{ "W8x10", "W8x13", "W10x12", /* … 50 more … */ };
   ```

2. Call `viewWith` (the richer, app-called entry point — the generated
   3-arg `view` only knows how to draw the closed button). `selectMsg` is a
   comptime `fn(usize) AppMsg` that builds the per-row Msg **value**;
   `max_visible` turns the open list into a scroll viewport:

   ```zig
   fn pick(i: usize) App.Msg { return .{ .picker = .{ .select = i } }; }
   const picker_msgs = .{
       .toggle = App.Msg{ .picker = .toggle },
       .close  = App.Msg{ .picker = .close },
       .selectMsg = pick,
   };

   pub fn view(m: *const App.Model, cb: anytype) void {
       cb.pushGroup(.{ .direction = .vertical, .padding = 16, .gap = 8 });
       Picker.viewWith(&m.picker, cb, &options, picker_msgs, .{
           .list_x = 16, .list_y = 52,   // anchor: usually last frame's closed-button rect
           .list_width = 200,
           .max_visible = 8,             // > 8 options → the open list scrolls
       });
       cb.popGroup();
   }
   ```

3. Feed wheel + arrow keys into the list with the builder helpers, which
   fill in the scroll clamp geometry from `options.len`:

   ```zig
   pub fn wheelMsg(m: *const App.Model, dy: f32) ?App.Msg {
       if (!m.picker.open) return null;
       return .{ .picker = Picker.scrollByMsg(dy, options.len, .{ .max_visible = 8 }) };
   }
   ```

**Common mistake:** using `Model.selected` (the committed index) to render
the keyboard highlight, or hand-computing option indices from scroll
offset. Each option button already carries `selectMsg(i)` for its *true*
index, so hit-test resolves correctly no matter the scroll; the highlight
is separate presentation derived from `Model.highlighted`.

---

## 6. Dynamic list with per-item focus

**Goal:** render a variable number of identical sub-components where a
focused child *stays* focused across inserts, removes, and reorders.

**You will touch:** `src/app.zig`. Uses `teak.ComponentList(Child, cap)` +
its stable-key helpers + the app's `focusedMsg` hook.

1. Compose a `ComponentList` of a child component. Each item gets a
   monotonic `u64` **key** at append time — that key, not the shifting
   index, identifies the item:

   ```zig
   const Row = teak.TextField(64);            // any component works as the child
   const Rows = teak.ComponentList(Row, 128);
   const App = teak.Components(.{ .rows = Rows }, AppLevel);
   // add a row:  App.update(&m, .{ .rows = .{ .append = .{} } });
   // remove:     App.update(&m, .{ .rows = .{ .remove_at = i } });
   ```

2. `Rows.view` emits every child in visual order, wiring each child's Msgs
   through its stable key automatically — you just call it. Track focus by
   the item's *key-derived* Msg, not its index:

   ```zig
   // AppLevel: focused_key: ?u64 = null,
   pub fn focusedMsg(m: *const App.Model) ?App.Msg {
       const key = m.focused_key orelse return null;
       // Byte-identical to what Rows.view emits for the focused item.
       return Rows.focusedMsgForKey(key, .focus, App.Msg);
   }
   ```

3. When a row's input is clicked, stash its **key** (resolve index→key via
   `Rows.keyAt`) so the focus survives the list mutating around it:

   ```zig
   // On a row focus click at visual index i:
   //   m.focused_key = Rows.keyAt(&m.rows, i);
   // After remove_at(0), the same key now resolves to a different index —
   // focusedMsg still points at the right widget.
   ```

**Common mistake:** keying focus (or a child Msg) off the visual index. The
moment you `remove_at`/`insert_at`/`swap`, a bare index points at the wrong
item. Route child Msgs with `Rows.childAt(model, i, child_msg)` /
`Rows.childMsg(key, child_msg)` and focus with `focusedMsgForKey` — all
resolve through the stable key. This is an *explicit Model field*, not ID
hashing (HARDLINE §3 sanctions the former, bans the latter).

---

## 6b. Rows with several focusable fields

**Goal:** a `ComponentList` whose rows each own *two or more* focusable
inputs (e.g. a point load with `P` and `a` text fields), with the keyboard
going to "this field of that row". (Consumer issue #1.)

**You will touch:** the row component, the app's `update` + host hooks.
Worked, tested code: the `LoadRow` / `LoadApp` block at the bottom of
`src/core/component_list.zig`.

1. Give the row one **payloadless focus variant per field** and one
   edit variant per field. `ComponentList.view` wires every payloadless
   variant into `rows.child{key, focus_x}` for you — each input carries its
   own focus Msg:

   ```zig
   const Row = struct {
       const TF = teak.TextField(16);
       pub const Model = struct { p: TF.Model = .{}, a: TF.Model = .{} };
       pub const Msg = union(enum) { focus_p, focus_a, p: TF.Msg, a: TF.Msg };
       // update: .p => |x| TF.update(&m.p, x), .a => ... , focus_* => {}
       // view:   cb.textInputSelected(msgs.focus_p, m.p.content(), ...);
       //         cb.textInputSelected(msgs.focus_a, m.a.content(), ...);
   };
   ```

2. The app remembers **`(key, field)`** — an explicit Model field — by
   intercepting the focus click before delegating to the composed `update`:

   ```zig
   // focus: ?struct { key: u64, field: enum { p, a } } = null,
   switch (msg) { .rows => |rm| switch (rm) {
       .child => |c| switch (c.child_msg) {
           .focus_p => m.focus = .{ .key = c.key, .field = .p },
           .focus_a => m.focus = .{ .key = c.key, .field = .a },
           else => {},
       }, else => {} } }
   ```

3. Host hooks build Msgs from that key — never from an index:

   ```zig
   pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
       const f = m.focus orelse return null;
       const child: Row.Msg = switch (f.field) { .p => .{ .p = .{ .char = c } }, .a => .{ .a = .{ .char = c } } };
       return .{ .rows = Rows.childMsg(f.key, child) };
   }
   pub fn focusedMsg(m: *const Model) ?Msg {          // draws the caret + focus rule
       const f = m.focus orelse return null;
       return Rows.focusedMsgForKey(f.key, if (f.field == .p) .focus_p else .focus_a, Msg);
   }
   ```

Because the key travels with the item, removing, inserting or reordering
rows leaves focus on the same field of the same row; Tab/Shift+Tab walk
`p, a` of each row in visual order (`teak.run` does this when you expose
`focusedMsg`). Compare the single-field case in recipe 6.

---

## 7. Line chart

**Goal:** plot a rolling data series (e.g. a value's history) as a labeled
line chart with gridlines.

**You will touch:** `src/app.zig` (a history buffer on `Model` + the chart
in `view`). Uses `teak.chart.lineChartPrimitives` + `cb.canvasLabeled`.
Depth: [canvas.md](features/canvas.md).

1. Keep a fixed-size ring of samples on `Model`, appended in `update` — the
   drop-oldest pattern from `examples/counter_greeter/src/counter.zig`:

   ```zig
   pub const HISTORY_CAP = 32;
   // Model:  history: [HISTORY_CAP]f32 = @splat(0),  history_len: usize = 0,

   fn record(m: *Model, v: f32) void {
       if (m.history_len < HISTORY_CAP) {
           m.history[m.history_len] = v; m.history_len += 1;
       } else {
           std.mem.copyForwards(f32, m.history[0 .. HISTORY_CAP - 1], m.history[1..]);
           m.history[HISTORY_CAP - 1] = v;
       }
   }
   ```

2. In `view`, compute the value range, build the primitives into the
   **per-frame arena**, and emit one `canvas` cmd (~5 lines for a full
   chart):

   ```zig
   const series = m.history[0..m.history_len];
   if (series.len >= 1) {
       var lo = series[0]; var hi = series[0];
       for (series) |v| { lo = @min(lo, v); hi = @max(hi, v); }
       if (hi == lo) { hi += 1; lo -= 1; } // avoid a flat series pinned to an edge
       const prims = teak.chart.lineChartPrimitives(cb.arena.allocator(), series, .{
           .width = 320, .height = 100, .min = lo, .max = hi, .grid_lines = 4,
       });
       cb.canvasLabeled(.{ .width = 320, .height = 100, .bg = cb.theme.panel_bg }, prims, "history");
   }
   ```

**Common mistake:** a `CanvasStyle` whose `width`/`height` don't match the
`LineChartOpts` you passed. The primitives are laid out for the opts
dimensions; if the canvas box is a different size the chart won't fill it
(there's no auto-fit). Keep the two in lock-step. Also: build `prims` in
`cb.arena.allocator()`, never a stack buffer — the slice must outlive
`view`.

---

## 8. Golden-test a view

**Goal:** assert an entire screen as one diffable text block, with no Host,
no GPU, no screenshot.

**You will touch:** a `test` block next to your view. Uses
`teak.LayoutEngine.doLayout` + `teak.monoMeasurer` + `teak.expectSnapshot`.
Depth: [snapshot.md](features/snapshot.md).

The pipeline is **view → layout (mono measurer) → snapshot → compare**:

```zig
test "counter view golden" {
    var cb = teak.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();

    var m: Model = .{ .count = 3 };
    view(&m, &cb);

    var rects: [16]teak.Rect = undefined;
    teak.LayoutEngine.doLayout(
        rects[0..cb.cmds.items.len], cb.cmds.items,
        800, 600, teak.monoMeasurer(),   // stub 10px/char, 20px line — no Host needed
    );

    try teak.expectSnapshot(cb.cmds.items, rects[0..cb.cmds.items.len], .{},
        \\group (0,0,800,600) vertical
        \\  text (16,16,80,20) "Count: 3"
        \\  group (16,44,128,36) horizontal
        \\    button (16,44,60,36) "+"
        \\    button (84,44,60,36) "-"
        \\
    );
}
```

(The literal above is the verified output of the recipe-1 view at
`count = 3`, laid out at 800×600 with the recipe-1 padding — outer group
`padding = 16`, `gap = 8`; inner row `padding = 0`, `gap = 8` — and the
`monoMeasurer` stub, 10px/byte × 20px line.) Pass
`.{ .transient = &ts }` to also assert `[hover]`/`[press]`/`[focus]`
markers, and `.{ .header = .{ … } }` to pin window size / frame / last-msg.

To capture a fresh golden after an intentional view change, dump the actual
once with `teak.snapshotAlloc` + `std.debug.print`, eyeball it, paste it
back into the multiline literal.

**Common mistake:** sizing the `rects` array smaller than
`cb.cmds.items.len`. `doLayout` writes one rect per cmd; too small a buffer
panics. Size it to the cmd count (or use a generous fixed cap and slice).

---

## 9. Watch a running app

**Goal:** as an agent driving a *running* app, observe live state
transitions as text instead of pixels.

**This is implemented.** `teak.run` mirrors each *changed* frame's snapshot
to a file — the same `tag (x,y,w,h) payload` format as recipe 8, with a
header line. Enable it two ways (env wins, read once at `run` start):

```zig
// In code, via RunOptions:
try teak.run(App, gpa, &host, &gpu, .{ .snapshot_path = "/tmp/teak.snap" });
```

```sh
# Or from the environment — overrides the option:
TEAK_SNAPSHOT=/tmp/teak.snap zig build ui &
```

Then read the live GUI as text from anywhere:

```sh
cat /tmp/teak.snap              # the whole screen, right now
grep 'button (' /tmp/teak.snap  # every button and where it sits
# the file is one block, rewritten in place — e.g.
#   window=900x500 frame=42 last_msg=inc
#   group (0,0,900,500) vertical
#     text (16,16,80,20) "Count: 1"
#     ...
```

**Guarantees:**
- **Atomic** — each frame is written to `<path>.tmp` then renamed over
  `<path>`, so a reader never sees a torn file.
- **Change-gated** — rewritten only when the frame content actually changes
  (the same frame-diff that gates the vertex rebuild, minus the cosmetic
  cursor blink). Idle frames never touch disk; `frame=N` in the header
  stamps the *last content change*, so a stale `N` proves no idle rewrite.
- **`last_msg`** in the header is the `@tagName` of the last dispatched
  `Msg` — including a sub-fired timer Msg — so a diff tells you *what*
  changed and *which transition* caused it.
- **Fail-safe** — an unwritable path disables the sink after one
  `std.log.warn`; it never crashes or slows the app.

**Also works (no Host):** the headless golden loop from recipe 8. Drive the
app in a test — `update(&m, msg)` then re-`view` + `snapshotAlloc` — and
read the returned text between transitions. Depth:
[snapshot.md](features/snapshot.md).

---

## 10. Add a second window

**Goal:** a detached top-level window (e.g. a live "Stats" panel) that
`teak.run` opens, renders, and tears down from data + Msgs.

**You will touch:** `src/app.zig` — three optional decls. `teak.run` owns
the Host + GPU window lifecycle; the app never calls
`Host.openSecondaryWindow`. Depth: [run.md](features/run.md#secondary-window).

> **Platform note:** secondary windows are **Win32-only** today. On X11 and
> wasm `Host.openSecondaryWindow` returns `null`, so the decls compile and
> the primary window is unaffected — the second window just never opens.

1. A bool on `Model` gates the window; `secondaryWindow` returns a
   data-only spec when it should be open, `null` when closed:

   ```zig
   // Model:  show_stats: bool = false,
   pub fn secondaryWindow(m: *const Model) ?teak.SecondaryWindowSpec {
       return if (m.show_stats)
           .{ .title = "Stats", .width = 360, .height = 200 }
       else
           null;
   }
   ```

2. `secondaryView` draws it — same Cmd type as the primary view, a
   different surface:

   ```zig
   pub fn secondaryView(m: *const Model, cb: anytype) void {
       cb.pushGroup(.{ .direction = .vertical, .padding = 16, .gap = 8, .bg = cb.theme.panel_bg });
       cb.heading("Stats");
       cb.text(std.fmt.allocPrint(cb.arena.allocator(), "Count: {d}", .{m.count}) catch "?");
       cb.popGroup();
   }
   ```

3. `secondaryClosedMsg` mirrors an OS-initiated close back into your state
   so the toggle re-syncs:

   ```zig
   pub fn secondaryClosedMsg(_: *const Model) ?Msg { return .close_stats; }
   // update: .close_stats => m.show_stats = false,
   ```

**Common mistake:** trying to touch platform/GPU handles from the app to
open the window. That breaks HARDLINE §4(c) (framework code never imports
`platform/*`/`gpu/*`). The window is declared as **data** (`secondaryWindow`
returns a spec); `run` diffs it against the live window to open/close/resize.

---

## 11. Timer / subscription

**Goal:** fire a `Msg` on a periodic timer (autosave tick, clock, poll)
without reading a clock inside `view` (HARDLINE §3 bans that).

**You will touch:** `src/app.zig` — one optional decl. Uses `teak.Sub(Msg)`
(data-only) + `Host.nowMs()`. Escape hatch 6 in [HARDLINE §2](HARDLINE.md);
depth: [subscriptions.md](features/subscriptions.md).

Expose `subscribe` as a **pure function of Model** returning data-only
`Sub` values — same purity rules as `view`. The variants are `.every`
(periodic) and `.at` (one-shot deadline):

```zig
pub fn subscribe(m: *const Model) []const teak.Sub(Msg) {
    _ = m;
    // Fire .tick on every crossed 1000 ms boundary.
    return &.{.{ .every = .{ .interval_ms = 1000, .msg = .tick } }};
}
// Msg: tick,   update: .tick => m.seconds += 1,
```

That's the whole app-side change. **`teak.run` auto-services it:** each
frame, immediately before it builds the view, `run` calls `subscribe(model)`
and feeds the result through `teak.runSubs` on `Host.nowMs()`; a fired sub
is dispatched as a normal `Msg` through `update` (no second mutation path),
reflected in the frame emitted this tick, and its tag lands in the live
snapshot's `last_msg`. You do **not** call `runSubs` yourself — `run` owns
the `nowMs` read and the `last_frame_ms` bookkeeping.

(If you hand-roll a loop instead of `teak.run`, call `runSubs` yourself:
`teak.runSubs(Msg, subscribe(&model), last_frame_ms, host.nowMs(), dispatch)`
where `dispatch` is a bare `fn(msg)` bound to your model via a small static
struct — see [subscriptions.md § "Standalone use"](features/subscriptions.md).)

**Common mistake:** expecting `.at` to *re-fire* every frame past its
deadline. It does not — `.at` fires **exactly once** on the crossing frame
(`last_frame_ms < deadline_ms <= now_ms`) and then auto-stops, because
`last_frame_ms` advances past the deadline; you need not drop the sub from
`subscribe()`. The real gotcha is the reverse: a **re-armed** deadline (a
new, later `deadline_ms` stored in `Model`) opens a fresh window and is a
new one-shot fire. `.every` is stateless too — a slow frame can skip or
double-fire a tick (both go through `update`).

---

## 12. Add a new widget to the framework

**Goal:** add a genuinely new `Cmd` variant to Teak itself (not composed
from existing widgets). Every pass over the flat buffer must learn the new
tag — miss one and you get a silent wrong-rects bug or a crash.

**You will touch:** `src/core/cmd.zig`, `src/layout/engine.zig`,
`src/input/hit_test.zig`, `src/render/build.zig` (+ `src/render/vertex.zig`
if you need a new quad shape), `src/input/a11y.zig`, `src/input/focus.zig`
(if the widget is keyboard-focusable), `src/core/snapshot.zig`,
`src/run.zig`, `src/platform/win32.zig`, `src/teak.zig` (re-export), and
`llms.txt` (the audit **fails the build** if a new `pub const` re-export is
absent — `tools/audit.zig`'s `LLMS_TXT_RULE`). Model it on how `canvas` was
added ([canvas.md](features/canvas.md) lists the same spots).

1. **Define the payload + variant** in `cmd.zig`: a `FooStyle`/`FooCmd(Msg)`
   struct (data only — no `fn` pointers, HARDLINE §3) and a line in the
   `Cmd(Msg)` union. Add a convenience emitter method on `CmdBuffer`
   (`pub fn foo(self, …)` doing `self.cmds.append(.{ .foo = … })`). If it's
   a container, also add matching `push_foo`/`pop_foo` and a `BalanceKind`.

2. **Layout** (`layout/engine.zig`): add a `.foo` arm to **`measurePass`**
   (intrinsic size) and to **`positionPass`** (most leaves join the
   `.text, .button, .image, … => {}` leaf arm).

3. **Hit-test** (`input/hit_test.zig`): add `.foo` to the `msgOf`-style
   switch — return its click `Msg`, or `null` if non-interactive.

4. **Render** (`render/build.zig`): add a `.foo` arm to `buildVertices`
   that emits quads/text draws.

5. **A11y** (`input/a11y.zig`): add a `Role` enum member and a `.foo` arm
   mapping the cmd to an `A11yNode{ .role = .foo, .label = … }`.

The three easy-to-miss spots — a stray tag here is a silent bug, not a
compile error, because these switches take `anytype`:

6. **Snapshot** (`core/snapshot.zig`): add a `.foo` arm to `writeCmd` (one
   grep-able line: `foo (x,y,w,h) payload`). Container? also handle it in
   the `push_*`/`pop_*` depth switches in `write`.

7. **Frame-diff** (`src/run.zig`): add a `.foo` arm to **`cmdsEqual`**
   comparing observable content (not pointer identity — the arena hands out
   fresh addresses each frame). Miss this and the frame-diff skip either
   over-renders or shows stale content.

8. **Win32 UIA** (`platform/win32.zig`): map the new `Role` in
   `controlTypeForRole` (and `isFocusableRole` if it's interactive) — e.g.
   `.foo => UIA_ImageControlTypeId`.

9. **Keyboard focus** (`input/focus.zig`): if the widget is Tab-focusable,
   add its tag to `isFocusable` — otherwise Tab traversal skips it. (Skip
   this for a purely-mouse or display-only widget, like `canvas`.)

10. **Re-export + llms.txt** (`src/teak.zig`, `llms.txt`): if the new
    payload/emitter is part of the public API, add the `pub const`
    re-export in `teak.zig` **and** document the name in `llms.txt` — the
    `zig build audit` `LLMS_TXT_RULE` **fails the build** when a
    `src/teak.zig` re-export is missing from `llms.txt`
    (`tools/audit.zig`).

**Common mistake:** the switches in steps 2–8 are `anytype` and many use a
combined leaf arm, so forgetting a tag *compiles* and then misbehaves
silently — wrong rects (layout), an un-clickable widget (hit-test), a
frame-diff that never refreshes (`cmdsEqual`), or an invisible-to-a11y
control. Before proposing a brand-new variant, check whether the widget can
be *composed* from existing primitives instead (that's how `Dropdown` works
— zero new Cmd variants); a new variant is a real cost across eight files
and should clear the HARDLINE §4 bar.

---

*Missing a recipe? The feature docs in [`docs/features/`](features/) carry
the full contract for every `pub` surface; this cookbook only covers the
common intents.*

---

## 13. Effects: HTTP, files, storage

**Goal:** talk to the outside world (an HTTP API, a file the user picks, a
download, a saved setting, a pasted screenshot) without doing I/O in
`update` or `view`.

**You will touch:** `src/app.zig` — `effects` + `effectMsg`. Escape hatch 7 in
[HARDLINE §2](HARDLINE.md); depth: [effects.md](features/effects.md);
a complete app: `examples/effects`.

The app *lists* what it wants; the host does it; the answer comes back as a
`Msg`. Keep the request in `Model` (the list borrows from it) and give every
request a fresh id:

```zig
const Model = struct {
    next_id: u32 = 1,
    asking: bool = false,
    req: [1]teak.Effect = undefined,
    reply: [512]u8 = undefined,
    reply_len: usize = 0,
};
const Msg = union(enum) { ask, answered: teak.HttpResult };

pub fn update(m: *Model, msg: Msg) void {
    switch (msg) {
        .ask => {
            m.req[0] = .{ .http = .{
                .id = m.next_id,
                .method = .post,
                .url = "https://api.example.com/v1/chat",
                .headers = &.{.{ .name = "content-type", .value = "application/json" }},
                .body = "{\"q\":\"hi\"}",
                .timeout_ms = 30_000,
            } };
            m.next_id += 1;
            m.asking = true;
        },
        .answered => |r| {
            m.asking = false; // delisted: the id is forgotten next frame
            const n = @min(r.body.len, m.reply.len); // r.body dies when update returns: copy
            @memcpy(m.reply[0..n], r.body[0..n]);
            m.reply_len = n; // status 0 means a transport failure; r.err says why
        },
    }
}

pub fn effects(m: *const Model) []const teak.Effect {
    return if (m.asking) &m.req else &.{};
}

pub fn effectMsg(_: *const Model, r: teak.EffectResult) ?Msg {
    return switch (r) {
        .http => |h| .{ .answered = h },
        else => null,
    };
}
```

`run` issues the id once while it is listed, never again, and drops a late
answer if you delisted it (that is how you cancel). The same shape covers
`open_file` (`.file_opened{ name, mime, bytes }` / `.file_cancelled`),
`download`, `storage_get` / `storage_set`, `clock`, `write_clipboard` and
`query_param`. An app that only wants pasted / dropped images and text
declares `effectMsg` alone and matches `.dropped` / `.pasted_text`.

**Common mistakes:** reusing an id while an older request of that id is in
flight (answers mix up); keeping `r.body` instead of copying it; expecting
`open_file` to open a picker outside a user gesture on the web (it arms
itself for the next click or key press); expecting a result from the
fire-and-forget `storage_set` / `write_clipboard`.

---

## 14. Searchable combobox

**Goal:** a picker over a long option list (W-shapes, materials, rebar) that
filters as you type. (Consumer issue #2; `Dropdown` is the no-search
variant, recipe 5.)

**You will touch:** `src/app.zig` — a `Model` field, a `Msg` variant, an
`update` arm, `viewWith` in the view, and four host hooks. Live example:
the MATERIAL field in `examples/chrome`.

```zig
const Material = teak.Combobox(24);            // 24 = query capacity (bytes)
const opts: teak.ComboboxViewOpts = .{ .list_x = 12, .list_y = 390, .list_width = 336, .max_visible = 6 };
// Model:  material: Material.Model = .{ .selected = 0 },
// Msg:    material: Material.Msg,
// update: .material => |mm| Material.update(&m.material, mm),
// view:   Material.viewWith(&m.material, cb, &options, msgs, opts);
const msgs = .{ .focus = Msg{ .material = .focus }, .close = Msg{ .material = .close }, .selectMsg = pick };
fn pick(i: usize) Msg { return .{ .material = .{ .select = i } }; }   // i = ORIGINAL option index
```

Host hooks (only while `m.material.open`, which doubles as "has focus"):

```zig
pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
    if (m.material.open) return .{ .material = Material.charMsg(c) };
    ...
}
pub fn keySpecialMsg(m: *const Model, key: teak.SpecialKey) ?Msg {
    if (m.material.open) return if (Material.keyMsg(&m.material, key, &options, opts)) |mm| .{ .material = mm } else null;
    ...
}
pub fn wheelMsg(m: *const Model, dy: f32) ?Msg {
    if (!m.material.open) return null;
    return .{ .material = Material.scrollByMsg(&m.material, dy, &options, opts) };
}
pub fn focusedMsg(m: *const Model) ?Msg { if (m.material.open) return .{ .material = .focus }; ... }
```

Behaviour: click the input or press Down to open; typing filters
(case-insensitive substring, or `.match = .prefix`) and highlights the first
match; Up/Down/PageUp/PageDown move the highlight (scrolled into view);
Enter picks it; Escape or a click outside closes; a disabled "No matches"
row shows when nothing matches. Focus the app's other fields with a Msg that
sets `material.open = false` (see chrome's `.focus_name`).

**Common mistake:** treating the `selectMsg` index as the filtered ordinal —
it is the index into *your* options slice, so `m.material.selected` is always
a valid index into it. `list_x/list_y` are window coordinates (the previous
frame's rect of the input, as for `Dropdown`).
