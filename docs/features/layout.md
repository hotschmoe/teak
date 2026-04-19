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
- **Stack bounded.** `FixedStack` depth 32 — exceeding it is a bug, not a growth trigger. A UI nesting 32+ groups deep has bigger problems.
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

## Test coverage target

- **Flex distribution** (covered): three children with weights 1/2/1 in a fixed-width group split the space 25/50/25.
- **Scroll viewport** (covered): a `push_scroll` with `width = 200, height = 200` produces a rect with those dimensions regardless of child intrinsic sizes.
- **Root stretch** (covered): root `push_group` ends up at `(window_w, window_h)`.
- **Padding + gap** (partial): covered for simple groups; missing a test that mixes gap + padding + flex in one group.
- **Depth-limit guard** (missing): a `@panic`-free test that 33 nested `push_group`s trigger a detectable error rather than silently clobbering the stack. Currently it's undefined behavior — worth an assert in debug builds.
