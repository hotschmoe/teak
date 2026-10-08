# Feature parity: teak vs egui, Dear ImGui, iced, Slint, Flutter (tool-style apps)

Date: 2026-10-08, teak column re-scored 2026-10-09 on `master` `65d629f`. Companion to
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

Scored against `master` `65d629f` (2026-10-09); "queued #N" marks work in an open PR that is not on master yet.

| Area | What exists | Evidence | Limit |
|---|---|---|---|
| Architecture | TEA loop, flat `[]Cmd` carrying `Msg` values, independent passes, per-frame arena, named hatches; frame diff and exhaustive passes derived by reflection | `docs/HARDLINE.md`, `src/core/cmd.zig`, `src/run.zig`, #29 | Whole view + layout rebuilt when the frame changes; quiet frames skip everything (#42, #55) |
| Cmd variants | group, scroll, overlay, virtual_list, text, rich_text, image, button, text_input, text_area, checkbox, radio, slider, divider, canvas, scene3d | `llms.txt` "Commands & CmdBuffer", #40 | Adding a variant touches ~9 places (`CLAUDE.md`) |
| Layout | Fixed/min sizes, align, justify, spacer, flex grow **and shrink**, wrapped text with constraint passing, scroll regions, form rows | `src/layout/engine.zig`, `layout.md`, #35 | No grid |
| Text | stb_truetype rasterizer into an instanced glyph atlas (Linux, web; Windows GDI until #31), `Shaper` interface + SimpleShaper, optional HarfBuzz (#77), NFC compose (#76), measure cache, wrap / ellipsis / shrink, UAX #29 / #14 | `docs/features/text.md`, `text-engine.md`, #14 #18 #28 #35 #36 #45 | No subpixel LCD AA; fallback chain (#44), colour emoji (#71), SDF text (#66) queued |
| Text input | `Editor` (graphemes, undo, word / line motion), `TextField(cap)`, `NumericField`, `TextArea(cap)` multi-line, pointer editing, IME on X11 / Win32 | `core/{editor,text_field,text_area}.zig`, #20, #40, #21 | Fixed byte capacity; web IME queued #49 |
| Widgets | button, checkbox, radio, slider, dropdown, combobox, numeric + date field, toggle, progress, tabs, split, tooltip, toast, dialog, menu bar + context menu, DataTable, VarList, TreeList, kinetic Scroller; `examples/gallery` shows all in three looks | `src/core/widgets/*`, #26 #52 #56 #59 #81, `docs/features/widgets.md` | Color picker (#78), number spinner (#75) queued |
| Lists/tables | virtual list (uniform + variable height), sortable / resizable / selectable `DataTable`, `TreeList`, type-to-search, fixed-col monospace `Table` | `tables-at-scale.md`, #56, #73 | |
| Graphics | SDF rounded rects, borders, gradients, soft shadows, elevation tokens (modern preset); images (growable cache); canvas prims, chart helper; `scene3d` with camera, picking, instancing, grid, section cut, sprites | `render/sdf.zig`, `scene.md`, #48 #23 #16 #27 #41 | No SVG |
| Interaction | Tab/Shift+Tab over text fields on master; key/char/special hooks; wheel + scroll regions; canvas pointer events; slider drag; clipboard vtable; cursor shapes; animation (`teak.anim`) | `focus.md`, `run.md`, `animation.md`, #33 #43 | Whole-UI keyboard nav queued #93-#95; shortcuts + command palette + drag and drop queued #60 |
| Side effects | `Sub` timers incl. animation frames; `effects`: http, download, open_file, clipboard, storage, clock, query_param; file / image / text drop | `core/{sub,effects}.zig`, `effects.md`, #21 | Win32 drop / image paste queued #57 |
| Multi-window | One secondary window + dialogs | `functional-gaps.md`, `host.md` | Win32 real; others limited |
| A11y | Tree builder (`a11y.zig`), Win32 UIA provider (read-only), zunk DOM-mirror shim | `src/input/a11y.zig`, `src/platform/win32.zig` | Publishing, hints, actions back, UIA patterns, web mirror v2 queued #58 / #64 / #65 |
| Platforms | Win32+wgpu, X11+wgpu (libX11 dlopen), **native Wayland** (#47), web WebGPU (zunk), headless | `docs/features/host.md`, `src/platform/` | No macOS (queued #54); web WebGL2 fallback evaluated only (#83) |
| Tooling | `TEAK_SNAPSHOT`, golden snapshots, headless `zig build shot`, `zig build bench`, debug overlay, `llms.txt` (audit-enforced) + generated API reference (#80), cookbook, validators, versioning (#38), CI matrix (#10) | `docs/features/{snapshot,headless}.md`, `docs/api.md`, `tools/` | Agent driver + record/replay (#46), hot reload (#79), visual regression (#32) queued |
| Footprint | ~334 KB brotli full app at ReleaseSmall (Kerf bake-off; secondary); release wasm debug info stripped (-90%, #39) | `REVIEW-2026-10.md` §1 | wgpu-native for native builds |

---

## 2. Matrix

Legend as above. Competitor cells are terse by design.

### 2.1 Text

| Feature | teak | egui | Dear ImGui | iced | Slint | Flutter |
|---|---|---|---|---|---|---|
| Shaping (ligatures, kerning, complex scripts) | partial: built-in SimpleShaper (cmap, kerning, fi/fl/ffi ligatures, combining marks; #18, #45, `src/text/shaper.zig`); NFC compose for faces lacking marks (#76); optional HarfBuzz for Arabic / Indic (`-Dharfbuzz=true`, native only, #77, `docs/features/harfbuzz.md`) | partial (harfrust kerning/ligatures per 0.35 notes; complex scripts limited) | ✗ (no shaping; FreeType only; optional lunasvg/plutosvg) | ✓ cosmic-text shaping | ✓ (via renderer text stack) | ✓ |
| Wrapping | ✓ `wrap` none / word / char / ellipsis, `max_lines`, flex shrink (#35, `core/text_wrap.zig`, `layout.md`) | ✓ | ✓ (`TextWrapped`) | ✓ | ✓ | ✓ |
| Bidi / RTL | partial: UAX #9 algorithm with the Unicode conformance excerpt merged (#74, `core/bidi.zig`, `docs/features/bidi.md`); rendering, caret and selection queued #85 | partial (limited) | ✗ | ✓ (cosmic-text) | partial | ✓ |
| IME | partial: X11 XIM (#21) and Win32 IMM with caret-placed candidate window; web bridge queued #49 | ✓ improved 0.35; web IME incl. mobile in 0.36 | partial (backend dependent, SDL/Win32 ok) | ✓ new in 0.14 (preedit styling) | ✓ | ✓ |
| Multi-line editing | ✓ `TextArea(cap)` + `text_area` Cmd: wrap, scroll, selection, pointer, IME (#40, `docs/features/text-area.md`) | ✓ `TextEdit::multiline` | ✓ `InputTextMultiline` | ✓ `text_editor` | ✓ `TextEdit` | ✓ |
| Undo/redo in text input | ✓ `Editor` + `UndoLog` with typing-burst grouping (#20, `core/editor.zig`) | ✓ | ✓ (basic) | partial | ✓ | ✓ |
| Rich text / styled spans | ✓ `rich_text` + `RichTextSpan`, rich_zig adapter (`examples/counter_greeter`); wrapped rich_text queued #44 | ✓ `LayoutJob` | partial (colour via markup hacks / `TextColored`) | ✓ `rich_text`, markdown widget | ✓ `StyledText`, `@markdown` (1.16) | ✓ |
| Font fallback / emoji / CJK | partial: other registered weights only on master; fallback chain + system faces queued #44; colour emoji queued #71; no bundled CJK face | partial (fallback chain; colour emoji limited) | partial (glyph ranges, merge fonts; 1.92 dynamic fonts) | ✓ system fallback | ✓ | ✓ |
| Crisp scaling / dynamic size | ✓ glyph atlas keyed by physical size and subpixel bin, HiDPI-aware (#14, #28, #45, `gpu/glyph_atlas.zig`); scalable SDF text queued #66 | ✓ glyph atlas | ✓ 1.92 dynamic re-rasterization | ✓ | ✓ | ✓ |
| Text selection (static text, copy) | partial: input selection only (`widgets.md`) | ✓ selectable labels | partial | partial | partial | ✓ `SelectableText` |

### 2.2 Rendering

| Feature | teak | egui | Dear ImGui | iced | Slint | Flutter |
|---|---|---|---|---|---|---|
| HiDPI | partial: web and X11 (#33) scale-aware, Wayland native (#47); Win32 DPI v2 queued #31; scene targets at device resolution queued #62 | ✓ | ✓ (backend dependent) | ✓ | ✓ | ✓ |
| Anti-aliasing (shapes) | partial: rounded rects, borders, shadows are antialiased SDF quads (#48, `render/sdf.zig`); canvas polylines remain quads | ✓ feathered | ✓ | ✓ | ✓ | ✓ |
| Rounded rects | ✓ per-corner `radius` on group, button, input, overlay (#48, `core/surface.zig`) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Shadows | ✓ soft blurred shadows + elevation tokens (#48); hard offset shadow kept | ✓ soft | partial | ✓ | ✓ | ✓ |
| Gradients | ✓ linear `Gradient` on group and button (#48) | partial (mesh/vertex colour) | partial (draw list gradient rect) | ✓ | ✓ | ✓ |
| Images | ✓ `image` cmd; growable cache with `releaseImage` (#23, `functional-gaps.md`) | ✓ | ✓ (texture ids) | ✓ | ✓ | ✓ |
| SVG / vector icons | ✗ | ✓ via resvg image loader | partial (plutosvg) | ✓ `svg` widget | ✓ | ✓ |
| Custom 2D canvas | ✓ `canvas` prims (rect, polyline, lines, hatch), pointer events (`canvas.md`) | ✓ `Painter`, plots | ✓ draw list | ✓ `canvas` | ✓ `Path` | ✓ `CustomPainter` |
| 3D viewport | ✓ `scene3d`: camera, picking, instanced items with highlight, grid + gizmo, section cut, plane layers (#16, #24, #27, #34, #37, #41, `scene.md`) | partial (paint callback) | partial (callback) | ✓ `shader` widget (wgpu) | partial (wgpu embedding, 1.16) | partial (platform views, Impeller custom shaders) |
| Backend | wgpu-native / WebGPU (wgpu-native v29, #19); WebGL2 fallback evaluated, policy in `docs/features/web-fallback.md` (#83) | wgpu or glow | any (OpenGL, Vulkan, DX, Metal, wgpu...) | wgpu or tiny-skia | Skia, FemtoVG, software, wgpu (1.16) | Impeller / Skia |

### 2.3 Widgets

| Widget | teak | egui | Dear ImGui | iced | Slint | Flutter |
|---|---|---|---|---|---|---|
| Button | ✓ `button`/`buttonStyled`/`buttonDisabled` | ✓ | ✓ | ✓ | ✓ | ✓ |
| Checkbox | ✓ `checkbox` | ✓ | ✓ | ✓ | ✓ | ✓ |
| Radio | ✓ `radio` | ✓ | ✓ | ✓ | ✓ | ✓ |
| Toggle switch | ✓ `widgets.toggle` (#52, `src/core/widgets/toggle.zig`) | ✓ (toggle example) | ✗ (3rd party) | ✓ `toggler` | ✓ `Switch` | ✓ |
| Slider | ✓ `slider` + `sliderDrag` | ✓ | ✓ | ✓ | ✓ | ✓ |
| Number field / drag value | partial: `NumericField` (+ `setValue`, #87) and `date_field`; spinner queued #75; no drag-value | ✓ `DragValue` | ✓ `DragFloat`, `InputFloat` | partial (3rd party) | partial (`SpinBox`) | partial (formatters) |
| Text field | ✓ single-line: grapheme-aware, selection, undo, clipboard, IME (#20, `text_field.zig`) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Text area | ✓ `TextArea` (#40) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Dropdown / combo | ✓ `Dropdown(cap)` with scroll, `Combobox` searchable select (#26), auto-anchoring (#90) | ✓ `ComboBox` | ✓ `BeginCombo` | ✓ `pick_list`, `combo_box` | ✓ `ComboBox` | ✓ |
| Menu / menubar | ✓ `widgets.menu`: menubar, submenus, keyboard, mnemonic underlines (#52, #68) | ✓ | ✓ | partial (3rd party / iced_aw) | ✓ `MenuBar` (native menus on desktop) | ✓ (`MenuBar`) |
| Context menu | ✓ `widgets.menu` context menu (#52); keyboard open queued #95 | ✓ | ✓ | partial | ✓ `ContextMenuArea` | ✓ |
| Tabs | ✓ `widgets.tabs` (#52); roving arrows tied to focus wait on #58 | partial (`selectable_label` idiom) | ✓ `TabBar` | partial (3rd party) | ✓ `TabWidget` | ✓ |
| Tree view | ✓ `TreeList` (#56, `core/tree_list.zig`) | ✓ `CollapsingHeader` | ✓ `TreeNode` | partial (3rd party) | partial | ✓ (via packages) |
| Table: virtualized / sortable / resizable | ✓ `DataTable`: virtual rows, sort, column resize, selection, type-to-search (#56, #73, `tables-at-scale.md`) | ✓ `egui_extras::Table` (virtual, resize; sort manual) | ✓ `BeginTable` (sort, resize, reorder; clipper) | ✓ `table` (0.14) | ✓ `StandardTableView` (sort) | ✓ `DataTable` / packages |
| Virtual list | ✓ `VarList` variable row heights (#56) and uniform `push_virtual_list` | ✓ `show_rows`; variable via `show_viewport` | ✓ `ListClipper` | partial (lazy via 3rd party; scrollables) | ✓ `ListView` | ✓ `ListView.builder` |
| Split panes | ✓ `widgets.split` (#52); keyboard resize queued #94 | ✓ `SidePanel` resizable; splitters manual | ✓ (manual / docking) | ✓ `PaneGrid` | partial | partial (packages) |
| Docking | ✗ | partial (3rd party `egui_dock`) | ✓ (docking branch) | partial (`PaneGrid`) | ✗ | ✗ (packages) |
| Dialog / modal | ✓ `push_overlay` modal + `widgets.dialog` (keys, backdrop, #52); focus trap and restore queued #93 | ✓ `Modal` | ✓ popup modal | ✓ `modal` via stack | ✓ `PopupWindow`/`Dialog` | ✓ |
| Tooltip | ✓ `widgets.tooltip` with hover delay (#52); on keyboard focus queued #94 | ✓ | ✓ | ✓ with delay (0.14) | ✓ | ✓ |
| Toast / snackbar | ✓ `widgets.toast`, slide / fade (#52, #69); Escape dismiss queued #94 | partial (3rd party `egui-notify`) | ✗ | partial (3rd party) | ✗ | ✓ |
| Progress | ✓ `widgets.progress` (#52) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Color picker | ✗ queued #78 | ✓ | ✓ | partial (3rd party) | partial | partial (packages) |
| Date picker | ✓ `widgets.date_field`: ISO field + month-grid popover, no wall clock in `view` (#81) | partial (`egui_extras::DatePickerButton`) | ✗ | partial (3rd party) | ✓ `DatePicker` (Material) | ✓ |
| Scroll areas | partial: wheel scroll regions + kinetic `Scroller` (#56); keyboard scrolling queued #94 | ✓ (drag, scrollbars; touch) | ✓ | ✓ (auto-scroll, smart scrollbars 0.14) | ✓ (touch flick) | ✓ momentum |
| Drag and drop (in-app) | ✗ queued #60 (drag and drop); `canvasMsg` + Model until then | ✓ `dnd_*` | ✓ drag-drop API | partial (3rd party) | partial (experimental 1.16) | ✓ `Draggable` |
| Charts / plots | partial: `chart.lineChartPrimitives` (line only) | ✓ `egui_plot` | ✓ ImPlot (add-on) | partial (3rd party / canvas) | partial (3rd party / Path) | ✓ (packages, e.g. fl_chart) |

### 2.4 Interaction

| Feature | teak | egui | Dear ImGui | iced | Slint | Flutter |
|---|---|---|---|---|---|---|
| Focus + keyboard nav | partial on master: Tab / Shift+Tab over text fields, Msg-keyed focus (`focus.zig`); queued #93-#95: every widget, focus ring, Space/Enter, arrows in groups / lists / sliders, modal trap + restore | ✓ (Tab, arrows partial) | ✓ keyboard/gamepad nav | partial | ✓ | ✓ |
| Shortcuts / command registry | partial: menu mnemonics (#68), app-side `keyCharMsg` / `keySpecialMsg`; registry + command palette queued #60 | partial (`InputState::consume_shortcut`) | ✓ `Shortcut()` / key chords | partial (`keyboard::listen`, subscription) | ✓ `KeyBinding` (1.16) | ✓ `Shortcuts`/`Actions` |
| Animation | ✓ `teak.anim` tweens + `Sub.animation_frame`, event-driven idle so settled UIs sleep (#43, #42, #55, `animation.md`) | ✓ `animate_value_*` | partial (manual) | ✓ animation API (0.14, wasm too) | ✓ `animate` blocks | ✓ best in class |
| Cursor shapes | ✓ `Host.setCursor(shape)` set from the hovered target (#33) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Clipboard text | ✓ vtable on Win32, web and X11 (#21); Msg-returning hooks queued #70 | ✓ | ✓ | ✓ | ✓ | ✓ |
| Clipboard image | partial: images arrive as drop / paste effects on web and X11 (#21); Win32 image paste queued #57 | ✓ | partial | partial | partial | ✓ via plugin |
| File pickers (native / web) | partial: `open_file` effect (web), Win32 dialog; native dialogs on other hosts queued #60 | partial (3rd party `rfd`; web via rfd) | ✗ (3rd party) | partial (3rd party `rfd`) | ✓ (native dialogs via crates) | ✓ plugin `file_picker` |
| File drag-and-drop into window | ✓ web, X11 XDND (#21); Win32 IDropTarget queued #57 | ✓ | ✓ (backend) | ✓ | partial | ✓ |

### 2.5 Accessibility

| Feature | teak | egui | Dear ImGui | iced | Slint | Flutter |
|---|---|---|---|---|---|---|
| A11y tree | partial on master: built (`a11y.zig`) but not published by `teak.run`; queued #58 publishes it on change with semantic hints | ✓ AccessKit (default in eframe) | ✗ (long-standing open request) | ✗ (not in 0.14 notes I could see) | ✓ AccessKit, always on desktop since 1.1 | ✓ |
| Screen reader per platform | partial on master: Win32 UIA read-only; queued #58 / #65: UIA Invoke / Toggle / Value, web DOM mirror v2; X11 AT-SPI feasible via AccessKit (`docs/features/a11y.md` in #58), macOS none | ✓ Win, mac, Linux (AT-SPI) | ✗ | ✗ | ✓ Win, mac, Linux | ✓ all |
| Web a11y | partial: DOM-mirror shim in zunk, unwired on master; queued #58 + zunk#26 (nested ARIA tree, live regions, focus sync) | partial (AccessKit web experimental) | ✗ | ✗ | partial | ✓ semantics tree |
| Actions back from AT | ✗ on master; queued #58 (activate / focus / set value as ordinary input), #65 (UIA patterns) | ✓ | ✗ | ✗ | ✓ (custom actions, 1.6+) | ✓ |

### 2.6 Platforms

| Platform | teak | egui | Dear ImGui | iced | Slint | Flutter |
|---|---|---|---|---|---|---|
| Windows | ✓ Win32 + wgpu; DPI v2, stb text and effects queued #31; live-window CI queued #67 | ✓ | ✓ | ✓ | ✓ | ✓ |
| macOS | ✗ on master; queued #54 (Cocoa host + Metal via wgpu-native) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Linux X11 | ✓ (dlopen libX11, no dev pkg) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Linux Wayland | ✓ native Wayland host with runtime backend selection (#47, `src/platform/wayland.zig`) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Web WebGPU | ✓ zunk, Chromium; Firefox Linux unstable (REVIEW §3.7) | ✓ (wgpu) | partial (bindings) | ✓ (wgpu) | partial (wasm; renderer WebGL/software) | partial (Skwasm/CanvasKit, WebGL) |
| Web WebGL fallback | ✗ (policy and WebGL2 evaluation: `docs/features/web-fallback.md`, #83) | ✓ (glow/wgpu WebGL2) | ✓ | ✓ | ✓ | ✓ |
| Mobile | ✗ out of scope | partial (Android; iOS limited) | partial (backend dependent) | partial | ✓ Android, iOS (maturing) | ✓ |
| Embedded / no-OS | ✗ | partial | ✓ | partial | ✓ MCU, LinuxKMS | partial |

### 2.7 Tooling and agent DX

| Feature | teak | egui | Dear ImGui | iced | Slint | Flutter |
|---|---|---|---|---|---|---|
| Inspector / devtools | partial: `appendDebugOverlay` cmd+rect dump (`debug_overlay.zig`); live agent driver queued #46 | partial (inspection protocol 0.35; built-in debug options) | ✓ Metrics/Debug Log windows, Item Picker | ✓ `comet` debugger (0.14) | ✓ live preview + inspector in tooling | ✓ DevTools |
| Hot reload | ✗ on master; queued #79 (libapp.so + stable loader, Model kept) | ✗ (3rd party) | ✗ | ✓ (0.14) | ✓ live preview | ✓ stateful |
| Headless testing | ✓ headless Host/Gpu, no-GPU snapshot goldens (`headless.md`, `snapshot.md`) | ✓ `kittest` (AccessKit) | partial (Test Engine, licensed) | ✓ headless mode + e2e (0.14) | ✓ testing backend | ✓ widget tests |
| Snapshot / golden tests | ✓ text snapshot of Cmd+Rect, PNG via `zig build shot`; visual-regression suite queued #32 | ✓ image snapshots in kittest | partial | ✓ | partial | ✓ goldens |
| Record / replay | partial: Msg stream replayable by design; recorder + replay queued #46 | ✗ | partial (Test Engine) | ✓ time-travel debugging (0.14) | ✗ | ✗ (integration tests only) |
| LLM docs | ✓ `llms.txt` audit-enforced, cookbook, generated API reference + `llms-full.txt` (#80) | partial (everydev.ai-hosted `llms.txt`; unofficial) | ✗ | ✗ | ✗ | partial (docs MCP) |
| Agent driving a running app | partial: `TEAK_SNAPSHOT` to read, headless scripted input to write; control channel + MCP queued #46 | ✓ `egui_mcp` over inspection protocol (0.35, port 5719) | ✗ | ✗ | ✗ | partial (Flutter MCP / driver) |

### 2.8 Footprint (indicative, mostly secondary; measure before quoting)

| Metric | teak | egui | Dear ImGui | iced | Slint | Flutter |
|---|---|---|---|---|---|---|
| Wasm size, small app | ~334 KB brotli ReleaseSmall (Kerf bake-off, `REVIEW` §1) | ~1.2 MB brotli (same bake-off, rust-egui) | n/a (C++ via emscripten, typically a few hundred KB) | ~1 to 2 MB (est.) | ~0.5 to 1 MB (est.) | ~1 to 2+ MB (est.), SharedArrayBuffer headers for multi-threaded Skwasm |
| Build time | fast (Zig; no proc macros) | slow-ish (Rust) | fast (C++) | slow (Rust) | moderate (Rust + Slint compiler) | moderate |
| Deps | none for core lib; wgpu-native prebuilt, zunk for web | many crates | none (single dir) + backend | many crates | many crates | large SDK |
| Language/runtime | Zig 0.17 (#17) | Rust | C++ | Rust | Rust/C++/JS/Python + DSL | Dart |

---

## 3. Ranked gap list for teak (tool-app lens)

Priority: **must** = blocks real tool apps (Kerf-class); **should** = common in tool apps, workaround exists;
**nice** = polish; **out** = not for this positioning. Effort is one engineer or agent-assisted equivalent (calendar),
HARDLINE assumed. This list overlaps and re-ranks REVIEW §3.8; where numbers disagree, prefer this file's note.

| Rank | Gap | Priority | Effort | Implementation note (HARDLINE-consistent) |
|---|---|---|---|---|
| 1 | Text pipeline: glyph atlas, lift 256-run cap, growable buffers | done (#14, #28, #45) (was: must) | 1-2 wk | Entirely in `render/` + `gpu/glyph_cache.zig`; no Cmd/Model change. Make overflow loud. (REVIEW §3.5) |
| 2 | Real text input: UTF-8/grapheme caret, click-to-caret, drag-select, Home/End/word jumps, horizontal scroll, undo; then multi-line text area | done (#20, #40; web IME queued #49) (was: must) | 2-3 wk | A `TextEditor` *component* with `Model`/`Msg`/`update`/`view` (hatch 1), caret/selection/undo ring as explicit Model fields; mouse caret from `textMeasurer.prefixWidth` + hit-test pointer coords through `canvasMsg`-style event, no hidden widget state. Start from Kerf's `Editor`. |
| 3 | Text wrap + measure-with-width, flex shrink | done (#35) (was: must) | 1-2 wk | New `wrap_width` in text style; measure pass asks measurer for line breaks (greedy, UTF-8 safe) and emits height; result stays derived from `[]Cmd`+`[]Rect`. Unblocks text area, tooltips, logs. |
| 4 | Accessibility wiring: call `publishA11yTree` from `Runtime`, finish web DOM mirror, actions back from AT | queued #58, #64, #65 (must for any shipped product) (was: should (must for any shipped product)) | 2 wk web, +2 wk X11 AT-SPI | Host-side only (hatch 4). Actions arrive as `Msg` via the Cmd's embedded `Msg`, i.e. AT "click" calls the same value hit-test would return. AccessKit is a Rust crate, so on Zig expect a hand-written web mirror + UIA first. |
| 5 | IME on web and X11 | partial: X11 + Win32 done (#21); web queued #49 (was: should) | 1-2 wk web, 2-3 wk X11 | Hidden `<textarea>` bridge in zunk; `ImeState` already flows into `TransientState`. Needs the #2 editor for composition display. |
| 6 | Animation primitive | done (#42, #43, #55) (was: should) | 3-5 days | Model-driven: a `Tween` helper struct stored in `Model` plus a `Sub` ticking `Msg.tick(now_ms)`; `view` stays pure (no clock read). Add event-driven idle so ticks do not force 60 Hz when no tween/sub is live. |
| 7 | Stock overlay widgets: tooltip (hover-delay), menu/menubar, context menu, toast | done (#52, #68, #69) (was: should) | 1-1.5 wk | Compose from `push_overlay` + buttons; hover-delay via `TransientState` hover time or a `Sub`, never widget-internal timers. Zero new Cmd variants if possible (as Dropdown did). |
| 8 | Tables: variable-height virtual list, sortable/resizable/selectable columns | done (#56, #73) (was: should) | 1-2 wk | Column widths and sort key live in `Model`; header buttons emit `Msg`; row heights as prefix-sum array in Model passed via `VirtualListStyle`. Drag-resize via `canvasMsg`-like pointer events on header dividers. |
| 9 | Shortcut/command registry and cursor shapes | partial: cursor shapes done (#33); shortcuts + palette queued #60 (was: should) | 3-5 days | Shortcuts: data table `[]const Binding{ chord, Msg }` returned by an App hook (`shortcuts(*const Model)`), matched by `run`; also powers a command palette. Cursor: `TransientState` field written by hit-test (target kind), applied by Host (hatch 2/4). |
| 10 | Visual polish: SDF rounded rects, soft shadow, gradients, AA edges | done (#48) (was: nice (should for non-"workstation" skins)) | ~1 wk | Shader + `vertex.zig`; extend `GroupStyle`/`ButtonStyle` with `radius`, `OverlayStyle` with blur. Update `cmdsEqual` (ideally reflection-generated, REVIEW gap 12). |
| 11 | Platform: native clipboard + file drop + dialog on X11; Win32 DPI awareness; Wayland-native | partial: X11 clipboard / XDND / HiDPI (#21, #33), Wayland (#47) done; Win32 DPI + drop queued #31, #57 (was: should (Linux/Win daily-driver)) | 1 wk + 1-2 wk + 3-4 wk | Host layer only. Render-at-scale plan is already written in `host.md`. |
| 12 | Remaining stock widgets: toggle, progress, color picker, date picker, drag-value | partial: toggle, progress (#52), date (#81) done; color picker #78, spinner #75 queued (was: nice) | 1-2 wk total | All composable from groups/canvas; keep as `teak.*` components with Msg. Progress/toggle first (day each). |
| 13 | Docking / split panes | partial: split panes done (#52); docking not started (was: nice (should for IDE-style tools)) | 2-3 wk | Pane tree as plain Model data (flat array of nodes with ratios); splitters are draggable dividers via pointer events; avoids retained layout state. |
| 14 | Font stack: system discovery, fallback, bold/italic, emoji/CJK (needs shaping) | partial: shaper + HarfBuzz + NFC done (#18, #76, #77); fallback chain #44, emoji #71 queued; no system discovery (was: nice now, must for i18n) | 4-8 wk | Behind the `TextMeasurer`/rasterizer vtable; HarfBuzz via C, shaped runs cached per string. Largest single dependency decision. |
| 15 | Live inspector / agent control channel (egui_mcp-style) | queued #46 (was: nice, differentiating) | 1-2 wk | `TEAK_SNAPSHOT` is the read half; add a Host-side socket that injects `Msg` from the snapshot's embedded Msg values and returns the next snapshot. Fits HARDLINE because injection reuses the hit-test result type. |
| 16 | Record/replay of Msg stream + hot-reload-friendly Model serialization | queued #46 (record/replay), #79 (hot reload) (was: nice) | 1 wk | Pure consequence of TEA: log `(frame, Msg)`, replay into `update`. Gives deterministic bug repro to agents. |
| 17 | macOS host | queued #54 (was: out of scope until a product needs it) | 4-6 wk | Cocoa Host + Metal via wgpu-native + CoreText or stb rasterizer. |
| 18 | Mobile (iOS/Android), embedded MCU, WebGL fallback | out of scope | n/a | Positioning rules these out; revisit only if web WebGPU adoption stalls. |

### Where teak is ahead or at par for its niche

- Agent-DX: `llms.txt` + audit, text snapshots, headless PNG, golden tests with no GPU. Only egui's new inspection/MCP route comes close on the "drive a live app" half, and iced 0.14 on headless/time-travel.
- Footprint: smallest wasm in the Kerf bake-off; no external crate sprawl.
- Keyboard and a11y are the deliberate focus of the open queue: #93-#95 (whole-UI keyboard navigation with a themed focus ring) and #58 (tree publishing, actions back from AT).
- Determinism: view/layout/render are pure, so replay and snapshots are free (Dear ImGui and egui are immediate-mode with hidden widget memory; Flutter and Slint hold retained trees).

### Biggest honest deficits versus every competitor

Accessibility actually reaching users (#58 queued), complex-script text end to end (bidi rendering #85, fallback #44, emoji #71 queued), keyboard operation of every widget (#93-#95 queued), and platform reach (no macOS yet, #54 queued). Text wrapping, multi-line editing, rounded / shadowed visuals, the stock widget set and native Wayland are no longer on this list.

---

## 4. Maintenance notes

- Re-score by editing only the teak column; keep evidence notes to a path or doc.
- When a gap in §3 lands, change its row's priority to "done (PR #)" rather than deleting it.
- Competitor snapshot is dated Oct 2026. Cells marked `(est.)` or uncertain should be verified before external use.

**Last scored (teak):** 2026-10-09 on `master 65d629f` (merged PRs through #92); items marked "queued #N" are open PRs and flip to ✓ when they merge. Competitor columns are unchanged from 2026-10-08.

## 5. Sources (fetched this session)

- iced 0.14.0 release notes: https://github.com/iced-rs/iced/releases/tag/0.14.0 (2025-12-07)
- Slint 1.16 release blog: https://slint.dev/blog/slint-1.16-released (2026-04-16)
- egui 0.35.0 / 0.36.0 release notes (via newreleases.io): https://newreleases.io/project/github/emilk/egui/release/0.35.0 , .../0.36.0
- Dear ImGui v1.92.9 notes (via newreleases.io): https://newreleases.io/project/github/ocornut/imgui/release/v1.92.9
- Flutter and Dart 2026 roadmap: https://flutter.dev/blog/flutter-darts-2026-roadmap (Wasm intended default on web; Impeller migration on Android; desktop multi-window)
- Slint accessibility history (AccessKit since 1.1, custom actions 1.6): https://slint.dev/blog/slint-1.1-released , https://slint.dev/blog/slint-1.6-released
