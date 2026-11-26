//! Native entry for the vector canvas example: `teak.run` owns the loop.

const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-native");
const gpu_native = @import("teak-gpu-native");
const App = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    const options = try teak.options_from_environment(init, .{});
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var host = try platform.Host.init("Teak - Vector canvas", 1280, 800, options);
    defer host.deinit();

    var gpu = try gpu_native.Gpu.initWithOptions(host.nativeHandle(), 1280, 800, .{
        .scale = host.scaleFactor(),
        .gpu_fallback = options.gpu_fallback,
    });
    defer gpu.deinit();

    try teak.run(App, gpa, &host, &gpu, options);
}
