//! Headless screenshot of the chrome example (no display needed):
//! `zig build shot -- out.png`. Plays a short input script against the
//! real App on the native wgpu backend and writes the last frame.
//!
//! `zig build shot -- out.png N` instead closes the help popover, lets it
//! settle, re-opens it and captures N frames (16 ms each) into the slide-in
//! animation: N=3 is mid-slide, N=30 is settled.

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    const path = teak.headless.pathArg(init, "chrome.png");
    var it = init.minimal.args.iterate();
    _ = it.next();
    _ = it.next();
    if (it.next()) |n_arg| {
        const n = try std.fmt.parseInt(u32, n_arg, 10);
        try teak.headless.shot(App, Host, Gpu, init.gpa, path, .{
            .width = 1280,
            .height = 800,
            .run = .{ .clear_color = App.paper },
            .steps = &.{
                .{ .frames = 2 },
                .{ .click = .{ 1240, 20 } }, // HELP: close the popover
                .{ .frames = 40 }, // let the slide-out settle
                .{ .click = .{ 1240, 20 } }, // HELP: re-open (starts the slide-in)
                .{ .frames = n },
            },
        });
        std.debug.print("wrote {s} ({d} frames into the slide-in)\n", .{ path, n });
        return;
    }
    try teak.headless.shot(App, Host, Gpu, init.gpa, path, .{
        .width = 1280,
        .height = 800,
        .run = .{ .clear_color = App.paper },
        .steps = &.{
            .{ .frames = 2 },
            .{ .click = .{ 43, 239 } }, // "< PREV": selects the previous part
            .{ .click = .{ 180, 298 } }, // focus the NAME field
            .{ .chars = "-X1" },
            .{ .move = .{ 600, 500 } },
            .{ .frames = 1 },
        },
    });
    std.debug.print("wrote {s}\n", .{path});
}
