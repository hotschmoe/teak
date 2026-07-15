//! Native entry for the counter_greeter example. `teak.run` owns the host
//! loop; the app supplies the optional hooks it needs — `keyCharMsg` /
//! `keySpecialMsg` (greeter typing + selection), `keyNeedsClipboard` /
//! `handleClipboard` (cut/copy/paste), `focusedMsg` (focus ring + cursor
//! blink), `themeFor` (dark/light toggle), and the secondary-window trio
//! (`secondaryWindow` / `secondaryView` / `secondaryClosedMsg`) that drives
//! the standalone "Stats" window. Backends (X11 / Win32 + wgpu) are picked
//! by the build under the stable import names below.

const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-native");
const gpu_native = @import("teak-gpu-native");
const App = @import("app.zig");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var host = try platform.Host.init("Teak — Counter + Greeter", 900, 500);
    defer host.deinit();

    var gpu = try gpu_native.Gpu.init(host.nativeHandle(), 900, 500);
    defer gpu.deinit();

    try teak.run(App, gpa, &host, &gpu, .{});
}
