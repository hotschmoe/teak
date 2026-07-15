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

`Dropdown(cap)` returns a component whose `Model` holds
`{ open: bool, selected: usize, scroll_offset: f32, highlighted: usize }`
(the last two only matter once the open list scrolls — see below) and whose
`Msg` is `{ toggle, close, select: usize, scroll_by, highlight }`. The
**option labels stay owned by the app** and are passed to an explicit view
call:

```zig
Dropdown(8).viewWith(model, cb, options, msgs, opts);
```

(`viewWith` is the real 5-arg view the app calls explicitly. The 3-arg
`view(model, cb, msgs)` that `validateComponent` requires — the one the
generated composed view invokes — has no slot for the `options` slice or
anchor geometry, so it can only draw a **placeholder** closed button. The
app must call `viewWith` to draw the real selection + open list, the same
hand-call pattern `counter_greeter` uses for `greeter.view`.
`Model`/`Msg`/`update` still compose via `Components` normally.)

> **Trap:** composing a Dropdown through `Components` and letting the
> generated app `view` drive it renders **only the placeholder button** —
> the generated path calls the 3-arg `view`, which has no options. You
> must hand-write the app `view` and call `Picker.viewWith(...)` yourself
> (see [cookbook recipe 5](../cookbook.md#5-dropdown-with-a-scrolling-list)).

`msgs` carries the composed AppMsgs: `.toggle`, `.close`, and
`selectMsg` — a **comptime `fn(usize) AppMsg`** the app supplies to build
the per-index select message. `DropdownViewOpts` positions the open list
(`list_x`, `list_y`, `list_width`, `list_max_height`) and caps its visible
height (`max_visible`, see below).

Behavior: **closed** = a button showing the selected option's label
(placeholder when the slice is empty / index out of range); **open** =
that button plus a `modal` overlay holding one button per option, with
click-outside-to-close for free via the overlay's `backdrop_msg`.
Option rows span the full `list_width` (each carries
`ButtonStyle.min_width = list_width`, honored by the measure pass) and
the scrolled viewport is backed by an opaque `panel_bg`, so a click
anywhere on a row selects — there is no dead zone that dismisses.

### Scrolling the open list

Long option sets no longer overflow the window. Set
`DropdownViewOpts.max_visible = N` and, when `options.len > N`, the open
list is wrapped in a `push_scroll` whose viewport is `N * ITEM_HEIGHT`
tall (`ITEM_HEIGHT = 36`, matching the option-button height) and scrolled
by `Model.scroll_offset`. `max_visible = 0` (the default) keeps the old
draw-everything behavior, so existing call sites are unchanged.

- **Scroll-in-overlay is the idiomatic path, no new mechanism.**
  `push_scroll` already composes inside `push_overlay`: layout gives the
  scroll a normal child cursor, and hit-test + render each keep an
  independent clip stack intersected with the overlay clip, so rows past
  the viewport are clipped in both passes. Feature 1 added no
  layout/hit-test/render code — it just nests the two existing hatches.
- **Scroll state is explicit Model state** (HARDLINE §1):
  `scroll_offset: f32` and `highlighted: usize` live on the Dropdown
  `Model` and are mutated *only* through `update`. `viewWith` clamps the
  offset to `[0, maxScroll]` for display; it never mutates Model.
- **Wheel**: `scrollByMsg(delta, options_len, opts)` builds a `.scroll_by`
  Msg carrying the delta plus the clamp ceiling (so `update` clamps
  without knowing the option count). Wire it from the app's `wheelMsg`.
- **Keyboard**: `moveHighlightMsg(.prev/.next/.first/.last, options_len,
  opts)` builds a `.highlight` Msg. `update` moves the highlight and
  scroll-to-reveals it — the revealed offset is self-bounding, so it never
  needs the option count for the vertical clamp. The highlighted row draws
  with a distinct background; hit-test still resolves each visible row to
  its true option index regardless of scroll offset or highlight (each
  button carries `selectMsg(i)`).

Helpers `maxScroll(options_len, max_visible)` and `scrolls(options_len,
opts)` are exposed for apps that size the anchor rect themselves.

### HARDLINE

No new `Cmd` variant — it's `button` + `pushOverlay` + `pushGroup` /
`pushScroll`. The per-index select Msg is produced by a comptime function
that returns a Msg *value*; nothing function-typed is stored on a `Cmd`
(§3). The open list reuses the overlay layer (§2 hatch 5), its modal
backdrop semantics, and the scroll container — all existing hatches, no
new escape hatch and no per-widget retained state.

---

## Dynamic window title — `Host.setTitle`

`src/platform/host.zig` (contract), `win32.zig` / `x11.zig` / `wasm.zig`
(backends).

### Why

Apps want to reflect state in the title bar — a `"* unsaved"` marker, the
open document's name. `Host.init` was one-shot.

### Shape

`setTitle(self, title: []const u8) void` — added to the `validateHost`
required set. Win32 calls `SetWindowTextW` (reusing init's stack
UTF-8→UTF-16 conversion); X11 calls `XStoreName`; wasm sets
`document.title` via zunk. `teak.run` calls it once per change when the app
exposes `windowTitle`.

### HARDLINE

A **Host surface extension** under §2 hatch 4(d), not a new escape hatch:
one decl added to `validateHost`, no platform type crosses the
framework-facing API.
