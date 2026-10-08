# Browsers without WebGPU

> **Decision (owner, 2026-10-09): the WebGL2 backend is deferred.** WebGPU is required on the web; browsers without it get the in-page
> message / `zunkFallback` hook described below. Revisit if Firefox-on-Linux/Android users become a real audience for a teak product.

**Status.** A browser without usable WebGPU no longer shows a blank canvas: zunk's generated `app.js` detects the missing
`navigator.gpu` / adapter / device, calls the page's `window.zunkFallback({ reason, webgl2 })` hook if it has one, and otherwise shows a
full-page "This app needs WebGPU" message (zunk `docs/ARCHITECTURE.md`, "No WebGPU"). That is the shipped policy. This note evaluates what a real
fallback renderer would cost.

## Who is affected

WebGPU is stable in Chrome / Edge (desktop, Android), Safari, and Firefox on Windows. Firefox on Linux and Android, older Safari, and
machines whose GPU driver is blocklisted still report no adapter (headless Chromium without `--enable-unsafe-webgpu` is the test case: `navigator.gpu`
exists, `requestAdapter()` returns null; WebGL2 works there, `--use-angle=vulkan` on this Mali box, per `kerf/tools/README.md`). For a tool aimed at engineers
on Linux workstations, "Firefox on Linux" is the case that matters.

## Options

| | what the user gets | cost | verdict |
|---|---|---|---|
| A. Message only (shipped) | a clear explanation | done | right default |
| B. WebGL2 backend | the same UI, same pixels (2D), no 3D at first | see below | worth it only if Firefox-Linux users are a real audience |
| C. Canvas 2D software renderer | the UI, slowly | a CPU rasterizer for quads + glyph blits: ~1.5 days, 10k-run text slow | no: B is faster to build and 100x faster to run |
| D. Server-side / video | n/a | n/a | no |

## What a WebGL2 backend (`src/gpu/webgl.zig`) needs

The Gpu contract (`validateGpu`) is small and everything above it is shared: `TextStage` already produces backend-neutral `GlyphInstance` lists and CPU
atlas pages, `render/build.zig` produces `Vertex` lists, overlay layering is `overlay.Range`. A WebGL2 Gpu would reuse `web.zig`'s structure with
GL calls instead of `zgpu` calls.

1. **zunk WebGL2 bindings** (new category `webgl`, `src/web/webgl.zig` + `js/gl.js`): context creation on the `#app` canvas
   (`antialias` for MSAA), `createShader/compile/link`, `getUniformLocation`, `uniform1f/2f/4f`, `createBuffer/bufferData/bufferSubData`, VAO
   (`vertexAttribPointer`, `vertexAttribIPointer` for the packed integer instance words, `vertexAttribDivisor`), `createTexture/texImage2D/
   texSubImage2D` (R8 and RGBA8, `UNPACK_ROW_LENGTH` for sub-rect uploads from the CPU atlas pages), `texParameteri`, `blendFunc`, `viewport`,
   `clear`, `drawArrays`, `drawArraysInstanced`. About 35 imports, ~300 lines of JS + ~250 lines of Zig externs/wrappers, resolved like the existing
   `zunk_gpu_*` entries. Handles go through the existing `H` table.
2. **Shaders** (GLSL ES 3.00), three small ones ported from WGSL: `quad` (pos, colour, uv), `image` (texture x tint), `glyph`. The glyph shader keeps
   the packed-word instance format (integer attributes: `in uvec2`, `in uint`), `gl_VertexID` for the corner, `texelFetch` for coverage glyphs,
   `texture()` for SDF (and RGBA colour pages), `fwidth` for the SDF edge: a line-for-line port, ~120 lines.
3. **`baseInstance`**: WebGL2 has no `firstInstance`. `TextStage` already lays out one contiguous range per (page, layer); the draw loop re-points the
   instance attributes (`vertexAttribPointer` byte offset = `first * 32`) before each `drawArraysInstanced`. One extra call per page per layer.
4. **`gpu/webgl.zig`**: a copy of `web.zig` with the pipelines replaced by programs + VAOs, `writeTextureRegion` by `texSubImage2D`, the main pass by
   `viewport`/`clear`/draws (no render-pass objects, no bind groups), image upload, overlay layering, `scale` / canvas size handling. ~700 lines; the text
   staging, atlas and shaper are untouched.
5. **Selecting a backend.** One wasm cannot link both Gpu types cheaply. Build the app twice (`-Dgpu=webgl` -> `<name>-gl.wasm`) and let the page choose:
   `window.zunkFallback` is exactly that hook (load the `-gl` build when `webgl2` is true). A runtime switch inside one wasm would add a vtable layer
   to every Gpu call for no user benefit, and doubles the wasm only for the browsers that need it (downloaded once).
6. **Scene3d** (optional second step): depth test, per-scene offscreen framebuffers, instanced line quads, section-cut discard, item instancing:
   the WGSL scene shader is ~110 lines plus `wgpu_scene` logic (~400 lines) to port; WebGL2 can do all of it.

## Estimate

| piece | work | size |
|---|---|---|
| zunk WebGL2 bridge + resolver + tests | 3 h | +6 KB JS in `app.js` only when a GL app uses it |
| GLSL shaders | 1 h | ~4 KB source |
| `gpu/webgl.zig` (2D: quads, atlas text incl. SDF/colour pages, images, overlay) | 4 h | ~+12-15 KB gzip wasm vs the WebGPU build (no `zgpu` render-pass layer) |
| second build + page loader + docs + CI shot | 1.5 h | |
| **2D total** | **~9-10 h** | |
| scene3d on WebGL2 | +6-8 h | +8 KB |

That is about three times the "<= 3 h for 2D" threshold, so it was **not prototyped**; nothing in the design is risky (every GL feature above is core
WebGL2), the cost is breadth, not uncertainty. Recommended order if Firefox-Linux matters: bridge (3 h) first with a quad-only spike to prove the draw
loop and `baseInstance` workaround, then text, then images; ship behind the `zunkFallback` loader so WebGPU users never download it.

## Test plan

Headless Chromium started *without* `--enable-unsafe-webgpu` (WebGL2 via ANGLE-Vulkan works on the Mali box): the `webgl` build must render
`examples/chrome` and `examples/tables` (zoomed SDF labels) and match the WebGPU render within AA noise; `tools/web-startup.mjs` and
`tools/web-frame-bench.mjs` work on either build.
