# Text state is passed in

The native text path (`teak-text`) no longer keeps module-level variables. The face table,
fallback chain, kerning cache, measurement cache and HarfBuzz objects live in one
`TextState`. The Host creates it at startup and frees it in `deinit`; the Gpu borrows it
through the Host's `nativeHandle()`. Two Hosts in one process share nothing, and a second
run in the same process starts from the same state as the first.

## Application entry points

Native and web entry points are unchanged: `Gpu.init(host.nativeHandle(), w, h)` and
`Gpu.initWithOptions(host.nativeHandle(), w, h, options)` already pass the handle, and every
`NativeHandle` now carries a `text` field the Gpu reads. `Host.registerFont` keeps its
signature.

Headless and offscreen entry points pass the handle too, because the offscreen Gpu has no
window to take it from:

```zig
// before
var gpu = try Gpu.initOffscreen(1280, 800, .{ .msaa = true });
// after
var gpu = try Gpu.initOffscreen(host.nativeHandle(), 1280, 800, .{ .msaa = true });
```

The headless Host's `nativeHandle()` used to return `void`; it now returns
`NativeHandle{ .text = *TextState }`. Hot-reload plugins use the same call in their
`Init.gpu(host, options)`. `headless.shot`, `shotCli` and the other helpers in
`headless_run.zig` need no change.

## Direct `teak-text` users

Every function takes the state first. Create it with `TextState.open`, which allocates every
buffer once for the declared `Limits`:

```zig
const state = try text.TextState.open(allocator, .{});   // .{} = default Limits
defer state.close();
try text.registerFace(state, .mono, .regular, ttf_bytes);
const m = text.measure(state, "hello", .{ .family = .mono });
```

| before | after |
|---|---|
| `text.registerFace(family, weight, ttf)` | `text.registerFace(state, family, weight, ttf)` |
| `text.registerFallbackFace(ttf)` | `text.registerFallbackFace(state, ttf)` |
| `text.releaseFaces()` | `text.releaseFaces(state)`; `state.close()` also frees the state |
| `text.faceFor(family, weight)` | `text.faceFor(state, family, weight)` |
| `face.setFallbackBytes(ttf)` | `face.setFallbackBytes(state, ttf)` |
| `face.configure(source)` | `face.configure(state, source)` |
| `text.measure(bytes, font)`, `text.width(bytes, font)` | `text.measure(state, bytes, font)`, `text.width(state, bytes, font)` |
| `shaper.shape(bytes, font, out)` | `shaper.shape(state, bytes, font, out)` |
| `shaper.shaper()` (stateless) | `shaper.shaper(state)` |
| `Font.loadSystem(allocator, source)` | `Font.loadSystem(allocator, embedded_bytes, source)` |
| `StbttRasterizer.init(allocator)` | `StbttRasterizer.init(allocator, state)` |
| `native_fonts.configure(text, options)` | `native_fonts.open(text, allocator, options)` returns the state |
| `face.epoch` | `state.faces.epoch` |

`TextMeasurer` for a state: `state.measurer()`. `Font.kernUnits` no longer caches; the
cache is `state.kern`. HarfBuzz builds keep their objects in `state.hb`;
`hb_shaper.deinit()` is gone (`state.close()` frees them).

## Limits

`Limits` has two fields, both powers of two: `kern_slots` (default 8192) and
`measure_slots` (default 4096; 1024 on wasm). `open` returns `error.LimitsInvalid` for
anything else. Both caches are direct-mapped (the measurement cache two-way on native):
a full slot is overwritten, never grown. `state.report()` returns what was evicted,
bypassed or refused since `open`:

- `kern_evicted`, `measure_evicted`: an entry was overwritten.
- `measure_bypassed`: text longer than the cache entry was measured uncached.
- `fallback_refused`: `registerFallbackFace` was past its four faces (it still returns
  `error.ChainFull`).
- `rtl_unordered`: a right-to-left run over 2048 bytes was shaped in logical order.
- `hb_skipped`: a HarfBuzz run was not shaped (its face had no slot, or its glyphs overflowed
  the scratch buffer).

`close()` logs a warning when a result was degraded (the last three) and a debug line when
only caches evicted or bypassed. Results never depend on the limits: a state with two-slot
caches measures and shapes exactly like one with the defaults.

## Behaviour changes

- `registerFallbackFace` now invalidates the caches, like `registerFace`. Measurements
  taken before a fallback face was added could be served stale.
- `FontSpec.snap_advance = true` no longer panics in safe builds when a text over 16 bytes
  or one that is not plain ASCII is measured (the measurement cache hash overflowed a
  one-bit integer). ReleaseFast builds wrapped silently; their results are unchanged.
- Kerning cache entries are keyed by face-table index instead of face address.
