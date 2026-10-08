# Changelog

## Unreleased

### Added

- `Shaper` / `ShapedGlyph` / `ShapeResult` (core) and `FontSpec.snap_advance` (default false).
- `teak-text` now ships `SimpleShaper` (stb kerning, fi/fl/ff/ffi/ffl ligatures on proportional
  faces) in `src/text/`; the module root moved from `src/gpu/text_stbtt.zig` to `src/text/text.zig`
  (same exports). Measurement and rasterization both place glyphs from the shaper; invalid
  UTF-8 now yields U+FFFD per bad byte (was byte-as-codepoint).

### Changed

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
