//! Headless screenshots of the vector canvas example (no display needed):
//! `zig build shot -- out.png [--state <name>]`, `-- --list` for the states.

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    try teak.headless.shotCli(App, Host, Gpu, init, "vector_canvas.png", .{
        .width = 1280,
        .height = 800,
    }, &.{
        .{ .name = "fit", .steps = &.{.{ .frames = 3 }} },
        .{ .name = "zoomed", .steps = &.{
            .{ .frames = 3 },
            .{ .move = .{ 640, 420 } },
            .{ .wheel = .{ 0, -1500 } },
            .{ .frames = 3 },
        } },
        .{ .name = "roof", .steps = &.{
            .{ .frames = 3 },
            .{ .move = .{ 30, 243 } },
            .{ .wheel = .{ 0, -2500 } },
            .{ .frames = 3 },
        } },
        .{ .name = "base", .steps = &.{
            .{ .frames = 3 },
            .{ .move = .{ 30, 600 } },
            .{ .wheel = .{ 0, -2500 } },
            .{ .frames = 3 },
        } },
    });
}
