# Focus traversal

**Status**: `pub` in `src/teak.zig` as `nextFocusable`, `prevFocusable`,
`nextNavigable`, `prevNavigable`, `indexOfFocusMsg`, `focusMsgAt`. The run loop's
keyboard navigation (`RunOptions.keyboard_nav`) is described first; the traversal
primitives follow.
**Source**: `src/input/focus.zig`
**Tests**: colocated — forward/backward wrap, empty buffer, single-focusable
self-wrap, `indexOfFocusMsg` mapping + conditional-drop stability,
`focusMsgAt` round-trip, Tab-skips-disabled.

## Keyboard navigation (run loop)

Text focus stays in the app's Model (`focusedMsg`). Every other keyboard-operable leaf (enabled buttons, checkboxes,
radios, sliders, clickable canvases such as the toggle switch) is focused by the **run loop itself**: a presentation-only
`nav` focus (HARDLINE hatch 2: derivable, non-logical, safely losable) keyed by the leaf's activation `Msg` plus its ordinal
among equal Msgs, so it follows the widget when items are inserted, removed or reordered (and falls to the nearest leaf when
the widget is gone). It never reaches `update`; only the Msgs it activates do.

| Key | Effect |
|---|---|
| Tab / Shift+Tab | next / previous navigable leaf in command order, wrapping; disabled leaves skipped; trapped inside the topmost modal overlay |
| Space, Enter | on a button, checkbox, radio or clickable canvas: dispatches the Msg a click would |
| arrows | radio: move to the previous/next radio of the group and select it (wraps); slider: +-5% (`sliderMsg`), PageUp/Down +-20%, Home / End = 0 / 1 |
| click | moves the keyboard focus to the clicked widget (text fields: to the Model focus) |

Rules: **the app's key hooks run first** (`keyCharMsg`, `keySpecialMsg`, `submitMsg`, clipboard, open menus and dialogs) and the
focused widget only gets keys they decline. Tabbing from a text field to another widget calls the optional hook
`blurMsg(*const Model) ?Msg` so the app can clear its text focus (otherwise typing keeps going to the field); tabbing onto a
text field dispatches its focus Msg as before. When a **modal overlay** opens, the focus moves to its first widget and the
previous widget is remembered; closing it restores that widget (Escape handling stays the app's, e.g. `dialog.keyMsg`).
`RunOptions.keyboard_nav = false` restores the old Tab (text fields only, apps with `focusedMsg`).

**Focus ring**: a frame of `Tokens.focus_ring_width` (2 px) in `Palette.accent`, drawn just outside the focused widget in every
look (square corners follow the button's radius in the modern look). Text fields keep their `focus_border`.

### Audit matrix (examples/gallery, master + this PR)

Legend: yes = works and tested; GAP = does not; N/A = no such widget. "Reach" = Tab / Shift+Tab lands on it. The gallery
test `examples/gallery/src/focus_audit.zig` asserts reach for every enabled interactive widget on every page in every look.

| Widget | Reach | Ring | Activate | Arrows / keys inside | Disabled skipped | Notes |
|---|---|---|---|---|---|---|
| Button | yes | yes | Space, Enter | n/a | yes | |
| Checkbox | yes | yes | Space | n/a | n/a (no disabled state) | |
| Radio group | yes | yes | Space | arrows move + select, wrap | n/a | |
| Slider | yes | yes | n/a | arrows, PageUp/Down, Home/End | n/a | needs the app's `sliderMsg` hook (gallery has it) |
| Toggle switch (clickable canvas) | yes | yes | Space, Enter | n/a | n/a | |
| Text input, NumericField | yes | border | typing | editor keys | yes | focus is the Model's |
| Text area | yes | border | typing | editor keys, visual Up/Down | yes | |
| Combobox | yes | border | Enter commits | Up/Down/Page, Esc closes | n/a | wired through `Combo.keyMsg` while focused |
| Dropdown (button + list) | yes (trigger) | yes | Enter opens; focus moves into the list, back to the trigger on close | Up/Down/Home/End/PageUp/PageDown, Enter chooses, Esc closes (`Dropdown.keyMsg`, wired in the gallery) | yes | |
| Tabs | yes (each tab is a button) | yes | Space, Enter | partial: Left/Right via `Tabs.keyMsg` while the page is shown, not tied to focus; GAP: roving arrows need the a11y `tab` hint | yes | |
| Menu bar / menus | via F10, mnemonics | highlight | Enter | arrows, Esc | yes | `MenuBar.keyMsg` |
| Context menu | yes: Menu key / Shift+F10 opens it at the focused widget (`SpecialKey.context_menu` -> `contextMsg`) | highlight | Enter | arrows, Esc | yes | |
| Dialog | trapped, first widget focused | yes | Enter confirms, Esc cancels | n/a | yes | focus returns to the opener |
| Data table / tree list / hand-built list rows | yes: ONE Tab stop per list | yes | Space, Enter (focuses a component list, then its `keyMsg` wiring drives the cursor) | roving buttons: arrows / Home / End / PageUp / PageDown move the focus (see below); components: their `keyMsg` once focused | n/a | gallery data page: 26 Tab stops became 16 |
| Split pane divider | yes (`Split.dividerFocusable`) | yes | Space, Enter (no-op focus Msg) | arrows resize by `Opts.key_step`, Home / End collapse (via `canvasMsg` `.key` events) | n/a | the plain `divider` stays pointer-only |
| Scroll regions | n/a | n/a | n/a | yes: keys the focused widget declines scroll its innermost id-bearing region through `scrollMsg` (arrows a line, PageUp/Down a viewport, Home/End) | n/a | scrolling the focus into view is not done yet |
| Tooltip | yes: keyboard focus is reported to `hoverMsg` as if the pointer rested on the widget | n/a | n/a | n/a | n/a | clears when focus leaves non-text widgets |
| Toast | its close button is a Tab stop | yes | Space, Enter | Escape dismisses the newest toast (`Toast.keyMsg`, after menus / dialogs) | n/a | |
| Date field (`widgets.date_field`, #81) | yes (text field + calendar button) | border | Down opens, Enter commits | open: arrows move by day / week, PageUp/Down by month, Home/End to month start / end, Esc closes (`DateField.keyMsg`); closed: editor keys | yes | the app routes keys to `keyMsg` while the field has the Model focus; not shown in the gallery |
| Focus after list mutation | yes | | | | | Msg-keyed, tested (insert before the focused widget) |
| Escape closes overlays | app hooks (`dialog.keyMsg`, `MenuBar.keyMsg`, `ContextMenu.keyMsg`) | | | | | the framework does not know how to close an overlay (no Msg) |

### Lists: one Tab stop, roving arrows

A list of row buttons would otherwise be N Tab stops. `ButtonCmd` carries two options (`cb.buttonNav(msg, label, style, .{ .tab_stop, .roving })`):

- `tab_stop = false`: Tab / Shift+Tab skip the button (clicks, Space, Enter and arrows still work). A list marks every row but its active one, so the whole list is one stop; Tab onto the active row, Shift+Tab leaves it backwards.
- `roving = .focus | .select`: contiguous roving buttons in one container form a group. Up/Left and Down/Right move the keyboard focus between them (no wrap), PageUp/PageDown by 5, Home / End to the ends; `.select` also dispatches the row's Msg (selection follows focus, like radios), `.focus` only moves the ring (Enter / Space then activate, e.g. toggle a tree folder).

`DataTable` and `TreeList` set `tab_stop` themselves (the cursor row's first cell / the selected node's label, else the first row) and keep their Model-owned focus: Enter or a click on the stop focuses the list and the app's existing `keyMsg` wiring takes over the arrows. The gallery's hand-built tree uses `.roving = .focus`.

The remaining GAP rows are tracked as follow-up PRs.

## Contract

```zig
pub fn nextFocusable(cmds: anytype, current: ?usize) ?usize;
pub fn prevFocusable(cmds: anytype, current: ?usize) ?usize;
pub fn indexOfFocusMsg(cmds: anytype, msg: anytype) ?usize;
pub fn focusMsgAt(cmds: anytype, index: usize) ?Msg;
```

`nextFocusable` / `prevFocusable` walk `cmds` to find the next/previous
**focusable** cmd index strictly after/before `current`. Wrap at the end.
Return `null` only if the buffer contains no focusables at all. If
`current` is `null`: `next` starts at 0, `prev` starts at the last index.

A command is "focusable" if it accepts keyboard input. Today the predicate
is an **enabled** `text_input` (a `disabled` one is skipped, mirroring how
hit-test refuses to focus it on click). When a new keyboard-operable
widget lands (e.g. an editable slider), extend `isFocusable`.

`indexOfFocusMsg(cmds, msg)` maps a `Msg` **value** back to the cmd index
of the interactive leaf carrying it (button / text_input / checkbox /
radio / slider), comparing with `std.meta.eql`. First match in buffer
order, or `null`. This is the **stable** alternative to "the Nth
text_input": an app keys focus off the `Msg` its focus click dispatches,
which survives conditionally rendered or reordered widgets. Because Msgs
are already data on the cmd (§3), this is not widget-identity hashing — it
matches the value the cmd already carries.

`focusMsgAt(cmds, index)` is the inverse: the focus `Msg` of the leaf at
`index` (the same Msg a click there fires), or `null` if that cmd isn't an
interactive leaf or `index` is out of range. `indexOfFocusMsg` and
`focusMsgAt` round-trip. Together they let `teak.run` implement
Tab/Shift+Tab: resolve the current focus index from the app's
`focusedMsg`, step with `nextFocusable`/`prevFocusable`, and dispatch the
landing leaf's `focusMsgAt`.

## Invariants

- **Pure.** No allocation, no state, no side effects. Given the same `(cmds, current)`, always returns the same result.
- **Wrapping.** `next` past the last focusable wraps to the first. `prev` past the first wraps to the last.
- **Strict-after / strict-before.** `next(cmds, i)` never returns `i`. Even if `i` is the only focusable, it returns `i` after wrapping (so callers that "advance" from the current focus land back on it).
- **Framework-level primitive.** These return cmd indices. The app translates an index into its own `Model.focused` field (which is an app-specific enum, not a cmd index — cmd indices aren't stable across view calls).

## Non-goals / known limits

- **No tab-order override.** Order is cmd-emission order. A `disabled`
  `text_input` *is* skipped; any other focus-skip rule would need
  `isFocusable` to consult a flag.
- **Focus trap.** `nextFocusable` / `nextNavigable` stay inside the topmost modal overlay when one is open (`focusScope`).
- **Cmd-index results are per-frame.** `nextFocusable`/`prevFocusable`
  return cmd indices, which aren't stable across view calls — use them
  within a frame. For focus that *persists* across frames, store it as a
  `Msg`-valued field and resolve it with `indexOfFocusMsg` each frame
  (what `teak.run` does via the app's `focusedMsg`). This is the stable
  path the consumer asked for, replacing fragile "Nth text_input"
  ordinals.

## Per-item focus in a `ComponentList` (consumer issue #1)

**Source**: `src/core/component_list.zig`
**Tests**: colocated — helper round-trip + Tab order, and focus survival
across remove-before, insert-before, and swap.

A `ComponentList(Child, cap)` manages a dynamic homogeneous list. Its
child Msgs route by a **stable per-item key**, not the item's current
index, so a focused widget inside an item stays focused as items are
inserted / removed / reordered around it.

- **The key is an explicit `Model` field, not a hash.** Each item gets a
  monotonic `u64` at `append` / `insert_at` time (a `next_key` counter on
  `Model`); the key travels with the item through `remove_at`, `insert_at`,
  and `swap`. HARDLINE §3 bans hashing ancestors+labels for identity but
  explicitly sanctions "persistent widget identity … on `Model` as an
  explicit field" — this is that field.
- **Why it fixes focus.** Focus is keyed off the `Msg` value a leaf
  carries (see `indexOfFocusMsg` above). `view` emits each item's child
  Msgs wrapped around the item's *key*, so the focus Msg a text input
  carries is stable across reordering. A bare index would shift when items
  move, silently moving focus to the wrong item (or losing it).

### Wiring helpers

```zig
pub fn keyAt(model, i) ?u64;                 // visual index → stable key
pub fn indexOfKey(model, key) ?usize;        // stable key → visual index
pub fn childMsg(key, child_msg) Msg;         // .child by key
pub fn childAt(model, i, child_msg) ?Msg;    // .child by visual index
pub fn focusedMsgForKey(key, child_msg, comptime AppMsg) AppMsg;
pub fn focusedMsgFor(model, i, child_msg, comptime AppMsg) ?AppMsg;
```

`focusedMsgFor` / `focusedMsgForKey` build the composed AppMsg an item's
focusable child carries — byte-identical to what `view` emits — so an app
can implement `focusedMsg(model)` without hand-assembling wrapped Msgs.
Store the focused item's *key* (+ which child field) in your Model, then
return `Fields.focusedMsgForKey(key, .focus, AppMsg)`. `run`'s built-in
Tab/Shift+Tab traversal resolves it via `indexOfFocusMsg` every frame, so
focus survives the list changing. `view` emits items in visual order, so
Tab walks into the list top-to-bottom and out the far side.

New `ComponentList.Msg` variants supporting reorder: `insert_at { idx,
model }` (insert before a visual index, fresh key) and `swap { a, b }`
(exchange two items and their keys).

## Test coverage target

- **Forward wrap** (covered): three focusables, `next` cycles all and returns to the first.
- **Backward wrap** (covered): same for `prev`.
- **No focusables** (covered): returns `null` rather than panicking.
- **Single focusable** (covered): one-widget buffer; `next(..., 0)` wraps back to 0.
- **Non-focusables interleaved** (covered via the wrap tests): text and button cmds in between text_inputs are correctly skipped.
- **`indexOfFocusMsg` mapping + stability** (covered): resolves the right
  index, and still resolves correctly after an earlier widget is
  conditionally dropped (where an ordinal would mismatch).
- **`focusMsgAt` round-trip** (covered): index → msg → index.
- **Tab skips disabled** (covered): a disabled input between two enabled
  ones is passed over by `nextFocusable`/`prevFocusable`.
