# Layout engine

**Status**: `pub` in `src/teak.zig` as `LayoutEngine`, `Rect`.
**Source**: `src/layout/engine.zig`
**Tests**: colocated — measure + position for groups, flex distribution, scroll viewports.

Escape hatch 3 in [HARDLINE §2](../HARDLINE.md#escape-hatch-3-flat-buffer-with-stack-layout).

## Contract

```zig
pub const LayoutEngine = struct {
    pub fn doLayout(rects: []Rect, cmds: anytype, window_w: f32, window_h: f32, measurer: TextMeasurer) void;
    pub fn measurePass(rects: []Rect, cmds: anytype, measurer: TextMeasurer) void;
    pub fn positionPass(rects: []Rect, cmds: anytype) void;
};

pub const Rect = struct { x, y, w, h: f32, ... };
```

`doLayout` runs the passes (`doLayoutStats` also reports whether the wrap passes ran). `rects.len == cmds.len` must hold; each `rects[i]` holds the layout result for `cmds[i]`. Use `measurePass` / `positionPass` individually only when writing tests or experimenting with alternative engines.

### Algorithm

Two O(n) linear passes over `[]Cmd` (two more when the frame has wrapped text or shrinkable nodes, see [Wrapped text and shrink](#wrapped-text-and-shrink)):

1. **Measure** (bottom-up, via explicit `FixedStack<GroupContext, 32>`). Each command writes its intrinsic outer size to `rects[i]`. Containers (`push_group` / `push_scroll` / `push_overlay` / `push_virtual_list`) also record `fixed_main`, `flex_total`, `child_count` so the position pass doesn't rescan children. A group's or scroll's `width` / `height` replaces the measured size; `min_width` / `min_height` floor it.
2. **Position** (top-down; pass 4 when wrapping is present). Root `push_group` gets stretched to `(window_w, window_h)`. A container is sized while it is placed in its parent (flex growth, stretch), so its final rect is known before its own children are placed.

No tree allocation. The `FixedStack` is the only stack-based storage, capped at depth 32.

### Sizing model

Every node has an **outer size** (padding and border included). Per axis:

| Source | Effect |
|---|---|
| intrinsic | text/button/etc. measure themselves; a container is content + padding + gaps |
| `width` / `height` (group, scroll, overlay) | replaces the intrinsic size on that axis; `0` = measured |
| `min_width` / `min_height` (group) | floors the result, including a fixed size and stretch |
| `flex` (main axis of the parent) | share of the parent's leftover space, added ON TOP of the child's size |
| `align_cross = .stretch` (parent) | cross size = parent's inner extent, unless the child fixed that axis itself |

**Main axis.** `flex` is a weight (flex-basis auto, grow only): leftover = inner extent - children - gaps, split by weight. Groups never shrink below their content; put overflowing content in a scroll. `flex` works on groups, scrolls, `button`, `canvas`, `image`, `text_input` and `slider`. `cb.spacer(w)` emits an empty flex group for "push the rest to the far end". With **no** flex child, `GroupStyle.justify` distributes the leftover: `.start` (default), `.center`, `.end`, `.space_between` (first/last child flush, equal gaps between; a single child behaves like `.start`).

**Cross axis.** `GroupStyle.align_cross` (also on `ScrollStyle` and `OverlayStyle`) places every child:

- `.start` (default): intrinsic cross size at the start edge. `text_input`, `slider` and `divider` keep their historic behaviour and fill the cross axis in a `.start` parent too.
- `.center` / `.end`: intrinsic size, centered / flush to the end.
- `.stretch`: every child kind (group, scroll, text, button, text_input, checkbox, radio, slider, divider, canvas, image) takes the inner cross extent. A group/scroll with an explicit `width` (vertical parent) or `height` (horizontal parent) keeps it. Stretch may shrink a child below its measured size; its content then overflows (a scroll clips, a group does not).

**Scroll containers.** `width` / `height` fix the viewport; `flex` / stretch size it from the parent. A scroll with `flex > 0` and no fixed size on the parent's main axis has a zero basis there: it takes exactly its share of the leftover and its content (which may be taller) is clipped by render and hit-test. Children are measured as before, shifted by `scroll_x` / `scroll_y`.

**Single-line controls.** `text_input` and `slider` are one row tall: their `flex` grows them along a *horizontal* main axis only. (Before, a `text_input` in a vertical group ballooned into the leftover column height.)

**Overlays.** Absolute `x` / `y` (shifted by the anchor fractions); `width` / `height` force the size; children lay out like a group's (`direction`, `gap`, `padding`, `align_cross`, flex). An overlay never contributes to its parent's size.

**Padding.** `padding` is uniform; `GroupStyle.pad_x` / `pad_y` override one axis.

### The app-shell recipe

```zig
cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });          // root: fills the window
    cb.pushGroup(.{ .direction = .horizontal, .height = 40, .align_cross = .center });  // header bar
    // ...title, cb.spacer(1), buttons...
    cb.popGroup();
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .flex = 1, .align_cross = .stretch }); // body
        cb.pushGroup(.{ .width = 360, .align_cross = .stretch });            // left column, full height
        cb.popGroup();
        cb.pushGroup(.{ .flex = 1, .align_cross = .stretch });               // flexible center
        cb.popGroup();
        cb.pushGroup(.{ .width = 320, .align_cross = .stretch });            // right column
        cb.popGroup();
    cb.popGroup();
    cb.pushGroup(.{ .direction = .horizontal, .height = 24, .align_cross = .center }); // status line
    cb.popGroup();
cb.popGroup();
```

`src/layout/sizing_test.zig` snapshots exactly this shape at 1440x900 (header 40, status 24, columns 360 / flex / 320), plus nested stretch, fixed table columns, `space_between`, min sizes and scroll overflow.

### Rect fields

- `x, y, w, h` — final layout (valid after both passes).
- `fixed_main`, `flex_total`, `child_count` — container accumulators the position pass reads (refreshed by pass 3 when wrapping is present); meaningful for container entries, ignored elsewhere.
- `end` — index of the matching `pop_*` (containers); lets the width passes hop over subtrees.

### Wrapped text and shrink

`text` gains `wrap` (`none` default, `word`, `char`, `ellipsis`), `max_lines` and `text_align`; groups and scrolls gain `shrink` (weight, default 0). Emitters: `cb.paragraph(s)`, `cb.paragraphStyled(s, font, color, opts)`, `cb.textEllipsis(s)`. A height depends on a width, so the engine adds two passes, run only when pass 1 saw a wrapped text or a `shrink > 0` container (`doLayoutStats(...).wrap_passes`):

1. **Measure** (bottom-up) sizes wrapped text at its *max-content* width (one line per hard break).
2. **Resolve widths** (top-down, forward over containers, hopping subtrees via `Rect.end`): for each container, flex growth, flex-shrink, and cross-axis stretch of its direct children, in the same terms the position pass would use. Horizontal overflow is shared among shrinkable children in proportion to `shrink * width`, each floored at its *min-content* (wrapped text: its widest unbreakable segment, `ellipsis`: the "…" glyph, a shrinkable container: what its children need at their minimums); what a clamped child cannot give moves to the others. Wrapped text shrinks implicitly (weight 1). A wrapped text in a vertical parent takes the parent's inner width when the parent stretches (or the text has a non-start `text_align`), else its natural width capped by the room it has. A horizontal scroll never shrinks its content; a vertical scroll's content wraps at the viewport width.
3. **Re-measure heights** (bottom-up): wrapped text height = its line count (`text_wrap`, capped by `max_lines`) times the line height; containers recompute height and `fixed_main`.
4. **Position** is unchanged; because pass 2 already distributed the width, it finds nothing left to grow or shrink.

Long unbreakable tokens break at grapheme boundaries (nothing overflows). Render draws one `TextDraw` per line from the same `text_wrap.LineIter` walk, so reserved height equals drawn lines (tested over 1000 random strings and widths). Defaults (`wrap = .none`, `shrink = 0`) leave every existing layout untouched.

### Text measurement

Text is measured through the Host's `TextMeasurer` (real glyph metrics). `teak.monoMeasurer()` is the headless stub the tests use: 10 px per byte (plus `FontSpec.letter_spacing` per byte), 20 px line height.

## Invariants

- **No allocation.** Caller owns the `rects` slice. Layout writes in place.
- **Stack bounded.** `FixedStack` depth 32 — exceeding it is a bug, not a growth trigger. A UI nesting 32+ groups deep has bigger problems. `push`/`pop`/`top` `std.debug.assert` against overflow and underflow respectively (see `src/layout/engine.zig` — both the generic `FixedStack(T, capacity)` and `ClipStack`), so a bad pass crashes loudly in Debug/ReleaseSafe and is zero-cost in ReleaseFast.
- **Independent passes.** `measurePass` and `positionPass` can each be swapped out without touching the other, so long as the intermediate `Rect` shape is preserved.
- **Deterministic.** Same `[]Cmd` + same window size → same `[]Rect`. No random, no time-varying inputs.
- **Flex is proportional.** `flex = 2` gets twice the remaining main-axis space of `flex = 1`. `flex = 0` uses intrinsic size.

## Non-goals / known limits

- **No constraint solver / CSS Grid.** Groups are horizontal or vertical flex only. A constraint-based pass would swap `positionPass` — the interface supports that, but no such pass exists today. See [`docs/archive/init_convo/ui-framework-refinement.md`](../archive/init_convo/ui-framework-refinement.md) §3 for the design sketch.
- **No intrinsic aspect ratios.** A child can't say "keep me 16:9".
- **No max constraints.** Groups have `min_width` / `min_height` but no maximum. Shrinking is opt-in (`shrink > 0`); groups never shrink by default.
- **Wrapping is `text` only.** `rich_text` stays single-line; no bidi / hyphenation (see text-engine.md section 6.6).
- **No baseline alignment.** Cross-axis alignment is start / center / end / stretch.
- **No RTL / bidi.** Horizontal groups advance left-to-right.

## Extension points

Replacing layout (e.g. with a constraint solver):

1. Write a new pass with the signature `fn (rects: []Rect, cmds: anytype) void` — match `measurePass` / `positionPass`.
2. Call it in place of the stock passes from your app's main loop (either wrap `doLayout` or use the passes directly).
3. No core change required — the passes don't depend on `LayoutEngine` being the entry point.

Read-only extension (e.g. a debug pass that measures overflow): walk `[]Cmd` + `[]Rect` after `doLayout`. Nothing in the framework prevents it.

## Group fills (`GroupStyle.bg`)

`GroupStyle` (in `src/core/cmd.zig`, consumed by both layout and render) carries an optional `bg: ?[4]f32 = null`. When non-null, the render pass emits a single solid-fill quad at the group's full padded rect **before** any of the group's children draw — children paint on top. Default `null` preserves the prior no-fill behaviour, so existing call sites are unaffected.

This is presentation data on a Cmd, not new state-flow shape — HARDLINE §3 is undisturbed (no fn-pointer, no widget-internal state, the view function still pure). Corners are square everywhere: the quad renderer has no rounding. `GroupStyle.border` / `border_width` add a frame inside the rect (see [widgets.md](widgets.md#chrome-styling-borders-hover-inversion-underline-fields-shadows)).

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

## Cmd-buffer balance validation

**Status**: `pub` in `src/teak.zig` as `validateBalance`, `formatBalanceError`, `BalanceError`, `BalanceKind`, `MAX_BALANCE_DEPTH`.
**Source**: `src/core/cmd.zig`
**Tests**: colocated in `src/core/cmd.zig` — balanced → `null`; each imbalance kind with its index; nested/crossed cases; form-row cases; depth overflow; formatter output.

Every `push_*` Cmd (`push_group` / `push_scroll` / `push_overlay` / `push_virtual_list`) must be closed by the matching `pop_*`. A missing pop, a stray pop, or a **crossed pair** (`push_group … pop_overlay`) is otherwise a silent bug: the layout `FixedStack` only `assert`s on overflow/underflow, and a *balanced-but-crossed* buffer doesn't even trip that — it just produces wrong rects. `validateBalance` turns the whole class into a named, immediate error.

```zig
pub fn validateBalance(cmds: anytype) ?BalanceError;         // null == balanced
pub fn formatBalanceError(err: BalanceError, buf: []u8) []const u8;
```

- **Pure, O(n), zero allocation.** Walks the flat `[]Cmd` once against a fixed 32-deep stack (mirrors the layout `FixedStack`). `cmds` is any `[]const Cmd(Msg)` — only Msg-independent tags are read, so it takes `anytype` the way the layout passes do.
- **Reports the first fault only**, as a small POD `BalanceError { tag, open_kind, open_index, close_kind, close_index }`:
  - `unclosed_push` — a `push_*` with no matching pop (`open_*` name it; the innermost still-open push is reported).
  - `stray_pop` — a `pop_*` with nothing open (`close_*` name it).
  - `mismatched_pop` — a crossed pair (`open_*` = the still-open push, `close_*` = the wrong pop).
  - `depth_overflow` — nesting past `MAX_BALANCE_DEPTH` (32); such a buffer would also overflow the layout stack, so it's flagged rather than accepted.
- **Form rows are handled correctly, not specially.** `pushFormRow` / `popFormRow` are sugar that emit `push_group` / `pop_group`, so an unbalanced form row surfaces as an unclosed/stray `.group` — matching what the buffer actually records (no invented distinction).
- **`formatBalanceError`** renders one actionable line into a caller buffer (128 bytes always suffice), e.g. `"push_overlay at cmd #17 was never popped"` or `"push_group at cmd #4 was closed by pop_overlay at cmd #12"`.

### When to run it

`view()` builds the buffer; run the validator between `view()` and `doLayout()`, in **debug builds and tests**, before the layout passes consume the buffer:

```zig
if (@import("builtin").mode == .debug) {
    if (teak.validateBalance(cb.cmds.items)) |err| {
        var buf: [128]u8 = undefined;
        std.debug.panic("teak: unbalanced cmd buffer — {s}", .{teak.formatBalanceError(err, &buf)});
    }
}
```

The recommended integration point is the host loop (`src/run.zig`), guarded on debug mode, so any app's malformed `view()` fails loudly at the exact cmd index instead of producing mystery rects. (The `builtin` import lives at the host-loop layer, outside framework core — HARDLINE §3's no-conditional-compilation rule applies to `src/{core,layout,input,render}/*` only.)

### Layout-engine diagnostics

Independently, `LayoutEngine.measurePass` / `positionPass` now name the cmd index when their container stack over/underflows: `assertPushable` / `assertPoppable` guards sit at each push/pop site and `std.debug.panic` with the offending index (e.g. `"teak layout: pop_* at cmd #12 underflows the container stack …"`) before the bare `FixedStack` assert would fire. These are pure error-path guards — for balanced, in-bounds input the condition is never true, so layout behavior is unchanged. They complement `validateBalance` (which also catches crossed pairs, and *without* panicking): run the validator first for a recoverable diagnostic; the engine guards are the last-line backstop.

## Test coverage target

- **Flex distribution** (covered): three children with weights 1/2/1 in a fixed-width group split the space 25/50/25.
- **Scroll viewport** (covered): a `push_scroll` with `width = 200, height = 200` produces a rect with those dimensions regardless of child intrinsic sizes.
- **Root stretch** (covered): root `push_group` ends up at `(window_w, window_h)`.
- **Padding + gap** (partial): covered for simple groups; missing a test that mixes gap + padding + flex in one group.
- **Depth-limit boundary** (covered): `src/layout/engine.zig` test "FixedStack (via 32-deep group nesting): documented depth is reachable" pushes the full 32-group depth through `measurePass` to confirm the documented capacity is actually reachable without tripping the assert. `src/layout/engine.zig` test "ClipStack: round-trip up to capacity without tripping bounds" does the same for the 16-deep render/hit-test clip stack. Overflow and underflow themselves are `std.debug.assert`ed at the stack call sites — not test-exercised, since a tripped assert is a panic the harness can't observe portably.
