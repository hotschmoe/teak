//! Headless screenshot of the chrome example (no display needed):
//! `zig build shot -- out.png`. Plays a short input script against the
//! real App on the native wgpu backend and writes the last frame.

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    const path = teak.headless.pathArg(init, "chrome.png");
    try teak.headless.shot(App, Host, Gpu, init.gpa, path, .{
        .width = 1280,
        .height = 800,
        .run = .{ .clear_color = App.paper },
        .steps = &.{
            .{ .frames = 2 },
            .{ .click = .{ 43, 239 } }, // "< PREV": selects the previous part
            .{ .click = .{ 180, 313 } }, // focus the NAME field
            .{ .chars = "-X1" },
            .{ .click = .{ 180, 376 } }, // open the MATERIAL combobox
            .{ .chars = "al" }, // filter: aluminum alloys, G10 / FR4 ... "al" substring
            .{ .move = .{ 600, 500 } },
            .{ .frames = 1 },
        },
    });
    std.debug.print("wrote {s}\n", .{path});
}
