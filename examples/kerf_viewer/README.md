# kerf_viewer: the Kerf dogfood app

A Kerf document (mesh + drawings) in three synchronised views, with a parts
table, NOTES and a scripted CHAT console, in Kerf's 1970s engineering-office
look (`kerf/spec/DESIGN.md`: paper, ink, vellum, non-photo blue, manila cards,
3270 status strip). It is the proof that teak can carry a real CAD-style UI.

```
zig build run                 # CLI canary: lays the app out headlessly, prints the snapshot
zig build ui                  # native window (X11 / Win32)
zig build web                 # wasm + WebGPU -> dist/
zig build shot -- out.png --state section_selected   # headless PNG; `-- --list` for the states
zig build test
```

## What is in it

| Piece | How |
|---|---|
| `[SECTION]` / `[ISO]` tabs | Kerf drawing JSON -> `draw/` (IR parser, stroke font, tessellator, pick; ported from the archived Kerf teak app) -> **one** `CanvasPrimitive.triangles` batch with a content `key` on an interactive canvas. Vellum + 1/4", 1", 12" blue grid that fades when dense, true pen weights (min 1 px), dashes, hatch, bulge arcs, Hershey text. Pan (left drag on paper / middle / right), wheel zoom at the cursor, `[-]` `[+]` `[FIT]`, `[GRID]`. SECTION has a sheet picker `A B C ...`. |
| `[3D]` tab | `viewport3d`: one mesh resource per part, items carry selection/hover flags; orbit/pan/zoom, view presets, ortho/persp, ground grid + axis gizmo, section cut with manila caps and ink outline. |
| One selection, one hover | The model holds a 1-based part id. A sheet pick (`src` such as `jack_studs#1`) maps to the part (`doc2d.partForSrc`), a selected part maps back to the sheet's `src` (`srcOfPart`: exact instance when the sheet draws it, else the bare id). Hover outlines the part in blue on the sheet, tints it in 3D and shades its table row; selection tints its cut region 15% blue, highlights it in 3D and inverts its row. |
| OPERATOR CONSOLE | `TextArea(512)` input (Enter sends, Shift+Enter newline via `SpecialKey.shift_enter`), message log in a scroll region that sticks to the newest message, DESIGN cards (designer = paper, Claude and its tool lines = manila) with `**bold**` rich text wrapped by `chat.wrapMarkup`. |
| Scripted "Claude" | `chat.zig`: a few intents (section / iso / 3d / cut / fit / select a part by name / summary / help). No network. Pacing is a `Sub.every(250 ms)` that exists only while a reply is pending: tick 2 posts the tool line and performs its UI action (switch tab, select, cut), tick 5 the answer. |
| NOTES | `TextArea(2048)` on a manila card. |
| Sources | bundled fixtures (palmer-sd1-like: 5 sections; flush-psl-2x6: section A + iso B), `?mesh=<fixture|url>` / `--mesh=`, `?tab=section|iso|3d`, `?select=<part>`, OPEN... (`open_file` effect, native `TEAK_OPEN=path`), drag-and-drop. A file is told apart by its header (`kerf_mesh` / `kerf_drawing`): a mesh replaces the document, a drawing joins it. |
| Keys | `S` `I` `D` tabs, `+` `-` `F` zoom/fit, `G` grid, `1`-`4` `O` `E` `C` `X` `Y` `Z` `V` 3D controls, Up/Down step the selection, Esc deselects / leaves an editor. Typed letters go to the focused text area. |

## Layout (DESIGN section 2)

header 40 px + 2 px rule; left console 360 px; centre flexes (tabs with the 3 px
blue bar on the active one); right inspector 320 px (parts table, DETAIL, NOTES);
24 px status strip (state, counts, selection, hover, sheet scale, cursor in
ft-in, `CLAUDE DEMO` / `CLAUDE BUSY`).

## Source map

```
src/app.zig      Model / Msg / update / view, hooks, tests + 3 snapshot goldens (SECTION, ISO, 3D)
src/doc2d.zig    the drawings of a document: sheets, per-sheet camera, tessellation (skips identical inputs), src <-> part mapping
src/chat.zig     message log, markup wrap, intent parser, scripted replies
src/kerf_mesh.zig  mesh JSON -> per-part meshes + pick data
src/draw/        the ported Kerf drawing pipeline (ir, jv, geom, font + kerf-simplex.json, tess, pick)
src/fixtures/    mesh + drawing JSON (from kerf/engines/zig/tests/golden)
```

Keeping the view pure: tessellation happens in `update` (after any Msg that can
change the active sheet), `view` only reads the finished triangle list.
