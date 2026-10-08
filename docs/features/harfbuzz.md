# Optional HarfBuzz shaper

Teak's built-in shaper (`SimpleShaper`, `src/text/shaper.zig`) does cmap, fi/fl
ligatures, kerning and centred combining marks. It cannot do contextual forms
(Arabic joining), reordering (Devanagari i-matra, conjuncts) or GPOS mark
attachment. `-Dharfbuzz=true` swaps in HarfBuzz for text that needs it.

- **Default off, default dependency-free.** `build.zig.zon` declares
  `harfbuzz` (11.2.1, MIT) as a *lazy* package; nothing fetches it unless a build
  asks for it. HarfBuzz is compiled from its single-source `src/harfbuzz.cc`
  with Zig's C++ compiler (libc++, no ICU / FreeType / GLib; platform font and
  threading backends disabled).
- **Switches.** Library tests: `zig build test -Dharfbuzz=true`. Consumers:
  `teak.linkNativeWgpu(b, exe, .{ .harfbuzz = true })`,
  `teak.linkHeadless(b, exe, .{ .harfbuzz = true })` (the example forwards a
  `-Dharfbuzz` option, see `examples/notes/build.zig`). Native targets only; the web
  (wasm32-freestanding) build has no libc++ and panics at configure time if asked.
- **When it runs.** `shaper.shape` sends a run to `hb_shaper.zig` only when it
  contains a complex-script code point (Hebrew .. Myanmar, Khmer, Mongolian,
  Balinese .. Vedic, Arabic presentation forms; `hb_shaper.needsShaping`). Latin,
  Greek, Cyrillic, CJK keep the built-in shaper, so default metrics never change.
  `shaper.shapeSimple` is always available.
- **Output contract.** Same `ShapedGlyph` data: glyph ids in the face's glyph
  space (stb rasterizes them as-is), byte-offset clusters, `sum(advance) == width`,
  resumable through `ShapeResult.consumed`. New field `ShapedGlyph.y` (px, down)
  carries mark attachment; the glyph stage adds it to the baseline. Advances are
  fractional (no snapping: it would break attachment); letter-spacing is skipped
  for RTL (joining) runs.
- **Faces.** HarfBuzz reads the bytes the face table already holds (read-only
  blob, no copy). A run uses the primary face while it covers the text, else the
  first registered face (any family / weight, then the system fallback) that does,
  so one line can mix Latin, Hebrew, Arabic and Devanagari faces.
- **Not done (bidi).** Direction is a stand-in until UAX#9 lands: a run takes its
  script's direction, RTL runs come out in visual order, and consecutive RTL runs
  are reversed. Nested LTR inside RTL (digits, Latin words in Arabic text),
  brackets and per-line reordering after wrapping are NOT handled, and
  `cluster` is therefore not monotonic inside RTL runs (caret / selection code
  must not assume logical glyph order for them yet).

## Tests and fonts

`src/text/hb_shaper_test.zig` (only built with `-Dharfbuzz=true`) checks Arabic
joining + right-to-left glyph order, a vowel mark's pixels sitting above its base,
Devanagari i-matra reordering and conjunct ligation, per-script face choice on a
mixed line, and resumable output. It needs Noto Naskh Arabic, Noto Sans
Devanagari / Hebrew / Sans (SIL OFL; not committed) in `$TEAK_TEST_FONTS`
(default `~/.cache/teak-test-fonts`) and skips when they are missing. They are
published at `fonts/<Family>/hinted/ttf/<Family>-Regular.ttf` in the
`notofonts.github.io` repository of the notofonts organisation.

## Demo

`examples/notes` has a "Show scripts" button. Point `NOTES_SCRIPT_FONTS` at the
directory holding the three scripts' fonts (`NotoNaskhArabic-Regular.ttf`,
`NotoSansHebrew-Regular.ttf`, `NotoSansDevanagari-Regular.ttf`) and run
`zig build ui` / `zig build shot -- out.png`, with and without `-Dharfbuzz=true`
(built-in: nominal Arabic forms, left to right; HarfBuzz: joined, right to left,
marks placed, Devanagari reordered).
