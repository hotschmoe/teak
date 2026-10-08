# Changelog

## Unreleased

### Animation primitive

- New `teak.anim`: `Tween(T)` (Model-resident), `Ease`/`ease`, `lerp`. New
  `Sub.animation_frame` and the optional App hook `animationMsg(model, dt_ms)`:
  while the sub is listed the run loop feeds frame time (capped at 100 ms) to
  the app and suspends idle skipping. `Sub` gained a variant (exhaustive
  switches over `Sub` need an arm). `examples/chrome`: sliding QUICK KEYS popover.
  See docs/features/animation.md.

### Event-driven idle

- `RunOptions.idle_skip` (default true): a frame with no input, no dispatched
  Msg, no blinking focused input, no IME / secondary window skips view,
  layout, diff, upload and present; `Runtime.quiet` reports it and `run`
  calls the Host's optional `waitEvents(timeout_ms)` (headless implements it;
  X11/Win32 hosts still to add it, see `platform/host.zig`). New
  `sub.nextDueMs`. Behaviour change: `frame_counter` / snapshot `frame=` count
  built frames only; set `.idle_skip = false` for the old every-frame behaviour.

### Core cleanup (idiomatic Zig + silent-failure hardening)

- **Frame diff is derived by reflection.** `cmdsEqual` now uses the generic
  `core/eql.zig` `deepEql` over `Cmd(Msg)` (slices by content, floats bitwise,
  `Msg` deep-compared): a new `Cmd` field can no longer be forgotten. Tests
  mutate every leaf of every variant. `SceneCmd.eql` is removed (breaking, but
  `deepEql` covers it); `CanvasPrimitive.eql` stays (revision-`key` shortcut).
- **Every pass is exhaustive over `Cmd` tags** (no `else =>`): a new variant
  fails to compile in layout, hit-test, focus, render, snapshot, a11y and
  scroll extent. The CLAUDE.md/AGENTS.md widget checklist is shortened.
- **OOM policy:** allocation `catch unreachable` (UB in release) replaced by
  `core/oom.zig`'s `oom()`, a `@panic` in every optimize mode. Emitters stay
  non-error-returning.
- **Loud capacities:** `MAX_BALANCE_DEPTH` 32 -> 64 (layout stacks and
  `ClipStack`). Stack overflow/underflow, `pushFormRow` nesting past 8 and a
  stray `popFormRow` now `@panic` in every mode. `teak.run` runs
  `validateBalance` every frame in every mode (was Debug only) and panics
  naming the offending cmd index. The resource table logs once when full
  (`Table.overflowed`).
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
