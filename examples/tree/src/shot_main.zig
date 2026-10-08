//! Headless screenshots of the tree example (no display needed):
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
    try teak.headless.shotCli(App, Host, Gpu, init, "tree.png", .{
        .width = 720,
        .height = 600,
    }, &.{
        .{ .name = "initial", .steps = &.{.{ .frames = 2 }} },
        .{
            .name = "toggled",
            .steps = &.{
                .{ .frames = 2 },
                .{ .click = .{ 75, 117 } }, // collapse "core"
                .{ .click = .{ 75, 231 } }, // expand "input" (row moved up)
                .{ .move = .{ 600, 500 } },
                .{ .frames = 2 },
            },
        },
    });
}
