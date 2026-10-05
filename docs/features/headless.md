# Headless native runs: scripted input -> PNG

**Status**: `pub` in `src/teak.zig` as `teak.headless` (tool API) and `teak.linkHeadless` (build helper, `build.zig`). Backends are import-only: `teak-platform-headless` (`src/platform/headless.zig`) and `teak-gpu-headless` (`src/gpu/native_headless.zig`).
**Source**: `src/headless_run.zig`, `src/platform/headless.zig`, `src/gpu/native_headless.zig`, `Gpu.initOffscreen` / `readFrame` in `src/gpu/wgpu_core.zig`.
**Tests**: `zig build test` (PNG encoder with CRC/Adler/inflate round-trip, `play` scripting, the Host's queue / clock / effects / text); `zig build test-gpu` (offscreen render + RGBA readback, resize).

Run any teak App on the real native wgpu backend with **no display**, drive it with scripted mouse / keyboard / wheel input, and write the last frame as a PNG that an agent (or CI) can look at. It needs a Vulkan device (a real GPU driver works; wgpu-native cannot use Chromium's SwiftShader) and a TTF (DejaVuSansMono by default, `TEAK_FONT` overrides), nothing else.

## Quick start (an app's `build.zig`)

```zig
const std = @import("std");
const teak = @import("teak");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // ... your usual exe / linkNativeWgpu / linkWebWgpu ...

    if (target.result.os.tag == .linux) {
        const shot = b.addExecutable(.{
            .name = "shot",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/shot_main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        teak.linkHeadless(b, shot, .{});            // teak, teak-platform-headless, teak-gpu-headless, wgpu-native
        const run = b.addRunArtifact(shot);
        if (b.args) |args| run.addArgs(args);
        b.step("shot", "Headless PNG screenshot: zig build shot -- out.png")
            .dependOn(&run.step);
    }
}
```

`src/shot_main.zig`:

```zig
const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");        // the same App module your windowed / web entries use

pub fn main(init: std.process.Init) !void {
    const path = teak.headless.pathArg(init, "shot.png");        // argv[1]
    try teak.headless.shot(App, Host, Gpu, init.gpa, path, .{
        .width = 1280, .height = 800,
        .steps = &.{
            .{ .frames = 2 },
            .{ .click = .{ 120, 80 } },     // hover, press, release (a frame between each)
            .{ .chars = "hello" },
            .{ .frames = 3 },
        },
    });
}
```

`zig build shot -- out.png` then writes the PNG. See `examples/chrome` and `examples/scene3d` (both have a `shot` step).

## What `teak.headless` offers

```zig
Step = union(enum) { frames: u32, move: [2]f32, down: Button, up: Button, wheel: [2]f32,
                     chars: []const u8, key: SpecialKey, mods: Modifiers,
                     click: [2]f32,            // move + frame, down + frame, up + frame
                     drag: [2][2]f32 }         // press at a, 4 interpolated moves, release at b
play(rt: anytype, host: anytype, steps: []const Step) !void
shot(App, Host, Gpu, gpa, path, ShotOptions{ width, height, msaa = true, steps, settle = 3, run: RunOptions }) !void
writeFramePng(gpu, gpa, path) !void      // gpu.readFrame -> PNG
writePng(gpa, path, rgba, w, h) !void
encodePng(gpa, rgba, w, h) ![]u8         // dependency-free; zlib stored blocks (~raw size)
pathArg(init, default) []const u8        // argv[1] of main(init: std.process.Init)
```

Prefer the lower-level pieces when you want to inspect state between steps:

```zig
var host = try Host.init(gpa, 1280, 800);
defer host.deinit();
var gpu = try Gpu.initOffscreen(1280, 800, .{ .msaa = true });
defer gpu.deinit();
var rt = try teak.Runtime(App, Host, Gpu).init(gpa, &host, &gpu, .{});
defer rt.deinit();
try teak.headless.play(&rt, &host, &.{ .{ .frames = 2 }, .{ .click = .{ 40, 40 } } });
std.debug.assert(rt.model.count == 1);               // the Model is right there
const rgba = try gpu.readFrame(gpa);                 // RGBA8, width*height*4
```

## `Gpu.initOffscreen` / `readFrame` (native wgpu backend)

```zig
Gpu.initOffscreen(width: u32, height: u32, options: InitOptions) !Gpu
Gpu.readFrame(self: *Gpu, allocator: std.mem.Allocator) ![]u8   // RGBA8; caller frees; error.NotOffscreen on a windowed Gpu
```

A surface-less device (Vulkan / Metal / D3D12 adapter) plus an offscreen BGRA8 colour target of the windowed format and the same MSAA path (`InitOptions.msaa`). `renderFrame` "presents" into that target; `readFrame` blocks until the GPU is done and returns the last frame converted to RGBA. `resize` recreates the target. Both are optional extensions (not in `validateGpu`). `initFromDevice(instance, null, ctx, ..)` + `renderToTexture` remain the lower-level hooks the GPU tests use.

## `HeadlessHost` (`platform/headless.zig`)

Implements the full `validateHost` surface for scripted runs.

- **Input** is queued by `pushMouseMove` / `pushMouseDown` / `pushMouseUp` / `pushWheel` / `pushChars` / `pushKey` / `setModifiers` and delivered, in order, by the next `pollInputs` (one per `Runtime.frame`). Edges are single-frame; a press and release queued together arrive as one fast click. The runtime routes input against the previous frame's layout, so move over a widget and run a frame before pressing (`.click` does this).
- **Clock**: `nowMs` is fake and advances **16 ms per frame** from 0, so `Sub.every` / `Sub.at` fire on a fixed, speed-independent schedule.
- **Text** is measured with the same stb_truetype `Font` the native Gpu rasterizes with, so layout matches the pixels.
- **Effects**: every `submit` is accepted and *captured* by deep copy (`submittedEffects()` -> `Captured{ kind, id, name, bytes, mime, method }`, `countEffects(kind)`, `clearSubmittedEffects()`). An effect is answered only by `injectEffectResult(EffectResult)` (also used for unsolicited `dropped` / `pasted_text`), so a test controls exactly what the app hears. Slices in an injected result must outlive the frame that dispatches it.
- Clipboard is an in-memory buffer; file dialogs cancel; no secondary windows; `scaleFactor()` is 1; `close()` ends a loop; `title()` returns the last `setTitle`.

## Visual differences from the web build

Same App, same layout engine, same shaders, same MSAA path, so geometry, colours, overlays and 3D scenes match. Text is the visible difference: the web draws strings with the browser's canvas 2D text engine (`monospace` CSS family and its hinting / subpixel positioning), native uses stb_truetype with DejaVuSansMono, grayscale AA and `FontSpec.family` ignored (one face). Expect slightly different glyph shapes and text widths (a few px per line), so row / button positions can shift by a pixel or a few. Fonts are not bundled: a box without DejaVu / Liberation needs `TEAK_FONT=/path/to.ttf`.

## Limits

- `linkHeadless` is Linux-only for now (the stb-text headless stitch; Windows would need its own).
- One primary window; secondary windows are not simulated.
- `zig build shot` runs the GPU for real: it needs a Vulkan driver (no software fallback is guaranteed) and exits with an error where none opens.
- The PNG writer stores uncompressed blocks; run an external optimizer if size matters.
