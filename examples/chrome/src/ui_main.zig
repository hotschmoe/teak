//! Native entry for the chrome example. `teak.run` owns the loop; the paper
//! background is the clear color, the look comes from `App.themeFor`.

const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-native");
const gpu_native = @import("teak-gpu-native");
const App = @import("app.zig");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var host = try platform.Host.init("Kerf chrome", 1440, 900);
    defer host.deinit();

    var gpu = try gpu_native.Gpu.init(host.nativeHandle(), 1440, 900);
    defer gpu.deinit();

    try teak.run(App, gpa, &host, &gpu, .{ .clear_color = App.paper });
}
