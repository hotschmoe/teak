# Canvas — charts & custom 2D drawing

**Status**: `pub` in `src/teak.zig` (`CanvasCmd`, `CanvasStyle`, `CanvasTransform`,
`CanvasPrimitive`, `CanvasPoint`, `canvasLocalPoint`, `lineChartPrimitives`,
`LineChartOpts`, `emitQuadCorners`, `CanvasEvent`, `CanvasEventKind`, `Buttons`,
`Modifiers`, `Button`)
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
    flex: f32 = 0,          // main-axis growth weight (fills a stretch parent with width/height 0)
    bg: ?[4]f32 = null,     // optional fill drawn before the primitives
    transform: CanvasTransform = .{},  // world -> canvas px at lowering (see "World transform")
    antialias: bool = false,           // per-pixel edge coverage (see "Antialiasing")
};

pub fn CanvasCmd(comptime Msg: type) type {
    return struct {
        style: CanvasStyle = .{},
        primitives: []const CanvasPrimitive = &.{},  // arena-owned, pure data
        msg: ?Msg = null,       // non-null → clickable (hit-test leaf)
        label: []const u8 = "", // a11y name
        pointer: bool = false,  // true → interactive surface: pointer input becomes CanvasEvents
        id: u32 = 0,            // CanvasEvent.id; non-zero + distinct per interactive canvas
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
    triangles:   struct { verts: []const TriVertex, key: u64 = 0 }, // pre-tessellated, per-vertex RGBA
    lines:       struct { segs: []const [4]f32, color: [4]f32, thickness: f32, key: u64 = 0 },
    text:        struct { x, y: f32, content: []const u8, font: FontSpec, color: [4]f32 },
    circle:      struct { x, y, radius: f32, fill: ?[4]f32, stroke: ?[4]f32 = null, thickness = 1, screen_radius = false },
    arc:         struct { x, y, radius, start = 0, sweep = pi: f32, color, thickness, screen_radius = false },
    polygon:     struct { points: []const CanvasPoint, fill: ?[4]f32, stroke: ?[4]f32 = null, thickness = 1 },
};
pub const TriVertex = struct { x, y, r, g, b, a: f32 };   // CanvasPrimitive.TriVertex
```

`CanvasPrimitive` is a **data tagged union** — no function pointers, same
rule as `Cmd` (HARDLINE §3). Build the slice in `view` into the per-frame
arena.

#### Big batches: `triangles` and `lines`

For apps that tessellate themselves (CAD hatching, filled regions,
antialiased vector linework) a canvas can carry whole batches in one
primitive:

- **`triangles`** — a plain triangle list (3 consecutive vertices = 1
  triangle, either winding) in canvas-local px with a **color per vertex**,
  interpolated across the triangle. Per-vertex alpha lets the app feather
  1 px edges for antialiasing without MSAA. Renders through the solid
  pipeline (alpha-blended, painter's order = slice order). A non-finite
  vertex drops its triangle; a trailing partial triangle is ignored.
- **`lines`** — `segs[i] = {x0, y0, x1, y1}`, one thickness/color for the
  batch; each segment is a rotated quad (no joins), clipped like polyline
  segments. For hatch fields.
- **Clipping** is CPU, against the canvas rect intersected with the active
  scroll/overlay clip. Triangles use three tiers: if the whole list's
  bounds are inside the clip it is one bulk conversion (a single
  allocation); else triangles whose own bounds are inside are copied;
  only the straddling ones go through Sutherland–Hodgman (color
  interpolated at the cut, result fan-triangulated). 200k vertices stay
  linear (covered by the perf tests in `render/build.zig`).
- **`key`** is a cheap content revision for the frame diff: two frames
  whose batch has the same non-zero `key` and length are treated as
  identical without comparing the vertices (megabytes). **Bump the key
  whenever the batch changes.** `key = 0` means "no revision supplied":
  the diff compares the bytes (still a fast `memcmp`).

#### Circles, arcs, polygons

- **`circle`**: fill, stroke (centred on the radius, `thickness` px), or
  both. `radius` is in world units (it follows the transform) unless
  `screen_radius`, which keeps a fixed pixel size at every zoom (node dots,
  handles). In the 2D pass a round circle is ONE SDF quad (12 vertices, exact
  antialiasing at any size, whatever `antialias` says); under a non-uniform
  transform (an ellipse) and in 3D plane layers it is tessellated with a
  quarter-pixel chord error.
- **`arc`**: a stroked arc from angle `start` through `sweep` radians, world
  orientation: 0 = +x, positive sweep turns toward +y (clockwise on screen with
  the identity transform, counter-clockwise under a y-up transform).
  A sweep of 2*pi or more draws the closed circle.
- **`polygon`**: a closed ring (the last point joins the first). The fill is
  ear-clipped, so any simple polygon works, convex or concave, either
  winding; a self-intersecting ring still fills (fan fallback) but not by any
  particular rule, so split it at the crossings (a moment diagram that changes
  sign: one polygon per lobe). `stroke` outlines the ring with joined
  segments. Polygons wholly outside the clip cost one bounds scan.

### World transform

`CanvasStyle.transform` (`teak.CanvasTransform{ sx, sy, tx, ty }`) maps every
primitive coordinate to canvas-local px while lowering:
`local = (x * sx + tx, y * sy + ty)`. A negative `sy` gives a y-up world.
Positions and geometric extents transform (rect size, world circle radius,
polygon and polyline points, triangle vertices, text positions); stroke
`thickness`, `marker.size`, `screen_radius` circles and text size stay in
screen px, so lines keep their weight at every zoom.

This is the efficient way to draw large static geometry: build it ONCE in
world units into Model-owned slices, hand the same slices to the canvas each
frame, and pan / zoom by changing only the transform. `view` does no
per-primitive work, the batch `key`s keep the frame diff cheap, and segments,
circles and polygons that fall outside the canvas are culled while lowering.
Helpers for `update`:

```zig
m.xf = teak.CanvasTransform.fit(x0, y0, x1, y1, view_w, view_h, 12, true); // fit a y-up world box
m.xf = m.xf.pan(ev.dx, ev.dy);                                          // drag
m.xf = m.xf.zoomAt(ev.x, ev.y, @exp(-ev.dy * 0.0015));                  // wheel, about the cursor
const world = m.xf.invert(.{ .x = ev.x, .y = ev.y });                   // pick
```

`examples/vector_canvas` draws an 80 100-member frame (20 301 node circles,
supports, moment-diagram polygons, release arcs) this way. `zig build bench`
has a `canvas` row: lowering 80k antialiased segments + 20k circles, all on
screen, takes about 1.8 ms of CPU (ReleaseFast, desktop x64); zoomed in, the
culled frame is cheaper. Every changed frame still re-lowers the whole
canvas on the CPU (there is no GPU-side retained vertex buffer yet).

### Antialiasing

`CanvasStyle.antialias = true` draws polyline, lines, circle, arc and polygon
edges with per-pixel coverage: each stroke segment is one quad whose `u`/`v`
carry the normalised distance to its edges, and the solid-quad shader
(`shaders/quad.wgsl`, vertex mode `a <= -1.5`, alpha = `-2 - a`) turns the
screen-space gradient of that distance into coverage, one device pixel wide at
any DPI. Fills get a one-pixel outer fringe per edge (no double blending of
translucent fills). Strokes thinner than a pixel draw one pixel wide at
proportionally lower alpha. With antialiasing, polylines join their segments
(ends extended into the turn), so thick polylines no longer notch at corners.
Off keeps the historical hard-edged quads pixel for pixel. 3D plane layers
(`scene_layers`) ignore the flag: their shader has no coverage mode.

### Emitters

```zig
cb.canvas(style, primitives);                        // non-interactive, unlabeled
cb.canvasLabeled(style, primitives, label);          // + a11y label
cb.canvasClickable(msg, style, primitives, label);   // + click Msg
cb.canvasInteractive(style, primitives, id, label);  // pointer surface (pan / zoom / drag)
```

### Per-pass behavior

- **Layout**: leaf sized from `style.width`/`height`; `flex` grows it along
  the parent's main axis and a `.stretch` parent stretches it across, so
  `.{ .width = 0, .height = 0, .flex = 1 }` in a stretch column fills the
  remaining space (the `layout` pointer event reports the size).
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
- **snapshot**: one line — `canvas (x,y,w,h) prims=N [xf=(sx,sy,tx,ty)] [aa] [id=N] [pointer] "label"` (a batch counts as one primitive).

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

### Bar, scatter and area charts

Same shape, same rules (pure, arena-allocated, canvas-local px):

```zig
const bars = teak.barChartPrimitives(arena, values, .{ .width = 320, .height = 120, .min = -5, .max = 10,
    .negative_color = cb.theme.palette.danger });
const dots = teak.scatterPrimitives(arena, xs, ys, .{ .width = 320, .height = 120,
    .x_min = 0, .x_max = 100, .y_min = 0, .y_max = 1, .radius = 2.5 });
const area = teak.chart.lineChartPrimitives(arena, series, .{ .width = 320, .height = 120,
    .min = 0, .max = 1, .fill = .{ 0.3, 0.7, 1.0, 0.25 } });
```

Bars grow from `baseline` (default 0, clamped into the range), so negative
values hang below it. Scatter dots are `circle` primitives (one SDF quad
each); points outside the ranges are skipped. `fill` adds a `polygon`
under the line. Set `antialias = true` on the canvas for smooth line and
polygon edges.

## Interactive canvases (pan / zoom / drag)

`cb.canvasInteractive(style, prims, id, label)` marks a canvas as a pointer
surface. `teak.run` (and `teak.Runtime`) then turns raw pointer input over it
into `CanvasEvent`s (`core/pointer.zig`) and hands each to the App's optional
hook, which maps it to an ordinary `Msg`:

```zig
pub fn canvasMsg(m: *const Model, ev: teak.CanvasEvent) ?Msg {
    return Msg{ .viewport = ev };   // update() does the pan / zoom / pick math
}
```

Coordinates are **canvas-local logical px** — the same space as the primitives,
so a pick is just `ev.x, ev.y` run through your own view transform.

| `ev.kind` | When | Notes |
|---|---|---|
| `layout` | First layout, and whenever the canvas rect **size** changes | `w`/`h` carry the size, `x`/`y` = 0. This is how the Model learns the viewport size (the view cannot read layout). Takes effect in the next frame's view. |
| `move` | Cursor moves over the canvas, or while a capture is active | `dx`/`dy` = delta since the previous event for this canvas (0 on the entry move). |
| `down` | A button went down on the canvas | `button` = which one; `buttons` = all held. **Starts a capture.** |
| `up` | A button was released | Delivered to the capturing canvas even if the cursor is outside it. |
| `wheel` | Wheel / trackpad over the canvas | `dx`/`dy` are DOM-signed px (+dy = down). Delivered **instead of** `wheelMsg` / `scrollMsg`. A web pinch is a wheel with `mods.ctrl`. |
| `leave` | The cursor left the canvas and no capture is active | Also sent when a capture ends with the cursor outside. |

**Capture.** A press on a canvas sends it every following `move` / `up` /
`wheel` until *all* buttons are released — a drag that leaves the rect (or the
window: the hosts capture the mouse) still finishes cleanly. A button held
since before the cursor reached the canvas (pressed on, say, a slider) does not
hover it. If the canvas leaves the view mid-capture the capture is dropped.

**Layering.** Routing uses the exact `hitTest` rules against the previous
frame's layout, so a button or overlay in front of the canvas wins, a modal
backdrop blocks it, and a scroll viewport clips it. Pointer canvases need the
`canvasMsg` hook; without it `pointer = true` is inert and the canvas behaves
as a plain one.

`CanvasEvent.mods` / `.buttons` are the shift/ctrl/alt/meta and left/middle/
right state at the event. See the example flow in `docs/features/run.md`.

### Click-only recipe (no capture)

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
- **No Bezier curves, no per-point styling** in the built-in primitives.
  Polylines are straight segments; circles and arcs are the only curves.
  Anything else: tessellate it yourself into `triangles` / `lines` /
  `polygon`.
- **No disabled state.** Drag / zoom live in the app: `canvasMsg` delivers
  the pointer stream, the app keeps the transform in its Model.
- Without `antialias`, polyline joins are unmitred (each segment is an
  independent quad); thick lines show small gaps/overlaps at sharp corners.
  With it, joins are extended (square-capped at turns sharper than 90
  degrees); translucent strokes darken slightly where segments overlap.
- Lowering is CPU work every changed frame (see "World transform").
