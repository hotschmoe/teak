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

`HitResult{ index, msg: ?Msg }` — `index` is the cmd index of the hit; `msg` is the `Msg` to dispatch through `update`. The main loop calls `update` directly with it; **no ID hashing**, no widget registry.

`msg` is **optional**. `null` means a *modal* overlay (HARDLINE §2 hatch 5) consumed the click but the app didn't supply a `backdrop_msg`. The host must treat the click as handled (do NOT fall through to widgets behind the modal) but skip the `update` call. The canonical host pattern is:

```zig
if (teak.hitTest(prev_cmds, prev_rects, mx, my)) |hit| {
    if (hit.msg) |m| App.update(&model, m);
    // No else branch: `hit != null and hit.msg == null` means
    // "modal consumed the click, no Msg requested." Skipping the
    // update is the whole point; falling through to base widgets
    // would re-introduce the click-through bug.
}
```

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
- **Modal overlays block fallthrough.** A `push_overlay` with `modal = true` claims any click inside its rect that no interactive child caught. If `backdrop_msg` is set, that Msg is dispatched (click-outside-to-close idiom). Otherwise the click is silently consumed — `HitResult{ .index = push_overlay_idx, .msg = null }`. Non-modal overlays (default) still fall through to base widgets when no leaf catches the click, preserving tooltip / popover / debug-overlay semantics.

## Modal overlay: click-outside-to-close

`OverlayStyle(Msg)` exposes two fields that turn a regular overlay into a true modal:

```zig
cb.pushOverlay(.{
    .x = 0, .y = 0,
    .width = window_w, .height = window_h,
    .backdrop = .{ 0, 0, 0, 0.55 },   // dim scrim
    .modal = true,                     // blocks fallthrough
    .backdrop_msg = Msg.help_close,    // click backdrop -> dismiss
});
// ... inner card with a Close button ...
cb.popOverlay();
```

- `modal: bool` — when true, hits inside the overlay's rect do NOT fall through to the base layer even with no interactive child to catch them.
- `backdrop_msg: ?Msg` — when the click lands inside the overlay rect but on no interactive leaf, dispatch this Msg. Data only — HARDLINE §3 bans fn-pointer callbacks on Cmd variants.

Interactive children inside the overlay still win over the backdrop (painter's order: a leaf hit recorded during the overlay-layer walk takes precedence). The Close button, the text input inside a search modal, etc. continue to work exactly as before.

## Non-goals / known limits

- **No spatial index.** Linear scan per query. Fine for proto-2's cmd counts (hundreds); would need rework at thousands.
- **Rect-only.** Hit regions are axis-aligned rectangles. No custom hit shapes, no per-pixel alpha testing.
- **No hit-test stability.** If a widget moves between frames, the index returned changes — callers using `press_index` across frames must handle the target moving.
- **No drag delta.** `sliderValueAt` is stateless: it maps current mouse X to slider value given the rect. Drag state (e.g. "grabbed this slider at value 0.4") lives in `Model`.

## Test coverage target

- **Painter's order** (covered): two overlapping buttons, click lands on the later one.
- **Scroll clipping** (covered): widget outside the scroll viewport doesn't hit.
- **Slider value mapping** (covered): click at known X, assert value is as expected.
- **Nested scroll clipping** (covered): two `push_scroll` levels; widget visible in the inner but clipped by the outer doesn't hit.
- **Empty buffer** (covered implicitly via integration test): `hitTest` on empty `cmds` returns `null` without panicking.
- **Modal overlay — silent consume** (covered): `modal = true`, no `backdrop_msg`, click on backdrop returns `HitResult{ .msg = null }`.
- **Modal overlay — backdrop_msg** (covered): `modal = true`, `backdrop_msg` set, click on backdrop returns that Msg.
- **Modal overlay — leaf wins** (covered): clicking an interactive child of a modal overlay still returns the child's Msg (not the backdrop_msg).
- **Non-modal overlay fallthrough** (covered): default `modal = false`, click on the overlay's empty area falls through to a base button underneath.
