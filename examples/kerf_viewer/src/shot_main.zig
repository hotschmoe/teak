//! Headless screenshot of the kerf_viewer example (no display needed):
//! `zig build shot -- out.png [--mesh=<fixture>]`. Plays an input script
//! against the real App on the native wgpu backend and writes the last frame.

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    const path = teak.headless.pathArg(init, "kerf_viewer.png");
    try teak.headless.shot(App, Host, Gpu, init.gpa, path, .{
        .width = 1280,
        .height = 800,
        .run = .{ .clear_color = App.paper },
        .steps = &.{
            .{ .frames = 3 },
            .{ .click = .{ 250, 520 } }, // click the model: CPU pick selects the part
            .{ .drag = .{ .{ 600, 650 }, .{ 640, 620 } } }, // orbit a little (empty space: no pick)
            .{ .frames = 2 },
        },
    });
    std.debug.print("wrote {s}\n", .{path});
}
