# Focus traversal

**Status**: `pub` in `src/teak.zig` as `nextFocusable`, `prevFocusable`.
**Source**: `src/input/focus.zig`
**Tests**: colocated — forward wrap, backward wrap, empty buffer.

## Contract

```zig
pub fn nextFocusable(cmds: anytype, current: ?usize) ?usize;
pub fn prevFocusable(cmds: anytype, current: ?usize) ?usize;
```

Walks `cmds` to find the next/previous **focusable** cmd index strictly after/before `current`. Wraps at the end. Returns `null` only if the buffer contains no focusables at all.

If `current` is `null`: `next` starts at 0, `prev` starts at the last index.

A command is "focusable" if it accepts keyboard input. Today the predicate is:

```zig
fn isFocusable(c: anytype) bool {
    return switch (c) { .text_input => true, else => false };
}
```

When a new keyboard-operable widget lands (e.g. an editable slider), extend `isFocusable`.

## Invariants

- **Pure.** No allocation, no state, no side effects. Given the same `(cmds, current)`, always returns the same result.
- **Wrapping.** `next` past the last focusable wraps to the first. `prev` past the first wraps to the last.
- **Strict-after / strict-before.** `next(cmds, i)` never returns `i`. Even if `i` is the only focusable, it returns `i` after wrapping (so callers that "advance" from the current focus land back on it).
- **Framework-level primitive.** These return cmd indices. The app translates an index into its own `Model.focused` field (which is an app-specific enum, not a cmd index — cmd indices aren't stable across view calls).

## Non-goals / known limits

- **No tab-order override.** Order is cmd-emission order. A widget that should be focus-skipped despite being keyboard-operable would need `isFocusable` to consult a flag — not currently supported.
- **No focus trap.** `next` always returns *something* if focusables exist. Modal dialogs that want to trap focus implement the trap in the app's handler.
- **Cmd-index-based, not widget-identity-based.** If `view` emits widgets in a different order between frames, "next after `prev_focused_index`" lands somewhere different. Apps should store focus as `Model.focused: ?FocusField` (a domain enum) and translate to/from cmd indices per frame.

## Test coverage target

- **Forward wrap** (covered): three focusables, `next` cycles all and returns to the first.
- **Backward wrap** (covered): same for `prev`.
- **No focusables** (covered): returns `null` rather than panicking.
- **Single focusable** (missing): one-widget buffer; `next(..., 0)` should wrap back to 0.
- **Non-focusables interleaved** (covered via the wrap tests): text and button cmds in between text_inputs are correctly skipped.
