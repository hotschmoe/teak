# Feature parity: teak vs egui, Dear ImGui, iced, Slint, Flutter (tool-style apps)

Date: 2026-10-08. Repo state: `master` at `d6f4d34` (teak), branch `docs-parity`. Companion to
[`REVIEW-2026-10.md`](REVIEW-2026-10.md) (see §1, §3.8, §4).

**Scope.** Teak's target is *tool-style apps*: engineering tools, dashboards, agent consoles. It is not
trying to be a general toolkit, so a gap only matters if a tool app needs it. Mobile and rich-media polish
are explicitly low priority.

**How to read the matrix.** `✓` = shipped and usable, `partial` = exists with a documented limit, `✗` = absent.
Teak is the first column and every teak cell carries an evidence note (file path or doc). To re-score teak
after a change, edit only the teak column and the "Last scored" line at the bottom; the competitor columns
are a snapshot.

**Evidence quality.**
- Teak column: read from source and docs in this repo (not re-run unless stated).
- Competitor columns: from the projects' own release notes where I could fetch them (versions and dates below),
  otherwise from my background knowledge of each project, which can be stale or wrong in details. Cells I could
  not confirm for 2026 are marked `?` after the score. Treat the competitor side as "verify before quoting".

Competitor versions checked: egui 0.35/0.36 (2026; 0.36.1 reported Aug 2026), Dear ImGui 1.92.x (1.92.9 notes),
iced 0.14.0 (released 2025-12-07), Slint 1.16 (2026-04-16), Flutter (2026 roadmap post). Sources are listed at the end.

---

## 1. What teak actually ships (inventory)

| Area | What exists | Evidence | Limit |
|---|---|---|---|
| Architecture | TEA loop, flat `[]Cmd` carrying `Msg` values, 3 independent passes, per-frame arena, 8 named hatches | `docs/HARDLINE.md`, `src/core/cmd.zig`, `src/run.zig` | Whole view + layout rebuilt every frame; GPU upload skipped when unchanged |
| Cmd variants | group, scroll, overlay, virtual_list (push/pop pairs), text, rich_text, image, button, text_input, checkbox, radio, slider, divider, canvas, scene3d | `llms.txt` "Commands & CmdBuffer" | Adding a variant touches 9 places (`CLAUDE.md`) |
| Layout | Fixed/min sizes, align, justify, spacer, grow-only flex, scroll regions, form rows | `src/layout/engine.zig`, `docs/features/layout.md` | No wrap, no flex shrink, no grid, depth cap 32 |
| Text | Host-supplied `TextMeasurer`, weights, letter spacing, mixed fonts, rich text spans, UTF-8 | `docs/features/text.md`, `src/core/text.zig` | Single-line only, no shaping/bidi/fallback, grayscale AA, 256-run/frame cap (REVIEW §3.5) |
| Text input | `TextField(cap)` fixed byte buffer, selection, clipboard hooks, `NumericField`, disabled state | `src/core/text_field.zig`, `numeric_field.zig`, `docs/features/widgets.md` | Single line, byte-indexed, no click-to-caret / mouse selection / undo (issue #6) |
| Widgets | button, checkbox, radio, slider, divider, dropdown, numeric field, form rows, modal/overlay | `src/core/{cmd,dropdown,numeric_field}.zig` | No toggle, menu, tooltip, toast, progress, color/date pickers as stock widgets |
| Lists/tables | `push_virtual_list` (uniform row height), `teak.Table` fixed-column monospace, tree via flat pre-order array (example) | `docs/features/tables.md`, `examples/tree`, `docs/features/widgets.md` | No sort/resize/variable height |
| Graphics | Solid quads, hard offset shadow, images (cache of 64), canvas prims (rect, polyline, hline/vline, hatch lines), chart helper, scene3d (flat-lit meshes, line quads) | `docs/features/canvas.md`, `scene3d.md`, `src/core/chart.zig` | Square corners, no gradients, no soft shadow |
| Interaction | Tab/Shift+Tab focus by Msg, key/char/special-key hooks, wheel + scroll regions, canvas pointer events, slider drag, clipboard vtable | `docs/features/focus.md`, `run.md` | No shortcut registry, no cursor shapes, no stock drag-and-drop widget |
| Side effects | `Sub` timers; `effects`: http, download, open_file, clipboard write, storage get/set, clock, query_param; file/image/text drop | `src/core/{sub,effects}.zig`, `docs/features/effects.md` | Native clipboard/drop gaps on X11 (issue #4) |
| Multi-window | One secondary window + dialogs | `docs/features/functional-gaps.md`, `host.md` | Win32 real; others limited |
| A11y | Tree builder (`a11y.zig`), Win32 UIA provider (read-only), web DOM-mirror shim in zunk | `src/input/a11y.zig`, `src/platform/win32.zig` | `teak.run` never publishes the tree (REVIEW §1) |
| Platforms | Win32+wgpu, X11+wgpu (libX11 dlopen), web WebGPU (zunk), headless | `docs/features/host.md` | No macOS, no Wayland-native, no mobile |
| Tooling | `TEAK_SNAPSHOT` text dump, golden snapshot tests, headless `zig build shot` PNG, debug overlay, `llms.txt` (audit-enforced), cookbook, validators | `docs/features/{snapshot,headless}.md`, `llms.txt`, `tools/audit.zig` | No inspector UI, no hot reload, no record/replay (only the Msg stream is replayable by construction) |
| Footprint | zig-teak ~334 KB brotli full app at ReleaseSmall (Kerf bake-off; secondary) | `REVIEW-2026-10.md` §1 | wgpu-native for native builds |

---

## 2. Matrix

Legend as above. Competitor cells are terse by design.

### 2.1 Text

| Feature | teak | egui | Dear ImGui | iced | Slint | Flutter |
|---|---|---|---|---|---|---|
| Shaping (ligatures, kerning, complex scripts) | ✗ no shaper (`layout.md`: "wrapping requires a shaper") | partial (harfrust kerning/ligatures per 0.35 notes; complex scripts limited) | ✗ (no shaping; FreeType only; optional lunasvg/plutosvg) | ✓ cosmic-text shaping | ✓ (via renderer text stack) | ✓ |
| Wrapping | ✗ single-line `text` cmds (`layout.md`) | ✓ | ✓ (`TextWrapped`) | ✓ | ✓ | ✓ |
| Bidi / RTL | ✗ | partial (limited) | ✗ | ✓ (cosmic-text) | partial | ✓ |
| IME | partial: Win32 only; X11/web stub (`host.md`, issue #7) | ✓ improved 0.35; web IME incl. mobile in 0.36 | partial (backend dependent, SDL/Win32 ok) | ✓ new in 0.14 (preedit styling) | ✓ | ✓ |
| Multi-line editing | ✗ single-line `TextField` (`text_field.zig`) | ✓ `TextEdit::multiline` | ✓ `InputTextMultiline` | ✓ `text_editor` | ✓ `TextEdit` | ✓ |
| Undo/redo in text input | ✗ | ✓ | ✓ (basic) | partial | ✓ | ✓ |
| Rich text / styled spans | ✓ `rich_text` + `RichTextSpan`, rich_zig adapter (`examples/counter_greeter`) | ✓ `LayoutJob` | partial (colour via markup hacks / `TextColored`) | ✓ `rich_text`, markdown widget | ✓ `StyledText`, `@markdown` (1.16) | ✓ |
| Font fallback / emoji / CJK | ✗ one registered face per weight (`text.md`) | partial (fallback chain; colour emoji limited) | partial (glyph ranges, merge fonts; 1.92 dynamic fonts) | ✓ system fallback | ✓ | ✓ |
| Crisp scaling / dynamic size | partial: rasterized per size and string, no atlas (REVIEW §1) | ✓ glyph atlas | ✓ 1.92 dynamic re-rasterization | ✓ | ✓ | ✓ |
| Text selection (static text, copy) | partial: input selection only (`widgets.md`) | ✓ selectable labels | partial | partial | partial | ✓ `SelectableText` |

### 2.2 Rendering

| Feature | teak | egui | Dear ImGui | iced | Slint | Flutter |
|---|---|---|---|---|---|---|
| HiDPI | partial: web done; X11 undersized; Win32 unaware (`host.md` truth table) | ✓ | ✓ (backend dependent) | ✓ | ✓ | ✓ |
| Anti-aliasing (shapes) | ✗ axis-aligned quads, polyline segments as quads (`cmd.zig` canvas) | ✓ feathered | ✓ | ✓ | ✓ | ✓ |
| Rounded rects | ✗ (`llms.txt`: "corners are square") | ✓ | ✓ | ✓ | ✓ | ✓ |
| Shadows | partial: hard offset only (`OverlayStyle.shadow`) | ✓ soft | partial | ✓ | ✓ | ✓ |
| Gradients | ✗ | partial (mesh/vertex colour) | partial (draw list gradient rect) | ✓ | ✓ | ✓ |
| Images | ✓ `image` cmd, 64-slot cache (`functional-gaps.md`) | ✓ | ✓ (texture ids) | ✓ | ✓ | ✓ |
| SVG / vector icons | ✗ | ✓ via resvg image loader | partial (plutosvg) | ✓ `svg` widget | ✓ | ✓ |
| Custom 2D canvas | ✓ `canvas` prims (rect, polyline, lines, hatch), pointer events (`canvas.md`) | ✓ `Painter`, plots | ✓ draw list | ✓ `canvas` | ✓ `Path` | ✓ `CustomPainter` |
| 3D viewport | ✓ `scene3d` flat-lit meshes (`scene3d.md`) | partial (paint callback) | partial (callback) | ✓ `shader` widget (wgpu) | partial (wgpu embedding, 1.16) | partial (platform views, Impeller custom shaders) |
| Backend | wgpu-native / WebGPU | wgpu or glow | any (OpenGL, Vulkan, DX, Metal, wgpu...) | wgpu or tiny-skia | Skia, FemtoVG, software, wgpu (1.16) | Impeller / Skia |

### 2.3 Widgets

| Widget | teak | egui | Dear ImGui | iced | Slint | Flutter |
|---|---|---|---|---|---|---|
| Button | ✓ `button`/`buttonStyled`/`buttonDisabled` | ✓ | ✓ | ✓ | ✓ | ✓ |
| Checkbox | ✓ `checkbox` | ✓ | ✓ | ✓ | ✓ | ✓ |
| Radio | ✓ `radio` | ✓ | ✓ | ✓ | ✓ | ✓ |
| Toggle switch | ✗ (compose from checkbox/canvas) | ✓ (toggle example) | ✗ (3rd party) | ✓ `toggler` | ✓ `Switch` | ✓ |
| Slider | ✓ `slider` + `sliderDrag` | ✓ | ✓ | ✓ | ✓ | ✓ |
| Number field / drag value | partial: `NumericField` text parse (`numeric_field.zig`), no drag-value | ✓ `DragValue` | ✓ `DragFloat`, `InputFloat` | partial (3rd party) | partial (`SpinBox`) | partial (formatters) |
| Text field | partial single-line (see 2.1) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Text area | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Dropdown / combo | ✓ `Dropdown(cap)` (`dropdown.zig`; scroll supported) | ✓ `ComboBox` | ✓ `BeginCombo` | ✓ `pick_list`, `combo_box` | ✓ `ComboBox` | ✓ |
| Menu / menubar | ✗ (composable from overlay + buttons; no stock) | ✓ | ✓ | partial (3rd party / iced_aw) | ✓ `MenuBar` (native menus on desktop) | ✓ (`MenuBar`) |
| Context menu | ✗ (overlay at pointer; not stock) | ✓ | ✓ | partial | ✓ `ContextMenuArea` | ✓ |
| Tabs | partial: composed from buttons, `examples/chrome` | partial (`selectable_label` idiom) | ✓ `TabBar` | partial (3rd party) | ✓ `TabWidget` | ✓ |
| Tree view | partial: indented buttons over flat array, `examples/tree` | ✓ `CollapsingHeader` | ✓ `TreeNode` | partial (3rd party) | partial | ✓ (via packages) |
| Table: virtualized / sortable / resizable | partial: fixed-col monospace only (`tables.md`) | ✓ `egui_extras::Table` (virtual, resize; sort manual) | ✓ `BeginTable` (sort, resize, reorder; clipper) | ✓ `table` (0.14) | ✓ `StandardTableView` (sort) | ✓ `DataTable` / packages |
| Virtual list | partial: uniform row height (`push_virtual_list`) | ✓ `show_rows`; variable via `show_viewport` | ✓ `ListClipper` | partial (lazy via 3rd party; scrollables) | ✓ `ListView` | ✓ `ListView.builder` |
| Split panes | ✗ | ✓ `SidePanel` resizable; splitters manual | ✓ (manual / docking) | ✓ `PaneGrid` | partial | partial (packages) |
| Docking | ✗ | partial (3rd party `egui_dock`) | ✓ (docking branch) | partial (`PaneGrid`) | ✗ | ✗ (packages) |
| Dialog / modal | ✓ `push_overlay` modal + `backdrop_msg` | ✓ `Modal` | ✓ popup modal | ✓ `modal` via stack | ✓ `PopupWindow`/`Dialog` | ✓ |
| Tooltip | ✗ (cookbook: non-modal overlay; no hover-delay) | ✓ | ✓ | ✓ with delay (0.14) | ✓ | ✓ |
| Toast / snackbar | ✗ | partial (3rd party `egui-notify`) | ✗ | partial (3rd party) | ✗ | ✓ |
| Progress | ✗ (draw via group/bg or canvas) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Color picker | ✗ | ✓ | ✓ | partial (3rd party) | partial | partial (packages) |
| Date picker | ✗ (`effects` clock only) | partial (`egui_extras::DatePickerButton`) | ✗ | partial (3rd party) | ✓ `DatePicker` (Material) | ✓ |
| Scroll areas | partial: wheel scroll, no momentum/drag-scrollbar (`scroll_extent.zig`) | ✓ (drag, scrollbars; touch) | ✓ | ✓ (auto-scroll, smart scrollbars 0.14) | ✓ (touch flick) | ✓ momentum |
| Drag and drop (in-app) | ✗ no stock widget (`canvasMsg` + Model) | ✓ `dnd_*` | ✓ drag-drop API | partial (3rd party) | partial (experimental 1.16) | ✓ `Draggable` |
| Charts / plots | partial: `chart.lineChartPrimitives` (line only) | ✓ `egui_plot` | ✓ ImPlot (add-on) | partial (3rd party / canvas) | partial (3rd party / Path) | ✓ (packages, e.g. fl_chart) |

### 2.4 Interaction

| Feature | teak | egui | Dear ImGui | iced | Slint | Flutter |
|---|---|---|---|---|---|---|
| Focus + keyboard nav | partial: Tab/Shift+Tab over focusable cmds, Msg-keyed (`focus.zig`); no arrow-key nav within groups | ✓ (Tab, arrows partial) | ✓ keyboard/gamepad nav | partial | ✓ | ✓ |
| Shortcuts / command registry | ✗ app-side `keyCharMsg`/`keySpecialMsg` only | partial (`InputState::consume_shortcut`) | ✓ `Shortcut()` / key chords | partial (`keyboard::listen`, subscription) | ✓ `KeyBinding` (1.16) | ✓ `Shortcuts`/`Actions` |
| Animation | ✗ only `frame_counter` + `Sub` (REVIEW §2.2) | ✓ `animate_value_*` | partial (manual) | ✓ animation API (0.14, wasm too) | ✓ `animate` blocks | ✓ best in class |
| Cursor shapes | ✗ (no Host API found in `host.zig`) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Clipboard text | ✓ vtable, Win32 + web; X11 gap (`host.md`, issue #4) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Clipboard image | ✗ (drop of images exists via effects) | ✓ | partial | partial | partial | ✓ via plugin |
| File pickers (native / web) | partial: `open_file` effect (web), Win32 dialog; no X11 (`effects.md`, `host.md`) | partial (3rd party `rfd`; web via rfd) | ✗ (3rd party) | partial (3rd party `rfd`) | ✓ (native dialogs via crates) | ✓ plugin `file_picker` |
| File drag-and-drop into window | partial: `Drop` effect on web/Win32; X11 XDND missing (issue #4) | ✓ | ✓ (backend) | ✓ | partial | ✓ |

### 2.5 Accessibility

| Feature | teak | egui | Dear ImGui | iced | Slint | Flutter |
|---|---|---|---|---|---|---|
| A11y tree | partial: built (`a11y.zig`), but not published by `teak.run` | ✓ AccessKit (default in eframe) | ✗ (long-standing open request) | ✗ (not in 0.14 notes I could see) | ✓ AccessKit, always on desktop since 1.1 | ✓ |
| Screen reader per platform | partial: Win32 UIA read-only; X11 none; macOS none | ✓ Win, mac, Linux (AT-SPI) | ✗ | ✗ | ✓ Win, mac, Linux | ✓ all |
| Web a11y | partial: DOM-mirror shim in zunk, unwired | partial (AccessKit web experimental) | ✗ | ✗ | partial | ✓ semantics tree |
| Actions back from AT | ✗ | ✓ | ✗ | ✗ | ✓ (custom actions, 1.6+) | ✓ |

### 2.6 Platforms

| Platform | teak | egui | Dear ImGui | iced | Slint | Flutter |
|---|---|---|---|---|---|---|
| Windows | ✓ Win32 + wgpu; DPI-unaware (`host.md`) | ✓ | ✓ | ✓ | ✓ | ✓ |
| macOS | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Linux X11 | ✓ (dlopen libX11, no dev pkg) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Linux Wayland | partial: via XWayland only | ✓ | ✓ | ✓ | ✓ | ✓ |
| Web WebGPU | ✓ zunk, Chromium; Firefox Linux unstable (REVIEW §3.7) | ✓ (wgpu) | partial (bindings) | ✓ (wgpu) | partial (wasm; renderer WebGL/software) | partial (Skwasm/CanvasKit, WebGL) |
| Web WebGL fallback | ✗ | ✓ (glow/wgpu WebGL2) | ✓ | ✓ | ✓ | ✓ |
| Mobile | ✗ out of scope | partial (Android; iOS limited) | partial (backend dependent) | partial | ✓ Android, iOS (maturing) | ✓ |
| Embedded / no-OS | ✗ | partial | ✓ | partial | ✓ MCU, LinuxKMS | partial |

### 2.7 Tooling and agent DX

| Feature | teak | egui | Dear ImGui | iced | Slint | Flutter |
|---|---|---|---|---|---|---|
| Inspector / devtools | partial: `appendDebugOverlay` cmd+rect dump (`debug_overlay.zig`) | partial (inspection protocol 0.35; built-in debug options) | ✓ Metrics/Debug Log windows, Item Picker | ✓ `comet` debugger (0.14) | ✓ live preview + inspector in tooling | ✓ DevTools |
| Hot reload | ✗ | ✗ (3rd party) | ✗ | ✓ (0.14) | ✓ live preview | ✓ stateful |
| Headless testing | ✓ headless Host/Gpu, no-GPU snapshot goldens (`headless.md`, `snapshot.md`) | ✓ `kittest` (AccessKit) | partial (Test Engine, licensed) | ✓ headless mode + e2e (0.14) | ✓ testing backend | ✓ widget tests |
| Snapshot / golden tests | ✓ text snapshot of Cmd+Rect, PNG via `zig build shot` | ✓ image snapshots in kittest | partial | ✓ | partial | ✓ goldens |
| Record / replay | partial: Msg stream replayable by design; no recorder shipped | ✗ | partial (Test Engine) | ✓ time-travel debugging (0.14) | ✗ | ✗ (integration tests only) |
| LLM docs | ✓ `llms.txt` audit-enforced, cookbook | partial (everydev.ai-hosted `llms.txt`; unofficial) | ✗ | ✗ | ✗ | partial (docs MCP) |
| Agent driving a running app | partial: `TEAK_SNAPSHOT` to read, headless scripted input to write; no live control channel | ✓ `egui_mcp` over inspection protocol (0.35, port 5719) | ✗ | ✗ | ✗ | partial (Flutter MCP / driver) |

### 2.8 Footprint (indicative, mostly secondary; measure before quoting)

| Metric | teak | egui | Dear ImGui | iced | Slint | Flutter |
|---|---|---|---|---|---|---|
| Wasm size, small app | ~334 KB brotli ReleaseSmall (Kerf bake-off, `REVIEW` §1) | ~1.2 MB brotli (same bake-off, rust-egui) | n/a (C++ via emscripten, typically a few hundred KB) | ~1 to 2 MB (est.) | ~0.5 to 1 MB (est.) | ~1 to 2+ MB (est.), SharedArrayBuffer headers for multi-threaded Skwasm |
| Build time | fast (Zig; no proc macros) | slow-ish (Rust) | fast (C++) | slow (Rust) | moderate (Rust + Slint compiler) | moderate |
| Deps | none for core lib; wgpu-native prebuilt, zunk for web | many crates | none (single dir) + backend | many crates | many crates | large SDK |
| Language/runtime | Zig 0.16 (0.17 migration pending) | Rust | C++ | Rust | Rust/C++/JS/Python + DSL | Dart |

---

## 3. Ranked gap list for teak (tool-app lens)

Priority: **must** = blocks real tool apps (Kerf-class); **should** = common in tool apps, workaround exists;
**nice** = polish; **out** = not for this positioning. Effort is one engineer or agent-assisted equivalent (calendar),
HARDLINE assumed. This list overlaps and re-ranks REVIEW §3.8; where numbers disagree, prefer this file's note.

| Rank | Gap | Priority | Effort | Implementation note (HARDLINE-consistent) |
|---|---|---|---|---|
| 1 | Text pipeline: glyph atlas, lift 256-run cap, growable buffers | must | 1-2 wk | Entirely in `render/` + `gpu/glyph_cache.zig`; no Cmd/Model change. Make overflow loud. (REVIEW §3.5) |
| 2 | Real text input: UTF-8/grapheme caret, click-to-caret, drag-select, Home/End/word jumps, horizontal scroll, undo; then multi-line text area | must | 2-3 wk | A `TextEditor` *component* with `Model`/`Msg`/`update`/`view` (hatch 1), caret/selection/undo ring as explicit Model fields; mouse caret from `textMeasurer.prefixWidth` + hit-test pointer coords through `canvasMsg`-style event, no hidden widget state. Start from Kerf's `Editor`. |
| 3 | Text wrap + measure-with-width, flex shrink | must | 1-2 wk | New `wrap_width` in text style; measure pass asks measurer for line breaks (greedy, UTF-8 safe) and emits height; result stays derived from `[]Cmd`+`[]Rect`. Unblocks text area, tooltips, logs. |
| 4 | Accessibility wiring: call `publishA11yTree` from `Runtime`, finish web DOM mirror, actions back from AT | should (must for any shipped product) | 2 wk web, +2 wk X11 AT-SPI | Host-side only (hatch 4). Actions arrive as `Msg` via the Cmd's embedded `Msg`, i.e. AT "click" calls the same value hit-test would return. AccessKit is a Rust crate, so on Zig expect a hand-written web mirror + UIA first. |
| 5 | IME on web and X11 | should | 1-2 wk web, 2-3 wk X11 | Hidden `<textarea>` bridge in zunk; `ImeState` already flows into `TransientState`. Needs the #2 editor for composition display. |
| 6 | Animation primitive | should | 3-5 days | Model-driven: a `Tween` helper struct stored in `Model` plus a `Sub` ticking `Msg.tick(now_ms)`; `view` stays pure (no clock read). Add event-driven idle so ticks do not force 60 Hz when no tween/sub is live. |
| 7 | Stock overlay widgets: tooltip (hover-delay), menu/menubar, context menu, toast | should | 1-1.5 wk | Compose from `push_overlay` + buttons; hover-delay via `TransientState` hover time or a `Sub`, never widget-internal timers. Zero new Cmd variants if possible (as Dropdown did). |
| 8 | Tables: variable-height virtual list, sortable/resizable/selectable columns | should | 1-2 wk | Column widths and sort key live in `Model`; header buttons emit `Msg`; row heights as prefix-sum array in Model passed via `VirtualListStyle`. Drag-resize via `canvasMsg`-like pointer events on header dividers. |
| 9 | Shortcut/command registry and cursor shapes | should | 3-5 days | Shortcuts: data table `[]const Binding{ chord, Msg }` returned by an App hook (`shortcuts(*const Model)`), matched by `run`; also powers a command palette. Cursor: `TransientState` field written by hit-test (target kind), applied by Host (hatch 2/4). |
| 10 | Visual polish: SDF rounded rects, soft shadow, gradients, AA edges | nice (should for non-"workstation" skins) | ~1 wk | Shader + `vertex.zig`; extend `GroupStyle`/`ButtonStyle` with `radius`, `OverlayStyle` with blur. Update `cmdsEqual` (ideally reflection-generated, REVIEW gap 12). |
| 11 | Platform: native clipboard + file drop + dialog on X11; Win32 DPI awareness; Wayland-native | should (Linux/Win daily-driver) | 1 wk + 1-2 wk + 3-4 wk | Host layer only. Render-at-scale plan is already written in `host.md`. |
| 12 | Remaining stock widgets: toggle, progress, color picker, date picker, drag-value | nice | 1-2 wk total | All composable from groups/canvas; keep as `teak.*` components with Msg. Progress/toggle first (day each). |
| 13 | Docking / split panes | nice (should for IDE-style tools) | 2-3 wk | Pane tree as plain Model data (flat array of nodes with ratios); splitters are draggable dividers via pointer events; avoids retained layout state. |
| 14 | Font stack: system discovery, fallback, bold/italic, emoji/CJK (needs shaping) | nice now, must for i18n | 4-8 wk | Behind the `TextMeasurer`/rasterizer vtable; HarfBuzz via C, shaped runs cached per string. Largest single dependency decision. |
| 15 | Live inspector / agent control channel (egui_mcp-style) | nice, differentiating | 1-2 wk | `TEAK_SNAPSHOT` is the read half; add a Host-side socket that injects `Msg` from the snapshot's embedded Msg values and returns the next snapshot. Fits HARDLINE because injection reuses the hit-test result type. |
| 16 | Record/replay of Msg stream + hot-reload-friendly Model serialization | nice | 1 wk | Pure consequence of TEA: log `(frame, Msg)`, replay into `update`. Gives deterministic bug repro to agents. |
| 17 | macOS host | out of scope until a product needs it | 4-6 wk | Cocoa Host + Metal via wgpu-native + CoreText or stb rasterizer. |
| 18 | Mobile (iOS/Android), embedded MCU, WebGL fallback | out of scope | n/a | Positioning rules these out; revisit only if web WebGPU adoption stalls. |

### Where teak is ahead or at par for its niche

- Agent-DX: `llms.txt` + audit, text snapshots, headless PNG, golden tests with no GPU. Only egui's new inspection/MCP route comes close on the "drive a live app" half, and iced 0.14 on headless/time-travel.
- Footprint: smallest wasm in the Kerf bake-off; no external crate sprawl.
- Determinism: view/layout/render are pure, so replay and snapshots are free (Dear ImGui and egui are immediate-mode with hidden widget memory; Flutter and Slint hold retained trees).

### Biggest honest deficits versus every competitor

Text (wrap, multi-line edit, shaping, fallback), accessibility actually reaching users, rounded/AA visuals, and platform reach (no macOS, no native Wayland). Items 1-5 in the ranking close the gap that decides whether a tool app is usable at all.

---

## 4. Maintenance notes

- Re-score by editing only the teak column; keep evidence notes to a path or doc.
- When a gap in §3 lands, change its row's priority to "done (PR #)" rather than deleting it.
- Competitor snapshot is dated Oct 2026. Cells marked `(est.)` or uncertain should be verified before external use.

**Last scored (teak):** 2026-10-08 on `master d6f4d34`, before the orchestration session's work.

## 5. Sources (fetched this session)

- iced 0.14.0 release notes: https://github.com/iced-rs/iced/releases/tag/0.14.0 (2025-12-07)
- Slint 1.16 release blog: https://slint.dev/blog/slint-1.16-released (2026-04-16)
- egui 0.35.0 / 0.36.0 release notes (via newreleases.io): https://newreleases.io/project/github/emilk/egui/release/0.35.0 , .../0.36.0
- Dear ImGui v1.92.9 notes (via newreleases.io): https://newreleases.io/project/github/ocornut/imgui/release/v1.92.9
- Flutter and Dart 2026 roadmap: https://flutter.dev/blog/flutter-darts-2026-roadmap (Wasm intended default on web; Impeller migration on Android; desktop multi-window)
- Slint accessibility history (AccessKit since 1.1, custom actions 1.6): https://slint.dev/blog/slint-1.1-released , https://slint.dev/blog/slint-1.6-released
