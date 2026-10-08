# Changelog

## Unreleased

### Added

- **X11 host parity** (issues #4, part of #7). `src/platform/x11.zig`:
  - Clipboard: `Clipboard.write` / `write_clipboard` own the `CLIPBOARD`
    selection and answer `SelectionRequest` (`TARGETS`, `UTF8_STRING`,
    `STRING`, `TEXT`, `text/plain`); `Clipboard.read` does a bounded
    synchronous `XConvertSelection` round trip; an unclaimed Ctrl+V becomes
    `.pasted_text` (or a `.dropped` PNG image) asynchronously, with INCR on
    receive.
  - XDND v5 drops: `text/uri-list` files and `UTF8_STRING` text arrive as
    `.dropped` like the web host.
  - Input methods: XIM input context with on-the-spot preedit callbacks
    feeding `imeState()`, `Xutf8LookupString` text (also Compose / dead keys),
    `Host.setImeSpot` for the over-the-spot style, clean fallback when no IM.
  - `zig build test-x11` (live display, skips without `DISPLAY`) drives the
    host with xclip / xdotool and an in-process XDND source.

### Fixed

- X11 host failed to compile on first use under Zig 0.17 (`Xlib.load` still
  used the removed `@typeInfo(...).fields`).

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
