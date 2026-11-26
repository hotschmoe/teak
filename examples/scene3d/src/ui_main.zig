//! Native entry for scene3d. `teak.run` owns the loop; MSAA of the UI pass
//! is on so the canvas triangles and any rotated geometry are antialiased.

const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-native");
const gpu_native = @import("teak-gpu-native");
const App = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    const options = try teak.options_from_environment(init, .{
        .clear_color = .{ 0.07, 0.08, 0.1, 1 },
    });
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var host = try platform.Host.init("Teak scene3d", 900, 500, options);
    defer host.deinit();

    var gpu = try gpu_native.Gpu.initWithOptions(host.nativeHandle(), 900, 500, .{
        .msaa = true,
        .gpu_fallback = options.gpu_fallback,
    });
    defer gpu.deinit();

    try teak.run(App, gpa, &host, &gpu, options);
}
