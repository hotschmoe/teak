# Text measurement + rasterization

**Status**: `pub` in `src/teak.zig` as `FontFamily`, `FontWeight`, `FontSpec`,
`DEFAULT_FONT`, `TextMetrics`, `TextMeasurer`, `TextureHandle`,
`TEXTURE_HANDLE_NONE`, `monoMeasurer`. WS1 ships the types, Host /
GPU contract extensions, and stubs; real rasterization lands in WS2
(native / DirectWrite) and WS4 (web / zunk).
**Source**: `src/core/text.zig`; Host extension at
`src/platform/host.zig`; GPU extension at `src/gpu/context.zig`.
**Tests**: colocated `TextMeasurer` vtable dispatch test in
`src/core/text.zig`; updated `validateHost` / `validateGpu` stub
tests cover the new decls.

Extends the [Host](host.md) and [Gpu](gpu.md) interfaces — not a new
escape hatch. See [HARDLINE §2 escape hatch 4(d)](../HARDLINE.md#escape-hatch-4-host-layer).

## Contract

The core vocabulary, usable above the platform layer:

| Type | Purpose |
|---|---|
| `FontFamily` | enum `{ sans, serif, mono }`. Platform maps to a concrete system font. |
| `FontWeight` | enum `{ regular, medium, bold }`. |
| `FontSpec` | `{ size_px: f32 = 14, family: FontFamily = .sans, weight: FontWeight = .regular, letter_spacing: f32 = 0 }`. By-value. |
| `DEFAULT_FONT` | `FontSpec{}` — sans 14px. Field default on text-bearing Cmds. |
| `TextMetrics` | `{ width, height, ascent, descent: f32 }`. All in pixels. |
| `TextMeasurer` | `{ ctx: *anyopaque, measure_fn: *const fn(...) TextMetrics }`. Opaque-context vtable. Methods: `measure(text, font) TextMetrics`, `prefixWidth(text, font, byte_prefix) f32`. |
| `TextureHandle` | `u32` token. Opaque above the GPU layer; each backend maps it to a real resource. |
| `TEXTURE_HANDLE_NONE` | Sentinel (`0`) for "no texture / stub". WS1 stubs return this; real impls issue non-zero handles. |
| `monoMeasurer()` | Stateless 10 px/byte (+ `letter_spacing` per byte), 20 px/line fallback. For CLI canaries and framework tests where no Host exists. Not production. |

### Weight and letter spacing

`FontSpec.weight` and `FontSpec.letter_spacing` (pixels added after every glyph) are plain data that travel with the font into `TextDraw.font`. Core only threads them through; the backend interprets them:

- **web**: CSS `font-weight` (`regular` 400, `medium` 500, `bold` 700) and canvas `letterSpacing`. The Host measurer and the Gpu rasterizer build the canvas font from one helper (`src/gpu/web_font.zig`), so they agree; the measure cache is keyed on the whole `FontSpec`.
- **native Linux** (X11 + stb_truetype): face selection by weight from the registered faces (below); spacing added after every code point in both the measurer and the rasterizer. `size_px` is the **em** size on every backend (CSS px = GDI negative height = stb em scale).
- **native Windows** (GDI): `weight` maps to `FW_NORMAL` / `FW_MEDIUM` / `FW_BOLD`; `letter_spacing` is not applied yet.
- A backend that cannot honor a field **ignores it**: the text still renders, just regular and untracked. The measurer must agree with the rasterizer so layout matches pixels; `monoMeasurer` adds `letter_spacing` per byte and ignores `weight`.
- `size_px` and `letter_spacing` change the glyph run (and `size_px` the atlas key), so changing them re-shapes/re-rasterizes instead of reusing a stale glyph.

```zig
const label: teak.FontSpec = .{ .size_px = 11, .family = .mono, .weight = .bold, .letter_spacing = 1 };
cb.textStyled("PARTS", label, cb.theme.muted_color);
```

### Custom fonts (IBM Plex Mono and friends)

**Web** — register files in the build; they are copied to `dist/fonts/`, declared with `@font-face`, and the app starts only after every face has loaded, so the first measurement already sees the real font:

```zig
teak.linkWebWgpu(b, web_exe, .{ .fonts = &.{
    .{ .family = "IBM Plex Mono", .weight = 400, .path = b.path("assets/IBMPlexMono-Regular.ttf") },
    .{ .family = "IBM Plex Mono", .weight = 500, .path = b.path("assets/IBMPlexMono-Medium.ttf") },
    .{ .family = "IBM Plex Mono", .weight = 700, .path = b.path("assets/IBMPlexMono-Bold.ttf") },
} });
```

`WebFont.slot` (default `.mono`) says which `FontFamily` the family stands in for; text in that slot is drawn with `"IBM Plex Mono", monospace`. Other slots keep the CSS generic family.

**Native Linux** — the app registers embedded TTFs with the X11 Host before the first frame (up to three weights per family):

```zig
try host.registerFont(.mono, .regular, @embedFile("plex-Regular"));
try host.registerFont(.mono, .bold, @embedFile("plex-Bold"));
```

The measurer and the Gpu rasterizer share one face table (`src/text/face.zig`). A request takes the registered weight nearest the one asked for (lighter on a tie); a family with no registered face uses the system monospace TTF (`TEAK_FONT=/path/to.ttf` overrides the search). Win32 ignores `registerFont` (GDI uses installed fonts). `examples/fonts` is the working reference for both.

### Host extension

| Decl | Signature | Purpose |
|---|---|---|
| `textMeasurer` | `fn(*Host) TextMeasurer` | Returns an interface value the layout pass can call to measure any `[]const u8` in a given `FontSpec`. |

Added to `validateHost`'s required list. The measurer's `ctx`
points at Host-internal state (font factory, cached text format
objects); core reaches it only through `measure_fn`.

### GPU extension

| Decl | Signature | Purpose |
|---|---|---|
| `rasterizeText` | `fn(*Gpu, []const u8, FontSpec, [4]f32, u32, u32) TextureHandle` | Rasterize `text` in the given font + RGBA color at a `width × height` output bitmap; return a texture handle. |

Added to `validateGpu`'s required list. WS2 replaces the native
stub with DirectWrite; WS4 replaces the web stub with zunk's
`rasterizeText`. The detailed contract for feeding the handle into a
textured-quad pipeline is WS2 scope.

### Cmd field additions

Every text-bearing `Cmd` variant carries a `font: FontSpec = DEFAULT_FONT`:

- `TextCmd`
- `ButtonCmd(Msg)` (label)
- `TextInputCmd(Msg)` (content)
- `CheckboxCmd(Msg)` (label)
- `RadioCmd(Msg)` (label)

Existing emitter methods (`cb.text`, `cb.button`, etc.) use the
default. Explicit-font emitters arrive later when a concrete use case
lands — WS1 doesn't proliferate API.

## Invariants

- **Measurer is ephemeral.** The value returned by
  `Host.textMeasurer()` is valid only while the Host outlives it.
  Callers capture it per frame and discard; do not stash across Host
  lifetimes.
- **`FontSpec` is by value.** Copied into each `Cmd`. The type is
  small enough (16 bytes) that this is trivial; no interning needed.
- **Texture handles are opaque above GPU.** Core / layout / render-
  build never unpack a `TextureHandle`. The GPU backend is the sole
  resolver. This mirrors `NativeHandle` and the validateGpu/validateHost
  "init signature varies per backend" convention.
- **Measurer fn cannot allocate.** The measure call happens inside
  the layout pass, which is per-frame arena territory. If a platform
  needs scratch space for shaping, it allocates out of a measurer-owned
  fixed buffer; the allocation is never visible to core.
- **`prefixWidth(text, font, 0)` returns 0 without dispatching.** The
  vtable short-circuits empty prefixes.
- **Stubs return numbers compatible with the 10 px/byte stub.** WS1
  backend stubs (`win32.zig`, `wasm.zig`, `native.zig`, `web.zig`)
  return `len * 10` for width and `20` for height, so WS1 ships with
  zero visual drift from pre-WS1 examples.

## Non-goals / known limits

Pushed out of scope for the text-rendering phase. Flag PRs that
re-add these concerns as drift from the phase plan:

- **Rich text** (mixed fonts or colors in one span). Every `Cmd.text`
  carries exactly one `font` + one color.
- **Bidi / RTL / complex script shaping.** Latin and basic Unicode
  only. Non-Latin runs render with the platform's fallback glyph.
- **IME composition UI.** Candidate windows, preedit marks — owned
  by the OS; Teak receives finished code points.
- **System font discovery by name.** Custom faces are registered
  explicitly (above); there is no `fc-match` lookup.
- **Subpixel anti-aliasing.** Grayscale only. Subpixel has per-
  orientation cost we don't need yet.
- **Per-glyph atlas packing.** WS2 rasterizes whole strings per
  `(content, font, color)` key. Glyph-level packing is a v2 cache
  optimization once the hit pattern is visible.
- **Animated measurement / metrics change mid-frame.** The measurer
  returns the same values for the same inputs within one frame.

## Test coverage target

- **Vtable dispatch** (covered): `TextMeasurer.measure` and
  `prefixWidth` tests in `src/core/text.zig`.
- **`validateHost` / `validateGpu` gap tests** (missing): one compile-
  fail test per missing decl — same target as the other two
  validators.
- **Stub-returned-number regression** (missing): a test that pins
  WS1 stubs to `len * 10` width, so a future stub swap doesn't
  silently drift sizes before WS2 lands.
- **Backend parity** (long-term, post-WS2): a native + web render of
  the same string with the same `FontSpec` should produce rect sizes
  within X% of each other. Blocked on both backends shipping real
  impls.
