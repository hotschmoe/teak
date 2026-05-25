# Ergonomic helpers — seven gaps closed

**Status**: all 7 `pub` in `src/teak.zig`.
**Branch**: `functional_gaps_yolo`.
**Tests**: distributed across `src/core/theme.zig`, `src/core/cmd.zig`,
`src/input/hit_test.zig`, `src/core/text_field.zig`,
`src/core/component_list.zig`, `src/core/debug_overlay.zig`.
**HARDLINE additions**: none — every helper sits inside the existing
invariants and §2 hatches.

The pre-yolo Teak prototype was production-shape for a counter + a
greeter, but engineering apps with multiple inputs, themed surfaces,
and dynamic lists hit seven friction points that scaled badly. This
doc names each one and where the fix lives.

Read [`docs/HARDLINE.md`](../HARDLINE.md) first if you haven't —
several of these helpers exist specifically *because* the obvious
shortcut violates a HARDLINE rule (fn pointers on Cmd, value-carrying
callbacks, widget-internal state). Each helper below explains which
rule it sidesteps.

---

## 1. Slider drag → `teak.sliderDrag`

**Source**: `src/input/hit_test.zig` (`SliderDrag`, `sliderDrag`).

A slider Cmd carries only `grab_msg` — HARDLINE §3 forbids
fn-pointers, so the framework can't fabricate a value-carrying Msg.
Apps used to write the dance by hand:

```zig
if (press_target) |idx| switch (prev_cmds[idx]) {
    .slider => {
        const v = teak.sliderValueAt(prev_rects[idx], mouse_x);
        // ... build a Msg containing v, dispatch it ...
    },
    else => {},
}
```

Now:

```zig
if (teak.sliderDrag(prev_cmds, prev_rects, press_target, mouse_x)) |d| {
    App.update(&model, App.makeSliderMsg(d.grab_msg, d.value));
}
```

`SliderDrag(Msg)` carries `{ index, grab_msg, value }`. The app's
mapping from `grab_msg` → "which model field to set" stays in the app
layer (one tagged-union switch typically), but the boilerplate that
repeated at every numeric input is gone.

## 2. Keyboard routing → `teak.TextField` + `teak.textFieldChar` / `textFieldSpecial`

**Source**: `src/core/text_field.zig`.

The pre-yolo pattern: every component with a `text_input` defined its
own `name_char` / `name_backspace` / `name_left` / `name_select_left`
/ … Msgs, and the main loop dispatched by hand:

```zig
pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
    return switch (m.focused.?) {
        .greeter => Msg{ .greeter = .{ .name_char = c } },
        .address => Msg{ .address = .{ .name_char = c } },
        // ... one arm per text input ...
    };
}
```

The factor: ship a canonical text-input component once.

```zig
const Search = teak.TextField(64); // 64-byte buffer
const App = teak.Components(.{ .search = Search, ... }, AppLevel);

// In the host's input loop:
for (input.chars) |ch| {
    if (focused == .search) {
        App.update(&model, teak.textFieldChar(App.Msg, "search", ch));
    }
}
for (input.keys) |key| {
    if (teak.keyNeedsClipboard(key)) { ... }   // clipboard chord
    else if (focused == .search) {
        if (teak.textFieldSpecial(App.Msg, "search", key)) |m| {
            App.update(&model, m);
        }
    }
}
```

`textFieldChar` / `textFieldSpecial` / `textFieldReplaceSelection`
use `@FieldType(AppMsg, field_name)` to wrap into the composed Msg —
so the helpers work for any TextField capacity uniformly.

`TextField.Msg` ships the full vocabulary: `focus`, `char`,
`backspace`, `cursor_left`, `cursor_right`, `select_left`,
`select_right`, `select_all`, `select_none`, `replace_selection`.
Apps that need extra ops compose alongside instead of forking.

## 3. Theme → `teak.Theme`, `cb.theme`

**Source**: `src/core/theme.zig`.

Every styled widget used to take an inline `ButtonStyle{...}` block.
No `Theme`, no inheritance, no dark/light switch.

Now a `Theme` carries a `Palette` (bg, fg, accent, danger, …) +
`Typography` (body / heading / mono / small) + per-widget styles
derived from those tokens. `CmdBuffer.theme` defaults to
`Theme.dark_default`; apps either assign one of `Theme.dark_default`
/ `Theme.light_default` per frame, or build their own brand theme
via `Theme.fromPalette(custom_palette)`.

The un-styled convenience emitters consult `cb.theme`:

```zig
cb.button(msg, "Save");    // uses theme.button
cb.text("Hello");          // uses theme.text_color + theme.typography.body
cb.heading("Section");     // uses theme.heading_color + theme.typography.heading
cb.textMuted("(units)");   // uses theme.muted_color + theme.typography.small
cb.textDanger("invalid");  // uses theme.danger_color + theme.typography.small
cb.textMono("42.0");       // uses theme.typography.mono
```

`*Styled` variants (`buttonStyled`, `textInputStyled`, …) keep their
explicit-override behavior. Switching dark↔light is a one-line theme
assignment at the top of the per-frame view setup; no widget knows.

## 4. Form row → `cb.pushFormRow` / `cb.popFormRow`

**Source**: `src/core/cmd.zig` (`FormRowOpts`, push/pop emitters).

Engineering UIs are columns of [label] [input] [units] [validation].
Hand-assembling that out of group + text + content + text every time
gets noisy fast.

```zig
cb.pushFormRow(.{
    .label = "Mass",
    .units = "kg",
    .validation = if (model.mass < 0) "must be positive" else "",
});
cb.textInput(.{ .focus = .mass }, model.mass_str, model.mass_cursor);
cb.popFormRow();
```

Layout: outer vertical group; inner horizontal contains label +
caller-emitted content + units; validation (if non-empty) sits below
the horizontal group inside the outer vertical. Theme-driven
throughout (label uses body color, units uses muted small, validation
uses danger small).

Nestable to depth 8 (e.g., a row inside an overlay); `reset()` zeroes
the row stack alongside cmds + arena.

## 5. Dynamic lists → `teak.ComponentList(Child, capacity)`

**Source**: `src/core/component_list.zig`.

`Components(.{ ... })` is comptime-fixed. A list of N beam-design
cards used to mean hand-rolling `[]BeamModel` and per-index msg
construction.

```zig
const Cards = teak.ComponentList(BeamCard, 64);
const App = teak.Components(.{ .cards = Cards }, AppLevel);

App.update(&model, .{ .cards = .{ .append = .{ /* fresh card */ } } });
App.update(&model, .{ .cards = .{ .child = .{ .idx = 3, .child_msg = .increment } } });
App.update(&model, .{ .cards = .{ .remove_at = 1 } });
App.update(&model, .{ .cards = .clear });
```

`Cards.Msg` is `{ clear, append: ChildModel, remove_at: usize,
child: {idx, child_msg} }`. Update dispatches `.child` to
`items[idx].update`. View loops over live items and constructs
per-index msgs that wrap each child variant as
`AppMsg{ .<list_name> = .{ .child = .{ .idx, .child_msg } } }`.

Magic detail: ComponentList's view recovers `AppMsg` from
`@TypeOf(msgs.clear)` and finds the composed field name by walking
AppMsg variants for one whose payload type is `Self.Msg`. Two
same-typed lists in one composition compile-error rather than
silently picking one.

Lives under HARDLINE §2 hatch 1 alongside `Components()`. Same shape,
same rules — no fn pointers, no runtime reflection.

## 6. Debug overlay → `teak.appendDebugOverlay`

**Source**: `src/core/debug_overlay.zig`.

A complex form's layout used to require std.debug.print breadcrumbs.
Now apps drop a single call at the bottom of view:

```zig
pub fn view(model: *const Model, cb: anytype) void {
    // ... regular UI ...
    if (model.debug_open) {
        teak.appendDebugOverlay(cb, cb.cmds.items, prev_rects, .{});
    }
}
```

Emits an overlay-layer panel with a mono dump of every cmd's index,
tag, and rect. `DebugOverlayOpts` controls filters (`skip_pops`,
`skip_pushes`), max line cap, position, backdrop, fg, font.

Implementation note: the function pre-formats every line into the
per-frame arena **before** calling `cb.pushOverlay`. Callers
universally pass `cb.cmds.items` as the cmds slice, and if we emitted
overlay cmds first the underlying ArrayList realloc would invalidate
the in-flight iteration. (One of those bugs worth stating once in the
doc instead of re-discovering each time.)

## 7. Mixed-font text → `cb.mixedText`

**Source**: `src/core/cmd.zig` (`MixedPart` + emitter).

`TextCmd` carries a single FontSpec — mixing monospaced results
columns with proportional labels in one paragraph used to require
splitting into multiple TextCmds by hand.

The existing `RichTextCmd` always supported per-span fonts; the
missing piece was an ergonomic constructor. `mixedText` bakes the
content + spans into the per-frame arena:

```zig
cb.mixedText(&.{
    .{ .text = "Length: ",  .color = cb.theme.muted_color },
    .{ .text = "42.0",      .font  = cb.theme.typography.mono },
    .{ .text = " mm",       .color = cb.theme.muted_color },
});
```

Each `MixedPart` declares its own font / color / bold / italic; null
fields inherit theme defaults at emit time. The output is a regular
`RichTextCmd` that flows through the existing rich-text layout +
render path.

---

## Public surface added to `teak.zig`

```
// Theme
pub const theme;
pub const Theme;
pub const Palette;
pub const Typography;
pub const dark_palette;
pub const light_palette;

// Mixed-font text
pub const MixedPart;

// Slider drag
pub const sliderDrag;
pub const SliderDrag;

// Text field
pub const text_field;
pub const TextField;
pub const textFieldChar;
pub const textFieldSpecial;
pub const textFieldReplaceSelection;
pub const keyNeedsClipboard;

// Form row
pub const FormRowOpts;

// Component list
pub const component_list;
pub const ComponentList;

// Debug overlay
pub const debug_overlay;
pub const DebugOverlayOpts;
pub const appendDebugOverlay;
```

New CmdBuffer methods: `heading`, `textMuted`, `textDanger`,
`textMono`, `textStyled`, `mixedText`, `pushFormRow`, `popFormRow`,
`setTheme`.

## Drift audit

`zig build audit` stays green. The greppable HARDLINE §5 rules
that this push had to keep clean:

- No `var` statics in framework core. ✓
- No fn-pointer fields on Cmd variants (`MixedPart` carries data;
  every helper's "callback shape" is a Msg value or a comptime
  function). ✓
- All framework core stays platform/gpu import-free. ✓
- wasm canary compiles all of `src/{core,layout,input,render}/` for
  `wasm32-freestanding`. ✓
- View signatures take no allocator parameter. ✓
