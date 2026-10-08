# Text engine (M1 design)

**Status**: DESIGN SPIKE. Nothing here is implemented; this document is the
plan for review milestone M1 ("make-or-break", `docs/REVIEW-2026-10.md`).
It replaces the "per-string texture" text path described in
[text.md](text.md) and closes issues
[#6](https://github.com/hotschmoe/teak/issues/6) (text widgets) and
[#8](https://github.com/hotschmoe/teak/issues/8) (wrap + flex shrink), and the
256-run defect in review §3.5.

**Measurements** in this document were taken on the dev box (aarch64 Linux,
Zig 0.16, `-O2`/`ReleaseFast`/`ReleaseSmall` as stated, DejaVuSansMono).
Scratch sources are not committed; each number says how to re-measure it.

> **Status (PR8/PR9):** wrap + shrink in layout and per-line render are implemented; `cb.wrap_nodes` was not needed (pass 1 detects wrapped nodes itself) and the text field is `text_align` (`align` is a Zig keyword). See layout.md.

## 0. Summary of decisions

| # | Question | Decision |
|---|---|---|
| 1 | Glyph storage | One R8 coverage **glyph atlas** (1024x1024 pages, up to 8), per-glyph entries keyed `(face, glyph id, physical size, x-subpixel bin)`. Shelf packing, page-granular eviction. Colour travels in a 32-byte **instance**, not in the texture. One draw per page per layer. |
| 2 | Vertex buffer | Instanced quads (`step_mode = instance`, 6 vertices generated in the vertex shader), **growable** (power-of-two realloc). No silent cap: hard limit 4M glyphs/frame, loud `std.log.err` when hit. |
| 3 | Web rasterizer | **(b) stb_truetype compiled into the wasm**. Measured cost: **+25.5 KB raw / 14.3 KB gzip** (kerning, +SDF: 30.8 KB / 16.7 KB). Canvas2D stays as an optional per-cluster *fallback* for glyphs the shipped fonts lack (CJK, emoji). |
| 4 | One rasterizer everywhere | stb on Linux, Windows and web, so layout == render == golden screenshots on every target. GDI becomes an optional fallback provider, deleted once Windows parity is verified. |
| 5 | SDF / MSDF | **Not now.** Coverage atlas rasterized per physical pixel size (HiDPI-aware). The instance carries a `mode` bit so a single-channel SDF page kind can be added for zooming canvas text without a format change. |
| 6 | Shaping | Core defines a **`Shaper` interface** (`runs -> positioned glyph ids`). Built-in `SimpleShaper` (pure Zig over stb tables): UTF-8 decode, cmap, pair kerning (kern + GPOS via stb), fi/fl/ffi/ffl ligatures via the Unicode presentation-form glyphs, per-codepoint face fallback. HarfBuzz can implement the same interface later. |
| 7 | Wrap | Layout gains **constraint passing** without a tree: two extra linear passes (resolve widths top-down, re-measure heights bottom-up) that are skipped when no node is wrapped or shrinkable. `TextCmd` gets `wrap`/`max_lines`; groups/leaves get `shrink` + a text `min-content`. |
| 8 | Editor | `Editor(cap)` pure model in core (promoted from Kerf, grapheme-aware, undo/redo, word/line motion), a `text_area` Cmd, and an App hook `textMsg` (twin of `canvasMsg`) that turns pointer input into **caret byte indices as data**. Bidi: logical-order movement, never crashes, no visual reordering. |
| 9 | Perf | Targets in §8. Measured: 100k glyph instances in **0.74 ms** (warm atlas, 2.8 MB upload); stb rasterizes a 14 px glyph in **3.2 us** (so 95 ASCII glyphs x 4 bins warm in about 1.2 ms, once). |

## 1. Where the current path breaks

Read end to end (file:line as of `d6f4d34`):

1. `render/build.zig` `emitText` appends one `TextDraw{content, font, color, rect, clip}` per string.
2. `wgpu_core.uploadText` (`src/gpu/wgpu_core.zig:924`) calls `rasterizeText` for each
   draw: the **whole string** is rasterized to a BGRA texture sized to the (integer-snapped) rect, cached in
   `glyph_cache.GlyphCache` (256 entries, linear LRU scan), each entry owning **one `WGPUTexture`, one view and one bind
   group**. Colour is baked into the bitmap as well as sent in the vertex.
3. The text vertex array is `[glyph_cache.CAPACITY * 6]Vertex` and the loop does
   `if (offset + 6 > self.text_verts.len) break; // text buffer full` (line 988). Beyond 256 runs text silently
   disappears (verified with `~/github/ws/ref/textstress.zig`: 640 runs, rows 15+ blank). `web.zig`
   has the same `TEXT_VERT_BUF_CAPACITY`.
4. Even without the cap, a cyclic working set of more than 256 distinct (string, font, colour, size) keys thrashes: every
   frame creates and destroys textures and bind groups.
5. `textCacheKey` (`glyph_cache.zig:~45`) XORs a Wyhash of the text with font/colour/size bits and **never compares the
   content on a hit**, so a collision displays the wrong string; it also truncates `size_px` to an integer, so 11.4 and
   11.9 share a key (only the pixel-size of the rect protects them).
6. Web: `zunk` `rasterize_text` (`src/gen/js_resolve.zig`) resizes a canvas, `fillText`s the string, `getImageData`s it
   (a GPU->CPU readback when the canvas is accelerated) and creates a **new GPUTexture per string**. `measure_text`
   crosses the JS boundary on every measurement; the Host caches by `FontSpec` but a first frame with 10k labels makes 10k
   calls.
7. Layout measures through `TextMeasurer` (`layout/engine.zig:297`) once per text node; render measures again
   (`emitText`); both are single-line only. There is no way to ask "height for width".
8. Native Linux and web disagree on glyph advances by construction (stb vs the browser's text engine), and Windows
   uses GDI with no `letter_spacing`. Golden screenshots cannot be shared across platforms.

## 2. Architecture and HARDLINE placement

```
                      core/ (pure, platform-free)                 Host layer (hatch 4)
 TextCmd / TextAreaCmd --+                                    +-- teak-text module (src/text/)
 FontSpec                |  layout/engine --- TextMeasurer ---+     Face (stb parse), SimpleShaper,
 core/text.zig:          |  render/build  --- TextMeasurer ---+     MeasureCache, rasterizeGlyph
   Shaper, ShapedGlyph   |  input/hit_test -- (runtime resolves caret via TextMeasurer)
   TextMeasurer          |                                    +-- gpu/: GlyphAtlas, instance upload
 core/text_wrap.zig  <---+  (wrap, line-break, caret math:     +-- platform/: font loading, clipboard
 core/editor.zig         |   pure functions of text + measurer)
```

Rules this design follows (HARDLINE §1/§3/§5):

* **Fonts, shaping state, atlas pages, measure caches are Host-layer state** (`src/text/`, `src/gpu/`, `src/platform/`).
  Hatch 4(d) explicitly permits extending `validateHost`/`validateGpu` with new platform-owned concerns; this is such an
  extension, not a new hatch.
* **Core sees data and interface values only.** `TextMeasurer` already is one; it gains optional entries
  (`measure_wrapped`, `caret_at`) and a `Shaper` sibling. No fn pointer lives on a `Cmd`.
* **`view` stays pure and allocation-parameter free.** `view` emits a `text_area` Cmd carrying *Model data* (content
  slice, caret, selection, scroll offset). It never wraps text: wrapping needs the final width, which only layout has.
* **Passes stay independent.** Layout, render and the runtime's caret resolution all call the *same pure function*
  (`text_wrap.layoutLines(text, font, max_w, measurer)`) with the same inputs, so they agree without sharing state.
* **No ID hashing, no retained widget state.** Glyph atlas keys hash `(face, glyph, size, bin)`, which is *resource*
  identity (like the existing glyph cache and `resources` hatch 8), never widget identity.
* **No wall clock in `view`.** Click-count and caret blink use `Host.nowMs()` in the runtime / `Sub`.

Two items need an explicit sign-off in review because they touch invariants:

* **S1: the `textMsg` pointer hook** (section 6.4). Same shape as `canvasMsg` (data in, optional `Msg` out, capture while
  dragging). I argue it is the interactive-surface pattern already blessed for `canvas`, not a new hatch, but HARDLINE
  §2 should gain a one-line mention next to hatch 4(d) when it lands.
* **S2: layout is no longer exactly two passes.** Hatch 3 says "two O(n) linear passes". The wrap design adds two more
  linear stack passes that are skipped for frames with no wrapped/shrinkable node. Still flat buffer, still explicit
  stack, no tree. HARDLINE §2 hatch 3 and `docs/features/layout.md` need an "up to four passes" amendment (PR8).

## 3. Glyph atlas (render + both GPU backends)

### 3.1 Data flow

```
render/build.zig        gpu/ (per backend)                                  GPU
TextDraw (string run) -> Shaper.shape -> []ShapedGlyph
                       -> GlyphAtlas.lookup((face,gid,size,bin)) -> rect | miss
                       miss -> Rasterizer.rasterizeGlyph -> R8 bitmap -> atlas page (CPU staging, dirty rect)
                       -> Instance{x,y,w,h,u,v,color,clip,page} appended to per-page lists
                       frame end: flush dirty rects (writeTexture), upload instance buffer
                       renderFrame: per layer, per page: setBindGroup(page), draw(6, n, 0, first)
```

`TextDraw` remains the render-pass output (positioned in logical px, one font, one colour *or* a colour-span list, see 6.5).
The **Gpu** turns it into glyph instances. This keeps `render/` free of font data (it only needs the measurer it already
gets) and keeps one shaping implementation (the Host's) feeding both measurement and drawing.

### 3.2 Entry key and subpixel positioning

```zig
pub const GlyphKey = packed struct(u64) {
    face: u16,        // index into the Host face table (family x weight x fallback slot)
    glyph: u16,       // glyph id (TrueType glyph ids fit in u16)
    size_q: u16,      // physical pixel size in 1/4 px: round(size_px * scale * 4)
    bin: u2,          // x subpixel bin 0..3 (0.25 px steps); 0 for grid-snapped faces
    mode: u2,         // 0 = coverage, 1 = sdf (reserved)
    _pad: u10 = 0,
};
```

* Lookup is an open-addressing table (power-of-two, linear probe) from the 64-bit key to
  `{page: u8, gen: u8, x,y: u16, w,h: u16, bearing_x,bearing_y: i16}`. The key is **compared in full** (no hash-only
  identity, which fixes defect 5 above).
* **x subpixel**: the pen position is fractional; the fractional part picks one of 4 bins, the integer part positions
  the quad. y is rounded to the pixel (baseline snap), like every UI toolkit does. Cost of 4 bins: up to 4x atlas area
  for proportional text (still tiny, see 3.4). Monospace families default to **integer-snapped advances with one bin**
  (`round(advance)`), applied identically in measurer and shaper. That gives the crisp terminal-grid look Kerf's
  IBM Plex Mono design wants (`spec/DESIGN.md`), at the price of up to ~3% width drift from the font's design advance
  (7.8 px at 13 px becomes 8 px). `FontSpec.snap_advance: bool` (default true for `.mono`, false otherwise) is the
  override; it is part of the key through `bin == 0` and of the measure cache key.
* `size_q` uses the **physical** size (`size_px * scale`), so HiDPI renders true device pixels instead of scaling a
  low-res bitmap. Layout and shaping run at logical size with the unhinted scale `size_px / units_per_em`, then positions
  are multiplied by `scale`. Today `Host.scaleFactor()` exists but the quad pass does not render at scale
  (`platform/host.zig:201`); the text engine takes `scale` as a Gpu parameter and the end-to-end switch is PR4's
  acceptance item. Animated sizes should round to `size_q` steps or use the SDF page (3.6).
* Rasterization uses `stbtt_GetGlyphBitmapSubpixel(scale, scale, shift_x = bin/4, 0, gid)` so the bin is a real subpixel
  offset. Padding: 1 px around every glyph to keep bilinear sampling from bleeding neighbours; sampling is `nearest`
  (quads are pixel-aligned in x and y after binning, so there is nothing to interpolate).

### 3.3 Packing and eviction

* Pages are R8Unorm, 1024x1024 (1 MiB each). Start with one page; `GpuOptions.max_atlas_pages` (default 8, 8 MiB).
  Pages are allocated lazily; a headless/test Gpu with no text allocates none.
* **Shelf packer** per page (rows of fixed height chosen on first use, glyph height rounded up to 4 px classes; a new
  shelf is opened when no shelf of that class has room). Simpler and faster than skyline for a glyph population that is
  almost entirely a few size classes; waste measured below. If measurement of real apps shows more than 25% waste,
  swap to skyline-bottom-left behind the same `Packer` interface (it is one file, `gpu/glyph_atlas.zig`).
* **Eviction is page-granular**, not per glyph. Each page has `last_used_frame` (stamped when any instance referencing it
  is emitted) and a `gen` counter. When a glyph does not fit:
  1. open a new page if `pages < max`;
  2. else reset the page with the oldest `last_used_frame < current_frame`: bump its `gen` (all its table entries become
     stale in O(1): an entry is valid only if `entry.gen == page.gen`), clear the packer, mark the page fully dirty;
  3. else (every page was used this frame): `std.log.err` once per second naming the cap and drop that glyph for the
     frame (renders as a gap). This is the only silent-ish failure path left and it is loud, documented and
     configurable. It needs more than 8 MiB of distinct glyphs *in one frame*.
  Thrash cost is bounded and cheap: re-rasterizing a glyph is about 3 us.
* No per-glyph LRU: it needs a free-list allocator with fragmentation handling for no real gain at these sizes.

### 3.4 Size budget (why 8 pages is plenty)

Average 14 px glyph bitmap is about 9x11 = 100 B plus a 1 px border (about 130 B). ASCII (95) x 4 bins x one size is
about 50 KB. A CJK app with 3000 distinct 16 px glyphs x 1 bin is about 1 MB: one page. The 640-run stress screen uses a
few dozen distinct glyphs. `tools/bench-text` (PR14) reports pages used for a real corpus so the default can be tuned.

### 3.5 Instance format, shader, draws

```zig
pub const GlyphInstance = extern struct {   // 32 bytes
    x: f32, y: f32,                // quad top-left, physical px, already bearing-adjusted and bin-snapped
    w: u16, h: u16,                // quad size in px == atlas rect size
    u: u16, v: u16,                // atlas texel origin of the glyph rect
    color: u32,                    // RGBA8 (premultiplied-free; alpha scales coverage)
    clip_xy: [2]i16, clip_wh: [2]u16, // scroll clip in physical px (4 x 16 bit); 0,0,0,0 = unclipped
    flags: u32,                    // bit0-1 mode (coverage/sdf), bits 8+ reserved (underline thickness etc.)
};
```

Vertex layout: one instance buffer, `step_mode = instance`, attributes `Float32x2, Uint16x2, Uint16x2, Unorm8x4,
Sint16x2, Uint16x2, Uint32`. `draw(6, instance_count, 0, first_instance)`. `wgpu_scene.zig` already uses instance
stepping on native and zunk exposes `VertexStepMode.instance`, so no new capability is needed on either backend.

```wgsl
@vertex fn vs(@builtin(vertex_index) vi: u32, inst: Inst) -> VOut {
    let c = vec2f(f32(vi & 1u), f32((vi >> 1u) & 1u));            // triangle-strip-style corner from 6 indices
    let px = inst.pos + c * vec2f(inst.size);
    let uv = (vec2f(inst.uv_origin) + c * vec2f(inst.size)) * uniforms.inv_atlas_size;
    ...
}
@fragment fn fs(in: VOut) -> @location(0) vec4f {
    if (in.clip_w != 0 && !inside(in.frag_px, in.clip)) { discard; }
    let cov = textureSample(atlas, nearest, in.uv).r;
    return vec4f(in.color.rgb, in.color.a * pow(cov, uniforms.text_gamma)); // text_gamma defaults 1.0; 0.8 thickens light-on-dark
}
```

* **One bind group per atlas page** (uniform + page texture + sampler), created when the page is. Draw count per frame is
  `layers x pages` (usually 2), instead of one texture + bind group per string.
* Layers: the existing `overlay.Marker` split (`gpu/overlay.zig`) is preserved by keeping per-layer instance ranges;
  instances are bucketed `(layer, page)` with a counting sort over the frame's glyphs (no `std.sort`).
* Partial clip is done per glyph in the fragment shader against the instance clip (fully-outside glyphs are culled on the
  CPU), which also fixes the current "snap rect + clip to integer pixels and compute UVs" dance in `uploadText`.
* Colour: in the stream, so identical text in 10 colours costs 0 extra atlas space (the current cache stores one
  texture per colour).

### 3.6 SDF / MSDF decision

**Shipped (PR15): `FontSpec.scalable`.** Scalable text uses glyph key `mode = 1` at a fixed 32 px source size; the SDF bitmaps live in the *same*
R8 pages as coverage glyphs (the instance's `flags` pick the shader branch, so no second page kind was needed). The quad is drawn at
`size_px * scale / 32` times the stored size (scale in `flags` bits 16-31, 1/256 units) at an unsnapped position, sampled bilinearly and cut with
`smoothstep(0.502 +- 0.7 * fwidth(d))`. The stb cubic solver needs cbrt/cos/acos; the wasm build carries small polynomial/Newton versions
(`src/text/stb_wasm_impl.c`) instead of libm. The original analysis follows.

**Recommendation: coverage atlas now; SDF page kind later and only for zoomable canvas text.**

Evidence and reasoning:

* stb's `stbtt_GetCodepointSDF` is free to integrate but measured **339 us/glyph** (28 px source, 6 px padding,
  DejaVuSansMono, `-O2`) against **3.2 us/glyph** for the 14 px coverage bitmap: 100x slower rasterization, and it needs
  about 3x the atlas area at small sizes (padding). A CJK page flip of 3000 glyphs would cost 1 s instead of 10 ms.
* Quality: single-channel SDF rounds sharp corners and blurs stems at small sizes; UI text is dominated by 11-16 px
  where hinting-free coverage at the exact pixel size with subpixel x bins looks better than SDF magnification. The retro
  Plex-Mono-on-grid look wants the opposite of SDF smoothing.
* SDF's win is *one bitmap for many sizes*, which matters for continuously zooming content: Kerf's 3D/CAD view and the
  `viewport` example's canvas text. A zoom animation on a coverage atlas re-rasterizes per `size_q` step, which is
  acceptable (3 us/glyph) if `size_q` is quantized to 1/4 px and the animation lasts 200 ms.
* HiDPI is handled by rasterizing at physical size, which SDF is not needed for.

Shader changes when it is added (PR15, optional): `mode == 1` samples the SDF page and applies
`smoothstep(0.5 - w, 0.5 + w, d)` with `w = fwidth(d)`; the glyph key already has `mode`; SDF pages are a second page
kind in the same table (fixed 32 px source, padding 6, on-edge value 128, pixel_dist_scale 32 as in the measurement).
MSDF (needs an offline generator and a 3-channel page) is rejected: it needs an outline pipeline that stb does not give us.

## 4. Web: stb in wasm vs canvas2D glyph rasterization

Both designs use the same atlas, shader, instance format and Gpu core; they differ in who produces R8 glyph bitmaps and
metrics.

| | (a) canvas2D into atlas | (b) stb_truetype in wasm |
|---|---|---|
| Glyph bitmap source | JS `fillText` per glyph, `getImageData`/`copyExternalImageToTexture` | `stbtt_GetGlyphBitmapSubpixel` in wasm linear memory, `writeTexture` region |
| Per-glyph cost | JS boundary + canvas readback (tens of us, GPU->CPU sync if accelerated) | about 3 us, no boundary |
| Measure | `measureText` over JS boundary per string; browser kerning/ligatures differ from native | in-wasm, identical to native; cacheable |
| Cross-platform determinism | no (browser text stack; subpixel/gamma vary by OS) | yes: same Zig code and same TTF bytes everywhere, golden screenshots portable |
| Fonts | system fonts, emoji, CJK, fallback for free | only the TTFs the app ships (Kerf already ships 410 KB) |
| Wasm size | 0 | **+25.5 KB raw / 14.3 KB gzip** (see below) |
| Atlas upload | needs sub-rect copy | needs sub-rect copy (new zunk extern, below) |

**Measured wasm cost of (b)** (`zig build-exe -target wasm32-freestanding -OReleaseSmall -fstrip -fno-entry`, vendored
`src/gpu/vendor/stb_truetype.h`, freestanding shims: bump allocator, `pow`/`cos`/`fmod`/`acos` from `std.math`, `assert`
disabled; gzip -9, brotli not installed here so brotli would be smaller still):

| Variant | raw | gzip |
|---|---|---|
| bitmap + metrics, no kerning, no SDF | 25,470 B | 14,264 B |
| + kerning (`GetCodepointKernAdvance`, kern + GPOS) | 27,139 B | 14,924 B |
| + SDF (`GetCodepointSDF`, pulls pow/cos/acos/fmod) | 30,750 B | 16,730 B |

Against the roughly 1 MB raw / 300 KB brotli framework baseline in review §3.4 that is about 3% raw, and it *replaces*
the zunk canvas text JS. Re-measure: the commands are in PR7's acceptance item.

**Decision: (b) as the primary path, (a) as the fallback for glyphs the app's fonts lack.**

* (b) buys the property that matters for a framework whose pitch is determinism: `layout == render` and identical pixels
  on web, X11 and Windows, which also makes `teak.snapshot` and screenshot goldens meaningful across targets.
* Fallback: `Shaper` reports `gid == 0` for an unmapped codepoint. On web the Gpu then asks zunk for a **cluster
  bitmap** (`zunk_text_raster_cluster(utf8, font_css, size_px, out_ptr, out_cap) -> {w,h,bearing_x,bearing_y,advance}`):
  canvas2D draws the cluster in white on transparent, JS writes the alpha channel into wasm memory, Zig uploads it as a
  glyph with a synthetic key (`face = 0xFFFF`, `glyph` = hash of the cluster, small cache). Colour emoji need an RGBA
  page kind (flags bit 2) and (shipped in PR16: a second atlas of RGBA pages, glyph key / instance mode 2; native colour sources need a sbix/CBDT PNG decoder) - the original plan follows: they render as the coverage of the glyph's
  alpha, which is acceptable for monochrome symbols and wrong for colour emoji.
* The font bytes reach wasm through the existing asset fetch (`zunk.web.asset.fetch`) plus `registerFont` (same as
  the X11 Host) so the app does not start before faces are in memory, as `web_font.zig` already guarantees today.
* New zunk surface needed (PR6): `writeTextureRegion(tex, x, y, w, h, ptr, bytes_per_row)` (the current
  `zunk_gpu_write_texture` writes the full texture; `queue.writeTexture` already takes an origin in WebGPU),
  growable buffers (`createBuffer` + `writeBuffer` exist; teak adds the realloc policy), and the cluster-raster
  fallback import. `TextureFormat.r8unorm` already exists in zunk.

## 5. Shaping

### 5.1 Interface (core, platform-free data)

```zig
// core/text.zig
pub const ShapedGlyph = extern struct {
    glyph: u16,        // glyph id in `face`
    face: u16,         // face-table index (fallback chain slot already resolved)
    cluster: u32,      // byte offset in the source text where this glyph's cluster starts
    x: f32,            // pen x BEFORE this glyph, in logical px, run-relative (includes kerning + letter_spacing)
    advance: f32,      // logical px
};

pub const Shaper = struct {
    ctx: *anyopaque,
    /// Fills `out` with at most out.len glyphs for `text` in `font`; returns {count, width, consumed_bytes}.
    /// No allocation. If the caller's buffer is full, `consumed_bytes < text.len` and the caller continues from there
    /// (shaping resumes on a cluster boundary).
    shape_fn: *const fn (ctx: *anyopaque, text: []const u8, font: FontSpec, out: []ShapedGlyph) ShapeResult,
};
```

An interface value like `TextMeasurer` (HARDLINE §4 text: interface values are how core calls into the Host layer). The
measurer is re-expressed on top of it: `measure(text, font) = sum(advances)`, so there is exactly one place advances
come from. `TextMeasurer` keeps its current methods and gains

* `caret_x(text, font, byte_index) f32` (generalizes `prefixWidth`, ligature-aware: inside a ligature the caret is
  interpolated by code-point count),
* `index_at_x(text, font, x) usize` (nearest grapheme boundary; used by click-to-caret),
* `measure_wrapped` (section 7), defaulted to the pure-core implementation over `measure`.

`monoMeasurer` implements all of them trivially so existing layout tests do not move.

### 5.2 Built-in `SimpleShaper` (`src/text/shaper.zig`)

Pure Zig over a `Face` (the stb parse that today lives in `gpu/text_stbtt.zig`, moved into the shared `teak-text`
module so the Host measurer and every Gpu use the same code):

1. Decode UTF-8 (invalid bytes become U+FFFD, one unit per bad byte, never reading out of bounds).
2. Per code point: `stbtt_FindGlyphIndex`; `gid == 0` walks the family's fallback chain (`FontFamily` maps to an ordered
   list of faces; the first face holding the codepoint wins, cluster-wise for combining sequences).
3. Ligatures: after mapping, if the face's cmap has the presentation-form code points, rewrite `f`+`i` -> U+FB01,
   `f`+`l` -> U+FB02, `f`+`f`+`i` -> U+FB03, `f`+`f`+`l` -> U+FB04, `f`+`f` -> U+FB00. No GSUB parsing; faces without
   those glyphs simply do not ligate. Disabled when `letter_spacing != 0` (CSS rule) and for monospace families (a
   ligature must not break the grid).
4. Kerning: `stbtt_GetGlyphKernAdvance(face, left, right)` for each adjacent glyph pair in the same face. stb 1.19+ reads
   both the legacy `kern` table and GPOS PairAdjustment formats 1 and 2, covering virtually all Latin kerning; cost
   measured at 0.056 us per lookup. Mark-attachment, contextual alternates, Indic/Arabic shaping are not supported.
5. Advance: `advance = hmtx_advance * scale + kern * scale + letter_spacing`, then `round` if `snap_advance`.
6. Output ordering: **logical order, left to right**. See 6.6 for the bidi consequence.

Determinism: no floating-point `@sin`/`pow` in this path, only multiplications, so native/web/Windows agree bit for bit
modulo the compiler's fused-multiply-add choices; tests compare to 1/64 px.

### 5.3 HarfBuzz later

`Shaper` is the seam. A `HarfBuzzShaper` (translate-c, vendored hb-ot subset, FreeType not required if glyph
rasterization stays stb) fills the same `[]ShapedGlyph` and the same atlas keys apply (glyph ids are glyph ids). What it
adds that `SimpleShaper` cannot: Arabic/Indic joining and reordering, GSUB ligatures/alternates, mark positioning.
What it costs: a C++ dependency (hb is C++), a few hundred KB of wasm, and it forces the *itemizer* work (script runs,
bidi runs, font fallback segmentation) that §6.6 declares out of scope for M1. The review's "font stack decision" is
therefore: **M1 ships "Latin + CJK-without-shaping" and says so in the README**; HarfBuzz is an additive PR behind the
existing interface, not a rewrite.

### 5.4 GDI vs stb vs canvas2D

* stb everywhere is the default (decision 4). Linux already runs it; Windows reads system TTFs by path probe
  (`%WINDIR%\Fonts\consola.ttf`, `segoeui.ttf`; `TEAK_FONT` override), exactly as `text_stbtt.loadSystem` does on Linux.
* `raster_gdi.zig` becomes a fallback provider behind the existing comptime `Rasterizer` parameter of
  `wgpu_core.Gpu(Surface, Rasterizer)`. The contract changes from "string -> BGRA bitmap" to
  `rasterizeGlyph(face, gid, size_q, bin) -> GlyphBitmap(R8)`. Deleting GDI after parity is verified removes 300 lines
  and the missing-`letter_spacing` gap (review gap 7).
* canvas2D is retained only for the cluster fallback (section 4).
* `TextMeasurer` implementations collapse to one (`teak-text`'s) on all platforms; the Win32 and wasm Hosts stop
  carrying their own measurers.

## 6. The text-editing stack

### 6.1 `Editor(cap)` model (promoted from Kerf)

Kerf's `apps/teak/src/app/editor.zig` is a fixed-capacity `[4096]u8` single-line buffer with `cursor`, `anchor`, UTF-8
stepping, word jumps, Home/End/Delete and a `window(max_cols)` helper. Issue #6 asks to upstream it. M1 generalizes it:

```zig
// core/editor.zig
pub fn Editor(comptime cap: usize, comptime undo_cap: usize) type { return struct {
    buf: [cap]u8 = undefined, len: usize = 0,
    cursor: usize = 0, anchor: ?usize = null,      // byte offsets, ALWAYS on grapheme boundaries
    goal_x: ?f32 = null,                            // sticky column for up/down (logical px, set by textMsg metrics)
    undo: UndoLog(undo_cap) = .{},                  // fixed ring of edit records + their bytes
    // ... pure methods: insert, replaceSelection, backspace, delete, move, setSelection, undo, redo
}; }
```

* **Everything in the component Model, nothing hidden**: buffer, cursor, selection, undo ring, scroll offsets, preedit.
  The Model is large (64 KB buffers are normal); the documented pitfall (slices into a by-value Model copy,
  `docs/pitfalls.md`) applies: `content()` returns a slice into `self`, so update must be called on the live Model.
  An arena-backed rope for megabyte documents is explicitly out of scope.
* **Invariants** (property-tested, section 10): `0 <= cursor <= len`, `cursor` and `anchor` on grapheme boundaries,
  `buf[0..len]` is whatever the user typed (invalid UTF-8 is tolerated, each bad byte counts as one unit), no operation
  can split a multi-byte sequence. This fixes issue #6's "backspace can split a multi-byte character" (current
  `TextField` edits bytes).
* **Graphemes**: `core/unicode.zig` implements the UAX#29 subset that matters for text entry: CR LF, Extend (combining
  marks U+0300-036F and the BMP ranges), ZWJ sequences, variation selectors FE0E/FE0F, emoji modifiers, regional-indicator
  pairs, Hangul L/V/T syllable composition, Prepend/SpacingMark for Indic. Tables are generated by
  `tools/gen_unicode.zig` from checked-in UCD excerpts into a compact range table (about 6-8 KB), committed as
  `core/unicode_tables.zig`; the generator is not run in the normal build.
* **Word jumps** (Ctrl+Left/Right, double-click): classes whitespace / word (letters, digits, `_`, any non-ASCII
  letter) / punctuation, CJK ideographs one per word. Ctrl+Backspace/Delete delete to the same boundaries.
* **Motions**: left/right (grapheme), word, home/end (visual line start/end when wrapped, using the line table from
  7.2; with `ctrl` the document start/end), up/down (sticky `goal_x`), page up/down, select-all, plus every
  shift-variant. `SpecialKey` (`input/keys.zig`) gains `delete`, `home`, `end`, `page_up`, `page_down`, `ctrl_z`, `ctrl_y`,
  `ctrl_shift_z`, word-jump chords; `input_queue.resolveKey` stays the single Shift/Ctrl policy point.
* **Undo/redo**: records `{pos, removed_len, inserted_len}` with the removed/inserted bytes in a fixed byte ring;
  consecutive single-grapheme inserts within one word coalesce into one record; any cursor move or non-adjacent edit
  closes the group. Overflow drops the oldest records (loudly: `UndoLog.dropped` counter in the Model for a status line).
* **Clipboard**: Host `Clipboard` stays the owner; `keyNeedsClipboard` / `textFieldReplaceSelection` pattern extends to
  `ctrl+x/c/v` on the area; paste is bounded by remaining capacity and truncated on a grapheme boundary.
* `TextField(cap)` becomes a thin single-line wrapper over the same `Editor` (newline rejected, horizontal scroll via
  `scroll_x`), so the old byte-editing code is deleted, not duplicated; its `Msg` names stay for compatibility with the
  dispatch helpers.

### 6.2 `text_area` Cmd and rendering

```zig
pub fn TextAreaCmd(comptime Msg: type) type { return struct {
    id: u32,                       // distinct non-zero, like canvas
    content: []const u8,
    cursor: usize, anchor: ?usize = null,
    scroll_x: f32 = 0, scroll_y: f32 = 0,    // from Model
    preedit: []const u8 = "", preedit_cursor: usize = 0,
    wrap: Wrap = .word,            // .none gives a horizontally scrolling code-style editor
    font: FontSpec = DEFAULT_FONT,
    style: TextAreaStyle = .{},    // colours, padding, line_height, caret width, selection colour
    colors: []const ColorSpan = &.{},   // optional per-range colour (syntax highlight); same font, so no re-shaping
    focus_msg: Msg,                // click focuses (as text_input)
    disabled: bool = false,
}; }
```

Single-line `text_input` stays as is (it keeps the cheap path). `text_area` is a genuinely new variant, so it follows the
full widget checklist in `CLAUDE.md` (cmd emitter, layout arm, hit-test, render, snapshot, a11y role `.text_area`,
`cmdsEqual`, Win32 UIA `Edit` control type + multi-line, re-export + `llms.txt`).

**Render** (`render/build.zig`) is where wrapped lines, selection rectangles and the caret are produced, because only
there are both the final rect and the measurer available: call `text_wrap.layoutLines(content, font, inner_w, measurer)`
to get a line table, emit selection quads per line span, one `TextDraw` per visible line (culled by `scroll_y`), the
caret as a 1-2 px quad (blink phase comes from `TransientState`, which already carries time-driven visual state), preedit
as underlined text at the caret. Vertical clipping reuses the scroll-clip fields.

### 6.3 Metrics event (how update learns about layout without view reading it)

`view` cannot read rects. The runtime, after layout, compares each `text_area`'s (rect size, content_h, caret rect) with
the previous frame and, on change, delivers `TextEvent{ id, kind = .metrics, viewport_w/h, content_w/h, caret_x/y/h }`
through `textMsg`, mirroring `CanvasEventKind.layout`. `update` uses it to clamp scroll, reveal the caret
("scroll_y = clamp so caret_y is inside the viewport"), and set the sticky column. One-frame latency, same as hit-test.
It also feeds `Host.setImeRect` (6.7).

### 6.4 Pointer: hit-test returns a caret position as data (S1)

`Msg` payloads are constructed by the app, never by the framework, so the hit-test result for a text area is not a
`Msg`; it is an event record, exactly the `canvasMsg` precedent:

```zig
// core/text_event.zig (pure data)
pub const TextEventKind = enum { down, drag, up, double_click, triple_click, wheel, metrics, leave };
pub const TextEvent = struct {
    id: u32, kind: TextEventKind,
    index: u32 = 0,            // byte offset of the nearest grapheme boundary to the pointer (clamped to content)
    line: u32 = 0,             // wrapped-line number, so Home/End and up/down can use visual lines
    x: f32 = 0, y: f32 = 0,    // area-local logical px
    dx: f32 = 0, dy: f32 = 0,  // wheel
    mods: Modifiers = .{}, clicks: u8 = 1,
    // metrics fields: see 6.3
};
// App hook (optional, @hasDecl, like canvasMsg):
pub fn textMsg(model: *const Model, ev: teak.TextEvent) ?Msg
```

`hit_test.pointerTarget` already finds the innermost interactive leaf and returns an `id`; the runtime (`run.zig`,
which owns the measurer and `nowMs()`) resolves `index` with `text_wrap.indexAt(content, font, rect_w, x + scroll_x,
y + scroll_y, measurer)`, tracks click count (same position, within 400 ms of `nowMs()`), and captures the pointer
while a button is held (drag selection continues outside the rect). The app maps `down` to "set caret, clear
anchor (or extend with shift)", `drag` to "move caret, keep anchor", `double/triple_click` to word/line selection. The
core editor offers `Editor.applyPointer(ev)` so a component can be written in four lines. The framework never builds a
`Msg` from a pointer, and no fn pointer sits on the Cmd.

### 6.5 Rich text spans and colour reuse

* `TextDraw` gains `colors: []const ColorSpan` (byte ranges); the Gpu emits one instance per glyph with the colour of
  the span containing `cluster`. Syntax-highlighted code and the `rich_text` Cmd's colour-only spans then shape **once
  per line** instead of once per span, and kerning across span boundaries works.
* Spans that change the font (size/weight/family) still break the shaping run: `RichTextSpan` pieces map to separate
  `TextDraw`s as today (`render/build.zig:236-262`), now each cheap because glyphs are atlas hits.
* Wrapping of `rich_text` reuses `text_wrap` through a `RunSource` iterator (`next() -> {slice, font}`) so a wrapped
  paragraph with bold words breaks lines across spans correctly. `rich_zig_adapter` is unchanged.

### 6.6 Bidi and scope

* **In scope for M1**: UTF-8 correctness, grapheme-safe editing, logical-order cursor movement, mixed-direction strings
  never crash and never produce garbage indices.
* **Out of scope for M1**: UAX#9 bidi reordering, Arabic/Indic shaping, vertical text, mirrored glyphs, hyphenation, and
  complex-script cursor affinity.
* **Defined behaviour on RTL text**: glyphs are placed in logical order left to right (RTL words look reversed), Left/Right
  move to the previous/next *logical* grapheme (documented), click-to-caret picks the nearest grapheme boundary by x in
  that logical layout. Every operation keeps the editor invariants. Test: fuzz with Hebrew/Arabic/mixed/invalid-UTF-8
  buffers through insert/delete/move/pointer; assert invariants and no OOB (PR10).
* The seam for later: `ShapedGlyph.cluster` and `Shaper` already carry what a bidi itemizer needs.

### 6.7 IME preedit

* Data: the component Model holds `preedit: [64]u8`, `preedit_len`, `preedit_cursor` (set by `Msg.ime_preedit{ bytes,
  cursor }`, cleared by commit/cancel); the area draws it inline at the caret with an underline. Commit arrives as
  ordinary text input (`textFieldReplaceSelection`).
* Host events: `InputState` gains `ime: ?ImeEvent` (`.preedit{bytes,cursor}`, `.commit{bytes}`, `.cancel`) as
  data, routed like keys.
* Host extension: optional `setImeRect(x, y, w, h)` (called from the `.metrics` caret rect) so the OS candidate window
  and the web hidden `<textarea>` follow the caret. `validateHost` treats it as optional (`@hasDecl`), like
  `scaleFactor`.
* Web: zunk adds a visually hidden `<textarea>` bridge (focus follows the focused area `id`), forwards `compositionstart/
  update/end` and `beforeinput` as the events above; acceptance is Japanese input working in Chrome. X11 XIM/IBus is a
  later PR (issue #7); Win32 already has IME handling to verify. The design only fixes the data contract so it is not
  redesigned per host.

## 7. Wrap, measure-with-width, flex shrink (issue #8)

### 7.1 API

* `TextCmd` gains `wrap: Wrap = .none` (`none | word | char | ellipsis`), `max_lines: u16 = 0` (0 = unlimited),
  `align: TextAlign = .start`. Changing `TextCmd` rather than adding a variant keeps the pass-checklist small; existing
  emitters default to `.none`, so nothing changes for current apps. New emitters: `cb.paragraph(text, font, color)`
  (`wrap = .word`, `fills_cross`, `shrink = 1`) and `cb.textEllipsis(...)`.
* `GroupStyle`/`ScrollStyle`/`FlexSpec` gain `shrink: f32 = 0` (default preserves "groups never shrink"). Wrapped text
  has `shrink = 1`, `min-content = longest unbreakable segment`. `min_width` on a group floors shrinking as today.

### 7.2 Pure core functions (`core/text_wrap.zig`, no platform, no allocation)

```zig
pub const Line = struct { start: u32, end: u32, width: f32, hard_break: bool };
/// Next line of `text[start..]` for a max width. O(line length) using the measurer.
pub fn nextLine(text: []const u8, start: usize, font: FontSpec, max_w: f32, mode: Wrap, m: TextMeasurer) Line;
/// Height-for-width: number of lines (capped by max_lines) * line_height.
pub fn measureWrapped(text, font, max_w, mode, max_lines, m) struct { w: f32, h: f32, lines: u32 };
pub fn minContent(text, font, m) f32;     // widest unbreakable segment
pub fn maxContent(text, font, m) f32;     // unwrapped width of the longest hard line
pub fn indexAt(...) / pub fn caretPos(...) // point <-> byte index through the same line walk
```

`nextLine` walks break opportunities from `core/linebreak.zig` (UAX#14-lite): hard breaks at `\n` / U+2028; soft break
after spaces, after `-` / en dash / em dash when followed by a letter, ZWSP; around CJK ideographs, kana and fullwidth
forms with the kinsoku sets (no line starts with closing punctuation `、。，．）」』】` and no line ends with opening
punctuation `（「『【`); never break at NBSP U+00A0 / NNBSP / U+2011 / WORD JOINER; an unbreakable segment wider than the
line is broken at grapheme boundaries (CSS `overflow-wrap: anywhere`) so nothing overflows. Trailing spaces hang
(excluded from `width` and from fit). `.ellipsis` renders one line truncated with "..." (U+2026) at a grapheme boundary
such that the ellipsis fits; `max_lines` ellipsizes the last visible line.

Width accumulation sums word measurements (`measure` per word) and relies on there being no kerning across a space;
the measure cache (8.3) makes repeated words free. For monospace the whole thing is integer arithmetic.

### 7.3 Layout: constraint passing in a flat stack (S2)

Problem: a text's height depends on its width, but the engine's pass 1 is bottom-up (child size before parent
size) and has no width yet. Solution, all linear passes over `[]Cmd` with the existing `FixedStack`s:

1. **Measure widths (bottom-up)**: every node gets `max_content` (today's intrinsic size at one line) and, for
   shrink-capable nodes, `min_content`. Text leaves with `wrap != none` store `min_content` in a new per-node
   scratch field and report `max_content` as their intrinsic width. Containers accumulate `min_content` as the
   sum (main axis) or max (cross axis) of children's. The emitter counts wrapped/shrinkable nodes in the `CmdBuffer`
   (`cb.wrap_nodes`); **if zero, passes 2 and 3 are skipped** and pass 1 is exactly today's code.
2. **Resolve widths (top-down)**: each container knows its final inner width (root = window). Main-axis containers
   with overflow shrink their `shrink > 0` children down to `min_content`, proportionally to `shrink * basis`
   (CSS flex-shrink with a floor); cross-axis children with `fills_cross`/stretch take the inner width. Each wrapped
   text now has its final width.
3. **Re-measure heights (bottom-up, only subtrees flagged `has_wrap`)**: wrapped texts call `measureWrapped` with their
   final width; ancestors recompute `h` (vertical groups sum, horizontal groups max) using the same accumulation as
   pass 1; flags make this O(wrapped subtree).
4. **Position (top-down)**: unchanged, now reading final widths/heights.

Scroll regions: a vertical scroll's content width is its viewport width (text wraps inside it); a horizontal scroll's
content is unbounded (text keeps `max_content`). Virtual lists keep fixed row heights (variable-height lists are M2).
`text_area` reuses the same machinery with `wrap = .word` and `min_height` rows.

Backward compatibility: all existing layout tests keep passing because every default is `wrap = .none`, `shrink = 0`.
New tests: wrapped paragraph in a stretching column; two wrapped paragraphs in a row shrinking; flex + shrink mixture;
unbreakable overlong token; `max_lines` ellipsis; CJK kinsoku; scroll with wrapped content.

## 8. Performance targets and measure caching

| Metric | Target | Measured / basis |
|---|---|---|
| Runs per frame | 10,000 text runs (about 100k glyphs) with no dropped text | design; today 256 |
| Instance generation (lookup + emit) | at most 1 ms per 100k glyphs on the dev box (aarch64, release) | **0.74 ms** (scratch bench: open-addressed table, 14-bit slots, 32 B instance) |
| Instance upload | at most 3.2 MB/frame (100k x 32 B) | 2.8 MB measured instance array; `writeBuffer`, grow-only |
| Glyph rasterization (cold) | at most 4 us per 14 px glyph | **3.2 us** (stb, `-O2`); ASCII x 4 bins about 1.2 ms once |
| Atlas upload | dirty rects only; at most 1 `writeTexture` per dirty page per frame | design; first frame about 100 KB |
| Draw calls for text | `layers x pages` (typically 2) | today `strings` (one bind group each) |
| Measure | 10k runs of about 10 glyphs: at most 1 ms cached, at most 8 ms cold | glyph metric+kern lookup 0.056 us |
| Frame budget (10k runs, 1080p) | 16.6 ms total, text CPU side (measure + shape + instances) at most 4 ms | sum of the above |
| Atlas memory | 1 MiB per page, 8 pages max | configurable |

### 8.1 Measure caching

* **Where**: Host-side `MeasureCache` in `teak-text` (the measurer's `ctx`). Pure core stays stateless
  (HARDLINE: no hidden retained widget state; a memo table of a pure function is Host implementation detail, like the
  atlas).
* **Key**: Wyhash(text) XOR a mix of `FontSpec` bits (size in 1/64 px, weight, family, letter_spacing, snap_advance),
  stored with the full text hash 64-bit and length; collisions are guarded by comparing length plus a second 32-bit hash
  (no raw-text storage needed: a miss simply re-measures, a false hit requires a 96-bit collision).
* **Policy**: 4096 entries x 24 B, open addressing; cleared wholesale when 75% full or when a font is registered. No LRU
  bookkeeping: the cache is a pure optimisation and wholesale clear costs one cold frame.
* **Frame-local alternative**: not needed once the Host cache exists; layout and render in the same frame hit it.

### 8.2 Perf harness

`tools/bench-text` (PR14): headless native, N runs x M glyphs, prints `layout ms | shape ms | instances ms |
upload bytes | pages` for 640, 10k, and 50k runs, plus the web counterpart through `shot.mjs` timing. It becomes the
gate for the 10k-run acceptance number.

## 9. Compatibility and removal list

* Deprecated then deleted: `GlyphCache` per-string textures (`glyph_cache.zig` `textCacheKey`, `CAPACITY`),
  `Gpu.rasterizeText` in `validateGpu` (replaced by `rasterizeGlyph` on the Rasterizer provider and an optional
  `warmGlyphs`), `TEXT_VERT_BUF_CAPACITY` (both backends), `raster_gdi.zig` (after Windows parity), zunk
  `rasterize_text` per-string import (kept one release for compatibility, then removed).
* Kept: `TextDraw` (gains `colors`), `TextMeasurer` vtable (gains optional entries with core defaults),
  `FontSpec` (gains `snap_advance`), `prefixWidth`, `Host.registerFont`, `WebFont` build step.
* `llms.txt` and `docs/features/text.md` are rewritten in the last doc PR; the audit rule that every `teak.zig`
  re-export is documented keeps this honest.

## 10. Implementation plan (agent-sized PRs)

Legend: **Own** = files the PR is the only writer of in its lane. **Dep** = must merge first. Estimates are agent-hours.
Lanes run in parallel; the "serialize" column lists the shared files that force ordering. Do not start lane
conflicts on `build.zig` / `src/teak.zig` / `llms.txt` before the Zig 0.17 migration lands (it rewrites them); until
then PRs touch them minimally (one-line re-exports).

### Lane A: text module and Host (platform-owned code)

**PR1: `teak-text` module + `Shaper` interface + `SimpleShaper`** (3 h)
* Own: `src/text/{face,shaper,measure}.zig`, additions to `src/core/text.zig` (`ShapedGlyph`, `Shaper`, `ShapeResult`,
  `FontSpec.snap_advance`), `src/gpu/text_stbtt.zig` (becomes a re-export shim over `src/text/face.zig`), test font
  `tests/fonts/` (an OFL subset of Plex Mono + a Latin proportional font with kerning, each under 40 KB).
* Dep: none. Serialize: touches `build.zig` (module wiring) and `teak.zig` re-exports.
* Accept: unit tests: kerning pair ("AV" narrower than A+V), fi/fl ligature present/absent per face, invalid UTF-8
  never OOB, fuzz 10k random byte strings, `measure(text) == sum(advances)`, mono snap makes every ASCII advance
  integral; `zig build test` green on Linux; X11 Host measurer swapped to the new module with no pixel change in
  `examples/counter_greeter` screenshots.

**PR14: MeasureCache + `tools/bench-text`** (1.5 h)
* Own: `src/text/measure_cache.zig`, `tools/bench-text/`.
* Dep: PR1. Parallel with everything after PR1.
* Accept: bench prints layout/shape numbers; 10k runs x 10 glyphs measured at most 1 ms warm and 8 ms cold; cache
  tests (collision guard, clear on font registration).

**PR17: Windows stb path** (2 h)
* Own: `src/platform/win32.zig` measurer swap, system font probe (`%WINDIR%\Fonts`), `src/gpu/native.zig` binding.
* Dep: PR1, PR4. Serialize: `build.zig`. Cross-compile gate: `zig build -Dtarget=x86_64-windows-gnu`.
* Accept: Windows cross-build green; fonts probe unit test with an injected directory; GDI left as fallback.

### Lane B: core pure code (no GPU, no platform; fully parallel to A and C)

**PR2a: `core/unicode.zig` + generator + tables** (2.5 h)
* Own: `src/core/unicode.zig`, `src/core/unicode_tables.zig`, `tools/gen_unicode.zig`.
* Dep: none. Accept: UAX#29 grapheme conformance subset (GraphemeBreakTest.txt excerpt checked in) passes; word-class
  tests; `utf8DecodeLossy` fuzz.

**PR2b: `core/linebreak.zig` + `core/text_wrap.zig`** (3 h)
* Own: `src/core/linebreak.zig`, `src/core/text_wrap.zig`.
* Dep: PR2a (graphemes for overlong-token breaking). Uses only `TextMeasurer` (monoMeasurer in tests).
* Accept: golden line-break table (Latin, hyphen, NBSP, CJK kinsoku, long token, ZWSP); `measureWrapped` monotone in
  width (property test); `indexAt(caretPos(i)) == i` round trip for every grapheme boundary.

**PR10: `core/editor.zig` (Editor + UndoLog)** (3 h)
* Own: `src/core/editor.zig`, `src/input/keys.zig` additions (new `SpecialKey`s), `src/platform/input_queue.zig`
  `resolveKey` additions.
* Dep: PR2a. Serialize: `keys.zig`/`input_queue.zig` are also touched by IME (PR13): PR13 rebases on this.
* Accept: property/fuzz tests (random edit scripts incl. RTL, combining marks, ZWJ emoji, invalid UTF-8): cursor and
  anchor always on a grapheme boundary and within `len`; undo-then-redo is identity; insert at capacity truncates on a
  boundary; Kerf's `editor.zig` test-suite ported verbatim passes.

**PR12: TextField on Editor** (1.5 h)
* Own: `src/core/text_field.zig`. Dep: PR10. Accept: existing TextField tests unchanged; backspace over "e" + U+0301
  deletes the whole grapheme; Delete/Home/End/Ctrl+Left/Right work; `examples/counter_greeter` and Kerf's chat prompt
  type UTF-8 correctly.

### Lane C: native GPU (renderer)

**PR3: `GlyphAtlas` pure data structure** (2 h)
* Own: `src/gpu/glyph_atlas.zig` (+ test). No GPU types. Dep: none (parallel with A, B).
* Accept: shelf packer fills a page to at least 80% with a realistic glyph-size mix; page-granular eviction increments
  `gen` and invalidates entries in O(1); full-key comparison (inject colliding hashes); all-pages-pinned path returns a
  loud error value, never UB; `GlyphKey` size/layout test.

**PR4: native instanced glyph pass** (3 h)
* Own: `src/gpu/wgpu_core.zig` text sections (`uploadText` rewritten to build instances; `renderFrame` text draws;
  growable instance buffer), `shaders/glyph.wgsl`, `src/gpu/native.zig`, `native_linux.zig`, `native_headless.zig`,
  `src/gpu/overlay.zig` if the marker needs ranges, `glyph_cache.zig` removed or reduced to a re-export.
* Dep: PR1, PR3. Serialize: `wgpu_core.zig` is single-writer; PR15 follows it.
* Accept (this is the make-or-break gate):
  1. `~/github/ws/ref/textstress.zig` + `textstress-shot.patch` (640 runs) via `zig build shot`: **every row shows text**
     (look at the PNG), then raise to 10k runs: still all text, no log errors;
  2. `zig build test-gpu` green; golden snapshots of `counter_greeter`/`todo`/`chrome` pixel-compared against the old
     path within a tolerance (identical cmds/rects; glyph raster differs only in subpixel binning), reviewer opens both;
  3. `tools/bench-text` (PR14, or a throwaway timer) shows 10k runs frame CPU time at most 4 ms;
  4. forcing `max_atlas_pages = 1` with the CJK corpus logs the loud message and keeps rendering;
  5. HiDPI: `scale = 2` screenshot is sharper (true 2x rasterization), no layout change.

**PR15 (optional): SDF page kind** (3 h). Own: `glyph_atlas.zig` page kinds, `shaders/glyph.wgsl` mode branch,
`TextDraw`/`FontSpec` hint `scalable: bool`. Dep: PR4. Accept: viewport example zooms canvas labels from 0.5x to 8x with no
re-rasterization and no blur at 1x; 14 px UI text unchanged.

### Lane D: web (zunk + backend)

**PR6: zunk glyph-atlas primitives** (2.5 h)
* Own (zunk repo): `src/web/gpu.zig` (`writeTextureRegion`, `zunk_gpu_write_texture_region`), `src/gen/js_resolve.zig`
  (new import + the optional cluster-raster import `zunk_text_raster_cluster`), `docs/`.
* Dep: none. Parallel with PR4. Accept: a zunk example uploads two sub-rects into an R8 texture and draws instanced quads
  (screenshot via `kerf/tools/shot.mjs`); `zig build test` in zunk green; old `rasterize_text` kept.

**PR7: web backend onto atlas + stb wasm** (3 h)
* Own: `src/gpu/web.zig`, `src/gpu/web_scene.zig` only if buffer helpers move, `src/platform/wasm.zig` (measurer from
  `teak-text`), `build.zig` `linkWebWgpu` (compile `stb_truetype_impl.c` for wasm32-freestanding with the shim file
  `src/gpu/vendor/stb_wasm_shim.zig`: bump allocator, `pow`/`cos`/`fmod`/`acos`, `fonts` option feeds asset fetch), shares
  `shaders/glyph.wgsl` with PR4.
* Dep: PR1, PR3, PR4 (shader + instance format), PR6. Serialize: `build.zig`.
* Accept: `zig build web` for chrome; Chromium WebGPU shot (`node kerf/tools/shot.mjs ... --webgpu`) of the 640-run
  stress shows all text and **matches the native shot to within AA noise** (identical glyph placement; first cross-target
  golden); wasm delta for `chrome` at most +20 KB gzip vs before (measure with `gzip -9`); fonts example still loads Plex
  Mono; canvas fallback draws a CJK label with no shipped CJK font.

### Lane E: layout and widgets

**PR8: wrap + shrink in layout** (3 h)
* Own: `src/layout/engine.zig` (+ `sizing_test.zig`), `src/core/cmd.zig` (`TextCmd.wrap/max_lines/align`, `shrink`
  fields, `paragraph`/`textEllipsis` emitters, `wrap_nodes` counter), `src/core/snapshot.zig`, `docs/features/layout.md`,
  HARDLINE hatch 3 amendment (S2).
* Dep: PR2b. Serialize: single writer of `engine.zig` and `cmd.zig` among lanes until PR11a.
* Accept: all existing layout tests (engine.zig, sizing_test.zig) unchanged; the new test list in 7.3; snapshot goldens; a frame with no
  wrapped nodes executes the old two passes (instrumented test asserts passes 2-3 skipped).

**PR9: render wrapped text** (2 h)
* Own: `src/render/build.zig` (per-line `TextDraw`, ellipsis, `colors` spans, `RunSource` rich-text wrapping),
  `src/run.zig` `cmdsEqual` arm for new fields. Dep: PR8, PR4 for visual check. Accept: `examples/` paragraph screenshot;
  render golden for wrap/ellipsis/`max_lines`; layout height == render line count for 1000 random strings and widths.

**PR11a: `text_area` Cmd (static)** (3 h)
* Own: `cmd.zig` variant + emitter, `layout/engine.zig` arm, `render/build.zig` selection/caret/preedit,
  `core/snapshot.zig`, `input/a11y.zig` (`.text_area`), `input/focus.zig`, `platform/win32.zig` UIA mapping,
  `teak.zig`/`llms.txt`. Dep: PR8, PR9, PR10. Serialize with PR8/PR9 (same files).
* Accept: the nine-item widget checklist all ticked; snapshot goldens for caret, multi-line selection across wrapped lines
  and scrolled content; a11y role test.

**PR11b: pointer + metrics hook** (3 h)
* Own: `src/run.zig` (`textMsg` hook, click count, capture), `src/input/hit_test.zig`, `src/core/text_event.zig`,
  `Editor.applyPointer`, headless scripted-input tests. Dep: PR11a.
* Accept: scripted headless run: click sets caret mid-word, shift-click extends, drag selects across wrapped lines, double
  click selects a word, triple selects a line, drag outside the rect keeps selecting, wheel scrolls, typing at the bottom
  reveals the caret via the `metrics` event.

**PR13: IME bridge** (3 h)
* Own: `ImeEvent` in `src/platform/host.zig`/`input_queue.zig`, optional `Host.setImeRect`, zunk hidden `<textarea>`
  bridge in zunk `src/web` + `src/gen/js_resolve.zig`, `src/platform/wasm.zig` event plumbing, `Editor` preedit helpers.
  Dep: PR11b, PR6, PR10. Serialize: `host.zig`/`input_queue.zig`.
* Accept: Chromium headless composition-event test via `shot.mjs` driving `compositionstart/update/end`; manual
  Japanese input checklist for the review (web + one native host is the M1 acceptance in the review).

**PR16 (optional): colour-emoji RGBA page + cluster fallback hardening** (2 h). Own: `glyph_atlas.zig` RGBA pages,
`shaders/glyph.wgsl` flag bit, `web.zig`. Dep: PR7.

**PR18: docs and examples** (2 h). Own: rewrite `docs/features/text.md`, `docs/cookbook.md` recipe "add a TextArea",
`llms.txt`, `examples/notes` (multi-line editor + wrapped paragraph + 10k-run stress toggle), Kerf notes note.
Dep: PR11b. Accept: `zig build audit` green; the example runs on native and web.

### Ordering and parallelism

```
 Week 1   A: PR1 --> PR14           B: PR2a --> PR2b --> PR10 --> PR12     C: PR3 --> PR4
          D: PR6 (zunk, independent)
 Week 2   D: PR7 (needs PR1, PR3, PR4, PR6)     E: PR8 --> PR9 --> PR11a --> PR11b (serial: engine.zig/cmd.zig)
          A: PR17 (Windows)                     C: PR15 (optional)
 Week 3   D/E: PR13 IME (needs PR11b + PR6)     PR16, PR18
```

* Safe to run in parallel from day 1: **PR1, PR2a, PR3, PR6** (disjoint files in three repos' areas).
* Must serialize: `wgpu_core.zig` (PR4 then PR15), `engine.zig`+`cmd.zig` (PR8, PR11a), `build.zig` (PR1, PR7, PR17),
  `keys.zig`/`input_queue.zig`/`host.zig` (PR10 then PR13), `teak.zig`+`llms.txt` (every PR adds one line; rebase,
  never reorder).
* Critical path to the review's M1 acceptance (multi-line chat input + notes editor with web IME): PR1 -> PR4 -> PR7,
  PR2a -> PR2b -> PR8 -> PR9 -> PR11a -> PR11b -> PR13. About 10 working days of agent time with two lanes in parallel.
* Estimated total: about 40 agent-hours (PR1 3, PR14 1.5, PR17 2, PR2a 2.5, PR2b 3, PR10 3, PR12 1.5, PR3 2, PR4 3,
  PR6 2.5, PR7 3, PR8 3, PR9 2, PR11a 3, PR11b 3, PR13 3, PR18 2; PR15/16 optional 5).

## 11. Risks and open questions

1. **Hinting.** stb has none; at 11-13 px unhinted AA text looks softer than GDI/ClearType. Mitigation: mono grid
   snap + integer baselines + x bins; if reviewers dislike it, a coverage "contrast" curve in the shader (`text_gamma`) is a
   one-line tuning, and stb's `stbtt_GetGlyphBitmapSubpixel` plus a slight vertical `oversample` can be evaluated on the
   stress shot before PR4 merges.
2. **No system font fallback on native** (no fontconfig). Mitigation: fallback chain of explicitly registered faces; web
   canvas fallback covers CJK/emoji; native users ship a CJK face. Documented in the README subset statement.
3. **Large fixed-size Models.** `Editor(64 KB)` makes `Model` big; by-value copies in tests and `update` helpers are
   costly and the slice-into-copy pitfall bites. Mitigation: `content()` doc and a debug assertion that the editor is
   not moved (address stamp), plus an arena-backed variant as a later PR if Kerf needs MB-scale notes.
4. **S1/S2 HARDLINE amendments** need sign-off (section 2). If the reviewer rejects `textMsg`, the fallback is to embed
   `TextAreaCmd.caret_msg: ?Msg` plus a `hit_test.textLocalPoint` helper like `canvasLocalPoint`; the runtime would
   resolve the index and the App would re-derive it, which is more app code and loses click counts.
5. **Float determinism across targets** (FMA contraction): tests compare within 1/64 px, goldens render on one
   platform and compare structurally across platforms.
6. **0.17 migration** rewrites `build.zig`, `teak.zig`, `llms.txt` and many `@cImport` sites (review §5.1); sequence the
   lane starts after it merges, or have PR1/PR3 (pure Zig, no build edits beyond one module line) go first.
7. **wasm `writeTexture` per dirty rect** may cost more than a staged full-page upload on some drivers: PR7 measures both
   and flushes the full page when more than 8 rects are dirty.
8. **Defects found while reading the current path** (all removed by this design, listed so they are not fixed twice):
   silent 256-run drop (`wgpu_core.zig:988`, `web.zig:44`), content-blind cache key and integer-truncated size
   (`glyph_cache.zig:textCacheKey`), per-string texture + bind group churn, GDI ignoring `letter_spacing`.

## 12. Orchestrator decisions (2026-10-08)

* **S1 approved:** the `textMsg` pointer/metrics hook ships as specified in 6.4 (same shape as `canvasMsg`). PR11b adds the
  one-line HARDLINE §2 hatch 4(d) mention.
* **S2 approved:** hatch 3 becomes "two to four O(n) linear passes; passes 2-3 run only when the frame has wrapped or
  shrinkable nodes". PR8 amends HARDLINE and `docs/features/layout.md`.
* **SDF deferred** as recommended; coverage atlas at physical pixel size. **stb everywhere** (web included) is the default
  rasterizer; GDI and canvas2D become fallbacks.
