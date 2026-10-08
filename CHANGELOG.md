# Changelog

## Unreleased

### Idle hosts and blink-aware idle

- `Host.waitEvents(timeout_ms)` on X11 (poll on the connection fd), Win32
  (`MsgWaitForMultipleObjectsEx`); `Expose` / `WM_PAINT` now request a repaint.
  Wayland: see its branch.
- **Breaking:** `RunOptions.blink_period` (frames) is replaced by
  `blink_half_ms` (Host-clock ms, default 500; 0 = no blink). The caret phase is
  the new `TransientState.blink_on`; a focused text input no longer prevents
  idle skipping — the loop wakes at each toggle and re-uploads vertices only.

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

- **DataTable: pixel-accurate ellipsis and type-to-search.** New `ButtonStyle.ellipsis` (fixed-width button whose label is cut with U+2026 at the pixel, any
  font); DataTable cells and headers use it instead of counting characters (`ViewOpts.char_w` is gone). Type a prefix to jump to the first row whose
  sort-column cell starts with it (`Table.charMsg`, `Table.searchText`).

- **Tables and lists at scale**: `teak.DataTable` (virtualized, sortable, resizable, selectable, sticky header), `teak.VarList`
  (rows of different heights, measured by layout, scroll-anchored), `teak.TreeList` (virtualized tree, keyboard) and `teak.Scroller`
  (smooth wheel + fling as Model data, driven by `Sub.animation_frame`). New App hooks `virtualRowsMsg` and `modsMsg`;
  `VirtualListStyle` gains `total_extent`, `start_offset`, `id`, `align_cross`. `examples/tables`, `tools/web-frame-bench.mjs`,
  docs/features/tables-at-scale.md.
- **SDF surfaces**: `Radii` (per-corner), soft `Shadow` (blur / spread / offset, CSS semantics), two-stop `Gradient` (linear /
  radial) on `GroupStyle`, `ButtonStyle`, `OverlayStyle`, `TextInputStyle` (`radius`, `gradient`, `soft_shadow`). A rect using
  any of them is one signed-distance quad in the solid vertex stream (`render/sdf.zig`; `shaders/quad.wgsl` reads its record
  back from the vertex buffer bound read-only), anti-aliased with one device pixel at any DPR, with an inside border stroke that
  follows the corners and dithered shadows / gradients. Rects using none draw exactly as before (kerf_viewer / scene3d shots
  are byte-identical). Both backends.
- **Theme tokens**: `Theme.tokens` (`ThemeTokens`: radii, border width, spacing scale, shadow elevations),
  `Theme.fromPaletteTokens`, `button_primary`, and the `Theme.modern_light` / `Theme.modern_dark` presets. The chrome example
  renders both looks (`M` key, header toggle, `zig build shot -- out.png --state modern`).
- **Widgets wave 1** (`teak.widgets`, `src/core/widgets/`; zero new Cmd variants): toggle switch,
  progress bar (determinate + indeterminate), tabs (keyboard), split pane (draggable, min sizes, ratio
  in the Model), tooltip (hover delay via `Sub.at`), toast stack (tick countdown), modal dialog helper,
  menu bar with submenus / mnemonics / F10 + Alt activation, and context menu. See
  `docs/features/widgets.md` and cookbook recipes.
- App hook `sliderMsg(model, grab_msg, value)`: slider drags under `teak.run` (they were click-only: nothing
  turned the pointer position into a value).
- App hooks `hoverMsg` / `contextMsg` (`teak.PointerEvent`, `teak.Box`): the widget under the pointer
  and its previous-frame rect, as data.
- `SpecialKey.f10` and `SpecialKey.alt_tap` (a bare Alt press + release), wired in the Win32, X11 and web
  hosts through `InputQueue.altDown` / `altUp`.
- Tab traversal (`focus.nextFocusable` / `prevFocusable`) is confined to the topmost modal overlay.
- `cb.buttonStyledDisabled`.

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

- `viewport3d` (= `scene3d` with `SceneCmd.view`): `SceneItem` (mesh key + 3x4 transform + tint + id + flags), grid / gizmo /
  section-cut options, material and highlight colour as data (`core/scene/view.zig`).
- Both scene backends draw `viewport3d` items: one instanced `drawIndexed` per mesh run, per-item transform / tint /
  `highlight` blend / `unlit` / `no_edges` / `hidden`, flat material, and a section-plane `discard` (faces and edges).
  `shaders/scene.wgsl` Globals grew to 176 B; new backend-neutral plan in `src/gpu/scene_pass.zig`.
- Section cut with caps (`View.cut`): stencil-parity caps per closed item (per-item `Item.cap_color`, hatched; `no_cap` for open
  shells), exact cut outlines from a CPU copy of each uploaded mesh (`section.outlinePositions`). Scene targets now use
  `Depth24PlusStencil8`. The canvas `layout` event also carries the rect's window origin (`x`, `y`) and fires when it moves;
  `pick.gizmoLabels` turns that into axis-letter anchors for overlay text.
- 2.5D layers in `viewport3d`: `View.planes` (`ScenePlane`: tilted sheets drawn from `CanvasPrimitive`s through the shared
  canvas tessellator, now `render/canvas_tess.zig`; `layer` depth bias, opacity, background, double-sided) and `View.sprites`
  (`SceneSprite`: camera-facing / axis-locked / fixed billboards from image resources, `screen_px` or world size). Opaque
  planes write depth; blended planes and sprites sort back to front (`scene.sort.byDepth`). CPU picking: `pick.planes`,
  `pick.sprites`. `Globals` is 208 B; `Gpu.renderScenes` / `stageDraws` take `SceneData{ items, sprites }` and
  `buildFrame` a `scene_sprites` list. New example `examples/scene_layers`.
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
