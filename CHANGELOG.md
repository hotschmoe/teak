# Changelog

## Unreleased

### Added

- Native glyph fallback chain (`src/text/fallback.zig`): per code point the shaper tries the requested face, the family's other weights,
  the other registered families, `registerFallbackFace` faces, then lazily-probed system fonts (DejaVu Sans, Noto Sans / CJK / Emoji,
  WenQuanYi, FreeSans, Unifont; `TEAK_FALLBACK_FONTS` prepends paths). Tofu only when nothing has the glyph; ZWJ / variation selectors /
  other default-ignorables take no space. Measurement, raster and atlas agree (one shaper decision, face ids above `fallback_face_id`).
- Wrapped `rich_text` (`RichTextCmd.wrap/max_lines/text_align`, `cb.richParagraph`): lines break across spans with mixed fonts and colours.
- `InputQueue` caps raised to 256 chars / 64 keys per frame and overflow is counted (`dropped`) and logged.
- `text_area` Cmd + `TextArea(cap)` component + `textMsg` hook (text-engine PR11a/PR11b, closes the multi-line half of #6):
  wrapped multi-line editing with selection across lines, scrolling, caret, IME composition, pointer (click, shift-click,
  drag incl. outside, double/triple click, wheel), visual Up/Down/Home/End with a sticky column, layout `metrics` events,
  `Host.setImeSpot` from the focused caret; `Editor.applyPointer`; `examples/notes`. See docs/features/text-area.md.
- Wrapped text and flex shrink (text-engine PR8/PR9, closes #8): `text` gains `wrap` (`none|word|char|ellipsis`),
  `max_lines`, `text_align`; groups/scrolls gain `shrink`; emitters `paragraph`, `paragraphStyled`, `textEllipsis`.
  Layout runs two extra passes (resolve widths, re-measure heights) only when a frame has wrapped or shrinkable nodes;
  render draws one `TextDraw` per line. HARDLINE hatch 3 amended accordingly. Chrome's NOTES panel shows it.
- `teak.Combobox(cap)`: searchable select (query field + filtered overlay list with scrolling, type-ahead
  highlight, keyboard, "No matches" row), composed from existing primitives; chrome's MATERIAL field uses it (#2).
- Cookbook recipe 6b + tested `LoadRow`/`LoadApp` example: rows owning several focusable fields (#1).
- `teak.unicode`, `teak.linebreak`, `teak.text_wrap`: UAX#29 graphemes, word classes, UAX#14-lite line
  breaking, wrapping/measure/caret mapping (text-engine PR2a/b).
- `teak.editor`: `Editor(cap, undo_cap)` with grapheme-aware editing, word jumps, undo/redo (PR10).
- `SpecialKey`: `ctrl_left/right/home/end` (+ `ctrl_shift_*`), `ctrl_backspace`, `ctrl_delete`,
  `ctrl_shift_z`; `resolveKey` maps them.
- `Shaper` / `ShapedGlyph` / `ShapeResult` (core) and `FontSpec.snap_advance` (default false).
- `teak-text` now ships `SimpleShaper` (stb kerning, fi/fl/ff/ffi/ffl ligatures on proportional
  faces) in `src/text/`; the module root moved from `src/gpu/text_stbtt.zig` to `src/text/text.zig`
  (same exports). Measurement and rasterization both place glyphs from the shaper; invalid
  UTF-8 now yields U+FFFD per bad byte (was byte-as-codepoint).

### Changed

- `Dropdown`/`Combobox`: the keyboard-highlighted row now also takes the theme's `hover_fg` (fixes invisible labels on inverting themes).
- `TextField(N)` is now built on `Editor`: backspace/Delete remove whole grapheme clusters, multi-byte
  characters typed byte-wise are inserted atomically, and it gains `delete`, `home`/`end`, word jumps,
  `undo`/`redo` Msgs (the `Model` field names `len`/`cursor`/`selection_anchor` are unchanged; the byte array is now `buf`).

- **wgpu-native prebuilts updated v25.0.2.2 -> v29.0.1.1** (all four Windows/Linux deps). No source API fixes were needed (the v25 code already used the StringView / callback-info API); device creation now installs an uncaptured-error callback that logs loudly, and sets the device-lost callback mode explicitly.

### Changed (breaking)

- **Zig 0.17.0 is now required; 0.16 support is dropped.** See
  [docs/migration-0.17.md](docs/migration-0.17.md).
  - Array/string `**` repeats replaced with `@splat` (library, examples, tests).
  - Comptime component composition (`Components`, `ComponentList`) and the
    build-time web-font table use the parallel-array `@typeInfo` layout.
  - `@cImport` replaced by `b.addTranslateC` modules `wgpu-c` and `stb-c`,
    wired up in `linkNativeWgpu`, `linkWebWgpu`, `linkHeadless` and the
    library's own test steps.
  - `b.args` replaced by `Run.addPassthruArgs()` in every example build and in
    the docs.
  - `builtin.mode` comparisons use the lowercase `.debug` spelling.
  - `rich_zig` (counter_greeter) and zunk's `webzocket` / `rich_zig` pins moved
    to their 0.17 branches.
  - CI and docs updated to Zig 0.17.0.
