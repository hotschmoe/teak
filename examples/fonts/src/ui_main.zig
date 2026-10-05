//! Native entry for the fonts example. `teak.run` owns the loop; the paper
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

    var host = try platform.Host.init("Teak fonts", 1000, 520);
    defer host.deinit();

    try host.registerFont(.mono, .regular, @embedFile("plex-Regular"));
    try host.registerFont(.mono, .medium, @embedFile("plex-Medium"));
    try host.registerFont(.mono, .bold, @embedFile("plex-Bold"));

    var gpu = try gpu_native.Gpu.init(host.nativeHandle(), 1000, 520);
    defer gpu.deinit();

    try teak.run(App, gpa, &host, &gpu, .{ .clear_color = .{ 0.08, 0.08, 0.1, 1.0 } });
}
