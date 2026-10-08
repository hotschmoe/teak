//! Headless screenshot of the notes example (no display needed):
//! `zig build shot -- out.png [--state <name>]`, `-- --list` for the states.
//! Each state plays an input script against the real App on the native wgpu
//! backend and writes the last frame.

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");
const script_fonts = @import("script_fonts.zig");

pub fn main(init: std.process.Init) !void {
    const faces = script_fonts.load(init.gpa, init.io);
    defer script_fonts.free(init.gpa, faces);
    var shot_fonts: [8]teak.headless.ShotFont = undefined;
    for (faces, 0..) |f, i| shot_fonts[i] = .{ .family = f.family, .weight = f.weight, .bytes = f.bytes };
    try teak.headless.shotCli(App, Host, Gpu, init, "notes.png", .{
        .fonts = shot_fonts[0..faces.len],
        .width = 1280,
        .height = 800,
        .run = .{ .clear_color = App.bg },
    }, &.{
        .{ .name = "initial", .steps = &.{.{ .frames = 3 }} },
        .{
            .name = "chat_and_selection",
            .steps = &.{
                .{ .frames = 3 },
                // Chat: send one message, leave a wrapped draft in the input.
                .{ .click = .{ 1000, 700 } },
                .{ .chars = "Ship it Friday, then we write the release notes together." },
                .{ .frames = 1 },
                .{ .key = .enter },
                .{ .frames = 1 },
                .{ .chars = "Sounds good! One more thing: can someone check the wrapped" },
                .{ .frames = 1 },
                .{ .chars = " paragraphs on the web build?" },
                .{ .frames = 2 },
                // Notes: drag-select across several wrapped lines.
                .{ .drag = .{ .{ 140, 126 }, .{ 560, 300 } } },
                .{ .move = .{ 640, 700 } },
                .{ .frames = 2 },
            },
        },
        // With script faces present (see script_fonts.zig), the "Show scripts" line opened.
        .{ .name = "scripts", .steps = &.{
            .{ .frames = 3 },
            .{ .click = .{ 60, 765 } },
            .{ .frames = 2 },
        } },
    });
}
