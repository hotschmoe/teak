# Layout engine

**Status**: `pub` in `src/teak.zig` as `LayoutEngine`, `Rect`.
**Source**: `src/layout/engine.zig`
**Tests**: colocated — measure + position for groups, flex distribution, scroll viewports.

Escape hatch 3 in [HARDLINE §2](../HARDLINE.md#escape-hatch-3-flat-buffer-with-stack-layout).

## Contract

```zig
pub const LayoutEngine = struct {
    pub fn doLayout(rects: []Rect, cmds: anytype, window_w: f32, window_h: f32) void;
    pub fn measurePass(rects: []Rect, cmds: anytype) void;
    pub fn positionPass(rects: []Rect, cmds: anytype) void;
};

pub const Rect = struct { x, y, w, h: f32, ... };
```

`doLayout` runs both passes. `rects.len == cmds.len` must hold; each `rects[i]` holds the layout result for `cmds[i]`. Use `measurePass` / `positionPass` individually only when writing tests or experimenting with alternative engines.

### Algorithm

Two O(n) linear passes over `[]Cmd`:

1. **Measure** (bottom-up, via explicit `FixedStack<GroupContext, 32>`). Each command writes its intrinsic size to `rects[i]`. `push_group` entries also record `fixed_main`, `flex_total`, `child_count` so the position pass doesn't rescan children.
2. **Position** (top-down). Root `push_group` gets stretched to `(window_w, window_h)`. Each group distributes remaining main-axis space proportionally to children with `flex > 0`.

No tree allocation. The `FixedStack` is the only stack-based storage, capped at depth 32.

### Rect fields

- `x, y, w, h` — final layout (valid after both passes).
- `fixed_main`, `flex_total`, `child_count` — measure-pass-only; meaningful for `push_group` entries, ignored elsewhere.

### Text measurement

Monospace approximation: `content.len * CHAR_WIDTH` where `CHAR_WIDTH = 10`, `TEXT_HEIGHT = 20`. Proto-2 ships with this; real font metrics are a future task dependent on a glyph atlas (blocked on `gpu.md` sampler gap).

## Invariants

- **No allocation.** Caller owns the `rects` slice. Layout writes in place.
- **Stack bounded.** `FixedStack` depth 32 — exceeding it is a bug, not a growth trigger. A UI nesting 32+ groups deep has bigger problems. `push`/`pop`/`top` `std.debug.assert` against overflow and underflow respectively (see `src/layout/engine.zig` — both the generic `FixedStack(T, capacity)` and `ClipStack`), so a bad pass crashes loudly in Debug/ReleaseSafe and is zero-cost in ReleaseFast.
- **Independent passes.** `measurePass` and `positionPass` can each be swapped out without touching the other, so long as the intermediate `Rect` shape is preserved.
- **Deterministic.** Same `[]Cmd` + same window size → same `[]Rect`. No random, no time-varying inputs.
- **Flex is proportional.** `flex = 2` gets twice the remaining main-axis space of `flex = 1`. `flex = 0` uses intrinsic size.

## Non-goals / known limits

- **No constraint solver / CSS Grid.** Groups are horizontal or vertical flex only. A constraint-based pass would swap `positionPass` — the interface supports that, but no such pass exists today. See [`docs/archive/init_convo/ui-framework-refinement.md`](../archive/init_convo/ui-framework-refinement.md) §3 for the design sketch.
- **No intrinsic aspect ratios.** A child can't say "keep me 16:9".
- **No min/max constraints beyond `flex`.** `TextInputStyle` has a `min_width` field read by the emitter, but the layout engine itself treats it as a measured width.
- **No text wrapping.** `text` cmds are single-line. Wrapping requires a shaper.
- **No baseline alignment.** Cross-axis alignment is center-by-stretch (children fill the cross-axis).
- **No RTL / bidi.** Horizontal groups advance left-to-right.

## Extension points

Replacing layout (e.g. with a constraint solver):

1. Write a new pass with the signature `fn (rects: []Rect, cmds: anytype) void` — match `measurePass` / `positionPass`.
2. Call it in place of the stock passes from your app's main loop (either wrap `doLayout` or use the passes directly).
3. No core change required — the passes don't depend on `LayoutEngine` being the entry point.

Read-only extension (e.g. a debug pass that measures overflow): walk `[]Cmd` + `[]Rect` after `doLayout`. Nothing in the framework prevents it.

## Group fills (`GroupStyle.bg`)

`GroupStyle` (in `src/core/cmd.zig`, consumed by both layout and render) carries an optional `bg: ?[4]f32 = null`. When non-null, the render pass emits a single solid-fill quad at the group's full padded rect **before** any of the group's children draw — children paint on top. Default `null` preserves the prior no-fill behaviour, so existing call sites are unaffected.

This is presentation data on a Cmd, not new state-flow shape — HARDLINE §3 is undisturbed (no fn-pointer, no widget-internal state, the view function still pure). No corner radius in this pass; rounded panels are a separate concern when one is asked for.

### Panel / modal-card idiom

The most common use: paint a readable opaque card behind a modal overlay's text. The overlay's `backdrop` is a dim scrim; the *inner* group is the panel.

```zig
cb.pushOverlay(.{
    .x = 0,
    .y = 0,
    .width = window_w,
    .height = window_h,
    .backdrop = .{ 0, 0, 0, 0.78 }, // dim scrim behind the card
    .modal = true,
    .backdrop_msg = Msg{ .close = {} },
});
cb.pushGroup(.{
    .padding = 16,
    .gap = 12,
    .bg = cb.theme.panel_bg, // opaque card surface from theme
});
cb.heading("Settings");
// ... rich text, form rows, buttons ...
cb.button(Msg{ .close = {} }, "Close");
cb.popGroup();
cb.popOverlay();
```

`Theme.panel_bg` (derived from `Palette.bg_panel`) is sized to sit one layer above the scene `bg` so it reads as elevated. Apps that want a flat-toned panel can override `bg` per-call rather than going through the theme.

## Test coverage target

- **Flex distribution** (covered): three children with weights 1/2/1 in a fixed-width group split the space 25/50/25.
- **Scroll viewport** (covered): a `push_scroll` with `width = 200, height = 200` produces a rect with those dimensions regardless of child intrinsic sizes.
- **Root stretch** (covered): root `push_group` ends up at `(window_w, window_h)`.
- **Padding + gap** (partial): covered for simple groups; missing a test that mixes gap + padding + flex in one group.
- **Depth-limit boundary** (covered): `src/layout/engine.zig` test "FixedStack (via 32-deep group nesting): documented depth is reachable" pushes the full 32-group depth through `measurePass` to confirm the documented capacity is actually reachable without tripping the assert. `src/layout/engine.zig` test "ClipStack: round-trip up to capacity without tripping bounds" does the same for the 16-deep render/hit-test clip stack. Overflow and underflow themselves are `std.debug.assert`ed at the stack call sites — not test-exercised, since a tripped assert is a panic the harness can't observe portably.
