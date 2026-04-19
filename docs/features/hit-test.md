# Hit-test + hover-test

**Status**: `pub` in `src/teak.zig` as `hitTest`, `hoverTest`, `sliderValueAt`.
**Source**: `src/input/hit_test.zig`
**Tests**: colocated — scroll clipping, painter's order, slider value mapping.

## Contract

```zig
pub fn hitTest(
    cmds: anytype,           // []const Cmd(Msg) — recovered via MsgT
    rects: []const Rect,
    mouse_x: f32,
    mouse_y: f32,
) ?HitResult(Msg);

pub fn hoverTest(
    cmds: anytype,
    rects: []const Rect,
    mouse_x: f32,
    mouse_y: f32,
) ?usize;  // cmd index, any hoverable widget — hit-test is a subset

pub fn sliderValueAt(rect: Rect, mouse_x: f32, style: SliderStyle) f32;
```

`HitResult{ index, msg }` — `msg` is the `Msg` embedded in the hit command. The main loop dispatches it directly; **no ID hashing**, no widget registry.

`hitTest` and `hoverTest` differ by intent:

- **`hitTest`** — "what `Msg` should fire on click?" Returns the interactive leaf (`button`, `text_input`, `checkbox`, `radio`, `slider`) under the cursor, or `null`.
- **`hoverTest`** — "what index should glow?" Broader: any hoverable cmd, used to drive `TransientState.hover_index`.

Both honor the same scroll clip stack (`push_scroll` / `pop_scroll` push/pop rects that intersect with parent clips).

## Invariants

- **Forward walk, last-wins.** Painter's order — later draws paint on top, so the last match at a pixel wins. A backward walk would be simpler for z-order but couldn't honor scroll clips that accumulate top-down.
- **Clipped.** A widget under a scroll container only hits if the mouse is inside the intersection of all enclosing clips.
- **No allocation.** The scroll clip stack is a fixed-depth `ClipStack` (16 levels). Exceeding it is a bug — deepening nested scrolls is not a supported use case.
- **Generic over `Msg`.** The `Msg` type is recovered from `cmds`'s element type via the `MsgT` decl. Callers pass `cb.cmds.items` directly.
- **Reads only the previous frame.** The main loop hit-tests against frame N-1 when dispatching clicks during frame N. One-frame latency is correct and imperceptible.

## Non-goals / known limits

- **No spatial index.** Linear scan per query. Fine for proto-2's cmd counts (hundreds); would need rework at thousands.
- **Rect-only.** Hit regions are axis-aligned rectangles. No custom hit shapes, no per-pixel alpha testing.
- **No hit-test stability.** If a widget moves between frames, the index returned changes — callers using `press_index` across frames must handle the target moving.
- **No drag delta.** `sliderValueAt` is stateless: it maps current mouse X to slider value given the rect. Drag state (e.g. "grabbed this slider at value 0.4") lives in `Model`.

## Test coverage target

- **Painter's order** (covered): two overlapping buttons, click lands on the later one.
- **Scroll clipping** (covered): widget outside the scroll viewport doesn't hit.
- **Slider value mapping** (covered): click at known X, assert value is as expected.
- **Nested scroll clipping** (missing): two `push_scroll` levels; widget visible in the inner but clipped by the outer shouldn't hit.
- **Empty buffer** (covered implicitly via integration test): `hitTest` on empty `cmds` returns `null` without panicking.
