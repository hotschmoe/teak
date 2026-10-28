# SVG icons

**Status**: `pub` in `src/teak.zig` as `teak.svg` (`rasterize`, `rasterizeInto`, `Options`, `Error`)
**Source**: `src/core/svg.zig` (pure, std only, no platform code)
**Tests**: colocated `test` blocks; `examples/vector_canvas` (toolbar icons)

`teak.svg` rasterizes a practical SVG subset on the CPU into RGBA8 pixels.
The pixels go to the GPU as an **image resource** (HARDLINE §2 hatch 8) and
are drawn with the ordinary `image` Cmd. No new Cmd, no new shader.

```zig
// Once (init / update), into Model-owned memory:
try teak.svg.rasterizeInto(gpa, icon_src, 40, 40, &m.icon_px, .{ .color = .{ 1, 1, 1, 1 } });
m.icon_res = .{ .image = .{ .key = ICON_FIT, .rev = 1, .width = 40, .height = 40, .rgba = &m.icon_px } };

pub fn resources(m: *const Model) []const teak.Resource { return (&m.icon_res)[0..1]; }

// view: drawn at 20 logical px (sharp at 2x), tinted to the theme.
cb.image(ICON_FIT, .{ .width = 20, .height = 20, .tint = cb.theme.palette.fg });
```

Rasterize white (`currentColor` = white) and tint the image to recolour a
monochrome icon set with the theme. Rasterize at the largest scale you expect
(2x the logical size covers HiDPI) or re-rasterize when the scale changes.
Never rasterize in `view` (it allocates scratch and costs real time).

## Supported subset

- Elements: `svg` (`viewBox`, else `width` / `height`; scaled uniformly and
  centred, i.e. `preserveAspectRatio="xMidYMid meet"`), `g`, `path`, `rect`
  (with `rx` / `ry`), `circle`, `ellipse`, `line`, `polyline`, `polygon`.
- Path data: every command (`M L H V C S Q T A Z`, absolute and relative,
  implicit repeats, packed numbers like `1-2.5.5`, packed arc flags).
- Paint: `fill`, `stroke`, `stroke-width`, `fill-rule` (`nonzero` /
  `evenodd`), `stroke-linecap` (`butt` / `round` / `square`),
  `stroke-linejoin` (`miter` with limit 4 / `round` / `bevel`), `opacity`,
  `fill-opacity`, `stroke-opacity`; as attributes or in `style="..."`;
  inherited through `g`.
- Colours: `#rgb`, `#rrggbb`, `rgb(r, g, b)`, `none`, `currentColor`
  (`Options.color`) and a few names (black, white, red, green, blue, gray,
  yellow, orange).
- `transform`: `matrix`, `translate`, `scale`, `rotate` (with centre),
  `skewX`, `skewY`, composed through groups.

Skipped silently: `defs`, gradients (`url(...)` paints keep the inherited
paint), patterns, masks, clip paths, filters, `text`, `use`, CSS classes,
dash arrays. Input that has no `<svg>` element fails with `error.InvalidSvg`.
That covers the usual line and solid icon sets (Lucide, Feather, Heroicons,
Tabler, Material).

## Quality and cost

Curves are flattened to about a quarter pixel. Each fill or stroke is
scan-converted with 8 sub-scanlines per pixel and exact horizontal coverage
under its fill rule, then composited "over" in document order (straight
alpha; fully transparent pixels take the paint's colour so bilinear sampling
does not darken edges). Strokes are outlined (segment quads plus joins and
caps) and filled nonzero, so self-overlapping strokes do not double-blend.
A 24-unit icon at 40 px rasterizes in well under a millisecond.

## Non-goals

A full SVG renderer (resvg-class) is out of scope: no text, no filters, no
gradients yet. Gradients and `use` are the likely next additions if an icon
set needs them.
