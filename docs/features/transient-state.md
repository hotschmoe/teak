# TransientState

**Status**: `pub` in `src/teak.zig` as `TransientState`.
**Source**: `src/core/transient.zig`
**Tests**: none colocated; exercised end-to-end through `examples/counter_greeter` renders.

Escape hatch 2 in [HARDLINE §2](../HARDLINE.md#escape-hatch-2-transientstate-presentation-only-state).

## Contract

```zig
pub const TransientState = struct {
    hover_index: ?usize = null,
    press_index: ?usize = null,
    focus_index: ?usize = null,
    frame_counter: u32 = 0,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
};
```

The main loop owns a single `TransientState` instance, updates its fields each frame from `InputState` + hit-test results, and passes it to `buildVertices`. **No other pass reads it.** `update` and `view` are forbidden from touching it.

Indices refer into the **current frame's** `[]Cmd`. Indices from a prior frame are invalid — `reset()` invalidates everything.

## The three-rule gate

A piece of state qualifies for `TransientState` **only if all three hold**:

1. **Derivable** from input + the current frame's `[]Cmd` + `[]Rect`. If the state depends on history the user would notice losing (e.g. scroll offset, text cursor position), it lives in `Model`.
2. **Non-logical.** No `update` branch reads it. No `Msg` is emitted based on it. It only drives pixels.
3. **Safely losable.** If the main loop resets it to default on the next frame, the user experience degrades visually (a flicker) but no data is lost.

If a proposed field fails any rule, it goes in `Model`.

## Invariants

- **Invisible to `update`.** HARDLINE §1: every state transition is a `Msg`. TransientState is not state in that sense — it is derived output.
- **Invisible to `view`.** HARDLINE §3 forbids `view` reading hover/press/focus. The renderer reads them after layout.
- **Bounded size.** All fields are plain values or `?usize`. No allocations.
- **Rebuilt, not accumulated.** The main loop writes every field each frame — no stale bits survive a frame that didn't touch them.

## Non-goals / known limits

- No per-widget animation timers. If a widget needs to animate, the current frame's time delta lives on the main loop's stack and is passed into `buildVertices` — don't stash it here.
- No drag state. Dragging changes logical state (e.g. slider value); emit a `Msg` and update `Model`. See `sliderValueAt` in `hit_test.zig`.
- No multi-touch. `mouse_x` / `mouse_y` / `press_index` assume a single pointer. Adding touch would expand this struct — evaluate against the three-rule gate before doing so.

## Test coverage target

- **Rule-violation sentinel.** A comment block in `src/core/transient.zig` showing the three most likely bad additions (`scroll_offset`, `cursor_pos`, `drag_start`) with a note on why each fails the gate. Not testable in code — a PR reviewer's checklist.
- **Bypass test.** An integration test asserting that changes to hover/press between frames do NOT change `buildVertices` output when the underlying `Model` + `[]Cmd` are identical. Confirms `update` stays untouched.
