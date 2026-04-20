# Teak: Next-Phase Task List

Working document. Current phase: **text rendering**. See §"Phase
history" at the bottom for what shipped before this phase.

**Status (2026-04-19)**: **WS1 + WS2 + WS3 + WS4 complete**.

- WS1 (`6d94be2`, `e59edc4`) — Host/GPU contracts + stubs + layout
  measurer threading.
- WS2 (`d129d36`, `19bf1c8`, `04e3862`, `551d7c9`) — native text
  rendering. GDI measurer + rasterizer, second render pipeline,
  glyph cache (256-entry LRU, 120-frame TTL), render emits
  `TextDraw` records, cursor placement via `measurer.prefixWidth`.
  Sharpness pass: nearest mag filter + integer-pixel rect/UV snap.
- WS3 — `CHAR_WIDTH` const deleted from `engine.zig` + `build.zig`;
  lingering comment references scrubbed; `no-char-width` audit rule
  added. `rg CHAR_WIDTH src/` returns zero matches.
- WS4 (`e6f6cf8`, `d1425e7`, `6e6a60c`) — web text via zunk wrapper.
  `measureText` + 128-entry LRU measure cache, `rasterizeText` +
  256-entry glyph cache mirroring native, text pipeline + BGL +
  nearest-mag sampler. Dropped stale DPR mouse-scaling workaround
  (zunk v0.5.2+ unified on CSS pixels). Stabilized per-font height
  at `ceil(size_px * 1.2)` so labels don't jitter by descender.

Native + web: real glyphs in all three examples. Browser-verified at
HiDPI.

Next up: **WS5** (glyph-cache hardening — instrumentation + canary).

---

## Current phase — Text rendering

### Motivation

Today Teak measures text with `content.len * CHAR_WIDTH` (10 px per
byte) in two places:

- `src/layout/engine.zig:114` — the measure pass
- `src/render/build.zig:12` — the cursor-and-text emit pass

Both constants have to stay in lockstep or the cursor drifts off the
glyphs. That's a dual-source-of-truth smell and it only gets worse once
we want:

- any font besides one hypothetical monospace
- non-ASCII (UTF-8 byte count ≠ display width)
- kerning / variable-width glyphs
- actual rendered text instead of colored rectangles where text would go

Real text measurement and real glyph rasterization close both the UX
gap and the CHAR_WIDTH duplication in one pass.

### Why now

Zunk shipped the web-side dependencies we were waiting on:

- **v0.6.0**: samplers + textures (primitives).
- **v0.7.0**: `measureText(text, font)` + `rasterizeText(text, font,
  color, w, h) → Texture` (browser canvas 2D under the hood).
- **v0.8.0**: descriptor type-safety pass (migration landed 2026-04-19).

The web path is a thin wrapper. The native path is the harder half and
gets first priority — see below.

### Priority ordering: native-first

Teak is a native UI framework first; wasm is a supported target but
not the dominant one. The text-rendering design decisions that matter
(Host-interface shape, atlas layout, glyph-cache policy, pipeline
split) should be driven by what native needs. The web path must
satisfy the same Host contract but won't get to define it.

Concretely:

- Ship native text rendering end-to-end before wiring the web path.
- When the two backends disagree on shape (e.g. zunk provides a
  pre-rasterized `Texture` but DirectWrite wants per-glyph atlas
  management), **the native shape wins** and the web path adapts —
  even if it means the web path does a bit more work than it would
  with a zunk-native API.
- Web parity is a deliverable, not a design constraint.

### HARDLINE interaction (flag early)

Text measurement is needed at layout time. Layout lives in framework
core (`src/layout/engine.zig`). Core **cannot** import `src/gpu/*` or
`src/platform/*` — HARDLINE §3. Therefore:

- `measureText` must be exposed through the **Host interface**
  (`src/platform/host.zig`), not the GPU interface.
- The Host owns the platform; the platform owns text metrics. This is
  the correct side of the boundary.
- `rasterizeText` (or equivalent) can live on the GPU interface — it
  only runs during render-pass build, which already imports GPU.

This is an extension of escape-hatch 4 (Host layer), not a new
escape hatch. Document the extension in HARDLINE §2 when the
Host-interface change lands.

### Workstreams

**WS1 — Host-interface extension (design + skeleton)** ✅
- `FontSpec` / `FontFamily` / `TextMetrics` / `TextMeasurer` /
  `TextureHandle` in `src/core/text.zig`.
- `validateHost` now requires `textMeasurer(*Host) TextMeasurer`;
  `validateGpu` now requires `rasterizeText(...) TextureHandle`.
- `font: FontSpec = DEFAULT_FONT` on five text-bearing Cmd variants.
- Stubs in all four backends return `len * 10` width / 20 height
  (pre-WS1 numbers) — zero visual drift.
- Layout pass takes a `TextMeasurer` parameter and dispatches four
  text-width sites through it. Render pass stays on CHAR_WIDTH
  until WS2/WS3.
- `teak.monoMeasurer()` shared helper for CLI canaries and tests
  that have no Host (pragmatic addition — stateless, placeholder).
- HARDLINE §2 extended with escape-hatch-4 clause (d) covering
  surface extensions + interface-value clarification. Feature doc
  at `docs/features/text.md`.

**WS2 — Native path (Win32 + wgpu)** ✅
- GDI instead of DirectWrite. Zero-COM, matches existing
  `win32.zig` style. Trade-off and non-goals documented in the
  plan (`.claude/plans/parallel-sleeping-frost.md`).
- Measurement via `GetTextExtentPoint32W` + `GetTextMetricsW`
  on a cached memory DC; HFONT cache keyed by (family, size_px).
  Segoe UI / Cambria / Cascadia Mono for `.sans` / `.serif` /
  `.mono`.
- Rasterization via `CreateDIBSection` (32bpp BGRA) + `DrawTextW`
  + alpha-from-luminance post-pass. Uploaded to wgpu BGRA8Unorm
  textures with `queueWriteTexture`.
- Glyph cache: 256 entries, LRU with 120-frame TTL, keyed by
  content hash × font × packed color × dimensions. Content length
  + hash re-compared on hit.
- Text pipeline: `shaders/textured_quad.wgsl`, reuses the same
  Vertex layout and blend state as the solid pipeline. Sampler
  is `magFilter = Nearest, minFilter = Linear, clamp_to_edge`.
- `renderFrame` runs solid pass then text pass. Text quads are
  snapped to integer pixels before UV math to avoid edge-repeat
  bleed.
- **Done**: counter_greeter / todo / tree all render real glyphs
  under `zig build ui`. Tested interactively; frame-diff still
  works (200k+ idle frames skipped without artifacts).

**WS3 — Remove `CHAR_WIDTH`** ✅
- Deleted the unused `const CHAR_WIDTH` from
  `src/layout/engine.zig` and `src/render/build.zig`. No lingering
  use in `src/platform/*`; comment-only references scrubbed from
  `engine.zig`, `build.zig`, `core/text.zig`, and `platform/wasm.zig`.
- `RULE_NO_CHAR_WIDTH` added to `tools/audit.zig`, scanning the whole
  `src/` tree. `zig build audit` enforces it going forward.
- **Done**: `rg CHAR_WIDTH src/` returns zero matches; library tests
  and audit both pass.

**WS4 — Web path (zunk wrapper)** ✅
- `src/platform/wasm.zig` `zunkMeasure` calls
  `zunk.web.gpu.measureText(content, css_font)` with a 128-entry
  LRU cache keyed by `(content_hash, content_len, size_px, family)`.
  Font-family mapping: `.sans` / `.serif` / `.mono` → CSS
  `sans-serif` / `serif` / `monospace`. Height is stabilized at
  `ceil(size_px * 1.2)` — zunk's `TextMetrics` returns glyph-tight
  ascent+descent which varies per string, and native returns
  font-scope `tm.tmHeight`; matching that keeps baselines stable.
- `src/gpu/web.zig` `rasterizeText` + `uploadText` mirror
  `native.zig` verbatim: 256-entry LRU glyph cache, same
  `textCacheKey` XOR, same pixel-snap + UV math, same draw loop.
  Second pipeline uses `textured_quad.wgsl`; sampler is
  nearest-mag / linear-min / clamp-to-edge. Zunk exposes no
  destroy for texture views or bind groups — cache eviction
  destroys the texture only (bounded leak at 256 entries).
- Dropped the pre-v0.5.2 `mouse * inv_dpr` workaround in
  `pollInputs`; zunk unified pointer and viewport on CSS pixels,
  and the extra divide was halving coords on HiDPI. Hit-tests now
  land under the cursor.
- **Done**: counter_greeter / todo / tree all render real glyphs
  under `zig build web`. Browser-verified at HiDPI.

**WS5 — Glyph-cache hardening**
- Cache-hit-rate instrumentation (debug build only): counters for
  hits, misses, evictions per frame. Log once a second.
- Regression test: a CLI canary that renders a fixed string
  across 200 frames and asserts the miss count drops to zero
  after frame 1.
- **Acceptance**: cache miss rate stays at 0% on steady-state
  UI. First-frame misses are expected.

### Non-goals for this phase

Explicitly out of scope — push back if they creep in:

- Rich text (mixed fonts/sizes within a single span). Every `Cmd.text`
  still has exactly one font + color.
- Bidi / RTL / complex script shaping. Latin + basic Unicode only.
  If a user types Arabic, the atlas will render it as the platform's
  fallback glyph; we don't shape.
- IME composition UI (candidate windows, preedit). Platform handles
  commit; we receive finished code points like today.
- Custom font loading from disk / embedded TTF. Stick to
  platform-provided families in v1.
- Subpixel AA. Grayscale AA is fine; subpixel has per-orientation
  rendering cost we don't need yet.
- Per-glyph atlas packing (one sheet with many glyphs). For v1 we
  rasterize whole strings and cache the bitmap. Per-glyph packing is
  a v2 optimization once we see the cache hit pattern.

### Sequencing

```
WS1 (Host-interface design)
  ↓
WS2 (Native path) ─── WS3 (CHAR_WIDTH removal, fed by WS2)
  ↓
WS4 (Web path)
  ↓
WS5 (Hardening)
```

WS2 and WS3 are tightly coupled — WS2 lands the real measurement;
WS3 flips call sites to use it; they'll likely ship in the same PR.

### Open asks for zunk

None today. If WS4 surfaces any, write them to
`docs/from_teak_team/text-rendering.md` or file a gh issue per the
pattern in `docs/from_zunk_team/v0.8.0-type-safety.md`.

---

## Post-hardening work that shipped (2026-04-19)

After the seven-phase cleanup landed, these follow-ups went in:

- **Divider widget** (`c2d30a1`) — horizontal/vertical separator.
- **Todo example** (`c2d30a1`) — dynamic-list stress test for the
  Msg-with-index pattern.
- **Tree example** (`a9e217f`) — recursive view, expand/collapse,
  flat pre-order node emission.
- **Zunk v0.8.0 migration** (2026-04-19) — `VertexAttribute` +
  `VertexBufferLayout` constructors in `src/gpu/web.zig` moved to
  struct-literal / `fromSlice` form. No ABI change.

---

## Phase history

The cleanup-and-abstraction phase (tasks 1–7) completed 2026-04-18.
All seven tasks landed plus the hardening pass (`zig build audit`,
filled test gaps, README rewrite, CI workflow, zunk roadmap handoff).

The detailed task descriptions from that phase are in the git history
at `1b096ee` and earlier. Not preserved inline here — this doc is the
current-phase working copy, not a historical record.

Zunk co-development (old task 6) stays as a standing concern:
general-purpose, no forking, no absorbing, cross-linked issues,
upstream preference for new features. See
`docs/journal/2026-04-16-zunk_teak_convo.md` for the full logic.
