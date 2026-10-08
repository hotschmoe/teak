//! Headless screenshot of the scene_layers example: `zig build shot -- out.png`.

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    const path = teak.headless.pathArg(init, "scene_layers.png");
    try teak.headless.shot(App, Host, Gpu, init.gpa, path, .{
        .width = 1280,
        .height = 800,
        .run = .{ .clear_color = App.paper },
        .steps = &.{
            .{ .frames = 4 },
            .{ .click = .{ 1100, 108 } }, // select a row in the layers list
            .{ .frames = 2 },
        },
    });
    std.debug.print("wrote {s}\n", .{path});
}
