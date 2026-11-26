//! Native entry for the tables example. `teak.run` owns the loop; the paper
//! background is the clear color, the look comes from `App.themeFor`.

const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-native");
const gpu_native = @import("teak-gpu-native");
const App = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    const options = try teak.options_from_environment(init, .{ .clear_color = .{ 0.08, 0.09, 0.11, 1 } });
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var host = try platform.Host.init("Teak tables", 1440, 900, options);
    defer host.deinit();

    var gpu = try gpu_native.Gpu.initWithOptions(host.nativeHandle(), 1440, 900, .{ .gpu_fallback = options.gpu_fallback });
    defer gpu.deinit();

    try teak.run(App, gpa, &host, &gpu, options);
}
