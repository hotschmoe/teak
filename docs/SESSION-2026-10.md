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

### Kerf dogfood (scam, kerf_viewer)

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
