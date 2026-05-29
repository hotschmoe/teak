# Widgets: disabled state, NumericField, Dropdown, dynamic title

Consumer-driven widget additions. Each is built from existing primitives
and stays within the existing passes — no new render pipeline, and (for
the components) no new `Cmd` variant.

---

## Disabled state — Button & TextInput

`src/core/cmd.zig`, `src/input/hit_test.zig`, `src/render/build.zig`,
`src/input/a11y.zig`.

### Why

A consumer hit "conditionally not-emit the `+ Add point load` button at
capacity" — which makes the button vanish and shifts everything below it.
A greyed, non-interactive button keeps its place.

### Shape

`ButtonCmd` and `TextInputCmd` gain `disabled: bool = false`.
`ButtonStyle` / `TextInputStyle` gain disabled color tokens
(`disabled_bg` / `disabled_fg`, plus `disabled_border` for inputs). Two
emitters: `cb.buttonDisabled(msg, label)` and
`cb.textInputDisabled(focus_msg, content, cursor)`.

A disabled widget:
- **occupies the identical layout box** — `layout/engine.zig` is untouched,
  so toggling disabled never shifts siblings;
- is **non-interactive** — `hit_test`'s `leafMsg` returns `null` for it,
  so both `hitTest` and `hoverTest` skip it, and `focus.isFocusable`
  skips a disabled `text_input` so Tab traversal passes over it;
- **renders greyed** and skips all interactive feedback (hover/press for
  buttons; focus border, selection highlight, blinking cursor for inputs);
- reports `disabled = true` on its `A11yNode` so screen readers announce
  it as unavailable.

### HARDLINE

`disabled` is plain data on the `Cmd` (no fn-pointers, no widget-internal
state, §3). The four passes stay independent — each reads the flag in its
own arm.

---

## NumericField

`src/core/numeric_field.zig`. Re-exported as `teak.NumericField` /
`teak.NumericConfig`.

### Why

Every form re-implemented "TextField + parseFloat + error state".
`NumericField` bundles them and gives consistent validation display.

### Shape

```zig
const Qty = teak.NumericField(.{ .capacity = 16, .min = 0, .max = 999, .precision = 2 });
```

`NumericField(config)` returns a component (`Model`/`Msg`/`update`/`view`)
that composes via `teak.Components(.{...})` like any other. It **reuses
TextField's `Msg` vocabulary verbatim** (`pub const Msg = TextField(cap).Msg`),
so the existing host dispatch helpers — `textFieldChar`,
`textFieldSpecial`, `textFieldReplaceSelection` — drive a NumericField
field unchanged.

`NumericConfig`: `capacity`, `min: ?f64`, `max: ?f64`, `precision: u8`,
`invalid_message: []const u8`.

Accessors:
- `value(model) ?f64` — parsed value, or `null` when the text doesn't
  parse or falls outside `[min, max]`. An empty field is `null` (a numeric
  field expects a number).
- `isValid(model) bool`, `content(model) []const u8`.
- `formatValue(model, buf) ?[]const u8` — formats the parsed value to
  `precision` decimals (the precision is comptime, so the format string is
  baked at comptime).

`view` emits the text input; when the current value is invalid it wraps
the input + a `textDanger(invalid_message)` line in a vertical group.

### HARDLINE

Pure data + pure functions: parsing happens in the `value` accessor (read
side), never in `update`; `view` is allocation-free beyond the cmd arena;
no platform imports.

---

## Dropdown / Select

`src/core/dropdown.zig`. Re-exported as `teak.Dropdown` /
`teak.DropdownViewOpts`.

### Why

Radios stop scaling past ~10 options; engineering forms need many pickers
(species, rebar sizes, steel sections, code editions, exposure
categories).

### Shape

`Dropdown(cap)` returns a component whose `Model` holds only
`{ open: bool, selected: usize }` and whose `Msg` is
`{ toggle, close, select: usize }`. The **option labels stay owned by the
app** and are passed to an explicit view call:

```zig
Dropdown(8).view(model, cb, options, msgs, opts);
```

(The standard generated `view(model, cb, msgs)` can't carry the options +
anchor geometry, so the app hand-calls this richer `view` — the same
pattern `counter_greeter` uses for `greeter.view`. `Model`/`Msg`/`update`
still compose via `Components` normally.)

`msgs` carries the composed AppMsgs: `.toggle`, `.close`, and
`selectMsg` — a **comptime `fn(usize) AppMsg`** the app supplies to build
the per-index select message. `DropdownViewOpts` positions the open list
(`list_x`, `list_y`, `list_width`, `list_max_height`).

Behavior: **closed** = a button showing the selected option's label
(placeholder when the slice is empty / index out of range); **open** =
that button plus a `modal` overlay holding one button per option, with
click-outside-to-close for free via the overlay's `backdrop_msg`.

### HARDLINE

No new `Cmd` variant — it's `button` + `pushOverlay` + `pushGroup`. The
per-index select Msg is produced by a comptime function that returns a Msg
*value*; nothing function-typed is stored on a `Cmd` (§3). The open list
reuses the overlay layer (§2 hatch 5) and its modal backdrop semantics.

### Follow-up

v1 does not scroll the open list — a list taller than `list_max_height`
draws past it. Wrapping the list in a `push_scroll` is a future addition.

---

## Dynamic window title — `Host.setTitle`

`src/platform/host.zig` (contract), `win32.zig` / `wasm.zig` (backends).

### Why

Apps want to reflect state in the title bar — a `"* unsaved"` marker, the
open document's name. `Host.init` was one-shot.

### Shape

`setTitle(self, title: []const u8) void` — added to the `validateHost`
required set. Win32 calls `SetWindowTextW` (reusing init's stack
UTF-8→UTF-16 conversion); wasm sets `document.title` via zunk. `teak.run`
calls it once per change when the app exposes `windowTitle`.

### HARDLINE

A **Host surface extension** under §2 hatch 4(d), not a new escape hatch:
one decl added to `validateHost`, no platform type crosses the
framework-facing API.
