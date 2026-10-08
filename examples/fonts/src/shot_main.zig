//! Headless screenshots of the fonts example (no display needed):
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
    try teak.headless.shotCli(App, Host, Gpu, init, "fonts.png", .{
        .width = 1000,
        .height = 520,
        .fonts = &.{
            .{ .family = .mono, .weight = .regular, .bytes = @embedFile("plex-Regular") },
            .{ .family = .mono, .weight = .medium, .bytes = @embedFile("plex-Medium") },
            .{ .family = .mono, .weight = .bold, .bytes = @embedFile("plex-Bold") },
        },
        .run = .{ .clear_color = .{ 0.08, 0.08, 0.1, 1.0 } },
    }, &.{
        .{ .name = "initial", .steps = &.{.{ .frames = 2 }} },
    });
}
