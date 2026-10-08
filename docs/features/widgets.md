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

## Combobox (searchable select)

### Why

`Dropdown` collapses a long list to one row but still makes the user scroll
to find "W12x26". `Combobox(cap)` adds a text query that filters the list
(consumer issue #2). Still zero new `Cmd` variants.

### Shape

`teak.Combobox(cap)` (cap = query bytes) is a component: `Model { query:
TextField model, open, selected: ?usize, highlighted, scroll_offset }`,
`Msg { focus, close, select: usize, edit: TextField.Msg, highlight,
scroll_by }`. The option labels are app-owned and passed to `viewWith(model,
cb, options, msgs, opts)`; `msgs` carries `.focus`, `.close` and a comptime
`selectMsg(i)` that receives the **original** option index. `ViewOpts`:
`list_x/list_y/list_width`, `max_visible` (default 8; the list scrolls past
it), `match` (`.substring` | `.prefix`), `input_style`.

The view is a `text_input` (query while open, the selected label while
closed) plus, when open, a modal overlay of one button per match inside a
`push_scroll`, or a disabled "No matches" row. Matching is case-insensitive
(ASCII, Latin-1/Extended-A, Greek, Cyrillic fold) and grapheme-safe: a match
starts and ends on option grapheme boundaries (`matches`, `countMatches`,
`nthMatch` are public and pure).

Host wiring helpers: `charMsg(byte)`, `keyMsg(model, key, options, opts)`
(Up/Down/PageUp/PageDown/Enter/Escape + all `TextField` editing chords),
`enterMsg`, `highlightMsg`, `scrollByMsg`, `shownText`. See cookbook recipe 14
and the MATERIAL field in `examples/chrome`.

### HARDLINE

All state in the Model; the highlight is a match *ordinal* (presentation),
selection is the original index; Cmds carry data only; filtering is a pure
function of `(query, options)` recomputed in `view` with no allocation.

---

## Primitive-built widgets (`teak.widgets`)

### Why

A widget that needs a new `Cmd` variant touches every pass over the flat
buffer. These nine do not: each is a `Model` + `Msg` + `update` and view
helpers that emit existing cmds (`button`, `canvas`, groups, overlays), in the
mould of Dropdown and Combobox. Source: `src/core/widgets/*.zig`; tests and
snapshot goldens sit next to each. They are reached as `teak.widgets.<name>`.

### Shape

| Widget | State (in the app's Model) | Emits |
|--------|----------------------------|-------|
| `toggle` | the app's own `bool` | a clickable `canvas` (track + knob) + label |
| `progress` | `phase` (indeterminate only) | a non-interactive `canvas` |
| `tabs` | `selected`, `focused` | a row of `button`s + a `divider` |
| `split` | `ratio`, `dragging` | two sized groups + an interactive `canvas` divider |
| `tooltip` | `item`, `box`, `deadline`, `shown` | a non-modal `overlay` |
| `toast` | a ring of `cap` entries with a tick countdown | a non-modal bottom-right `overlay` of cards |
| `dialog` | the app's own `bool` | a modal `overlay` (dim backdrop + centred card) |
| `menu.MenuBar` | `State` (active, hot, open, depth, sel) | a button row + modal-scrim + `overlay` panels |
| `menu.ContextMenu` | `State` + the open point | the same panels at the pointer |

**toggle.** `toggle.view(cb, msg, on, label)`: the click Msg flips the app's
bool. Square corners (the quad renderer has no radius), so the retro switch is
a slab with a square knob.

**progress.** `progress.bar(cb, value, style)` is a pure function of a 0..1
value. `progress.indeterminate(cb, phase, style)` slides a block; advance
`phase` with `Sub.every(progress.TICK_MS)` while the work runs
(`Progress.Msg.tick`), never otherwise.

**tabs.** `Tabs.viewWith(model, cb, labels, msgs, opts)` draws the strip (the
selected tab takes the panel colour and an accent border when the strip has
focus); the app emits the content for `model.selected`. Clicking a tab focuses
the strip; `Tabs.keyMsg` then maps Left / Right (wrapping) / Home / End /
Escape. `msgs.selectMsg(i)` is a comptime fn like Dropdown's.

**split.** `begin` / `divider` / `end` bracket the two panes; the outer size
comes from the app (`windowMsg`) because `view` cannot read layout. The divider
is an interactive canvas, so a drag keeps working off the thin strip (pointer
capture). Route it from the app's `canvasMsg` with `split.canvasMsg`. The ratio
is clamped to `min_a` / `min_b`; when both minimums cannot fit, the space is
split in their proportion.

**tooltip.** See "HARDLINE" below. Wiring: `hoverMsg` hook ->
`Tooltip.hoverMsg(Msg, ev, &targets, delay_ms)`, `subscribe` lists
`Sub.at(deadline)`, `view` ends with `Tooltip.view`. The popup flips above and
right-aligns near the window's lower-right so it stays on screen.

**toast.** `Toast(cap, text_cap)`. `Toast.push(&m.toasts, kind, text, ttl)`
from any `update` arm; `ttl` counts `TICK_MS` ticks (0 = sticky). List
`Sub.every(TICK_MS)` only while `Toast.active`. A full stack drops its oldest.
No slide / fade yet (it needs the animation layer); cards appear and vanish.

**dialog.** `Dialog.view(cb, opts, .{ .confirm = ..., .cancel = ... })` while
the app's flag is set; `begin` / `end` wrap custom body content. Enter / Escape
via `Dialog.keyMsg`. Focus trap: the card is a modal overlay, so clicks outside
it hit the backdrop, and `focus.nextFocusable` / `prevFocusable` now confine
Tab traversal to the topmost modal overlay.

**menu.** `MenuBar(Action)` and `ContextMenu(Action)`; the tree is app data
(`MenuItem`: label with an `&` mnemonic, optional action, shortcut text,
enabled / checked, separator, children). Choosing a leaf dispatches
`msgs.run(action)`; the app's `update` for that Msg also closes the menu
(`MenuBar.update(&m.bar, .close)`). Keyboard: F10 or a bare Alt tap
(`SpecialKey.f10` / `.alt_tap`) activates the bar, arrows / Enter / Escape
navigate, a letter is a mnemonic while the bar is active. Because `view` cannot
read layout, geometry is computed from fixed sizes (`top_width`, `row_h`,
`panel_w`, `SEP_H`); rows pad their text to `cols` columns so shortcuts align
in a monospaced font. Panels clamp to the window. A transparent full-window
modal "scrim" overlay behind the panels makes a click anywhere else dismiss
the menu. The navigation logic (`Nav`) is pure and exhaustively tested.

**spinner.** `Spinner(.{ .min, .max, .step, .big_step, .precision })` wraps a `NumericField`: its `Msg` *is* the
NumericField's, so typing routes through `textFieldChar` / `textFieldSpecial` unchanged, and stepping is a function the
app calls from its own `update` arm (`Spinner.step(&m.qty, .up)`). `keyStep` maps Up / Down / Page Up / Page Down,
`wheelStep(dy, shift)` maps the wheel (Shift = big step). A step starts from the current value (the minimum when the
text is empty or invalid), rounds to `precision` (no `0.30000000000000004`), clamps to `[min, max]` and rewrites the
text; the `-` / `+` buttons disable at the limits.
**color_picker.** A saturation / value square and a hue strip (interactive canvases drawn from per-vertex-coloured
triangles: white -> hue left to right, a transparent -> black overlay top to bottom), a preview, hex / R / G / B fields
and a 16-swatch palette. The colour is HSV in the Model (so dragging hue over a grey does not lose it) plus the text of
the four fields; dragging or a swatch rewrites the texts, typing a valid value updates the colour and the *other*
fields (never the one being typed in), and an unparseable field is drawn with a danger border. Route the canvases from
`canvasMsg` (`color_picker.canvasMsg`), the fields from the app's key hooks (`charMsg(field, c)` / `keyMsg(field, key)`),
read the result with `rgb(model)` / `rgba(model)`.

### Host support for the keys

`SpecialKey.f10` is mapped on Win32 (`WM_SYSKEYDOWN`), X11 (`XK_F10`) and the
web host; `alt_tap` is produced by `InputQueue.altDown` / `altUp`, which the
three hosts call from their Alt press / release handling. An Alt press that is
followed by any other key, text or mouse button is not a tap, so Alt+F4 and
Alt+letter chords keep working. (Browsers may take a bare Alt for their own
menu; F10 is the portable activator.)

### Two new App hooks

The tooltip and the context menu need to know what is under the pointer,
which the view cannot read. `teak.run` therefore offers two optional hooks that
hand the app a `PointerEvent(Msg)`: `hoverMsg` (the interactive widget under
the pointer changed) and `contextMsg` (the right button went down). Each event
carries `hit` (the Msg a left click on that widget would dispatch, which *is*
the widget's identity: compare it with `std.meta.eql`, no ids), `box` (its rect
in the previous frame's layout), `mods` and the host clock `now_ms`. Both are
plain data in, `?Msg` out, like `canvasMsg`.

### HARDLINE

* **State.** Everything above is in the Model and moves only through `Msg`s.
* **Tooltip hover and the 3-rule gate.** `TransientState` is for presentation
  that never affects routing *or the Cmd stream* (hover colour, focus ring). A
  tooltip changes what `view` emits, so it fails the gate and its hover state is
  Model state, fed by `hoverMsg`. The delay is a declarative `Sub.at`
  (hatch 6), the anchor comes from the previous frame's rect via the event,
  and there is no wall-clock read in `view`.
* **Toast timing.** A tick countdown in the Model, not `now - created`: `update`
  never sees a clock, and tests are deterministic.
* **No fn pointers on Cmds.** The comptime `msgs.*Msg(i)` / `msgs.menu` /
  `msgs.run` fns build Msg *values*; they are never stored on a cmd.
* **Panels are positioned from constants**, never from measured layout.

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

## Chrome styling (borders, hover inversion, underline fields, shadows)

All square-cornered: the quad renderer has no rounding (the old
`corner_radius` fields were dead and are gone). Everything below is data on
the style structs; render draws it from `TransientState` hover/press/focus
exactly as before.

| Style | Fields |
|---|---|
| `GroupStyle` | `border: ?[4]f32`, `border_width = 1`. Four quads INSIDE the rect, after `bg`, before children. No layout space: keep `padding >= border_width`. |
| `ButtonStyle` | `border`, `border_width`; `hover_fg` / `press_fg` (null = `fg`); `press_offset_y` (label shifts down while pressed); `label_align: TextAlign = .start` (`start`/`center`/`end`); `h_padding = 8`, `min_width = 60`, `height = 36`, `flex`. |
| `TextInputStyle` | `variant: InputVariant = .boxed` (`.underline` = no box, 1px bottom rule, 2px in `focus_border` when focused); `border_width = 2` (boxed); `selection_bg`; `height = 28`. |
| `OverlayStyle` | `border`, `border_width`; `shadow: ?[4]f32`, `shadow_offset = {2, 2}`: a hard, blur-free copy of the overlay rect drawn behind it. It shows through transparent areas, so pair it with an opaque `backdrop` (or opaque child panel). |

Ink-on-paper button that inverts on hover, with a hard-shadowed floating panel:

```zig
const key: teak.ButtonStyle = .{
    .bg = paper, .fg = ink, .hover_bg = ink, .hover_fg = paper,
    .press_bg = ink, .press_fg = paper, .press_offset_y = 1,
    .border = ink, .label_align = .center, .min_width = 0, .height = 24,
};
cb.buttonStyled(.save, "SAVE", key);

cb.pushOverlay(.{ .x = 400, .y = 120, .width = 260, .backdrop = paper, .padding = 10,
                  .border = ink, .shadow = ink, .shadow_offset = .{ 3, 3 } });
// ...panel content...
cb.popOverlay();
```

A `ButtonStyle` / `TextInputStyle` assigned to a `buttonStyled` /
`textInputStyled` call keeps the theme's body font (these emitters used to
fall back to the default sans 14 and ignore the theme typography).
