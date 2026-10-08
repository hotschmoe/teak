//! Native entry for the notes example. `teak.run` owns the loop; the paper
//! background is the clear color, the look comes from `App.themeFor`.

const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-native");
const gpu_native = @import("teak-gpu-native");
const App = @import("app.zig");
const script_fonts = @import("script_fonts.zig");

pub fn main(init: std.process.Init) !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var host = try platform.Host.init("Kerf notes", 1440, 900);
    defer host.deinit();

    const faces = script_fonts.load(gpa, init.io);
    defer script_fonts.free(gpa, faces);
    for (faces) |f| try host.registerFont(f.family, f.weight, f.bytes);

    var gpu = try gpu_native.Gpu.init(host.nativeHandle(), 1440, 900);
    defer gpu.deinit();

    try teak.run(App, gpa, &host, &gpu, .{ .clear_color = App.bg });
}
