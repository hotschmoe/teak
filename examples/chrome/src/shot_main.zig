//! Headless screenshots of the chrome example (no display needed):
//! `zig build shot -- out.png [--state <name>]`, `-- --list` for the states.
//! Each state plays a short input script against the real App on the native
//! wgpu backend and writes the last frame.

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    try teak.headless.shotCli(App, Host, Gpu, init, "chrome.png", .{
        .width = 1280,
        .height = 800,
        .run = .{ .clear_color = App.paper },
    }, &.{
        .{
            .name = "edited",
            .steps = &.{
                .{ .frames = 2 },
                .{ .click = .{ 47, 253 } }, // "< PREV": selects the previous part
                .{ .click = .{ 180, 314 } }, // focus the NAME field
                .{ .chars = "-X1" },
                .{ .move = .{ 600, 500 } },
                .{ .frames = 1 },
            },
        },
        .{ .name = "initial", .steps = &.{.{ .frames = 2 }} },
    });
}
