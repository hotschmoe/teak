//! Headless screenshots of the kerf_viewer example (no display needed):
//! `zig build shot -- out.png [--state <name>]`, `-- --list` for the states.
//! Each state plays an input script against the real App on the native wgpu
//! backend and writes the last frame.

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    try teak.headless.shotCli(App, Host, Gpu, init, "kerf_viewer.png", .{
        .width = 1280,
        .height = 800,
        .run = .{ .clear_color = App.paper },
    }, &.{
        .{
            .name = "picked_orbit",
            .steps = &.{
                .{ .frames = 3 },
                .{ .click = .{ 250, 520 } }, // click the model: CPU pick selects the part
                .{ .drag = .{ .{ 600, 650 }, .{ 640, 620 } } }, // orbit a little (empty space: no pick)
                .{ .frames = 2 },
            },
        },
        .{ .name = "initial", .steps = &.{.{ .frames = 3 }} },
    });
}
