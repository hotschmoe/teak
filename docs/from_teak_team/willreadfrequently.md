# Zunk ask: `willReadFrequently: true` on the text canvas

**Audience**: Zunk maintainers.
**Drafted**: 2026-04-19.
**Zunk version observed**: 0.8.0 (path dep at `../zunk`, sha TBD).
**Target file**: `src/gen/js_resolve.zig` (two JS one-liners).
**Status**: filed as gh issue on `hotschmoe/zunk` (see §"Issue" below).

## TL;DR

The offscreen canvas created by the text path (`measure_text` /
`rasterize_text`) calls `getContext('2d')` without options. Chrome
emits a perf warning on every `rasterize_text` call:

```
Canvas2D: Multiple readback operations using getImageData are faster
with the willReadFrequently attribute set to true.
See: https://html.spec.whatwg.org/multipage/canvas.html#concept-canvas-will-read-frequently
```

`rasterize_text` does exactly what the warning targets — one
`getImageData(0,0,w,h)` per call, to copy pixels into a `GPUTexture`
via `queue.writeTexture`. Opting in unblocks the spec's software-
rendered readback path; for our workload (N cache misses per
first-paint plus occasional churn on dynamic labels) the readback is
the dominant cost of the whole function.

## Where

`src/gen/js_resolve.zig`, the two JS body strings that lazy-create
`zunkTextCanvas` / `zunkTextCtx`:

```zig
.{ "measure_text", "if(!zunkTextCanvas){zunkTextCanvas=document.createElement('canvas');zunkTextCtx=zunkTextCanvas.getContext('2d');}" ++ ...
.{ "rasterize_text", "if(!zunkTextCanvas){zunkTextCanvas=document.createElement('canvas');zunkTextCtx=zunkTextCanvas.getContext('2d');}" ++ ...
```

Both share `zunkTextCanvas` through the lazy guard, so whichever JS
body runs first wins the context options. Both need the flag to be
safe against call-order variations.

## Proposed change

One argument per call:

```js
zunkTextCtx=zunkTextCanvas.getContext('2d',{willReadFrequently:true});
```

That's it. No API change, no Zig-side delta, no ABI implication. Teak
does nothing on its end — the next `zig build web` picks up the fix
from the updated zunk source.

## Why now

Teak just shipped WS5 (glyph-cache hardening — commit `5024a8c` on
`teak:master`). Steady-state UI has 0% miss rate in the cache, so
`rasterize_text` is called once per new (content, font, color, size)
tuple and never again. But:

- First paint misses N entries (≈10-20 per example) back-to-back —
  that's N readbacks at cold-cache cost.
- Dynamic labels (e.g. counter value, todo item title edits) miss on
  every new value, so continuous `getImageData` calls happen during
  interaction.

Chrome's warning is the load-bearing signal here: we're on the slow
path the flag was designed for.

## Non-goals

- Not asking for a text atlas / per-glyph packing. WS5 intentionally
  defers that to v2 (see `teak/tasks.md` §"Non-goals for this phase"
  lines 202-203).
- Not asking to swap canvas 2D for OffscreenCanvas / WebGL — the
  current shape is fine.

## Issue

Filed at: https://github.com/hotschmoe/zunk/issues/13
