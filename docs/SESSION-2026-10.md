# Teak + zunk orchestration session, October 2026

Orchestrator: Claude Opus 5.5. Implementers: Claude Sonnet 5.5 sub-agents, one git worktree pair (teak + zunk) each.
Kickoff brief: [`docs/ORCHESTRATION-SESSION.md`](ORCHESTRATION-SESSION.md). Strategy input: [`docs/REVIEW-2026-10.md`](REVIEW-2026-10.md).

## Baseline (master `d6f4d34`, zunk `166979b`, Zig 0.16.0, 2026-10-08)

Machine: aarch64 Linux (Cix Sky1, 12 cores, 30 GB), Mali-G720 via Vulkan; headless Chromium WebGPU on SwiftShader.

| Gate | Result |
|---|---|
| `zig build test` | 398/398 pass (334 core + 64 across 13 other test roots) |
| `zig build test-gpu` | 39/39 pass (real wgpu-native on Vulkan) |
| `zig build audit` (incl. `test-wasm`) | pass |
| examples `test` / `install` / `web` | 8/8 / 8/8 / 8/8 pass (`ui` needs a display; compile covered by `install`) |
| `zig build shot` (chrome, scene3d) | pass, viewed |
| CI | Linux only: library tests, audit, 3 example test suites |

| Metric | Value |
|---|---|
| `src/` lines (all / non-test) | 28,171 / 24,068 |
| examples lines | 5,318 |
| zunk `src/` lines | 8,024 |
| `catch unreachable` in `src/` | 58 |
| wasm (ReleaseSmall, raw bytes) | chrome 1,207,369 · counter_greeter 1,262,015 · effects 1,313,417 · fonts 1,120,293 · scene3d 1,097,928 · todo 1,181,652 · tree 1,165,172 · viewport 1,216,129 |
| chrome `app.js` | 37,810 B |
| CPU pipeline (review §3.4, ReleaseFast) | 1k rows: view 0.20 / layout 0.13 / hit 0.08 / render-build 0.32 / cmdsEqual 0.36 ms; 10k rows: 1.29 / 0.80 / 0.71 / 1.91 / 2.29 ms |
| Text runs per frame | **capped at 256, silently dropped above** (review §3.5) |

Visual notes at baseline: native chrome renders correctly; web `todo` button labels sit high (not vertically centred).

Open issues at start: teak #1, #2, #4, #5, #6, #7, #8; zunk none.

## Log

### Checkpoint 1 (09:26, ≈ +0.9 h)

Merged:
- teak #11 `docs/PARITY.md` (parity matrix vs egui/ImGui/iced/Slint/Flutter), #12 `docs/features/scene.md` (Viewport3D + 2.5D design,
  S1–S10/P1–P5 plan), #13 `docs/features/text-engine.md` (atlas/shaper/wrap/editor design, 17-PR plan; orchestrator sign-off on the
  `textMsg` hook and "up to four layout passes" HARDLINE amendments), #17 Zig 0.17 migration.
- zunk #19 (0.17, v0.12.0); rich_zig #14 (0.17, v2.1.0 auto-released); webzocket #4 (0.17, v0.3.0 auto-released).

0.17 migration result: 398/398 tests, 39/39 GPU tests, audit green, all 8 examples test/build/web, native + web screenshots byte-identical to the
0.16 baseline. wasm grew 5-7% on 0.17 (chrome 1,207,369 → 1,272,561 B) — to investigate in the perf pass.

Windows ARM64: the native **aarch64-windows Zig 0.17.0 compiler works** on GitHub `windows-11-arm` (PE machine 0xAA64, ReleaseFast
hello runs; 0.16 control crashes as expected): https://github.com/hotschmoe/teak/actions/runs/37709576849. Full teak verification on that
runner is in CI PR #10.

Decisions: 0.17-only (no 0.16 lane, deps released); no reflection shim needed (parallel-array `@typeInfo` used directly); CPU ray pick first
for 3D (ID buffer later); stb_truetype as the single rasterizer on every platform incl. web (+25 KB wasm), SDF deferred.

Environment: installed `xvfb xdotool xclip x11-utils` (apt) on the dev box for X11 host testing.

In flight: CI matrix (#10), unicode/linebreak/wrap (#15) → Editor, glyph atlas (#14) → teak-text/shaper, scene math (#16) → zunk stencil/readback,
core cleanup, wgpu-native v29, X11 clipboard/XDND/IME.

### Checkpoint 2 (10:14, ≈ +1.6 h)

Merged since checkpoint 1: teak #10 (CI matrix: Linux, lavapipe GPU, web smoke, Windows x86_64 + **native windows-11-arm**, macOS; `tools/gate.sh`,
`tools/webshot.mjs`), #14 (GlyphAtlas), #15 (unicode/linebreak/text_wrap, UAX#29 conformance), #16 (scene camera/pick/section math), #18 (teak-text
module + SimpleShaper: kerning, ligatures), #19 (wgpu-native v29.0.1.1), #20 (Editor + UndoLog; TextField on Editor: UTF-8/grapheme, Home/End/Delete,
word jumps, undo), #25 (Windows CRLF test-data fix); zunk #20 (stencil + region readback, 0.13.0), #22 (texture-region upload + canvas cluster raster,
0.14.0).

Gate on master (`tools/gate.sh`, full): PASS in 449 s; tests 398 → 480.

Found + fixed: Windows CI broke on CRLF checkout of Unicode test data; `std.log` reachable from wasm breaks freestanding builds (default logFn pulls
`Io.Threaded`) → zunk `web.logFn` + teak `platform.logFn` + wasm canary (zunk #23 / teak #29); `Editor.set` didn't compile for small capacities;
Dropdown highlighted row label invisible on inverting themes; X11 `Xlib.load` used removed 0.17 reflection; `XCloseDisplay` crash after Xcursor unload.

Review highlights: PR4 native atlas renders all 640 and 10k runs (was capped at 256), crisp 2x HiDPI; 10k runs ≈ 7 ms frame CPU (target 4 ms, perf
follow-up assigned). kerf_viewer renders Kerf meshes with orbit/pick/per-part highlight + grid + gizmo on native and web.

Installed for testing: weston (headless), libwayland-client0, libxkbcommon0, libdecor-0-0.

### Checkpoint 3 (11:15, ≈ +2.7 h)

Merged since checkpoint 2: teak #20 Editor/TextField, #26 Combobox (closes #2) + ComponentList multi-field recipe (#1), #22 kerf_viewer, #21 X11
clipboard/XDND/XIM (closes #4), #28 **native glyph atlas** (256-run cap gone; 10k runs render), #23 growable image cache, #29 core cleanup
(reflection-derived cmdsEqual, exhaustive passes, `oom()`, loud caps, web `logFn` + wasm canary), #50; zunk #23 (`web.logFn`), #24 versioning;
rich_zig #15 / webzocket #5 versioning (owner's `kerf/docs/VERSIONING.md` standard applied to all four repos; per-PR version-bump checks and
auto-tag-on-merge removed; rich_zig's ruleset no longer requires the deleted "Version Bump Check").

Key results under review / in the train: wrap + flex shrink (#35, closes #8), TextArea + textMsg (#40), font fallback + rich wrap (#44), **web atlas**
(#45, web text pixel-identical to native, +21 KB gzip), web IME (#49 + zunk #25, CDP-verified Japanese composition), scene S3–S6 + 2.5D layers
(#24 #27 #30 #34 #37 #41: per-part items, grid, gizmo, section cut with hatched caps, tilted sheets, billboards), SDF rounded rects/shadows/
gradients + "modern" theme (#48), bench + MeasureCache + **wasm strip by default** (#36/#39: chrome wasm 1.27 MB → 120 KB), event-driven idle (#42),
`teak.anim` tweens (#43), cursor shapes + X11 HiDPI (#33), **Wayland host** (#47), visual regression suite (#32), **agent driver: control socket,
`teak-drive` CLI + MCP server, record/replay, inspector** (#46), versioning (#38).

Process notes: GitHub Actions runners are heavily backlogged, so merges go through a local "merge train" (merge master → `tools/gate.sh --quick` +
every example's web build → push → merge). One incident: an agent opened a PR against the upstream fork parent of webzocket by mistake
(karlseguin/websocket.zig#114); it was closed within a minute with an apology; `gh repo set-default` pinned and the brief now requires `-R`.

Bugs found and fixed in passing: todo labels read a by-value loop copy (garbled text), counter_greeter light theme kept a dark clear colour,
combining marks rendered as separate glyphs ("cafe´"), double HiDPI scale on the primary window uniform, kerf_viewer web build missing `logFn`.
Open: an intermittent, load-dependent `zig build test` failure seen 3× by agents (not reproduced in 27 isolated runs).

### Kerf dogfood (scene agent, examples/kerf_viewer)

The Kerf app rebuilt on teak without touching the framework core beyond one key: `examples/kerf_viewer` (README there).
Mesh viewer -> SECTION / ISO / 3D with one shared selection, a chat console and NOTES.

What the framework carried unchanged: the Kerf tessellator output as one `CanvasPrimitive.triangles` batch with a `key`
(a pan/zoom frame re-tessellates in `update` in ~0.3 ms and costs nothing when nothing changed); `canvasInteractive`
events for pick/hover/pan/zoom; `viewport3d` items for per-part highlight; `TextArea` for notes and chat; `effects`
(`open_file`, `query_param`, `http`, drops); `Sub.every` for reply pacing; web build and headless shots identical.

Friction found (each is a possible follow-up):
- `SpecialKey` had no Shift+Enter, so a chat box could not tell send from newline: added `shift_enter`.
- `rich_text` does not wrap; the console wraps `**bold**` markup itself (`chat.wrapMarkup`, 36 columns for the 360 px panel
  in the monospace face). A wrapping rich text (spans across wrapped lines) would remove that code.
- `Sub.at` needs a deadline on the host clock but the Model cannot read the clock, so a one-shot "reply after N ms" is a
  tick counter on `Sub.every`. A `Sub.after(ms, msg)` (armed by the runtime when first listed) would fit HARDLINE.
- Scroll "stick to bottom" needs the extent hook plus a flag in the Model; a `scroll_to_end` field would be simpler.
- A text area's Tab / focus state lives in `TransientState` while the app keeps its own `focus` for key routing: two
  sources of truth for "who has the keyboard", easy to desync (clicking a canvas must blur the Model flag by hand).
- Branch hygiene: master's `buildFrame` signature changes (scene items, sprites) silently broke tests on other
  branches; a thin config struct instead of positional args would stop that.
- Bug found by the evaluator while this was in flight: SDF records read through a stale bind group after the vertex
  buffer grew (PR #86).

### Checkpoint 4 (12:48, ≈ +4.2 h)

Merged since checkpoint 3 (teak): #35 wrap + flex shrink (closes #8), #40 TextArea + `textMsg`, #45 web glyph atlas, #36 bench + measure cache,
#39 wasm strip (chrome wasm 1.27 MB → ~230 KB incl. stb + default face; 103 KB gzip), #42 event-driven idle, #43 `teak.anim`, #48 SDF rounded
rects/shadows/gradients + modern theme, #52 widgets wave 1 (menubar/menus, context menu, tooltip, toast, dialog, tabs, toggle, progress, split
pane), #59 examples/gallery, #55 X11/Win32 `waitEvents` + blink-aware idle (X11 idle CPU 6.5 % → 0.05 % of a core), #56 DataTable/VarList/
TreeList/Scroller (100k-row table 1.1–2.4 ms native), #61 dead `@hasDecl` capability gates (web a11y mirror + file dialog were never called),
#68 menu mnemonics, #73 table type-to-search + pixel ellipsis, #24/#27/#30/#34 scene View payload, instanced items, kerf_viewer per-part, grid +
gizmo; zunk #25 IME bridge, #26 a11y mirror, #27 RGBA cluster raster, #28 clipboard image.

Environment: the disk hit 100 % (other project's stale Zig caches: laminae `.zig-cache` 377 GB + worktree caches); with the owner's OK they were
deleted → 567 GB free. A disk guard now prunes stale caches in this session's workspaces below 10 GB free.

Process: the merge queue is now a daemon (`ws/runner.sh` + `ws/queue.txt`) with union-merge for additive files (CHANGELOG, llms.txt, teak.zig,
docs) and API-reference regeneration; an **integrator agent** resolves code conflicts on skipped PRs so authors keep building. Lesson: long-lived
stacked branches on hot files (`cmd.zig`, `run.zig`, `examples/chrome`) caused most of the merge cost; small PRs and "no demos in chrome" fixed it.
One slip of mine: I pushed a non-compiling merge to the scene-view branch (test result masked by `| tail`); caught before merge, fixed by its author.

**M5 acceptance eval** — a fresh agent built "UnitLab" (unit converter: dropdown pickers, numeric field, history table, TextArea notes, menubar,
tooltip; native + web; tests + snapshot golden) from `llms.txt` + docs only, no `src/` reads, in ~15 min. Rating 6/10 for a weaker model. Gaps:
web entry import names, zon path rules, TextArea wiring and Enter handling, setting field text from code, Dropdown select-when-closed, no Ctrl
chords on master yet (#60), headless chars/keys ordering. It also found a real **SDF render bug** (modern theme buttons lose backgrounds / shift after
an overlay closes). All assigned.

---

## Final report (20:15, ≈ +11.7 h)

### Executive summary

The session executed the review's M0 completely and most of M1–M5, plus the 3D milestones 1 and 2:

- **M0 (stabilise):** Zig 0.17 across teak, zunk, rich_zig and webzocket; the 256-text-run cap is gone (glyph atlas on native and web);
  fixed capacities fail loudly; the frame diff is derived by reflection and every pass is exhaustive over `Cmd`; CI covers Linux, lavapipe GPU,
  web smoke, Windows x86_64 + **native Windows ARM64** (the emulation workaround is retired), macOS and X11/Wayland live tests.
- **M1 (text, the make-or-break milestone):** stb_truetype everywhere (layout == render on every target), a pluggable `Shaper`
  (kerning, ligatures, NFC compose, optional HarfBuzz for Arabic/Hebrew/Indic), UAX#29/#14/#9, wrap + ellipsis + flex shrink, a font fallback
  chain, SDF scalable text, colour emoji on web, `Editor`/`TextField`/`TextArea` with mouse selection, undo, bidi caret, and IME on web, X11, Win32 and macOS.
  The review's acceptance (Kerf's multi-line chat + notes on the library component, Japanese IME on web and one native host) is met:
  `examples/kerf_viewer` chat/notes are `TextArea`s; web composition is CDP-verified; X11 XIM and Win32 IMM feed the same `imeState()`.
- **M2 (widgets):** menubar/menus/context menu, tooltip, toast, dialog, tabs, toggle, progress, split pane, combobox, number spinner, colour picker,
  date field, DataTable (100k rows: 1.1–2.4 ms native), variable-height list, tree list, kinetic scrolling, SDF rounded rects/shadows/gradients and a
  "modern" theme next to the retro one, animation (`teak.anim`), event-driven idle, keyboard navigation and focus everywhere, shortcuts + command
  palette, in-app drag and drop, cursor shapes, native file dialogs, image clipboard.
- **M3 (a11y):** the tree is published from `teak.run`, AT actions come back as ordinary input, a nested ARIA DOM mirror on web with a Puppeteer probe in
  CI, UIA Invoke/Toggle/Value on Windows. (Linux AT-SPI: evaluated, not shipped.)
- **M4 (platforms):** native **Wayland** (runtime-selected over X11), a **macOS** Cocoa + Metal backend (window renders on GitHub macOS runners), Win32
  parity (effects, headless, per-monitor DPI, IDropTarget, image paste) with Windows shots rendered on WARP.
- **M5 (agent DX):** a control socket + `teak-drive` CLI + **MCP server** to drive a running app, record/replay, a dev inspector, **hot reload** with Model
  preserved, a visual-regression suite with golden PNGs, a generated API reference (`llms-full.txt`), an audit that keeps docs in sync with code, and a
  measured "build an app from the docs alone" eval (6/10 for a weaker model; every finding fixed afterwards).
- **3D track:** `teak.scene` camera/pick/section math, `viewport3d` with per-part instanced items, grid, gizmo, section cut with hatched caps (M1), and
  2.5D plane layers, billboards and depth sort (M2). The Kerf mesh acceptance is met in `examples/kerf_viewer` (orbit, pick, cut) on native and web.
- **Dogfood:** `examples/kerf_viewer` is a working Kerf detail workstation: SECTION/ISO drawing views, the 3D view with cut, a shared selection across
  table/sheets/3D, a scripted chat console and notes, command palette and menubar.

All 7 issues open at the start (#1, #2, #4, #5, #6, #7, #8) are closed.

### Before / after

| Metric | Baseline (`d6f4d34`, Zig 0.16) | End of session (Zig 0.17) |
|---|---|---|
| `zig build test` | 398 tests | 995 pass + 2 skipped |
| `zig build test-gpu` | 39 | 113 |
| local full gate (`tools/gate.sh`) | n/a | 60 steps, PASS (858 s) |
| `src/` lines (non-test) | 24,068 | 62,074 (incl. ~2.9k generated Wayland protocol code) |
| examples | 8 (5,318 lines) | 13 (18,803 lines) |
| chrome wasm, ReleaseFast (example default) | 1,207,501 B raw / 308 KB brotli | 526,762 B / 159 KB brotli |
| chrome wasm, ReleaseSmall | 94,878 B / 36 KB brotli (text via canvas2D JS) | 351,775 B / 129 KB brotli (shaper + stb + atlas + default font in wasm) |
| chrome native `ui` (ReleaseSmall) | 1,345,024 B | 896,552 B (+ libwgpu_native 9.5 MB, v25 → v29) |
| CPU pipeline, 10k rows (sum of passes) | 7.0 ms (review figure; same-day master measured 10.6) | 5.5 ms (Cmd 480 B → 72 B: −53 % vs the day's master) |
| 10k text runs per frame | broken (capped at 256, silently dropped) | 2.4 ms warm frame (~55k glyphs) |
| idle frame (headless, 640 runs) | full rebuild every vsync (0.4–0.6 ms) | ~2 µs (idle skip) |
| web first frame (warm browser) | ~165 ms | ~200 ms (1.7 s cold = browser GPU-process start, not teak) |
| platforms running teak | web, X11, headless (Win32 compile-only) | web, X11, **Wayland**, headless, **Win32 (x86_64 + ARM64, rendered on CI)**, **macOS (rendered on CI)** |
| open issues | 7 | 0 |

Measured on this box at the end of the session (shared with other agents, load 2.5–13; timings are minimums of N runs, sizes exact). Baseline
wasm/native sizes were rebuilt from `d6f4d34` with Zig 0.16; the baseline CPU-pipeline numbers are the review's (§3.4).

### Merged PRs

teak: 110 PRs merged this session (#10–#121; #67 and #107 closed as superseded); zunk: 11 (#19–#30: 0.17, stencil + region readback, atlas uploads,
web logFn, versioning, IME bridge, a11y mirror, RGBA cluster raster, clipboard image, startup marks, no-WebGPU fallback); rich_zig #14, #15;
webzocket #4, #5. Releases auto-cut before the versioning change: rich_zig v2.1.0, webzocket v0.3.0, zunk tags up to v0.15.0.

### Feature parity (teak, end of session; competitor columns from docs/PARITY.md, secondary sources)

| Area | teak | egui | Dear ImGui | iced | Slint | Flutter |
|---|---|---|---|---|---|---|
| Shaping / complex scripts | partial (built-in Latin; HarfBuzz opt-in) | partial | partial | ✓ | ✓ | ✓ |
| Wrap / multi-line edit / undo | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Bidi | ✓ (UAX#9, visual caret) | partial | ✗ | partial | ✓ | ✓ |
| IME | ✓ web, X11, Win32, macOS (Wayland text-input-v3 untested live) | ✓ | partial | ✓ | ✓ | ✓ |
| Font fallback / emoji | partial (chain + system faces; colour emoji web only) | partial | partial | ✓ | ✓ | ✓ |
| HiDPI / AA / rounded / shadows / gradients | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| 3D viewport (pick, cut, layers) | ✓ | partial | partial | partial | ✗ | partial |
| Stock widgets (menus, tabs, tree, table, dialogs, toasts, pickers) | ✓ (no docking, no SVG) | ✓ | ✓ | partial | ✓ | ✓ |
| Virtualized 100k table | ✓ | ✓ | ✓ | partial | partial | ✓ |
| Focus / keyboard nav / shortcuts | ✓ | partial | ✓ | partial | ✓ | ✓ |
| Animation | ✓ | ✓ | partial | ✓ | ✓ | ✓ |
| Accessibility | partial (Win UIA + web mirror; no AT-SPI/macOS AX) | ✓ | ✗ | partial | ✓ | ✓ |
| Platforms | Win, macOS, X11, Wayland, web (WebGPU only) | ✓ + WebGL | ✓ | ✓ | ✓ + MCU | ✓ + mobile |
| Headless tests / goldens / record-replay | ✓ | ✓ | partial | ✓ | partial | partial |
| Agent driving (MCP) + LLM docs | ✓ | ✓ (0.35) | ✗ | ✗ | ✗ | partial |
| Hot reload | ✓ (Linux, Model kept) | ✗ | ✗ | ✓ | ✓ | ✓ |
| Web download (small app) | ~130–160 KB brotli | ~1.2 MB | few 100 KB | ~1–2 MB | ~1 MB+ | ~2–3 MB |

### Screenshots

`docs/showcase.md` (PR #113, refreshed in #119) holds 33 images: every gallery page in three looks, kerf_viewer SECTION/ISO/3D-cut/chat/command
palette, scene_layers, notes (Arabic/Hebrew/Devanagari with HarfBuzz), tables at 100k rows, chrome retro + modern, native|web side-by-side pairs, a 2x
HiDPI crop, and the macOS and Windows-ARM64 windows.

### 3D track status

Milestone 1 (Viewport3D) shipped: camera math, CPU ray pick (BVH), instanced per-part items with tint/highlight, flat/Lambert, feature edges, grid,
axis gizmo with letters, section cut with stencil-parity caps and exact cut outlines, native + web, pixel tests. Milestone 2 (2.5D) shipped: plane layers
carrying 2D canvas content, billboards, translucent depth sort, `examples/scene_layers`. Not done: ID-buffer GPU picking (S9, the CPU pick covers Kerf
meshes), tilted text on planes via offscreen targets (P5 stretch), stencil caps for open shells (outline only, by design).

### Remaining risks

0. **End state:** master `760c2da` — local full gate PASS (60 steps) and GitHub CI run 37770920087 green on every job
   (Library Debug+ReleaseSafe+audit+fmt, 10 example jobs, lavapipe GPU, web smoke ×2, a11y probe, X11/Xvfb, Wayland/weston, Windows x86_64,
   **Windows ARM64 native**, **macOS Cocoa+Metal**), plus the live Win32 window workflow (#121) on windows-latest + windows-11-arm. The two
   visual-regression jobs are report-only until tolerances are calibrated against CI's software renderers. Gap: kerf_viewer, tables and
   scene_layers are not yet in the CI example matrix (the local gate covers them).
1. **CI on non-Linux was red for part of the day** (the local merge gate is Linux-only); fixes landed in #54 and the `ci-green` PR (#114) adds a cross-OS
   compile check to `tools/gate.sh`. Confirm a completed green master run on all OSes.
2. **Untested at runtime:** Wayland IME (weston lacks text-input-v3), macOS input/IME/Retina (compiled + unit-tested; window render verified on CI),
   Win32 drag-in and image paste (unit-tested; live-window CI in #67).
3. **Size:** ReleaseSmall web builds grew ~3.7x because the text engine moved into the wasm (canvas2D path removed); ReleaseFast shrank 2.3x. A
   lighter "canvas text" mode could return for size-critical apps.
4. **Surface growth:** many optional App hooks were added this session; pointer input is now consolidated into one `pointerMsg` (#124), the
   other hooks remain individually documented in the run.md hook table.
5. **No WebGL2 fallback** (Firefox Linux/Android): deferred by owner decision; a friendly in-page message ships (estimate if revived: 9–10 h for 2D).
6. **Bus factor / review debt:** ~120 PRs in a day were reviewed by an orchestrator plus local gates and screenshots, not by a human.
7. **Flake:** one intermittent, load-dependent test-runner failure was seen ~4 times under heavy load (silenced the only stderr-printing tests; not
   reproduced in isolation).

### Process notes (what worked, what didn't)

- Worked: design docs first (text engine, scene, parity) then agent-sized PRs with file ownership; paired teak+zunk worktrees per agent; screenshots
  reviewed by eye for every visual PR (caught real bugs: dangling labels, SDF stale bind group, combining marks, CRLF test data, std.log on wasm).
- Didn't: long-lived stacked branches on hot files caused most of the merge cost. Fixes that worked: a local merge-queue daemon with union-merge of
  additive files, API/module-tree regeneration and `zig fmt` in the queue, batching (one gate per batch, bisect on failure), and dedicated integrator
  agents. GitHub Actions was backlogged for hours by agent pushes; docs-only changes now skip the matrix and master runs are no longer cancelled.
- Mistakes of mine: a self-matching `pgrep` wait loop, a `pkill` that killed my own shell, one non-compiling merge pushed to a PR branch (caught before
  merge), assigning the headless input cap twice, cookbook recipe-number collisions.
- Environment changes on the dev box: installed xvfb, xdotool, xclip, x11-utils, weston, libwayland/xkbcommon/libdecor, mesa-vulkan-drivers; with the
  owner's OK deleted ~550 GB of stale laminae Zig caches; a disk guard prunes stale caches in `~/github/ws`.

### Releases and follow-up (2026-10-09)

Owner decisions after the report, all executed:

- **Released zunk v0.16.0** (https://github.com/hotschmoe/zunk/releases/tag/v0.16.0) and **teak v0.1.0** (first release; tag `v0.1.0`).
  teak now pins zunk by url + hash to the v0.16.0 release (#123), so a tagged teak builds standalone; co-develop zunk with
  `zig build <step> --fork=../zunk`. CI no longer checks out a zunk sibling.
- **WebGL2 fallback deferred** (WebGPU required on the web; in-page message + `zunkFallback` hook; `docs/features/web-fallback.md`).
- **Pointer hooks consolidated** (#124): one `pointerMsg(*const Model, PointerEvent(Msg))` with a `Target` union (widget, canvas, text_area
  with resolved caret, slider, scroll), one capture rule and one routing function; `canvasMsg`/`textMsg`/`sliderMsg`/`scrollMsg`/`hoverMsg`/
  `contextMsg` survive as deprecated adapters (`docs/migration-pointer-msg.md`), every example migrated, an audit rule keeps it that way.
- **Cleanup:** all agent worktrees and scratch checkouts removed (unmerged WIP preserved as pushed branches `idle-hosts-wayland`,
  `wave2-gallery`), this session's stray static servers stopped, build caches cleared.

### Recommended next session

1. Confirm green CI on every OS for a full week of master pushes; add a nightly ReleaseSafe + ASan-ish lane.
2. A HARDLINE review of the remaining hook surface; drop the deprecated pointer adapters after one release.
3. Linux a11y via AccessKit C (AT-SPI) and macOS NSAccessibility; screen-reader passes with Orca/VoiceOver/NVDA.
4. A size-optimised web text mode (WebGL2 stays deferred unless a product needs it).
5. Docking, SVG icons, charts beyond lines; GPU ID-buffer picking for large meshes.
6. Re-run the docs-only app-building eval with a smaller model and fix what it trips on.
7. Keep cutting releases with `tools/release.sh` (teak v0.1.x, zunk v0.16.x) and bump teak's zunk pin per zunk release.
