# Web startup

`node tools/web-startup.mjs <dist> [--baseline <dist>] [--runs N]` profiles navigation to first frame in headless
Chromium. The generated `app.js` emits `performance.mark`s (`zunk:load-start`, `zunk:wasm-ready`, `zunk:gpu-start`,
`zunk:gpu-ready`, `zunk:init-start/end`, `zunk:first-frame-start/end`) and `window.__zunkStats` (JS-side time in
`createShaderModule` / `createRenderPipeline`), so any zunk page can be read the same way.

## Where the time goes (examples/chrome, 257 KiB wasm, local server, SwiftShader WebGPU)

| phase | cold first browser launch | later launches |
|---|---|---|
| html | ~15 ms | ~10 ms |
| wasm download | ~100 ms | ~80-130 ms |
| wasm compile + instantiate | ~5 ms (streaming) | ~3 ms |
| **adapter + device** | **~1.65 s** | ~60-120 ms |
| `exports.init()` (Host, Gpu, pipelines' JS side, Runtime) | ~5 ms | ~5 ms |
| first frame (pipeline compile on first use, glyph raster, upload) | ~70-120 ms | ~50-90 ms |

The "1.7 s" of the review is the **first browser launch's GPU-process start-up**, billed to `requestAdapter()`: it
is the browser's, not ours, and a second launch on the same machine pays 60-120 ms for the same call. Everything
that is ours is under ~250 ms.

## What was changed

* The adapter + device request now starts at the top of the script instead of after the wasm has downloaded
  and compiled, so a slow GPU start overlaps the download (it used to follow it).
* The wasm `<link rel=preload>` is on in every build (it was deploy-only), so the download starts at HTML parse;
  `--font` files get preload hints too.
* `--font-nowait` (teak passes it): startup no longer waits for the page's `@font-face` files. teak embeds its
  faces in the wasm and shapes them with stb; the page fonts only serve the canvas fallback for glyphs no face has.
* The image/composite pipeline and the whole scene renderer (2 shaders, 3 pipelines) are created on first use;
  a typical 2D app compiles 2 shaders and 2 pipelines at startup instead of 4 and 5.
* `createRenderPipelineAsync` was evaluated and not used: the JS-side cost of `createRenderPipeline` is ~0.1 ms each
  (0.3 ms in total), compilation already happens off the main thread, and the render path needs the pipeline object
  synchronously.

Measured with `--baseline` (6 alternating cold samples each, a shared box with load average 13): first-frame medians
186 ms before / 201 ms after, i.e. no change beyond the +-40 ms noise; the structural wins (parallel GPU start, fewer
shaders to compile, no font wait for embedded-font apps) matter most where the GPU start or the font download is
slow, which a local server and a warm GPU process hide.
