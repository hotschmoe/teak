//! Headless screenshot of the notes example (no display needed):
//! `zig build shot -- out.png`. Plays a short input script against the
//! real App on the native wgpu backend and writes the last frame.

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    const path = teak.headless.pathArg(init, "notes.png");
    try teak.headless.shot(App, Host, Gpu, init.gpa, path, .{
        .width = 1280,
        .height = 800,
        .run = .{ .clear_color = App.bg },
        .steps = &.{
            .{ .frames = 3 },
            // Chat: send one message, leave a wrapped draft in the input.
            .{ .click = .{ 1000, 700 } },
            .{ .chars = "Ship it Friday, then we write the release notes together." },
            .{ .frames = 1 },
            .{ .key = .enter },
            .{ .frames = 1 },
            .{ .chars = "Sounds good! One more thing: can someone check the wrapped" },
            .{ .frames = 1 },
            .{ .chars = " paragraphs on the web build?" },
            .{ .frames = 2 },
            // Notes: drag-select across several wrapped lines.
            .{ .drag = .{ .{ 140, 126 }, .{ 560, 300 } } },
            .{ .move = .{ 640, 700 } },
            .{ .frames = 2 },
        },
    });
    std.debug.print("wrote {s}\n", .{path});
}
