//! Native entry for kerf_viewer. `teak.run` owns the loop; the 3D mesh comes
//! from the bundled fixture, `--mesh=<fixture>` (read by the `query_param`
//! effect), `TEAK_OPEN=<file.json>` + the OPEN button, or a file drop.

const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-native");
const gpu_native = @import("teak-gpu-native");
const App = @import("app.zig");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var host = try platform.Host.init("Kerf mesh viewer", 1280, 800);
    defer host.deinit();

    var gpu = try gpu_native.Gpu.initWithOptions(host.nativeHandle(), 1280, 800, .{ .msaa = true });
    defer gpu.deinit();

    try teak.run(App, gpa, &host, &gpu, .{ .clear_color = App.paper, .app_name = "kerf_viewer" });
}
