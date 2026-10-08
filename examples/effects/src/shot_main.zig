//! Headless screenshots of the effects example (no display needed):
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
    try teak.headless.shotCli(App, Host, Gpu, init, "effects.png", .{
        .width = 1000,
        .height = 640,
        .run = .{ .clear_color = .{ 0.08, 0.08, 0.1, 1.0 } },
    }, &.{
        .{ .name = "initial", .steps = &.{.{ .frames = 2 }} },
        .{
            .name = "hover",
            .steps = &.{
                .{ .frames = 2 },
                .{ .move = .{ 60, 101 } }, // over "HTTP GET"
                .{ .frames = 2 },
            },
        },
    });
}
