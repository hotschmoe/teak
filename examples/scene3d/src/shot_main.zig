//! Headless screenshots of the scene3d example (no display needed):
//! `zig build shot -- out.png [--state <name>]`, `-- --list` for the states.
//! The orbit `Sub` runs on the host's fake 16 ms-per-frame clock, so the
//! camera angle in the picture is deterministic.

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    try teak.headless.shotCli(App, Host, Gpu, init, "scene3d.png", .{
        .width = 1280,
        .height = 800,
        .run = .{ .clear_color = .{ 0.07, 0.08, 0.1, 1 } },
    }, &.{
        .{
            .name = "orbit",
            .steps = &.{
                .{ .frames = 40 }, // ~640 ms of orbit
                .{ .click = .{ 590, 347 } }, // "Hide edges"
                .{ .click = .{ 590, 347 } }, // ... and back on
                .{ .click = .{ 580, 391 } }, // "Zoom +"
                .{ .frames = 5 },
            },
        },
        .{
            .name = "edges_hidden",
            .steps = &.{
                .{ .frames = 40 },
                .{ .click = .{ 590, 347 } }, // "Hide edges"
                .{ .move = .{ 900, 600 } },
                .{ .frames = 3 },
            },
        },
    });
}
