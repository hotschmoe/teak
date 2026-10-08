//! Headless screenshots of the viewport example (no display needed):
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
    try teak.headless.shotCli(App, Host, Gpu, init, "viewport.png", .{
        .width = 900,
        .height = 520,
    }, &.{
        .{ .name = "initial", .steps = &.{.{ .frames = 2 }} },
        .{
            .name = "zoomed_panned",
            .steps = &.{
                .{ .frames = 2 },
                .{ .move = .{ 290, 240 } },
                .{ .wheel = .{ 0, -240 } }, // zoom in around the cursor
                .{ .frames = 2 },
                .{ .drag = .{ .{ 300, 250 }, .{ 380, 300 } } }, // pan
                .{ .frames = 2 },
            },
        },
        // Canvas labels are scalable text (one distance-field glyph set serves every zoom).
        .{ .name = "zoomed_in", .steps = &.{
            .{ .frames = 2 },
            .{ .move = .{ 290, 240 } },
            .{ .wheel = .{ 0, -600 } },
            .{ .frames = 3 },
        } },
        .{ .name = "list_scrolled", .steps = &.{
            .{ .frames = 2 },
            .{ .move = .{ 660, 300 } },
            .{ .wheel = .{ 0, 200 } },
            .{ .frames = 3 },
        } },
    });
}
