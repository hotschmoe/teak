# Canvas — charts & custom 2D drawing

**Status**: `pub` in `src/teak.zig` (`CanvasCmd`, `CanvasStyle`,
`CanvasPrimitive`, `CanvasPoint`, `canvasLocalPoint`, `lineChartPrimitives`,
`LineChartOpts`, `emitQuadCorners`)
**Source**: `src/core/cmd.zig` (variant + emitters), `src/core/chart.zig`
(chart helper), `src/layout/engine.zig`, `src/input/hit_test.zig`,
`src/render/{vertex,build}.zig`, `src/input/a11y.zig`,
`src/core/snapshot.zig`, `src/run.zig` (`cmdsEqual` frame-diff arm),
`src/platform/win32.zig` (UIA role map), `src/teak.zig` (re-exports)
**Tests**: colocated `test` blocks in each of the above.

A `canvas` is a fixed-size leaf widget that draws a list of pure-data 2D
primitives (gridlines, polylines, filled rects, markers) through the
**existing solid-quad pipeline** — no shader or GPU-backend change. It
exists so engineering-calc apps can draw line charts and other custom 2D
graphics that don't decompose into the standard widgets.

## Contract

### The Cmd

```zig
canvas: CanvasCmd(Msg)   // added to the Cmd(Msg) union

pub const CanvasStyle = struct {
    width: f32 = 200,
    height: f32 = 120,
    flex: f32 = 0,          // sibling-distribution weight (image convention)
    bg: ?[4]f32 = null,     // optional fill drawn before the primitives
};

pub fn CanvasCmd(comptime Msg: type) type {
    return struct {
        style: CanvasStyle = .{},
        primitives: []const CanvasPrimitive = &.{},  // arena-owned, pure data
        msg: ?Msg = null,       // non-null → clickable (hit-test leaf)
        label: []const u8 = "", // a11y name
    };
}
```

### Primitives

All coordinates are **canvas-local logical pixels** (`f32`), origin at the
canvas rect's top-left. `[0, width] × [0, height]` is the drawing space.

```zig
pub const CanvasPoint = struct { x: f32, y: f32 };

pub const CanvasPrimitive = union(enum) {
    polyline:    struct { points: []const CanvasPoint, color: [4]f32, thickness: f32 },
    filled_rect: struct { x, y, w, h: f32, color: [4]f32 },
    hline:       struct { y: f32, color: [4]f32, thickness: f32 },  // spans full width
    vline:       struct { x: f32, color: [4]f32, thickness: f32 },  // spans full height
    marker:      struct { x, y: f32, size: f32, color: [4]f32 },    // centered square
};
```

`CanvasPrimitive` is a **data tagged union** — no function pointers, same
rule as `Cmd` (HARDLINE §3). Build the slice in `view` into the per-frame
arena.

### Emitters

```zig
cb.canvas(style, primitives);                        // non-interactive, unlabeled
cb.canvasLabeled(style, primitives, label);          // + a11y label
cb.canvasClickable(msg, style, primitives, label);   // + click Msg
```

### Per-pass behavior

- **Layout**: fixed-size leaf sized from `style.width`/`height`. `flex`
  contributes to sibling distribution but the canvas keeps its declared
  box (identical convention to the `image` widget).
- **Render**: axis-aligned prims (`filled_rect`/`hline`/`vline`/`marker`)
  are plain quads via the shared `emit`. Polyline segments are arbitrary
  angle, so each is drawn as a 4-corner rotated quad via
  `render/vertex.zig::emitQuadCorners` (added beside `emitQuad`, which
  stays axis-aligned). Primitives clip to the canvas rect intersected with
  the surrounding scroll/overlay clip: axis-aligned prims via the standard
  `clipRect`, polyline segments via a Liang–Barsky data-space clip (fully
  out-of-bounds segments emit nothing).
- **Hit-test**: non-interactive by default. A non-null `msg` makes it an
  interactive leaf; `hit_test.canvasLocalPoint(rect, mx, my)` converts a
  click into canvas-local coordinates (mirrors `sliderValueAt`) so the app
  turns the point into its own data-space `Msg`.
- **a11y**: emits an `A11yNode` with `role = .canvas` and the `label`.
- **snapshot**: one line — `canvas (x,y,w,h) prims=N "label"`.

## The chart helper

```zig
pub fn lineChartPrimitives(
    arena: std.mem.Allocator,
    series: []const f32,
    opts: LineChartOpts,   // width, height, min, max, padding, colors, grid_lines
) []const CanvasPrimitive
```

Pure, data-in-data-out: maps a value series + `[min, max]` bounds into
`grid_lines` horizontal gridlines plus one polyline (min → bottom, max →
top; out-of-range values clamped). A series shorter than 2 points emits
gridlines only. Three lines get a consumer a full chart:

```zig
const prims = teak.chart.lineChartPrimitives(cb.arena.allocator(), series,
    .{ .width = 320, .height = 100, .min = lo, .max = hi, .grid_lines = 4 });
cb.canvasLabeled(.{ .width = 320, .height = 100, .bg = cb.theme.panel_bg },
    prims, "count history");
```

See `examples/counter_greeter/src/app.zig` (`statsView`) for a live
count-history chart driven by plain Model state.

## Interactive recipe (click → data coordinate)

```zig
cb.canvasClickable(Msg{ .chart_click = {} }, style, prims, "plot");
// … in the host/update path, after hitTest returns the canvas index:
if (teak.canvasLocalPoint(rects[hit.index], mouse_x, mouse_y)) |p| {
    // p.x / p.y are canvas-local px; map to your value space in a Msg.
}
```

## Invariants

- Renders entirely through the colored-quad pipeline; no textured/GPU
  changes. `emitQuad`'s axis-aligned contract is unchanged — rotated quads
  go through the new `emitQuadCorners`.
- Primitives never draw outside the canvas rect beyond a bounded
  half-thickness bulge at a Liang–Barsky-trimmed polyline endpoint.
- The `msg` is data only; the canvas carries no callback (HARDLINE §3).

## Non-goals / known limits (v1)

- **No text inside the canvas.** Compose regular `text` cmds around it for
  axis labels / titles.
- **No curves, no fills-under-line, no per-point styling.** Polylines are
  straight segments; markers are squares (the quad pipeline has no circle).
- **No disabled state** and no drag/zoom interaction — only the optional
  single click `msg`.
- Polyline joins are unmitred (each segment is an independent quad); thick
  lines show small gaps/overlaps at sharp corners.
