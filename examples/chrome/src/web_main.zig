//! Wasm entry for the chrome example. Zunk inverts control: it owns the rAF loop and
//! calls the exported `init` / `frame` / `resize`. All the loop logic lives
//! in `teak.Runtime` — the same code `teak.run` drives on native hosts —
//! so this file only builds the Host, Gpu and Runtime once and forwards
//! each rAF tick to `Runtime.frame`.

const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-wasm");
const gpu_web = @import("teak-gpu-web");
const build_options = @import("build_options");
const stress = build_options.stress;
const App = if (stress > 0) @import("textstress.zig") else @import("app.zig");

/// std.log -> browser console (the default logFn does not build for wasm32-freestanding).
pub const std_options: std.Options = .{ .logFn = platform.logFn };

const Host = platform.Host;
const Gpu = gpu_web.Gpu;
const Runtime = teak.Runtime(App, Host, Gpu);

comptime {
    teak.validateHost(Host);
    teak.validateGpu(Gpu);
}

// Exports can't close over a struct, so the three live in module-level vars.
var host: Host = undefined;
var gpu: Gpu = undefined;
var runtime: Runtime = undefined;

export fn init() void {
    host = Host.init("Kerf chrome", 1440, 900) catch @panic("host init failed");
    host.activate();
    gpu = Gpu.init(host.nativeHandle(), 1440, 900) catch @panic("gpu init failed");
    runtime = Runtime.init(std.heap.wasm_allocator, &host, &gpu, .{ .clear_color = if (stress > 0) .{ 0.08, 0.08, 0.1, 1 } else App.paper }) catch @panic("runtime init failed");
    if (stress > 0) {
        // Same grid as `zig build shot -- --stress N`.
        const many = stress > 640;
        runtime.model.cols = if (many) 48 else 16;
        runtime.model.rows = (stress + runtime.model.cols - 1) / runtime.model.cols;
        runtime.model.size_px = if (many) 8 else 11;
    }
}

export fn resize(w: u32, h: u32) void {
    gpu.resize(w, h);
}

export fn frame(_: f32) void {
    runtime.frame() catch @panic("teak: frame failed (out of memory)");
}
