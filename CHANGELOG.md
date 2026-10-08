# Changelog

## Unreleased

### Event-driven idle

- `RunOptions.idle_skip` (default true): a frame with no input, no dispatched
  Msg, no blinking focused input, no IME / secondary window skips view,
  layout, diff, upload and present; `Runtime.quiet` reports it and `run`
  calls the Host's optional `waitEvents(timeout_ms)` (headless implements it;
  X11/Win32 hosts still to add it, see `platform/host.zig`). New
  `sub.nextDueMs`. Behaviour change: `frame_counter` / snapshot `frame=` count
  built frames only; set `.idle_skip = false` for the old every-frame behaviour.
### Web build: stripped wasm by default

- `linkWebWgpu` now strips DWARF and the name section from the wasm in every
  non-Debug build (`WebWgpuOptions.strip`, default true). The shipped
  `chrome-web.wasm` was 1.27 MB, of which 1.15 MB was debug info (the
  apparent 0.16 -> 0.17 growth of +65 KB was all DWARF: code actually shrank
  97.5 KB -> 89.8 KB); stripped it is 120 KB. Pass `.{ .strip = false }` to
  keep symbols for wasm debugging.

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
### Changed

- Web text now uses the same glyph atlas as native: stb_truetype compiled into the wasm
  (`src/text/stb_wasm_impl.c` + a malloc/libm shim) shapes and rasterizes glyphs, the web Host
  measures with `teak-text` (layout == render, and chrome's web render is pixel-identical to
  native), and glyphs no shipped face has (CJK, symbols) are rasterized by canvas 2D one cluster
  at a time. The `.fonts` files are embedded in the wasm (and still copied to `dist/fonts/` for
  the canvas fallback); a small Plex Mono subset is embedded as the default face. Text is
  vertically centred in buttons on web now. `glyph_cache.zig`, `textured_quad.wgsl` and the old
  `rasterizeText` web path are removed. Chrome's wasm grows ~23 KB gzip (ReleaseFast, stripped; ~21 KB with ReleaseSmall), 5.5 KB of it the embedded default face, which apps that ship `.fonts` do not pay.
- Combining marks (U+0300 block and friends) take no advance and are centred over the preceding base glyph (`cafe` + U+0301 measures like `café`); a mark the face lacks is dropped instead of drawn as a missing-glyph box.
- `shaders/glyph.wgsl` reads the instance as raw 32-bit words (shared by native and web, since
  zunk vertex formats are 32-bit). `TextStage` (src/gpu/text_stage.zig) holds the backend-neutral
  staging code with a shaped-run cache; `teak-text`'s `measure` has a small result cache.

- **Image cache is growable** (native + web): the fixed 64-slot table and 64-draw/frame limit are gone (65536 live images, log at the ceiling on native). `releaseImage` is now a required `Gpu` declaration (`validateGpu`). `resources.MAX_RESOURCES` 128 -> 1024 and overflow now logs a warning and counts `Table.dropped`. Part of #7.
- Native text (Linux, Windows) is drawn from a glyph atlas: shaped glyphs are packed into R8
  pages and drawn as instanced quads (`shaders/glyph.wgsl`), replacing the per-string BGRA
  texture cache. Text is rasterized at the device pixel size with quarter-pixel x positioning.
  `.mono` text now snaps advances to whole pixels by default (`FontSpec.snap_advance = null`
  resolves to on for `.mono`; set `false` for the old fractional advances); screenshots shift
  by a pixel here and there. `InitOptions` gains `scale` and `max_atlas_pages`.
- The Gpu contract's `rasterizeText` is optional (web only); the native `Rasterizer` provider
  contract is now per glyph (see `docs/features/gpu.md`). The Windows backend uses stb_truetype
  (`TEAK_FONT`, then `C:\Windows\Fonts\consola.ttf`) and measures through `teak-text` too;
  `Host.registerFont` now works on Windows.

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

- `viewport3d` (= `scene3d` with `SceneCmd.view`): `SceneItem` (mesh key + 3x4 transform + tint + id + flags), grid / gizmo /
  section-cut options, material and highlight colour as data (`core/scene/view.zig`).
- Both scene backends draw `viewport3d` items: one instanced `drawIndexed` per mesh run, per-item transform / tint /
  `highlight` blend / `unlit` / `no_edges` / `hidden`, flat material, and a section-plane `discard` (faces and edges).
  `shaders/scene.wgsl` Globals grew to 176 B; new backend-neutral plan in `src/gpu/scene_pass.zig`.
- Section cut with caps (`View.cut`): stencil-parity caps per closed item (per-item `Item.cap_color`, hatched; `no_cap` for open
  shells), exact cut outlines from a CPU copy of each uploaded mesh (`section.outlinePositions`). Scene targets now use
  `Depth24PlusStencil8`. The canvas `layout` event also carries the rect's window origin (`x`, `y`) and fires when it moves;
  `pick.gizmoLabels` turns that into axis-letter anchors for overlay text.
- `viewport3d` grid and gizmo: `shaders/scene_grid.wgsl` ray-intersects a world plane per pixel (anti-aliased minor / major
  lines, two axis lines, distance and far-plane fade, depth-tested), and a corner axis triad is drawn in a sub-viewport
  from the camera's own rotation. Hit-testing the gizmo is `scene.pick.gizmoHit` (S2).

### Changed

- `Dropdown`/`Combobox`: the keyboard-highlighted row now also takes the theme's `hover_fg` (fixes invisible labels on inverting themes).
- `TextField(N)` is now built on `Editor`: backspace/Delete remove whole grapheme clusters, multi-byte
  characters typed byte-wise are inserted atomically, and it gains `delete`, `home`/`end`, word jumps,
  `undo`/`redo` Msgs (the `Model` field names `len`/`cursor`/`selection_anchor` are unchanged; the byte array is now `buf`).

- **wgpu-native prebuilts updated v25.0.2.2 -> v29.0.1.1** (all four Windows/Linux deps). No source API fixes were needed (the v25 code already used the StringView / callback-info API); device creation now installs an uncaptured-error callback that logs loudly, and sets the device-lost callback mode explicitly.

### Changed (breaking)

- **Scene staging takes the flat item list**: `render.buildFrame(..., scene_draws, scene_items, ...)`,
  `stageDraws(gpu, table, images, scenes, items)` and `Gpu.renderScenes(draws, items)` (one extra slice each; pass
  `scene_items` through from `buildFrame`). `SceneDraw` gained `item_first/item_count`, grid, gizmo, cut, material.
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
