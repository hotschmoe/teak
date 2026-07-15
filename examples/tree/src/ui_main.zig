//! Native entry for the tree example. `teak.run` owns the host loop; the
//! app supplies `keySpecialMsg` (arrow / page-key scrolling) and
//! `wheelMsg` (mouse-wheel scrolling). Backends (X11 / Win32 + wgpu) are
//! picked by the build under the stable import names below.

const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-native");
const gpu_native = @import("teak-gpu-native");
const App = @import("app.zig");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var host = try platform.Host.init("Teak — Tree", 720, 600);
    defer host.deinit();

    var gpu = try gpu_native.Gpu.init(host.nativeHandle(), 720, 600);
    defer gpu.deinit();

    try teak.run(App, gpa, &host, &gpu, .{});
}
