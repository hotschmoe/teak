//! Headless screenshots of the todo example (no display needed):
//! `zig build shot -- out.png [--state <name>]`, `-- --list` for the states.
//! Each state plays a short input script against the real App on the
//! native wgpu backend and captures the last frame (the visual-regression
//! goldens in `test/golden/` come from these; see docs/features/visual-regression.md).

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    try teak.headless.shotCli(App, Host, Gpu, init, "todo.png", .{
        .width = 720,
        .height = 600,
    }, &.{
        .{ .name = "initial", .steps = &.{.{ .frames = 2 }} },
        .{
            .name = "three_items",
            .steps = &.{
                .{ .frames = 2 },
                .{ .click = .{ 80, 66 } }, // focus the add input
                .{ .chars = "Buy milk" },
                .{ .frames = 1 },
                .{ .key = .enter },
                .{ .frames = 1 },
                .{ .chars = "Write the golden tests" },
                .{ .frames = 1 },
                .{ .key = .enter },
                .{ .frames = 1 },
                .{ .chars = "Ship it" },
                .{ .frames = 1 },
                .{ .key = .enter },
                .{ .frames = 1 },
                .{ .click = .{ 33, 171 } }, // check the second item
                .{ .move = .{ 400, 400 } },
            },
        },
    });
}
