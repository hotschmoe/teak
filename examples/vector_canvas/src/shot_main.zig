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
        .{ .name = "hard", .steps = &.{
            .{ .frames = 3 },
            .{ .move = .{ 30, 600 } },
            .{ .wheel = .{ 0, -2500 } },
            .{ .frames = 3 },
            .{ .click = .{ 196, 27 } },
            .{ .frames = 3 },
        } },
        .{ .name = "nobraces", .steps = &.{
            .{ .frames = 3 },
            .{ .move = .{ 30, 243 } },
            .{ .wheel = .{ 0, -2500 } },
            .{ .frames = 3 },
            .{ .click = .{ 345, 27 } },
            .{ .frames = 3 },
            .{ .drag = .{ .{ 600, 400 }, .{ 760, 470 } } },
            .{ .frames = 3 },
        } },
        .{ .name = "deep", .steps = &.{
            .{ .frames = 3 },
            .{ .move = .{ 30, 600 } },
            .{ .wheel = .{ 0, -2500 } },
            .{ .frames = 3 },
            .{ .move = .{ 60, 517 } },
            .{ .wheel = .{ 0, -1200 } },
            .{ .frames = 3 },
            .{ .drag = .{ .{ 300, 400 }, .{ 700, 400 } } },
            .{ .frames = 3 },
        } },
    });
}
