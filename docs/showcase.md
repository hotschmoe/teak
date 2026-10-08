# Showcase

What Teak looks like today, rendered by the real examples. Every image is a headless wgpu shot (native) or a headless
Chromium / WebGPU capture (web) driven by scripted input, so each one is also a layout + render + hit-routing check.
Regenerate them with `tools/showcase.sh` (it builds `tools/qa`, runs the states in `tools/qa/scripts.zig`, and
compresses to an adaptive 256-colour PNG; about 1.4 MB in total). Captions name the feature and the PR that landed it.

## Kerf workstation (`examples/kerf_viewer`)

![SECTION drawing](images/showcase/kerf-section.png)

**SECTION**: a Kerf drawing tessellated into one triangle batch on an interactive canvas: vellum and blue grid, true pen
weights, hatch, dashes, stroke font; selecting the stem in any view tints it here and highlights it in the parts table
and the 3D view. Hover outlines the footing. (kerf dogfood #89, canvas triangles #14/#41, QA fixes #97-#106)

![ISO drawing](images/showcase/kerf-iso.png)

**ISO**: the same document's iso drawing (flush-psl-2x6), `beam` selected from the table; hover and select map drawing
`src#instance` ids to mesh parts. (#89)

![3D section cut](images/showcase/kerf-3d-cut.png)

**3D with a section cut**: per-part items with highlight flags, ground grid, axis gizmo, stencil-parity cut with manila
caps and hatch; open shells are outlined, not capped. (scene S3-S6: #24 #27 #34 #37, viewer #30)

![Command palette](images/showcase/kerf-palette.png)

**Command palette**: Ctrl+K opens a filtered list over the app's command table (the same table builds the menu bar and the
shortcuts shown beside each entry). (shortcuts + palette #60, menu bar from commands #116)

![Chat console](images/showcase/kerf-chat.png)

**OPERATOR CONSOLE**: a multi-line `TextArea` (Enter sends, Shift+Enter newline), manila message cards with `**bold**`
rich text, a scripted "Claude" (no network) whose tool lines drive the UI (select, cut), paced by a `Sub.every` that
only exists while a reply is pending. (#89, TextArea #40, Enter fix #112)

![scene_layers](images/showcase/scene-layers.png)

**2.5D layers** (`examples/scene_layers`): drawing sheets as tilted planes with canvas content, billboard markers,
depth sorting among 3D parts and labels over the scene. (#41)

## Native and web side by side (left: native wgpu, right: Chromium WebGPU)

![Kerf, native and web](images/showcase/pair-kerf.png)
![Gallery, native and web](images/showcase/pair-gallery.png)
![Chrome modern, native and web](images/showcase/pair-chrome-modern.png)
![Tables, native and web](images/showcase/pair-tables.png)

Same App code, same layout; the web build uses IBM Plex Mono, native uses the system / bundled face, so rows differ by
a couple of pixels. (web backend, text atlas #28/#45, startup #82)

## HiDPI

![2x crop](images/showcase/hidpi-2x-crop.png)

A 2x device-pixel crop of the SECTION view (no resampling): hairlines stay one logical pixel (two device pixels),
text is rasterized at device size, the tessellated linework is antialiased with 1 px fringes. (HiDPI #33 #62)

## Gallery (`examples/gallery`): every page in three looks

Retro (DESIGN-style paper and ink), dark and light, all from `Theme` presets; the widgets are wave 1 (#52) plus tables
at scale (#56, #73), text areas (#40) and the 3D / image resources hook. Gallery #59, light-look fixes #98 #102.

| Retro | Dark | Light |
|---|---|---|
| ![](images/showcase/gallery-retro-controls.png) | ![](images/showcase/gallery-dark-controls.png) | ![](images/showcase/gallery-light-controls.png) |
| Controls: buttons, toggle, checkbox / radio, sliders, rich text | Controls, dark | Controls, light (disabled states derived from the palette, #98) |
| ![](images/showcase/gallery-retro-inputs.png) | | ![](images/showcase/gallery-light-inputs.png) |
| Inputs: text field, underline field, NumericField, dropdown, searchable combobox, live TextArea | | Inputs, light |
| ![](images/showcase/gallery-retro-data.png) | ![](images/showcase/gallery-dark-data.png) | ![](images/showcase/gallery-light-data.png) |
| Data: fixed-column table, tree, 10k-row virtual list, canvas chart, scroll region | Data, dark | Data, light |
| ![](images/showcase/gallery-retro-overlays.png) | ![](images/showcase/gallery-dark-overlays.png) | |
| Overlays: tooltips, context menu, menu bar, toasts, dialogs | Overlays, dark | |
| ![](images/showcase/gallery-retro-layout.png) | ![](images/showcase/gallery-dark-layout.png) | |
| Layout: tabs, progress, draggable split pane | Layout, dark | |
| ![](images/showcase/gallery-retro-scene.png) | | ![](images/showcase/gallery-light-scene.png) |
| 3D and images: `viewport3d`, RGBA texture, resources hook | | 3D and images, light |

## Chrome, tables, notes, todo

![Chrome, modern look](images/showcase/chrome-modern.png)

**Modern look**: `Theme.modern_light` (rounded SDF surfaces, soft shadows, token-derived styles, WCAG-AA text pairs) on the
engineering-workstation shell, with a wrapped-text NOTES card and a sliding Quick Keys popover. (SDF #48, tokens #48,
animation #43, wrap #35, contrast #98)

![Chrome, retro look](images/showcase/chrome-retro.png)

**Retro look** of the same App: one `themeFor` switch, a hand-built `Look`. (#48)

![Tables, 100,000 rows](images/showcase/tables-100k.png)

**100,000-row `DataTable`**: virtualized, sortable, resizable, selectable, sticky header, pixel-accurate ellipsis;
only the visible rows are emitted. Scrolled deep into the data. (#56 #73, tab fixes #105)

![Notes](images/showcase/notes.png)

**Notes** (`examples/notes`): wrapping multi-line `TextArea` with a drag selection across wrapped lines, grapheme-aware
caret (combining marks stay with their letter), per-script font fallback in one paragraph, chat box beside it. (#40, a11y
role #118)

![Notes, complex scripts](images/showcase/notes-scripts-harfbuzz.png)

**Complex scripts**: built with `-Dharfbuzz=true` (#77) and the Noto faces: Arabic joined and right-to-left with marks placed,
Hebrew, Devanagari reordered; visual-order caret, hit-testing and selection from the bidi core (#74, #85).

![Todo](images/showcase/todo.png)

**Todo**: the dynamic-list basic: rows from `Model.items`, per-row `Msg`s with keyboard-reachable controls (#93); labels fixed by #100.

## Platforms

![macOS](images/showcase/platform-macos.png)

**macOS**: the chrome example in a real Cocoa window, rendered through Metal by wgpu-native. (#54)

![Windows ARM64](images/showcase/platform-windows-arm64.png)

**Windows on ARM64**: the Win32 host and GDI text, rendered through wgpu on the WARP software adapter. (#31, #10, wgpu-native #19)
