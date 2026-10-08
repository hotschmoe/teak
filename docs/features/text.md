# Text

**Status**: shipped, with a short queue of open PRs listed per item below (a row says *master* when it is in
`origin/master`, otherwise *queued* with the PR). `pub` surface: `FontFamily`, `FontWeight`, `FontSpec`,
`DEFAULT_FONT`, `TextMetrics`, `TextMeasurer`, `ShapedGlyph`, `ShapeResult`, `Shaper`, `monoMeasurer`, `unicode`,
`linebreak`, `text_wrap`, `editor` (`Editor`), `TextField`, `TextArea`, `TextEvent`, `NumericField`, and the `text` / `text_area` /
`text_input` Cmds.
**Source**: `src/core/{text,text_wrap,unicode,linebreak,editor,text_field,text_area,text_event}.zig`,
`src/text/*` (the `teak-text` module: faces, shaper, measure), `src/gpu/{glyph_atlas,text_stage}.zig`,
`src/render/build.zig`.
**Design record**: [text-engine.md](text-engine.md) (decisions, measurements, per-PR plan).
**Guides**: [text-area.md](text-area.md) (multi-line editing, self-contained), cookbook recipe 23.

## The supported subset (read this first)

Teak draws and edits **Latin, Greek, Cyrillic and other left-to-right alphabetic text** (CJK too, given a registered face that covers it; the bundled IBM Plex Mono does not) with proper wrapping,
kerning, ligatures (fi fl ff ffi ffl), combining marks, grapheme-aware editing and undo. What that means, precisely:

| Capability | Status |
|---|---|
| Grapheme-correct caret, delete, selection (UAX #29), word motion, line breaking (UAX #14 subset), wrap, ellipsis, shrink | **master** |
| Kerning (kern + GPOS pairs via stb), fi/fl/ffi/ffl ligatures, zero-advance combining marks centred over the base | **master** |
| One rasterizer everywhere (stb_truetype): Linux native and web; Windows still draws through GDI until the Win32 stb path lands | Linux/web **master**; Windows *queued* ([#31](https://github.com/hotschmoe/teak/pull/31)) |
| Font fallback chain across registered families, an app chain and system last-resort faces | *queued* ([#44](https://github.com/hotschmoe/teak/pull/44)) |
| NFC-compose accents when a face lacks U+0301 and friends ("café") | *queued* ([#76](https://github.com/hotschmoe/teak/pull/76)) |
| Scalable (SDF) text for zooming canvases | *queued* ([#66](https://github.com/hotschmoe/teak/pull/66)) |
| Colour emoji (RGBA atlas pages; web via canvas 2D) | *queued* ([#71](https://github.com/hotschmoe/teak/pull/71)); until then emoji draw as monochrome/missing glyphs |
| Bidirectional text (UAX #9): levels, per-line reordering, visual caret | algorithm *queued* ([#74](https://github.com/hotschmoe/teak/pull/74)), rendering + editing *queued* ([#85](https://github.com/hotschmoe/teak/pull/85)); until then right-to-left text is drawn in logical order |
| Complex-script shaping (Arabic joining, Indic reordering, mark positioning) | optional HarfBuzz, off by default, native only, *queued* ([#77](https://github.com/hotschmoe/teak/pull/77)); the built-in shaper does not join or reorder |
| IME composition | X11 (XIM) and Win32: **master**; web bridge *queued* ([#49](https://github.com/hotschmoe/teak/pull/49)) |

So the honest statement for an evaluator: **left-to-right scripts that need no shaping are fully supported; Arabic,
Hebrew and Indic scripts are supported only with the optional HarfBuzz build plus the bidi PRs, and need a face that
covers them (nothing is shipped but IBM Plex Mono).** There is no subpixel LCD anti-aliasing (grayscale only), no
system-font discovery by name (faces are registered explicitly), and no vertical text.

## Vocabulary

| Type | Purpose |
|---|---|
| `FontFamily` | `{ sans, serif, mono }`: a slot, mapped to a registered face (or the build's default). |
| `FontWeight` | `{ regular, medium, bold }`. |
| `FontSpec` | `{ size_px = 14, family = .sans, weight = .regular, letter_spacing = 0, snap_advance = null }`, by value on every text-bearing Cmd. `size_px` is the em size on every backend. `snap_advance` rounds each advance to a whole pixel (null = on for `.mono`). |
| `TextMetrics`, `TextMeasurer` | `measure(text, font)` and `prefixWidth`; the layout pass calls the Host's measurer. `monoMeasurer()` is a stateless 10 px/byte stub for tests and CLI canaries. |
| `Shaper`, `ShapedGlyph`, `ShapeResult` | the shaping interface (below). |
| `TextDraw` | what render emits per run: rect, content, font, colour, clip. |

Weight and `letter_spacing` travel with the font into `TextDraw`; the measurer and the rasterizer share one face table
and one shaper, so layout equals pixels (`sum(advance) == width`).

## Architecture in one picture

```
view -> Cmd(text | text_input | text_area | rich_text) -> layout (text_wrap: wrap, ellipsis, shrink)
     -> render/build: one TextDraw per line (per run for mixed direction)
     -> gpu/text_stage: Shaper -> glyph ids + x  -> GlyphAtlas (R8 pages)  -> one instanced draw per page
```

- **Atlas** (`src/gpu/glyph_atlas.zig`, pure data): R8 coverage pages of 1024x1024, up to 8, shelf-packed, entries keyed
  `(face, glyph id, physical size, x-subpixel bin)`, page-granular eviction. Colour travels in a 32-byte instance, not in
  the texture; one draw per page per layer. Growable instance buffer, no silent cap.
- **Rasterizer**: stb_truetype on Linux (X11 + wgpu) and web (compiled into the wasm, +25 KB raw / 14 KB gzip). Windows
  uses the GDI rasterizer until [#31](https://github.com/hotschmoe/teak/pull/31). HiDPI is handled by rasterizing per
  physical pixel size; text is crisp at any scale factor.
- **Shaper interface** (`core/text.zig`): `shape(text, font, out []ShapedGlyph) ShapeResult` returns glyph ids, pen x,
  advance (kerning and `letter_spacing` folded in) and a source `cluster` per glyph; resumable when `out` fills.
  **SimpleShaper** (`src/text/shaper.zig`): UTF-8 decode, cmap, other registered weights of the family as fallback,
  ligatures, kerning, combining marks. **HarfBuzz** implements the same interface behind `-Dharfbuzz=true`
  ([#77](https://github.com/hotschmoe/teak/pull/77); default build stays dependency-free).
- **Fallback chain** ([#44](https://github.com/hotschmoe/teak/pull/44)): primary face, other weights of the family, other
  registered families, `registerFallbackFace` chain, then system faces (native only; `TEAK_FALLBACK_FONTS` adds paths).
  Missing everywhere draws .notdef, one em wide for wide scripts.
- **Measure caches**: `src/text/measure.zig` caches widths of runs up to 48 bytes in a 1024-slot direct-mapped table keyed
  on the full text and font, invalidated when the face table changes; `text_stage` caches shaped runs across frames.
  Layout of an unchanged screen therefore measures almost nothing.
- **Wrap, ellipsis, shrink** (`core/text_wrap.zig`, pure, allocation-free; [layout.md](layout.md)): `text` takes
  `wrap = none | word | char | ellipsis`, `max_lines`, `text_align`; groups and scrolls take `shrink`. Layout runs two extra
  linear passes only for frames that contain wrapped or shrinkable nodes. Emitters: `paragraph`, `paragraphStyled`
  (wrapped `rich_text` is part of [#44](https://github.com/hotschmoe/teak/pull/44)).
- **Editing stack**: `Editor(cap, undo_cap)` is the pure model (grapheme-aware cursor and selection, word/line motion,
  undo/redo with grouping, `applyPointer`); `TextField(cap)` is the single-line component on it; `TextArea(cap)` is the
  multi-line component ([text-area.md](text-area.md)); `NumericField` parses numbers on top of `TextField`. State lives in
  the Model; layout facts the view cannot read (click to byte index, visual Up/Down/Home/End, wrapped size, caret rect)
  are resolved by the run loop into `TextEvent`s and arrive through the optional `textMsg` hook.
- **IME**: the Host reports the pre-commit string through `imeState()`; render draws it underlined at the caret and the
  run loop tells the Host where the caret is (`setImeSpot`) so the candidate window sits next to it. X11 uses XIM
  (over-the-spot), Win32 uses IMM. The web bridge is [#49](https://github.com/hotschmoe/teak/pull/49).
- **Bidi** ([#74](https://github.com/hotschmoe/teak/pull/74), [#85](https://github.com/hotschmoe/teak/pull/85);
  docs/features/bidi.md arrives with #74): UAX #9 in core; mixed-direction lines draw run by run in visual order; caret, pointer,
  selection rects and Left/Right follow the visual layout; word jumps stay logical.

## Custom fonts

**Web**: register files in the build; they are copied to `dist/fonts/`, declared with `@font-face`, and the app starts
after every face has loaded:

```zig
teak.linkWebWgpu(b, web_exe, .{ .fonts = &.{
    .{ .family = "IBM Plex Mono", .weight = 400, .path = b.path("assets/IBMPlexMono-Regular.ttf") },
    .{ .family = "IBM Plex Mono", .weight = 700, .path = b.path("assets/IBMPlexMono-Bold.ttf") },
} });
```

**Native Linux**: register embedded TTFs on the Host before the first frame (up to three weights per family):

```zig
try host.registerFont(.mono, .regular, @embedFile("plex-Regular"));
try host.registerFont(.mono, .bold, @embedFile("plex-Bold"));
```

A request takes the registered weight nearest the one asked for (lighter on a tie); a family with no registered face uses
the default face (`TEAK_FONT=/path/to.ttf` overrides the system search). `examples/fonts` is the working reference.

## Invariants

- The measurer and the rasterizer use one shaper and one face table: layout width equals drawn width.
- Core never sees a platform type: text reaches the GPU as `TextDraw` data; the atlas and rasterizer live behind the Gpu
  and Host interfaces (HARDLINE hatch 4).
- Editing keeps all state in the Model; the run loop only turns input into data (`TextEvent`), never into mutation.
- Measure, shaping and wrapping allocate nothing per frame.

## Limits

- Atlas: 8 pages of 1024x1024; a frame that needs more evicts the least recently used page.
- Measure cache covers runs of at most 48 bytes; longer runs measure uncached each frame (the run cache in the text stage
  still avoids re-shaping across frames).
- Shaping works in chunks of 256 glyphs; a `TextArea(cap)` / `TextField(cap)` holds at most `cap` bytes; the typed-character
  queue per frame is bounded (excess typing in one frame is dropped with a warning on web).
- `TextArea` remembers metrics for 8 areas at once; more are re-reported when they change.
- No subpixel LCD rendering, no vertical text, no font discovery by name, no hyphenation, no per-run tab stops.
- Text is UTF-8; invalid bytes decode as U+FFFD one byte at a time and never crash layout or editing (fuzz-tested).
