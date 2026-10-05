//! Native entry for the viewport example. `teak.run` owns the host loop; the
//! app supplies `canvasMsg` (pan / zoom), `scrollMsg` + `scrollLayoutMsg`
//! (scroll list + scrollbar). Backends (X11 / Win32 + wgpu) are picked by the
//! build under the stable import names below.

const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-native");
const gpu_native = @import("teak-gpu-native");
const App = @import("app.zig");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var host = try platform.Host.init("Teak — Viewport", 900, 520);
    defer host.deinit();

    var gpu = try gpu_native.Gpu.init(host.nativeHandle(), 900, 520);
    defer gpu.deinit();

    try teak.run(App, gpa, &host, &gpu, .{});
}
