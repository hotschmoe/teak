# Focus traversal

**Status**: `pub` in `src/teak.zig` as `nextFocusable`, `prevFocusable`,
`indexOfFocusMsg`, `focusMsgAt`.
**Source**: `src/input/focus.zig`
**Tests**: colocated — forward/backward wrap, empty buffer, single-focusable
self-wrap, `indexOfFocusMsg` mapping + conditional-drop stability,
`focusMsgAt` round-trip, Tab-skips-disabled.

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
- **No focus trap.** `next` always returns *something* if focusables exist. Modal dialogs that want to trap focus implement the trap in the app's handler.
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
