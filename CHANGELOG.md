# Changelog

## Unreleased

### `pointerMsg`: one pointer hook, blank-space clicks delivered

- New optional App hook `pointerMsg(*const Model, PointerEvent(Msg)) ?Msg`.
  `PointerEvent` gained `kind` (`hover` / `down` / `up` / `context`), `button`
  and `isBlank()`. A press on blank space arrives as `kind = .down, hit = null`,
  so an app can clear its own focus (the old hooks never reported it).
  `hoverMsg` / `contextMsg` keep working. chrome and gallery now clear their
  text focus on a blank click.

### Clipboard: Msg-returning hooks (HARDLINE §1 fix)

- New optional App hooks `clipboardText(*const Model, SpecialKey) ?[]const u8`
  (what Ctrl+C / Ctrl+X copy; a pure query, the loop writes the Host clipboard)
  and `clipboardMsg(*const Model, SpecialKey, paste) ?Msg` (the Msg for the
  chord; `paste` is the clipboard text for Ctrl+V, an empty paste is not
  delivered). Helpers `teak.textFieldClipboardMsg` / `teak.textFieldCopyText`.
- **Deprecated:** `keyNeedsClipboard` + `handleClipboard(*Model, ...)` mutated the
  Model outside `update`. They still work when neither new hook is declared, and
  are removed next release. See docs/migration-clipboard.md.
### Kerf dogfood

- `examples/kerf_viewer` is now the Kerf workstation: SECTION / ISO drawings on a pan/zoom canvas (vellum + blue grid,
  the Kerf tessellator ported into the example), the 3D tab, one selection/hover shared by the table, the sheets and the
  3D view, a `TextArea` NOTES card, and an OPERATOR CONSOLE with a scripted Claude (no network). See its README.
- `SpecialKey.shift_enter` (resolved by `InputQueue.resolveKey` on every host); `TextArea.keyMsg` maps it to a newline,
  so "Enter submits, Shift+Enter newline" needs no host code (`submitMsg` still fires only for plain Enter).
### Text perf: 10k runs 8.4 -> ~3.2 ms per warm frame

- teak-text: short pure-ASCII runs measure straight from the face's ASCII tables
  (no cache probe, no shaper); kern pairs are cached per face; the native measure
  cache is 4096 slots / 96 bytes. Results are bit-identical to `shape`.
- `TextStage`: a draw whose geometry, font, colour, clip and text match the same
  draw index last frame replays its glyph instances (Host-side, losable; guarded
  by atlas page generation).
- `tools/bench` compiles again; the chrome `--stress` bench disables idle skip.

### Optional HarfBuzz shaper

- `-Dharfbuzz=true` (library tests) / `.harfbuzz = true` (`NativeWgpuOptions`,
  `HeadlessOptions`): complex scripts (Arabic joining, Hebrew, Indic reordering and
  conjuncts, GPOS mark attachment) are shaped by HarfBuzz 11.2.1, built from its
  single-source `harfbuzz.cc` as a lazy package (default builds fetch nothing and
  are unchanged). Native only. `ShapedGlyph` gains `y` (baseline offset).
  Direction is a stand-in until bidi lands. `examples/notes`: "Show scripts".
  See docs/features/harfbuzz.md.
### Fixed

- **SDF quads lost their records when the vertex buffer grew** (visible with `modern_light`: after a dropdown
  opened, buttons lost their fill, one drew shifted, stray dots appeared). The solid bind group (vertex buffer as
  read-only storage) was rebuilt only when the buffer *handle* changed; a reallocation can hand the old handle
  back, leaving the group on the stale buffer. It now also tracks the buffer size. Regression test:
  `sdf: records survive the vertex buffer growing and shrinking between frames` (`zig build test-gpu`).

### Bidi (UAX #9)

- New `teak.bidi` (pure, `src/core/bidi.zig`): the full Unicode 16 bidirectional algorithm
  (P2-P3, X1-X10 with isolates, W1-W7, N0 bracket pairs, N1-N2, I1-I2, L1-L2) plus per-line
  visual runs, visual-order left/right caret movement (with affinity) and selection highlight
  spans. Passes all 91,707 lines of BidiCharacterTest.txt (a 306-line excerpt is the committed
  regression test). `tools/gen_unicode.zig` now also generates `Bidi_Class` and paired-bracket
  tables. Not yet wired into rendering / `Editor` (see docs/features/bidi.md).
### Overlay anchoring

- `OverlayStyle.anchor_msg` / `anchor_side` / `anchor_gap`: an overlay can be
  placed against a widget by its click / focus Msg (`cmd.leafMsg`), resolved by
  the layout pass from the same frame's rects. `Dropdown` and `Combobox` use it
  by default (`auto_anchor = true`): apps no longer compute `list_x` / `list_y`
  (they apply only with `auto_anchor = false`). Behaviour change: callers that
  passed coordinates now get the auto position; set `.auto_anchor = false` to keep
  the old placement. New `teak.AnchorSide`.

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

### Fixed

- `idle_skip`: a Msg dispatched by `reportLayout` (a canvas `layout` event, `scrollLayoutMsg`) after the frame's
  build left the shown frame stale: the next frame had nothing of its own to do and was skipped as idle, so e.g.
  the viewport example kept showing `canvas 0 x 0` and no grid until the first input. `Runtime.layout_dirty` now
  forces that follow-up frame.
- **"café" (e + U+0301) rendered as "cafe" with faces that lack the combining mark** (the web default face). The shaper now NFC-composes a base + combining
  mark when the face has the precomposed letter (`src/text/compose_table.zig`, generated by `tools/gen_compose.py`: Latin-1/Extended-A/B, Greek and Cyrillic
  pairs, ~330 entries), and the web default face now includes the common combining marks (U+0300-030C, 0327, 0328), so accents it cannot compose are still
  drawn, centred over the base. Wasm: about +2 KB gzip.

### Added

- Bidi in rendering and editing (`teak.bidi_text`): lines of mixed direction draw one run at a time in visual order (`text`, wrapped text, `text_input`, `text_area`), RTL paragraphs right-align, caret / pointer / IME spot / selection rects follow the visual layout, Left/Right arrows move in visual order (runtime for `text_area`, `Editor` for fields); `FontSpec.rtl` makes shapers return a run in visual order.
- **Native file dialogs** (X11, Wayland via the shared service): `open_file` shows a zenity / kdialog (or `$TEAK_PICKER`) dialog on a worker
  thread; `download{ pick = true }` is a Save As dialog; `OpenFile.title`, `Download.pick` / `title`; `TEAK_OPEN` still bypasses.
  **Clipboard image**: new effect `write_clipboard_image{ id, png }` (X11 serves `image/png`; web via zunk `fx.clipboardWriteImage`,
  hotschmoe/zunk#28 must land first for the web build).

- **In-app drag and drop** (docs/features/drag-drop.md): `GroupStyle.drag_id` / `drop_id`, App hook `dragMsg(*const Model, DragEvent)`
  (`start` / `move` / `drop` / `cancel`, innermost drop target + pointer fraction); `examples/todo` reorders by mouse (ghost overlay,
  drop indicator) and by keyboard (Alt+Up/Down via the command table); control command `drag`, `teak-drive drag`, MCP tool `drag`.

- **Commands, shortcuts, command palette** (docs/features/commands.md): App hook `commands(*const Model, *CommandList(Msg))`;
  `teak.Chord` / `teak.Key`; hosts (X11, Win32, web, headless) report `InputState.chords`; `teak.run` matches them before widget
  key handling and swallows claimed chords; `teak.CommandPalette(cap)` (fuzzy, built on `Combobox`, new `Match.fuzzy`);
  `Command.menuLabel` for menu shortcut text; control command `shortcut`; kerf_viewer has Ctrl+K and shortcuts.

- `widgets.color_picker`: SV square + hue strip (canvas triangles), hex / R / G / B fields, swatches.
- **Web IME.** Composition input (Japanese, Chinese, Korean) works in the browser: zunk's new IME bridge keeps a
  hidden `<textarea>` focused while a text field is, the preedit shows inline with an underline and the candidate
  window opens at the caret. New optional Host extension `setImeActive(bool)` next to `setImeSpot`; the preedit
  stays presentation-only (TransientState, see docs/features/text-engine.md 6.7). `tools/web-ime-test.mjs` is the
  CDP acceptance test.
- `widgets.spinner.Spinner`: NumericField with step buttons, arrow / Page / wheel stepping.

- Win32 UIA control patterns (Invoke / Toggle / Value) route AT requests back as input through `teak.A11yActionQueue` and `Host.pollA11yActions`; `ValuePattern` replaces the value-as-Name fallback.
- Accessibility wiring (M3): `Runtime` builds the a11y tree and publishes it to the Host only when it changed
  (`RunOptions.a11y`, default on); `A11yHint` semantics (tablist, tab, tree, table, menu, status/live, progressbar, ...) on
  groups, scrolls and buttons; `A11yNode` gains parent / value / selection / state; optional `Host.pollA11yActions` turns AT
  activate / focus / set-value requests into ordinary input; web wire format v2 (nested ARIA DOM mirror in zunk, focus sync
  both ways, live regions); Win32 UIA control types for the new roles; `tools/a11yprobe.mjs`; docs/features/a11y.md.
- Fixed: the wasm host never called `__zunk_publish_a11y_tree` (a `@hasDecl` on non-`pub` externs was always false);
  examples/todo labels were dangling stack slices on wasm (`|item|` capture by value).
- Keyboard gaps: lists are one Tab stop with roving arrows (`ButtonNav`, `cb.buttonNav`; `DataTable` / `TreeList` rows; gallery tree), `Dropdown.keyMsg` (arrows / Enter / Esc in the open list), Menu key / Shift+F10 (`SpecialKey.context_menu`) opens the context menu at the focused widget through `contextMsg`.
- Keyboard gaps closed: a focusable split divider (`Split.dividerFocusable`, arrows / Home / End via new `CanvasEventKind.key` events), keyboard scrolling of the region around the focused widget (arrows, PageUp / PageDown, Home / End through `scrollMsg`), keyboard focus reported to `hoverMsg` (tooltips show for the focused widget), Escape dismisses toasts (`Toast.keyMsg`). `cb.canvasInteractiveFocusable`.
- **HiDPI scenes.** Native 3D scene targets are rendered at device resolution (logical size x scale) instead of logical-then-magnified; `TEAK_SCALE=2 zig build shot` takes any headless example at 2x. test-gpu pins scene seam position, 1-logical-px line width and 1:1 image texels at scale 2.

- Keyboard navigation everywhere (`RunOptions.keyboard_nav`, default on): Tab / Shift+Tab over buttons, checkboxes, radios, sliders, clickable canvases (toggle switch) and text fields; a focus ring (`Palette.accent`, `Tokens.focus_ring_width`) in every look; Space / Enter activate; arrows move and select inside radio groups and set sliders (`sliderMsg`); modal overlays move focus inside and restore it to the opener on close; focus is keyed by the widget's Msg so it survives list mutations; optional `blurMsg` hook; `nextNavigable` / `prevNavigable`. Focus audit matrix in docs/features/focus.md; gallery asserts every enabled widget is Tab-reachable.
- **Colour emoji (web).** Glyphs no face has and that are emoji / pictographs go through a second, RGBA atlas
  (`TextStage.catlas`, 1024x1024 pages, glyph key `mode = 2`; instance `flags` mode 2 draws the texels as they are, instance alpha
  fades them). The web backend fills it from canvas 2D via zunk's new `gpu.rasterClusterRgba` (needs the zunk change), so the browser's colour
  emoji font shows in colour. Emoji advance one em. Native has the whole RGBA path (pixel-tested with a stub rasterizer) but no source of colour glyphs yet:
  stb cannot read COLR/CBDT/sbix, and decoding sbix/CBDT PNG strikes needs the PNG decoder from the visual-regression PR; until then native shows the face's
  missing-glyph box. Providers opt in with `rasterizeColor(utf8, FontSpec, size_px) ?GlyphBitmap` (RGBA).

- **Scalable (SDF) text.** `FontSpec.scalable = true` draws a glyph from a signed distance field rasterized ONCE (stb
  `GetGlyphSDF`, 32 px source, shared R8 atlas pages, `GlyphKey.mode = 1`) instead of once per size: crisp from below 1x to 8x+ with no
  re-rasterization or blur, positioned at exact (unsnapped) coordinates. `shaders/glyph.wgsl` branches per instance on `flags` (bits 0-1 mode,
  bits 16-31 quad scale) and samples bilinearly. New `CanvasPrimitive.text` draws labels inside a canvas; `examples/viewport` labels its grid
  with scalable text and gains `zig build shot -- out.png --zoom Z`. Native and web (the wasm math shim gained small cbrt/cos/acos; chrome-sized
  apps pay about 4-5 KB gzip for the SDF code). Not for UI text: a distance field is softer than a hinted bitmap at 12-16 px.

- **Win32 leftovers.** The window is an OLE drop target (`IDropTarget`): files, text and images dragged in arrive as `dropped` results (images as PNG <= 1568 px plus an RGBA thumbnail, like web). A Ctrl+V that `handleClipboard` does not claim becomes `pasted_text` or, for a clipboard image (PNG / CF_DIB), a `dropped` image. PNG / JPEG files dropped are `kind = .image` on every native host. The IME mirror (`imeState()`) has a synthetic-message unit test.
- **Hot reload** (docs/features/hot-reload.md): `teak.dev` + `zig build dev` (examples/todo): the App as `libapp.so` behind a stable loader
  that keeps the window, GPU and control socket; the Model (when `typeFingerprint` matches) and TransientState carry across rebuilds.
  `tools/hot_reload_check.sh` is the end-to-end test.

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
- **Scalable (SDF) text.** `FontSpec.scalable = true` draws a glyph from a signed distance field rasterized ONCE (stb
  `GetGlyphSDF`, 32 px source, shared R8 atlas pages, `GlyphKey.mode = 1`) instead of once per size: crisp from below 1x to 8x+ with no
  re-rasterization or blur, positioned at exact (unsnapped) coordinates. `shaders/glyph.wgsl` branches per instance on `flags` (bits 0-1 mode,
  bits 16-31 quad scale) and samples bilinearly. New `CanvasPrimitive.text` draws labels inside a canvas; `examples/viewport` labels its grid
  with scalable text and gains `zig build shot -- out.png --zoom Z`. Native and web (the wasm math shim gained small cbrt/cos/acos; chrome-sized
  apps pay about 4-5 KB gzip for the SDF code). Not for UI text: a distance field is softer than a hinted bitmap at 12-16 px.

- Wrapped text and flex shrink (text-engine PR8/PR9, closes #8): `text` gains `wrap` (`none|word|char|ellipsis`),
  `max_lines`, `text_align`; groups/scrolls gain `shrink`; emitters `paragraph`, `paragraphStyled`, `textEllipsis`.
  Layout runs two extra passes (resolve widths, re-measure heights) only when a frame has wrapped or shrinkable nodes;
  render draws one `TextDraw` per line. HARDLINE hatch 3 amended accordingly. Chrome's NOTES panel shows it.
- **Agent driver** (docs/features/agent-driver.md): `TEAK_CONTROL=<unix socket>` control channel in `teak.run`
  (snapshot, a11y `tree`, click/hover/type/key/scroll by role+label selector, screenshot, msglog, state, wait),
  injected through the Host's real input queue (`Host.injectInput`; headless + X11 hosts); `TEAK_RECORD` /
  `TEAK_REPLAY` input record/replay; `tools/teak-drive` CLI + MCP server (`zig build drive`);
  `teak.headless.serve`; dev inspector overlay (`TEAK_INSPECT=1` / F12, `teak.inspector`);
  `SpecialKey.f12`; optional App hook `debugState`. `examples/todo` gains a `drive` step.
- `widgets.date` (pure calendar maths, ISO parse / format) and `widgets.date_field` (ISO text field + calendar popover, keyboard navigation; "today" comes from a clock effect).
- **Generated API reference**: `tools/gen_api.zig` (`zig build api`) walks `src/teak.zig` with `std.zig.Ast`, follows its `@import`s and writes
  every public signature + `///` doc to `docs/api.md` and `llms-full.txt` (= hand-curated `llms.txt` + the generated part). `zig build audit` fails
  when either is stale, and when a `docs/migration-*.md` is not linked from `llms.txt`.
- Toasts slide in from the right and fade (and slide out on expiry / dismiss) with `teak.anim` tweens; the app
  forwards `animationMsg` frames as `Toast.Msg.frame` and lists `Sub.animation_frame` while `Toast.animating`.
- **Native Wayland host** (`src/platform/wayland.zig`) and a runtime-selecting
  Linux host (`src/platform/linux.zig`, `teak-platform-native` on Linux): one
  binary uses Wayland when `WAYLAND_DISPLAY` is set and works, else X11
  (`TEAK_BACKEND=x11|wayland` forces). xdg-shell window, xkbcommon keyboard
  with client-side repeat, pointer/wheel, clipboard + paste + file/text drops
  on `wl_data_device`, text-input-v3 IME, cursor themes, fractional / integer
  HiDPI, all libraries `dlopen`ed. Protocol tables are generated by
  `tools/gen_wayland.zig` (committed output). `gpu/surface_linux.zig` builds
  the Xlib or Wayland wgpu surface from the host's `NativeHandle` union.
  `zig build test-wayland` runs live tests against weston.

- `teak.unicode`, `teak.linebreak`, `teak.text_wrap`: UAX#29 graphemes, word classes, UAX#14-lite line
  breaking, wrapping/measure/caret mapping (text-engine PR2a/b).
- `teak.editor`: `Editor(cap, undo_cap)` with grapheme-aware editing, word jumps, undo/redo (PR10).
- `SpecialKey`: `ctrl_left/right/home/end` (+ `ctrl_shift_*`), `ctrl_backspace`, `ctrl_delete`,
  `ctrl_shift_z`; `resolveKey` maps them.


- **Cursor shapes**: `teak.CursorShape`, optional `Host.setCursor` (X11, Win32,
  web), `CanvasCmd.cursor`, App hook `cursorFor(model, HoverKind)`. The runtime
  picks the shape from the hovered cmd and calls the Host only on change.
- **X11 HiDPI**: scale from `TEAK_SCALE` / `GDK_SCALE` / `Xft.dpi`; the Host
  reports logical size and pointer coordinates, `InitOptions.scale` from `host.scaleFactor()`
  configures a physical surface and bakes text at device resolution. Headless
  `shot` takes `ShotOptions.scale`.

- `ButtonCmd.underline` / `cb.buttonStyledUnderlined`: one underlined character in a button label (a 1 px quad under the
  glyph). Menu bars and panels use it for their `&` mnemonics.

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

- **macOS backend** (`src/platform/cocoa.zig`, `objc.zig`, `cocoa_data.zig`,
  `gpu/surface_cocoa.zig`, `gpu/native_macos.zig`): Cocoa host driven through
  the Objective-C runtime (libobjc / AppKit / QuartzCore `dlopen`ed, so no SDK
  and no frameworks are needed to build or cross-compile), Metal through
  wgpu-native (macOS prebuilts as lazy deps), NSTextInputClient text + IME
  marked text, Cmd as the primary modifier, precise scrolling, NSPasteboard
  clipboard, file drops, NSCursor shapes, open/save panels, Retina scale.
  `teak.hasNativeBackend(.macos)` is true; `teak.linkHeadless` now works on
  macOS (offscreen Metal screenshots); stb text probes `Menlo.ttc` & friends.

### Fixed

- X11 host failed to compile on first use under Zig 0.17 (`Xlib.load` still
  used the removed `@typeInfo(...).fields`).
- `examples/todo`: item labels pointed at a by-value loop copy (garbled text); iterate by pointer.

- `text_area` Cmd + `TextArea(cap)` component + `textMsg` hook (text-engine PR11a/PR11b, closes the multi-line half of #6):
  wrapped multi-line editing with selection across lines, scrolling, caret, IME composition, pointer (click, shift-click,
  drag incl. outside, double/triple click, wheel), visual Up/Down/Home/End with a sticky column, layout `metrics` events,
  `Host.setImeSpot` from the focused caret; `Editor.applyPointer`; `examples/notes`. See docs/features/text-area.md.
- Wrapped text and flex shrink (text-engine PR8/PR9, closes #8): `text` gains `wrap` (`none|word|char|ellipsis`),
  `max_lines`, `text_align`; groups/scrolls gain `shrink`; emitters `paragraph`, `paragraphStyled`, `textEllipsis`.
  Layout runs two extra passes (resolve widths, re-measure heights) only when a frame has wrapped or shrinkable nodes;
  render draws one `TextDraw` per line. HARDLINE hatch 3 amended accordingly. Chrome's NOTES panel shows it.

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

### Added

- **Win32 parity (closes #5).** Windows now uses the shared stb_truetype text module (so `registerFont` and `letter_spacing` work and layout == render; the GDI measurer/rasterizer and `raster_gdi.zig` are gone), services declarative effects (HTTP via std.http on worker threads, storage under `%APPDATA%\teak\<app>`, clock, command-line `query_param`, native Open/Save dialogs for `open_file`/`download`, clipboard write, `WM_DROPFILES` drops), supports `teak.linkHeadless` (set `TEAK_GPU_FALLBACK=1` for a software adapter), and runs per-monitor DPI v2 with an optional `Host.renderScale` / `Gpu.setScale` pair (`Gpu.setScale` for runtime DPI changes). CI renders headless shots on the Windows runners.
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
