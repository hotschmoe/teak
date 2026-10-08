//! Headless screenshots of the counter_greeter example (no display needed):
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
    try teak.headless.shotCli(App, Host, Gpu, init, "counter_greeter.png", .{
        .width = 900,
        .height = 500,
    }, &.{
        .{ .name = "initial", .steps = &.{.{ .frames = 2 }} },
        .{
            .name = "counted_named",
            .steps = &.{
                .{ .frames = 2 },
                .{ .click = .{ 70, 134 } }, // "+" three times
                .{ .click = .{ 70, 134 } },
                .{ .click = .{ 70, 134 } },
                .{ .click = .{ 284, 98 } }, // focus the greeter field
                .{ .chars = "Teak" },
                .{ .move = .{ 600, 400 } },
                .{ .frames = 2 },
            },
        },
        .{
            .name = "help_modal",
            .steps = &.{
                .{ .frames = 2 },
                .{ .click = .{ 38, 25 } }, // "Help"
                .{ .frames = 2 },
            },
        },
        .{
            .name = "light_mode",
            .steps = &.{
                .{ .frames = 2 },
                .{ .click = .{ 126, 25 } }, // theme toggle: the clear colour follows the theme
                .{ .move = .{ 600, 400 } },
                .{ .frames = 2 },
            },
        },
    });
}
